/**
 * Tests for the Rudra CallAnchorWebService (Opportunity__c + Task).
 * Uses isolated test records (SeeAllData=false). Org triggers still run.
 */
@IsTest(SeeAllData=false)
private class CallAnchorWebServiceTest {
  private static final String PHONE = '9876501234';
  private static final String STARTED_AT = '2026-09-21T06:00:00Z';

  // Stored on User.Call_Anchor_Phone__c in a different format from the
  // webhook's agentNumber, to prove matching is on the last 10 digits.
  private static final String AGENT_CALL_ANCHOR_PHONE = '+91 93193 00765';
  private static final String AGENT_NUMBER_IN_PAYLOAD = '09319300765';

  // opportunityTrigger dereferences this setting without a null check,
  // and custom setting data is not visible to tests.
  @TestSetup
  static void setup() {
    insert new TriggerControl__c(
      Name = 'OpportunityTrigger',
      isActive__c = false
    );
  }

  private static Map<String, Object> payload(String callId) {
    return new Map<String, Object>{
      'call' => new Map<String, Object>{
        'id' => callId,
        'callType' => 'incoming',
        'agentName' => 'Nobody Here',
        'agentNumber' => '+91 1111100000',
        'startedAt' => STARTED_AT,
        'callerName' => 'Test Customer',
        'callerPhone' => '+91 ' + PHONE,
        'durationSeconds' => 120,
        'recordingUrl' => 'https://example.com/recording.m4a',
        'dispositionLabel' => 'Interested',
        'dispositionNote' => 'Wants a quote'
      }
    };
  }

  private static Map<String, Object> call(Map<String, Object> body) {
    return (Map<String, Object>) body.get('call');
  }

  private static Map<String, Object> postRaw(String jsonBody) {
    RestRequest request = new RestRequest();
    request.requestUri = '/services/apexrest/CallAnchorWebhook/';
    request.httpMethod = 'POST';
    request.requestBody = Blob.valueOf(jsonBody);
    RestContext.request = request;
    RestContext.response = new RestResponse();

    CallAnchorWebService.handleWebhook();

    return (Map<String, Object>) JSON.deserializeUntyped(
      RestContext.response.responseBody.toString()
    );
  }

  private static Map<String, Object> post(Map<String, Object> body) {
    return postRaw(JSON.serialize(body));
  }

  private static void expectOk(Map<String, Object> result) {
    System.assertEquals(
      200,
      RestContext.response.statusCode,
      JSON.serialize(result)
    );
    System.assertEquals(true, result.get('success'), JSON.serialize(result));
  }

  private static void expectPopup(Id agentId, Id opportunityId) {
    Open_Screen_Flow__e popup = CallAnchorWebService.lastPopupEvent;
    System.assertNotEquals(null, popup, 'Expected a popup event');
    System.assertEquals(agentId, popup.Target_User_Id__c);
    System.assertEquals(
      opportunityId,
      popup.Record_Id__c,
      'Popup shows the matched opportunity'
    );
    System.assertEquals('Call_Anchor_Screen_Flow', popup.Flow_Api_Name__c);
  }

  private static Task taskFor(Map<String, Object> result) {
    Id taskId = (Id) result.get('taskId');
    return [
      SELECT
        Id,
        WhatId,
        OwnerId,
        Subject,
        Status,
        ActivityDate,
        Description,
        Call_Anchor_Call_Started_At__c,
        Call_Anchor_Agent_Name__c,
        Call_Anchor_Agent_Mobile__c,
        Call_Anchor_Call_Id__c,
        Call_Anchor_Recording_Url__c,
        Call_Anchor_Call_Type__c,
        Call_Anchor_Disposition__c,
        Call_Anchor_Disposition_Note__c,
        Call_Anchor_Duration_Seconds__c,
        Call_Anchor_Callback_Scheduled_At__c,
        IsReminderSet,
        ReminderDateTime
      FROM Task
      WHERE Id = :taskId
    ];
  }

  private static User agent() {
    return agent(null, true);
  }

  private static User agent(String callAnchorPhone, Boolean active) {
    String unique = String.valueOf(Crypto.getRandomInteger()).replace('-', '');
    User u = new User(
      FirstName = 'Webhook',
      LastName = 'Agent' + unique,
      Email = 'webhook.agent' + unique + '@example.com',
      Username = 'webhook.agent' + unique + '@example.com.test',
      Alias = 'wagent',
      ProfileId = UserInfo.getProfileId(),
      TimeZoneSidKey = 'Asia/Kolkata',
      LocaleSidKey = 'en_IN',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US',
      Call_Anchor_Phone__c = callAnchorPhone,
      IsActive = active
    );
    insert u;
    return [SELECT Id, Name, Email FROM User WHERE Id = :u.Id];
  }

  private static Map<String, Object> callbackDisposition(Datetime callback) {
    return new Map<String, Object>{
      'fields' => new Map<String, Object>{
        'outcome' => 'Call back',
        'scheduled-at' => callback.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'')
      }
    };
  }

  @IsTest
  static void newNumberCreatesOpportunityAndTask() {
    Test.startTest();
    Map<String, Object> result = post(payload('CALL-001'));
    Test.stopTest();

    expectOk(result);
    System.assertEquals(true, result.get('OpportunityCreated'));

    Opportunity__c opp = [SELECT Id, Name, Phone__c FROM Opportunity__c];
    System.assertEquals(opp.Id, result.get('OpportunityId'));
    System.assertEquals('Test Customer', opp.Name);

    Task t = taskFor(result);
    Datetime started = Datetime.newInstanceGmt(2026, 9, 21, 6, 0, 0);
    System.assertEquals(opp.Id, t.WhatId);
    System.assertEquals(
      UserInfo.getUserId(),
      t.OwnerId,
      'Unknown agent falls back to running user'
    );
    System.assertEquals(
      'Incoming Call - Test Customer - +91 ' + PHONE,
      t.Subject
    );
    System.assertEquals('Completed', t.Status);
    System.assertEquals(started, t.Call_Anchor_Call_Started_At__c);
    System.assertEquals(started.date(), t.ActivityDate);
    System.assertEquals('Nobody Here', t.Call_Anchor_Agent_Name__c);
    System.assertEquals('+91 1111100000', t.Call_Anchor_Agent_Mobile__c);
    System.assertEquals('CALL-001', t.Call_Anchor_Call_Id__c);
    System.assertEquals(
      'https://example.com/recording.m4a',
      t.Call_Anchor_Recording_Url__c
    );
    System.assertEquals('Incoming', t.Call_Anchor_Call_Type__c);
    System.assertEquals('Interested', t.Call_Anchor_Disposition__c);
    System.assertEquals('Wants a quote', t.Call_Anchor_Disposition_Note__c);
    System.assertEquals(120, t.Call_Anchor_Duration_Seconds__c);
    System.assert(t.Description.contains('Call ID: CALL-001'), t.Description);
    System.assert(t.Description.contains('Agent: Nobody Here'), t.Description);
    System.assertEquals(
      null,
      CallAnchorWebService.lastPopupEvent,
      'No popup when the agent is unknown'
    );
  }

  @IsTest
  static void existingOpportunityMatchedOnLast10Digits() {
    Opportunity__c existing = new Opportunity__c(
      Name = 'Existing',
      Phone__c = '0' + PHONE
    );
    insert existing;

    Map<String, Object> body = payload('CALL-002');
    call(body).put('callType', 'outgoing');
    call(body).remove('callerPhone');
    call(body).put('calleePhone', PHONE);

    Test.startTest();
    Map<String, Object> result = post(body);
    Test.stopTest();

    expectOk(result);
    System.assertEquals(false, result.get('OpportunityCreated'));
    System.assertEquals(existing.Id, result.get('OpportunityId'));
    System.assertEquals(1, [SELECT COUNT() FROM Opportunity__c]);
    System.assertEquals('Outgoing', taskFor(result).Call_Anchor_Call_Type__c);
  }

  @IsTest
  static void duplicateCallIdReturnsExistingTask() {
    Map<String, Object> first = post(payload('CALL-DUP'));
    expectOk(first);

    Test.startTest();
    Map<String, Object> second = post(payload('CALL-DUP'));
    Test.stopTest();

    expectOk(second);
    System.assertEquals(true, second.get('duplicate'));
    System.assertEquals(first.get('taskId'), second.get('taskId'));
    // Org flows on opportunity__c may add their own Tasks; count call logs only.
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Task WHERE Call_Anchor_Call_Id__c = 'CALL-DUP']
    );
  }

  @IsTest
  static void callAnchorPhoneOwnsTask() {
    User phoneAgent = agent(AGENT_CALL_ANCHOR_PHONE, true);
    User namedAgent = agent();
    Map<String, Object> body = payload('CALL-010');
    call(body).put('agentName', namedAgent.Name);
    call(body).put('agentNumber', AGENT_NUMBER_IN_PAYLOAD);

    Test.startTest();
    Map<String, Object> result = post(body);
    Test.stopTest();

    expectOk(result);
    System.assertEquals(
      phoneAgent.Id,
      taskFor(result).OwnerId,
      'Call Anchor Phone wins over the agent name'
    );
    expectPopup(phoneAgent.Id, (Id) result.get('OpportunityId'));
  }

  @IsTest
  static void callAnchorPhoneOwnsFollowUpTask() {
    User phoneAgent = agent(AGENT_CALL_ANCHOR_PHONE, true);
    Map<String, Object> body = payload('CALL-012');
    call(body).put('agentNumber', AGENT_NUMBER_IN_PAYLOAD);
    body.put('disposition', callbackDisposition(Datetime.now().addDays(1)));

    Test.startTest();
    Map<String, Object> result = post(body);
    Test.stopTest();

    expectOk(result);
    Id followUpId = (Id) result.get('followUpTaskId');
    System.assertNotEquals(null, followUpId, JSON.serialize(result));
    System.assertEquals(phoneAgent.Id, taskFor(result).OwnerId);
    System.assertEquals(
      phoneAgent.Id,
      [SELECT OwnerId FROM Task WHERE Id = :followUpId].OwnerId,
      'Follow-up goes to the same agent as the call log'
    );
  }

  @IsTest
  static void inactiveCallAnchorPhoneUserIsSkipped() {
    agent(AGENT_CALL_ANCHOR_PHONE, false);
    Map<String, Object> body = payload('CALL-013');
    call(body).put('agentNumber', AGENT_NUMBER_IN_PAYLOAD);

    Test.startTest();
    Map<String, Object> result = post(body);
    Test.stopTest();

    expectOk(result);
    System.assertEquals(
      UserInfo.getUserId(),
      taskFor(result).OwnerId,
      'Inactive users are never owners; falls back to the running user'
    );
  }

  @IsTest
  static void shortAgentNumberIsNotMatched() {
    agent('765', true);
    Map<String, Object> body = payload('CALL-014');
    call(body).put('agentNumber', '765');

    Test.startTest();
    Map<String, Object> result = post(body);
    Test.stopTest();

    expectOk(result);
    System.assertEquals(
      UserInfo.getUserId(),
      taskFor(result).OwnerId,
      'Numbers under 10 digits are too ambiguous to match'
    );
  }

  @IsTest
  static void popupShowsMatchedOpportunity() {
    User phoneAgent = agent(AGENT_CALL_ANCHOR_PHONE, true);
    Opportunity__c existing = new Opportunity__c(
      Name = 'Existing',
      Phone__c = '0' + PHONE
    );
    insert existing;

    Map<String, Object> body = payload('CALL-011');
    call(body).put('agentNumber', AGENT_NUMBER_IN_PAYLOAD);

    Test.startTest();
    Map<String, Object> result = post(body);
    Test.stopTest();

    expectOk(result);
    expectPopup(phoneAgent.Id, existing.Id);
    System.assertNotEquals(
      result.get('taskId'),
      CallAnchorWebService.lastPopupEvent.Record_Id__c,
      'Popup shows the opportunity, not the call task'
    );
    System.assertEquals(
      result.get('taskId'),
      CallAnchorWebService.lastPopupEvent.Task_Id__c,
      'Popup passes the call task to the flow'
    );
  }

  @IsTest
  static void resolvedAgentOwnsTask() {
    User agentUser = agent();
    Map<String, Object> body = payload('CALL-003');
    call(body).put('agentName', agentUser.Name);

    Test.startTest();
    Map<String, Object> result = post(body);
    Test.stopTest();

    expectOk(result);
    System.assertEquals(agentUser.Id, taskFor(result).OwnerId);
    expectPopup(agentUser.Id, (Id) result.get('OpportunityId'));
  }

  @IsTest
  static void dispositionFieldsSetCallback() {
    Datetime callback = Datetime.now().addDays(2);
    Map<String, Object> body = payload('CALL-004');
    call(body).remove('dispositionLabel');
    call(body).remove('dispositionNote');
    body.put(
      'disposition',
      new Map<String, Object>{
        'fields' => new Map<String, Object>{
          'outcome' => 'Call back',
          'note' => 'Busy now',
          'scheduled-at' => callback.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'')
        }
      }
    );

    Test.startTest();
    Map<String, Object> result = post(body);
    Test.stopTest();

    expectOk(result);
    Task t = taskFor(result);
    Datetime expected = Datetime.newInstance(callback.getTime() / 1000 * 1000);
    System.assertEquals('Call back', t.Call_Anchor_Disposition__c);
    System.assertEquals('Busy now', t.Call_Anchor_Disposition_Note__c);
    System.assertEquals(expected, t.Call_Anchor_Callback_Scheduled_At__c);
    System.assertEquals('Completed', t.Status);

    Id followUpId = (Id) result.get('followUpTaskId');
    System.assertNotEquals(null, followUpId, JSON.serialize(result));
    Task followUp = [
      SELECT
        WhatId,
        OwnerId,
        Subject,
        Status,
        IsClosed,
        ActivityDate,
        IsReminderSet,
        ReminderDateTime,
        Call_Anchor_Callback_Scheduled_At__c,
        Scheduled_Date_Time__c,
        Description
      FROM Task
      WHERE Id = :followUpId
    ];
    System.assertEquals(t.WhatId, followUp.WhatId);
    System.assertEquals(t.OwnerId, followUp.OwnerId);
    System.assertEquals(
      'Callback - Test Customer - +91 ' + PHONE,
      followUp.Subject
    );
    System.assertEquals(false, followUp.IsClosed);
    System.assertEquals(expected.date(), followUp.ActivityDate);
    System.assertEquals(expected, followUp.Scheduled_Date_Time__c);
    System.assertEquals(
      expected,
      followUp.Call_Anchor_Callback_Scheduled_At__c
    );
    // Set by the org's Set_Reminder_for_Task flow: 15 minutes before the callback
    System.assertEquals(
      true,
      followUp.IsReminderSet,
      'Reminder must stick on the open follow-up'
    );
    Long reminderLeadMs =
      expected.getTime() - followUp.ReminderDateTime.getTime();
    System.assert(
      Math.abs(reminderLeadMs - 15 * 60 * 1000) < 2000,
      'Reminder lead ms: ' + reminderLeadMs
    );
    System.assert(
      followUp.Description.contains('CALL-004'),
      followUp.Description
    );
    System.assert(
      followUp.Description.contains('Busy now'),
      followUp.Description
    );
  }

  @IsTest
  static void noCallbackMeansNoFollowUp() {
    Test.startTest();
    Map<String, Object> result = post(payload('CALL-006'));
    Test.stopTest();

    expectOk(result);
    System.assertEquals(null, result.get('followUpTaskId'));
    // Org flows on opportunity__c may add their own Tasks; count callbacks only.
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE Subject LIKE 'Callback - %']
    );
  }

  @IsTest
  static void missingCallTypeStillSavesTask() {
    Map<String, Object> body = payload('CALL-007');
    call(body).remove('callType');

    Test.startTest();
    Map<String, Object> result = post(body);
    Test.stopTest();

    expectOk(result);
    Task t = taskFor(result);
    System.assertEquals(null, t.Call_Anchor_Call_Type__c);
    System.assertEquals('Call - Test Customer - +91 ' + PHONE, t.Subject);
  }

  @IsTest
  static void callTypeMatchedIgnoringCase() {
    Map<String, Object> body = payload('CALL-008');
    call(body).put('callType', 'MISSED');

    Map<String, Object> result = post(body);
    expectOk(result);
    System.assertEquals('Missed', taskFor(result).Call_Anchor_Call_Type__c);

    Map<String, Object> unknown = payload('CALL-009');
    call(unknown).put('callType', 'voicemail');

    Map<String, Object> unknownResult = post(unknown);
    expectOk(unknownResult);
    System.assertEquals(
      null,
      taskFor(unknownResult).Call_Anchor_Call_Type__c,
      'Unknown types are left blank'
    );
  }

  @IsTest
  static void flatPayloadWithFallbackParsing() {
    Map<String, Object> body = new Map<String, Object>{
      'callType' => 'missed',
      'phone' => PHONE,
      'name' => 'Flat Customer',
      'startedAt' => '2026-09-21 06:00:00',
      'durationSeconds' => 'not a number'
    };

    Test.startTest();
    Map<String, Object> result = post(body);
    Test.stopTest();

    expectOk(result);
    Task t = taskFor(result);
    System.assertEquals('Missed', t.Call_Anchor_Call_Type__c);
    System.assertNotEquals(
      null,
      t.Call_Anchor_Call_Started_At__c,
      'Space-separated datetime should still parse'
    );
    System.assertEquals(
      null,
      t.Call_Anchor_Duration_Seconds__c,
      'Invalid duration is ignored'
    );
  }

  @IsTest
  static void invalidStartedAtDefaultsToToday() {
    Map<String, Object> body = payload(null);
    call(body).put('startedAt', 'yesterday');

    Test.startTest();
    Map<String, Object> result = post(body);
    Test.stopTest();

    expectOk(result);
    Task t = taskFor(result);
    System.assertEquals(Date.today(), t.ActivityDate);
    System.assertEquals(null, t.Call_Anchor_Call_Started_At__c);
  }

  @IsTest
  static void missingPhoneIsRejected() {
    Map<String, Object> body = payload('CALL-005');
    call(body).remove('callerPhone');

    Map<String, Object> result = post(body);

    System.assertEquals(400, RestContext.response.statusCode);
    System.assertEquals(false, result.get('success'));
    System.assertEquals(0, [SELECT COUNT() FROM Task]);
  }

  @IsTest
  static void emptyBodyIsRejected() {
    Map<String, Object> result = postRaw('');
    System.assertEquals(400, RestContext.response.statusCode);
    System.assertEquals(false, result.get('success'));
  }

  @IsTest
  static void invalidJsonReturnsServerError() {
    Map<String, Object> result = postRaw('{not json');
    System.assertEquals(500, RestContext.response.statusCode);
    System.assertEquals(false, result.get('success'));
  }
}
