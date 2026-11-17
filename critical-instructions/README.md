# Critical instructions

This folder holds the standard operating procedure (SOP) that Claude Code follows in this repo. The root `CLAUDE.md` imports every rule file listed below, so the rules load automatically in every session.

| File                           | Covers                                                          |
| ------------------------------ | --------------------------------------------------------------- |
| `00-safety-and-deploy.md`      | Org targeting, deploys, prod safety. Applies to everything.     |
| `apex.md`                      | Apex classes, triggers, tests                                   |
| `objects-and-fields.md`        | Custom objects, fields, picklists, permission sets, layouts     |
| `lwc.md`                       | Lightning Web Components                                        |
| `flows.md`                     | Flows and other declarative automation                          |
| `data-operations.md`           | Record updates and data loads through the CLI or REST           |
| `templates/customer-CLAUDE.md` | Starting point for an optional `customers/<customer>/CLAUDE.md` |

## Maintaining these files

- **Adding a rule:** put it in the file that matches its topic. Write it as an instruction, and add a one-line _why_ when the reason isn't obvious. Rules that came from an incident are the most valuable ones to keep.
- **Adding a file:** create it here, then add an `@critical-instructions/<file>.md` line to the root `CLAUDE.md`. A file that isn't imported is never loaded.
- **Customer-only rules** go in `customers/<customer>/CLAUDE.md`, not in this folder. If a customer rule conflicts with a global one, Claude asks you which to follow. If the answer should stick, write it into the customer file as an explicit exception.
- **Length:** keep every file short. All of them load in every session, so long files take up context and weaken the important rules.
