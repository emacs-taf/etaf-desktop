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
options. It also records each workspace's layout mode, detached tree, split
orientations/ratios and floating membership. Application-owned data enters the
session only through the manifest's serialize callback; View and Runtime objects
never enter the persisted value. Restore invokes the registered restore callback,
reapplies saved window state, then validates and reapplies each saved workspace
layout. An unavailable application becomes an error placeholder, while a
low-level window without an application manifest is recreated with a title
placeholder because its caller-owned View cannot be serialized. Older sessions
without layout records continue through the existing window-only restore path.

## Settings and shell composition

Desktop settings are stored in one controller-owned reactive plist and are
serialized with the desktop snapshot. The mounted shell projects that value
through ETAF UI Components: the workspace bar exposes a settings action and
`etaf-dialog` renders the form as a retained root-layer panel. Desktop chooses
the unpainted modal variant so the underlying application windows remain
visible; the reusable UI component retains its normal painted backdrop for
other modal callers. Font changes set the positioned window host to the larger
of the title and content sizes, preserving Ebox's shared line-height invariant.

The settings form owns only policies already supported by the application:
theme/accent presentation, typography, resize and locked-drag behavior,
taskbar grouping, close confirmation, and keyboard actions. Session restore
remains the explicit public save/restore workflow. Keyboard callbacks are
installed in the mounted Desktop buffer through its local overriding map;
they do not become global Emacs bindings.

Tiling geometry reserves no extra vertical row. The retained splitter overlay
owns the single visible divider row, while window records remain authoritative
for their rectangles.
