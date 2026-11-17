@RestResource(urlMapping='/CallAnchorWebhook/*')
global with sharing class CallAnchorWebhookService {
  // Owner of every Lead and Task the webhook creates (Shalu). The agent is recorded in the Call Anchor agent fields.
  private static final Id OWNER_ID = '005dM00000arNkvQAE';

  // Searched in order; the first object with a phone match wins.
  private static final List<Lookup> LOOKUPS = new List<Lookup>{
    new Lookup(
      'Contact',
      new List<String>{
        'Phone',
        'MobilePhone',
        'AssistantPhone',
        'HomePhone',
        'OtherPhone'
      },
      null
    ),
    new Lookup(
      'Lead',
      new List<String>{ 'Phone', 'MobilePhone' },
      'IsConverted = false'
    )
  };

  private static final String NEW_RECORD_OBJECT = 'Lead';

  private static final Map<String, String> NEW_RECORD_FIELDS = new Map<String, String>{
    'LastName' => 'calc.calleeName',
    'Company' => 'calc.calleeName',
    'MobilePhone' => 'calc.phone',
    'OwnerId' => 'calc.ownerId'
  };

  private static final String ACTIVITY_OBJECT = 'Task';

  // The call log is record type Call (Call Layout), the follow-up record type Task (Task Layout).
  // Both are set explicitly: left blank, a Task takes the user's default record type, which can be Call.
  private static final String CALL_RECORD_TYPE = 'Call';
  private static final String FOLLOW_UP_RECORD_TYPE = 'Task';
  private static final String CALL_SUBTYPE = 'Call';

  private static final Map<String, String> ACTIVITY_FIELDS = new Map<String, String>{
    'Subject' => 'calc.subject',
    'Status' => 'calc.status',
    'RecordTypeId' => 'calc.callRecordTypeId',
    'TaskSubtype' => 'calc.callSubtype',
    'OwnerId' => 'calc.ownerId',
    'ActivityDate' => 'calc.activityDate',
    'Call_Anchor_Call_Id__c' => 'call.id',
    'Call_Anchor_Call_Type__c' => 'call.callType',
    'Call_Anchor_Call_Started_At__c' => 'call.startedAt',
    'Call_Anchor_Duration_Seconds__c' => 'call.durationSeconds',
    'Call_Anchor_Agent_Name__c' => 'calc.agentName',
    'Call_Anchor_Agent_Mobile__c' => 'call.agentNumber',
    'Call_Anchor_Recording_Url__c' => 'call.recordingUrl',
    'Call_Anchor_Disposition__c' => 'disposition.fields.outcome',
    'Call_Anchor_Disposition_Note__c' => 'call.dispositionNote',
    'Call_Anchor_Callback_Scheduled_At__c' => 'call.dispositionScheduledAt',
    'Description' => 'calc.rawPayload'
  };

  // Created only when the call has a callback scheduled (call.dispositionScheduledAt).
  private static final Map<String, String> FOLLOW_UP_FIELDS = new Map<String, String>{
    'Subject' => 'calc.followUpSubject',
    'Status' => 'calc.followUpStatus',
    'RecordTypeId' => 'calc.followUpRecordTypeId',
    'OwnerId' => 'calc.ownerId',
    'ActivityDate' => 'calc.followUpDate',
    'IsReminderSet' => 'calc.followUpReminderSet',
    'ReminderDateTime' => 'call.dispositionScheduledAt',
    'Call_Anchor_Agent_Name__c' => 'calc.agentName',
    'Call_Anchor_Agent_Mobile__c' => 'call.agentNumber',
    'Call_Anchor_Disposition__c' => 'disposition.fields.outcome',
    'Call_Anchor_Disposition_Note__c' => 'call.dispositionNote'
  };

  private static final Integer RAW_PAYLOAD_MAX = 32000;

  @HttpPost
  global static void doPost() {
    try {
      Map<String, Object> values = readPayload();
      logCall(values);
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
    Map<String, Object> disposition;
    Map<String, Object> fields;
    try {
      root = (Map<String, Object>) JSON.deserializeUntyped(body.toString());
      call = (Map<String, Object>) root.get('call');
      disposition = (Map<String, Object>) root.get('disposition');
      fields = (disposition == null)
        ? null
        : (Map<String, Object>) disposition.get('fields');
    } catch (Exception e) {
      throw fail(400, 'INVALID_JSON', 'Request body is not valid JSON.');
    }
    if (call == null) {
      throw fail(400, 'MISSING_CALL', '"call" is required.');
    }
    if (fields == null)
      fields = new Map<String, Object>();

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
    Datetime callbackAt = toDatetime(
      call.get('dispositionScheduledAt'),
      'call.dispositionScheduledAt'
    );

    String calleeName = text(call.get('calleeName'));
    calleeName = String.isBlank(calleeName) ? phone : calleeName.trim();

    String selectedAgent = text(fields.get('select-calling-agent'));
    if (String.isBlank(selectedAgent))
      selectedAgent = text(call.get('agentName'));

    root.put(
      'calc',
      new Map<String, Object>{
        'subject' => String.isBlank(callType)
          ? 'Call Log'
          : 'Call - ' + callType,
        'status' => 'Completed',
        'callRecordTypeId' => taskRecordTypeId(CALL_RECORD_TYPE),
        'callSubtype' => CALL_SUBTYPE,
        'activityDate' => startedAt != null ? startedAt.date() : Date.today(),
        'phone' => phone,
        'calleeName' => calleeName,
        'agentName' => String.isBlank(selectedAgent)
          ? null
          : selectedAgent.trim(),
        'ownerId' => OWNER_ID,
        'rawPayload' => body.toString().left(RAW_PAYLOAD_MAX),
        'followUpSubject' => 'Follow-up - ' + calleeName,
        'followUpStatus' => 'Not Started',
        'followUpRecordTypeId' => taskRecordTypeId(FOLLOW_UP_RECORD_TYPE),
        'followUpDate' => callbackAt != null ? callbackAt.date() : null,
        'followUpReminderSet' => callbackAt != null
      }
    );
    return root;
  }

  private static void logCall(Map<String, Object> values) {
    Savepoint sp = Database.setSavepoint();
    try {
      List<String> log = new List<String>();

      Id recordId = findRecord((String) valueAt(values, 'calc.phone'));
      if (recordId == null) {
        recordId = createRecord(NEW_RECORD_OBJECT, NEW_RECORD_FIELDS, values)
          .Id;
        log.add('Created ' + NEW_RECORD_OBJECT + ' ' + recordId);
      } else {
        log.add('Matched ' + recordId.getSObjectType() + ' ' + recordId);
      }

      SObject callActivity = createActivity(
        ACTIVITY_OBJECT,
        recordId,
        ACTIVITY_FIELDS,
        values
      );
      log.add('Created call ' + callActivity.Id);

      SObject followUp = null;
      if (valueAt(values, 'calc.followUpDate') == null) {
        log.add('No callback scheduled; no follow-up task created');
      } else {
        followUp = createActivity(
          ACTIVITY_OBJECT,
          recordId,
          FOLLOW_UP_FIELDS,
          values
        );
        log.add('Created follow-up task ' + followUp.Id);
      }

      sendSuccess(
        callActivity.Id,
        log,
        new Map<String, Object>{
          'callActivityId' => callActivity.Id,
          'followUpTaskId' => (followUp == null) ? null : followUp.Id,
          'recordId' => recordId
        }
      );
    } catch (Exception e) {
      Database.rollback(sp);
      throw e;
    }
  }

  private static Id taskRecordTypeId(String developerName) {
    Schema.RecordTypeInfo info = Schema.SObjectType.Task.getRecordTypeInfosByDeveloperName()
      .get(developerName);
    if (info == null || !info.isActive()) {
      throw fail(
        500,
        'CONFIG_ERROR',
        'Task record type ' + developerName + ' is missing or inactive.'
      );
    }
    return info.getRecordTypeId();
  }

  private static Id findRecord(String phone) {
    for (Lookup lookup : LOOKUPS) {
      List<SObject> records = findByPhone(
        lookup.objectName,
        lookup.phoneFields,
        phone,
        lookup.filter
      );
      if (!records.isEmpty()) {
        return records[0].Id;
      }
    }
    return null;
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

  private class Lookup {
    String objectName;
    List<String> phoneFields;
    String filter;
    Lookup(String objectName, List<String> phoneFields, String filter) {
      this.objectName = objectName;
      this.phoneFields = phoneFields;
      this.filter = filter;
    }
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

  // JSON.serialize does not keep Map key order, so the success body is written key by key.
  private static final List<String> RECORD_KEY_ORDER = new List<String>{
    'callActivityId',
    'followUpTaskId',
    'recordId'
  };

  private static void sendSuccess(
    Id id,
    List<String> log,
    Map<String, Object> records
  ) {
    JSONGenerator gen = JSON.createGenerator(false);
    gen.writeStartObject();
    gen.writeObjectField('id', id);
    gen.writeObjectField('log', log);
    gen.writeFieldName('records');
    gen.writeStartObject();
    for (String key : RECORD_KEY_ORDER) {
      Object value = records.get(key);
      if (value == null) {
        gen.writeNullField(key);
      } else {
        gen.writeObjectField(key, value);
      }
    }
    gen.writeEndObject();
    gen.writeBooleanField('success', true);
    gen.writeEndObject();
    writeResponse(201, gen.getAsString());
  }

  private static void send(Integer status, Map<String, Object> body) {
    writeResponse(status, JSON.serialize(body));
  }

  private static void writeResponse(Integer status, String json) {
    RestResponse res = RestContext.response;
    res.statusCode = status;
    res.addHeader('Content-Type', 'application/json');
    res.responseBody = Blob.valueOf(json);
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
