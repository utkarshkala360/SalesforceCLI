# Flows and declarative automation

- **A retrieved flow is the latest version, not necessarily the active one.** Before editing a flow, compare `FlowDefinition.ActiveVersion.VersionNumber` with `LatestVersion.VersionNumber` (Tooling API). If they differ, rebuild the file from the active version's Tooling `Flow.Metadata`.
  _Why:_ on Wunderbar prod, the retrieve returned an obsolete v5 while a completely different v2 was active.
- Record-triggered flows that send messages or emails must have entry conditions using ISCHANGED or "only when updated to meet criteria". Point it out when an existing flow lacks them.
- Deploy flow changes as a new version, then activate deliberately. Don't change the activation of a flow you weren't asked to touch.
- Give every flow a `description`, and give its elements names that say what they do.
