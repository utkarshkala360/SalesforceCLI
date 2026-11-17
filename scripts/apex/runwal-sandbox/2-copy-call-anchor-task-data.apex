// Runwal - step 2 of the Call Anchor field rename (run AFTER step 1).
// Copies values from the old Activity fields into the new Call_Anchor_*
// fields on every existing Task, including archived ones. Only fills blank
// new fields, so it never overwrites data written by the new webhook and is
// safe to re-run. Old fields are left untouched until they are deleted.
List<Task> updates = new List<Task>();
for (Task t : [
  SELECT
    Id,
    Call_ID__c, Call_Anchor_Call_Id__c,
    Agent_Mobile__c, Call_Anchor_Agent_Mobile__c,
    Agent_Name__c, Call_Anchor_Agent_Name__c,
    Call_Started_At__c, Call_Anchor_Call_Started_At__c,
    Callback_scheduled__c, Call_Anchor_Callback_Scheduled_At__c,
    Disposition__c, Call_Anchor_Disposition__c,
    Disposition_Note__c, Call_Anchor_Disposition_Note__c,
    Duration_Seconds__c, Call_Anchor_Duration_Seconds__c,
    Recording_URL__c, Call_Anchor_Recording_Url__c
  FROM Task
  WHERE
    IsDeleted = FALSE
    AND (Call_ID__c != NULL
    OR Agent_Mobile__c != NULL
    OR Agent_Name__c != NULL
    OR Call_Started_At__c != NULL
    OR Callback_scheduled__c != NULL
    OR Disposition__c != NULL
    OR Disposition_Note__c != NULL
    OR Duration_Seconds__c != NULL
    OR Recording_URL__c != NULL)
  ALL ROWS
]) {
  Boolean changed = false;
  if (t.Call_Anchor_Call_Id__c == null && t.Call_ID__c != null) { t.Call_Anchor_Call_Id__c = t.Call_ID__c; changed = true; }
  if (t.Call_Anchor_Agent_Mobile__c == null && t.Agent_Mobile__c != null) { t.Call_Anchor_Agent_Mobile__c = t.Agent_Mobile__c; changed = true; }
  if (t.Call_Anchor_Agent_Name__c == null && t.Agent_Name__c != null) { t.Call_Anchor_Agent_Name__c = t.Agent_Name__c; changed = true; }
  if (t.Call_Anchor_Call_Started_At__c == null && t.Call_Started_At__c != null) { t.Call_Anchor_Call_Started_At__c = t.Call_Started_At__c; changed = true; }
  if (t.Call_Anchor_Callback_Scheduled_At__c == null && t.Callback_scheduled__c != null) { t.Call_Anchor_Callback_Scheduled_At__c = t.Callback_scheduled__c; changed = true; }
  if (t.Call_Anchor_Disposition__c == null && t.Disposition__c != null) { t.Call_Anchor_Disposition__c = t.Disposition__c; changed = true; }
  if (t.Call_Anchor_Disposition_Note__c == null && t.Disposition_Note__c != null) { t.Call_Anchor_Disposition_Note__c = t.Disposition_Note__c; changed = true; }
  if (t.Call_Anchor_Duration_Seconds__c == null && t.Duration_Seconds__c != null) { t.Call_Anchor_Duration_Seconds__c = t.Duration_Seconds__c; changed = true; }
  if (t.Call_Anchor_Recording_Url__c == null && t.Recording_URL__c != null) { t.Call_Anchor_Recording_Url__c = t.Recording_URL__c; changed = true; }
  if (changed) updates.add(t);
}
// allOrNone: either every Task is migrated or none is.
update updates;
System.debug('Tasks migrated: ' + updates.size());
