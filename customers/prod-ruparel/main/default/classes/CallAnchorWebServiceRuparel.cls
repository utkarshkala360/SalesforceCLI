@RestResource(urlMapping='/CallAnchorWebhooks/*')
global with sharing class CallAnchorWebServiceRuparel {
  // ---------- Response wrapper ----------
  global class CallResponse {
    global Boolean success;
    global String message;
    global Id taskId;
    global Id matchedLeadId;
  }

  global class CallPayload {
    public CallData call;
    public String event;
    public Object disposition;
    public Boolean hasRecording;
  }

  global class CallData {
    public String id;
    public String callType;
    public String agentName;
    public Datetime startedAt;
    public String calleeName;
    public String calleePhone;
    public String recordingUrl;
    public String dispositionNote;
    public Integer durationSeconds;
    public String dispositionLabel;
    public Datetime dispositionScheduledAt;
  }

  // ---------- Webhook ----------
  @HttpPost
  global static void doPost() {
    RestResponse res = RestContext.response;
    res.addHeader('Content-Type', 'application/json');

    try {
      RestRequest req = RestContext.request;

      if (
        req == null ||
        req.requestBody == null ||
        req.requestBody.size() == 0
      ) {
        res.statusCode = 400;
        res.responseBody = Blob.valueOf('{"error":"Empty request body."}');
        return;
      }

      CallPayload payload;

      try {
        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(
          req.requestBody.toString()
        );

        payload = new CallPayload();

        payload.event = (String) root.get('event');

        payload.hasRecording = (Boolean) root.get('hasRecording');

        Object callRaw = root.get('call');

        if (callRaw != null) {
          payload.call = (CallData) JSON.deserialize(
            JSON.serialize(callRaw),
            CallData.class
          );
        }

        // Keep disposition as generic object
        payload.disposition = root.get('disposition');
      } catch (Exception parseEx) {
        System.debug(
          LoggingLevel.ERROR,
          'Payload parsing error: ' + parseEx.getMessage()
        );

        res.statusCode = 400;
        res.responseBody = Blob.valueOf('{"error":"malformed payload"}');
        return;
      }

      // Validate phone number
      if (payload.call == null || String.isBlank(payload.call.calleePhone)) {
        res.statusCode = 400;
        res.responseBody = Blob.valueOf('{"error":"PhoneNumber is required"}');
        return;
      }

      Task recordTask = buildTask(payload);

      if (recordTask != null) {
        res.statusCode = 200;

        res.responseBody = Blob.valueOf(
          '{"status":"ok","taskId":"' + recordTask.Id + '"}'
        );
      } else {
        res.statusCode = 400;

        res.responseBody = Blob.valueOf('{"error":"Some thing went wrong"}');
      }
    } catch (Exception ex) {
      System.debug(LoggingLevel.ERROR, 'Webhook error: ' + ex.getMessage());

      res.statusCode = 400;

      res.responseBody = Blob.valueOf('{"error":"malformed payload"}');

      return;
    }
  }

  // ---------- Build Task ----------
  global static Task buildTask(CallPayload payloadData) {
    // Normalize incoming phone number
    String cleanNumber = payloadData.call.calleePhone.replaceAll('[^0-9]', '');

    if (cleanNumber.length() > 10) {
      cleanNumber = cleanNumber.right(10);
    }

    String likePattern = '%' + cleanNumber + '%';

    try {
      // ---------------------------------------------
      // Get disposition fields from webhook
      // ---------------------------------------------

      Map<String, Object> dispositionObj = (Map<String, Object>) payloadData.disposition;

      if (dispositionObj == null) {
        System.debug(LoggingLevel.WARN, 'Disposition object is missing.');
        return null;
      }

      Map<String, Object> fields = (Map<String, Object>) dispositionObj.get(
        'fields'
      );

      if (fields == null) {
        System.debug(LoggingLevel.WARN, 'Disposition fields are missing.');
        return null;
      }

      // ---------------------------------------------
      // Read values from disposition.fields
      // ---------------------------------------------

      String projectName = (String) fields.get('project-name');

      String outcome = (String) fields.get('outcome');

      String note = (String) fields.get('note');

      // ---------------------------------------------
      // Normalize Project Name
      // Example:
      // ruparel-arista -> ruparel arista
      // ---------------------------------------------

      if (String.isNotBlank(projectName)) {
        projectName = projectName.replace('-', ' ').trim();
      }

      System.debug('### Project Name: ' + projectName);

      System.debug('### Outcome: ' + outcome);

      System.debug('### Note: ' + note);

      // ---------------------------------------------
      // Find Lead using Phone + Project Name
      // ---------------------------------------------

      List<Lead__c> matchedLeads = [
        SELECT Id, Name, Project__c, Project__r.Name
        FROM Lead__c
        WHERE
          Primary_Mobile__c LIKE :likePattern
          AND Project__r.Name = :projectName
      ];

      // FIX: guard against empty list before indexing
      Lead__c matchedLead = matchedLeads.isEmpty() ? null : matchedLeads[0];

      // ---------------------------------------------
      // Find Project by Name (independent of Lead match)
      // ---------------------------------------------

      List<Project__c> matchedProjects = [
        SELECT Id, Name
        FROM Project__c
        WHERE Name = :projectName
        LIMIT 1
      ];

      // FIX: guard against empty list before indexing
      Project__c matchedProject = matchedProjects.isEmpty()
        ? null
        : matchedProjects[0];

      // ---------------------------------------------
      // Build Task Subject
      // ---------------------------------------------

      String subject = String.isNotBlank(payloadData.call.callType)
        ? 'Call - ' + payloadData.call.callType
        : 'Call Log';

      // ---------------------------------------------
      // Create Task
      // ---------------------------------------------

      Task t = new Task();

      // WhatId only set if a lead was actually matched;
      // otherwise Task is still created with WhatId = null
      t.WhatId = matchedLead != null ? matchedLead.Id : null;

      t.mobile__c = payloadData.call.calleePhone;

      t.Subject = subject;

      t.ActivityDate = payloadData.call.startedAt != null
        ? payloadData.call.startedAt.date()
        : Date.today();

      // Recording URL
      t.recordingUrl__c = payloadData.call.recordingUrl;
      t.Audio_File__c = payloadData.call.recordingUrl;

      // ---------------------------------------------
      // Disposition fields
      // ---------------------------------------------

      t.outcome__c = outcome;

      t.note__c = note;

      // IMPORTANT:
      // Store PROJECT NAME instead of dispositionLabel

      t.Call_Disposition__c = projectName;

      // ---------------------------------------------
      // Scheduled At
      // ---------------------------------------------

      Object scheduledAtRaw = fields.get('scheduled-at');

      if (scheduledAtRaw != null) {
        String scheduledAtStr = (String) scheduledAtRaw;

        try {
          t.scheduled_At__c = (Datetime) JSON.deserialize(
            '"' + scheduledAtStr + '"',
            Datetime.class
          );
        } catch (Exception ex) {
          System.debug(
            LoggingLevel.WARN,
            'Could not parse scheduled-at: ' + scheduledAtStr
          );
        }
      }

      // Project lookup only set if a Project__c record
      // with that name actually exists; independent of
      // whether a Lead was matched
      t.Project__c = matchedProject != null ? matchedProject.Id : null;

      // ---------------------------------------------
      // Insert Task
      // ---------------------------------------------

      insert t;

      return t;
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.ERROR,
        'Error while logging call: ' + ex.getMessage()
      );

      return null;
    }
  }
}
