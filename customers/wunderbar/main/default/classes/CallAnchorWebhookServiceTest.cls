@IsTest
private class CallAnchorWebhookServiceTest {
  private static final String FATHER_PHONE = '9876543210';
  private static final String MOTHER_PHONE = '9123456780';
  private static final String AGENT_USERNAME = 'callanchor.agent@wunderbar.test';

  // The service writes Task fields in user mode, so calls run as a user holding the
  // Call Anchor permission set.
  @TestSetup
  static void createAgent() {
    Profile admin = [
      SELECT Id
      FROM Profile
      WHERE Name = 'System Administrator'
    ];
    User agent = new User(
      Alias = 'caagent',
      Email = AGENT_USERNAME,
      Username = AGENT_USERNAME + '.' + System.currentTimeMillis(),
      LastName = 'Agent',
      ProfileId = admin.Id,
      TimeZoneSidKey = 'Asia/Kolkata',
      LocaleSidKey = 'en_IN',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US'
    );
    insert agent;
    insert new PermissionSetAssignment(
      AssigneeId = agent.Id,
      PermissionSetId = [
        SELECT Id
        FROM PermissionSet
        WHERE Name = 'Call_Anchor_Access'
      ]
      .Id
    );
  }

  private static User agent() {
    return [SELECT Id FROM User WHERE Email = :AGENT_USERNAME LIMIT 1];
  }

  // Wunderbar stores parent phones as +91XXXXXXXXXX (enforced by validation rules).
  private static String stored(String phone) {
    return phone == null ? null : '+91' + phone;
  }

  // Required picklists (e.g. Location__c) are filled with the first active value so the
  // test survives picklist changes in the org.
  private static void fillRequiredPicklists(SObject record) {
    Map<String, Schema.SObjectField> fields = record.getSObjectType()
      .getDescribe()
      .fields.getMap();
    for (Schema.SObjectField field : fields.values()) {
      Schema.DescribeFieldResult describe = field.getDescribe();
      Boolean required =
        describe.isCreateable() &&
        !describe.isNillable() &&
        !describe.isDefaultedOnCreate();
      if (
        !required ||
        record.get(describe.getName()) != null ||
        (describe.getType() != Schema.DisplayType.PICKLIST &&
        describe.getType() != Schema.DisplayType.MULTIPICKLIST)
      ) {
        continue;
      }
      for (Schema.PicklistEntry entry : describe.getPicklistValues()) {
        if (entry.isActive()) {
          record.put(describe.getName(), entry.getValue());
          break;
        }
      }
    }
  }

  private static Opportunity createOpportunity(String fatherPhone) {
    Opportunity opp = new Opportunity(
      Name = 'Test Opportunity',
      StageName = 'School Visit Scheduled',
      CloseDate = Date.today().addDays(30)
    );
    opp.put('Fathers_Contact_No__c', stored(fatherPhone));
    fillRequiredPicklists(opp);
    insert opp;
    return opp;
  }

  private static Lead createLead(String fatherPhone, String motherPhone) {
    Lead lead = new Lead(LastName = 'Test Lead', Company = 'Test Lead');
    lead.put('Father_Name__c', 'Test Father');
    lead.put('Fathers_Contact_No__c', stored(fatherPhone));
    if (motherPhone != null) {
      lead.put('Mother_s_name__c', 'Test Mother');
      lead.put('Mothers_Contact_No__c', stored(motherPhone));
    }
    fillRequiredPicklists(lead);
    insert lead;
    return lead;
  }

  private static Map<String, Object> callPayload(String phone) {
    return new Map<String, Object>{
      'call' => new Map<String, Object>{
        'id' => 'CALL-001',
        'callType' => 'Outgoing',
        'calleePhone' => phone,
        'calleeName' => 'Rahul Sharma',
        'startedAt' => '2026-10-01T10:15:30Z',
        'durationSeconds' => 125,
        'agentName' => 'Agent Smith',
        'agentNumber' => '9000000000',
        'recordingUrl' => 'https://example.com/recording.mp3',
        'dispositionNote' => 'Asked for a callback',
        'dispositionScheduledAt' => '2026-10-05T09:00:00Z'
      },
      'disposition' => new Map<String, Object>{
        'fields' => new Map<String, Object>{ 'outcome' => 'Interested' }
      }
    };
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

  private static RestResponse post(Map<String, Object> payload) {
    return post(JSON.serialize(payload));
  }

  private static Map<String, Object> body(RestResponse res) {
    return (Map<String, Object>) JSON.deserializeUntyped(
      res.responseBody.toString()
    );
  }

  private static void assertError(
    RestResponse res,
    Integer status,
    String code
  ) {
    Assert.areEqual(status, res.statusCode, res.responseBody.toString());
    Map<String, Object> result = body(res);
    Assert.areEqual(false, result.get('success'));
    Assert.areEqual(
      code,
      ((Map<String, Object>) result.get('error')).get('code')
    );
  }

  private static Task taskFor(Object activityId) {
    return [
      SELECT
        Subject,
        Status,
        ActivityDate,
        WhoId,
        WhatId,
        Description,
        Call_Anchor_Call_Id__c,
        Call_Anchor_Call_Type__c,
        Call_Anchor_Call_Started_At__c,
        Call_Anchor_Duration_Seconds__c,
        Call_Anchor_Agent_Name__c,
        Call_Anchor_Recording_Url__c,
        Call_Anchor_Disposition__c,
        Call_Anchor_Disposition_Note__c,
        Call_Anchor_Callback_Scheduled_At__c
      FROM Task
      WHERE Id = :(Id) activityId
    ];
  }

  @IsTest
  static void logsCallAgainstMatchingOpportunity() {
    Opportunity opp = createOpportunity(FATHER_PHONE);

    RestResponse res;
    Test.startTest();
    System.runAs(agent()) {
      res = post(callPayload('+91 98765 43210'));
    }
    Test.stopTest();

    Assert.areEqual(201, res.statusCode, res.responseBody.toString());
    Map<String, Object> result = body(res);
    Assert.areEqual(true, result.get('success'));
    Assert.areEqual(opp.Id, (Id) result.get('recordId'));

    Task task = taskFor(result.get('activityId'));
    Assert.areEqual(opp.Id, task.WhatId);
    Assert.isNull(task.WhoId);
    Assert.areEqual('Call - Outgoing', task.Subject);
    Assert.areEqual('Completed', task.Status);
    Assert.areEqual(Date.newInstance(2026, 10, 1), task.ActivityDate);
    Assert.areEqual('CALL-001', task.Call_Anchor_Call_Id__c);
    Assert.areEqual('Outgoing', task.Call_Anchor_Call_Type__c);
    Assert.areEqual(
      Datetime.newInstanceGmt(2026, 10, 1, 10, 15, 30),
      task.Call_Anchor_Call_Started_At__c
    );
    Assert.areEqual(125, task.Call_Anchor_Duration_Seconds__c);
    Assert.areEqual('Agent Smith', task.Call_Anchor_Agent_Name__c);
    Assert.areEqual(
      'https://example.com/recording.mp3',
      task.Call_Anchor_Recording_Url__c
    );
    Assert.areEqual('Interested', task.Call_Anchor_Disposition__c);
    Assert.areEqual(
      'Asked for a callback',
      task.Call_Anchor_Disposition_Note__c
    );
    Assert.areEqual(
      Datetime.newInstanceGmt(2026, 10, 5, 9, 0, 0),
      task.Call_Anchor_Callback_Scheduled_At__c
    );
    Assert.isTrue(task.Description.contains('CALL-001'));
  }

  @IsTest
  static void prefersOpportunityOverLead() {
    Opportunity opp = createOpportunity(FATHER_PHONE);
    createLead(FATHER_PHONE, null);

    RestResponse res;
    Test.startTest();
    System.runAs(agent()) {
      res = post(callPayload(FATHER_PHONE));
    }
    Test.stopTest();

    Assert.areEqual(201, res.statusCode, res.responseBody.toString());
    Assert.areEqual(opp.Id, (Id) body(res).get('recordId'));
  }

  @IsTest
  static void logsCallAgainstLeadMatchedOnMotherPhone() {
    Lead lead = createLead(FATHER_PHONE, MOTHER_PHONE);

    RestResponse res;
    Test.startTest();
    System.runAs(agent()) {
      res = post(callPayload('0' + MOTHER_PHONE));
    }
    Test.stopTest();

    Assert.areEqual(201, res.statusCode, res.responseBody.toString());
    Map<String, Object> result = body(res);
    Assert.areEqual(lead.Id, (Id) result.get('recordId'));

    Task task = taskFor(result.get('activityId'));
    Assert.areEqual(lead.Id, task.WhoId);
    Assert.isNull(task.WhatId);
  }

  @IsTest
  static void defaultsSubjectAndDateWhenMissing() {
    Lead lead = createLead(FATHER_PHONE, null);
    Map<String, Object> payload = new Map<String, Object>{
      'call' => new Map<String, Object>{ 'calleePhone' => FATHER_PHONE }
    };

    RestResponse res;
    Test.startTest();
    System.runAs(agent()) {
      res = post(payload);
    }
    Test.stopTest();

    Assert.areEqual(201, res.statusCode, res.responseBody.toString());
    Task task = taskFor(body(res).get('activityId'));
    Assert.areEqual(lead.Id, task.WhoId);
    Assert.areEqual('Call Log', task.Subject);
    Assert.areEqual(Date.today(), task.ActivityDate);
  }

  @IsTest
  static void createsLeadWhenNoRecordMatches() {
    RestResponse res;
    Test.startTest();
    System.runAs(agent()) {
      res = post(callPayload(FATHER_PHONE));
    }
    Test.stopTest();

    // The org may reject the new Lead (required fields / validation rules); in that
    // case the whole call must roll back and report SAVE_FAILED.
    if (res.statusCode == 422) {
      assertError(res, 422, 'SAVE_FAILED');
      Assert.areEqual(0, [SELECT COUNT() FROM Lead]);
      Assert.areEqual(0, [SELECT COUNT() FROM Task]);
      return;
    }

    Assert.areEqual(201, res.statusCode, res.responseBody.toString());
    Map<String, Object> result = body(res);
    Lead lead = (Lead) Database.query(
      'SELECT LastName, Father_Name__c, Fathers_Contact_No__c FROM Lead WHERE Id = \'' +
        String.escapeSingleQuotes((String) result.get('recordId')) +
        '\''
    );
    Assert.areEqual('Rahul Sharma', lead.LastName);
    Assert.areEqual('Rahul Sharma', lead.get('Father_Name__c'));
    Assert.isTrue(
      String.valueOf(lead.get('Fathers_Contact_No__c')).endsWith(FATHER_PHONE)
    );
    Assert.areEqual(lead.Id, taskFor(result.get('activityId')).WhoId);
  }

  @IsTest
  static void rejectsEmptyBody() {
    assertError(post((String) null), 400, 'EMPTY_BODY');
    assertError(post(''), 400, 'EMPTY_BODY');
  }

  @IsTest
  static void rejectsInvalidJson() {
    assertError(post('{not json'), 400, 'INVALID_JSON');
    assertError(post('{"call": "text"}'), 400, 'INVALID_JSON');
  }

  @IsTest
  static void rejectsMissingCall() {
    assertError(post('{"foo": 1}'), 400, 'MISSING_CALL');
  }

  @IsTest
  static void rejectsInvalidPhone() {
    assertError(post(callPayload('12345')), 400, 'INVALID_PHONE');
    assertError(post(callPayload(null)), 400, 'INVALID_PHONE');
  }

  @IsTest
  static void rejectsInvalidStartDate() {
    Map<String, Object> payload = callPayload(FATHER_PHONE);
    ((Map<String, Object>) payload.get('call')).put('startedAt', 'yesterday');

    assertError(post(payload), 400, 'INVALID_DATE');
  }

  @IsTest
  static void rejectsInvalidFieldValueAndRollsBack() {
    createLead(FATHER_PHONE, null);
    Map<String, Object> payload = callPayload(FATHER_PHONE);
    ((Map<String, Object>) payload.get('call'))
      .put('durationSeconds', 'two minutes');

    Test.startTest();
    RestResponse res = post(payload);
    Test.stopTest();

    assertError(res, 400, 'INVALID_VALUE');
    Assert.areEqual(0, [SELECT COUNT() FROM Task]);
  }

  @IsTest
  static void cleanPhoneNormalisesToTenDigits() {
    Assert.areEqual(
      FATHER_PHONE,
      CallAnchorWebhookService.cleanPhone('+91-98765 43210')
    );
    Assert.areEqual(
      FATHER_PHONE,
      CallAnchorWebhookService.cleanPhone(FATHER_PHONE)
    );
    Assert.isNull(CallAnchorWebhookService.cleanPhone(' '));
    Assert.isNull(CallAnchorWebhookService.cleanPhone('987654321'));
    Assert.isNull(CallAnchorWebhookService.cleanPhone('123456789012345'));
  }

  @IsTest
  static void valueAtReadsNestedPaths() {
    Map<String, Object> data = new Map<String, Object>{
      'a' => new Map<String, Object>{ 'b' => 'value' }
    };
    Assert.areEqual('value', CallAnchorWebhookService.valueAt(data, 'a.b'));
    Assert.isNull(CallAnchorWebhookService.valueAt(data, 'a.c'));
    Assert.isNull(CallAnchorWebhookService.valueAt(data, 'a.b.c'));
  }

  @IsTest
  static void reportsMissingConfiguredField() {
    Map<String, Object> values = new Map<String, Object>{
      'calc' => new Map<String, Object>{ 'name' => 'Test' }
    };
    try {
      CallAnchorWebhookService.createRecord(
        'Lead',
        new Map<String, String>{ 'Does_Not_Exist__c' => 'calc.name' },
        values
      );
      Assert.fail('Expected CallException');
    } catch (CallAnchorWebhookService.CallException e) {
      Assert.areEqual(500, e.status);
      Assert.areEqual('CONFIG_ERROR', e.code);
    }
  }

  @IsTest
  static void reportsActivityWithoutLookupToRecord() {
    Lead lead = createLead(FATHER_PHONE, null);
    try {
      CallAnchorWebhookService.createActivity(
        'Account',
        lead.Id,
        new Map<String, String>(),
        new Map<String, Object>()
      );
      Assert.fail('Expected CallException');
    } catch (CallAnchorWebhookService.CallException e) {
      Assert.areEqual('CONFIG_ERROR', e.code);
    }
  }
}
