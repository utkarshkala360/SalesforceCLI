@IsTest
private class CallAnchorRecordingControllerTest {
  private static Task createTask() {
    Task task = new Task(
      Subject = 'Call',
      Status = 'Completed',
      Priority = 'Normal'
    );
    insert task;
    return task;
  }

  private static Id attachFile(Id recordId, String title, String fileName) {
    ContentVersion version = new ContentVersion(
      Title = title,
      PathOnClient = fileName,
      VersionData = Blob.valueOf('audio')
    );
    insert version;
    Id documentId = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :version.Id
    ]
    .ContentDocumentId;
    insert new ContentDocumentLink(
      ContentDocumentId = documentId,
      LinkedEntityId = recordId,
      ShareType = 'V',
      Visibility = 'AllUsers'
    );
    return version.Id;
  }

  private static void assertThrows(Id recordId) {
    try {
      CallAnchorRecordingController.getRecordings(recordId);
      Assert.fail('Expected AuraHandledException');
    } catch (AuraHandledException ex) {
      Assert.isNotNull(ex);
    }
  }

  @IsTest
  static void returnsOnlyAudioRecordings() {
    Task task = createTask();
    Id m4aId = attachFile(task.Id, 'Recording', 'recording.m4a');
    Id mp3Id = attachFile(task.Id, 'Recording Mp3', 'recording.mp3');
    attachFile(task.Id, 'Notes', 'notes.txt');

    Test.startTest();
    CallAnchorRecordingController.PlayerData result = CallAnchorRecordingController.getRecordings(
      task.Id
    );
    Test.stopTest();

    Assert.areEqual('Task', result.objectApiName);
    Assert.areEqual(2, result.recordings.size());
    Set<Id> versionIds = new Set<Id>();
    for (
      CallAnchorRecordingController.Recording recording : result.recordings
    ) {
      versionIds.add(recording.versionId);
      Assert.isNotNull(recording.documentId);
    }
    Assert.isTrue(versionIds.containsAll(new Set<Id>{ m4aId, mp3Id }));
  }

  @IsTest
  static void supportsNonTaskRecords() {
    Account acct = new Account(Name = 'Call Anchor Test');
    insert acct;
    Id versionId = attachFile(acct.Id, 'Account Recording', 'account.m4a');

    CallAnchorRecordingController.PlayerData result = CallAnchorRecordingController.getRecordings(
      acct.Id
    );

    Assert.areEqual('Account', result.objectApiName);
    Assert.areEqual(
      Account.SObjectType.getDescribe().getLabel(),
      result.objectLabel
    );
    Assert.areEqual(1, result.recordings.size());
    Assert.areEqual(versionId, result.recordings[0].versionId);
  }

  @IsTest
  static void returnsEmptyListWhenNoFiles() {
    Task task = createTask();
    Assert.isTrue(
      CallAnchorRecordingController.getRecordings(task.Id).recordings.isEmpty()
    );
  }

  @IsTest
  static void rejectsNullId() {
    assertThrows(null);
  }

  @IsTest
  static void rejectsMissingRecord() {
    Task task = createTask();
    delete task;
    assertThrows(task.Id);
  }

  @IsTest
  static void returnsInlineAudio() {
    Task task = createTask();
    Id versionId = attachFile(task.Id, 'Recording', 'recording.m4a');

    CallAnchorRecordingController.AudioData audio = CallAnchorRecordingController.getAudio(
      versionId
    );

    Assert.areEqual('audio/mp4', audio.mimeType);
    Assert.areEqual(
      EncodingUtil.base64Encode(Blob.valueOf('audio')),
      audio.base64Data
    );
    Assert.isTrue(
      CallAnchorRecordingController.getRecordings(task.Id)
        .recordings[0]
        .inlinePlayback
    );
  }

  @IsTest
  static void rejectsNonAudioInline() {
    Task task = createTask();
    Id versionId = attachFile(task.Id, 'Notes', 'notes.txt');
    try {
      CallAnchorRecordingController.getAudio(versionId);
      Assert.fail('Expected AuraHandledException');
    } catch (AuraHandledException ex) {
      Assert.isNotNull(ex);
    }
  }
}
