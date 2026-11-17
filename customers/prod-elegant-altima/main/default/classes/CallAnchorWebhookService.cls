/**
 * REST Webhook endpoint: /services/apexrest/CallAnchorWebhook/
 *
 * Receives call event payloads from an external calling platform, matches the
 * "calleePhone" against Lead.Phone / Lead.MobilePhone. If a match is found, a
 * completed call Task is logged against that Lead. If NO match is found, a new
 * Lead is auto-created from the call data first, and the Task is then linked
 * to that newly created Lead.
 *
 * If the disposition carries a "scheduled-at" value, an additional open
 * follow-up Task (same field mappings) is created, due at that time.
 *
 * Both Tasks are owned by the active User whose Call_Anchor_Phone__c matches
 * the call's agentNumber (last 10 digits); otherwise by the running
 * (integration) user.
 *
 * Retries are idempotent: a call id that is already logged returns the
 * existing Task Ids instead of creating duplicates.
 *
 * Response contract (same shape for success and errors; HTTP status tells them apart):
 * {
 *   "taskId": "<completed call Task Id>" | null,
 *   "records": {
 *     "leadId": "<matched or created Lead Id>",
 *     "followUpTaskId": "<open follow-up Task Id>"   // only when created
 *   },
 *   "logs": [ "<what happened, step by step / error detail>" ]
 * }
 */
@RestResource(urlMapping='/CallAnchorWebhook/*')
global with sharing class CallAnchorWebhookService {
  // ---------- Config ----------
  // Lead Source picklist value marking Leads auto-created from a call
  private static final String NEW_LEAD_SOURCE = '360 CallAnchor';
  private static final String UNKNOWN_FIRST_NAME = 'Unknown';
  private static final String UNKNOWN_LAST_NAME = 'Caller';
  // Elegant Altima's numbers are Indian; used to build exact-match variants
  private static final String COUNTRY_CODE = '91';
  private static final Integer PHONE_MATCH_DIGITS = 10;
  private static final Integer MAX_CANDIDATES = 50;
  private static final String SUBTYPE_CALL = 'Call';
  private static final String SUBTYPE_TASK = 'Task';

  // Steps logged during this request, returned in the response "logs".
  // Never put phone numbers or signed recording URLs in here.
  private static List<String> logs = new List<String>();

  // ---------- Response wrapper ----------
  global class WebhookResponse {
    global Id taskId;
    global Map<String, Id> records = new Map<String, Id>();
    global List<String> logs;
  }

  // ---------- Payload wrappers ----------
  global class CallPayload {
    public CallData call;
    public String event;
    public Object disposition; // kept generic — shape of "fields" can vary
    public Boolean hasRecording;
  }

  global class CallData {
    public String id;
    public String callType;
    public String agentName;
    public Datetime startedAt;
    public String calleeName;
    public String agentNumber;
    public String calleePhone;
    public String recordingUrl;
    public String dispositionNote;
    public Integer durationSeconds;
    public String dispositionLabel;
    public Datetime dispositionScheduledAt;
  }

  // ---------- Result of processing one call ----------
  global class CallResult {
    global Id leadId;
    global Task callTask;
    global Task followUpTask;
  }

  @HttpPost
  global static void doPost() {
    RestResponse res = RestContext.response;
    res.addHeader('Content-Type', 'application/json');
    logs = new List<String>();

    try {
      RestRequest req = RestContext.request;

      if (
        req == null ||
        req.requestBody == null ||
        req.requestBody.size() == 0
      ) {
        respondError(res, 400, 'Empty request body.');
        return;
      }

      CallPayload payload;

      try {
        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(
          req.requestBody.toString()
        );
        payload = new CallPayload();
        payload.event = asString(root.get('event'));
        payload.hasRecording = root.get('hasRecording') instanceof Boolean
          ? (Boolean) root.get('hasRecording')
          : null;
        payload.disposition = root.get('disposition');

        Object callRaw = root.get('call');
        if (callRaw != null) {
          payload.call = (CallData) JSON.deserialize(
            JSON.serialize(callRaw),
            CallData.class
          );
        }
      } catch (Exception parseEx) {
        respondError(res, 400, 'Malformed payload: ' + parseEx.getMessage());
        return;
      }

      if (payload.call == null || String.isBlank(payload.call.calleePhone)) {
        respondError(res, 400, 'calleePhone is required.');
        return;
      }

      CallResult result = processCall(payload);

      WebhookResponse body = new WebhookResponse();
      body.taskId = result.callTask.Id;
      body.records.put('leadId', result.leadId);
      if (result.followUpTask != null) {
        body.records.put('followUpTaskId', result.followUpTask.Id);
      }
      respond(res, 200, body);
    } catch (Exception ex) {
      respondError(res, 500, 'Exception: ' + ex.getMessage());
    }
  }

  /**
   * Matches the Lead by phone (last 10 digits) against Phone OR MobilePhone.
   * If no match is found, a new Lead is created from the call data first.
   * Either way, a completed call Task is inserted and linked (WhoId) to that
   * Lead, plus an open follow-up Task when "scheduled-at" is present.
   */
  global static CallResult processCall(CallPayload payloadData) {
    CallData call = payloadData.call;

    // The app retries on timeouts; return what was already logged for this call
    CallResult existing = findExistingResult(call.id);
    if (existing != null) {
      logs.add(
        'Call ' +
          call.id +
          ' was already logged; returning the existing Task, nothing created.'
      );
      return existing;
    }

    Map<String, Object> dispositionMap = payloadData.disposition instanceof Map<String, Object>
      ? (Map<String, Object>) payloadData.disposition
      : new Map<String, Object>();
    Map<String, Object> fields = dispositionMap.get(
        'fields'
      ) instanceof Map<String, Object>
      ? (Map<String, Object>) dispositionMap.get('fields')
      : new Map<String, Object>();

    Datetime scheduledAt = parseDatetime(
      fields.get('scheduled-at'),
      'scheduled-at'
    );
    if (scheduledAt == null) {
      scheduledAt = call.dispositionScheduledAt;
    }

    // Lead insert and Task insert succeed or fail together, so a failed
    // request never leaves an orphan Lead behind
    Savepoint sp = Database.setSavepoint();
    try {
      Lead matchedLead = findOrCreateLead(call);

      // ---------- Completed call Task (the recording / call log) ----------
      Task callTask = new Task();
      callTask.WhoId = matchedLead.Id;
      // Set before the follow-up is cloned, so both Tasks belong to the agent
      Id agentUserId = findAgentUserByPhone(call.agentNumber);
      if (agentUserId != null) {
        callTask.OwnerId = agentUserId;
        logs.add(
          'Matched agent user ' +
            agentUserId +
            ' by phone; Tasks are owned by that user.'
        );
      } else {
        logs.add(
          'No active user has a matching Call Anchor Phone; Tasks are owned by the integration user.'
        );
      }
      callTask.Subject = String.isNotBlank(call.callType)
        ? 'Call - ' + call.callType
        : 'Call Log';
      callTask.Status = 'Completed';
      callTask.TaskSubtype = SUBTYPE_CALL;
      callTask.ActivityDate = (call.startedAt != null
          ? call.startedAt
          : Datetime.now())
        .date();
      callTask.CallDurationInSeconds = call.durationSeconds;
      callTask.Call_Anchor_Call_Id__c = call.id;
      callTask.Call_Anchor_Call_Type__c = call.callType;
      callTask.Call_Anchor_Agent_Name__c = call.agentName;
      callTask.Call_Anchor_Agent_Mobile__c = call.agentNumber;
      callTask.Call_Anchor_Call_Started_At__c = call.startedAt;
      callTask.Call_Anchor_Duration_Seconds__c = call.durationSeconds;
      callTask.Call_Anchor_Recording_Url__c = call.recordingUrl;
      callTask.Call_Anchor_Disposition__c = firstNonBlank(
        asString(fields.get('outcome')),
        call.dispositionLabel
      );
      callTask.Call_Anchor_Disposition_Note__c = firstNonBlank(
        asString(fields.get('note')),
        call.dispositionNote
      );
      callTask.Call_Anchor_Callback_Scheduled_At__c = scheduledAt;

      List<Task> tasksToInsert = new List<Task>{ callTask };

      // ---------- Open follow-up Task (only when scheduled-at is received) ----------
      Task followUpTask;
      if (scheduledAt != null) {
        followUpTask = callTask.clone(false, true, false, false);
        followUpTask.Subject = 'Follow-up - ' + callTask.Subject;
        followUpTask.Status = 'Not Started';
        followUpTask.TaskSubtype = SUBTYPE_TASK;
        followUpTask.ActivityDate = scheduledAt.date();
        followUpTask.IsReminderSet = scheduledAt > Datetime.now();
        followUpTask.ReminderDateTime = followUpTask.IsReminderSet
          ? scheduledAt
          : null;
        followUpTask.CallDurationInSeconds = null;
        tasksToInsert.add(followUpTask);
      }

      // Truncate over-length values (e.g. long signed recording URLs) instead of failing
      Database.insert(tasksToInsert, truncatingDml());

      logs.add(
        'Created call Task ' + callTask.Id + ' (' + callTask.Subject + ').'
      );
      if (followUpTask != null) {
        logs.add(
          'Created follow-up Task ' +
            followUpTask.Id +
            ' due ' +
            scheduledAt.formatGmt('yyyy-MM-dd HH:mm') +
            ' GMT' +
            (followUpTask.IsReminderSet
              ? ' with a reminder.'
              : '; time already passed, so no reminder.')
        );
      } else {
        logs.add('No callback scheduled; no follow-up Task created.');
      }

      CallResult result = new CallResult();
      result.leadId = matchedLead.Id;
      result.callTask = callTask;
      result.followUpTask = followUpTask;
      return result;
    } catch (Exception ex) {
      Database.rollback(sp);
      logs.add('Rolled back: no Lead or Task was saved.');
      throw ex;
    }
  }

  // ---------- Helpers ----------

  private static CallResult findExistingResult(String callId) {
    if (String.isBlank(callId)) {
      return null;
    }
    CallResult result = new CallResult();
    for (Task t : [
      SELECT Id, TaskSubtype, WhoId
      FROM Task
      WHERE Call_Anchor_Call_Id__c = :callId
      ORDER BY CreatedDate ASC
    ]) {
      if (t.TaskSubtype == SUBTYPE_CALL && result.callTask == null) {
        result.callTask = t;
        result.leadId = t.WhoId;
      } else if (t.TaskSubtype == SUBTYPE_TASK && result.followUpTask == null) {
        result.followUpTask = t;
      }
    }
    return result.callTask != null ? result : null;
  }

  private static Lead findOrCreateLead(CallData call) {
    String matchKey = phoneKey(call.calleePhone);

    Lead matched = findLeadByPhone(call.calleePhone.trim(), matchKey);
    if (matched != null) {
      logs.add('Matched existing Lead ' + matched.Id + ' by phone.');
      return matched;
    }

    // No existing Lead — create one from the call data
    String calleeName = call.calleeName == null ? '' : call.calleeName.trim();
    Boolean hasCalleeName =
      String.isNotBlank(calleeName) && !calleeName.equalsIgnoreCase('Unknown');

    Lead newLead = new Lead();
    if (hasCalleeName) {
      Integer lastSpace = calleeName.lastIndexOf(' ');
      newLead.FirstName = lastSpace > 0
        ? calleeName.left(lastSpace).trim().left(40)
        : null;
      newLead.LastName = calleeName.substring(lastSpace + 1).left(80);
    } else {
      newLead.FirstName = UNKNOWN_FIRST_NAME;
      newLead.LastName = UNKNOWN_LAST_NAME;
    }
    // Company is left blank: Person Accounts are on, so Company isn't required
    newLead.LeadSource = NEW_LEAD_SOURCE;
    newLead.Phone = call.calleePhone;
    newLead.MobilePhone = call.calleePhone;
    Database.insert(newLead, truncatingDml());
    logs.add('No Lead matched the phone; created Lead ' + newLead.Id + '.');
    return newLead;
  }

  /**
   * Stored Lead phones come in many formats ("+91 99439 84451", "09943984451",
   * "9943984451"), so a single LIKE misses most of them. Candidates come from:
   *  - SOSL IN PHONE FIELDS, which ignores formatting (but indexes new records
   *    with a short delay), and
   *  - an exact SOQL match on the common unformatted variants, which catches
   *    Leads created moments ago, e.g. by a previous call from this webhook.
   * Each candidate is then confirmed by comparing the last 10 digits, so a
   * partial hit like "98765432108" never counts as a match.
   */
  private static Lead findLeadByPhone(String rawPhone, String matchKey) {
    if (String.isBlank(matchKey)) {
      return null;
    }
    Set<String> variants = new Set<String>{
      rawPhone,
      matchKey,
      '0' + matchKey,
      COUNTRY_CODE + matchKey,
      '+' +
      COUNTRY_CODE +
      matchKey
    };

    List<Lead> candidates = [
      SELECT Id, Phone, MobilePhone, LastModifiedDate
      FROM Lead
      WHERE Phone IN :variants OR MobilePhone IN :variants
      ORDER BY LastModifiedDate DESC
      LIMIT :MAX_CANDIDATES
    ];
    if (matchKey.length() >= 2) {
      List<List<SObject>> found = [
        FIND :matchKey
        IN PHONE FIELDS
        RETURNING
          Lead(
            Id,
            Phone,
            MobilePhone,
            LastModifiedDate
            ORDER BY LastModifiedDate DESC
            LIMIT 50
          )
      ];
      candidates.addAll((List<Lead>) found[0]);
    }

    Lead best;
    for (Lead candidate : candidates) {
      Boolean isMatch =
        phoneKey(candidate.Phone) == matchKey ||
        phoneKey(candidate.MobilePhone) == matchKey;
      if (
        isMatch &&
        (best == null ||
        candidate.LastModifiedDate > best.LastModifiedDate)
      ) {
        best = candidate;
      }
    }
    return best;
  }

  /**
   * Maps the call's agentNumber to the active User whose Call_Anchor_Phone__c
   * has the same last 10 digits. The LIKE on the last 4 digits only narrows the
   * query; the exact comparison happens in the loop because the field is
   * free-format ("+91 93193 00765", "09319300765", ...).
   */
  private static Id findAgentUserByPhone(String agentPhone) {
    String agentKey = phoneKey(agentPhone);
    if (agentKey == null || agentKey.length() < PHONE_MATCH_DIGITS) {
      return null;
    }
    String searchPattern = '%' + agentKey.right(4);

    // Oldest user wins if two users share a number, so the owner is stable
    for (User agent : [
      SELECT Id, Call_Anchor_Phone__c
      FROM User
      WHERE Call_Anchor_Phone__c LIKE :searchPattern AND IsActive = TRUE
      ORDER BY CreatedDate ASC
      LIMIT 200
    ]) {
      if (phoneKey(agent.Call_Anchor_Phone__c) == agentKey) {
        return agent.Id;
      }
    }
    return null;
  }

  // Digits only, last 10 kept, so country code / trunk prefix / spacing don't matter
  private static String phoneKey(String phone) {
    if (String.isBlank(phone)) {
      return null;
    }
    String digits = phone.replaceAll('[^0-9]', '');
    return digits.length() > PHONE_MATCH_DIGITS
      ? digits.right(PHONE_MATCH_DIGITS)
      : digits;
  }

  private static Database.DMLOptions truncatingDml() {
    Database.DMLOptions dml = new Database.DMLOptions();
    dml.allowFieldTruncation = true;
    dml.optAllOrNone = true;
    return dml;
  }

  private static String asString(Object raw) {
    return raw == null ? null : String.valueOf(raw);
  }

  private static String firstNonBlank(String primary, String fallback) {
    return String.isNotBlank(primary) ? primary : fallback;
  }

  private static Datetime parseDatetime(Object raw, String label) {
    if (raw == null || String.isBlank(String.valueOf(raw))) {
      return null;
    }
    try {
      return (Datetime) JSON.deserialize(
        '"' + String.valueOf(raw) + '"',
        Datetime.class
      );
    } catch (Exception ex) {
      logs.add('Ignored unparseable ' + label + ' value.');
      return null;
    }
  }

  private static void respondError(
    RestResponse res,
    Integer statusCode,
    String error
  ) {
    logs.add(error);
    respond(res, statusCode, new WebhookResponse());
  }

  private static void respond(
    RestResponse res,
    Integer statusCode,
    WebhookResponse body
  ) {
    body.logs = logs;
    res.statusCode = statusCode;
    res.responseBody = Blob.valueOf(JSON.serialize(body));
  }
}
