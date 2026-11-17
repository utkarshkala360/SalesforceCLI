# Data operations (CLI / REST)

- Run a query showing which records would be affected, and their current values, before any update or delete. Get confirmation for prod.
- **Lead updates:** never use `sf data update record` on a Lead. Use:
  `sf api request rest --method PATCH --header "Sforce-Auto-Assign: FALSE" --body '{...}' /services/data/v62.0/sobjects/Lead/<Id>`
  Check the Owner afterwards.
  _Why:_ REST updates fire the Lead assignment rule by default and silently change the owner.
- Updating any record can fire flows and triggers. Apply the zero-side-effects check from `00-safety-and-deploy.md`.
- Bulk loads: test on 1–5 records first, keep a CSV backup of the original values, and log the IDs you changed.
