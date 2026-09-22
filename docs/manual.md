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

With no explicit `:canvas-width` or `:canvas-height`, the mounted surface
measures the Emacs window that displays it before the first render, so the
workspace bar, canvas and taskbar fill the visible window body.  Pass explicit
dimensions when a desktop embeds a fixed-size surface or when tests need
deterministic geometry.

The mounted desktop hides that buffer's header and mode lines so its workspace
bar, canvas and taskbar occupy the complete visible body.  Application status
and actions belong in the desktop shell or in the active application's own
surface.

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

## Applications and instances

`etaf-desktop` is an application host. Register an application once with a
manifest, then launch one or more independent instances. The manifest's
`:open` callback receives a context plist and returns one window spec or a
`:windows` list. A spec uses the same public geometry options as
`etaf-desktop-open-window`; its `:view` remains application-owned.

```elisp
(etaf-desktop-register-app
 'notes :title "Notes"
 :open (lambda (context)
         (list :state '(:document "welcome")
               :windows (list
                         (list :id 'main :title "Notes"
                               :view (etaf-view (text "Welcome"))))))
 :close (lambda (_context reason) (message "Notes closed: %s" reason))
 :serialize (lambda (context) (plist-get context :state)))

(let ((instance (etaf-desktop-launch desktop 'notes)))
  (etaf-desktop-focus-instance desktop (plist-get instance :id)))
```

A manifest without the `multiple-instances` capability is single-instance:
an implicit `etaf-desktop-launch` focuses its running instance instead of
creating a second one, while session restore keeps passing explicit instance
ids.  The host owns instance identity, lifecycle (`launching`, `active`,
`suspended`, `closing`, `closed` or `error`) and all window cleanup. Applications
may update their serializable state with `etaf-desktop-set-instance-state`;
they do not mutate desktop internals. A callback error is isolated to that
instance and produces a visible error placeholder so the remaining desktop can
continue operating. `etaf-desktop-instances` and `etaf-desktop-instance`
return detached state snapshots.

`etaf-desktop-session-state` excludes View and Runtime objects. It records
desktop geometry, workspaces, instance options and application-owned data from
`:serialize`. `etaf-desktop-save-session` writes this plist, and
`etaf-desktop-restore-session` invokes the registered `:restore` callback and
reapplies saved window state. If an application is no longer registered, its
instance is restored as an error placeholder instead of aborting the session.

## Workspace layout policy

Each workspace can use `floating`, `tiling`, `master-stack` or `monocle` mode.
Floating windows keep their own rectangles. Tiling uses a detached layout tree
whose leaves are window IDs and whose split nodes have an orientation and ratio:

```elisp
(etaf-desktop-set-layout-mode desktop 'tiling)
(etaf-desktop-layout-split desktop 'editor 'terminal 'horizontal 0.65)
(etaf-desktop-layout-resize-split desktop nil 0.55)
```

`horizontal` splits divide width from left to right; `vertical` splits divide
height from top to bottom. The allocator observes each window's minimum and
maximum dimensions where the canvas permits. `master-stack` gives the first
visible window a wide master region and stacks the remaining leaves vertically.
`monocle` keeps the tree but gives every leaf the canvas rectangle and raises
the focused window, allowing a quick return to tiling.

`etaf-desktop-layout-tile-window` and `etaf-desktop-layout-untile-window`
control individual leaves. An explicitly untiled window remains a floating
overlay while other leaves reflow. Closing a window removes its leaf and
collapses empty split branches. The runtime invokes
`etaf-desktop-layout-refresh` after state publication, so a newly opened window
is inserted into an active tiling or master-stack workspace without a second
event loop. Applications that publish through a custom mutation path should
call the same refresh hook.

The title bar uses a macOS-style traffic-light control group on the left:
close is red, minimize is yellow and maximize/restore is green. The taskbar,
workspace bar, launcher, switcher and splitter are reusable ETAF UI components;
their callbacks call these desktop APIs while the application layer retains
window, focus and lifecycle policy.
