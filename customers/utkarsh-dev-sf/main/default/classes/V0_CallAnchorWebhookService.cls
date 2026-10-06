@RestResource(urlMapping='/CallAnchorWebhook/*')
global with sharing class V0_CallAnchorWebhookService {
  // ---------- Response wrapper ----------
  global class CallResponse {
    global Boolean success;
    global String message;
    global Id taskId;
    global Id matchedLeadId;
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

  // "disposition": { "fields": {...}, "submittedAt": "..." }
  global class CallPayload {
    public CallData call;
    public String event;
    public Object disposition;
    public Boolean hasRecording;
  }

  @HttpPost
  global static void doPost() {
    //CallResponse resp = new CallResponse();
    //resp.success = false;
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
          // untyped map -> JSON string -> typed CallData (no Object props here, so this is safe)
          payload.call = (CallData) JSON.deserialize(
            JSON.serialize(callRaw),
            CallData.class
          );
        }
        // disposition stays generic (Map<String,Object>) — untyped, no deserialize() needed
        payload.disposition = root.get('disposition');
      } catch (Exception parseEx) {
        res.statusCode = 400;
        res.responseBody = Blob.valueOf('{"error":"malformed payload"}');
        return;
      }

      if (String.isBlank(payload.call.calleePhone)) {
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
      System.debug('ex message' + ex.getMessage());
      res.statusCode = 400;
      res.responseBody = Blob.valueOf('{"error":"malformed payload"}');
      return;
    }

    return;
  }

  global static Task buildTask(CallPayload payloadData) {
    // Normalize the incoming number (strip spaces, dashes, +91 etc.)
    String cleanNumber = payloadData.call.calleePhone.replaceAll('[^0-9]', '');
    if (cleanNumber.length() > 10) {
      cleanNumber = cleanNumber.right(10); // keep last 10 digits
    }
    String likePattern = '%' + cleanNumber + '%';

    try {
      // ---- Step 1: Match against RealtyForce__Ticket__c ----
      List<Lead__c> matchedLeads = [
        SELECT Id, Name, Project__c, Project__r.Name
        FROM Lead__c
        WHERE
          Primary_Mobile__c LIKE :likePattern
          AND Project__r.Name = :payloadData.call.dispositionLabel
      ];

      if (matchedLeads.isEmpty()) {
        return null;
      }

      Lead__c matchedLead = matchedLeads[0];

      // ---- Step 3: Build Subject per disposition convention (BRD 5.2) ----
      String subject = String.isNotBlank(payloadData.call.callType)
        ? 'Call - ' + payloadData.call.callType
        : 'Call Log';

      // ---- Step 4: Create the Task ----
      Task t = new Task();
      t.WhatId = matchedLead.Id;
      t.Subject = subject;
      t.ActivityDate = payloadData.call.startedAt != null
        ? payloadData.call.startedAt.date()
        : Date.today();
      // t.Status          = 'Completed';
      t.recordingUrl__c = payloadData.call.recordingUrl;
      t.Audio_File__c = payloadData.call.recordingUrl;
      Map<String, Object> dispositionObj = (Map<String, Object>) payloadData.disposition;
      Map<String, Object> fields = (Map<String, Object>) dispositionObj
        .get('fields');
      System.debug('### disposition fields: ' + fields);
      System.debug('### outcome: ' + fields.get('outcome'));
      System.debug('### note: ' + fields.get('note'));
      System.debug('### scheduled-at: ' + fields.get('scheduled-at'));
      t.outcome__c = (String) fields.get('outcome');
      t.note__c = (String) fields.get('note');
      t.Call_Disposition__c = payloadData.call.dispositionLabel;
      Object scheduledAtRaw = fields.get('scheduled-at');
      if (scheduledAtRaw != null) {
        String scheduledAtStr = (String) scheduledAtRaw;
        try {
          // ISO8601 string -> Datetime via JSON deserializer
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

      insert t;

      return t;
    } catch (Exception ex) {
      // resp.success = false;
      //resp.message = 'Error while logging call: ' + ex.getMessage();
    }

    return null;
  }
}
