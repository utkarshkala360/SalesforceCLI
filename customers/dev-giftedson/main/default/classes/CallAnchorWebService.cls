@RestResource(urlMapping='/CallAnchorWebhook/*')
global without sharing class CallAnchorWebService {
  @HttpPost
  global static void handleWebhook() {
    RestResponse res = RestContext.response;
    res.addHeader('Content-Type', 'application/json');

    try {
      String requestBody = RestContext.request.requestBody.toString();

      if (String.isBlank(requestBody)) {
        sendError(400, 'Empty request body.');
        return;
      }

      Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(
        requestBody
      );

      Map<String, Object> callData;

      if (root.containsKey('call') && root.get('call') != null) {
        callData = (Map<String, Object>) root.get('call');
      } else {
        callData = root;
      }

      /*
       * =========================================================
       * READ CALL ANCHOR DATA
       * =========================================================
       */

      String callId = getString(callData, 'id');

      String callType = getString(callData, 'callType');

      String agentName = getString(callData, 'agentName');

      // Agent mobile supplied by the Call Anchor webhook.
      String agentMobile = getString(callData, 'agentNumber');

      String startedAt = getString(callData, 'startedAt');

      String recordingUrl = getString(callData, 'recordingUrl');

      String dispositionLabel = getString(callData, 'dispositionLabel');

      String dispositionNote = getString(callData, 'dispositionNote');

      String dispositionScheduledAt = getString(
        callData,
        'dispositionScheduledAt'
      );

      /*
       * =========================================================
       * IDENTIFY CUSTOMER NAME / PHONE
       * =========================================================
       */

      String customerPhone;
      String customerName;

      if (!String.isBlank(callType) && callType.toLowerCase() == 'incoming') {
        customerPhone = firstNonBlank(
          new List<String>{
            getString(callData, 'callerPhone'),
            getString(callData, 'calleePhone'),
            getString(callData, 'customerPhone'),
            getString(callData, 'phone')
          }
        );

        customerName = firstNonBlank(
          new List<String>{
            getString(callData, 'callerName'),
            getString(callData, 'calleeName'),
            getString(callData, 'customerName'),
            getString(callData, 'name')
          }
        );
      } else {
        customerPhone = firstNonBlank(
          new List<String>{
            getString(callData, 'calleePhone'),
            getString(callData, 'callerPhone'),
            getString(callData, 'customerPhone'),
            getString(callData, 'phone')
          }
        );

        customerName = firstNonBlank(
          new List<String>{
            getString(callData, 'calleeName'),
            getString(callData, 'callerName'),
            getString(callData, 'customerName'),
            getString(callData, 'name')
          }
        );
      }

      if (String.isBlank(customerPhone)) {
        sendError(400, 'Customer phone number is missing.');

        return;
      }

      String normalizedPhone = normalizePhone(customerPhone);

      /*
       * =========================================================
       * DUPLICATE CALL CHECK
       * =========================================================
       */

      if (!String.isBlank(callId)) {
        List<Task> existingTasks = [
          SELECT Id
          FROM Task
          WHERE Call_Id__c = :callId
          LIMIT 1
        ];

        if (!existingTasks.isEmpty()) {
          sendSuccess(
            new Map<String, Object>{
              'success' => true,
              'duplicate' => true,
              'taskId' => existingTasks[0].Id
            }
          );

          return;
        }
      }

      /*
       * =========================================================
       * FIND LEAD USING MobilePhone
       * =========================================================
       */

      Lead leadRecord = findLeadByMobile(normalizedPhone);

      Boolean leadCreated = false;

      /*
       * =========================================================
       * UNKNOWN NUMBER → CREATE NEW LEAD
       * =========================================================
       */

      if (leadRecord == null) {
        leadRecord = new Lead();

        if (!String.isBlank(customerName)) {
          leadRecord.LastName = customerName;
        }

        // Standard mandatory Lead fields

        leadRecord.Company = 'Unknown';

        // Client's primary phone field
        leadRecord.MobilePhone = customerPhone;

        insert leadRecord;

        leadCreated = true;
      }

      /*
       * =========================================================
       * CREATE TASK
       * =========================================================
       */

      Task taskRecord = new Task();

      /*
       * Lead relationship
       */
      taskRecord.WhoId = leadRecord.Id;

      /*
       * Task Owner
       */
      Id agentUserId = findAgentUser(agentName);

      if (agentUserId != null) {
        taskRecord.OwnerId = agentUserId;
      } else {
        taskRecord.OwnerId = UserInfo.getUserId();
      }

      /*
       * =========================================================
       * SUBJECT
       * =========================================================
       */

      String displayName = !String.isBlank(customerName)
        ? customerName
        : customerPhone;

      String normalizedCallType = normalizeCallType(callType);

      taskRecord.Subject =
        normalizedCallType +
        ' Call - ' +
        displayName +
        ' - ' +
        customerPhone;

      taskRecord.Status = 'Completed';

      /*
       * =========================================================
       * CALL DATETIME
       * =========================================================
       */

      Datetime callDateTime = parseDateTime(startedAt);

      if (callDateTime != null) {
        taskRecord.ActivityDate = callDateTime.date();

        taskRecord.Call_Started_At__c = callDateTime;
      } else {
        taskRecord.ActivityDate = Date.today();
      }

      /*
       * =========================================================
       * STANDARD CALL ANCHOR TASK FIELDS
       * =========================================================
       */

      taskRecord.Agent_Name__c = agentName;

      // Preserve the webhook phone value, including + and leading zeros.
      taskRecord.Agent_Mobile__c = agentMobile;

      taskRecord.Call_Id__c = callId;

      taskRecord.Recording_URL__c = recordingUrl;

      taskRecord.Call_Type__c = normalizedCallType;

      taskRecord.Disposition__c = dispositionLabel;

      taskRecord.Disposition_Note__c = dispositionNote;

      /*
       * Duration
       */
      if (
        callData.containsKey('durationSeconds') &&
        callData.get('durationSeconds') != null
      ) {
        try {
          taskRecord.Duration_Seconds__c = Decimal.valueOf(
            String.valueOf(callData.get('durationSeconds'))
          );
        } catch (Exception ignored) {
        }
      }

      /*
       * =========================================================
       * DISPOSITION
       * =========================================================
       */

      Map<String, Object> disposition = getDisposition(root, callData);

      if (disposition != null) {
        Map<String, Object> dispositionFields = getMap(disposition, 'fields');

        if (dispositionFields != null) {
          /*
           * Generic disposition outcome
           */
          if (String.isBlank(dispositionLabel)) {
            dispositionLabel = getString(dispositionFields, 'outcome');

            taskRecord.Disposition__c = dispositionLabel;
          }

          /*
           * Generic disposition note
           */
          if (String.isBlank(dispositionNote)) {
            dispositionNote = getString(dispositionFields, 'note');

            taskRecord.Disposition_Note__c = dispositionNote;
          }

          /*
           * Scheduled follow-up
           */
          if (String.isBlank(dispositionScheduledAt)) {
            dispositionScheduledAt = getString(
              dispositionFields,
              'scheduled-at'
            );
          }
        }
      }

      /*
       * =========================================================
       * REMINDER
       * =========================================================
       */

      Datetime scheduledDate = parseDateTime(dispositionScheduledAt);

      if (scheduledDate != null) {
        taskRecord.Callback_scheduled__c = scheduledDate;

        taskRecord.IsReminderSet = true;

        taskRecord.ReminderDateTime = scheduledDate;
      }

      /*
       * =========================================================
       * DESCRIPTION
       * =========================================================
       */

      List<String> descriptionLines = new List<String>();

      if (!String.isBlank(callId)) {
        descriptionLines.add('Call ID: ' + callId);
      }

      if (!String.isBlank(callType)) {
        descriptionLines.add('Call Type: ' + callType);
      }

      if (!String.isBlank(agentName)) {
        descriptionLines.add('Agent: ' + agentName);
      }

      if (!String.isBlank(startedAt)) {
        descriptionLines.add('Started At: ' + startedAt);
      }

      if (!String.isBlank(recordingUrl)) {
        descriptionLines.add('Recording URL: ' + recordingUrl);
      }

      if (!String.isBlank(dispositionLabel)) {
        descriptionLines.add('Disposition: ' + dispositionLabel);
      }

      if (!String.isBlank(dispositionNote)) {
        descriptionLines.add('Disposition Note: ' + dispositionNote);
      }

      taskRecord.Description = String.join(descriptionLines, '\n');

      /*
       * =========================================================
       * INSERT TASK
       * =========================================================
       */

      insert taskRecord;

      /*
       * =========================================================
       * RESPONSE TO CALL ANCHOR
       * =========================================================
       */

      sendSuccess(
        new Map<String, Object>{
          'success' => true,
          'leadId' => leadRecord.Id,
          'leadCreated' => leadCreated,
          'taskId' => taskRecord.Id
        }
      );
    } catch (Exception e) {
      sendError(500, e.getMessage() + ' | Line: ' + e.getLineNumber());
    }
  }

  /*
   * =============================================================
   * FIND LEAD USING MobilePhone
   * =============================================================
   */

  private static Lead findLeadByMobile(String incomingPhone) {
    if (String.isBlank(incomingPhone)) {
      return null;
    }

    String comparisonNumber = getLastDigits(incomingPhone, 10);

    String suffix = getLastDigits(comparisonNumber, 4);

    String searchPattern = '%' + suffix;

    List<Lead> candidates = [
      SELECT Id, FirstName, LastName, Company, MobilePhone
      FROM Lead
      WHERE MobilePhone LIKE :searchPattern
      LIMIT 200
    ];

    for (Lead leadItem : candidates) {
      String salesforcePhone = normalizePhone(leadItem.MobilePhone);

      if (String.isBlank(salesforcePhone)) {
        continue;
      }

      String salesforceComparison = getLastDigits(salesforcePhone, 10);

      if (salesforceComparison == comparisonNumber) {
        return leadItem;
      }
    }

    return null;
  }

  /*
   * =============================================================
   * PHONE NORMALIZATION
   * =============================================================
   */

  private static String normalizePhone(String phone) {
    if (String.isBlank(phone)) {
      return null;
    }

    return phone.replaceAll('[^0-9]', '');
  }

  private static String getLastDigits(String value, Integer digits) {
    if (String.isBlank(value)) {
      return value;
    }

    if (value.length() <= digits) {
      return value;
    }

    return value.substring(value.length() - digits);
  }

  /*
   * =============================================================
   * FIND AGENT USER
   * =============================================================
   */

  private static Id findAgentUser(String agentName) {
    if (String.isBlank(agentName)) {
      return null;
    }

    List<User> users = [
      SELECT Id
      FROM User
      WHERE Name = :agentName AND IsActive = TRUE
      LIMIT 1
    ];

    if (!users.isEmpty()) {
      return users[0].Id;
    }

    return null;
  }

  /*
   * =============================================================
   * NORMALIZE CALL TYPE
   * =============================================================
   */

  private static String normalizeCallType(String callType) {
    if (String.isBlank(callType)) {
      return 'Call';
    }

    if (callType.toLowerCase() == 'incoming') {
      return 'Incoming';
    }

    if (callType.toLowerCase() == 'outgoing') {
      return 'Outgoing';
    }

    return callType;
  }

  /*
   * =============================================================
   * DATETIME PARSER
   * =============================================================
   */

  private static Datetime parseDateTime(String value) {
    if (String.isBlank(value)) {
      return null;
    }

    try {
      return (Datetime) JSON.deserialize('"' + value + '"', Datetime.class);
    } catch (Exception e) {
      try {
        return Datetime.valueOf(value);
      } catch (Exception ignored) {
        return null;
      }
    }
  }

  /*
   * =============================================================
   * DISPOSITION
   * =============================================================
   */

  private static Map<String, Object> getDisposition(
    Map<String, Object> root,
    Map<String, Object> callData
  ) {
    if (root.containsKey('disposition') && root.get('disposition') != null) {
      return (Map<String, Object>) root.get('disposition');
    }

    if (
      callData.containsKey('disposition') && callData.get('disposition') != null
    ) {
      return (Map<String, Object>) callData.get('disposition');
    }

    return null;
  }

  /*
   * =============================================================
   * JSON HELPERS
   * =============================================================
   */

  private static String getString(Map<String, Object> data, String key) {
    if (data == null || !data.containsKey(key) || data.get(key) == null) {
      return null;
    }

    return String.valueOf(data.get(key));
  }

  private static Map<String, Object> getMap(
    Map<String, Object> data,
    String key
  ) {
    if (data == null || !data.containsKey(key) || data.get(key) == null) {
      return null;
    }

    return (Map<String, Object>) data.get(key);
  }

  private static String firstNonBlank(List<String> values) {
    for (String value : values) {
      if (!String.isBlank(value)) {
        return value;
      }
    }

    return null;
  }

  /*
   * =============================================================
   * SUCCESS RESPONSE
   * =============================================================
   */

  private static void sendSuccess(Map<String, Object> responseData) {
    RestContext.response.statusCode = 200;

    RestContext.response.responseBody = Blob.valueOf(
      JSON.serialize(responseData)
    );
  }

  /*
   * =============================================================
   * ERROR RESPONSE
   * =============================================================
   */

  private static void sendError(Integer statusCode, String message) {
    RestContext.response.statusCode = statusCode;

    RestContext.response.responseBody = Blob.valueOf(
      JSON.serialize(
        new Map<String, Object>{ 'success' => false, 'message' => message }
      )
    );
  }
}
