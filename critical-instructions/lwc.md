# Lightning Web Components

- Name components in camelCase with a feature prefix (`callAnchorTaskPlayer`). Each component is a folder containing `.html`, `.js`, `.js-meta.xml`, and `.css` when needed.
- In `js-meta.xml`, expose only the targets that are actually used, and give the component a `masterLabel` and `description`.
- Use `@wire` with Lightning Data Service or `cacheable=true` Apex for reads. Use imperative Apex for writes, and handle errors in the UI with a toast or inline message.
- Import fields with `@salesforce/schema` instead of using string field names, so dependencies are tracked.
- Use SLDS classes and base components before writing custom CSS. No hardcoded colours.
- Third-party JS goes in a Static Resource loaded with `loadScript`. No CDN links.
- Run `npm run lint` before you finish.
