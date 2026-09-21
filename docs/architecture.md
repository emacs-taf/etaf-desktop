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
