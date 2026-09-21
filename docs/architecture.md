# ETAF Desktop architecture

ETAF Desktop is the top application layer in the ETAF ecosystem.

- **Ebox** owns measured geometry, overlap, z-index rendering, hit testing and
  incremental publication. It supplies the retained gesture phases.
- **ETAF** owns reactive application state, Component lifecycle, event batching
  and Runtime publication.
- **ETAF UI** owns the reusable controlled `etaf-window` and
  `etaf-resizable-panel` presentation components. They expose title-bar and
  resize gestures but retain no window policy.
- **ETAF Desktop** owns window records, workspaces, focus and z-order policy,
  restore rectangles, taskbar projection and the mounted application surface.

Window mutations create a copied state value and publish it through one ETAF ref.
The View projects the current state into controlled UI props. Consequently a
failed render leaves the previous committed Ebox target active while application
state remains explicit and queryable. No Ebox node, private ETAF Runtime table,
or private ETAF UI module is used by consumers.

A desktop window's public identity is its stable application ID. The rendered
Host refs are derived from that ID only for Ebox/ETAF target retention; they are
not a second state store. Playground packages may demonstrate this package but
do not own any of its policies.

## Application host boundary

The application registry is a separate policy layer above window geometry.
Each manifest identifies an application, declares its capabilities and
provides optional open, close, serialize and restore callbacks. A manifest is
not an application instance: one manifest may have multiple instances, each
with its own lifecycle state, caller-owned View values, options and window
IDs. Instance status transitions are observable as `launching`, `active`,
`inactive`, `suspended`, `closing`, `closed` or `error`.

`etaf-desktop-launch` creates instances and routes callback failures into an
error placeholder. Closing always releases the instance's windows even when a
close callback fails. Focus policy marks the previously active instance
inactive; suspend and restore operate on all windows belonging to one
instance. These rules isolate one application failure from the mounted
desktop and other applications.

Session state contains desktop geometry, workspaces, window state and instance
options. Application-owned data enters the session only through the manifest's
serialize callback; View and Runtime objects never enter the persisted value.
Restore invokes the registered restore callback and reapplies saved window
state. An unavailable application becomes an error placeholder, while a
low-level window without an application manifest is recreated with a title
placeholder because its caller-owned View cannot be serialized.
