@RestResource(urlMapping='/CallAnchorWebhook/*')
global with sharing class CallAnchorWebhookService {
  // A record matches when the caller's phone is on it AND it is owned by the agent's
  // Salesforce user AND its Brand + Location equal the "select-brand" disposition.
  // Opportunity is checked first, then Lead; among several matches the most recently
  // created one wins. When neither matches, a new Lead is created only if
  // CREATE_LEAD_WHEN_NOT_FOUND is on; otherwise the Tasks are created without a
  // Lead or Opportunity.
  private static final String OPPORTUNITY_OBJECT = 'Opportunity';
  private static final List<String> OPPORTUNITY_PHONE_FIELDS = new List<String>{
    'Fathers_Contact_No__c',
    'Mothers_Contact_No__c'
  };
  private static final String OPPORTUNITY_BRAND_FIELD = 'Brand__c';

  private static final String LEAD_OBJECT = 'Lead';
  private static final List<String> LEAD_PHONE_FIELDS = new List<String>{
    'Fathers_Contact_No__c',
    'Mothers_Contact_No__c'
  };
  // Lead has no Brand__c; its brand picklist is Company_Brand__c.
  private static final String LEAD_BRAND_FIELD = 'Company_Brand__c';
  private static final String LEAD_FILTER = 'IsConverted = false';

  private static final String LOCATION_FIELD = 'Location__c';

  // Disposition value in "brand-location" form, all lower case, e.g. "mindseed-balewadi".
  private static final String SELECT_BRAND_PATH = 'disposition.fields.select-brand';

  // Active Salesforce users with a CallAnchor_Phone__c, keyed by its 10 digits
  // (call.agentNumber). Maintained on each User record.
  @TestVisible
  private static Map<String, Agent> AGENTS {
    get {
      if (AGENTS == null) {
        AGENTS = loadAgents();
      }
      return AGENTS;
    }
    set;
  }

  // Flip to true to create a new Lead when no Opportunity or Lead matches the caller.
  @TestVisible
  private static Boolean CREATE_LEAD_WHEN_NOT_FOUND = false;

  // Writes the callback to the matched Lead/Opportunity's next follow-up date and time.
  // This update re-runs Wunderbar's active stage flows (e.g. Mindseed_Lead_Flow,
  // Foundree_Lead_Flow, Foundree_Flow, Send_message_when_lead_is_created), which re-send
  // the current stage's email/SMS without checking whether it changed. Set to false to
  // stop these updates.
  @TestVisible
  private static Boolean UPDATE_NEXT_FOLLOW_UP = true;

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

  // The call is logged as a "Call" Task (TaskSubtype = Call, like Log a Call) owned by
  // the agent. Standard call fields and Wunderbar's existing Task fields are reused;
  // only the Call_Anchor_* / CallAnchor_* fields are Call Anchor specific.
  private static final Map<String, String> ACTIVITY_FIELDS = new Map<String, String>{
    'TaskSubtype' => 'calc.callSubtype',
    'OwnerId' => 'calc.ownerId',
    'Subject' => 'calc.subject',
    'Status' => 'calc.status',
    'ActivityDate' => 'calc.activityDate',
    'Call_Anchor_Call_Id__c' => 'call.id',
    'CallType' => 'calc.callType',
    'Call_Anchor_Call_Type__c' => 'call.callType',
    'Task_Time__c' => 'call.startedAt',
    'CallDurationInSeconds' => 'call.durationSeconds',
    'Call_Anchor_Agent_Name__c' => 'call.agentName',
    'CallAnchor_Recording_Url__c' => 'call.recordingUrl',
    'CallDisposition' => 'disposition.fields.outcome',
    'Remarks__c' => 'calc.remarks',
    'Call_Anchor_Callback_Scheduled_At__c' => 'call.dispositionScheduledAt',
    'Description' => 'calc.rawPayload'
  };

  // Call Anchor call types -> standard Task.CallType, whose values (Inbound, Outbound,
  // Internal) cannot be changed. Missed and rejected calls are incoming calls; any other
  // value leaves CallType blank. The original value is kept in Call_Anchor_Call_Type__c.
  private static final Map<String, String> CALL_TYPES = new Map<String, String>{
    'outgoing' => 'Outbound',
    'incoming' => 'Inbound',
    'missed' => 'Inbound',
    'rejected' => 'Inbound'
  };

  // Remarks__c is a 255-character text area; the full note stays in Description.
  private static final Integer REMARKS_MAX = 255;

  // Open follow-up Task created when the disposition schedules a callback. It is a
  // regular Task (not a Call) and carries every call field of the call Task; only these
  // are replaced. Its due date matches Call_Anchor_Callback_Scheduled_At__c.
  private static final Map<String, String> FOLLOW_UP_OVERRIDES = new Map<String, String>{
    'TaskSubtype' => 'calc.followUpSubtype',
    'Subject' => 'calc.followUpSubject',
    'Status' => 'calc.followUpStatus',
    'ActivityDate' => 'call.dispositionScheduledAt',
    'Description' => 'call.dispositionNote'
  };

  private static final Map<String, String> FOLLOW_UP_FIELDS = followUpFields();

  private static Map<String, String> followUpFields() {
    Map<String, String> fields = ACTIVITY_FIELDS.clone();
    fields.putAll(FOLLOW_UP_OVERRIDES);
    return fields;
  }

  // When a callback is scheduled, the matched record's next follow-up date and time are
  // set to it, in the agent's time zone. The date field's API name differs per object;
  // the time field is Next_Followup_Time__c on both.
  private static final Map<String, String> NEXT_FOLLOW_UP_DATE_FIELDS = new Map<String, String>{
    'Lead' => 'Next_Follow_up_Date__c',
    'Opportunity' => 'Next_followup_date__c'
  };
  private static final String NEXT_FOLLOW_UP_TIME_FIELD = 'Next_Followup_Time__c';

  // Follow-up reminder, in minutes before the callback. A Task holds a single reminder,
  // so the first offset whose time is still in the future is used.
  @TestVisible
  private static List<Integer> REMINDER_MINUTES_BEFORE = new List<Integer>{
    15
  };

  // Used when the org has an open Task status with this name; otherwise the default open status.
  private static final String OPEN_STATUS = 'Open';

  private static final Integer RAW_PAYLOAD_MAX = 32000;

  // Up to this many matches per object are listed in the log; the newest is picked.
  private static final Integer MATCH_LOG_LIMIT = 10;

  // Steps taken for the current request, returned as "log" in every response.
  @TestVisible
  private static List<String> LOG = new List<String>();

  // Each line is tagged with where the information came from:
  // [Webhook] value received in the payload, [Salesforce] read from or saved to the org,
  // [Mapping] payload value converted to a Salesforce value, [Decision] what was chosen,
  // [Error] why the request failed.
  private static final String WEBHOOK = '[Webhook] ';
  private static final String SALESFORCE = '[Salesforce] ';
  private static final String MAPPING = '[Mapping] ';
  private static final String DECISION = '[Decision] ';
  private static final String ERROR = '[Error] ';

  private static void log(String tag, String message) {
    LOG.add(tag + message);
  }

  @HttpPost
  global static void doPost() {
    LOG = new List<String>();
    try {
      Map<String, Object> values = readPayload();
      Map<String, Object> result = logCall(values);
      // Nothing is created when the call is skipped, so that case is 200 rather than 201.
      send(result.containsKey('activityId') ? 201 : 200, result);
    } catch (CallException e) {
      log(ERROR, e.code + ': ' + e.getMessage());
      send(e.status, errorBody(e.code, e.getMessage()));
    } catch (DmlException e) {
      log(ERROR, 'Save failed, nothing was saved: ' + e.getDmlMessage(0));
      send(422, errorBody('SAVE_FAILED', e.getDmlMessage(0)));
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        e.getMessage() + '\n' + e.getStackTraceString()
      );
      log(ERROR, 'Unexpected: ' + e.getMessage());
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
    log(
      WEBHOOK,
      'Received call ' +
        call.get('id') +
        ' (' +
        call.get('callType') +
        '), calleePhone "' +
        call.get('calleePhone') +
        '", agentNumber "' +
        call.get('agentNumber') +
        '"'
    );

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

    String agentPhone = cleanPhone(text(call.get('agentNumber')));
    Agent agent = agentPhone == null ? null : AGENTS.get(agentPhone);
    String selectBrand = text(valueAt(root, SELECT_BRAND_PATH));
    String brand = selectBrand?.substringBefore('-').trim();
    String location = selectBrand?.substringAfter('-').trim();

    log(
      WEBHOOK,
      'Received select-brand "' +
        selectBrand +
        '" -> brand "' +
        brand +
        '", location "' +
        location +
        '"'
    );
    log(MAPPING, 'calleePhone -> ' + phone + ', agentNumber -> ' + agentPhone);
    log(
      SALESFORCE,
      agent == null
        ? 'User.CallAnchor_Phone__c: no active agent with phone ' + agentPhone
        : 'User.CallAnchor_Phone__c: ' +
          agentPhone +
          ' -> User ' +
          agent.userId +
          ' (' +
          agent.department +
          ')'
    );
    String dispositionNote = text(call.get('dispositionNote'));

    root.put(
      'calc',
      new Map<String, Object>{
        'callSubtype' => 'Call',
        'followUpSubtype' => 'Task',
        'ownerId' => agent?.userId,
        'callType' => String.isBlank(callType)
          ? null
          : CALL_TYPES.get(callType.trim().toLowerCase()),
        'remarks' => dispositionNote?.left(REMARKS_MAX),
        'subject' => String.isBlank(callType)
          ? 'Call Log'
          : 'Call - ' + callType,
        'status' => 'Completed',
        'activityDate' => startedAt != null ? startedAt.date() : Date.today(),
        'phone' => phone,
        'agentPhone' => agentPhone,
        'agent' => agent,
        'selectBrand' => selectBrand,
        'brand' => String.isBlank(brand) ? null : brand,
        'location' => String.isBlank(location) ? null : location,
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
    String skipReason = skipReason(values);
    if (skipReason != null) {
      log(DECISION, 'Skipped, call not logged: ' + skipReason);
      return new Map<String, Object>{
        'success' => true,
        'message' => skipReason + '; call not logged.'
      };
    }

    Savepoint sp = Database.setSavepoint();
    try {
      Id recordId = findOrCreateRecord(values);
      String linkedTo = recordId == null
        ? 'no Lead or Opportunity'
        : String.valueOf(recordId);
      if (recordId == null) {
        log(
          DECISION,
          'No matching Opportunity or Lead; Tasks are created without a related record'
        );
      }

      SObject activity = createActivity(
        ACTIVITY_OBJECT,
        recordId,
        ACTIVITY_FIELDS,
        values
      );
      log(SALESFORCE, 'Created call Task ' + activity.Id + ' on ' + linkedTo);

      SObject followUp = createFollowUp(recordId, values);
      if (followUp == null) {
        log(DECISION, 'No dispositionScheduledAt received; no follow-up Task');
      } else {
        log(
          SALESFORCE,
          'Created follow-up Task ' +
            followUp.Id +
            ' on ' +
            linkedTo +
            ' due ' +
            valueAt(values, 'calc.scheduledAt')
        );
        updateNextFollowUp(recordId, values);
      }

      Map<String, Object> result = new Map<String, Object>{
        'success' => true,
        'activityId' => activity.Id,
        'followUpId' => followUp == null ? null : followUp.Id,
        'recordId' => recordId
      };
      if (recordId == null) {
        result.put(
          'message',
          'No Opportunity or Lead found for phone ' +
            valueAt(values, 'calc.phone') +
            ' owned by agent ' +
            valueAt(values, 'calc.agentPhone') +
            ' with select-brand "' +
            valueAt(values, 'calc.selectBrand') +
            '"; call logged without a related record.'
        );
      }
      return result;
    } catch (Exception e) {
      Database.rollback(sp);
      throw e;
    }
  }

  // Calls from unknown agents or without a usable "select-brand" cannot be matched.
  private static String skipReason(Map<String, Object> values) {
    if (valueAt(values, 'calc.agent') == null) {
      return 'Agent ' +
        valueAt(values, 'call.agentNumber') +
        ' is not in the agent map';
    }
    if (
      valueAt(values, 'calc.brand') == null ||
      valueAt(values, 'calc.location') == null
    ) {
      return 'select-brand "' +
        valueAt(values, 'calc.selectBrand') +
        '" is not in brand-location form';
    }
    return null;
  }

  private static Id findOrCreateRecord(Map<String, Object> values) {
    SObject opportunity = findMatch(
      OPPORTUNITY_OBJECT,
      OPPORTUNITY_PHONE_FIELDS,
      OPPORTUNITY_BRAND_FIELD,
      null,
      values
    );
    if (opportunity != null) {
      return opportunity.Id;
    }

    SObject lead = findMatch(
      LEAD_OBJECT,
      LEAD_PHONE_FIELDS,
      LEAD_BRAND_FIELD,
      LEAD_FILTER,
      values
    );
    if (lead != null) {
      return lead.Id;
    }

    if (!CREATE_LEAD_WHEN_NOT_FOUND) {
      return null;
    }
    log(DECISION, 'No match; creating a new Lead');
    Id leadId = createRecord(LEAD_OBJECT, NEW_LEAD_FIELDS, values).Id;
    log(SALESFORCE, 'Created Lead ' + leadId);
    return leadId;
  }

  // Most recently created record with the caller's phone, the agent as owner and the
  // selected Brand + Location; null when none matches.
  public static SObject findMatch(
    String objectName,
    List<String> phoneFields,
    String brandField,
    String filter,
    Map<String, Object> values
  ) {
    String brand = picklistValue(
      objectName,
      brandField,
      (String) valueAt(values, 'calc.brand')
    );
    String location = picklistValue(
      objectName,
      LOCATION_FIELD,
      (String) valueAt(values, 'calc.location')
    );
    log(
      MAPPING,
      objectName +
        '.' +
        brandField +
        ': "' +
        valueAt(values, 'calc.brand') +
        '" -> ' +
        (brand == null ? 'no matching picklist value' : '"' + brand + '"')
    );
    log(
      MAPPING,
      objectName +
        '.' +
        LOCATION_FIELD +
        ': "' +
        valueAt(values, 'calc.location') +
        '" -> ' +
        (location == null ? 'no matching picklist value' : '"' + location + '"')
    );
    if (brand == null || location == null) {
      log(
        DECISION,
        objectName + ' not searched: brand or location has no picklist value'
      );
      return null;
    }

    List<String> conditions = new List<String>();
    for (String field : phoneFields) {
      conditions.add(field + ' LIKE :phoneLike');
    }
    String whereClause =
      '(' +
      String.join(conditions, ' OR ') +
      ') AND OwnerId = :ownerId AND ' +
      brandField +
      ' = :brand AND ' +
      LOCATION_FIELD +
      ' = :location';
    if (String.isNotBlank(filter)) {
      whereClause += ' AND (' + filter + ')';
    }

    String query =
      'SELECT Id, Name, CreatedDate FROM ' +
      objectName +
      ' WHERE ' +
      whereClause +
      ' ORDER BY CreatedDate DESC LIMIT ' +
      MATCH_LOG_LIMIT;

    List<SObject> records = Database.queryWithBinds(
      query,
      new Map<String, Object>{
        'phoneLike' => '%' +
        valueAt(values, 'calc.phone') +
        '%',
        'ownerId' => ((Agent) valueAt(values, 'calc.agent')).userId,
        'brand' => brand,
        'location' => location
      },
      AccessLevel.USER_MODE
    );
    String criteria =
      'phone ' +
      valueAt(values, 'calc.phone') +
      ' + Owner ' +
      ((Agent) valueAt(values, 'calc.agent')).userId +
      ' + ' +
      brandField +
      ' "' +
      brand +
      '" + ' +
      LOCATION_FIELD +
      ' "' +
      location +
      '"' +
      (String.isBlank(filter) ? '' : ' + ' + filter);
    if (records.isEmpty()) {
      log(SALESFORCE, objectName + ' search (' + criteria + '): 0 found');
      return null;
    }
    List<String> found = new List<String>();
    for (SObject record : records) {
      found.add(
        record.get('Name') +
          ' [' +
          record.Id +
          ', created ' +
          record.get('CreatedDate') +
          ']'
      );
    }
    log(
      SALESFORCE,
      objectName +
        ' search (' +
        criteria +
        '): ' +
        records.size() +
        (records.size() == MATCH_LOG_LIMIT ? '+' : '') +
        ' found - ' +
        String.join(found, '; ')
    );
    log(
      DECISION,
      'Call mapped to ' +
        objectName +
        ' ' +
        records[0].get('Name') +
        ' [' +
        records[0].Id +
        ']' +
        (records.size() > 1
          ? ' - most recently created of ' + records.size()
          : ' - only match')
    );
    return records[0];
  }

  // Maps a lower-case key such as "balewadi" or "wakad-chaudhary-park" to the picklist
  // value whose API name or label is the same once case, spaces and punctuation are
  // ignored. Labels are checked too because Lead and Opportunity use different API
  // names for some locations (e.g. "New Panvel 19" vs "Panvel 19").
  public static String picklistValue(
    String objectName,
    String field,
    String key
  ) {
    if (String.isBlank(key)) {
      return null;
    }
    Map<String, Schema.SObjectField> objectFields = Schema.getGlobalDescribe()
      .get(objectName)
      .getDescribe()
      .fields.getMap();
    if (!objectFields.containsKey(field)) {
      throw fail(
        500,
        'CONFIG_ERROR',
        objectName + '.' + field + ' does not exist.'
      );
    }
    String wanted = normalise(key);
    for (
      Schema.PicklistEntry entry : objectFields.get(field)
        .getDescribe()
        .getPicklistValues()
    ) {
      if (
        entry.isActive() &&
        (normalise(entry.getValue()) == wanted ||
        normalise(entry.getLabel()) == wanted)
      ) {
        return entry.getValue();
      }
    }
    return null;
  }

  private static String normalise(String value) {
    return value.toLowerCase().replaceAll('[^a-z0-9]', '');
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
    if (recordId != null) {
      activity.put(linkField(activityObject, recordId), recordId);
    }
    insert as user activity;
    return activity;
  }

  // Creates an open follow-up Task when the disposition scheduled a callback.
  // The reminder is set from REMINDER_MINUTES_BEFORE, only when it is still in the future.
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
    if (recordId != null) {
      followUp.put(linkField(ACTIVITY_OBJECT, recordId), recordId);
    }
    Datetime reminderAt = reminderTime(scheduledAt);
    followUp.IsReminderSet = reminderAt != null;
    followUp.ReminderDateTime = reminderAt;
    log(
      DECISION,
      reminderAt == null
        ? 'No follow-up reminder: every reminder time ' +
          REMINDER_MINUTES_BEFORE +
          ' min before is past'
        : 'Follow-up reminder at ' + reminderAt
    );
    insert as user followUp;
    return followUp;
  }

  private static Datetime reminderTime(Datetime scheduledAt) {
    for (Integer minutes : REMINDER_MINUTES_BEFORE) {
      Datetime reminderAt = scheduledAt.addMinutes(-minutes);
      if (reminderAt > Datetime.now()) {
        return reminderAt;
      }
    }
    return null;
  }

  // Sets the record's next follow-up date and time to the scheduled callback, as seen in
  // the agent's time zone. A failed update is logged but does not undo the Tasks.
  private static void updateNextFollowUp(
    Id recordId,
    Map<String, Object> values
  ) {
    if (recordId == null) {
      log(DECISION, 'No related record; next follow-up date/time not updated');
      return;
    }
    if (!UPDATE_NEXT_FOLLOW_UP) {
      log(
        DECISION,
        'UPDATE_NEXT_FOLLOW_UP is off; ' +
          recordId +
          ' next follow-up date/time not updated'
      );
      return;
    }
    String objectName = recordId.getSObjectType().getDescribe().getName();
    String dateField = NEXT_FOLLOW_UP_DATE_FIELDS.get(objectName);
    if (dateField == null) {
      log(DECISION, objectName + ' has no next follow-up fields; not updated');
      return;
    }

    Datetime scheduledAt = (Datetime) valueAt(values, 'calc.scheduledAt');
    String timeZone = agentTimeZone(values);
    String local = scheduledAt.format('yyyy-MM-dd HH:mm:ss', timeZone);
    Date followUpDate = Date.valueOf(local.left(10));
    Time followUpTime = Time.newInstance(
      Integer.valueOf(local.substring(11, 13)),
      Integer.valueOf(local.substring(14, 16)),
      Integer.valueOf(local.substring(17, 19)),
      0
    );

    String target =
      objectName +
      ' ' +
      recordId +
      ' ' +
      dateField +
      ' = ' +
      followUpDate +
      ', ' +
      NEXT_FOLLOW_UP_TIME_FIELD +
      ' = ' +
      local.substring(11, 16) +
      ' (' +
      timeZone +
      ')';

    // Nothing to write when unchanged, and skipping it avoids re-running the stage flows.
    SObject current = Database.query(
      'SELECT ' +
        dateField +
        ', ' +
        NEXT_FOLLOW_UP_TIME_FIELD +
        ' FROM ' +
        objectName +
        ' WHERE Id = :recordId'
    );
    if (
      current.get(dateField) == followUpDate &&
      current.get(NEXT_FOLLOW_UP_TIME_FIELD) == followUpTime
    ) {
      log(DECISION, 'Already set, not updated: ' + target);
      return;
    }

    SObject record = recordId.getSObjectType().newSObject(recordId);
    record.put(dateField, followUpDate);
    record.put(NEXT_FOLLOW_UP_TIME_FIELD, followUpTime);
    Database.SaveResult saved = Database.update(
      record,
      false,
      AccessLevel.USER_MODE
    );
    if (saved.isSuccess()) {
      log(SALESFORCE, 'Updated ' + target);
    } else {
      log(
        ERROR,
        'Could not update ' +
          target +
          ': ' +
          saved.getErrors()[0].getMessage() +
          ' (Tasks were still created)'
      );
    }
  }

  // The agent user's time zone, falling back to the running user's.
  private static String agentTimeZone(Map<String, Object> values) {
    Agent agent = (Agent) valueAt(values, 'calc.agent');
    if (agent != null && String.isNotBlank(agent.userId)) {
      for (User user : [
        SELECT TimeZoneSidKey
        FROM User
        WHERE Id = :agent.userId
        LIMIT 1
      ]) {
        return user.TimeZoneSidKey;
      }
    }
    return UserInfo.getTimeZone().getID();
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

  @TestVisible
  private static Map<String, Agent> loadAgents() {
    Map<String, Agent> agents = new Map<String, Agent>();
    for (User user : [
      SELECT Id, CallAnchor_Phone__c, CallAnchor_Department__c
      FROM User
      WHERE IsActive = TRUE AND CallAnchor_Phone__c != NULL
    ]) {
      String phone = cleanPhone(user.CallAnchor_Phone__c);
      if (phone != null) {
        agents.put(phone, new Agent(user.Id, user.CallAnchor_Department__c));
      }
    }
    return agents;
  }

  public class Agent {
    public String userId;
    public String department;

    public Agent(String userId, String department) {
      this.userId = userId;
      this.department = department;
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

  private static void send(Integer status, Map<String, Object> body) {
    RestResponse res = RestContext.response;
    res.statusCode = status;
    body.put('log', LOG);
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
