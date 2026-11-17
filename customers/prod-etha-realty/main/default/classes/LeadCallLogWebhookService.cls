/**
 * REST Webhook endpoint: /services/apexrest/LeadCallLogWebhook/
 *
 * Receives call event payloads from an external calling platform, matches the
 * "calleePhone" against Lead__c.Mobile__c. If a match is found, a
 * Lead_Call_Log__c is created against that Lead. If NO match is found, a new
 * Lead__c is auto-created from the call data first, and the Lead_Call_Log__c
 * is then linked to that newly created Lead.
 *
 * Response contract:
 * {
 *   "success": true|false,
 *   "message": "success" | "<error / exception detail>",
 *   "salesforceRecordId": "<Lead_Call_Log__c Id>" | null
 * }
 */
@RestResource(urlMapping='/LeadCallLogWebhook/*')
global with sharing class LeadCallLogWebhookService {
  // ---------- Response wrapper ----------
  global class WebhookResponse {
    global Boolean success;
    global String message;
    global Id salesforceRecordId;

    global WebhookResponse(Boolean success, String message, Id recordId) {
      this.success = success;
      this.message = message;
      this.salesforceRecordId = recordId;
    }
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
    public String calleePhone;
    public String recordingUrl;
    public String dispositionNote;
    public Integer durationSeconds;
    public String dispositionLabel;
    public Datetime dispositionScheduledAt;
  }

  @HttpPost
  global static void doPost() {
    RestResponse res = RestContext.response;
    res.addHeader('Content-Type', 'application/json');

    WebhookResponse wrapperResp;

    try {
      RestRequest req = RestContext.request;

      if (
        req == null ||
        req.requestBody == null ||
        req.requestBody.size() == 0
      ) {
        res.statusCode = 400;
        wrapperResp = new WebhookResponse(false, 'Empty request body.', null);
        res.responseBody = Blob.valueOf(JSON.serialize(wrapperResp));
        return;
      }

      CallPayload payload;
      Map<String, Object> root;

      try {
        root = (Map<String, Object>) JSON.deserializeUntyped(
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
        payload.disposition = root.get('disposition');
      } catch (Exception parseEx) {
        res.statusCode = 400;
        wrapperResp = new WebhookResponse(
          false,
          'Malformed payload: ' + parseEx.getMessage(),
          null
        );
        res.responseBody = Blob.valueOf(JSON.serialize(wrapperResp));
        return;
      }

      if (payload.call == null || String.isBlank(payload.call.calleePhone)) {
        res.statusCode = 400;
        wrapperResp = new WebhookResponse(
          false,
          'calleePhone is required.',
          null
        );
        res.responseBody = Blob.valueOf(JSON.serialize(wrapperResp));
        return;
      }

      // processCall now always returns a record (existing or newly created lead)
      Lead_Call_Log__c logRecord = processCall(payload);

      res.statusCode = 200;
      wrapperResp = new WebhookResponse(true, 'success', logRecord.Id);
    } catch (Exception ex) {
      res.statusCode = 500;
      wrapperResp = new WebhookResponse(
        false,
        'Exception: ' + ex.getMessage(),
        null
      );
    }

    res.responseBody = Blob.valueOf(JSON.serialize(wrapperResp));
  }

  /**
   * Matches the Lead by phone (last 10 digits). If no match is found, a new
   * Lead__c is created from the call data first. Either way, a
   * Lead_Call_Log__c is inserted and linked to that Lead.
   */
  global static Lead_Call_Log__c processCall(CallPayload payloadData) {
    // Normalize incoming number: strip non-digits, keep last 10 digits
    String cleanNumber = payloadData.call.calleePhone.replaceAll('[^0-9]', '');
    if (cleanNumber.length() > 10) {
      cleanNumber = cleanNumber.right(10);
    }
    String likePattern = '%' + cleanNumber + '%';

    List<Lead__c> matchedLeads = [
      SELECT Id, Name
      FROM Lead__c
      WHERE Mobile__c LIKE :likePattern
      LIMIT 1
    ];

    Lead__c matchedLead;

    if (!matchedLeads.isEmpty()) {
      matchedLead = matchedLeads[0];
    } else {
      // No existing Lead — create one from the call data
      String leadName = String.isNotBlank(payloadData.call.calleeName) &&
        payloadData.call.calleeName != 'Unknown'
        ? payloadData.call.calleeName
        : 'Unknown Caller - ' + cleanNumber;

      matchedLead = new Lead__c();
      matchedLead.First_Name__c = 'Unknown';
      matchedLead.Last_Name__c = 'Caller';
      matchedLead.Mobile__c = payloadData.call.calleePhone;
      matchedLead.Lead_Source__c = 'App';
      matchedLead.Sub_Source__c = 'CTI';
      insert matchedLead;
    }

    Map<String, Object> dispositionMap = payloadData.disposition != null
      ? (Map<String, Object>) payloadData.disposition
      : new Map<String, Object>();
    Map<String, Object> fields = dispositionMap.get('fields') != null
      ? (Map<String, Object>) dispositionMap.get('fields')
      : new Map<String, Object>();
    String submittedAtRaw = (String) dispositionMap.get('submittedAt');

    Lead_Call_Log__c logRec = new Lead_Call_Log__c();
    logRec.Lead__c = matchedLead.Id;
    logRec.Call_Id__c = payloadData.call.id;
    logRec.Call_Type__c = payloadData.call.callType;
    logRec.Agent_Name__c = payloadData.call.agentName;
    logRec.Started_At__c = payloadData.call.startedAt;
    logRec.Callee_Name__c = payloadData.call.calleeName;
    logRec.Callee_Phone__c = payloadData.call.calleePhone;
    logRec.Recording_URL__c = payloadData.call.recordingUrl;
    logRec.Disposition_Note__c = payloadData.call.dispositionNote;
    logRec.Duration_Seconds__c = payloadData.call.durationSeconds;
    logRec.Disposition_Label__c = payloadData.call.dispositionLabel;
    logRec.Disposition_Scheduled_At__c = payloadData.call.dispositionScheduledAt;
    logRec.Event__c = payloadData.event;
    logRec.Has_Recording__c = payloadData.hasRecording;
    logRec.Outcome__c = (String) fields.get('outcome');
    logRec.Note__c = (String) fields.get('note');

    Object scheduledAtRaw = fields.get('scheduled-at');
    if (scheduledAtRaw != null) {
      try {
        logRec.Scheduled_At__c = (Datetime) JSON.deserialize(
          '"' + (String) scheduledAtRaw + '"',
          Datetime.class
        );
      } catch (Exception ex) {
        System.debug(
          LoggingLevel.WARN,
          'Could not parse scheduled-at: ' + scheduledAtRaw
        );
      }
    }

    if (String.isNotBlank(submittedAtRaw)) {
      try {
        logRec.Submitted_At__c = (Datetime) JSON.deserialize(
          '"' + submittedAtRaw + '"',
          Datetime.class
        );
      } catch (Exception ex) {
        System.debug(
          LoggingLevel.WARN,
          'Could not parse submittedAt: ' + submittedAtRaw
        );
      }
    }

    insert logRec;
    return logRec;
  }
}
