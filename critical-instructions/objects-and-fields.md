# Objects, fields, permission sets and layouts

## Custom fields

- API name: `<Feature>_<Purpose>__c` in Title_Snake_Case. Example: `Call_Anchor_Call_Id__c`. Check the customer's org for an existing field before creating a new one.
- `label`: short and readable for users ("Agent Mobile"). Don't repeat the feature prefix unless it's needed to tell fields apart.
- `description` is **mandatory**: who writes the field and what it holds. Example: "For Call Anchor app to store the mobile number of the agent who handled the call."
- Add `inlineHelpText` for any field a user edits by hand.
- Pick the narrowest type: Phone, Email, Number(scale), DateTime, Picklist. Don't use Text when a typed field fits.
- Long Text Area holding raw payloads: 131072 characters, not shown on layouts by default.
- Restricted picklists for values that integrations write. Keep API values stable; only labels may change.
- Never change the type of an existing field, or delete one, without asking. Data and dependencies break.

## Objects

- Every custom object needs a `description`, a sensible `nameField`, and its sharing model stated explicitly.

## Permission sets

- New features ship with a permission set that grants **only the new fields and classes**. Never re-grant or change existing permissions.
- Don't edit profiles unless explicitly asked.

## Layouts

- Before editing a layout, retrieve the org's current version. Change only the new section, and check again for drift right before deploying.
