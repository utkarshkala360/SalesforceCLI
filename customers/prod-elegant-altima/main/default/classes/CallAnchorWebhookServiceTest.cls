@IsTest
private class CallAnchorWebhookServiceTest {
  private static final String FORMATTED_PHONE = '+91 99439 84451';
  private static final String PLAIN_PHONE = '9876543210';
  private static final String RUNNER_USERNAME = 'callanchor.webhook.runner@test.elegant.example';
  private static final String AGENT_USERNAME = 'callanchor.agent@test.elegant.example';
  private static final String AGENT_PHONE = '+91 90000 00000'; // = basePayload agentNumber
  private static final String INACTIVE_AGENT_PHONE = '9111122222';

  @TestSetup
  static void setup() {
    // The webhook runs as the user who connected Call Anchor, who holds
    // Call_Anchor_Access. New fields have no profile FLS in this org, so tests
    // must run as such a user to read and write the Call Anchor fields.
    // Call_Anchor_Phone_Access lets it set the agents' numbers below.
    User runner = newUser(RUNNER_USERNAME, 'Webhook Runner', 'cawrun');
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert runner;
      List<PermissionSetAssignment> grants = new List<PermissionSetAssignment>();
      for (PermissionSet ps : [
        SELECT Id
        FROM PermissionSet
        WHERE Name IN ('Call_Anchor_Access', 'Call_Anchor_Phone_Access')
      ]) {
        grants.add(
          new PermissionSetAssignment(
            AssigneeId = runner.Id,
            PermissionSetId = ps.Id
          )
        );
      }
      insert grants;
    }
    System.runAs(runner) {
      User agent = newUser(AGENT_USERNAME, 'Agent', 'caagent');
      agent.Call_Anchor_Phone__c = AGENT_PHONE;
      User inactiveAgent = newUser(
        'callanchor.inactive@test.elegant.example',
        'Inactive Agent',
        'cainact'
      );
      inactiveAgent.Call_Anchor_Phone__c = INACTIVE_AGENT_PHONE;
      inactiveAgent.IsActive = false;
      insert new List<User>{ agent, inactiveAgent };
    }

    List<Lead> leads = new List<Lead>{
      new Lead(
        LastName = 'Formatted',
        Company = 'Test',
        Phone = FORMATTED_PHONE
      ),
      new Lead(LastName = 'Plain', Company = 'Test', MobilePhone = PLAIN_PHONE)
    };
    // Bulk noise: 200 Leads with other numbers that must never be matched
    for (Integer i = 0; i < 200; i++) {
      leads.add(
        new Lead(
          LastName = 'Noise ' + i,
          Company = 'Test',
          Phone = '70000' + String.valueOf(10000 + i)
        )
      );
    }
    insert leads;
  }

  // ---------- Helpers ----------

  private static User newUser(String username, String lastName, String alias) {
    return new User(
      ProfileId = [
        SELECT Id
        FROM Profile
        WHERE Name = 'System Administrator'
        LIMIT 1
      ]
      .Id,
      Username = username,
      LastName = lastName,
      Email = alias + '@test.elegant.example',
      Alias = alias,
      TimeZoneSidKey = 'Asia/Kolkata',
      LocaleSidKey = 'en_IN',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US'
    );
  }

  private static Id agentId() {
    return [SELECT Id FROM User WHERE Username = :AGENT_USERNAME].Id;
  }

  private static Map<String, Object> payloadWithAgent(
    String callId,
    String agentNumber
  ) {
    Map<String, Object> payload = basePayload(callId, PLAIN_PHONE, 'Someone');
    ((Map<String, Object>) payload.get('call')).put('agentNumber', agentNumber);
    return payload;
  }

  private static Map<String, Object> basePayload(
    String callId,
    String phone,
    String name
  ) {
    return new Map<String, Object>{
      'event' => 'call.completed',
      'hasRecording' => true,
      'call' => new Map<String, Object>{
        'id' => callId,
        'callType' => 'Outgoing',
        'agentName' => 'Test Agent',
        'agentNumber' => '+919000000000',
        'startedAt' => '2026-10-16T09:59:47.000Z',
        'calleeName' => name,
        'calleePhone' => phone,
        'recordingUrl' => 'https://example.com/rec?t=' + 'x'.repeat(400),
        'durationSeconds' => 7
      }
    };
  }

  private static Map<String, Object> post(Object body) {
    RestRequest req = new RestRequest();
    req.requestURI = '/services/apexrest/CallAnchorWebhook/';
    req.httpMethod = 'POST';
    req.requestBody = body == null
      ? null
      : Blob.valueOf(
          body instanceof String ? (String) body : JSON.serialize(body)
        );
    RestContext.request = req;
    RestContext.response = new RestResponse();

    CallAnchorWebhookService.doPost();

    Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
      RestContext.response.responseBody.toString()
    );
    parsed.put('statusCode', RestContext.response.statusCode);
    return parsed;
  }

  private static Map<String, Object> records(Map<String, Object> res) {
    return (Map<String, Object>) res.get('records');
  }

  private static List<Object> logs(Map<String, Object> res) {
    return (List<Object>) res.get('logs');
  }

  private static User runner() {
    return [SELECT Id FROM User WHERE Username = :RUNNER_USERNAME];
  }

  private static Id leadId(String lastName) {
    return [SELECT Id FROM Lead WHERE LastName = :lastName LIMIT 1].Id;
  }

  // ---------- Matching ----------

  @IsTest
  static void matchesFormattedPhoneViaSosl() {
    System.runAs(runner()) {
      Id formattedId = leadId('Formatted');
      Test.setFixedSearchResults(new List<Id>{ formattedId });

      Test.startTest();
      Map<String, Object> res = post(
        basePayload('c1', '+919943984451', 'Someone')
      );
      Test.stopTest();

      Assert.areEqual(
        200,
        res.get('statusCode'),
        String.valueOf(res.get('logs'))
      );
      Assert.areEqual(
        new Set<String>{ 'taskId', 'records', 'logs', 'statusCode' },
        res.keySet()
      );
      Assert.areEqual(formattedId, records(res).get('leadId'));
      Assert.areEqual(
        new List<Object>{
          'Matched existing Lead ' +
          formattedId +
          ' by phone.',
          'Matched agent user ' +
          agentId() +
          ' by phone; Tasks are owned by that user.',
          'Created call Task ' +
          res.get('taskId') +
          ' (Call - Outgoing).',
          'No callback scheduled; no follow-up Task created.'
        },
        logs(res)
      );
      Task t = [
        SELECT WhoId, OwnerId, Status, TaskSubtype, Call_Anchor_Recording_Url__c
        FROM Task
        WHERE Id = :(Id) res.get('taskId')
      ];
      Assert.areEqual(
        formattedId,
        t.WhoId,
        'Formatted phone should match the existing Lead'
      );
      Assert.areEqual(
        agentId(),
        t.OwnerId,
        'Call Task belongs to the agent whose Call Anchor Phone matches'
      );
      Assert.areEqual('Completed', t.Status);
      Assert.areEqual('Call', t.TaskSubtype);
      // URL fields hold 255 chars; the 400+ char signed URL is truncated, not rejected
      Assert.areEqual(255, t.Call_Anchor_Recording_Url__c.length());
      Assert.areEqual(
        202,
        [SELECT COUNT() FROM Lead],
        'No Lead should be created'
      );
      Assert.isNull(records(res).get('followUpTaskId'));
    }
  }

  @IsTest
  static void matchesPlainPhoneViaSoqlWithoutSearchIndex() {
    System.runAs(runner()) {
      Test.startTest();
      Map<String, Object> res = post(
        basePayload('c2', '+91 98765-43210', 'Someone')
      );
      Test.stopTest();

      Task t = [SELECT WhoId FROM Task WHERE Id = :(Id) res.get('taskId')];
      Assert.areEqual(leadId('Plain'), t.WhoId);
      Assert.areEqual(202, [SELECT COUNT() FROM Lead]);
    }
  }

  @IsTest
  static void rejectsSearchHitWithDifferentDigits() {
    System.runAs(runner()) {
      // SOSL returns a Lead whose number only partially overlaps
      Test.setFixedSearchResults(new List<Id>{ leadId('Plain') });

      Test.startTest();
      Map<String, Object> res = post(
        basePayload('c3', '8765432109', 'Shalu 360DC')
      );
      Test.stopTest();

      Assert.areEqual(
        203,
        [SELECT COUNT() FROM Lead],
        'A new Lead should be created'
      );
      Lead created = [
        SELECT FirstName, LastName, Company, LeadSource, Phone, MobilePhone
        FROM Lead
        WHERE LastName = '360DC'
      ];
      Assert.areEqual('Shalu', created.FirstName);
      Assert.areEqual('360 CallAnchor', created.LeadSource);
      Assert.isNull(
        created.Company,
        'Company is no longer set on auto-created Leads'
      );
      Assert.areEqual('8765432109', created.MobilePhone);
      Task t = [SELECT WhoId FROM Task WHERE Id = :(Id) res.get('taskId')];
      Assert.areEqual(created.Id, t.WhoId);
    }
  }

  @IsTest
  static void createsUnknownCallerWhenNameMissing() {
    System.runAs(runner()) {
      Test.startTest();
      post(basePayload('c4', '9111111111', 'unknown'));
      Test.stopTest();

      Lead created = [
        SELECT FirstName, LastName
        FROM Lead
        WHERE Phone = '9111111111'
      ];
      Assert.areEqual('Unknown', created.FirstName);
      Assert.areEqual('Caller', created.LastName);
    }
  }

  // ---------- Disposition / follow-up ----------

  @IsTest
  static void createsFollowUpWithReminderForFutureCallback() {
    System.runAs(runner()) {
      Datetime future = Datetime.now().addDays(2);
      Map<String, Object> payload = basePayload('c5', PLAIN_PHONE, 'Someone');
      payload.put(
        'disposition',
        new Map<String, Object>{
          'fields' => new Map<String, Object>{
            'outcome' => 'Interested',
            'note' => 12345, // non-string values must not break the cast
            'scheduled-at' => future.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'')
          }
        }
      );

      Test.startTest();
      Map<String, Object> res = post(payload);
      Test.stopTest();

      Task callTask = [
        SELECT Call_Anchor_Disposition__c, Call_Anchor_Disposition_Note__c
        FROM Task
        WHERE Id = :(Id) res.get('taskId')
      ];
      Assert.areEqual('Interested', callTask.Call_Anchor_Disposition__c);
      Assert.areEqual('12345', callTask.Call_Anchor_Disposition_Note__c);

      Task followUp = [
        SELECT
          OwnerId,
          Status,
          TaskSubtype,
          ActivityDate,
          ReminderDateTime,
          CallDurationInSeconds,
          Subject
        FROM Task
        WHERE Id = :(Id) records(res).get('followUpTaskId')
      ];
      Assert.areEqual(
        agentId(),
        followUp.OwnerId,
        'Follow-up belongs to the same agent as the call'
      );
      Assert.areEqual('Not Started', followUp.Status);
      Assert.areEqual('Task', followUp.TaskSubtype);
      Assert.areEqual('Follow-up - Call - Outgoing', followUp.Subject);
      Assert.areEqual(future.date(), followUp.ActivityDate);
      Assert.isNotNull(followUp.ReminderDateTime);
      Assert.isNull(followUp.CallDurationInSeconds);
    }
  }

  @IsTest
  static void fallsBackToCallLevelDispositionAndSkipsPastReminder() {
    System.runAs(runner()) {
      Map<String, Object> payload = basePayload('c6', PLAIN_PHONE, 'Someone');
      Map<String, Object> call = (Map<String, Object>) payload.get('call');
      call.put('dispositionLabel', 'Not Reachable');
      call.put('dispositionNote', 'Switched off');
      call.put('dispositionScheduledAt', '2020-01-01T10:00:00.000Z');
      payload.put('disposition', 'not-a-map');

      Test.startTest();
      Map<String, Object> res = post(payload);
      Test.stopTest();

      Task callTask = [
        SELECT Call_Anchor_Disposition__c, Call_Anchor_Disposition_Note__c
        FROM Task
        WHERE Id = :(Id) res.get('taskId')
      ];
      Assert.areEqual('Not Reachable', callTask.Call_Anchor_Disposition__c);
      Assert.areEqual('Switched off', callTask.Call_Anchor_Disposition_Note__c);
      Task followUp = [
        SELECT IsReminderSet, ReminderDateTime
        FROM Task
        WHERE Id = :(Id) records(res).get('followUpTaskId')
      ];
      Assert.isFalse(followUp.IsReminderSet);
      Assert.isNull(followUp.ReminderDateTime);
    }
  }

  // ---------- Agent → Task owner ----------

  @IsTest
  static void unmappedAgentLeavesIntegrationUserAsOwner() {
    System.runAs(runner()) {
      Test.startTest();
      Map<String, Object> res = post(payloadWithAgent('o1', '+91 12345 67890'));
      Test.stopTest();

      Task t = [SELECT OwnerId FROM Task WHERE Id = :(Id) res.get('taskId')];
      Assert.areEqual(runner().Id, t.OwnerId);
      Assert.isTrue(
        String.valueOf(logs(res))
          .contains('No active user has a matching Call Anchor Phone')
      );
    }
  }

  @IsTest
  static void inactiveAgentIsNotUsedAsOwner() {
    System.runAs(runner()) {
      Test.startTest();
      Map<String, Object> res = post(
        payloadWithAgent('o2', INACTIVE_AGENT_PHONE)
      );
      Test.stopTest();

      Task t = [SELECT OwnerId FROM Task WHERE Id = :(Id) res.get('taskId')];
      Assert.areEqual(
        runner().Id,
        t.OwnerId,
        'Inactive users cannot own Tasks'
      );
    }
  }

  @IsTest
  static void missingOrShortAgentNumberLeavesIntegrationUserAsOwner() {
    System.runAs(runner()) {
      Test.startTest();
      Map<String, Object> missing = post(payloadWithAgent('o3', null));
      Map<String, Object> shortNo = post(payloadWithAgent('o4', '00000'));
      Test.stopTest();

      for (
        Map<String, Object> res : new List<Map<String, Object>>{
          missing,
          shortNo
        }
      ) {
        Assert.areEqual(
          200,
          res.get('statusCode'),
          String.valueOf(res.get('logs'))
        );
        Assert.areEqual(
          runner().Id,
          [SELECT OwnerId FROM Task WHERE Id = :(Id) res.get('taskId')].OwnerId
        );
      }
    }
  }

  // ---------- Idempotency ----------

  @IsTest
  static void retryWithSameCallIdReturnsExistingTasks() {
    System.runAs(runner()) {
      Map<String, Object> payload = basePayload(
        'dup-1',
        '7777777777',
        'Retry Person'
      );
      payload.put(
        'disposition',
        new Map<String, Object>{
          'fields' => new Map<String, Object>{
            'scheduled-at' => '2030-01-01T10:00:00Z'
          }
        }
      );

      Test.startTest();
      Map<String, Object> first = post(payload);
      Map<String, Object> second = post(payload);
      Test.stopTest();

      Assert.areEqual(first.get('taskId'), second.get('taskId'));
      Assert.isNotNull(records(first).get('followUpTaskId'));
      Assert.areEqual(
        records(first),
        records(second),
        'Retry returns the same leadId and followUpTaskId'
      );
      Assert.isTrue(((String) logs(second)[0]).contains('already logged'));
      Assert.areEqual(
        2,
        [SELECT COUNT() FROM Task WHERE Call_Anchor_Call_Id__c = 'dup-1']
      );
      Assert.areEqual(1, [SELECT COUNT() FROM Lead WHERE Phone = '7777777777']);
    }
  }

  // ---------- Invalid input ----------

  @IsTest
  static void rejectsEmptyBody() {
    System.runAs(runner()) {
      Map<String, Object> res = post(null);
      Assert.areEqual(400, res.get('statusCode'));
      Assert.isNull(res.get('taskId'));
      Assert.isTrue(records(res).isEmpty());
      Assert.areEqual(new List<Object>{ 'Empty request body.' }, logs(res));
    }
  }

  @IsTest
  static void rejectsMalformedJson() {
    System.runAs(runner()) {
      Map<String, Object> res = post('{not json');
      Assert.areEqual(400, res.get('statusCode'));
      Assert.isTrue(((String) logs(res)[0]).startsWith('Malformed payload'));
    }
  }

  @IsTest
  static void rejectsMissingPhone() {
    System.runAs(runner()) {
      Map<String, Object> res = post(basePayload('c7', '  ', 'Someone'));
      Assert.areEqual(400, res.get('statusCode'));
      Assert.areEqual(
        new List<Object>{ 'calleePhone is required.' },
        logs(res)
      );
      // Count only webhook Tasks: org automation also creates Tasks on Lead insert
      Assert.areEqual(
        0,
        [SELECT COUNT() FROM Task WHERE Call_Anchor_Call_Id__c != NULL]
      );
    }
  }

  @IsTest
  static void phoneWithoutDigitsCreatesNewLead() {
    System.runAs(runner()) {
      Test.startTest();
      Map<String, Object> res = post(
        basePayload('c8', 'private', 'Hidden Number')
      );
      Test.stopTest();

      Assert.areEqual(
        200,
        res.get('statusCode'),
        String.valueOf(res.get('logs'))
      );
      Assert.areEqual(203, [SELECT COUNT() FROM Lead]);
    }
  }
}
