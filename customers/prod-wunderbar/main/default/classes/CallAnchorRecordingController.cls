public with sharing class CallAnchorRecordingController {
  private static final Set<String> AUDIO_EXTENSIONS = new Set<String>{
    'm4a',
    'mp3',
    'wav',
    'aac',
    'ogg',
    'webm',
    'amr'
  };
  // Inline playback streams bytes through Apex; keep base64 well under heap/response limits.
  @TestVisible
  private static final Integer MAX_INLINE_BYTES = 4 * 1024 * 1024;
  private static final Map<String, String> MIME_TYPES = new Map<String, String>{
    'm4a' => 'audio/mp4',
    'mp3' => 'audio/mpeg',
    'wav' => 'audio/wav',
    'aac' => 'audio/aac',
    'ogg' => 'audio/ogg',
    'webm' => 'audio/webm',
    'amr' => 'audio/amr'
  };

  public class Recording {
    @AuraEnabled
    public Id documentId { get; set; }
    @AuraEnabled
    public Id versionId { get; set; }
    @AuraEnabled
    public String title { get; set; }
    @AuraEnabled
    public Boolean inlinePlayback { get; set; }
  }

  public class AudioData {
    @AuraEnabled
    public String mimeType { get; set; }
    @AuraEnabled
    public String base64Data { get; set; }
  }

  public class PlayerData {
    @AuraEnabled
    public String objectApiName { get; set; }
    @AuraEnabled
    public String objectLabel { get; set; }
    @AuraEnabled
    public List<Recording> recordings { get; set; }
  }

  @AuraEnabled(cacheable=true)
  public static PlayerData getRecordings(Id recordId) {
    Schema.SObjectType objectType = recordId?.getSObjectType();
    if (objectType == null) {
      throw new AuraHandledException('Open this player from a record.');
    }
    Schema.DescribeSObjectResult describe = objectType.getDescribe();
    if (!describe.isQueryable() || !describe.isAccessible()) {
      throw new AuraHandledException(
        'Recordings are not supported for ' + describe.getLabel() + ' records.'
      );
    }
    PlayerData result = new PlayerData();
    result.objectApiName = describe.getName();
    result.objectLabel = describe.getLabel();
    result.recordings = new List<Recording>();
    try {
      List<SObject> records = Database.query(
        'SELECT Id FROM ' +
          describe.getName() +
          ' WHERE Id = :recordId WITH USER_MODE'
      );
      if (records.isEmpty()) {
        throw new AuraHandledException(
          'This ' +
            describe.getLabel() +
            ' is unavailable or you do not have access.'
        );
      }
      Set<Id> documentIds = new Set<Id>();
      for (ContentDocumentLink link : [
        SELECT ContentDocumentId
        FROM ContentDocumentLink
        WHERE LinkedEntityId IN :callTaskIds(recordId)
        WITH USER_MODE
      ]) {
        documentIds.add(link.ContentDocumentId);
      }
      if (documentIds.isEmpty())
        return result;
      for (ContentVersion version : [
        SELECT Id, ContentDocumentId, Title, ContentSize
        FROM ContentVersion
        WHERE
          ContentDocumentId IN :documentIds
          AND IsLatest = TRUE
          AND FileExtension IN :AUDIO_EXTENSIONS
        WITH USER_MODE
        ORDER BY CreatedDate DESC, Id DESC
      ]) {
        Recording recording = new Recording();
        recording.documentId = version.ContentDocumentId;
        recording.versionId = version.Id;
        recording.title = version.Title;
        recording.inlinePlayback = version.ContentSize <= MAX_INLINE_BYTES;
        result.recordings.add(recording);
      }
      return result;
    } catch (QueryException ex) {
      throw new AuraHandledException(
        'Unable to read recordings. Ask your administrator to check ' +
          describe.getLabel() +
          ' and Salesforce Files access.'
      );
    }
  }

  // The Call Anchor app attaches the recording File to only one Task of a call. A Task
  // with a Call_Anchor_Call_Id__c therefore also looks at the other Tasks of the same
  // call (the call and its follow-up) that the user can see. Reading them here, rather
  // than copying File links to every Task, keeps file uploads in the org untouched.
  // The call id is matched without field-level checks (users need not see the field);
  // sharing still limits the Tasks to ones the user can see, and the Files themselves
  // are read in user mode.
  private static Set<Id> callTaskIds(Id recordId) {
    Set<Id> ids = new Set<Id>{ recordId };
    if (recordId.getSObjectType() != Task.SObjectType) {
      return ids;
    }
    List<Task> current = [
      SELECT Call_Anchor_Call_Id__c
      FROM Task
      WHERE Id = :recordId
    ];
    if (
      current.isEmpty() || String.isBlank(current[0].Call_Anchor_Call_Id__c)
    ) {
      return ids;
    }
    for (Task sibling : [
      SELECT Id
      FROM Task
      WHERE Call_Anchor_Call_Id__c = :current[0].Call_Anchor_Call_Id__c
      LIMIT 50
    ]) {
      ids.add(sibling.Id);
    }
    return ids;
  }

  @AuraEnabled
  public static AudioData getAudio(Id versionId) {
    List<ContentVersion> versions;
    try {
      versions = [
        SELECT FileExtension, ContentSize, VersionData
        FROM ContentVersion
        WHERE
          Id = :versionId
          AND FileExtension IN :AUDIO_EXTENSIONS
          AND ContentSize <= :MAX_INLINE_BYTES
        WITH USER_MODE
      ];
    } catch (QueryException ex) {
      versions = new List<ContentVersion>();
    }
    if (versions.isEmpty()) {
      throw new AuraHandledException(
        'This recording is unavailable or too large to play inline.'
      );
    }
    AudioData audio = new AudioData();
    audio.mimeType = MIME_TYPES.get(versions[0].FileExtension.toLowerCase());
    audio.base64Data = EncodingUtil.base64Encode(versions[0].VersionData);
    return audio;
  }
}
