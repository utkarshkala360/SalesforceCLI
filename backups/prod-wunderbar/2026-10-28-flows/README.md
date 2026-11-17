# Wunderbar prod messaging flows – backup 2026-10-28

- `with-skip-decision/`: versions deployed 2026-10-27 with the `Skip_Follow_Up_Only_Update` decision
  (skip the flow when only the next follow-up date/time changed). Reverted on 2026-10-28 after an
  UNKNOWN_EXCEPTION on Lead 00QTw00000R4NcnMAF.
- `previous-active/`: the versions that were active before that deploy (Mindseed_New_Lead2 is its v2).

| Flow                                        | Previous active | With skip decision |
| ------------------------------------------- | --------------- | ------------------ |
| Foundree_New_Lead                           | v2              | v3                 |
| Mindseed_New_Lead2                          | v2              | v6                 |
| Mindseed_Lead_Flow                          | v3              | v4                 |
| Foundree_Flow                               | v3              | v4                 |
| Foundree_Lead_Flow                          | v2              | v3                 |
| Transactional_Messages                      | v5              | v6                 |
| Opportunity_Transactional_Messages          | v6              | v7                 |
| Transactional_Messages_Lead_Foundree        | v3              | v4                 |
| Opportunity_Transactional_Messages_Foundree | v3              | v4                 |
| VJ_Transactional_Messages_Lead              | v1              | v2                 |
| VJ_Transactional_Opportunity_Messages       | v1              | v2                 |
| VJ_Job_Enquiry                              | v1              | v2                 |
