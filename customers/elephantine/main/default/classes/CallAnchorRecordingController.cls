public with sharing class CallAnchorRecordingController {
  private static final Set<String> AUDIO_EXTENSIONS = new Set<String>{
    'm4a',
    'mp3',
    'wav',
    'aac',
    'ogg',
    'webm'
  };

  public class Recording {
    @AuraEnabled
    public Id documentId { get; set; }
    @AuraEnabled
    public Id versionId { get; set; }
    @AuraEnabled
    public String title { get; set; }
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
        WHERE LinkedEntityId = :recordId
        WITH USER_MODE
      ]) {
        documentIds.add(link.ContentDocumentId);
      }
      if (documentIds.isEmpty())
        return result;
      for (ContentVersion version : [
        SELECT Id, ContentDocumentId, Title
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
}
