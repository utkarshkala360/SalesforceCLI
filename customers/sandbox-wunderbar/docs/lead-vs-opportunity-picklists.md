# Lead vs Opportunity – Brand / Region / Location

Checked in **Wunderbar - Sandbox** on 2026-10-21 (`sf sobject describe`).

## Field existence

| Field       | Lead                                                        | Opportunity |
| ----------- | ----------------------------------------------------------- | ----------- |
| Brand       | `Company_Brand__c` (label "Brand") – there is no `Brand__c` | `Brand__c`  |
| Region__c   | yes                                                         | yes         |
| Location__c | yes                                                         | yes         |

## Picklist values

- **Brand** – same 3 values on both: Vishwajyot, Mindseed, Foundree.
  Restricted on Lead, unrestricted on Opportunity.
- **Region__c** – same 12 values (API / label identical, e.g. API `Thane`, label `M-Thane`).
  Restricted on Lead, unrestricted on Opportunity.
- **Location__c** – one mismatch, same label "New Panvel 19" but different API names:
  - Lead: `New Panvel 19`
  - Opportunity: `Panvel 19`

## Dependencies

**Brand → Region** (Lead: `Company_Brand__c`, Opportunity: `Brand__c`) – identical:

| Brand      | Regions                                  |
| ---------- | ---------------------------------------- |
| Mindseed   | Thane, Navi Mumbai, Mumbai, Pune         |
| Vishwajyot | V-Navi Mumbai                            |
| Foundree   | F-Thane, F-Navi Mumbai, F-Mumbai, F-Pune |

**Region → Location** – identical except:

| Region      | Only on Lead    | Only on Opportunity                       |
| ----------- | --------------- | ----------------------------------------- |
| Navi Mumbai | `New Panvel 19` | `Panvel 19`, `Kharghar 35`, `Vashi`, `NA` |
| F-Thane     | –               | `Kharghar 8`                              |

## Values no one can select

- Lead: **Kharghar 35** and **Vashi** exist but are not allowed under any Lead region.
- Both objects: **Lonand**, **Phaltan**, **Sakharwadi** exist but are not allowed under any region.

## Impact on the Call Anchor webhook

`CallAnchorWebhookService` matches the `select-brand` disposition (e.g. `mindseed-new-panvel-19`)
against both the API name and the label of each object's picklist, so the
`New Panvel 19` / `Panvel 19` mismatch does not break call matching.
