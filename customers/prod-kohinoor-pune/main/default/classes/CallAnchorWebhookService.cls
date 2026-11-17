@RestResource(urlMapping='/CallAnchorWebhook/*')
global with sharing class CallAnchorWebhookService {
  // The agent is the active User whose CallAnchor_Phone__c matches call.agentNumber
  // (10 digits). The agent owns the call Task and the Sales Task.
  private static final String AGENT_PHONE_KEY = 'call.agentNumber';

  // The caller's latest Opportunity (by CreatedDate) owned by the agent gets the call.
  // When the disposition carries a project, only Opportunities whose Project Enquired
  // matches it count. Referral and channel partner numbers are left out: they belong to
  // other people.
  private static final List<String> OPPORTUNITY_PHONE_FIELDS = new List<String>{
    'Mobile_Number__c',
    'Ud_Secondary_Mobile_Number__c',
    'Ud_Local_Contact_Mobile_Number__c'
  };
  // Call Anchor sends the project as a slug of Ud_Project__c.Name ("KOHINOOR VIVA PIXEL-
  // PHASE I" -> "kohinoor-viva-pixel-phase-i"), so projects are matched on the slug of
  // their name. Names that slug alike ("B-ZONE - BANER", "B-ZONE -- BANER") all count.
  private static final String PROJECT_FIELD = 'Ud_Project_Enquired__c';
  private static final String PROJECT_NAME_KEY = 'disposition.fields.project-name';

  // Sales record type: the Presales and CP Task record types carry validation rules
  // and the CP email flow (Task_Activity_Notification_to_CP).
  private static final String ACTIVITY_OBJECT = 'Task';
  private static final String ACTIVITY_RECORD_TYPE = 'Ud_Sales';

  private static final Map<String, String> ACTIVITY_FIELDS = new Map<String, String>{
    'RecordTypeId' => 'calc.activityRecordTypeId',
    'Subject' => 'calc.subject',
    'Status' => 'calc.status',
    'OwnerId' => 'calc.ownerId',
    'ActivityDate' => 'calc.activityDate',
    'Call_Anchor_Call_Id__c' => 'call.id',
    'Call_Anchor_Call_Type__c' => 'call.callType',
    'Call_Anchor_Call_Started_At__c' => 'call.startedAt',
    'Call_Anchor_Duration_Seconds__c' => 'call.durationSeconds',
    'Call_Anchor_Agent_Name__c' => 'call.agentName',
    'Call_Anchor_Agent_Mobile__c' => 'call.agentNumber',
    'Call_Anchor_Recording_Url__c' => 'call.recordingUrl',
    'Call_Anchor_Disposition__c' => 'disposition.fields.task-subject',
    'CallDisposition' => 'disposition.fields.next-action-status',
    'Call_Anchor_Disposition_Note__c' => 'calc.dispositionNote',
    'Call_Anchor_Callback_Scheduled_At__c' => 'calc.scheduledAt',
    'Description' => 'calc.rawPayload'
  };

  // Completed Sales Task for the call itself, created for every call type in TASK_SUBJECTS.
  // Its record type matches the Opportunity's (Commercial / Residential). The webhook never
  // creates the Open follow-up: SalesTaskTrigger creates it from Next_Action_Status__c,
  // Next_Action_Date__c and Next_Action_time__c, so setting those here is what schedules it.
  private static final String SALES_TASK_OBJECT = 'Sales_Task__c';

  // "No action needed": the call needs no follow-up, so the Sales Task is dated at the
  // scheduled-at (creation time when absent) and carries no next action. Any other value,
  // or none, dates it at creation time and puts the scheduled-at in the next action.
  private static final String NEXT_ACTION_KEY = 'disposition.fields.next-action-status';
  private static final String NO_ACTION_NEEDED = 'No action needed';

  private static final Map<String, String> SALES_TASK_FIELDS = new Map<String, String>{
    'RecordTypeId' => 'calc.salesTaskRecordTypeId',
    'OwnerId' => 'calc.ownerId',
    'Opportunity__c' => 'calc.opportunityId',
    'Task_Date__c' => 'calc.taskDate',
    'Task_Time__c' => 'calc.taskTime',
    'Next_Action_Date__c' => 'calc.nextActionDate',
    'Next_Action_time__c' => 'calc.nextActionTime',
    'Task_Subject__c' => 'calc.taskSubject',
    'Communication_Type__c' => 'calc.communicationType',
    'Task_Status__c' => 'calc.taskStatus',
    'Comments__c' => 'calc.comments',
    'Call_Anchor_Comments_Detailed__c' => 'calc.commentsDetailed',
    'Call_Meeting_Status__c' => 'disposition.fields.call-meeting-status',
    'Priority__c' => 'disposition.fields.priority',
    'Next_Action_Status__c' => NEXT_ACTION_KEY,
    'Call_Anchor_Call_Id__c' => 'call.id',
    'Call_Anchor_Call_Type__c' => 'call.callType',
    'Call_Anchor_Call_Started_At__c' => 'call.startedAt',
    'Call_Anchor_Duration_Seconds__c' => 'call.durationSeconds',
    'Call_Anchor_Agent_Name__c' => 'call.agentName',
    'Call_Anchor_Agent_Mobile__c' => 'call.agentNumber',
    'Call_Anchor_Recording_Url__c' => 'call.recordingUrl',
    'Call_Anchor_Disposition__c' => 'disposition.fields.task-subject',
    'Call_Anchor_Disposition_Note__c' => 'calc.dispositionNote',
    'Call_Anchor_Callback_Scheduled_At__c' => 'calc.scheduledAt',
    'Call_Anchor_Raw_Payload__c' => 'calc.rawPayload'
  };

  private static final String SALES_TASK_STATUS = 'Completed';

  // Call Anchor sends disposition picklists as slugs ("follow-up"); these map them to
  // the Sales Task picklist values, keyed by webhook path. A value not listed is used as is.
  private static final String TASK_SUBJECT_KEY = 'disposition.fields.task-subject';

  private static final Map<String, String> ACTION_VALUES = new Map<String, String>{
    'no-action-needed' => 'No action needed',
    'virtual-meeting' => 'Virtual Meeting',
    'follow-up' => 'Follow Up',
    'outbound-call' => 'Outbound Call',
    'inbound-call' => 'Inbound Call'
  };

  private static final Map<String, Map<String, String>> VALUE_MAPS = new Map<String, Map<String, String>>{
    TASK_SUBJECT_KEY => ACTION_VALUES,
    'disposition.fields.call-meeting-status' => new Map<String, String>{
      'connected' => 'Connected',
      'not-connected' => 'Not Connected',
      'completed' => 'Completed',
      'rescheduled' => 'Rescheduled',
      'cancelled' => 'Cancelled'
    },
    'disposition.fields.priority' => new Map<String, String>{
      'low' => 'Low',
      'medium' => 'Medium',
      'high' => 'High'
    },
    NEXT_ACTION_KEY => ACTION_VALUES
  };

  // Call Anchor call type -> Communication_Type__c, and Task_Subject__c when the
  // disposition has no task-subject (note "Inbound call" in Communication_Type__c).
  // Missed calls count as inbound, rejected calls as outbound.
  private static final Map<String, String> TASK_SUBJECTS = new Map<String, String>{
    'incoming' => 'Inbound Call',
    'missed' => 'Inbound Call',
    'outgoing' => 'Outbound Call',
    'rejected' => 'Outbound Call'
  };
  private static final Map<String, String> COMMUNICATION_TYPES = new Map<String, String>{
    'incoming' => 'Inbound call',
    'missed' => 'Inbound call',
    'outgoing' => 'Outbound Call',
    'rejected' => 'Outbound Call'
  };

  // Comments__c and Call_Anchor_Disposition_Note__c are 255-character text areas: a longer
  // note is cut to fit and ends in COMMENTS_ELLIPSIS. The full text stays in
  // Call_Anchor_Comments_Detailed__c and the raw payload.
  private static final String NOTE_KEY = 'disposition.fields.note';
  private static final Integer COMMENTS_MAX = 255;
  private static final String COMMENTS_ELLIPSIS = '......';

  // Sales Task dates and times are the sales team's local date and time. The scheduled-at
  // is the disposition's scheduled-at (call.dispositionScheduledAt when it is absent).
  // A date/time without a zone is taken as TIME_ZONE.
  private static final String SCHEDULED_AT_KEY = 'disposition.fields.scheduled-at';
  private static final String SCHEDULED_AT_FALLBACK_KEY = 'call.dispositionScheduledAt';
  private static final String TIME_ZONE = 'Asia/Kolkata';

  private static final Integer RAW_PAYLOAD_MAX = 32000;

  @HttpPost
  global static void doPost() {
    try {
      Map<String, Object> values = readPayload();
      Map<String, Object> result = logCall(values);
      send(201, result);
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

    String agentPhone = cleanPhone(text(valueAt(root, AGENT_PHONE_KEY)));
    if (agentPhone == null) {
      throw fail(
        400,
        'INVALID_AGENT_PHONE',
        AGENT_PHONE_KEY + ' is missing or not a valid 10-digit number.'
      );
    }
    Id agentId = findAgent(agentPhone);

    String callType = text(call.get('callType'));
    String direction = String.isBlank(callType)
      ? null
      : callType.trim().toLowerCase();
    Datetime startedAt = toDatetime(call.get('startedAt'), 'call.startedAt');

    Boolean createSalesTask = TASK_SUBJECTS.containsKey(direction);
    Object scheduledValue = valueAt(root, SCHEDULED_AT_KEY);
    String scheduledKey = SCHEDULED_AT_KEY;
    if (
      scheduledValue == null || String.isBlank(String.valueOf(scheduledValue))
    ) {
      scheduledValue = valueAt(root, SCHEDULED_AT_FALLBACK_KEY);
      scheduledKey = SCHEDULED_AT_FALLBACK_KEY;
    }
    Datetime scheduledAt = toDatetime(scheduledValue, scheduledKey);

    String projectName = text(valueAt(root, PROJECT_NAME_KEY));
    String taskSubject = text(valueAt(root, TASK_SUBJECT_KEY));
    String note = text(valueAt(root, NOTE_KEY));
    String nextAction = text(valueAt(root, NEXT_ACTION_KEY));

    Boolean noAction =
      String.isNotBlank(nextAction) &&
      NO_ACTION_NEEDED.equalsIgnoreCase(
        mapValue(NEXT_ACTION_KEY, nextAction).normalizeSpace()
      );
    Datetime createdAt = Datetime.now();
    Datetime taskAt = noAction && scheduledAt != null ? scheduledAt : createdAt;
    Datetime nextActionAt = noAction ? null : scheduledAt;

    root.put(
      'calc',
      new Map<String, Object>{
        'subject' => String.isBlank(callType)
          ? 'Call Log'
          : 'Call - ' + callType,
        'status' => 'Completed',
        'activityDate' => startedAt != null ? startedAt.date() : Date.today(),
        'phone' => phone,
        'ownerId' => agentId,
        'projectSlug' => projectSlug(projectName),
        'createSalesTask' => createSalesTask,
        'scheduledAt' => scheduledAt,
        'taskDate' => localDate(taskAt),
        'taskTime' => localTime(taskAt),
        'nextActionDate' => nextActionAt == null
          ? null
          : localDate(nextActionAt),
        'nextActionTime' => nextActionAt == null
          ? null
          : localTime(nextActionAt),
        'taskSubject' => String.isBlank(taskSubject)
          ? TASK_SUBJECTS.get(direction)
          : mapValue(TASK_SUBJECT_KEY, taskSubject),
        'communicationType' => COMMUNICATION_TYPES.get(direction),
        'taskStatus' => SALES_TASK_STATUS,
        'comments' => shortComments(note),
        'dispositionNote' => shortComments(text(call.get('dispositionNote'))),
        'commentsDetailed' => String.isBlank(note) ? null : note.trim(),
        'rawPayload' => body.toString().left(RAW_PAYLOAD_MAX)
      }
    );
    return root;
  }

  private static Map<String, Object> logCall(Map<String, Object> values) {
    Savepoint sp = Database.setSavepoint();
    try {
      Map<String, Object> calc = (Map<String, Object>) values.get('calc');

      Opportunity opportunity = findOpportunity(
        (String) calc.get('phone'),
        (Id) calc.get('ownerId'),
        (String) calc.get('projectSlug')
      );
      calc.put('opportunityId', opportunity.Id);
      calc.put(
        'activityRecordTypeId',
        recordTypeId(ACTIVITY_OBJECT, ACTIVITY_RECORD_TYPE)
      );

      SObject activity = createActivity(
        ACTIVITY_OBJECT,
        opportunity.Id,
        ACTIVITY_FIELDS,
        values
      );

      SObject salesTask;
      if ((Boolean) calc.get('createSalesTask')) {
        calc.put(
          'salesTaskRecordTypeId',
          recordTypeId(SALES_TASK_OBJECT, opportunity.RecordType.DeveloperName)
        );
        salesTask = createRecord(SALES_TASK_OBJECT, SALES_TASK_FIELDS, values);
      }

      return new Map<String, Object>{
        'success' => true,
        'opportunityId' => opportunity.Id,
        'activityId' => activity.Id,
        'salesTaskId' => salesTask == null ? null : salesTask.Id
      };
    } catch (Exception e) {
      Database.rollback(sp);
      throw e;
    }
  }

  // Users are matched on the 10 digits of CallAnchor_Phone__c; inactive users never match.
  private static Id findAgent(String agentPhone) {
    Set<Id> matches = new Set<Id>();
    for (User user : [
      SELECT Id, CallAnchor_Phone__c
      FROM User
      WHERE IsActive = TRUE AND CallAnchor_Phone__c != NULL
    ]) {
      if (cleanPhone(user.CallAnchor_Phone__c) == agentPhone) {
        matches.add(user.Id);
      }
    }
    if (matches.isEmpty()) {
      throw fail(
        404,
        'AGENT_NOT_FOUND',
        'No active User has CallAnchor Phone ' + agentPhone + '.'
      );
    }
    if (matches.size() > 1) {
      throw fail(
        409,
        'DUPLICATE_AGENT_PHONE',
        matches.size() +
          ' active Users have CallAnchor Phone ' +
          agentPhone +
          '.'
      );
    }
    return new List<Id>(matches)[0];
  }

  public static Opportunity findOpportunity(
    String phone,
    Id ownerId,
    String projectSlug
  ) {
    List<String> conditions = new List<String>();
    for (String field : OPPORTUNITY_PHONE_FIELDS) {
      conditions.add(field + ' LIKE :phoneLike');
    }
    String whereClause =
      '(' +
      String.join(conditions, ' OR ') +
      ') AND OwnerId = :ownerId';
    Set<Id> projectIds = new Set<Id>();
    if (projectSlug != null) {
      projectIds = findProjectIds(projectSlug);
      whereClause += ' AND ' + PROJECT_FIELD + ' IN :projectIds';
    }

    List<Opportunity> opportunities = Database.queryWithBinds(
      'SELECT Id, RecordType.DeveloperName FROM Opportunity' +
        ' WHERE ' +
        whereClause +
        ' ORDER BY CreatedDate DESC LIMIT 1',
      new Map<String, Object>{
        'phoneLike' => '%' +
        phone +
        '%',
        'ownerId' => ownerId,
        'projectIds' => projectIds
      },
      AccessLevel.USER_MODE
    );

    if (opportunities.isEmpty()) {
      throw fail(
        404,
        'OPPORTUNITY_NOT_FOUND',
        'No Opportunity owned by the agent found for ' +
          phone +
          (projectSlug == null ? '' : ' in project "' + projectSlug + '"') +
          '.'
      );
    }
    return opportunities[0];
  }

  // Lowercase, every run of non-alphanumerics becomes one hyphen, no hyphen at either end.
  // Accepts the slug itself or the project name, so both resolve to the same value.
  public static String projectSlug(String value) {
    if (String.isBlank(value)) {
      return null;
    }
    String slug = value.toLowerCase()
      .replaceAll('[^a-z0-9]+', '-')
      .removeStart('-')
      .removeEnd('-');
    return String.isBlank(slug) ? null : slug;
  }

  private static Set<Id> findProjectIds(String slug) {
    Set<Id> ids = new Set<Id>();
    for (Ud_Project__c project : [
      SELECT Id, Name
      FROM Ud_Project__c
      WITH USER_MODE
    ]) {
      if (projectSlug(project.Name) == slug) {
        ids.add(project.Id);
      }
    }
    return ids;
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
    activity.put('WhatId', recordId);
    insert as user activity;
    return activity;
  }

  private static Id recordTypeId(String objectName, String developerName) {
    Schema.RecordTypeInfo info = Schema.getGlobalDescribe()
      .get(objectName)
      .getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get(developerName);
    if (info == null || !info.isActive()) {
      throw fail(
        500,
        'CONFIG_ERROR',
        objectName + ' has no active record type "' + developerName + '".'
      );
    }
    return info.getRecordTypeId();
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
      if (VALUE_MAPS.containsKey(fieldMap.get(field))) {
        value = mapValue(fieldMap.get(field), String.valueOf(value));
      }
      if (!objectFields.containsKey(field)) {
        throw fail(
          500,
          'CONFIG_ERROR',
          objectName + '.' + field + ' does not exist.'
        );
      }
      Schema.DescribeFieldResult describe = objectFields.get(field)
        .getDescribe();
      record.put(field, convert(value, describe, fieldMap.get(field)));
    }
    return record;
  }

  private static Object convert(
    Object value,
    Schema.DescribeFieldResult field,
    String key
  ) {
    String textValue = String.valueOf(value).trim();
    Object result = textValue;
    try {
      switch on field.getType() {
        when DATE {
          result = (value instanceof Date)
            ? value
            : toDatetime(value, key).date();
        }
        when DATETIME {
          result = toDatetime(value, key);
        }
        when TIME {
          result = value;
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
        when PICKLIST {
          result = picklistValue(field, textValue, key);
        }
      }
    } catch (CallException e) {
      throw e;
    } catch (Exception e) {
      throw fail(
        400,
        'INVALID_VALUE',
        '"' +
          textValue +
          '" (' +
          key +
          ') is not a valid ' +
          field.getType() +
          '.'
      );
    }
    return result;
  }

  // Matches a picklist value ignoring case and extra spaces; the Sales Task picklists are restricted.
  private static String picklistValue(
    Schema.DescribeFieldResult field,
    String value,
    String key
  ) {
    String wanted = value.normalizeSpace();
    for (Schema.PicklistEntry entry : field.getPicklistValues()) {
      if (entry.isActive() && entry.getValue().equalsIgnoreCase(wanted)) {
        return entry.getValue();
      }
    }
    throw fail(
      400,
      'INVALID_VALUE',
      '"' + value + '" (' + key + ') is not a valid ' + field.getLabel() + '.'
    );
  }

  private static String mapValue(String path, String value) {
    String mapped = VALUE_MAPS.get(path).get(value.trim().toLowerCase());
    return mapped == null ? value : mapped;
  }

  public static String shortComments(String note) {
    if (String.isBlank(note)) {
      return null;
    }
    String trimmed = note.trim();
    if (trimmed.length() <= COMMENTS_MAX) {
      return trimmed;
    }
    return trimmed.left(COMMENTS_MAX - COMMENTS_ELLIPSIS.length()) +
      COMMENTS_ELLIPSIS;
  }

  private static Date localDate(Datetime value) {
    return Date.valueOf(value.format('yyyy-MM-dd', TIME_ZONE));
  }

  private static Time localTime(Datetime value) {
    List<String> parts = value.format('HH:mm:ss', TIME_ZONE).split(':');
    return Time.newInstance(
      Integer.valueOf(parts[0]),
      Integer.valueOf(parts[1]),
      Integer.valueOf(parts[2]),
      0
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
    if (value instanceof Datetime) {
      return (Datetime) value;
    }
    String textValue = String.valueOf(value).trim();
    try {
      Datetime parsed = (Datetime) JSON.deserialize(
        '"' + textValue + '"',
        Datetime.class
      );
      // No "Z" or +hh:mm offset: the value is local time, which JSON read as GMT.
      if (!Pattern.matches('.*T.*(Z|[+-]\\d{2}:?\\d{2})$', textValue)) {
        parsed = parsed.addSeconds(
          -TimeZone.getTimeZone(TIME_ZONE).getOffset(parsed) / 1000
        );
      }
      return parsed;
    } catch (Exception e) {
      throw fail(
        400,
        'INVALID_DATE',
        fieldName + ' must be an ISO-8601 date/time.'
      );
    }
  }
}
