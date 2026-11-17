// Runwal - step 1 of the Call Anchor field rename (run AFTER deploying the
// new Call_Anchor_* Activity fields). Gives every profile / permission set the
// same read/edit access on each new field that it has on the old field, so
// users keep seeing Call Anchor data on existing Tasks. Safe to re-run.
// Setup-object DML: must run separately from step 2 (mixed DML).
Map<String, String> renamed = new Map<String, String>{
  'Call_ID__c' => 'Call_Anchor_Call_Id__c',
  'Agent_Mobile__c' => 'Call_Anchor_Agent_Mobile__c',
  'Agent_Name__c' => 'Call_Anchor_Agent_Name__c',
  'Call_Started_At__c' => 'Call_Anchor_Call_Started_At__c',
  'Callback_scheduled__c' => 'Call_Anchor_Callback_Scheduled_At__c',
  'Disposition__c' => 'Call_Anchor_Disposition__c',
  'Disposition_Note__c' => 'Call_Anchor_Disposition_Note__c',
  'Duration_Seconds__c' => 'Call_Anchor_Duration_Seconds__c',
  'Recording_URL__c' => 'Call_Anchor_Recording_Url__c'
};
Set<String> oldFields = new Set<String>();
Set<String> newFields = new Set<String>();
for (String oldName : renamed.keySet()) {
  oldFields.add('Task.' + oldName);
  newFields.add('Task.' + renamed.get(oldName));
}
// Activity field permissions are exposed under SobjectType 'Task' and 'Event'.
Map<String, FieldPermissions> existing = new Map<String, FieldPermissions>();
for (FieldPermissions fp : [
  SELECT Id, ParentId, SobjectType, Field, PermissionsRead, PermissionsEdit
  FROM FieldPermissions
  WHERE SobjectType = 'Task' AND Field IN :newFields
]) {
  existing.put(fp.ParentId + '|' + fp.Field, fp);
}
List<FieldPermissions> upserts = new List<FieldPermissions>();
for (FieldPermissions old : [
  SELECT ParentId, Field, PermissionsRead, PermissionsEdit
  FROM FieldPermissions
  WHERE SobjectType = 'Task' AND Field IN :oldFields
]) {
  String newField = 'Task.' + renamed.get(old.Field.substringAfter('.'));
  FieldPermissions target = existing.get(old.ParentId + '|' + newField);
  if (target == null) {
    target = new FieldPermissions(
      ParentId = old.ParentId,
      SobjectType = 'Task',
      Field = newField
    );
  } else if (
    target.PermissionsRead == old.PermissionsRead &&
    target.PermissionsEdit == old.PermissionsEdit
  ) {
    continue;
  }
  target.PermissionsRead = old.PermissionsRead;
  target.PermissionsEdit = old.PermissionsEdit;
  upserts.add(target);
}
// Partial success: system-managed permission sets cannot be edited and must
// not block access for everyone else. Failures are listed in the debug log.
List<FieldPermissions> inserts = new List<FieldPermissions>();
List<FieldPermissions> updates = new List<FieldPermissions>();
for (FieldPermissions fp : upserts) {
  if (fp.Id == null) inserts.add(fp); else updates.add(fp);
}
Integer saved = 0;
List<Database.SaveResult> results = new List<Database.SaveResult>();
results.addAll(Database.insert(inserts, false));
results.addAll(Database.update(updates, false));
for (Integer i = 0; i < results.size(); i++) {
  FieldPermissions fp = i < inserts.size() ? inserts[i] : updates[i - inserts.size()];
  if (results[i].isSuccess()) saved++;
  else System.debug(LoggingLevel.ERROR, 'FAILED ' + fp.ParentId + ' ' + fp.Field + ': ' + results[i].getErrors()[0].getMessage());
}
System.debug('Field permissions granted/updated: ' + saved + ' of ' + upserts.size());
