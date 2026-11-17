@IsTest
private class CallAnchorRecordingLinkerTest {
  private static final String CALL_ID = 'call-123';
  private static final String USERNAME_PREFIX = 'callanchor.linker@';

  // Runs as a user with only the Call Anchor permission set, like the
  // Call Anchor integration user that uploads recordings in the org.
  @TestSetup
  static void createIntegrationUser() {
    User integrationUser = new User(
      ProfileId = UserInfo.getProfileId(),
      Username = USERNAME_PREFIX + UserInfo.getOrganizationId() + '.test',
      Email = 'callanchor.test@example.com',
      LastName = 'Call Anchor',
      Alias = 'calink',
      TimeZoneSidKey = 'Asia/Kolkata',
      LocaleSidKey = 'en_IN',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US'
    );
    insert integrationUser;
    insert new PermissionSetAssignment(
      AssigneeId = integrationUser.Id,
      PermissionSetId = [
        SELECT Id
        FROM PermissionSet
        WHERE Name = 'Call_Anchor_Access'
      ]
      .Id
    );
  }

  private static User integrationUser() {
    String pattern = USERNAME_PREFIX + '%';
    return [SELECT Id FROM User WHERE Username LIKE :pattern LIMIT 1];
  }

  private static List<Task> createTasks(String callId, Integer count) {
    List<Task> tasks = new List<Task>();
    for (Integer i = 0; i < count; i++) {
      tasks.add(
        new Task(
          Subject = 'Call ' + i,
          Status = 'Completed',
          Call_Anchor_Call_Id__c = callId
        )
      );
    }
    insert tasks;
    return tasks;
  }

  private static Id upload(Id taskId, String fileName) {
    ContentVersion version = new ContentVersion(
      Title = fileName,
      PathOnClient = fileName,
      VersionData = Blob.valueOf('audio'),
      FirstPublishLocationId = taskId
    );
    insert version;
    return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :version.Id]
    .ContentDocumentId;
  }

  private static Set<Id> linkedTasks(Id documentId) {
    Set<Id> result = new Set<Id>();
    for (ContentDocumentLink link : [
      SELECT LinkedEntityId
      FROM ContentDocumentLink
      WHERE ContentDocumentId = :documentId
    ]) {
      if (link.LinkedEntityId.getSObjectType() == Task.SObjectType)
        result.add(link.LinkedEntityId);
    }
    return result;
  }

  @IsTest
  static void uploadToOneTaskIsSharedWithTheWholeCall() {
    System.runAs(integrationUser()) {
      List<Task> callTasks = createTasks(CALL_ID, 3);
      Task otherCall = createTasks('other-call', 1)[0];

      Test.startTest();
      Id documentId = upload(callTasks[1].Id, 'recording.m4a');
      Test.stopTest();

      Assert.areEqual(
        new Map<Id, Task>(callTasks).keySet(),
        linkedTasks(documentId),
        'One File must be linked to every Task of the call'
      );
      Assert.isFalse(linkedTasks(documentId).contains(otherCall.Id));
      Assert.areEqual(
        1,
        [SELECT COUNT() FROM ContentDocument WHERE Id = :documentId]
      );
    }
  }

  @IsTest
  static void nonAudioFilesAreNotShared() {
    System.runAs(integrationUser()) {
      List<Task> callTasks = createTasks(CALL_ID, 2);

      Test.startTest();
      Id documentId = upload(callTasks[0].Id, 'notes.txt');
      Test.stopTest();

      Assert.areEqual(new Set<Id>{ callTasks[0].Id }, linkedTasks(documentId));
    }
  }

  @IsTest
  static void tasksCreatedAfterUploadReceiveExistingFile() {
    System.runAs(integrationUser()) {
      List<Task> callTasks = createTasks(CALL_ID, 1);
      Id documentId = upload(callTasks[0].Id, 'recording.m4a');
      List<Task> later = createTasks(CALL_ID, 2);

      Test.startTest();
      Integer created = CallAnchorRecordingLinker.linkCallRecordings(
        new Map<Id, Task>(later).keySet()
      );
      Integer repeated = CallAnchorRecordingLinker.linkCallRecordings(
        new Map<Id, Task>(later).keySet()
      );
      Test.stopTest();

      Assert.areEqual(2, created);
      Assert.areEqual(0, repeated, 'Re-running must not duplicate links');
      Assert.areEqual(3, linkedTasks(documentId).size());
    }
  }

  @IsTest
  static void tasksWithoutCallIdAreIgnored() {
    System.runAs(integrationUser()) {
      Task plain = new Task(Subject = 'Plain', Status = 'Completed');
      insert plain;
      Test.startTest();
      Id documentId = upload(plain.Id, 'recording.m4a');
      Integer created = CallAnchorRecordingLinker.linkCallRecordings(
        new Set<Id>{ plain.Id }
      );
      Test.stopTest();
      Assert.areEqual(0, created);
      Assert.areEqual(new Set<Id>{ plain.Id }, linkedTasks(documentId));
    }
  }
}
