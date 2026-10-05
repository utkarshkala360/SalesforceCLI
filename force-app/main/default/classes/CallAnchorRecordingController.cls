public with sharing class CallAnchorRecordingController {
    public class Recording {
        @AuraEnabled public Id documentId { get; set; }
        @AuraEnabled public Id versionId { get; set; }
        @AuraEnabled public String title { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static List<Recording> getRecordings(Id taskId) {
        if (taskId == null || taskId.getSObjectType() != Task.SObjectType) {
            throw new AuraHandledException('Open this player from a Task record.');
        }
        try {
            List<Task> tasks = [SELECT Id FROM Task WHERE Id = :taskId WITH USER_MODE];
            if (tasks.isEmpty()) {
                throw new AuraHandledException('This Task is unavailable or you do not have access.');
            }
            Set<Id> documentIds = new Set<Id>();
            for (ContentDocumentLink link : [
                SELECT ContentDocumentId FROM ContentDocumentLink
                WHERE LinkedEntityId = :taskId WITH USER_MODE
            ]) {
                documentIds.add(link.ContentDocumentId);
            }
            List<Recording> recordings = new List<Recording>();
            if (documentIds.isEmpty()) return recordings;
            for (ContentVersion version : [
                SELECT Id, ContentDocumentId, Title FROM ContentVersion
                WHERE ContentDocumentId IN :documentIds
                AND IsLatest = true AND FileExtension = 'm4a'
                WITH USER_MODE ORDER BY CreatedDate DESC, Id DESC
            ]) {
                Recording recording = new Recording();
                recording.documentId = version.ContentDocumentId;
                recording.versionId = version.Id;
                recording.title = version.Title;
                recordings.add(recording);
            }
            return recordings;
        } catch (QueryException ex) {
            throw new AuraHandledException('Unable to read recordings. Ask your administrator to check Task and Salesforce Files access.');
        }
    }
}
