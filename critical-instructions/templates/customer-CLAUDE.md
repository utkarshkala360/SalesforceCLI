# <Customer> – <Env> (`customers/<folder>`)

These rules apply only to this customer and add to the global rules in `critical-instructions/`. If a rule here conflicts with a global rule, ask the user which one to follow before going ahead.

## Org

- Alias: `<Alias from customers.json>`
- Edition / notes: <e.g. production, managed packages installed: tdc_tsw, tdc_360CTI>

## Naming overrides

- <e.g. field prefix `Ud_` for customer-owned fields; our fields use `Call_Anchor_`>

## Automation to watch

- <flows, triggers or rules that fire on objects we touch, and why they matter>

## Customer-specific rules

- <e.g. Tasks must use record type X; never update Opportunity Stage>

## Integration notes

- <webhook endpoint, which records the app links to, response keys the app depends on>
