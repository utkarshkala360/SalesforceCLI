/**
 * Manish Minerals & Chemicals - Call Anchor Rest Class.
 */
@RestResource(urlMapping='/CallAnchorWebhook/*')
global with sharing class CallAnchorWebService {
  private static final String NEW_ENQUIRY_RECORD_TYPE = 'New_Customer';
  private static final String NEW_TEAM_MEMBER = 'New';
  private static final Integer CANDIDATE_LIMIT = 500;
  // Agent mobile (normalized: country code + number, digits only) -> Enquiry Team_Member__c.
  // Agents not listed here fall back to NEW_TEAM_MEMBER.
  private static final Map<String, String> TEAM_MEMBER_BY_AGENT_MOBILE = new Map<String, String>{
    '918291936833' => 'Vaishnavi Prabhu',
    '918657490344' => 'Megha Haria',
    '919319300765' => 'Pooja Kharade',
    '919664980208' => 'Sweta Nevatia'
  };

  private class RequestException extends Exception {
  }
  private class MatchConflictException extends Exception {
  }
  private class ConfigurationException extends Exception {
  }

  private class CallData {
    public String id;
    public String callType;
    public String agentName;
    public String agentNumber;
    public Datetime startedAt;
    public String calleeName;
    public String calleePhone;
    public String recordingUrl;
    public String dispositionNote;
    public Integer durationSeconds;
    public String dispositionLabel;
    public Datetime dispositionScheduledAt;
  }

  // Fixed response contract: every field is always present (null when not applicable),
  // so Call Anchor can parse success and error responses with one schema.
  @TestVisible
  private class WebhookResponse {
    public Boolean success; // true for 2xx, false otherwise
    public Integer statusCode; // mirrors the HTTP status code
    public String code; // TASK_CREATED | TASK_UPDATED | EVENT_IGNORED | error code
    public String action; // created | updated | ignored | failed
    public String message; // human readable summary
    public Boolean retryable; // true when the same request may succeed if resent later
    public String event; // event name received in the payload
    public String callId; // call.id received in the payload
    public Id taskId; // Task created/updated
    public Id relatedRecordId; // Account or Enquiry__c the Task is related to
    public String relatedObject; // Account | Enquiry__c
    public Boolean createdEnquiry; // true when a new Enquiry__c was created for the caller
    public List<String> warnings = new List<String>();
    public String requestId; // Salesforce request id, for log correlation
    public String processedAt; // ISO-8601 UTC timestamp
  }

  @HttpPost
  global static void receiveCall() {
    Savepoint checkpoint;
    WebhookResponse result = new WebhookResponse();
    List<String> warnings = result.warnings;
    try {
      if (
        RestContext.request == null ||
        RestContext.request.requestBody == null
      ) {
        throw new RequestException('A JSON request body is required.');
      }
      Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
        RestContext.request.requestBody.toString()
      );
      if (body == null)
        throw new RequestException('The JSON body must be an object.');
      String eventName = stringValue(body.get('event'));
      result.event = eventName;
      if (String.isBlank(eventName))
        throw new RequestException('event is required.');
      // if (eventName != 'recording.ready') {
      //   result.code = 'EVENT_IGNORED';
      //   result.action = 'ignored';
      //   result.message =
      //     'Event "' +
      //     eventName +
      //     '" is not processed; only recording.ready is handled.';
      //   respond(200, result);
      //   return;
      // }
      if (!(body.get('call') instanceof Map<String, Object>)) {
        throw new RequestException('call must be a JSON object.');
      }
      CallData callData = (CallData) JSON.deserialize(
        JSON.serialize(body.get('call')),
        CallData.class
      );
      if (callData != null)
        result.callId = callData.id;
      validateCall(callData);
      Map<String, Object> dispositionFields = new Map<String, Object>();
      if (body.get('disposition') != null) {
        Map<String, Object> disposition = (Map<String, Object>) body.get(
          'disposition'
        );
        if (disposition.get('fields') != null) {
          dispositionFields = (Map<String, Object>) disposition.get('fields');
        }
      }
      String outcome = firstNonblank(
        stringValue(dispositionFields.get('outcome')),
        callData.dispositionLabel
      );
      String note = firstNonblank(
        stringValue(dispositionFields.get('note')),
        callData.dispositionNote
      );

      // Bind values, never concatenate payload data into a query.
      List<SObject> existingTasks = Database.queryWithBinds(
        'SELECT Id, WhatId, calleePhone__c FROM Task ' +
        'WHERE Call_Id__c = :callId LIMIT 2 FOR UPDATE',
        new Map<String, Object>{ 'callId' => callData.id },
        AccessLevel.USER_MODE
      );
      if (existingTasks.size() > 1) {
        throw new MatchConflictException(
          'Multiple Tasks already have this Call_Id__c. Resolve duplicates first.'
        );
      }
      Boolean isNewTask = existingTasks.isEmpty();
      Id parentId;
      Boolean createdEnquiry = false;
      Task activity;

      // Roll back both records if later field mapping or DML fails.
      checkpoint = Database.setSavepoint();
      if (isNewTask) {
        parentId = matchCompany(callData.calleePhone, warnings);
        if (parentId == null)
          parentId = matchEnquiry(callData.calleePhone);
        if (parentId == null) {
          parentId = createEnquiry(
            callData.calleePhone,
            callData.calleeName,
            callData.agentNumber,
            warnings
          );
          createdEnquiry = true;
        }
        activity = new Task(WhatId = parentId, OwnerId = UserInfo.getUserId());
        List<TaskStatus> closedStatuses = [
          SELECT ApiName
          FROM TaskStatus
          WHERE IsClosed = TRUE
          ORDER BY SortOrder
          LIMIT 1
        ];
        if (closedStatuses.isEmpty()) {
          throw new ConfigurationException(
            'Configure at least one closed Task status.'
          );
        }
        activity.Status = closedStatuses[0].ApiName;
        activity.TaskSubtype = 'Call';
        // Do not set WhoId: this activity belongs to the Company/Enquiry.
      } else {
        SObject previous = existingTasks[0];
        String previousPhone = stringValue(previous.get('calleePhone__c'));
        if (
          !String.isBlank(previousPhone) &&
          normalizePhone(previousPhone) != normalizePhone(callData.calleePhone)
        ) {
          throw new MatchConflictException(
            'This call ID is already associated with a different customer phone.'
          );
        }
        parentId = (Id) previous.get('WhatId');
        if (
          parentId == null ||
          (parentId.getSObjectType().getDescribe().getName() != 'Account' &&
          parentId.getSObjectType().getDescribe().getName() != 'Enquiry__c')
        ) {
          throw new MatchConflictException(
            'The existing Task must be related to an Account or Enquiry__c.'
          );
        }
        activity = new Task(Id = (Id) previous.get('Id'));
      }

      String direction = callData.callType.equalsIgnoreCase('Incoming')
        ? 'Incoming'
        : 'Outgoing';
      String customer = firstNonblank(
        callData.calleeName,
        callData.calleePhone
      );
      activity.Subject = clip(
        direction + ' call - ' + customer,
        Task.Subject.getDescribe().getLength()
      );
      activity.ActivityDate = callData.startedAt.dateGmt();
      activity.CallType = direction == 'Incoming' ? 'Inbound' : 'Outbound';
      if (callData.durationSeconds != null) {
        activity.CallDurationInSeconds = callData.durationSeconds;
      }

      putValue(activity, 'Call_Id__c', callData.id, true, warnings);
      putValue(activity, 'Agent_Name__c', callData.agentName, true, warnings);
      putValue(
        activity,
        'Agent_Mobile__c',
        callData.agentNumber,
        true,
        warnings
      );
      putValue(activity, 'calleeName__c', callData.calleeName, true, warnings);
      putValue(
        activity,
        'calleePhone__c',
        callData.calleePhone,
        true,
        warnings
      );
      putValue(activity, 'callType__c', direction, true, warnings);
      putValue(activity, 'startedAt__c', callData.startedAt, true, warnings);
      putValue(
        activity,
        'durationSeconds__c',
        callData.durationSeconds,
        true,
        warnings
      );
      putValue(
        activity,
        'recordingUrl__c',
        callData.recordingUrl,
        true,
        warnings
      );
      putValue(
        activity,
        'Recording_Link__c',
        callData.recordingUrl,
        false,
        warnings
      );
      putValue(
        activity,
        'disposition__c',
        firstNonblank(callData.dispositionLabel, outcome),
        true,
        warnings
      );
      putValue(activity, 'Outcome__c', outcome, true, warnings);
      putValue(activity, 'Note__c', note, true, warnings);
      putValue(
        activity,
        'ScheduledAt__c',
        callData.dispositionScheduledAt,
        true,
        warnings
      );
      setRelatedType(activity, parentId, warnings);

      if (isNewTask) {
        insert as user activity;
      } else {
        update as user activity;
      }
      String relatedObject = parentId.getSObjectType().getDescribe().getName();
      result.code = isNewTask ? 'TASK_CREATED' : 'TASK_UPDATED';
      result.action = isNewTask ? 'created' : 'updated';
      result.taskId = activity.Id;
      result.relatedRecordId = parentId;
      result.relatedObject = relatedObject;
      result.createdEnquiry = createdEnquiry;
      result.message =
        (isNewTask ? 'Call Task created' : 'Call Task updated') +
        ' and related to ' +
        (createdEnquiry ? 'a new ' : 'existing ') +
        relatedObject +
        '.';
      respond(isNewTask ? 201 : 200, result);
    } catch (MatchConflictException e) {
      fail(checkpoint, result, 409, 'MATCH_CONFLICT', e.getMessage(), false);
    } catch (RequestException e) {
      fail(checkpoint, result, 400, 'INVALID_REQUEST', e.getMessage(), false);
    } catch (ConfigurationException e) {
      fail(
        checkpoint,
        result,
        400,
        'CONFIGURATION_ERROR',
        e.getMessage(),
        false
      );
    } catch (System.JSONException e) {
      fail(
        checkpoint,
        result,
        400,
        'INVALID_JSON',
        'Check JSON structure, ISO-8601 timestamps and integer durationSeconds.',
        false
      );
    } catch (System.TypeException e) {
      fail(
        checkpoint,
        result,
        400,
        'INVALID_TYPE',
        'Check call/disposition objects and the mapped Salesforce field types.',
        false
      );
    } catch (DmlException e) {
      Boolean locked =
        e.getNumDml() > 0 &&
        e.getDmlStatusCode(0) == 'UNABLE_TO_LOCK_ROW';
      fail(
        checkpoint,
        result,
        locked ? 503 : 400,
        locked ? 'RETRY_LATER' : 'DML_ERROR',
        e.getNumDml() > 0 ? e.getDmlMessage(0) : e.getMessage(),
        locked
      );
    } catch (QueryException e) {
      fail(
        checkpoint,
        result,
        503,
        'QUERY_ERROR',
        'Query failed. Check field names, read permissions and record locks. ' +
        e.getMessage(),
        true
      );
    } catch (Exception e) {
      fail(
        checkpoint,
        result,
        500,
        'INTERNAL_ERROR',
        'Webhook processing failed: ' + e.getMessage(),
        true
      );
    }
  }

  private static void validateCall(CallData c) {
    if (
      c == null ||
      String.isBlank(c.id) ||
      String.isBlank(c.calleePhone) ||
      c.startedAt == null ||
      String.isBlank(c.agentName) ||
      String.isBlank(c.agentNumber)
    ) {
      throw new RequestException(
        'call.id, calleePhone, startedAt, agentName and agentNumber are required.'
      );
    }
    if (
      String.isBlank(c.callType) ||
      (!c.callType.equalsIgnoreCase('Incoming') &&
      !c.callType.equalsIgnoreCase('Outgoing'))
    ) {
      throw new RequestException('call.callType must be Incoming or Outgoing.');
    }
    normalizePhone(c.calleePhone);
    normalizePhone(c.agentNumber);
    if (c.durationSeconds != null && c.durationSeconds < 0) {
      throw new RequestException('durationSeconds cannot be negative.');
    }
  }

  private static Id matchCompany(String phone, List<String> warnings) {
    Set<Id> companies = new Set<Id>();
    for (SObject row : phoneCandidates('Account', 'Mobile__c', phone, false)) {
      if (samePhone(row.get('Mobile__c'), phone))
        companies.add((Id) row.get('Id'));
    }
    for (SObject row : phoneCandidates('Contact', 'MobilePhone', phone, true)) {
      if (!samePhone(row.get('MobilePhone'), phone))
        continue;
      if (row.get('AccountId') != null) {
        companies.add((Id) row.get('AccountId'));
      } else {
        warnings.add(
          'A matching Contact has no Account; Enquiry matching was used instead.'
        );
      }
    }
    if (companies.size() > 1) {
      throw new MatchConflictException(
        'Customer phone matches more than one Company. Resolve the company/ contact phone duplicates.'
      );
    }
    if (companies.isEmpty())
      return null;
    Id accountId = new List<Id>(companies)[0];
    List<SObject> accessible = Database.queryWithBinds(
      'SELECT Id FROM Account WHERE Id = :accountId',
      new Map<String, Object>{ 'accountId' => accountId },
      AccessLevel.USER_MODE
    );
    if (accessible.isEmpty()) {
      throw new ConfigurationException(
        'The integration user cannot access the matched Contact\'s Company.'
      );
    }
    return accountId;
  }

  private static Id matchEnquiry(String phone) {
    Set<Id> enquiries = new Set<Id>();
    for (
      SObject row : phoneCandidates('Enquiry__c', 'Phone__c', phone, false)
    ) {
      if (samePhone(row.get('Phone__c'), phone))
        enquiries.add((Id) row.get('Id'));
    }
    if (enquiries.size() > 1) {
      throw new MatchConflictException(
        'Customer phone matches more than one Enquiry. Resolve the duplicates first.'
      );
    }
    return enquiries.isEmpty() ? null : new List<Id>(enquiries)[0];
  }

  private static List<SObject> phoneCandidates(
    String objectName,
    String fieldName,
    String phone,
    Boolean includeAccount
  ) {
    String normalized = normalizePhone(phone);
    String searchDigits = normalized.length() == 12 &&
      normalized.startsWith('91')
      ? normalized.substring(2)
      : normalized;
    String pattern = '%';
    for (Integer i = 0; i < searchDigits.length(); i++) {
      pattern += searchDigits.substring(i, i + 1) + '%';
    }
    // Names are internal constants. Bounded candidate query tolerates punctuation;
    // full normalized equality below is required before a record can be matched.
    List<SObject> rows = Database.queryWithBinds(
      'SELECT Id, ' +
        fieldName +
        (includeAccount ? ', AccountId' : '') +
        ' FROM ' +
        objectName +
        ' WHERE ' +
        fieldName +
        ' LIKE :pattern LIMIT 501',
      new Map<String, Object>{ 'pattern' => pattern },
      AccessLevel.USER_MODE
    );
    if (rows.size() > CANDIDATE_LIMIT) {
      throw new MatchConflictException(
        'Phone search exceeds 500 candidates on ' +
          objectName +
          '. Configure normalized phone fields before retrying.'
      );
    }
    return rows;
  }

  private static Id createEnquiry(
    String phone,
    String calleeName,
    String agentNumber,
    List<String> warnings
  ) {
    Schema.SObjectType objectType = Schema.getGlobalDescribe()
      .get('Enquiry__c');
    if (objectType == null)
      throw new ConfigurationException('Enquiry__c does not exist.');
    Schema.RecordTypeInfo recordType = objectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get(NEW_ENQUIRY_RECORD_TYPE);
    if (
      recordType == null ||
      !recordType.isActive() ||
      !recordType.isAvailable()
    ) {
      throw new ConfigurationException(
        'New_Customer Enquiry record type must be active and available to the integration user.'
      );
    }
    SObject enquiry = objectType.newSObject();
    enquiry.put('RecordTypeId', recordType.getRecordTypeId());
    putValue(enquiry, 'Phone__c', phone, true, warnings);
    putValue(enquiry, 'First_Name__c', calleeName, true, warnings);
    String teamMember = teamMemberFor(agentNumber);
    try {
      putValue(enquiry, 'Team_Member__c', teamMember, true, warnings);
    } catch (ConfigurationException e) {
      // e.g. the agent's name is not a value of a restricted picklist: keep the call, flag it.
      if (teamMember == NEW_TEAM_MEMBER)
        throw e;
      warnings.add(
        'Team_Member__c could not be set to "' +
          teamMember +
          '" (' +
          e.getMessage() +
          '); "' +
          NEW_TEAM_MEMBER +
          '" was used instead.'
      );
      putValue(enquiry, 'Team_Member__c', NEW_TEAM_MEMBER, true, warnings);
    }
    insert as user enquiry;
    return (Id) enquiry.get('Id');
  }

  @TestVisible
  private static String teamMemberFor(String agentNumber) {
    String teamMember = TEAM_MEMBER_BY_AGENT_MOBILE.get(
      normalizePhone(agentNumber)
    );
    return teamMember == null ? NEW_TEAM_MEMBER : teamMember;
  }

  private static void setRelatedType(
    Task activity,
    Id parentId,
    List<String> warnings
  ) {
    Schema.SObjectField field = Task.SObjectType.getDescribe()
      .fields.getMap()
      .get('Related_To_Type__c');
    if (field == null || field.getDescribe().isCalculated())
      return;
    Boolean isCompany =
      parentId.getSObjectType().getDescribe().getName() == 'Account';
    List<String> candidates = isCompany
      ? new List<String>{ 'Company', 'Companies', 'Account' }
      : new List<String>{ 'Enquiry', 'Inquiry', 'Enquiry__c' };
    Schema.DescribeFieldResult info = field.getDescribe();
    if (info.getType() == Schema.DisplayType.Picklist) {
      for (String candidate : candidates) {
        String choice = picklistValue(info, candidate);
        if (choice != null) {
          putValue(activity, 'Related_To_Type__c', choice, false, warnings);
          return;
        }
      }
      warnings.add(
        'Related_To_Type__c was not set: no matching Company/Enquiry picklist value.'
      );
    } else {
      putValue(activity, 'Related_To_Type__c', candidates[0], false, warnings);
    }
  }

  // Describe-based assignment supports the supplied fields as text, numeric,
  // Date/DateTime or picklist without guessing their undisclosed data types.
  private static void putValue(
    SObject record,
    String fieldName,
    Object value,
    Boolean requiredMapping,
    List<String> warnings
  ) {
    if (value == null)
      return;
    Schema.SObjectField field = record.getSObjectType()
      .getDescribe()
      .fields.getMap()
      .get(fieldName);
    String qualifiedName =
      record.getSObjectType().getDescribe().getName() +
      '.' +
      fieldName;
    if (field == null) {
      if (requiredMapping)
        throw new ConfigurationException('Missing field: ' + qualifiedName);
      warnings.add('Optional field missing: ' + qualifiedName);
      return;
    }
    Schema.DescribeFieldResult info = field.getDescribe();
    Boolean writable = record.get('Id') == null
      ? info.isCreateable()
      : info.isUpdateable();
    if (info.isCalculated() || !writable) {
      if (requiredMapping)
        throw new ConfigurationException(
          'Field must be writable: ' + qualifiedName
        );
      warnings.add(
        'Optional formula/read-only field not written: ' + qualifiedName
      );
      return;
    }
    String kind = String.valueOf(info.getType()).toLowerCase();
    String textValue = value instanceof Datetime
      ? iso((Datetime) value)
      : String.valueOf(value);
    if (kind == 'datetime') {
      if (!(value instanceof Datetime))
        throw new ConfigurationException(
          qualifiedName + ' expects a DateTime.'
        );
      record.put(fieldName, value);
    } else if (kind == 'date') {
      if (!(value instanceof Datetime))
        throw new ConfigurationException(
          qualifiedName + ' expects a date value.'
        );
      record.put(fieldName, ((Datetime) value).dateGmt());
      warnings.add(
        qualifiedName +
        ' is Date-only; only the UTC date is stored. Use a DateTime field to retain time.'
      );
    } else if (kind == 'integer') {
      record.put(fieldName, Integer.valueOf(textValue));
    } else if (kind == 'double' || kind == 'currency' || kind == 'percent') {
      record.put(fieldName, Decimal.valueOf(textValue));
    } else if (kind == 'picklist') {
      String choice = picklistValue(info, textValue);
      if (choice == null && info.isRestrictedPicklist()) {
        throw new ConfigurationException(
          qualifiedName + ' does not accept value: ' + textValue
        );
      }
      record.put(fieldName, choice == null ? textValue : choice);
    } else if (
      new Set<String>{ 'string', 'textarea', 'phone', 'url', 'email' }
        .contains(kind)
    ) {
      if (info.getLength() > 0 && textValue.length() > info.getLength()) {
        throw new ConfigurationException(
          qualifiedName +
            ' is too short. Needed characters: ' +
            textValue.length()
        );
      }
      record.put(fieldName, textValue);
    } else {
      throw new ConfigurationException(
        'Unsupported mapping type for ' + qualifiedName + ': ' + kind
      );
    }
  }

  private static String picklistValue(
    Schema.DescribeFieldResult info,
    String textValue
  ) {
    // API value first, then label. Record-type restrictions still apply at setup/DML.
    for (Schema.PicklistEntry entry : info.getPicklistValues()) {
      if (entry.isActive() && entry.getValue().equalsIgnoreCase(textValue))
        return entry.getValue();
    }
    for (Schema.PicklistEntry entry : info.getPicklistValues()) {
      if (entry.isActive() && entry.getLabel().equalsIgnoreCase(textValue))
        return entry.getValue();
    }
    return null;
  }

  @TestVisible
  private static String normalizePhone(String raw) {
    if (
      String.isBlank(raw) || !Pattern.matches('[+]?[0-9() .-]+', raw.trim())
    ) {
      throw new RequestException(
        'Phone must contain one number without extension text.'
      );
    }
    String phoneDigits = raw.replaceAll('[^0-9]', '');
    Boolean international =
      raw.trim().startsWith('+') || phoneDigits.startsWith('00');
    if (phoneDigits.startsWith('00'))
      phoneDigits = phoneDigits.substring(2);
    if (
      !international &&
      phoneDigits.length() == 11 &&
      phoneDigits.startsWith('0')
    )
      phoneDigits = phoneDigits.substring(1);
    if (!international && phoneDigits.length() == 10)
      phoneDigits = '91' + phoneDigits;
    if (phoneDigits.length() < 7 || phoneDigits.length() > 15) {
      throw new RequestException(
        'Phone must contain 7 to 15 digits after normalization.'
      );
    }
    return phoneDigits;
  }

  private static Boolean samePhone(Object storedValue, String incomingPhone) {
    if (storedValue == null)
      return false;
    try {
      return normalizePhone(String.valueOf(storedValue)) ==
        normalizePhone(incomingPhone);
    } catch (RequestException e) {
      return false;
    }
  }
  private static String firstNonblank(String first, String second) {
    return String.isBlank(first) ? second : first;
  }
  private static String stringValue(Object value) {
    return value == null ? null : String.valueOf(value);
  }
  private static String printable(Object value) {
    if (value == null)
      return '';
    return value instanceof Datetime
      ? iso((Datetime) value)
      : String.valueOf(value);
  }
  private static String iso(Datetime value) {
    return value.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'');
  }
  private static String clip(String value, Integer maxLength) {
    return value.length() > maxLength ? value.substring(0, maxLength) : value;
  }
  private static void fail(
    Savepoint checkpoint,
    WebhookResponse result,
    Integer status,
    String code,
    String message,
    Boolean retryable
  ) {
    if (checkpoint != null)
      Database.rollback(checkpoint);
    // Rolled back: no record ids from this request are valid any more.
    result.code = code;
    result.action = 'failed';
    result.message = message;
    result.retryable = retryable;
    result.taskId = null;
    result.relatedRecordId = null;
    result.relatedObject = null;
    result.createdEnquiry = false;
    respond(status, result);
  }
  private static void respond(Integer status, WebhookResponse result) {
    result.statusCode = status;
    result.success = status < 400;
    if (result.retryable == null)
      result.retryable = false;
    if (result.createdEnquiry == null)
      result.createdEnquiry = false;
    result.requestId = Request.getCurrent().getRequestId();
    result.processedAt = iso(Datetime.now());
    if (RestContext.response == null)
      RestContext.response = new RestResponse();
    RestContext.response.statusCode = status;
    RestContext.response.addHeader('Content-Type', 'application/json');
    RestContext.response.responseBody = Blob.valueOf(JSON.serialize(result));
  }
}
