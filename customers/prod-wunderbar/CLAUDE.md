# Wunderbar – Production (`customers/prod-wunderbar`)

These rules apply only to this customer and add to the global rules in `critical-instructions/`. If a rule here conflicts with a global rule, ask the user which one to follow before going ahead.

## Automation to watch

- `Mindseed_Lead_Flow`, `Foundree_Flow` and `Opportunity_Transactional_Messages_Foundree` send email or WhatsApp on **any** Lead or Opportunity update, with no ISCHANGED check. Any field update from our code re-sends those messages to the customer, so don't update existing Leads or Opportunities unless the user explicitly approves it.
- `Mindseed_New_Lead2`: the active version (v2) differs from the latest version (v5, obsolete). Follow the flow-version rule in `critical-instructions/flows.md`.
- Lead assignment rule is active. Use the `Sforce-Auto-Assign: FALSE` PATCH for any Lead update.

## Call Anchor integration

- Keep the recording feature in a single class. `CallAnchorRecordingController.getRecordings()` reads Files on sibling Tasks that share the same `Call_Anchor_Call_Id__c`. Don't use a linker class or a ContentDocumentLink trigger.
- Never download `recordingUrl` in Apex. The app uploads the recording File itself.
