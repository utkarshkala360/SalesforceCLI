@IsTest
private class CallAnchorWebhookServiceTest {
  // Matches CallAnchorWebhookService.OWNER_ID.
  private static final Id OWNER_ID = '005dM00000arNkvQAE';

  // The service saves in user mode, so run as a user with the Call Anchor field permissions.
  private static User callerUser() {
    Profile admin = [
      SELECT Id
      FROM Profile
      WHERE Name = 'System Administrator'
      LIMIT 1
    ];
    String unique = String.valueOf(Crypto.getRandomInteger()).replace('-', '');
    User u = new User(
      ProfileId = admin.Id,
      LastName = 'Webhook Caller',
      Alias = 'cawh',
      Email = 'cawh' + unique + '@example.com',
      Username = 'cawh' + unique + '@example.com.test',
      TimeZoneSidKey = 'Asia/Kolkata',
      LocaleSidKey = 'en_US',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US'
    );
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert u;
      PermissionSet ps = [
        SELECT Id
        FROM PermissionSet
        WHERE Name = 'Call_Anchor_Access'
        LIMIT 1
      ];
      insert new PermissionSetAssignment(
        AssigneeId = u.Id,
        PermissionSetId = ps.Id
      );
    }
    return u;
  }

  private static Map<String, Object> payload(String phone, String agentName) {
    return new Map<String, Object>{
      'call' => new Map<String, Object>{
        'id' => 'CALL-001',
        'callType' => 'Outgoing',
        'calleePhone' => phone,
        'calleeName' => 'Ravi Kumar',
        'agentName' => agentName,
        'agentNumber' => '9988776655',
        'startedAt' => '2026-11-03T10:15:00Z',
        'durationSeconds' => 125,
        'recordingUrl' => 'https://example.com/rec/1.mp3',
        'dispositionNote' => 'Asked for a callback',
        'dispositionScheduledAt' => '2026-11-04T09:00:00Z'
      },
      'disposition' => new Map<String, Object>{
        'fields' => new Map<String, Object>{ 'outcome' => 'Interested' }
      }
    };
  }

  private static Map<String, Object> payloadWithoutCallback(
    String phone,
    String agentName
  ) {
    Map<String, Object> data = payload(phone, agentName);
    ((Map<String, Object>) data.get('call')).remove('dispositionScheduledAt');
    return data;
  }

  private static RestResponse post(String body) {
    RestRequest req = new RestRequest();
    req.requestURI = '/services/apexrest/CallAnchorWebhook';
    req.httpMethod = 'POST';
    req.requestBody = body == null ? null : Blob.valueOf(body);
    RestContext.request = req;
    RestContext.response = new RestResponse();
    CallAnchorWebhookService.doPost();
    return RestContext.response;
  }

  private static RestResponse post(Map<String, Object> body) {
    return post(JSON.serialize(body));
  }

  private static Map<String, Object> bodyOf(RestResponse res) {
    return (Map<String, Object>) JSON.deserializeUntyped(
      res.responseBody.toString()
    );
  }

  private static Map<String, Object> recordsOf(RestResponse res) {
    return (Map<String, Object>) bodyOf(res).get('records');
  }

  private static Id recordTypeId(String developerName) {
    return Schema.SObjectType.Task.getRecordTypeInfosByDeveloperName()
      .get(developerName)
      .getRecordTypeId();
  }

  private static String errorCode(RestResponse res) {
    return (String) ((Map<String, Object>) bodyOf(res).get('error'))
      .get('code');
  }

  @IsTest
  static void noMatchCreatesLeadWithCallAndFollowUp() {
    User caller = callerUser();
    RestResponse res;
    System.runAs(caller) {
      Test.startTest();
      res = post(payload('+91 98765-43210', 'Someone Else'));
      Test.stopTest();
    }

    Map<String, Object> body = bodyOf(res);
    Assert.areEqual(201, res.statusCode, res.responseBody.toString());
    Assert.areEqual(
      recordsOf(res).get('callActivityId'),
      body.get('id'),
      'id is the call activity'
    );
    Assert.isTrue((Boolean) body.get('success'));
    List<Object> log = (List<Object>) body.get('log');
    Assert.isTrue(
      ((String) log[0]).startsWith('Created Lead '),
      String.valueOf(log)
    );

    Lead l = [
      SELECT LastName, Company, MobilePhone
      FROM Lead
      WHERE Id = :(Id) recordsOf(res).get('recordId')
    ];
    Assert.areEqual('Ravi Kumar', l.LastName);
    Assert.areEqual('Ravi Kumar', l.Company);
    Assert.areEqual('9876543210', l.MobilePhone);

    Task t;
    Task followUp;
    System.runAs(caller) {
      t = [
        SELECT
          Subject,
          Status,
          IsClosed,
          WhoId,
          ActivityDate,
          Description,
          RecordTypeId,
          TaskSubtype,
          Call_Anchor_Call_Id__c,
          Call_Anchor_Call_Type__c,
          Call_Anchor_Call_Started_At__c,
          Call_Anchor_Duration_Seconds__c,
          Call_Anchor_Agent_Name__c,
          Call_Anchor_Agent_Mobile__c,
          Call_Anchor_Recording_Url__c,
          Call_Anchor_Disposition__c,
          Call_Anchor_Disposition_Note__c,
          Call_Anchor_Callback_Scheduled_At__c
        FROM Task
        WHERE Id = :(Id) recordsOf(res).get('callActivityId')
      ];
      followUp = [
        SELECT
          Subject,
          Status,
          WhoId,
          ActivityDate,
          IsReminderSet,
          ReminderDateTime,
          RecordTypeId,
          TaskSubtype,
          Call_Anchor_Call_Id__c,
          Call_Anchor_Disposition__c,
          Call_Anchor_Disposition_Note__c,
          Call_Anchor_Agent_Name__c,
          Call_Anchor_Agent_Mobile__c
        FROM Task
        WHERE Id = :(Id) recordsOf(res).get('followUpTaskId')
      ];
    }
    Assert.areEqual('Call - Outgoing', t.Subject);
    Assert.areEqual('Completed', t.Status);
    Assert.isTrue(t.IsClosed);
    Assert.areEqual(
      recordTypeId('Call'),
      t.RecordTypeId,
      'Call log uses the Call record type'
    );
    Assert.areEqual('Call', t.TaskSubtype);
    Assert.areEqual(l.Id, t.WhoId);
    Assert.areEqual(Date.newInstance(2026, 11, 3), t.ActivityDate);
    Assert.areEqual('CALL-001', t.Call_Anchor_Call_Id__c);
    Assert.areEqual('Outgoing', t.Call_Anchor_Call_Type__c);
    Assert.areEqual(
      Datetime.newInstanceGmt(2026, 11, 3, 10, 15, 0),
      t.Call_Anchor_Call_Started_At__c
    );
    Assert.areEqual(125, t.Call_Anchor_Duration_Seconds__c);
    Assert.areEqual('Someone Else', t.Call_Anchor_Agent_Name__c);
    Assert.areEqual('9988776655', t.Call_Anchor_Agent_Mobile__c);
    Assert.areEqual(
      'https://example.com/rec/1.mp3',
      t.Call_Anchor_Recording_Url__c
    );
    Assert.areEqual('Interested', t.Call_Anchor_Disposition__c);
    Assert.areEqual('Asked for a callback', t.Call_Anchor_Disposition_Note__c);
    Assert.areEqual(
      Datetime.newInstanceGmt(2026, 11, 4, 9, 0, 0),
      t.Call_Anchor_Callback_Scheduled_At__c
    );
    Assert.isTrue(t.Description.contains('CALL-001'));

    Assert.areEqual('Follow-up - Ravi Kumar', followUp.Subject);
    Assert.areEqual('Not Started', followUp.Status);
    Assert.areEqual(
      recordTypeId('Task'),
      followUp.RecordTypeId,
      'Follow-up uses the Task record type'
    );
    Assert.areEqual('Task', followUp.TaskSubtype);
    Assert.areEqual(l.Id, followUp.WhoId);
    Assert.areEqual(
      Datetime.newInstanceGmt(2026, 11, 4, 9, 0, 0).date(),
      followUp.ActivityDate
    );
    Assert.isTrue(followUp.IsReminderSet);
    Assert.areEqual(
      Datetime.newInstanceGmt(2026, 11, 4, 9, 0, 0),
      followUp.ReminderDateTime
    );
    Assert.isNull(
      followUp.Call_Anchor_Call_Id__c,
      'Call ID stays on the call Task only'
    );
    Assert.areEqual('Interested', followUp.Call_Anchor_Disposition__c);
    Assert.areEqual(
      'Asked for a callback',
      followUp.Call_Anchor_Disposition_Note__c
    );
    Assert.areEqual('Someone Else', followUp.Call_Anchor_Agent_Name__c);
    Assert.areEqual('9988776655', followUp.Call_Anchor_Agent_Mobile__c);
  }

  @IsTest
  static void existingLeadGetsCallAndFollowUp() {
    User caller = callerUser();
    Lead existing;
    System.runAs(caller) {
      existing = new Lead(
        LastName = 'Existing',
        Company = 'Acme',
        Phone = '09876543210'
      );
      insert existing;
    }

    RestResponse res;
    System.runAs(caller) {
      Test.startTest();
      res = post(payload('9876543210', null));
      Test.stopTest();
    }

    Map<String, Object> body = bodyOf(res);
    Assert.areEqual(201, res.statusCode, res.responseBody.toString());
    Assert.areEqual(existing.Id, (Id) recordsOf(res).get('recordId'));
    Assert.areEqual(
      'Matched Lead ' + existing.Id,
      ((List<Object>) body.get('log'))[0]
    );
    Assert.areEqual(1, [SELECT COUNT() FROM Lead]);
    Assert.areEqual(2, [SELECT COUNT() FROM Task WHERE WhoId = :existing.Id]);
  }

  @IsTest
  static void existingContactGetsCallAndFollowUp() {
    User caller = callerUser();
    Contact existing;
    System.runAs(caller) {
      existing = new Contact(LastName = 'Existing', HomePhone = '9876543210');
      insert existing;
    }

    RestResponse res;
    System.runAs(caller) {
      Test.startTest();
      res = post(payload('9876543210', null));
      Test.stopTest();
    }

    Map<String, Object> body = bodyOf(res);
    Assert.areEqual(201, res.statusCode, res.responseBody.toString());
    Assert.areEqual(existing.Id, (Id) recordsOf(res).get('recordId'));
    Assert.isNotNull(recordsOf(res).get('followUpTaskId'));
    Assert.areEqual(0, [SELECT COUNT() FROM Lead]);
    Assert.areEqual(2, [SELECT COUNT() FROM Task WHERE WhoId = :existing.Id]);
  }

  @IsTest
  static void contactWinsWhenLeadAlsoMatches() {
    User caller = callerUser();
    Contact c;
    System.runAs(caller) {
      insert new Lead(
        LastName = 'Lead Match',
        Company = 'Acme',
        MobilePhone = '9876543210'
      );
      c = new Contact(LastName = 'Contact Match', MobilePhone = '9876543210');
      insert c;
    }

    RestResponse res;
    System.runAs(caller) {
      Test.startTest();
      res = post(payload('9876543210', null));
      Test.stopTest();
    }

    Assert.areEqual(201, res.statusCode, res.responseBody.toString());
    Assert.areEqual(c.Id, (Id) recordsOf(res).get('recordId'));
  }

  @IsTest
  static void noCallbackMeansNoFollowUp() {
    User caller = callerUser();
    Contact existing;
    System.runAs(caller) {
      existing = new Contact(LastName = 'Existing', Phone = '9876543210');
      insert existing;
    }

    RestResponse res;
    System.runAs(caller) {
      Test.startTest();
      res = post(payloadWithoutCallback('9876543210', null));
      Test.stopTest();
    }

    Map<String, Object> body = bodyOf(res);
    Assert.areEqual(201, res.statusCode, res.responseBody.toString());
    Assert.isNull(recordsOf(res).get('followUpTaskId'));
    Assert.isTrue(
      recordsOf(res).containsKey('followUpTaskId'),
      'Key is always present'
    );
    Assert.isNotNull(body.get('id'));
    Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE WhoId = :existing.Id]);
  }

  @IsTest
  static void fixedOwnerAndSelectedAgentDetails() {
    Map<String, Object> data = payload('9876543210', null);
    Map<String, Object> call = (Map<String, Object>) data.get('call');
    call.remove('calleeName');
    call.remove('callType');
    call.remove('startedAt');
    ((Map<String, Object>) ((Map<String, Object>) data.get('disposition'))
        .get('fields'))
      .put('select-calling-agent', '  Priya Sharma ');

    RestResponse res;
    System.runAs(callerUser()) {
      Test.startTest();
      res = post(data);
      Test.stopTest();
    }

    Map<String, Object> body = bodyOf(res);
    Assert.areEqual(201, res.statusCode, res.responseBody.toString());

    Lead l = [
      SELECT LastName, OwnerId
      FROM Lead
      WHERE Id = :(Id) recordsOf(res).get('recordId')
    ];
    Assert.areEqual('9876543210', l.LastName);
    Assert.areEqual(OWNER_ID, l.OwnerId);

    Task t = [
      SELECT Subject, OwnerId, ActivityDate
      FROM Task
      WHERE Id = :(Id) recordsOf(res).get('callActivityId')
    ];
    Assert.areEqual('Call Log', t.Subject);
    Assert.areEqual(OWNER_ID, t.OwnerId);
    Assert.areEqual(Date.today(), t.ActivityDate);

    Task followUp = [
      SELECT Subject, OwnerId
      FROM Task
      WHERE Id = :(Id) recordsOf(res).get('followUpTaskId')
    ];
    Assert.areEqual('Follow-up - 9876543210', followUp.Subject);
    Assert.areEqual(OWNER_ID, followUp.OwnerId);
  }

  @IsTest
  static void badRequestsReturn400() {
    Map<String, Object> badPhone = payload('12345', null);

    Map<String, Object> badDate = payload('9876543210', null);
    ((Map<String, Object>) badDate.get('call')).put('startedAt', 'yesterday');

    Map<String, Object> badCallback = payload('9876543210', null);
    ((Map<String, Object>) badCallback.get('call'))
      .put('dispositionScheduledAt', 'tomorrow');

    Map<String, Object> badNumber = payload('9876543210', null);
    ((Map<String, Object>) badNumber.get('call')).put('durationSeconds', 'abc');

    System.runAs(callerUser()) {
      Test.startTest();
      RestResponse empty = post((String) null);
      Assert.areEqual(400, empty.statusCode);
      Assert.areEqual('EMPTY_BODY', errorCode(empty));

      RestResponse notJson = post('{not json');
      Assert.areEqual(400, notJson.statusCode);
      Assert.areEqual('INVALID_JSON', errorCode(notJson));

      RestResponse noCall = post(
        new Map<String, Object>{ 'disposition' => null }
      );
      Assert.areEqual(400, noCall.statusCode);
      Assert.areEqual('MISSING_CALL', errorCode(noCall));

      RestResponse phone = post(badPhone);
      Assert.areEqual(400, phone.statusCode);
      Assert.areEqual('INVALID_PHONE', errorCode(phone));

      RestResponse started = post(badDate);
      Assert.areEqual(400, started.statusCode);
      Assert.areEqual('INVALID_DATE', errorCode(started));

      RestResponse callback = post(badCallback);
      Assert.areEqual(400, callback.statusCode);
      Assert.areEqual('INVALID_DATE', errorCode(callback));

      RestResponse num = post(badNumber);
      Assert.areEqual(400, num.statusCode);
      Assert.areEqual('INVALID_VALUE', errorCode(num));
      Test.stopTest();
    }

    // The failed number conversion happens after the Lead insert, so it must be rolled back.
    Assert.areEqual(0, [SELECT COUNT() FROM Lead]);
    Assert.areEqual(0, [SELECT COUNT() FROM Task]);
  }

  @IsTest
  static void saveFailureReturns422() {
    Map<String, Object> data = payload('9876543210', null);
    // Lead.LastName is limited to 80 characters.
    ((Map<String, Object>) data.get('call')).put('calleeName', 'x'.repeat(120));

    RestResponse res;
    System.runAs(callerUser()) {
      Test.startTest();
      res = post(data);
      Test.stopTest();
    }

    Assert.areEqual(422, res.statusCode);
    Assert.areEqual('SAVE_FAILED', errorCode(res));
  }

  @IsTest
  static void helpers() {
    Assert.isNull(CallAnchorWebhookService.cleanPhone(null));
    Assert.isNull(CallAnchorWebhookService.cleanPhone('123456789'));
    Assert.isNull(CallAnchorWebhookService.cleanPhone('123456789012345'));
    Assert.areEqual(
      '9876543210',
      CallAnchorWebhookService.cleanPhone('+91 (987) 654-3210')
    );

    Map<String, Object> data = new Map<String, Object>{
      'a' => new Map<String, Object>{ 'b' => 'value' }
    };
    Assert.areEqual('value', CallAnchorWebhookService.valueAt(data, 'a.b'));
    Assert.isNull(CallAnchorWebhookService.valueAt(data, 'a.b.c'));
    Assert.isNull(CallAnchorWebhookService.valueAt(data, 'x.y'));
  }

  @IsTest
  static void activityOnAccountUsesWhatId() {
    System.runAs(callerUser()) {
      Account acc = new Account(Name = 'Acme', Phone = '9876543210');
      insert acc;

      Assert.areEqual(
        1,
        CallAnchorWebhookService.findByPhone(
            'Account',
            new List<String>{ 'Phone' },
            '9876543210'
          )
          .size()
      );

      Task t = (Task) CallAnchorWebhookService.createActivity(
        'Task',
        acc.Id,
        new Map<String, String>{ 'Subject' => 'subject' },
        new Map<String, Object>{ 'subject' => 'Hello' }
      );
      Assert.areEqual(
        acc.Id,
        [SELECT WhatId FROM Task WHERE Id = :t.Id].WhatId
      );
    }
  }

  @IsTest
  static void unknownFieldIsConfigError() {
    try {
      CallAnchorWebhookService.createRecord(
        'Lead',
        new Map<String, String>{ 'No_Such_Field__c' => 'v' },
        new Map<String, Object>{ 'v' => 'x' }
      );
      Assert.fail('Expected a CallException');
    } catch (CallAnchorWebhookService.CallException e) {
      Assert.areEqual('CONFIG_ERROR', e.code);
      Assert.areEqual(500, e.status);
    }
  }
}
