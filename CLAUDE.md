# CLAUDE.md

This is a multi-customer Salesforce DX repo. Each customer org has its own package directory, `customers/{env}-{alias}/`, which is mapped to its org in `customers/customers.json`. `force-app/` is intentionally empty. See README.md for the Org Guard workflow.

The rules live in `critical-instructions/`. Edit them there, not here. Follow them every time you create or change metadata, or run a deploy or data operation.

## Instruction hierarchy

1. **Global (always applies):** the files imported below.
2. **Customer (optional):** `customers/<customer>/CLAUDE.md`. Before working in a customer folder, check whether that file exists and read it. Customer rules add to the global rules. **If a customer rule conflicts with a global rule, stop and ask the user which one to follow. Don't pick either one yourself.** Name both rules and what each would mean for the task. The answer covers only the current task, unless the user says to make it permanent. New customer files start from `critical-instructions/templates/customer-CLAUDE.md`.
3. If a task would break a rule at either level, stop and ask. Do not work around it.

## Global rules

@critical-instructions/00-safety-and-deploy.md
@critical-instructions/apex.md
@critical-instructions/objects-and-fields.md
@critical-instructions/lwc.md
@critical-instructions/flows.md
@critical-instructions/data-operations.md
