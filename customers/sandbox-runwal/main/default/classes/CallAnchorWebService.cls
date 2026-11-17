/**
Runwal Realty - 360 Call Anchor webhook. API version 60.0 or later.

Logs each call as a Task on every Applicant matching the callee's mobile
number, and on each distinct Booking those Applicants belong to.

RECORDING FILES - CallAnchorRecordingLinker + CallAnchorFileLinkTrigger
(deploy together with this class):
  This class does NOT download or store recordings; it only saves
  recordingUrl on the Tasks. The Call Anchor app uploads the recording File
  itself, seconds after this webhook returns, and attaches it to one Task.
  CallAnchorFileLinkTrigger (on ContentDocumentLink) then links that same
  File to every Task with the same Call_Anchor_Call_Id__c - one stored copy
  shown on each Applicant and Booking Task.
  - After saving, this class also calls
    CallAnchorRecordingLinker.linkCallRecordings() so Tasks created after the
    upload (re-sent webhook, newly matched Applicant) get the existing File.
  - Call_Anchor_Call_Id__c is the key that ties a call's Tasks together;
    changing how it is written breaks recording sharing.
  - The response keeps applicantTaskId / bookingTaskId / activityId for the
    Call Anchor app; do not remove them without checking with Call Anchor.
 */
@RestResource(urlMapping='/CallAnchorWebhook/*')
global with sharing class CallAnchorWebService {
  private class InputException extends Exception {
  }
  private class ConflictException extends Exception {
  }

  @HttpPost
  global static void receiveCall() {
    Savepoint sp;
    try {
      if (RestContext.request.requestBody == null) {
        throw new InputException('JSON request body is required.');
      }
      Map<String, Object> root;
      try {
        root = (Map<String, Object>) JSON.deserializeUntyped(
          RestContext.request.requestBody.toString()
        );
      } catch (Exception ex) {
        throw new InputException('Request body must be a JSON object.');
      }
      if (root == null)
        throw new InputException('JSON object is required.');
      String eventName = stringValue(root.get('event'), 'event');
      if (
        !String.isBlank(eventName) &&
        eventName != 'call.completed' &&
        eventName != 'recording.ready'
      ) {
        respond(
          200,
          new Map<String, Object>{
            'status' => 'ignored',
            'reason' => 'Unsupported event',
            'event' => eventName
          }
        );
        return;
      }
      Map<String, Object> callData;
      try {
        callData = (Map<String, Object>) root.get('call');
      } catch (Exception ex) {
        throw new InputException('call must be a JSON object.');
      }
      if (callData == null)
        throw new InputException('call is required.');
      String callId = requiredString(callData, 'id');
      if (callId.length() > 100)
        throw new InputException('call.id exceeds 100 characters.');
      String callType = requiredString(callData, 'callType');
      if (
        !new Set<String>{ 'Incoming', 'Outgoing', 'Missed', 'Rejected' }
          .contains(callType)
      ) {
        throw new InputException('Unsupported call.callType.');
      }
      String phone = normalizePhone(requiredString(callData, 'calleePhone'));
      if (phone.length() < 7 || phone.length() > 15) {
        throw new InputException(
          'call.calleePhone must contain 7 to 15 digits after normalization.'
        );
      }
      // Digit subsequence retrieves formatted candidates; exact normalized
      // comparison below prevents false matches from the permissive LIKE.
      String phonePattern = '%';
      for (Integer i = 0; i < phone.length(); i++) {
        phonePattern += phone.substring(i, i + 1) + '%';
      }
      List<Applicant_Details__c> candidates = [
        SELECT Id, Booking__c, Mobile_Number__c
        FROM Applicant_Details__c
        WHERE Mobile_Number__c LIKE :phonePattern
        WITH USER_MODE
        LIMIT 201
      ];
      if (candidates.size() > 200) {
        throw new ConflictException(
          'Too many phone candidates; use an indexed normalized mobile field.'
        );
      }
      List<Applicant_Details__c> matches = new List<Applicant_Details__c>();
      for (Applicant_Details__c candidate : candidates) {
        if (normalizePhone(candidate.Mobile_Number__c) == phone)
          matches.add(candidate);
      }
      if (matches.isEmpty()) {
        respond(
          200,
          new Map<String, Object>{
            'status' => 'ignored',
            'reason' => 'No matching Applicant',
            'callId' => callId,
            'tasksCreated' => 0
          }
        );
        return;
      }
      // A mobile number can legitimately belong to several Applicants (e.g. the
      // same buyer on multiple Bookings); the call is logged against each.
      Set<Id> applicantIds = new Set<Id>();
      for (Applicant_Details__c match : matches)
        applicantIds.add(match.Id);
      // This is only a lock/recheck on already user-mode-authorized rows.
      List<Applicant_Details__c> locked = [
        SELECT Id, Booking__c, Mobile_Number__c
        FROM Applicant_Details__c
        WHERE Id IN :applicantIds
        FOR UPDATE
      ];
      if (locked.size() != applicantIds.size()) {
        throw new ConflictException(
          'Applicant changed during processing. Retry the webhook.'
        );
      }
      Set<Id> bookingIds = new Set<Id>();
      for (Applicant_Details__c applicant : locked) {
        if (normalizePhone(applicant.Mobile_Number__c) != phone) {
          throw new ConflictException(
            'Applicant changed during processing. Retry the webhook.'
          );
        }
        // Applicants without a Booking are still logged; only linked
        // Bookings receive their own Task.
        if (applicant.Booking__c != null)
          bookingIds.add(applicant.Booking__c);
      }
      if (!bookingIds.isEmpty()) {
        List<Booking__c> bookings = [
          SELECT Id
          FROM Booking__c
          WHERE Id IN :bookingIds
          WITH USER_MODE
        ];
        if (bookings.size() != bookingIds.size())
          throw new ConflictException('Parent Booking is not accessible.');
      }

      // Applicants first, then each distinct Booking once (co-applicants on
      // the same Booking share a single Booking Task).
      List<Id> relatedIds = new List<Id>(applicantIds);
      relatedIds.addAll(bookingIds);
      Integer existingLimit = relatedIds.size() + 1;
      Map<Id, Id> existingIds = new Map<Id, Id>();
      // ALL ROWS includes archived Tasks; deleted Tasks are explicitly excluded.
      for (Task previous : [
        SELECT Id, WhatId
        FROM Task
        WHERE
          Call_Anchor_Call_Id__c = :callId
          AND WhatId IN :relatedIds
          AND IsDeleted = FALSE
        WITH USER_MODE
        LIMIT :existingLimit
        ALL ROWS
      ]) {
        if (existingIds.containsKey(previous.WhatId)) {
          throw new ConflictException(
            'Duplicate existing Tasks for this call and record. Resolve duplicates first.'
          );
        }
        existingIds.put(previous.WhatId, previous.Id);
      }
      List<TaskStatus> closedStatuses = [
        SELECT ApiName
        FROM TaskStatus
        WHERE IsClosed = TRUE
        ORDER BY SortOrder
        LIMIT 1
      ];
      if (closedStatuses.isEmpty())
        throw new ConflictException('No closed Task status is configured.');

      // Parse the payload once; every Task is cloned from this template so all
      // of them reference the identical recording rather than separate copies.
      Task template = new Task(
        Subject = 'Call Anchor - ' + callType + ' Call',
        Status = closedStatuses[0].ApiName,
        Call_Anchor_Call_Id__c = callId,
        Call_Anchor_Call_Type__c = callType
      );
      mapText(template, callData, 'agentNumber', 'Call_Anchor_Agent_Mobile__c');
      mapText(template, callData, 'agentName', 'Call_Anchor_Agent_Name__c');
      mapText(
        template,
        callData,
        'dispositionNote',
        'Call_Anchor_Disposition_Note__c'
      );
      mapText(
        template,
        callData,
        'dispositionLabel',
        'Call_Anchor_Disposition__c'
      );
      mapText(
        template,
        callData,
        'recordingUrl',
        'Call_Anchor_Recording_Url__c'
      );
      mapDate(
        template,
        callData,
        'startedAt',
        'Call_Anchor_Call_Started_At__c'
      );
      mapDate(
        template,
        callData,
        'dispositionScheduledAt',
        'Call_Anchor_Callback_Scheduled_At__c'
      );
      if (callData.containsKey('durationSeconds')) {
        Object raw = callData.get('durationSeconds');
        Decimal duration;
        if (raw != null) {
          try {
            duration = Decimal.valueOf(String.valueOf(raw));
          } catch (Exception ex) {
            throw new InputException(
              'durationSeconds must be a non-negative integer.'
            );
          }
          if (
            duration < 0 ||
            duration > 9999999999L ||
            duration != duration.setScale(0)
          ) {
            throw new InputException(
              'durationSeconds must be an integer from 0 to 9999999999.'
            );
          }
        }
        template.Call_Anchor_Duration_Seconds__c = duration;
      }

      List<Task> inserts = new List<Task>();
      List<Task> updates = new List<Task>();
      List<Task> results = new List<Task>();
      for (Id relatedId : relatedIds) {
        Task activity = template.clone(false);
        activity.WhatId = relatedId;
        if (existingIds.containsKey(relatedId)) {
          activity.Id = existingIds.get(relatedId);
        } else {
          activity.OwnerId = UserInfo.getUserId();
          activity.TaskSubtype = 'Call';
        }
        results.add(activity);
        if (activity.Id == null)
          inserts.add(activity);
        else
          updates.add(activity);
      }
      sp = Database.setSavepoint();
      if (!inserts.isEmpty())
        insert as user inserts;
      if (!updates.isEmpty())
        update as user updates;
      // A recording the Call Anchor app already uploaded for this call (e.g.
      // on a re-sent webhook) is linked to Tasks created now. New uploads are
      // shared by CallAnchorFileLinkTrigger. See CallAnchorRecordingLinker.
      // Sharing failures must not lose the call log: the Tasks are kept and
      // the trigger links the File when the app uploads or re-attaches it.
      Integer recordingLinksCreated = 0;
      try {
        recordingLinksCreated = CallAnchorRecordingLinker.linkCallRecordings(
          new Map<Id, Task>(results).keySet()
        );
      } catch (Exception ex) {
        System.debug(
          LoggingLevel.ERROR,
          'Call Anchor recording linking failed: ' + ex.getTypeName()
        );
      }

      Map<Id, Id> taskIds = new Map<Id, Id>();
      for (Task activity : results)
        taskIds.put(activity.WhatId, activity.Id);
      // results lists Applicant Tasks first, then Booking Tasks. The single-id
      // keys keep the response compatible with the original integration
      // (applicantTaskId / bookingTaskId) and other orgs (activityId).
      Id applicantTaskId = results[0].Id;
      Id bookingTaskId = bookingIds.isEmpty()
        ? null
        : results[applicantIds.size()].Id;
      respond(
        200,
        new Map<String, Object>{
          'status' => 'success',
          'callId' => callId,
          'activityId' => applicantTaskId,
          'applicantId' => results[0].WhatId,
          'applicantTaskId' => applicantTaskId,
          'bookingId' => bookingIds.isEmpty()
            ? null
            : results[applicantIds.size()].WhatId,
          'bookingTaskId' => bookingTaskId,
          'applicantIds' => applicantIds,
          'bookingIds' => bookingIds,
          'taskIds' => taskIds,
          'tasksCreated' => inserts.size(),
          'tasksUpdated' => updates.size(),
          'recordingLinksCreated' => recordingLinksCreated
        }
      );
    } catch (InputException ex) {
      if (sp != null)
        Database.rollback(sp);
      respond(
        400,
        new Map<String, Object>{
          'status' => 'error',
          'message' => ex.getMessage()
        }
      );
    } catch (ConflictException ex) {
      if (sp != null)
        Database.rollback(sp);
      respond(
        409,
        new Map<String, Object>{
          'status' => 'error',
          'message' => ex.getMessage()
        }
      );
    } catch (Exception ex) {
      if (sp != null)
        Database.rollback(sp);
      // Do not echo payloads, phone numbers or signed recording URLs in errors.
      respond(
        500,
        new Map<String, Object>{
          'status' => 'error',
          'message' => 'No Tasks were committed. Check integration-user permissions, validation rules, field configuration and record locks.',
          'errorType' => ex.getTypeName()
        }
      );
    }
  }

  private static String stringValue(Object value, String key) {
    if (value == null)
      return null;
    if (!(value instanceof String))
      throw new InputException(key + ' must be a string or null.');
    return (String) value;
  }
  private static String requiredString(Map<String, Object> data, String key) {
    String value = stringValue(data.get(key), 'call.' + key);
    if (String.isBlank(value))
      throw new InputException('call.' + key + ' is required.');
    return value.trim();
  }
  private static String normalizePhone(String value) {
    if (String.isBlank(value))
      return '';
    String digits = value.replaceAll('[^0-9]', '');
    if (digits.startsWith('00'))
      digits = digits.substring(2);
    if (digits.length() == 12 && digits.startsWith('91'))
      digits = digits.substring(2);
    if (digits.length() == 11 && digits.startsWith('0'))
      digits = digits.substring(1);
    return digits;
  }
  private static void mapText(
    Task activity,
    Map<String, Object> data,
    String key,
    String fieldName
  ) {
    if (!data.containsKey(key))
      return;
    String value = stringValue(data.get(key), 'call.' + key);
    Integer maxLength = Schema.SObjectType.Task.fields.getMap()
      .get(fieldName)
      .getDescribe()
      .getLength();
    if (value != null && value.length() > maxLength) {
      throw new InputException(
        'call.' +
          key +
          ' exceeds ' +
          fieldName +
          ' limit of ' +
          maxLength +
          ' characters.'
      );
    }
    activity.put(fieldName, value);
  }
  private static void mapDate(
    Task activity,
    Map<String, Object> data,
    String key,
    String fieldName
  ) {
    if (!data.containsKey(key))
      return;
    String value = stringValue(data.get(key), 'call.' + key);
    Datetime parsed;
    if (!String.isBlank(value)) {
      // Require a timezone; never reinterpret a portal UTC timestamp as local time.
      if (!Pattern.matches('.*(Z|[+-][0-9]{2}:[0-9]{2})$', value)) {
        throw new InputException(
          'call.' + key + ' must be ISO 8601 with Z or a timezone offset.'
        );
      }
      try {
        parsed = (Datetime) JSON.deserialize(
          JSON.serialize(value),
          Datetime.class
        );
      } catch (Exception ex) {
        throw new InputException('Invalid date/time in call.' + key + '.');
      }
    }
    activity.put(fieldName, parsed);
  }
  private static void respond(Integer statusCode, Map<String, Object> body) {
    RestContext.response.statusCode = statusCode;
    RestContext.response.addHeader('Content-Type', 'application/json');
    RestContext.response.responseBody = Blob.valueOf(JSON.serialize(body));
  }
}
