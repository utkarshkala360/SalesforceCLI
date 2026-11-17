@RestResource(urlMapping='/CallAnchorWebhook/*')
global with sharing class CallAnchorWebhookService {
  // Opportunity is checked first, then Lead. When neither matches, a new Lead is
  // created only if CREATE_LEAD_WHEN_NOT_FOUND is on; otherwise the call is skipped (200).
  private static final String OPPORTUNITY_OBJECT = 'Opportunity';
  private static final List<String> OPPORTUNITY_PHONE_FIELDS = new List<String>{
    'Fathers_Contact_No__c',
    'Mothers_Contact_No__c'
  };

  private static final String LEAD_OBJECT = 'Lead';
  private static final List<String> LEAD_PHONE_FIELDS = new List<String>{
    'Fathers_Contact_No__c',
    'Mothers_Contact_No__c'
  };
  private static final String LEAD_FILTER = 'IsConverted = false';

  // Flip to true to create a new Lead when no Opportunity or Lead matches the caller.
  @TestVisible
  private static Boolean CREATE_LEAD_WHEN_NOT_FOUND = false;

  // The caller is always recorded as the father on a new Lead.
  private static final Map<String, String> NEW_LEAD_FIELDS = new Map<String, String>{
    'LastName' => 'calc.calleeName',
    'Company' => 'calc.calleeName',
    'Father_Name__c' => 'calc.calleeName',
    'Fathers_Contact_No__c' => 'calc.leadPhone',
    'Location__c' => 'calc.leadLocation',
    'Lead_Source_Primary_new1__c' => 'calc.leadSource'
  };

  // Lead validation rules require contact numbers in +91XXXXXXXXXX format.
  private static final String LEAD_PHONE_PREFIX = '+91';
  private static final String LEAD_LOCATION = 'NA';
  private static final String LEAD_SOURCE = '360 CallAnchor';

  private static final String ACTIVITY_OBJECT = 'Task';

  private static final Map<String, String> ACTIVITY_FIELDS = new Map<String, String>{
    'Subject' => 'calc.subject',
    'Status' => 'calc.status',
    'ActivityDate' => 'calc.activityDate',
    'Call_Anchor_Call_Id__c' => 'call.id',
    'Call_Anchor_Call_Type__c' => 'call.callType',
    'Call_Anchor_Call_Started_At__c' => 'call.startedAt',
    'Call_Anchor_Duration_Seconds__c' => 'call.durationSeconds',
    'Call_Anchor_Agent_Name__c' => 'call.agentName',
    'Call_Anchor_Agent_Mobile__c' => 'call.agentNumber',
    'Call_Anchor_Recording_Url__c' => 'call.recordingUrl',
    'Call_Anchor_Disposition__c' => 'disposition.fields.outcome',
    'Call_Anchor_Disposition_Note__c' => 'call.dispositionNote',
    'Call_Anchor_Callback_Scheduled_At__c' => 'call.dispositionScheduledAt',
    'Description' => 'calc.rawPayload'
  };

  // Open follow-up Task created when the disposition schedules a callback.
  // Its due date and reminder match Call_Anchor_Callback_Scheduled_At__c.
  private static final Map<String, String> FOLLOW_UP_FIELDS = new Map<String, String>{
    'Subject' => 'calc.followUpSubject',
    'Status' => 'calc.followUpStatus',
    'ActivityDate' => 'call.dispositionScheduledAt',
    'Description' => 'call.dispositionNote',
    'Call_Anchor_Call_Id__c' => 'call.id',
    'Call_Anchor_Call_Type__c' => 'call.callType',
    'Call_Anchor_Agent_Name__c' => 'call.agentName',
    'Call_Anchor_Agent_Mobile__c' => 'call.agentNumber',
    'Call_Anchor_Disposition__c' => 'disposition.fields.outcome',
    'Call_Anchor_Disposition_Note__c' => 'call.dispositionNote',
    'Call_Anchor_Callback_Scheduled_At__c' => 'call.dispositionScheduledAt'
  };

  // Used when the org has an open Task status with this name; otherwise the default open status.
  private static final String OPEN_STATUS = 'Open';

  private static final Integer RAW_PAYLOAD_MAX = 32000;

  @HttpPost
  global static void doPost() {
    try {
      Map<String, Object> values = readPayload();
      Map<String, Object> result = logCall(values);
      // Nothing is created when no record matches, so that case is 200 rather than 201.
      send(result.containsKey('activityId') ? 201 : 200, result);
    } catch (CallException e) {
      send(e.status, errorBody(e.code, e.getMessage()));
    } catch (DmlException e) {
      send(422, errorBody('SAVE_FAILED', e.getDmlMessage(0)));
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        e.getMessage() + '\n' + e.getStackTraceString()
      );
      send(500, errorBody('UNEXPECTED_ERROR', e.getMessage()));
    }
  }

  private static Map<String, Object> readPayload() {
    Blob body = RestContext.request.requestBody;
    if (body == null || body.size() == 0) {
      throw fail(400, 'EMPTY_BODY', 'Request body is empty.');
    }

    Map<String, Object> root;
    Map<String, Object> call;
    try {
      root = (Map<String, Object>) JSON.deserializeUntyped(body.toString());
      call = (Map<String, Object>) root.get('call');
    } catch (Exception e) {
      throw fail(400, 'INVALID_JSON', 'Request body is not valid JSON.');
    }
    if (call == null) {
      throw fail(400, 'MISSING_CALL', '"call" is required.');
    }

    String phone = cleanPhone(text(call.get('calleePhone')));
    if (phone == null) {
      throw fail(
        400,
        'INVALID_PHONE',
        'call.calleePhone is missing or not a valid 10-digit number.'
      );
    }

    String callType = text(call.get('callType'));
    Datetime startedAt = toDatetime(call.get('startedAt'), 'call.startedAt');

    String calleeName = text(call.get('calleeName'));
    Datetime scheduledAt = toDatetime(
      call.get('dispositionScheduledAt'),
      'call.dispositionScheduledAt'
    );

    root.put(
      'calc',
      new Map<String, Object>{
        'subject' => String.isBlank(callType)
          ? 'Call Log'
          : 'Call - ' + callType,
        'status' => 'Completed',
        'activityDate' => startedAt != null ? startedAt.date() : Date.today(),
        'phone' => phone,
        'leadPhone' => LEAD_PHONE_PREFIX + phone,
        'leadLocation' => LEAD_LOCATION,
        'leadSource' => LEAD_SOURCE,
        'calleeName' => String.isBlank(calleeName) ? phone : calleeName.trim(),
        'scheduledAt' => scheduledAt,
        'followUpSubject' => 'Follow Up Call - ' +
        (String.isBlank(calleeName) ? phone : calleeName.trim()),
        'rawPayload' => body.toString().left(RAW_PAYLOAD_MAX)
      }
    );
    return root;
  }

  private static Map<String, Object> logCall(Map<String, Object> values) {
    Savepoint sp = Database.setSavepoint();
    try {
      Id recordId = findOrCreateRecord(values);
      if (recordId == null) {
        return new Map<String, Object>{
          'success' => true,
          'message' => 'No Lead found for phone ' +
          valueAt(values, 'calc.phone') +
          '; call not logged.'
        };
      }

      SObject activity = createActivity(
        ACTIVITY_OBJECT,
        recordId,
        ACTIVITY_FIELDS,
        values
      );

      SObject followUp = createFollowUp(recordId, values);

      return new Map<String, Object>{
        'success' => true,
        'activityId' => activity.Id,
        'followUpId' => followUp == null ? null : followUp.Id,
        'recordId' => recordId
      };
    } catch (Exception e) {
      Database.rollback(sp);
      throw e;
    }
  }

  private static Id findOrCreateRecord(Map<String, Object> values) {
    String phone = (String) valueAt(values, 'calc.phone');

    List<SObject> opportunities = findByPhone(
      OPPORTUNITY_OBJECT,
      OPPORTUNITY_PHONE_FIELDS,
      phone
    );
    if (!opportunities.isEmpty()) {
      return opportunities[0].Id;
    }

    List<SObject> leads = findByPhone(
      LEAD_OBJECT,
      LEAD_PHONE_FIELDS,
      phone,
      LEAD_FILTER
    );
    if (!leads.isEmpty()) {
      return leads[0].Id;
    }

    if (!CREATE_LEAD_WHEN_NOT_FOUND) {
      return null;
    }
    return createRecord(LEAD_OBJECT, NEW_LEAD_FIELDS, values).Id;
  }

  public static List<SObject> findByPhone(
    String objectName,
    List<String> phoneFields,
    String phone
  ) {
    return findByPhone(objectName, phoneFields, phone, null);
  }

  public static List<SObject> findByPhone(
    String objectName,
    List<String> phoneFields,
    String phone,
    String filter
  ) {
    List<String> conditions = new List<String>();
    for (String field : phoneFields) {
      conditions.add(field + ' LIKE :phoneLike');
    }
    String whereClause = '(' + String.join(conditions, ' OR ') + ')';
    if (String.isNotBlank(filter)) {
      whereClause += ' AND (' + filter + ')';
    }

    String query =
      'SELECT Id FROM ' +
      objectName +
      ' WHERE ' +
      whereClause +
      ' ORDER BY LastModifiedDate DESC LIMIT 10';

    return Database.queryWithBinds(
      query,
      new Map<String, Object>{ 'phoneLike' => '%' + phone + '%' },
      AccessLevel.USER_MODE
    );
  }

  public static SObject createRecord(
    String objectName,
    Map<String, String> fieldMap,
    Map<String, Object> values
  ) {
    SObject record = buildRecord(objectName, fieldMap, values);
    insert as user record;
    return record;
  }

  public static SObject createActivity(
    String activityObject,
    Id recordId,
    Map<String, String> fieldMap,
    Map<String, Object> values
  ) {
    SObject activity = buildRecord(activityObject, fieldMap, values);
    activity.put(linkField(activityObject, recordId), recordId);
    insert as user activity;
    return activity;
  }

  // Creates an open follow-up Task when the disposition scheduled a callback.
  // The reminder is only set when the callback time is still in the future.
  private static SObject createFollowUp(
    Id recordId,
    Map<String, Object> values
  ) {
    Datetime scheduledAt = (Datetime) valueAt(values, 'calc.scheduledAt');
    if (scheduledAt == null) {
      return null;
    }
    ((Map<String, Object>) values.get('calc'))
      .put('followUpStatus', openStatus());

    Task followUp = (Task) buildRecord(
      ACTIVITY_OBJECT,
      FOLLOW_UP_FIELDS,
      values
    );
    followUp.put(linkField(ACTIVITY_OBJECT, recordId), recordId);
    followUp.IsReminderSet = scheduledAt > Datetime.now();
    followUp.ReminderDateTime = followUp.IsReminderSet ? scheduledAt : null;
    insert as user followUp;
    return followUp;
  }

  // "Open" if present, otherwise the org's default open status, otherwise the first open one.
  private static String openStatus() {
    List<TaskStatus> statuses = [
      SELECT ApiName, MasterLabel, IsDefault
      FROM TaskStatus
      WHERE IsClosed = FALSE
      ORDER BY SortOrder
    ];
    if (statuses.isEmpty()) {
      throw fail(500, 'CONFIG_ERROR', 'No open Task status is configured.');
    }
    TaskStatus defaultStatus;
    for (TaskStatus option : statuses) {
      if (
        option.ApiName.equalsIgnoreCase(OPEN_STATUS) ||
        option.MasterLabel.equalsIgnoreCase(OPEN_STATUS)
      ) {
        return option.ApiName;
      }
      if (option.IsDefault && defaultStatus == null) {
        defaultStatus = option;
      }
    }
    return (defaultStatus == null ? statuses[0] : defaultStatus).ApiName;
  }

  public static String cleanPhone(String phone) {
    if (String.isBlank(phone)) {
      return null;
    }
    String digits = phone.replaceAll('[^0-9]', '');

    if (digits.length() < 10 || digits.length() > 14) {
      return null;
    }
    return digits.right(10);
  }

  public static Object valueAt(Map<String, Object> data, String path) {
    Object current = data;
    for (String key : path.split('\\.')) {
      if (!(current instanceof Map<String, Object>)) {
        return null;
      }
      current = ((Map<String, Object>) current).get(key);
    }
    return current;
  }

  private static SObject buildRecord(
    String objectName,
    Map<String, String> fieldMap,
    Map<String, Object> values
  ) {
    Schema.SObjectType objectType = Schema.getGlobalDescribe().get(objectName);
    Map<String, Schema.SObjectField> objectFields = objectType.getDescribe()
      .fields.getMap();
    SObject record = objectType.newSObject();

    for (String field : fieldMap.keySet()) {
      Object value = valueAt(values, fieldMap.get(field));
      if (value == null || String.isBlank(String.valueOf(value))) {
        continue;
      }
      if (!objectFields.containsKey(field)) {
        throw fail(
          500,
          'CONFIG_ERROR',
          objectName + '.' + field + ' does not exist.'
        );
      }
      Schema.DisplayType fieldType = objectFields.get(field)
        .getDescribe()
        .getType();
      record.put(field, convert(value, fieldType, fieldMap.get(field)));
    }
    return record;
  }

  private static Object convert(
    Object value,
    Schema.DisplayType fieldType,
    String key
  ) {
    String textValue = String.valueOf(value).trim();
    Object result = textValue;
    try {
      switch on fieldType {
        when DATE {
          result = (value instanceof Date)
            ? value
            : toDatetime(textValue, key).date();
        }
        when DATETIME {
          result = toDatetime(textValue, key);
        }
        when INTEGER {
          result = Decimal.valueOf(textValue).intValue();
        }
        when DOUBLE, CURRENCY, PERCENT {
          result = Decimal.valueOf(textValue);
        }
        when BOOLEAN {
          result = Boolean.valueOf(textValue);
        }
        when REFERENCE, ID {
          result = value;
        }
      }
    } catch (CallException e) {
      throw e;
    } catch (Exception e) {
      throw fail(
        400,
        'INVALID_VALUE',
        '"' + textValue + '" (' + key + ') is not a valid ' + fieldType + '.'
      );
    }
    return result;
  }

  private static String linkField(String activityObject, Id recordId) {
    Schema.SObjectType recordType = recordId.getSObjectType();

    if (activityObject == 'Task' || activityObject == 'Event') {
      return (recordType == Lead.SObjectType ||
        recordType == Contact.SObjectType)
        ? 'WhoId'
        : 'WhatId';
    }
    for (
      Schema.SObjectField field : Schema.getGlobalDescribe()
        .get(activityObject)
        .getDescribe()
        .fields.getMap()
        .values()
    ) {
      if (field.getDescribe().getReferenceTo().contains(recordType)) {
        return field.getDescribe().getName();
      }
    }
    throw fail(
      500,
      'CONFIG_ERROR',
      activityObject + ' has no lookup to ' + recordType + '.'
    );
  }

  public class CallException extends Exception {
    public Integer status;
    public String code;
  }

  private static CallException fail(
    Integer status,
    String code,
    String message
  ) {
    CallException e = new CallException(message);
    e.status = status;
    e.code = code;
    return e;
  }

  private static Map<String, Object> errorBody(String code, String message) {
    return new Map<String, Object>{
      'success' => false,
      'error' => new Map<String, Object>{ 'code' => code, 'message' => message }
    };
  }

  private static void send(Integer status, Map<String, Object> body) {
    RestResponse res = RestContext.response;
    res.statusCode = status;
    res.addHeader('Content-Type', 'application/json');
    res.responseBody = Blob.valueOf(JSON.serialize(body));
  }

  private static String text(Object value) {
    return value == null ? null : String.valueOf(value);
  }

  private static Datetime toDatetime(Object value, String fieldName) {
    if (value == null || String.isBlank(String.valueOf(value))) {
      return null;
    }
    try {
      return (Datetime) JSON.deserialize('"' + value + '"', Datetime.class);
    } catch (Exception e) {
      throw fail(
        400,
        'INVALID_DATE',
        fieldName + ' must be an ISO-8601 date/time.'
      );
    }
  }
}
