@IsTest
private class CallAnchorRecordingControllerTest {
  private static Task makeTask() {
    Task record = new Task(Subject = 'Recording player test');
    insert record;
    return record;
  }
  private static ContentVersion addFile(
    Id taskId,
    String title,
    String extension
  ) {
    ContentVersion version = new ContentVersion(
      Title = title,
      PathOnClient = title + '.' + extension,
      VersionData = Blob.valueOf('Synthetic test data, not playable audio'),
      FirstPublishLocationId = taskId
    );
    insert version;
    return [
      SELECT Id, ContentDocumentId
      FROM ContentVersion
      WHERE Id = :version.Id
    ];
  }
  @IsTest
  static void returnsOnlyLinkedM4aLatestVersions() {
    Task target = makeTask();
    Task other = makeTask();
    ContentVersion original = addFile(target.Id, 'Call one', 'm4a');
    addFile(target.Id, 'Notes', 'txt');
    addFile(other.Id, 'Other task call', 'm4a');
    ContentVersion latest = new ContentVersion(
      Title = 'Call one revised',
      PathOnClient = 'revised.m4a',
      VersionData = Blob.valueOf('New synthetic version'),
      ContentDocumentId = original.ContentDocumentId
    );
    insert latest;
    Test.startTest();
    List<CallAnchorRecordingController.Recording> results = CallAnchorRecordingController.getRecordings(
      target.Id
    );
    Test.stopTest();
    System.assertEquals(1, results.size());
    System.assertEquals(latest.Id, results[0].versionId);
    System.assertEquals(original.ContentDocumentId, results[0].documentId);
    System.assertEquals('Call one revised', results[0].title);
    System.assertEquals(true, results[0].streamable);
    System.assertEquals(null, results[0].externalUrl);
  }
  @IsTest
  static void pairsCallAnchorUrlWithSingleRecording() {
    Task record = makeTask();
    record.Call_Anchor_Recording_Url__c = 'https://app.360callanchor.com/api/public/recordings/play?t=abc';
    update record;
    addFile(record.Id, 'Call', 'm4a');
    List<CallAnchorRecordingController.Recording> results = CallAnchorRecordingController.getRecordings(
      record.Id
    );
    System.assertEquals(1, results.size());
    System.assertEquals(
      record.Call_Anchor_Recording_Url__c,
      results[0].externalUrl
    );
  }
  @IsTest
  static void urlOnlyTaskStillGetsAPlayer() {
    Task record = makeTask();
    record.Call_Anchor_Recording_Url__c = 'https://app.360callanchor.com/api/public/recordings/play?t=abc';
    update record;
    List<CallAnchorRecordingController.Recording> results = CallAnchorRecordingController.getRecordings(
      record.Id
    );
    System.assertEquals(1, results.size());
    System.assertEquals(null, results[0].versionId);
    System.assertEquals(
      record.Call_Anchor_Recording_Url__c,
      results[0].externalUrl
    );
  }
  @IsTest
  static void urlNotPairedWhenSeveralRecordings() {
    Task record = makeTask();
    record.Call_Anchor_Recording_Url__c = 'https://app.360callanchor.com/api/public/recordings/play?t=abc';
    update record;
    addFile(record.Id, 'Call A', 'm4a');
    addFile(record.Id, 'Call B', 'm4a');
    for (
      CallAnchorRecordingController.Recording recording : CallAnchorRecordingController.getRecordings(
        record.Id
      )
    ) {
      System.assertEquals(null, recording.externalUrl);
    }
  }
  @IsTest
  static void streamsRecordingData() {
    Task record = makeTask();
    ContentVersion version = addFile(record.Id, 'Call', 'm4a');
    String data = CallAnchorRecordingController.getRecordingData(version.Id);
    System.assertEquals(
      'Synthetic test data, not playable audio',
      EncodingUtil.base64Decode(data).toString()
    );
  }
  @IsTest
  static void streamRejectsBadIds() {
    ContentVersion removed = addFile(makeTask().Id, 'Gone', 'm4a');
    delete new ContentDocument(Id = removed.ContentDocumentId);
    for (
      Id invalidId : new List<Id>{ null, UserInfo.getUserId(), removed.Id }
    ) {
      Boolean rejected = false;
      try {
        CallAnchorRecordingController.getRecordingData(invalidId);
      } catch (AuraHandledException ex) {
        rejected = true;
      }
      System.assert(
        rejected,
        'Must reject missing, wrong-type and deleted IDs'
      );
    }
  }
  @IsTest
  static void noFilesReturnsEmpty() {
    Task record = makeTask();
    System.assertEquals(
      0,
      CallAnchorRecordingController.getRecordings(record.Id).size()
    );
  }
  @IsTest
  static void rejectsMissingAndNonTaskIds() {
    for (Id invalidId : new List<Id>{ null, UserInfo.getUserId() }) {
      Boolean rejected = false;
      try {
        CallAnchorRecordingController.getRecordings(invalidId);
      } catch (AuraHandledException ex) {
        rejected = true;
      }
      System.assert(rejected, 'Must reject missing and non-Task IDs');
    }
  }
  @IsTest
  static void deletedTaskIsUnavailable() {
    Task record = makeTask();
    delete record;
    Boolean rejected = false;
    try {
      CallAnchorRecordingController.getRecordings(record.Id);
    } catch (AuraHandledException ex) {
      rejected = true;
    }
    System.assert(rejected, 'Must reject unavailable Tasks');
  }
}
