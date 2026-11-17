/**
Runwal Realty - shares a Call Anchor recording File across all Tasks of a call.

The Call Anchor app uploads the recording itself (as its integration user),
seconds after the webhook, and attaches it to only ONE of the call's Tasks.
This class links that same ContentDocument (a pointer, never a copy) to every
other Task with the same Call_Anchor_Call_Id__c, so each Applicant and Booking
Task plays the one stored File.

DEPENDENCIES (deploy together):
  - CallAnchorFileLinkTrigger (ContentDocumentLink, after insert) calls
    onLinksInserted() when the app attaches the File to a Task.
  - CallAnchorWebService calls linkCallRecordings() after saving Tasks, so
    Tasks created after the upload (re-sent webhook, newly matched Applicant)
    also receive an already-stored File.
  - Relies on CallAnchorWebService writing Task.Call_Anchor_Call_Id__c.

Only audio Files are shared, so unrelated attachments stay where they are.
Runs without sharing: the uploader may not see every sibling Task, and the
only effect is extending an audio File to Tasks of the very same call.
 */
public without sharing class CallAnchorRecordingLinker {
  @TestVisible
  private static final Set<String> AUDIO_EXTENSIONS = new Set<String>{
    'm4a',
    'mp3',
    'wav',
    'aac',
    'ogg',
    'webm',
    'amr'
  };
  // Links inserted here fire CallAnchorFileLinkTrigger again; skip that pass.
  private static Boolean linking = false;

  public static void onLinksInserted(List<ContentDocumentLink> links) {
    if (linking)
      return;
    Set<Id> taskIds = new Set<Id>();
    for (ContentDocumentLink link : links) {
      if (
        link.LinkedEntityId != null &&
        link.LinkedEntityId.getSObjectType() == Task.SObjectType
      ) {
        taskIds.add(link.LinkedEntityId);
      }
    }
    if (taskIds.isEmpty())
      return;
    try {
      linkCallRecordings(taskIds);
    } catch (Exception ex) {
      // Never fail the app's upload because sharing to sibling Tasks failed;
      // the next webhook for the call retries the linking.
      System.debug(
        LoggingLevel.ERROR,
        'Call Anchor recording linking failed: ' + ex.getMessage()
      );
    }
  }

  /** Links each call's audio Files to all Tasks of that call. Returns links created. */
  public static Integer linkCallRecordings(Set<Id> taskIds) {
    Set<String> callIds = new Set<String>();
    for (Task activity : [
      SELECT Call_Anchor_Call_Id__c
      FROM Task
      WHERE Id IN :taskIds AND Call_Anchor_Call_Id__c != NULL
    ]) {
      callIds.add(activity.Call_Anchor_Call_Id__c);
    }
    if (callIds.isEmpty())
      return 0;

    Map<Id, String> callByTask = new Map<Id, String>();
    Map<String, Set<Id>> tasksByCall = new Map<String, Set<Id>>();
    for (Task activity : [
      SELECT Id, Call_Anchor_Call_Id__c
      FROM Task
      WHERE Call_Anchor_Call_Id__c IN :callIds
    ]) {
      callByTask.put(activity.Id, activity.Call_Anchor_Call_Id__c);
      if (!tasksByCall.containsKey(activity.Call_Anchor_Call_Id__c))
        tasksByCall.put(activity.Call_Anchor_Call_Id__c, new Set<Id>());
      tasksByCall.get(activity.Call_Anchor_Call_Id__c).add(activity.Id);
    }

    Map<Id, Set<String>> callsByDocument = new Map<Id, Set<String>>();
    Set<String> existing = new Set<String>();
    for (ContentDocumentLink link : [
      SELECT ContentDocumentId, LinkedEntityId
      FROM ContentDocumentLink
      WHERE
        LinkedEntityId IN :callByTask.keySet()
        AND ContentDocument.FileExtension IN :AUDIO_EXTENSIONS
    ]) {
      existing.add(link.ContentDocumentId + '|' + link.LinkedEntityId);
      if (!callsByDocument.containsKey(link.ContentDocumentId))
        callsByDocument.put(link.ContentDocumentId, new Set<String>());
      callsByDocument.get(link.ContentDocumentId)
        .add(callByTask.get(link.LinkedEntityId));
    }

    List<ContentDocumentLink> links = new List<ContentDocumentLink>();
    for (Id documentId : callsByDocument.keySet()) {
      for (String callId : callsByDocument.get(documentId)) {
        for (Id taskId : tasksByCall.get(callId)) {
          if (!existing.contains(documentId + '|' + taskId)) {
            existing.add(documentId + '|' + taskId);
            // Inferred sharing: whoever can see the Task can play the File.
            links.add(
              new ContentDocumentLink(
                ContentDocumentId = documentId,
                LinkedEntityId = taskId,
                ShareType = 'I'
              )
            );
          }
        }
      }
    }
    if (links.isEmpty())
      return 0;
    linking = true;
    try {
      insert links;
    } finally {
      linking = false;
    }
    return links.size();
  }
}
