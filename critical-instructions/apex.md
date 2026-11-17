# Apex classes, triggers and tests

## Structure

- Declare every class `with sharing` unless there's a documented reason not to. Use `without sharing` only in a small, named helper class, with a comment saying why.
- Name classes by role: `<Feature>Service` for logic and REST resources, `<Feature>Controller` for LWC/Aura, `<Feature>Test` for tests, `<Object>TriggerHandler` for trigger logic.
- One trigger per object, with no logic in the trigger body. It delegates to a handler class.
- Keep field API names and other config in `private static final` constants or maps at the top of the class, not scattered through the code.
- Each `-meta.xml` must use an `apiVersion` that matches `sourceApiVersion` in `sfdx-project.json`, unless the customer's org is on an older release.

## Code rules

- Bulkify everything. No SOQL or DML inside loops.
- Use `WITH USER_MODE`, or `Security.stripInaccessible`, for queries a user triggers from the UI.
- No hardcoded record IDs, user IDs or org URLs. Look them up, or read them from Custom Metadata.
- Callouts go through Named Credentials. No secrets in code.
- REST resources (`@RestResource`) validate their input and return a stable JSON response shape. Never rename keys an external app relies on.
- Comments explain _why_ (business rule, org quirk, chosen record type), not what the code does.

## Tests

- Every class gets a test class. Aim for at least 85% coverage, and assert on behaviour, not just coverage.
- Create data with `@TestSetup`. Never use `SeeAllData=true`.
- Mock callouts with `HttpCalloutMock`.
- Cover bulk input (200 records), negative paths and missing or invalid input.
