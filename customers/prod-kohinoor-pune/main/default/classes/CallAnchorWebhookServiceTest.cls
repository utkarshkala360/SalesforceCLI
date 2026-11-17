@IsTest
private class CallAnchorWebhookServiceTest {
  private static final String PHONE = '9876501234';
  private static final String PROJECT_A = 'Call Anchor Test Project A';
  private static final String PROJECT_B = 'Call Anchor Test Project B';
  private static final String AGENT_EMAIL = 'call.anchor.agent@kohinoor.test';
  private static final String AGENT_PHONE = '9000000001';
  private static final String OTHER_PHONE = '9000000002';

  // The webhook runs in user mode, so it runs as a user with the Call_Anchor_Webhook
  // permission set (field access to the Call Anchor Task and Sales Task fields). That user is also the
  // agent who owns the Opportunities; the other agent owns none.
  @TestSetup
  static void setup() {
    User agent = user(AGENT_EMAIL, 'caagent', '+91 90000-00001');
    User other = user(
      'call.anchor.other@kohinoor.test',
      'caother',
      OTHER_PHONE
    );
    User inactive = user(
      'call.anchor.inactive@kohinoor.test',
      'cainact',
      '9000000003'
    );
    inactive.IsActive = false;
    insert new List<User>{ agent, other, inactive };
    insert new PermissionSetAssignment(
      AssigneeId = agent.Id,
      PermissionSetId = [
        SELECT Id
        FROM PermissionSet
        WHERE Name = 'Call_Anchor_Webhook'
      ]
      .Id
    );

    System.runAs(agent) {
      Ud_Project__c projectA = project(PROJECT_A);
      Ud_Project__c projectB = project(PROJECT_B);
      insert new List<Ud_Project__c>{ projectA, projectB };

      Opportunity older = opportunity('Older', projectA.Id);
      Opportunity newer = opportunity('Newer', projectB.Id);
      insert new List<Opportunity>{ older, newer };
      Test.setCreatedDate(older.Id, Datetime.now().addDays(-10));
      Test.setCreatedDate(newer.Id, Datetime.now().addDays(-1));
    }
  }

  @IsTest
  static void projectNameSelectsMatchingOpportunity() {
    Map<String, Object> payload = callPayload('Outgoing');
    fields(payload).put('project-name', PROJECT_A.toLowerCase());

    Test.startTest();
    RestResponse res = post(payload);
    Test.stopTest();

    Map<String, Object> result = body(res);
    System.assertEquals(201, res.statusCode, res.responseBody.toString());
    Id activityId = (Id) result.get('activityId');
    Id salesTaskId = (Id) result.get('salesTaskId');
    System.assertEquals(opportunityId('Older'), result.get('opportunityId'));

    Id agentId = [SELECT Id FROM User WHERE Email = :AGENT_EMAIL].Id;
    Task call = [
      SELECT
        WhatId,
        OwnerId,
        RecordType.DeveloperName,
        Status,
        Subject,
        Call_Anchor_Call_Id__c,
        Call_Anchor_Duration_Seconds__c,
        Call_Anchor_Disposition__c,
        CallDisposition
      FROM Task
      WHERE Id = :activityId
    ];
    System.assertEquals(opportunityId('Older'), call.WhatId);
    System.assertEquals(agentId, call.OwnerId);
    System.assertEquals(
      agentId,
      [SELECT OwnerId FROM Sales_Task__c WHERE Id = :salesTaskId].OwnerId
    );
    System.assertEquals('Ud_Sales', call.RecordType.DeveloperName);
    System.assertEquals('Completed', call.Status);
    System.assertEquals('Call - Outgoing', call.Subject);
    System.assertEquals('CALL-001', call.Call_Anchor_Call_Id__c);
    System.assertEquals(125, call.Call_Anchor_Duration_Seconds__c);
    // No task-subject in the payload: Disposition stays blank rather than taking the call-type default.
    System.assertEquals(null, call.Call_Anchor_Disposition__c);
    System.assertEquals('No action needed', call.CallDisposition);

    Sales_Task__c salesTask = [
      SELECT
        Opportunity__c,
        Task_Subject__c,
        Communication_Type__c,
        Task_Status__c,
        Call_Meeting_Status__c,
        Priority__c,
        Next_Action_Status__c,
        Task_Date__c,
        Task_Time__c,
        Next_Action_Date__c,
        Next_Action_time__c,
        Comments__c,
        Call_Anchor_Comments_Detailed__c,
        Call_Anchor_Call_Id__c,
        Call_Anchor_Call_Type__c,
        Call_Anchor_Duration_Seconds__c,
        Call_Anchor_Agent_Name__c,
        Call_Anchor_Disposition_Note__c,
        Call_Anchor_Callback_Scheduled_At__c,
        Call_Anchor_Raw_Payload__c
      FROM Sales_Task__c
      WHERE Id = :salesTaskId
    ];
    System.assertEquals(
      'Customer wants a site visit next week',
      salesTask.Comments__c
    );
    System.assertEquals(
      'Customer wants a site visit next week',
      salesTask.Call_Anchor_Comments_Detailed__c
    );
    Datetime scheduledAt = (Datetime) JSON.deserialize(
      '"' + scheduledAt() + '"',
      Datetime.class
    );
    System.assertEquals(opportunityId('Older'), salesTask.Opportunity__c);
    System.assertEquals('Outbound Call', salesTask.Task_Subject__c);
    System.assertEquals('Outbound Call', salesTask.Communication_Type__c);
    System.assertEquals('Completed', salesTask.Task_Status__c);
    System.assertEquals('Not Connected', salesTask.Call_Meeting_Status__c);
    System.assertEquals('High', salesTask.Priority__c);
    System.assertEquals('No action needed', salesTask.Next_Action_Status__c);
    // No action needed: dated at the scheduled-at, with no next action.
    System.assertEquals(
      Date.valueOf(scheduledAt.format('yyyy-MM-dd', 'Asia/Kolkata')),
      salesTask.Task_Date__c
    );
    System.assertEquals(
      scheduledAt.format('HH:mm', 'Asia/Kolkata'),
      hhmm(salesTask.Task_Time__c)
    );
    System.assertEquals(null, salesTask.Next_Action_Date__c);
    System.assertEquals(null, salesTask.Next_Action_time__c);
    System.assertEquals(1, [SELECT COUNT() FROM Sales_Task__c]);

    System.assertEquals('CALL-001', salesTask.Call_Anchor_Call_Id__c);
    System.assertEquals('Outgoing', salesTask.Call_Anchor_Call_Type__c);
    System.assertEquals(125, salesTask.Call_Anchor_Duration_Seconds__c);
    System.assertEquals('Agent Smith', salesTask.Call_Anchor_Agent_Name__c);
    System.assertEquals(
      'Asked for a callback',
      salesTask.Call_Anchor_Disposition_Note__c
    );
    System.assertEquals(
      scheduledAt.formatGmt('yyyy-MM-dd HH:mm'),
      salesTask.Call_Anchor_Callback_Scheduled_At__c.formatGmt(
        'yyyy-MM-dd HH:mm'
      )
    );
    System.assert(
      salesTask.Call_Anchor_Raw_Payload__c.contains('"CALL-001"'),
      salesTask.Call_Anchor_Raw_Payload__c
    );
  }

  @IsTest
  static void longNoteIsShortenedInCommentsAndKeptInFullInDetailed() {
    String note = 'Customer asked about floor plans. '.repeat(10).trim();
    Map<String, Object> payload = callPayload('Outgoing');
    fields(payload).put('note', note);

    RestResponse res = post(payload);

    System.assertEquals(201, res.statusCode, res.responseBody.toString());
    Id salesTaskId = (Id) body(res).get('salesTaskId');
    Sales_Task__c salesTask = [
      SELECT Comments__c, Call_Anchor_Comments_Detailed__c
      FROM Sales_Task__c
      WHERE Id = :salesTaskId
    ];
    System.assert(note.length() > 255);
    System.assertEquals(255, salesTask.Comments__c.length());
    System.assertEquals(note.left(249) + '......', salesTask.Comments__c);
    System.assertEquals(note, salesTask.Call_Anchor_Comments_Detailed__c);
  }

  @IsTest
  static void longDispositionNoteIsShortenedOnTaskAndSalesTask() {
    String note = 'Client is still finding the price of 78 lakhs to 79 lakhs high. '
      .repeat(5)
      .trim();
    Map<String, Object> payload = callPayload('Outgoing');
    call(payload).put('dispositionNote', note);

    RestResponse res = post(payload);

    System.assertEquals(201, res.statusCode, res.responseBody.toString());
    Id activityId = (Id) body(res).get('activityId');
    Id salesTaskId = (Id) body(res).get('salesTaskId');
    String expected = note.left(249) + '......';
    System.assertEquals(
      expected,
      [SELECT Call_Anchor_Disposition_Note__c FROM Task WHERE Id = :activityId]
      .Call_Anchor_Disposition_Note__c
    );
    System.assertEquals(
      expected,
      [
        SELECT Call_Anchor_Disposition_Note__c
        FROM Sales_Task__c
        WHERE Id = :salesTaskId
      ]
      .Call_Anchor_Disposition_Note__c
    );
  }

  @IsTest
  static void shortCommentsFitsOnlyWhenNeeded() {
    System.assertEquals(null, CallAnchorWebhookService.shortComments('   '));
    System.assertEquals(
      'a'.repeat(255),
      CallAnchorWebhookService.shortComments(' ' + 'a'.repeat(255) + ' ')
    );
    System.assertEquals(
      'a'.repeat(249) + '......',
      CallAnchorWebhookService.shortComments('a'.repeat(256))
    );
  }

  @IsTest
  static void nextActionDatesCompletedTaskNowAndTriggerOpensFollowUp() {
    Map<String, Object> payload = callPayload('Outgoing');
    fields(payload).put('next-action-status', 'follow-up');

    Datetime before = Datetime.now();
    RestResponse res = post(payload);

    System.assertEquals(201, res.statusCode, res.responseBody.toString());
    Id salesTaskId = (Id) body(res).get('salesTaskId');
    Datetime scheduledAt = (Datetime) JSON.deserialize(
      '"' + scheduledAt() + '"',
      Datetime.class
    );

    Sales_Task__c completed = [
      SELECT
        Task_Status__c,
        Task_Date__c,
        Task_Time__c,
        Next_Action_Status__c,
        Next_Action_Date__c,
        Next_Action_time__c
      FROM Sales_Task__c
      WHERE Id = :salesTaskId
    ];
    System.assertEquals('Completed', completed.Task_Status__c);
    System.assertEquals('Follow Up', completed.Next_Action_Status__c);
    System.assertEquals(
      Date.valueOf(before.format('yyyy-MM-dd', 'Asia/Kolkata')),
      completed.Task_Date__c
    );
    assertNear(before, completed.Task_Time__c);
    System.assertEquals(
      Date.valueOf(scheduledAt.format('yyyy-MM-dd', 'Asia/Kolkata')),
      completed.Next_Action_Date__c
    );
    System.assertEquals(
      scheduledAt.format('HH:mm', 'Asia/Kolkata'),
      hhmm(completed.Next_Action_time__c)
    );

    // SalesTaskTrigger, not the webhook, creates the Open follow-up at the next action.
    List<Sales_Task__c> open = [
      SELECT Task_Subject__c, Task_Date__c, Task_Time__c, Opportunity__c
      FROM Sales_Task__c
      WHERE Id != :salesTaskId
    ];
    System.assertEquals(1, open.size());
    System.assertEquals('Follow Up', open[0].Task_Subject__c);
    System.assertEquals(completed.Next_Action_Date__c, open[0].Task_Date__c);
    System.assertEquals(completed.Next_Action_time__c, open[0].Task_Time__c);
    System.assertEquals(opportunityId('Newer'), open[0].Opportunity__c);
  }

  @IsTest
  static void missingNextActionStatusIsTreatedAsAnAction() {
    Map<String, Object> payload = callPayload('Outgoing');
    fields(payload).remove('next-action-status');

    Datetime before = Datetime.now();
    RestResponse res = post(payload);

    System.assertEquals(201, res.statusCode, res.responseBody.toString());
    Id salesTaskId = (Id) body(res).get('salesTaskId');
    Sales_Task__c salesTask = [
      SELECT
        Task_Status__c,
        Task_Date__c,
        Next_Action_Status__c,
        Next_Action_Date__c,
        Next_Action_time__c
      FROM Sales_Task__c
      WHERE Id = :salesTaskId
    ];
    Datetime scheduledAt = (Datetime) JSON.deserialize(
      '"' + scheduledAt() + '"',
      Datetime.class
    );
    System.assertEquals('Completed', salesTask.Task_Status__c);
    System.assertEquals(
      Date.valueOf(before.format('yyyy-MM-dd', 'Asia/Kolkata')),
      salesTask.Task_Date__c
    );
    System.assertEquals(
      Date.valueOf(scheduledAt.format('yyyy-MM-dd', 'Asia/Kolkata')),
      salesTask.Next_Action_Date__c
    );
    System.assertNotEquals(null, salesTask.Next_Action_time__c);
    // With no Next Action Status the trigger has nothing to schedule.
    System.assertEquals(null, salesTask.Next_Action_Status__c);
    System.assertEquals(1, [SELECT COUNT() FROM Sales_Task__c]);
  }

  @IsTest
  static void pastNextActionIsRejectedByTriggerAndRolledBack() {
    Map<String, Object> payload = callPayload('Outgoing');
    fields(payload).put('next-action-status', 'follow-up');
    call(payload)
      .put(
        'dispositionScheduledAt',
        Datetime.now().addDays(-2).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'')
      );

    RestResponse res = post(payload);

    System.assertEquals(422, res.statusCode, res.responseBody.toString());
    System.assertEquals('SAVE_FAILED', errorCode(res));
    System.assertEquals(0, [SELECT COUNT() FROM Sales_Task__c]);
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE Call_Anchor_Call_Id__c = 'CALL-001']
    );
  }

  @IsTest
  static void withoutProjectNameUsesLatestOpportunity() {
    Test.startTest();
    RestResponse res = post(callPayload('Incoming'));
    Test.stopTest();

    Map<String, Object> result = body(res);
    System.assertEquals(201, res.statusCode, res.responseBody.toString());
    Id salesTaskId = (Id) result.get('salesTaskId');
    System.assertEquals(opportunityId('Newer'), result.get('opportunityId'));

    Sales_Task__c salesTask = [
      SELECT Task_Subject__c, Communication_Type__c
      FROM Sales_Task__c
      WHERE Id = :salesTaskId
    ];
    System.assertEquals('Inbound Call', salesTask.Task_Subject__c);
    System.assertEquals('Inbound call', salesTask.Communication_Type__c);
  }

  @IsTest
  static void dispositionTaskSubjectOverridesCallType() {
    Map<String, Object> payload = callPayload('Outgoing');
    fields(payload).put('task-subject', 'virtual-meeting');

    RestResponse res = post(payload);

    System.assertEquals(201, res.statusCode, res.responseBody.toString());
    Id salesTaskId = (Id) body(res).get('salesTaskId');
    Sales_Task__c salesTask = [
      SELECT Task_Subject__c, Communication_Type__c
      FROM Sales_Task__c
      WHERE Id = :salesTaskId
    ];
    System.assertEquals('Virtual Meeting', salesTask.Task_Subject__c);
    System.assertEquals('Outbound Call', salesTask.Communication_Type__c);

    Id activityId = (Id) body(res).get('activityId');
    System.assertEquals(
      'Virtual Meeting',
      [SELECT Call_Anchor_Disposition__c FROM Task WHERE Id = :activityId]
      .Call_Anchor_Disposition__c
    );
  }

  @IsTest
  static void missedIsInboundAndRejectedIsOutbound() {
    Id missedId = (Id) body(post(callPayload('Missed'))).get('salesTaskId');
    Id rejectedId = (Id) body(post(callPayload('Rejected'))).get('salesTaskId');

    Map<Id, Sales_Task__c> salesTasks = new Map<Id, Sales_Task__c>(
      [SELECT Task_Subject__c, Communication_Type__c FROM Sales_Task__c]
    );
    System.assertEquals(
      'Inbound Call',
      salesTasks.get(missedId).Task_Subject__c
    );
    System.assertEquals(
      'Inbound call',
      salesTasks.get(missedId).Communication_Type__c
    );
    System.assertEquals(
      'Outbound Call',
      salesTasks.get(rejectedId).Task_Subject__c
    );
    System.assertEquals(
      'Outbound Call',
      salesTasks.get(rejectedId).Communication_Type__c
    );
  }

  @IsTest
  static void unknownCallTypeLogsTaskOnly() {
    Map<String, Object> payload = callPayload('Unknown');
    call(payload).remove('dispositionScheduledAt');

    RestResponse res = post(payload);

    Map<String, Object> result = body(res);
    System.assertEquals(201, res.statusCode, res.responseBody.toString());
    System.assertNotEquals(null, result.get('activityId'));
    System.assertEquals(null, result.get('salesTaskId'));
    System.assertEquals(0, [SELECT COUNT() FROM Sales_Task__c]);
  }

  @IsTest
  static void dispositionScheduledAtSetsTaskDateAndTime() {
    Datetime local = Datetime.now().addDays(3);
    String day = local.format('yyyy-MM-dd', 'Asia/Kolkata');
    String hhmm = local.format('HH:mm', 'Asia/Kolkata');
    Map<String, Object> payload = callPayload('Outgoing');
    fields(payload).put('scheduled-at', day + 'T' + hhmm + ':00');

    RestResponse res = post(payload);

    System.assertEquals(201, res.statusCode, res.responseBody.toString());
    Map<String, Object> result = body(res);
    Id salesTaskId = (Id) result.get('salesTaskId');
    Id activityId = (Id) result.get('activityId');
    Sales_Task__c salesTask = [
      SELECT Task_Date__c, Task_Time__c
      FROM Sales_Task__c
      WHERE Id = :salesTaskId
    ];
    System.assertEquals(Date.valueOf(day), salesTask.Task_Date__c);
    System.assertEquals(
      hhmm,
      Datetime.newInstanceGmt(Date.today(), salesTask.Task_Time__c)
        .formatGmt('HH:mm')
    );

    Task call = [
      SELECT Call_Anchor_Callback_Scheduled_At__c
      FROM Task
      WHERE Id = :activityId
    ];
    System.assertEquals(
      day + ' ' + hhmm,
      call.Call_Anchor_Callback_Scheduled_At__c.format(
        'yyyy-MM-dd HH:mm',
        'Asia/Kolkata'
      )
    );
  }

  @IsTest
  static void withoutScheduledAtSalesTaskIsDatedNow() {
    Map<String, Object> payload = callPayload('Outgoing');
    call(payload).remove('dispositionScheduledAt');

    Datetime before = Datetime.now();
    RestResponse res = post(payload);

    System.assertEquals(201, res.statusCode, res.responseBody.toString());
    Id salesTaskId = (Id) body(res).get('salesTaskId');
    Sales_Task__c salesTask = [
      SELECT Task_Status__c, Task_Date__c, Task_Time__c, Next_Action_Date__c
      FROM Sales_Task__c
      WHERE Id = :salesTaskId
    ];
    System.assertEquals('Completed', salesTask.Task_Status__c);
    System.assertEquals(
      Date.valueOf(before.format('yyyy-MM-dd', 'Asia/Kolkata')),
      salesTask.Task_Date__c
    );
    assertNear(before, salesTask.Task_Time__c);
    System.assertEquals(null, salesTask.Next_Action_Date__c);
  }

  @IsTest
  static void projectSlugSelectsMatchingOpportunity() {
    Map<String, Object> payload = callPayload('Outgoing');
    // Upper-case slug against the mixed-case name 'Call Anchor Test Project A'.
    fields(payload).put('project-name', 'CALL-ANCHOR-TEST-PROJECT-A');

    RestResponse res = post(payload);

    System.assertEquals(201, res.statusCode, res.responseBody.toString());
    System.assertEquals(opportunityId('Older'), body(res).get('opportunityId'));
  }

  @IsTest
  static void projectSlugNormalisesNamesAndSlugs() {
    System.assertEquals(
      'kohinoor-viva-pixel-phase-i',
      CallAnchorWebhookService.projectSlug('KOHINOOR VIVA PIXEL- PHASE I')
    );
    System.assertEquals(
      'b-zone-baner',
      CallAnchorWebhookService.projectSlug('B-ZONE -- BANER')
    );
    System.assertEquals(
      'kohinoor-reina',
      CallAnchorWebhookService.projectSlug(' kohinoor-reina ')
    );
    // A project renamed only in case keeps its slug, and the slug itself may arrive in any case.
    System.assertEquals(
      'kohinoor-reina',
      CallAnchorWebhookService.projectSlug('Kohinoor Reina')
    );
    System.assertEquals(
      'kohinoor-reina',
      CallAnchorWebhookService.projectSlug('KOHINOOR-REINA')
    );
    System.assertEquals(null, CallAnchorWebhookService.projectSlug(' - '));
    System.assertEquals(null, CallAnchorWebhookService.projectSlug(null));
  }

  @IsTest
  static void unknownProjectReturnsNotFound() {
    Map<String, Object> payload = callPayload('Outgoing');
    fields(payload).put('project-name', 'No Such Project');

    RestResponse res = post(payload);

    System.assertEquals(404, res.statusCode);
    System.assertEquals('OPPORTUNITY_NOT_FOUND', errorCode(res));
  }

  @IsTest
  static void unknownPhoneReturnsNotFound() {
    Map<String, Object> payload = callPayload('Outgoing');
    call(payload).put('calleePhone', '+91 90000 00000');

    RestResponse res = post(payload);

    System.assertEquals(404, res.statusCode);
    System.assertEquals('OPPORTUNITY_NOT_FOUND', errorCode(res));
  }

  @IsTest
  static void opportunityOwnedByAnotherUserIsNotUsed() {
    Map<String, Object> payload = callPayload('Outgoing');
    call(payload).put('agentNumber', OTHER_PHONE);

    RestResponse res = post(payload);

    System.assertEquals(404, res.statusCode);
    System.assertEquals('OPPORTUNITY_NOT_FOUND', errorCode(res));
  }

  @IsTest
  static void unmappedOrInactiveAgentReturnsNotFound() {
    Map<String, Object> unmapped = callPayload('Outgoing');
    call(unmapped).put('agentNumber', '9000000009');
    System.assertEquals('AGENT_NOT_FOUND', errorCode(post(unmapped)));

    Map<String, Object> inactive = callPayload('Outgoing');
    call(inactive).put('agentNumber', '9000000003');
    System.assertEquals('AGENT_NOT_FOUND', errorCode(post(inactive)));

    Map<String, Object> missing = callPayload('Outgoing');
    call(missing).remove('agentNumber');
    System.assertEquals('INVALID_AGENT_PHONE', errorCode(post(missing)));
  }

  @IsTest
  static void invalidPicklistValueIsRejectedAndRolledBack() {
    Map<String, Object> payload = callPayload('Outgoing');
    fields(payload).put('priority', 'Urgent');

    RestResponse res = post(payload);

    System.assertEquals(400, res.statusCode);
    System.assertEquals('INVALID_VALUE', errorCode(res));
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE Call_Anchor_Call_Id__c = 'CALL-001']
    );
  }

  @IsTest
  static void invalidRequests() {
    System.assertEquals('EMPTY_BODY', errorCode(post((String) null)));
    System.assertEquals('INVALID_JSON', errorCode(post('not json')));
    System.assertEquals(
      'MISSING_CALL',
      errorCode(post(new Map<String, Object>()))
    );

    Map<String, Object> badPhone = callPayload('Outgoing');
    call(badPhone).put('calleePhone', '123');
    System.assertEquals('INVALID_PHONE', errorCode(post(badPhone)));

    Map<String, Object> badDate = callPayload('Outgoing');
    call(badDate).put('dispositionScheduledAt', 'tomorrow');
    System.assertEquals('INVALID_DATE', errorCode(post(badDate)));
  }

  private static User user(String email, String alias, String callAnchorPhone) {
    return new User(
      ProfileId = [SELECT Id FROM Profile WHERE Name = 'System Administrator']
      .Id,
      LastName = alias,
      Alias = alias,
      Email = email,
      Username = email + '.' + System.currentTimeMillis(),
      CallAnchor_Phone__c = callAnchorPhone,
      TimeZoneSidKey = 'Asia/Kolkata',
      LocaleSidKey = 'en_IN',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US'
    );
  }

  private static Ud_Project__c project(String name) {
    return new Ud_Project__c(
      Name = name,
      Ud_Project_Location__c = 'Pune',
      Ud_Project_Property_Type__c = 'Apartments',
      Ud_Project_Start_Date__c = Date.today(),
      Ud_Project_Address__PostalCode__s = '411001'
    );
  }

  private static Opportunity opportunity(String name, Id projectId) {
    return new Opportunity(
      Name = name,
      Ud_Last_Name__c = name,
      StageName = 'Open',
      CloseDate = Date.today().addDays(30),
      Ud_Project_Enquired__c = projectId,
      Mobile_Number__c = PHONE,
      RecordTypeId = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName()
        .get('Residential')
        .getRecordTypeId()
    );
  }

  private static Id opportunityId(String name) {
    return [SELECT Id FROM Opportunity WHERE Name = :name].Id;
  }

  private static String scheduledAt() {
    return Datetime.now().addDays(2).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
  }

  private static Map<String, Object> callPayload(String callType) {
    return new Map<String, Object>{
      'call' => new Map<String, Object>{
        'id' => 'CALL-001',
        'callType' => callType,
        'calleePhone' => '+91 ' + PHONE,
        'calleeName' => 'Rahul Sharma',
        'startedAt' => '2026-10-01T10:15:30Z',
        'durationSeconds' => 125,
        'agentName' => 'Agent Smith',
        'agentNumber' => '+91 ' + AGENT_PHONE,
        'recordingUrl' => 'https://example.com/recording.mp3',
        'dispositionNote' => 'Asked for a callback',
        'dispositionScheduledAt' => scheduledAt()
      },
      'disposition' => new Map<String, Object>{
        'fields' => new Map<String, Object>{
          'call-meeting-status' => 'not-connected',
          'priority' => 'high',
          'next-action-status' => 'no-action-needed',
          'note' => '  Customer wants a site visit next week  '
        }
      }
    };
  }

  private static String hhmm(Time value) {
    return Datetime.newInstanceGmt(Date.today(), value).formatGmt('HH:mm');
  }

  // The webhook stamps its own "now"; allow the few seconds the request takes.
  private static void assertNear(Datetime expected, Time actual) {
    Integer expectedSeconds =
      Integer.valueOf(expected.format('H', 'Asia/Kolkata')) * 3600 +
      Integer.valueOf(expected.format('m', 'Asia/Kolkata')) * 60 +
      Integer.valueOf(expected.format('s', 'Asia/Kolkata'));
    Integer actualSeconds =
      actual.hour() * 3600 +
      actual.minute() * 60 +
      actual.second();
    System.assert(
      Math.abs(actualSeconds - expectedSeconds) <= 60,
      'Expected about ' +
        expected.format('HH:mm:ss', 'Asia/Kolkata') +
        ', got ' +
        actual
    );
  }

  private static Map<String, Object> call(Map<String, Object> payload) {
    return (Map<String, Object>) payload.get('call');
  }

  private static Map<String, Object> fields(Map<String, Object> payload) {
    return (Map<String, Object>) ((Map<String, Object>) payload.get(
        'disposition'
      ))
      .get('fields');
  }

  private static RestResponse post(String body) {
    RestRequest req = new RestRequest();
    req.requestURI = '/services/apexrest/CallAnchorWebhook';
    req.httpMethod = 'POST';
    req.requestBody = body == null ? null : Blob.valueOf(body);
    RestContext.request = req;
    RestContext.response = new RestResponse();

    User agent = [SELECT Id FROM User WHERE Email = :AGENT_EMAIL LIMIT 1];
    System.runAs(agent) {
      CallAnchorWebhookService.doPost();
    }
    return RestContext.response;
  }

  private static RestResponse post(Map<String, Object> payload) {
    return post(JSON.serialize(payload));
  }

  private static Map<String, Object> body(RestResponse res) {
    return (Map<String, Object>) JSON.deserializeUntyped(
      res.responseBody.toString()
    );
  }

  private static String errorCode(RestResponse res) {
    return (String) ((Map<String, Object>) body(res).get('error')).get('code');
  }
}
