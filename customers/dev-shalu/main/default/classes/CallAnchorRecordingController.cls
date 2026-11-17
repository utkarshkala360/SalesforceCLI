public with sharing class CallAnchorRecordingController {
  // Files above this are not streamed through Apex (heap limit); the player falls back to the download URL.
  @TestVisible
  static final Integer MAX_STREAM_BYTES = 2000000;

  public class Recording {
    @AuraEnabled
    public Id documentId { get; set; }
    @AuraEnabled
    public Id versionId { get; set; }
    @AuraEnabled
    public String title { get; set; }
    @AuraEnabled
    public Integer size { get; set; }
    @AuraEnabled
    public Boolean streamable { get; set; }
    @AuraEnabled
    public String externalUrl { get; set; }
  }

  @AuraEnabled(cacheable=true)
  public static List<Recording> getRecordings(Id taskId) {
    if (taskId == null || taskId.getSObjectType() != Task.SObjectType) {
      throw new AuraHandledException('Open this player from a Task record.');
    }
    try {
      List<Task> tasks = [
        SELECT Id
        FROM Task
        WHERE Id = :taskId
        WITH USER_MODE
      ];
      if (tasks.isEmpty()) {
        throw new AuraHandledException(
          'This Task is unavailable or you do not have access.'
        );
      }
      Set<Id> documentIds = new Set<Id>();
      for (ContentDocumentLink link : [
        SELECT ContentDocumentId
        FROM ContentDocumentLink
        WHERE LinkedEntityId = :taskId
        WITH USER_MODE
      ]) {
        documentIds.add(link.ContentDocumentId);
      }
      List<Recording> recordings = new List<Recording>();
      if (!documentIds.isEmpty()) {
        for (ContentVersion version : [
          SELECT Id, ContentDocumentId, Title, ContentSize
          FROM ContentVersion
          WHERE
            ContentDocumentId IN :documentIds
            AND IsLatest = TRUE
            AND FileExtension = 'm4a'
          WITH USER_MODE
          ORDER BY CreatedDate DESC, Id DESC
        ]) {
          Recording recording = new Recording();
          recording.documentId = version.ContentDocumentId;
          recording.versionId = version.Id;
          recording.title = version.Title;
          recording.size = version.ContentSize;
          recording.streamable =
            version.ContentSize != null &&
            version.ContentSize <= MAX_STREAM_BYTES;
          recordings.add(recording);
        }
      }
      // The Task holds one Call Anchor link, so only pair it when it cannot be ambiguous.
      String externalUrl = readRecordingUrl(taskId);
      if (externalUrl != null && recordings.size() <= 1) {
        if (recordings.isEmpty()) {
          Recording recording = new Recording();
          recording.title = 'Call Anchor recording';
          recording.streamable = false;
          recordings.add(recording);
        }
        recordings[0].externalUrl = externalUrl;
      }
      return recordings;
    } catch (QueryException ex) {
      throw new AuraHandledException(
        'Unable to read recordings. Ask your administrator to check Task and Salesforce Files access.'
      );
    }
  }

  // Returns the file as base64 so the player can play it without Salesforce's file-domain redirects.
  @AuraEnabled
  public static String getRecordingData(Id versionId) {
    if (
      versionId == null ||
      versionId.getSObjectType() != ContentVersion.SObjectType
    ) {
      throw new AuraHandledException('Recording not found.');
    }
    List<ContentVersion> versions = [
      SELECT ContentSize
      FROM ContentVersion
      WHERE Id = :versionId
      WITH USER_MODE
    ];
    if (versions.isEmpty()) {
      throw new AuraHandledException(
        'This recording is unavailable or you do not have access.'
      );
    }
    if (versions[0].ContentSize > MAX_STREAM_BYTES) {
      throw new AuraHandledException(
        'This recording is too large to stream here. Use Open File.'
      );
    }
    ContentVersion version = [
      SELECT VersionData
      FROM ContentVersion
      WHERE Id = :versionId
      WITH USER_MODE
    ];
    return EncodingUtil.base64Encode(version.VersionData);
  }

  private static String readRecordingUrl(Id taskId) {
    List<Task> tasks = (List<Task>) Security.stripInaccessible(
        AccessType.READABLE,
        [SELECT Call_Anchor_Recording_Url__c FROM Task WHERE Id = :taskId]
      )
      .getRecords();
    // A field stripped for lack of access is unset; reading it would throw.
    String url = tasks.isEmpty() ||
      !tasks[0].isSet('Call_Anchor_Recording_Url__c')
      ? null
      : tasks[0].Call_Anchor_Recording_Url__c;
    return String.isNotBlank(url) && url.startsWithIgnoreCase('https://')
      ? url
      : null;
  }
}
