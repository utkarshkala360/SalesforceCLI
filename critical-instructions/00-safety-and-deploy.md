# Safety and deploy (applies to everything)

## Targeting the right org

- Work inside exactly one `customers/<customer>/` folder per task. Never copy files between customer folders without being asked.
- Before any deploy, retrieve or data command, confirm that the target org alias matches the folder in `customers/customers.json`.
- `prod-*` folders are customer production orgs. Confirm with the user before every deploy or data change to them.

## Deploying

- Deploy only with `--source-dir customers/<customer>/...`, or with `scripts/deploy.ps1`. **Never use `--manifest` or `-m <Type:Name>`.**
  _Why:_ every customer folder is a package directory and class names repeat across customers, so a deploy by manifest or name can pick another customer's file. This has already happened: Giftedson's webhook was pushed to Runwal.
- For destructive changes, pair `destructiveChanges.xml` with an empty `package.xml`.
- After a deploy, retrieve the deployed component and diff it against the customer's file.
- Run the relevant tests on the deploy (`--test-level RunSpecifiedTests --tests <TestClass>`) whenever Apex changes.

## Retrieving

- New components: use `scripts/retrieve-new.ps1 <customer> "<Type:Name>"` so they land in the customer folder, not in `force-app/`.

## Production: zero side effects

- Before writing code that does DML on existing records in a prod org, list everything that fires on the objects it touches: active record-triggered flows, Apex triggers (including managed packages), workflow rules, assignment rules and drip campaigns. Report what you find before you ship.
  _Why:_ some orgs have flows that send email or WhatsApp on any update, with no ISCHANGED check.
- Put risky updates behind a setting that is off by default (Custom Metadata or Custom Setting).
- Prefer read-side logic over org-wide triggers. For example, avoid triggers on ContentDocumentLink.
- Keep a feature's footprint minimal: as few new classes and components as possible, and touch no existing metadata unless it is required.
