/**
 * Tests for the supplied Manish Minerals CallAnchorWebService.
 * Uses isolated test records (SeeAllData=false). Run as an administrator with
 * access to the fields/record type used by the service's USER_MODE operations.
 * Existing org validation rules and Flows still execute during these tests.
 */
@IsTest(SeeAllData=false)
private class CallAnchorWebServiceTest {
  private static final String PHONE = '9876501234';
  private static final Datetime STARTED = Datetime.newInstanceGmt(
    2026,
    9,
    21,
    6,
    0,
    0
  );

  private static Map<String, Object> payload(String callId, String phone) {
    return new Map<String, Object>{
      'event' => 'recording.ready',
      'call' => new Map<String, Object>{
        'id' => callId,
        'callType' => 'Incoming',
        'agentName' => 'New',
        'agentNumber' => '9876509999',
        'startedAt' => STARTED,
        'calleeName' => 'Test Customer',
        'calleePhone' => phone,
        'durationSeconds' => 120,
        'recordingUrl' => 'https://example.com/test-recording.m4a'
      }
    };
  }
  private static Map<String, Object> callFields(Map<String, Object> body) {
    return (Map<String, Object>) body.get('call');
  }
  private static Map<String, Object> postRaw(String jsonBody) {
    RestRequest request = new RestRequest();
    request.requestUri = '/services/apexrest/CallAnchorWebhook/';
    request.httpMethod = 'POST';
    request.addHeader('Content-Type', 'application/json');
    if (jsonBody != null)
      request.requestBody = Blob.valueOf(jsonBody);
    RestContext.request = request;
    RestContext.response = new RestResponse();
    CallAnchorWebService.receiveCall();
    System.assertNotEquals(null, RestContext.response.responseBody);
    return (Map<String, Object>) JSON.deserializeUntyped(
      RestContext.response.responseBody.toString()
    );
  }
  private static Map<String, Object> post(Map<String, Object> body) {
    return postRaw(JSON.serialize(body));
  }
  private static void expectStatus(
    Integer expected,
    Map<String, Object> result
  ) {
    System.assertEquals(
      expected,
      RestContext.response.statusCode,
      JSON.serialize(result)
    );
    System.assertEquals(
      expected < 400,
      result.get('success'),
      JSON.serialize(result)
    );
    // Every response carries the full contract, whether it succeeded or failed.
    System.assertEquals(
      expected,
      result.get('statusCode'),
      JSON.serialize(result)
    );
    for (
      String key : new List<String>{
        'code',
        'action',
        'message',
        'retryable',
        'event',
        'callId',
        'taskId',
        'followUpTaskId',
        'relatedRecordId',
        'relatedObject',
        'createdEnquiry',
        'warnings',
        'requestId',
        'processedAt'
      }
    ) {
      System.assert(
        result.containsKey(key),
        'Missing response key ' + key + ': ' + JSON.serialize(result)
      );
    }
    System.assertNotEquals(null, result.get('code'), JSON.serialize(result));
    System.assertNotEquals(null, result.get('message'), JSON.serialize(result));
  }
  private static Account company(String name, String phone) {
    Account account = new Account(Name = name);
    account.put('Mobile__c', phone);
    insert account;
    return account;
  }
  private static SObject enquiry(String phone) {
    Schema.SObjectType enquiryType = Schema.getGlobalDescribe()
      .get('Enquiry__c');
    System.assertNotEquals(null, enquiryType, 'Enquiry__c is required.');
    Schema.RecordTypeInfo rt = enquiryType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('New_Customer');
    System.assertNotEquals(null, rt, 'New_Customer record type is required.');
    SObject row = enquiryType.newSObject();
    row.put('RecordTypeId', rt.getRecordTypeId());
    row.put('Phone__c', phone);
    row.put('First_Name__c', 'Existing Test Customer');
    insert row;
    return row;
  }
  private static Task taskFrom(Map<String, Object> result) {
    Id taskId = (Id) String.valueOf(result.get('taskId'));
    return [
      SELECT
        Id,
        WhatId,
        WhoId,
        OwnerId,
        Subject,
        IsClosed,
        TaskSubtype,
        ActivityDate,
        CallType,
        CallDurationInSeconds,
        Description,
        Call_Anchor_Call_Id__c,
        Call_Anchor_Agent_Name__c,
        Call_Anchor_Agent_Mobile__c,
        Call_Anchor_Callee_Name__c,
        Call_Anchor_Callee_Phone__c,
        Call_Anchor_Call_Type__c,
        Call_Anchor_Call_Started_At__c,
        Call_Anchor_Duration_Seconds__c,
        Call_Anchor_Recording_Url__c,
        Call_Anchor_Disposition__c,
        Call_Anchor_Outcome__c,
        Call_Anchor_Disposition_Note__c,
        Call_Anchor_Callback_Scheduled_At__c,
        Team_Member__c
      FROM Task
      WHERE Id = :taskId
    ];
  }
  private static Task followUpFrom(Map<String, Object> result) {
    Id taskId = (Id) String.valueOf(result.get('followUpTaskId'));
    return [
      SELECT
        Id,
        WhatId,
        OwnerId,
        Subject,
        Status,
        IsClosed,
        ActivityDate,
        IsReminderSet,
        ReminderDateTime,
        Description,
        Call_Anchor_Call_Id__c,
        Call_Anchor_Callback_Scheduled_At__c,
        Call_Anchor_Callee_Phone__c,
        Team_Member__c,
        Call_Anchor_Agent_Name__c,
        Call_Anchor_Agent_Mobile__c
      FROM Task
      WHERE Id = :taskId
    ];
  }
  // Whole seconds: DateTime fields do not keep milliseconds.
  private static Datetime futureAt(Integer days, Integer hour) {
    return Datetime.newInstance(
      Date.today().addDays(days),
      Time.newInstance(hour, 0, 0, 0)
    );
  }
  // Choose valid org API values for configurable disposition fields.
  private static String fieldValue(String fieldName, String fallback) {
    Schema.DescribeFieldResult info = Task.SObjectType.getDescribe()
      .fields.getMap()
      .get(fieldName)
      .getDescribe();
    if (info.getType() == Schema.DisplayType.Picklist) {
      for (Schema.PicklistEntry entry : info.getPicklistValues()) {
        if (entry.isActive())
          return entry.getValue();
      }
    }
    return fallback;
  }
  private static void assertTimestamp(
    Task row,
    String fieldName,
    Datetime expected
  ) {
    Schema.DisplayType kind = Task.SObjectType.getDescribe()
      .fields.getMap()
      .get(fieldName)
      .getDescribe()
      .getType();
    Object actual = row.get(fieldName);
    if (kind == Schema.DisplayType.DateTime)
      System.assertEquals(expected, actual);
    else if (kind == Schema.DisplayType.Date)
      System.assertEquals(expected.dateGmt(), actual);
    else
      System.assertEquals(
        expected.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\''),
        actual
      );
  }

  @IsTest
  static void incomingCompanyMapsFields() {
    Account account = company('CA Test Company', PHONE);
    Map<String, Object> body = payload('company-incoming', '+91 ' + PHONE);
    String label = fieldValue('Call_Anchor_Disposition__c', 'Follow up');
    String outcome = fieldValue('Call_Anchor_Outcome__c', 'Interested');
    String note = fieldValue(
      'Call_Anchor_Disposition_Note__c',
      'Customer requested a callback.'
    );
    callFields(body).put('dispositionLabel', label);
    callFields(body).put('dispositionNote', 'Fallback note');
    callFields(body).put('dispositionScheduledAt', STARTED.addDays(1));
    body.put(
      'disposition',
      new Map<String, Object>{
        'fields' => new Map<String, Object>{
          'outcome' => outcome,
          'note' => note
        }
      }
    );
    Test.startTest();
    Map<String, Object> result = post(body);
    Test.stopTest();
    expectStatus(201, result);
    System.assertEquals('created', result.get('action'));
    System.assertEquals(false, result.get('createdEnquiry'));
    Task row = taskFrom(result);
    System.assertEquals(account.Id, row.WhatId);
    System.assertEquals(null, row.WhoId);
    System.assertEquals(UserInfo.getUserId(), row.OwnerId);
    System.assertEquals(true, row.IsClosed);
    System.assertEquals('Call', row.TaskSubtype);
    System.assertEquals('Incoming call - Test Customer', row.Subject);
    System.assertEquals('Inbound', row.CallType);
    System.assertEquals(120, row.CallDurationInSeconds);
    System.assertEquals(STARTED.dateGmt(), row.ActivityDate);
    System.assertEquals('company-incoming', row.get('Call_Anchor_Call_Id__c'));
    System.assertEquals('New', row.get('Call_Anchor_Agent_Name__c'));
    System.assertEquals('9876509999', row.get('Call_Anchor_Agent_Mobile__c'));
    System.assertEquals('Test Customer', row.get('Call_Anchor_Callee_Name__c'));
    System.assertEquals('+91 ' + PHONE, row.get('Call_Anchor_Callee_Phone__c'));
    System.assertEquals('Incoming', row.get('Call_Anchor_Call_Type__c'));
    System.assertEquals(
      Decimal.valueOf('120'),
      Decimal.valueOf(
        String.valueOf(row.get('Call_Anchor_Duration_Seconds__c'))
      )
    );
    System.assertEquals(
      'https://example.com/test-recording.m4a',
      row.get('Call_Anchor_Recording_Url__c')
    );
    System.assertEquals(label, row.get('Call_Anchor_Disposition__c'));
    System.assertEquals(outcome, row.get('Call_Anchor_Outcome__c'));
    System.assertEquals(note, row.get('Call_Anchor_Disposition_Note__c'));
    assertTimestamp(row, 'Call_Anchor_Call_Started_At__c', STARTED);
    assertTimestamp(
      row,
      'Call_Anchor_Callback_Scheduled_At__c',
      STARTED.addDays(1)
    );
    System.assertEquals(null, row.get('Team_Member__c'));
    for (
      String line : new List<String>{
        'Call ID: company-incoming',
        'Direction: Incoming',
        'Customer: Test Customer (+91 ' +
        PHONE +
        ')',
        'Agent: New (9876509999)',
        'Started: ',
        'Duration: 2m 0s',
        'Disposition: ' + label,
        'Outcome: ' + outcome,
        'Note: ' + note,
        'Follow-up: ',
        'Recording: https://example.com/test-recording.m4a'
      }
    ) {
      System.assert(
        row.Description.contains(line),
        'Missing "' + line + '" in ' + row.Description
      );
    }
    // A follow-up time already in the past still gets an open Task, but no reminder.
    Task followUp = followUpFrom(result);
    System.assertEquals(false, followUp.IsClosed);
    System.assertEquals(false, followUp.IsReminderSet);
    System.assertEquals(
      'company-incoming-followup',
      followUp.get('Call_Anchor_Call_Id__c')
    );
    System.assertEquals(account.Id, followUp.WhatId);
    System.assert(
      String.valueOf(result.get('message'))
        .contains('Follow-up Task scheduled for'),
      JSON.serialize(result)
    );
  }
  @IsTest
  static void futureFollowUpCreatesOpenTaskWithReminder() {
    Account account = company('Follow-up Company', PHONE);
    Datetime scheduled = futureAt(2, 10);
    Map<String, Object> body = payload('future-followup', PHONE);
    callFields(body).put('agentName', 'Vaishnavi Prabhu');
    callFields(body).put('agentNumber', '+91 82919 36833');
    callFields(body).put('dispositionScheduledAt', scheduled);
    Test.startTest();
    Map<String, Object> result = post(body);
    Test.stopTest();
    expectStatus(201, result);
    System.assertNotEquals(
      null,
      result.get('followUpTaskId'),
      JSON.serialize(result)
    );
    System.assertNotEquals(result.get('taskId'), result.get('followUpTaskId'));
    Task followUp = followUpFrom(result);
    System.assertEquals('Open', followUp.Status);
    System.assertEquals(false, followUp.IsClosed);
    System.assertEquals(account.Id, followUp.WhatId);
    System.assertEquals(UserInfo.getUserId(), followUp.OwnerId);
    System.assertEquals(
      'Follow-up: Incoming call - Test Customer',
      followUp.Subject
    );
    System.assertEquals(scheduled.date(), followUp.ActivityDate);
    System.assertEquals(true, followUp.IsReminderSet);
    System.assertEquals(scheduled, followUp.ReminderDateTime);
    System.assertEquals(
      scheduled,
      followUp.get('Call_Anchor_Callback_Scheduled_At__c')
    );
    System.assertEquals(PHONE, followUp.get('Call_Anchor_Callee_Phone__c'));
    System.assertEquals('Vaishnavi Prabhu', followUp.get('Team_Member__c'));
    // Same agent as the call Task.
    Task callTask = taskFrom(result);
    System.assertEquals(
      callTask.get('Call_Anchor_Agent_Name__c'),
      followUp.get('Call_Anchor_Agent_Name__c')
    );
    System.assertEquals(
      callTask.get('Call_Anchor_Agent_Mobile__c'),
      followUp.get('Call_Anchor_Agent_Mobile__c')
    );
    System.assertEquals(
      'Vaishnavi Prabhu',
      followUp.get('Call_Anchor_Agent_Name__c')
    );
    System.assertEquals(
      '+91 82919 36833',
      followUp.get('Call_Anchor_Agent_Mobile__c')
    );
    System.assertEquals(
      'Vaishnavi Prabhu',
      taskFrom(result).get('Team_Member__c')
    );
    System.assert(followUp.Description.contains('future-followup'));
  }
  @IsTest
  static void followUpRetryReschedulesSameTask() {
    company('Reschedule Company', PHONE);
    Map<String, Object> body = payload('reschedule-call', PHONE);
    callFields(body).put('dispositionScheduledAt', futureAt(1, 9));
    Map<String, Object> first = post(body);
    expectStatus(201, first);
    Datetime rescheduled = futureAt(3, 15);
    callFields(body).put('dispositionScheduledAt', rescheduled);
    Test.startTest();
    Map<String, Object> second = post(body);
    Test.stopTest();
    expectStatus(200, second);
    System.assertEquals(
      first.get('followUpTaskId'),
      second.get('followUpTaskId')
    );
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Task
        WHERE Call_Anchor_Call_Id__c = 'reschedule-call-followup'
      ]
    );
    Task followUp = followUpFrom(second);
    System.assertEquals(
      rescheduled,
      followUp.get('Call_Anchor_Callback_Scheduled_At__c')
    );
    System.assertEquals(rescheduled, followUp.ReminderDateTime);
    System.assertEquals(rescheduled.date(), followUp.ActivityDate);
  }
  @IsTest
  static void closedFollowUpIsLeftUntouched() {
    company('Closed Follow-up Company', PHONE);
    Datetime original = futureAt(1, 11);
    Map<String, Object> body = payload('closed-followup', PHONE);
    callFields(body).put('dispositionScheduledAt', original);
    Map<String, Object> first = post(body);
    expectStatus(201, first);
    update new Task(
      Id = (Id) String.valueOf(first.get('followUpTaskId')),
      Status = 'Completed'
    );
    callFields(body).put('dispositionScheduledAt', futureAt(4, 11));
    Test.startTest();
    Map<String, Object> second = post(body);
    Test.stopTest();
    expectStatus(200, second);
    System.assertEquals(
      null,
      second.get('followUpTaskId'),
      JSON.serialize(second)
    );
    System.assert(
      String.valueOf(second.get('warnings')).contains('already closed'),
      JSON.serialize(second)
    );
    System.assert(
      !String.valueOf(second.get('message')).contains('Follow-up'),
      JSON.serialize(second)
    );
    Task followUp = followUpFrom(first);
    System.assertEquals(true, followUp.IsClosed);
    System.assertEquals(
      original,
      followUp.get('Call_Anchor_Callback_Scheduled_At__c')
    );
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Task
        WHERE Call_Anchor_Call_Id__c = 'closed-followup-followup'
      ]
    );
  }
  @IsTest
  static void duplicateFollowUpsAreRejected() {
    Account account = company('Duplicate Follow-up Company', PHONE);
    insert new List<Task>{
      new Task(
        WhatId = account.Id,
        Subject = 'Dup 1',
        Call_Anchor_Call_Id__c = 'dup-call-followup'
      ),
      new Task(
        WhatId = account.Id,
        Subject = 'Dup 2',
        Call_Anchor_Call_Id__c = 'dup-call-followup'
      )
    };
    Map<String, Object> body = payload('dup-call', PHONE);
    callFields(body).put('dispositionScheduledAt', futureAt(1, 12));
    Test.startTest();
    Map<String, Object> result = post(body);
    Test.stopTest();
    expectStatus(409, result);
    System.assertEquals('MATCH_CONFLICT', result.get('code'));
    System.assertEquals(null, result.get('followUpTaskId'));
    // Rolled back: the call Task is not kept either.
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE Call_Anchor_Call_Id__c = 'dup-call']
    );
  }
  @IsTest
  static void contactMatchesItsCompany() {
    Account account = company('Contact Company', '9876500001');
    insert new Contact(
      LastName = 'Test Contact',
      AccountId = account.Id,
      MobilePhone = PHONE
    );
    Map<String, Object> body = payload('contact-outgoing', '+91' + PHONE);
    callFields(body).put('callType', 'outgoing');
    callFields(body).remove('calleeName');
    Test.startTest();
    Map<String, Object> result = post(body);
    Test.stopTest();
    expectStatus(201, result);
    Task row = taskFrom(result);
    System.assertEquals(account.Id, row.WhatId);
    System.assertEquals(null, row.WhoId);
    System.assertEquals('Outbound', row.CallType);
    System.assertEquals('Outgoing call - +91' + PHONE, row.Subject);
    System.assert(
      row.Description.contains('Customer: +91' + PHONE),
      row.Description
    );
    // No Call_Anchor_Callback_Scheduled_At__c: no follow-up Task.
    System.assertEquals(null, result.get('followUpTaskId'));
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Task
        WHERE Call_Anchor_Call_Id__c = 'contact-outgoing-followup'
      ]
    );
  }
  // Missed and rejected calls are logged with their own Call Type; missed counts as
  // inbound, rejected as outbound.
  @IsTest
  static void missedAndRejectedCallsAreLogged() {
    Account account = company('Missed Company', PHONE);
    Map<String, Object> missed = payload('missed-call', '+91' + PHONE);
    callFields(missed).put('callType', 'missed');
    callFields(missed).put('durationSeconds', 0);
    callFields(missed).put('recordingUrl', null);
    Map<String, Object> rejected = payload('rejected-call', '+91' + PHONE);
    callFields(rejected).put('callType', 'Rejected');
    Test.startTest();
    Map<String, Object> missedResult = post(missed);
    expectStatus(201, missedResult);
    Map<String, Object> rejectedResult = post(rejected);
    expectStatus(201, rejectedResult);
    Test.stopTest();
    Task missedRow = taskFrom(missedResult);
    System.assertEquals(account.Id, missedRow.WhatId);
    System.assertEquals('Missed', missedRow.get('Call_Anchor_Call_Type__c'));
    System.assertEquals('Inbound', missedRow.CallType);
    System.assertEquals('Missed call - Test Customer', missedRow.Subject);
    System.assertEquals(0, missedRow.CallDurationInSeconds);
    System.assertEquals(null, missedRow.get('Call_Anchor_Recording_Url__c'));
    System.assert(
      missedRow.Description.contains('Call Type: Missed'),
      missedRow.Description
    );
    System.assert(
      missedRow.Description.contains('Direction: Incoming'),
      missedRow.Description
    );
    Task rejectedRow = taskFrom(rejectedResult);
    System.assertEquals(
      'Rejected',
      rejectedRow.get('Call_Anchor_Call_Type__c')
    );
    System.assertEquals('Outbound', rejectedRow.CallType);
    System.assertEquals('Rejected call - Test Customer', rejectedRow.Subject);
    System.assert(
      rejectedRow.Description.contains('Direction: Outgoing'),
      rejectedRow.Description
    );
  }

  @IsTest
  static void existingEnquiryIsReused() {
    SObject existing = enquiry(PHONE);
    Test.startTest();
    Map<String, Object> result = post(
      payload('existing-enquiry', '+91' + PHONE)
    );
    Test.stopTest();
    expectStatus(201, result);
    System.assertEquals(false, result.get('createdEnquiry'));
    System.assertEquals(existing.get('Id'), taskFrom(result).WhatId);
    System.assertEquals(
      1,
      Database.countQuery('SELECT COUNT() FROM Enquiry__c')
    );
  }
  @IsTest
  static void unknownPhoneCreatesEnquiry() {
    Test.startTest();
    Map<String, Object> result = post(payload('new-enquiry', PHONE));
    Test.stopTest();
    expectStatus(201, result);
    System.assertEquals(true, result.get('createdEnquiry'));
    System.assertEquals('Enquiry__c', result.get('relatedObject'));
    Id parentId = taskFrom(result).WhatId;
    SObject row = Database.query(
      'SELECT Phone__c, First_Name__c, RecordType.DeveloperName ' +
      'FROM Enquiry__c WHERE Id = :parentId'
    );
    System.assertEquals(PHONE, row.get('Phone__c'));
    System.assertEquals('Test Customer', row.get('First_Name__c'));
    System.assertEquals(
      'New_Customer',
      row.getSObject('RecordType').get('DeveloperName')
    );
  }
  @IsTest
  static void teamMemberResolvesFromAgentMobile() {
    System.assertEquals(
      'Vaishnavi Prabhu',
      CallAnchorWebService.teamMemberFor('+91 82919 36833')
    );
    System.assertEquals(
      'Vaishnavi Prabhu',
      CallAnchorWebService.teamMemberFor('8291936833')
    );
    System.assertEquals(
      'Megha Haria',
      CallAnchorWebService.teamMemberFor('+918657490344')
    );
    System.assertEquals(
      'Megha Haria',
      CallAnchorWebService.teamMemberFor('08657490344')
    );
    System.assertEquals(
      'Pooja Chavan',
      CallAnchorWebService.teamMemberFor('9319300765')
    );
    System.assertEquals(
      'Sweta Nevatia',
      CallAnchorWebService.teamMemberFor('91 96649 80208')
    );
    System.assertEquals(null, CallAnchorWebService.teamMemberFor('9876509999'));
  }
  @IsTest
  static void newEnquiryGetsAgentTeamMember() {
    Map<String, Object> body = payload('agent-enquiry', PHONE);
    callFields(body).put('agentName', 'Megha Haria');
    callFields(body).put('agentNumber', '+91 86574 90344');
    Test.startTest();
    Map<String, Object> result = post(body);
    Test.stopTest();
    expectStatus(201, result);
    System.assertEquals(true, result.get('createdEnquiry'));
    Task callTask = taskFrom(result);
    Id parentId = callTask.WhatId;
    SObject row = Database.query(
      'SELECT Team_Member__c FROM Enquiry__c WHERE Id = :parentId'
    );
    // Left blank only if the org's Team_Member__c picklist lacks the agent's name.
    String warnings = String.valueOf(result.get('warnings'));
    System.assertEquals(
      warnings.contains('Enquiry__c.Team_Member__c could not be set')
        ? null
        : 'Megha Haria',
      row.get('Team_Member__c'),
      JSON.serialize(result)
    );
    System.assertEquals(
      warnings.contains('Task.Team_Member__c could not be set')
        ? null
        : 'Megha Haria',
      callTask.get('Team_Member__c'),
      JSON.serialize(result)
    );
  }
  @IsTest
  static void companyTakesPriorityOverEnquiry() {
    enquiry(PHONE);
    Account account = company('Preferred Company', PHONE);
    Test.startTest();
    Map<String, Object> result = post(payload('company-priority', PHONE));
    Test.stopTest();
    expectStatus(201, result);
    System.assertEquals(account.Id, taskFrom(result).WhatId);
  }
  @IsTest
  static void retryUpdatesWithoutDuplicatingOrClearingValues() {
    company('Retry Company', PHONE);
    Map<String, Object> body = payload('retry-call', PHONE);
    Map<String, Object> first = post(body);
    expectStatus(201, first);
    callFields(body).put('calleePhone', '+91' + PHONE);
    callFields(body).put('callType', 'Outgoing');
    callFields(body).remove('recordingUrl');
    callFields(body).remove('durationSeconds');
    Test.startTest();
    Map<String, Object> second = post(body);
    Test.stopTest();
    expectStatus(200, second);
    System.assertEquals('updated', second.get('action'));
    System.assertEquals(first.get('taskId'), second.get('taskId'));
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Task WHERE Call_Anchor_Call_Id__c = 'retry-call']
    );
    Task row = taskFrom(second);
    System.assertEquals('Outbound', row.CallType);
    System.assertEquals(120, row.CallDurationInSeconds);
    System.assertEquals(
      'https://example.com/test-recording.m4a',
      row.get('Call_Anchor_Recording_Url__c')
    );
  }
  @IsTest
  static void retryRejectsDifferentCustomer() {
    company('Conflict Company', PHONE);
    Map<String, Object> first = post(payload('phone-conflict', PHONE));
    expectStatus(201, first);
    Test.startTest();
    Map<String, Object> result = post(payload('phone-conflict', '9876502222'));
    Test.stopTest();
    expectStatus(409, result);
    System.assertEquals('MATCH_CONFLICT', result.get('code'));
    System.assertEquals(
      PHONE,
      taskFrom(first).get('Call_Anchor_Callee_Phone__c')
    );
  }
  @IsTest
  static void directCompanyMatchBeatsContactMatch() {
    Account first = company('First Company', PHONE);
    Account other = company('Second Company', '9876500002');
    insert new Contact(
      LastName = 'Conflicting Contact',
      AccountId = other.Id,
      MobilePhone = PHONE
    );
    Test.startTest();
    Map<String, Object> result = post(payload('ambiguous-company', PHONE));
    Test.stopTest();
    expectStatus(201, result);
    System.assertEquals(first.Id, taskFrom(result).WhatId);
    String warnings = String.valueOf(result.get('warnings'));
    System.assert(
      warnings.contains('more than one Company'),
      JSON.serialize(result)
    );
    System.assert(
      warnings.contains(String.valueOf(other.Id)),
      JSON.serialize(result)
    );
  }
  @IsTest
  static void whatsappNumberMatchesCompany() {
    Account account = new Account(Name = 'Whatsapp Company');
    account.put('Mobile_Whatsapp__c', PHONE);
    insert account;
    Test.startTest();
    Map<String, Object> result = post(
      payload('whatsapp-company', '+91' + PHONE)
    );
    Test.stopTest();
    expectStatus(201, result);
    System.assertEquals(false, result.get('createdEnquiry'));
    System.assertEquals(account.Id, taskFrom(result).WhatId);
  }
  @IsTest
  static void duplicateCompaniesUseOneAndWarn() {
    Account first = company('Dup Company A', PHONE);
    Account second = company('Dup Company B', '91' + PHONE);
    Test.startTest();
    Map<String, Object> result = post(payload('duplicate-company', PHONE));
    Test.stopTest();
    expectStatus(201, result);
    Id related = taskFrom(result).WhatId;
    System.assert(
      related == first.Id || related == second.Id,
      JSON.serialize(result)
    );
    System.assert(
      String.valueOf(result.get('warnings')).contains('more than one Company'),
      JSON.serialize(result)
    );
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Task
        WHERE Call_Anchor_Call_Id__c = 'duplicate-company'
      ]
    );
  }
  @IsTest
  static void invalidMappingRollsBackNewEnquiry() {
    Map<String, Object> body = payload('rollback-call', PHONE);
    Integer length = Task.SObjectType.getDescribe()
      .fields.getMap()
      .get('Call_Anchor_Recording_Url__c')
      .getDescribe()
      .getLength();
    String oversized = 'x';
    while (oversized.length() <= length)
      oversized += oversized;
    callFields(body).put('recordingUrl', oversized);
    Integer beforeCount = Database.countQuery('SELECT COUNT() FROM Enquiry__c');
    Test.startTest();
    Map<String, Object> result = post(body);
    Test.stopTest();
    expectStatus(400, result);
    System.assertEquals('CONFIGURATION_ERROR', result.get('code'));
    System.assertEquals(null, result.get('followUpTaskId'));
    System.assert(
      String.valueOf(result.get('message'))
        .contains('Call_Anchor_Recording_Url__c'),
      JSON.serialize(result)
    );
    System.assertEquals(
      beforeCount,
      Database.countQuery('SELECT COUNT() FROM Enquiry__c')
    );
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE Call_Anchor_Call_Id__c = 'rollback-call']
    );
  }
  // The recording.ready-only filter is disabled in the service: every event with a call is processed.
  @IsTest
  static void otherEventsAreProcessed() {
    Map<String, Object> body = payload('other-event', PHONE);
    body.put('event', 'call.completed');
    Test.startTest();
    Map<String, Object> result = post(body);
    Test.stopTest();
    expectStatus(201, result);
    System.assertEquals('call.completed', result.get('event'));
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Task WHERE Call_Anchor_Call_Id__c = 'other-event']
    );
  }
  @IsTest
  static void invalidRequestShapesAreRejected() {
    Test.startTest();
    for (
      String body : new List<String>{
        null,
        'null',
        '{}',
        '{"event":"recording.ready"}',
        '{"event":"recording.ready","call":[]}'
      }
    ) {
      Map<String, Object> result = postRaw(body);
      expectStatus(400, result);
      System.assertEquals('INVALID_REQUEST', result.get('code'));
    }
    Map<String, Object> malformed = postRaw('{invalid json');
    expectStatus(400, malformed);
    System.assertEquals('INVALID_JSON', malformed.get('code'));
    Test.stopTest();
  }
  @IsTest
  static void invalidCallValuesAreRejected() {
    Test.startTest();
    for (
      String required : new List<String>{
        'id',
        'calleePhone',
        'startedAt',
        'agentName',
        'agentNumber'
      }
    ) {
      Map<String, Object> body = payload('missing-field', PHONE);
      callFields(body).remove(required);
      Map<String, Object> result = post(body);
      expectStatus(400, result);
      System.assertEquals('INVALID_REQUEST', result.get('code'));
    }
    for (String direction : new List<String>{ null, ' ', 'Voicemail' }) {
      Map<String, Object> body = payload('invalid-direction', PHONE);
      callFields(body).put('callType', direction);
      Map<String, Object> result = post(body);
      expectStatus(400, result);
      System.assertEquals('INVALID_REQUEST', result.get('code'));
    }
    Map<String, Object> negative = payload('negative-duration', PHONE);
    callFields(negative).put('durationSeconds', -1);
    Map<String, Object> result = post(negative);
    expectStatus(400, result);
    System.assertEquals('INVALID_REQUEST', result.get('code'));
    Test.stopTest();
  }
  @IsTest
  static void invalidDispositionTypeIsRejected() {
    Map<String, Object> body = payload('invalid-disposition', PHONE);
    body.put('disposition', 'not an object');
    Test.startTest();
    Map<String, Object> result = post(body);
    Test.stopTest();
    expectStatus(400, result);
    System.assertEquals('INVALID_TYPE', result.get('code'));
  }
  @IsTest
  static void phoneNormalizationHandlesPrefixesAndPunctuation() {
    System.assertEquals(
      '919876501234',
      CallAnchorWebService.normalizePhone('9876501234')
    );
    System.assertEquals(
      '919876501234',
      CallAnchorWebService.normalizePhone('09876501234')
    );
    System.assertEquals(
      '919876501234',
      CallAnchorWebService.normalizePhone('+91 (98765) 01234')
    );
    System.assertEquals(
      '919876501234',
      CallAnchorWebService.normalizePhone('0091-98765-01234')
    );
    System.assertEquals(
      '14155552671',
      CallAnchorWebService.normalizePhone('+1 (415) 555-2671')
    );
    for (
      String invalid : new List<String>{
        null,
        '',
        '123',
        '+1234567890123456',
        '9876501234 ext 2'
      }
    ) {
      Boolean rejected = false;
      try {
        CallAnchorWebService.normalizePhone(invalid);
      } catch (Exception e) {
        rejected = true;
      }
      System.assert(
        rejected,
        'Expected invalid phone to be rejected: ' + invalid
      );
    }
  }
}
