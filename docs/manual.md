# ETAF Desktop manual

ETAF Desktop is a controlled application layer. A desktop controller owns a
reactive state value; each mutation copies and publishes that state through
ETAF. The mounted View consumes the state and calls ETAF UI's `etaf-window`,
which forwards geometry and gestures to Ebox.

Create a controller with `etaf-desktop-create`, add windows with
`etaf-desktop-open-window`, and mount it with `etaf-desktop-mount`. A window's
`:view` is caller-owned content. The controller owns its identifier, rectangle,
size limits, workspace, visibility, minimized/maximized mode and z-index.

```elisp
(let ((desktop (etaf-desktop-create :workspaces '(main dev))))
  (etaf-desktop-open-window
   desktop 'editor :title "Editor" :x 2 :y 1 :width 70 :height 20
   :view (etaf-view (text "Application content")))
  (etaf-desktop-mount desktop))
```

`etaf-desktop-move-window` and `etaf-desktop-resize-window` are the single
state update paths used by ETAF's controlled geometry Behaviors. Resize is
clamped to each window's minimum and optional maximum, and Ebox pixel deltas
are converted to desktop text-row units before application state is changed.
The built-in shell exposes right and bottom resize handles; applications that
need edge-specific policy can compose the public ETAF UI shell directly.
The desktop package does not run a second event loop or keep a second geometry
store.

`etaf-desktop-maximize-window` saves the normal rectangle and fills the desktop
canvas. `etaf-desktop-restore-window` returns that rectangle. Minimized windows
become invisible and are listed by the taskbar; restoring them makes them
visible and active. `etaf-desktop-focus-window` raises a window and switches to
its workspace. Workspaces are application state: removing one moves its windows
to a remaining workspace and the final workspace cannot be removed.

Read-only queries return detached plists: `etaf-desktop-state`,
`etaf-desktop-windows`, `etaf-desktop-window-state`,
`etaf-desktop-active-window` and `etaf-desktop-active-workspace`. Callers must
use the mutation functions rather than changing returned plists.

`etaf-desktop-close` unmounts the Runtime and kills the buffer it owns. Closing
is idempotent. A controller can be mounted only once at a time.
