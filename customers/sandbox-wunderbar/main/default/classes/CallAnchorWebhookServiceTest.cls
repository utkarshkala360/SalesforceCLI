@IsTest
private class CallAnchorWebhookServiceTest {
  private static final String FATHER_PHONE = '9876543210';
  private static final String MOTHER_PHONE = '9123456780';
  private static final String AGENT_USERNAME = 'callanchor.agent@wunderbar.test';
  private static final String AGENT_PHONE = '9000000000';
  private static final String SELECT_BRAND = 'mindseed-balewadi';

  // The service writes Task fields in user mode, so calls run as a user holding the
  // Call Anchor permission set.
  @TestSetup
  static void createAgent() {
    // The Lead "Round Robin flow" increments these counters when a brand is set.
    insert new Auto_No__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      RR_Auto_No__c = 0
    );
    insert new Auto_No_FD__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      RR_Auto_No_FD__c = 0
    );

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

  // Maps AGENT_PHONE to the test agent; records below are owned by that agent.
  private static User mapAgent() {
    User user = agent();
    CallAnchorWebhookService.AGENTS.put(
      AGENT_PHONE,
      new CallAnchorWebhookService.Agent(user.Id, 'PreSales')
    );
    return user;
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
    return createOpportunity(fatherPhone, 'Mindseed', 'Pune', 'Balewadi');
  }

  private static Opportunity createOpportunity(
    String fatherPhone,
    String brand,
    String region,
    String location
  ) {
    Opportunity opp = new Opportunity(
      Name = 'Test Opportunity',
      StageName = 'School Visit Scheduled',
      CloseDate = Date.today().addDays(30),
      OwnerId = agent().Id
    );
    opp.put('Fathers_Contact_No__c', stored(fatherPhone));
    opp.put('Brand__c', brand);
    opp.put('Region__c', region);
    opp.put('Location__c', location);
    fillRequiredPicklists(opp);
    insert opp;
    return opp;
  }

  private static Lead createLead(String fatherPhone, String motherPhone) {
    Lead lead = new Lead(LastName = 'Test Lead', Company = 'Test Lead');
    lead.put('Company_Brand__c', 'Mindseed');
    lead.put('Region__c', 'Pune');
    lead.put('Location__c', 'Balewadi');
    lead.put('Father_Name__c', 'Test Father');
    lead.put('Fathers_Contact_No__c', stored(fatherPhone));
    if (motherPhone != null) {
      lead.put('Mother_s_name__c', 'Test Mother');
      lead.put('Mothers_Contact_No__c', stored(motherPhone));
    }
    fillRequiredPicklists(lead);
    insert lead;
    // The "Round Robin flow" assigns an owner on insert, so set the agent afterwards.
    update new Lead(Id = lead.Id, OwnerId = agent().Id);
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
        'agentNumber' => '+91 ' + AGENT_PHONE,
        'recordingUrl' => 'https://example.com/recording.mp3',
        'dispositionNote' => 'Asked for a callback',
        'dispositionScheduledAt' => '2026-10-05T09:00:00Z'
      },
      'disposition' => new Map<String, Object>{
        'fields' => new Map<String, Object>{
          'outcome' => 'Interested',
          'select-brand' => SELECT_BRAND
        }
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
    System.runAs(mapAgent()) {
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

    // The follow-up Task carries the same call fields as the call Task.
    Task followUp = taskFor(result.get('followUpId'));
    Assert.areEqual(opp.Id, followUp.WhatId);
    Assert.areEqual('Follow Up Call - Rahul Sharma', followUp.Subject);
    Assert.areEqual(Date.newInstance(2026, 10, 5), followUp.ActivityDate);
    Assert.areEqual('Asked for a callback', followUp.Description);
    for (
      String field : new List<String>{
        'Call_Anchor_Call_Id__c',
        'Call_Anchor_Call_Type__c',
        'Call_Anchor_Call_Started_At__c',
        'Call_Anchor_Duration_Seconds__c',
        'Call_Anchor_Agent_Name__c',
        'Call_Anchor_Recording_Url__c',
        'Call_Anchor_Disposition__c',
        'Call_Anchor_Disposition_Note__c',
        'Call_Anchor_Callback_Scheduled_At__c'
      }
    ) {
      Assert.areEqual(task.get(field), followUp.get(field), field);
    }

    // 2026-10-05T09:00Z is 14:30 in the agent's Asia/Kolkata time zone.
    Opportunity updated = (Opportunity) Database.query(
      'SELECT Next_followup_date__c, Next_Follow_up_Time__c FROM Opportunity WHERE Id = \'' +
        opp.Id +
        '\''
    );
    Assert.areEqual(
      Date.newInstance(2026, 10, 5),
      updated.get('Next_followup_date__c')
    );
    Assert.areEqual(
      Time.newInstance(14, 30, 0, 0),
      updated.get('Next_Follow_up_Time__c')
    );
  }

  @IsTest
  static void prefersOpportunityOverLead() {
    Opportunity opp = createOpportunity(FATHER_PHONE);
    createLead(FATHER_PHONE, null);

    RestResponse res;
    Test.startTest();
    System.runAs(mapAgent()) {
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
    System.runAs(mapAgent()) {
      res = post(callPayload('0' + MOTHER_PHONE));
    }
    Test.stopTest();

    Assert.areEqual(201, res.statusCode, res.responseBody.toString());
    Map<String, Object> result = body(res);
    Assert.areEqual(lead.Id, (Id) result.get('recordId'));

    Task task = taskFor(result.get('activityId'));
    Assert.areEqual(lead.Id, task.WhoId);
    Assert.isNull(task.WhatId);

    Lead updated = (Lead) Database.query(
      'SELECT Next_Follow_up_Date__c, Next_Follow_up_Time__c FROM Lead WHERE Id = \'' +
        lead.Id +
        '\''
    );
    Assert.areEqual(
      Date.newInstance(2026, 10, 5),
      updated.get('Next_Follow_up_Date__c')
    );
    Assert.areEqual(
      Time.newInstance(14, 30, 0, 0),
      updated.get('Next_Follow_up_Time__c')
    );
  }

  @IsTest
  static void setsFollowUpReminderBeforeCallback() {
    createLead(FATHER_PHONE, null);
    Datetime callbackAt = Datetime.now().addDays(1);
    Map<String, Object> payload = callPayload(FATHER_PHONE);
    ((Map<String, Object>) payload.get('call'))
      .put('dispositionScheduledAt', JSON.serialize(callbackAt).remove('"'));

    RestResponse res;
    Test.startTest();
    System.runAs(mapAgent()) {
      res = post(payload);
    }
    Test.stopTest();

    Assert.areEqual(201, res.statusCode, res.responseBody.toString());
    Task followUp = [
      SELECT IsReminderSet, ReminderDateTime
      FROM Task
      WHERE Id = :(Id) body(res).get('followUpId')
    ];
    Assert.isTrue(followUp.IsReminderSet);
    Assert.areEqual(
      callbackAt.addMinutes(-15).getTime() / 1000,
      followUp.ReminderDateTime.getTime() / 1000
    );
  }

  @IsTest
  static void leavesNextFollowUpWhenNoCallbackScheduled() {
    Lead lead = createLead(FATHER_PHONE, null);
    Map<String, Object> payload = callPayload(FATHER_PHONE);
    ((Map<String, Object>) payload.get('call'))
      .remove('dispositionScheduledAt');

    RestResponse res;
    Test.startTest();
    System.runAs(mapAgent()) {
      res = post(payload);
    }
    Test.stopTest();

    Assert.areEqual(201, res.statusCode, res.responseBody.toString());
    Assert.isNull(body(res).get('followUpId'));
    Lead updated = (Lead) Database.query(
      'SELECT Next_Follow_up_Date__c, Next_Follow_up_Time__c FROM Lead WHERE Id = \'' +
        lead.Id +
        '\''
    );
    Assert.isNull(updated.get('Next_Follow_up_Date__c'));
    Assert.isNull(updated.get('Next_Follow_up_Time__c'));
  }

  @IsTest
  static void defaultsSubjectAndDateWhenMissing() {
    Lead lead = createLead(FATHER_PHONE, null);
    Map<String, Object> payload = new Map<String, Object>{
      'call' => new Map<String, Object>{
        'calleePhone' => FATHER_PHONE,
        'agentNumber' => AGENT_PHONE
      },
      'disposition' => new Map<String, Object>{
        'fields' => new Map<String, Object>{ 'select-brand' => SELECT_BRAND }
      }
    };

    RestResponse res;
    Test.startTest();
    System.runAs(mapAgent()) {
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
  static void logsUnrelatedTasksWhenNoRecordMatches() {
    RestResponse res;
    Test.startTest();
    System.runAs(mapAgent()) {
      res = post(callPayload(FATHER_PHONE));
    }
    Test.stopTest();

    Assert.areEqual(201, res.statusCode, res.responseBody.toString());
    Map<String, Object> result = body(res);
    Assert.areEqual(true, result.get('success'));
    Assert.isTrue(
      ((String) result.get('message'))
        .startsWith('No Opportunity or Lead found')
    );
    Assert.isNull(result.get('recordId'));
    Assert.areEqual(0, [SELECT COUNT() FROM Lead]);

    Task task = taskFor(result.get('activityId'));
    Assert.isNull(task.WhoId);
    Assert.isNull(task.WhatId);
    Task followUp = taskFor(result.get('followUpId'));
    Assert.isNull(followUp.WhoId);
    Assert.isNull(followUp.WhatId);
    Assert.areEqual(2, [SELECT COUNT() FROM Task]);
  }

  @IsTest
  static void createsLeadWhenNoRecordMatchesAndFlagIsOn() {
    CallAnchorWebhookService.CREATE_LEAD_WHEN_NOT_FOUND = true;

    RestResponse res;
    Test.startTest();
    System.runAs(mapAgent()) {
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
  static void picksMostRecentlyCreatedOpportunity() {
    Opportunity older = createOpportunity(FATHER_PHONE);
    // The org blocks a second Opportunity with the same number and location.
    PreventDuplicateContactsOppHandler.isTestBypass = true;
    Opportunity newer = createOpportunity(FATHER_PHONE);
    Test.setCreatedDate(older.Id, Datetime.now().addDays(-2));
    Test.setCreatedDate(newer.Id, Datetime.now().addDays(-1));

    RestResponse res;
    Test.startTest();
    System.runAs(mapAgent()) {
      res = post(callPayload(FATHER_PHONE));
    }
    Test.stopTest();

    Assert.areEqual(201, res.statusCode, res.responseBody.toString());
    Map<String, Object> result = body(res);
    Assert.areEqual(newer.Id, (Id) result.get('recordId'));
    String log = String.join((List<Object>) result.get('log'), '\n');
    Assert.isTrue(log.contains('[Webhook] Received call CALL-001'), log);
    Assert.isTrue(log.contains('[Salesforce] Call_Anchor_Agent__mdt'), log);
    Assert.isTrue(log.contains('[Mapping] Opportunity.Location__c'), log);
    Assert.isTrue(log.contains('): 2 found'), log);
    Assert.isTrue(log.contains('[Decision] Call mapped to Opportunity'), log);
    Assert.isTrue(log.contains('most recently created of 2'), log);
  }

  @IsTest
  static void fallsBackToLeadWhenOpportunityBrandOrLocationDiffers() {
    createOpportunity(FATHER_PHONE, 'Mindseed', 'Pune', 'Aundh');
    createOpportunity(FATHER_PHONE, 'Foundree', 'F-Pune', 'Baner');
    Lead lead = createLead(FATHER_PHONE, null);

    RestResponse res;
    Test.startTest();
    System.runAs(mapAgent()) {
      res = post(callPayload(FATHER_PHONE));
    }
    Test.stopTest();

    Assert.areEqual(201, res.statusCode, res.responseBody.toString());
    Assert.areEqual(lead.Id, (Id) body(res).get('recordId'));
  }

  @IsTest
  static void ignoresRecordsOwnedByAnotherUser() {
    Opportunity opp = createOpportunity(FATHER_PHONE);
    opp.OwnerId = UserInfo.getUserId();
    update opp;

    RestResponse res;
    Test.startTest();
    System.runAs(mapAgent()) {
      res = post(callPayload(FATHER_PHONE));
    }
    Test.stopTest();

    Assert.areEqual(201, res.statusCode, res.responseBody.toString());
    Assert.isNull(body(res).get('recordId'));
    Assert.isNull(taskFor(body(res).get('activityId')).WhatId);
  }

  @IsTest
  static void matchesLocationByLabel() {
    // Opportunity stores "New Panvel 19" with API name "Panvel 19".
    Opportunity opp = createOpportunity(
      FATHER_PHONE,
      'Mindseed',
      'Navi Mumbai',
      'Panvel 19'
    );
    Map<String, Object> payload = callPayload(FATHER_PHONE);
    ((Map<String, Object>) ((Map<String, Object>) payload.get('disposition'))
        .get('fields'))
      .put('select-brand', 'mindseed-new-panvel-19');

    RestResponse res;
    Test.startTest();
    System.runAs(mapAgent()) {
      res = post(payload);
    }
    Test.stopTest();

    Assert.areEqual(201, res.statusCode, res.responseBody.toString());
    Assert.areEqual(opp.Id, (Id) body(res).get('recordId'));
  }

  @IsTest
  static void skipsCallFromUnmappedAgent() {
    createOpportunity(FATHER_PHONE);

    RestResponse res;
    Test.startTest();
    System.runAs(agent()) {
      res = post(callPayload(FATHER_PHONE));
    }
    Test.stopTest();

    Assert.areEqual(200, res.statusCode, res.responseBody.toString());
    Assert.isTrue(
      ((String) body(res).get('message')).contains('not in the agent map')
    );
    Assert.areEqual(0, [SELECT COUNT() FROM Task]);
  }

  @IsTest
  static void skipsCallWithoutSelectBrand() {
    createOpportunity(FATHER_PHONE);
    Map<String, Object> payload = callPayload(FATHER_PHONE);
    ((Map<String, Object>) ((Map<String, Object>) payload.get('disposition'))
        .get('fields'))
      .put('select-brand', 'mindseed');

    RestResponse res;
    Test.startTest();
    System.runAs(mapAgent()) {
      res = post(payload);
    }
    Test.stopTest();

    Assert.areEqual(200, res.statusCode, res.responseBody.toString());
    Assert.isTrue(
      ((String) body(res).get('message')).contains('brand-location')
    );
    Assert.areEqual(0, [SELECT COUNT() FROM Task]);
  }

  @IsTest
  static void loadsActiveAgentsFromMetadata() {
    Map<String, CallAnchorWebhookService.Agent> agents = CallAnchorWebhookService.loadAgents();
    Integer active = 0;
    for (
      Call_Anchor_Agent__mdt record : Call_Anchor_Agent__mdt.getAll().values()
    ) {
      if (
        record.Active__c &&
        CallAnchorWebhookService.cleanPhone(record.Phone__c) != null
      ) {
        Assert.areEqual(
          record.User_Id__c,
          agents.get(CallAnchorWebhookService.cleanPhone(record.Phone__c))
            .userId
        );
        active++;
      }
    }
    Assert.isTrue(agents.size() <= active);
  }

  @IsTest
  static void picklistValueIgnoresCaseAndPunctuation() {
    Assert.areEqual(
      'Wakad - Chaudhary Park',
      CallAnchorWebhookService.picklistValue(
        'Opportunity',
        'Location__c',
        'wakad-chaudhary-park'
      )
    );
    Assert.areEqual(
      'Mindseed',
      CallAnchorWebhookService.picklistValue(
        'Lead',
        'Company_Brand__c',
        'mindseed'
      )
    );
    Assert.isNull(
      CallAnchorWebhookService.picklistValue('Lead', 'Location__c', 'nowhere')
    );
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

    mapAgent();
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
