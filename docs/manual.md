# ETAF Desktop manual

ETAF Desktop is a controlled application layer. A desktop controller owns
reactive window and workspace state. Public queries return detached snapshots;
floating moves and resizes publish their geometry and focus changes together
to ETAF observers. The mounted View supplies that state to ETAF UI's
`etaf-window`, which forwards geometry and gestures to Ebox.

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
The built-in shell exposes all four edges and all four corners through the
reusable ETAF UI shell. The configured drag-lock modifier applies to both
the title and every resize handle: the first release keeps tracking, and the
next primary-button press confirms at that press's position. The default is
Shift; Desktop Settings → Behavior → Drag lock modifier can select Super.
An explicit Escape cancellation during locked resize, or C-g during resize,
restores the starting rectangle. Unrelated input or target invalidation keeps
the last accepted geometry; a replaced window is never restored by an old
gesture. Generic ETAF Behaviors retain their caller-owned cancel semantics.
The desktop package uses Ebox's event loop and the existing controlled geometry
writer; it does not introduce a second input or geometry authority.

`etaf-desktop-maximize-window` saves the normal rectangle and fills the desktop
canvas. `etaf-desktop-restore-window` returns that rectangle. Minimized windows
become invisible and are listed by the taskbar; restoring them makes them
visible and active. `etaf-desktop-focus-window` raises a window and switches to
its workspace. Workspaces are application state: removing one moves its windows
to a remaining workspace and the final workspace cannot be removed.

## Desktop Settings

The workspace bar's Settings action opens an in-buffer ETAF UI dialog as a
root-layer projection, so the existing desktop remains visible underneath.
On a graphical Emacs viewport the panel is centered, limited to the visible
canvas and scrollable. Appearance, Layout, Behavior and Shortcuts tabs keep
the controls in a compact panel. Appearance controls theme, accent and fonts;
Layout controls layout mode and tile spacing; Behavior controls drag locking,
resize availability, close confirmation and taskbar grouping. Shortcuts
configures focus traversal, launcher, switcher, layout, split, swap, maximize,
minimize and close bindings. Done closes the panel; Reset settings restores
defaults. Session restore remains an explicit
`etaf-desktop-save-session`/`etaf-desktop-restore-session` workflow.

`etaf-desktop-settings` returns a detached plist. Use
`etaf-desktop-set-setting` for validated changes or
`etaf-desktop-reset-settings` to restore defaults. Settings are included in
`etaf-desktop-session-state`; invalid persisted values are rejected through the
same public validator during restore.

### Themes

A desktop theme is a named set of ETAF Theme tokens that paints the shell
(bars, canvas, window chrome, dividers) and the dialogs above it. Built-in
themes are `daylight` and `paper` (light) and `midnight`, `forest` and
`graphite` (dark); `etaf-desktop-themes` lists them in order. The `:theme`
setting selects one by name, or `system` (the first built-in theme matching
the Emacs frame's light or dark mode), `light` or `dark`. `:accent-color`
is nil by default, which keeps the theme's accent; a `#RRGGBB` string replaces
the accent and its derived tints. The Appearance tab exposes both controls.

Theme and accent changes repaint the mounted desktop through Theme paint
slots without re-rendering windows, and while the launcher, switcher or
settings dialog is open the shell is dimmed behind the dialog. Register a
custom theme before mounting or at any later time:

```elisp
(etaf-desktop-define-theme
 'harbor :label "Harbor" :mode 'dark
 :tokens '(:ui-shell-bg "#10202B" :ui-canvas-bg "#152A36"
           :ui-window-bg "#1B3442" :ui-accent "#5DD3C8"))
(etaf-desktop-set-setting desktop :theme 'harbor)
```

Omitted tokens fall back to the first built-in theme of the same mode.
`etaf-desktop-theme-tokens` returns the resolved plist so companion
applications can match the desktop's colors.

The default Desktop buffer map uses single letters because it is local to the
Desktop surface: `n`/`p` focus next/previous, `a` opens Applications, `w`
opens the switcher, `o` opens Settings, `l` toggles layout, `s` splits, `x`
swaps, `m` maximizes, `r` restores, `i` minimizes, and `q` closes the active
window. A modal or native input surface temporarily takes precedence.

Read-only queries return detached plists: `etaf-desktop-state`,
`etaf-desktop-windows`, `etaf-desktop-window-state`,
`etaf-desktop-active-window` and `etaf-desktop-active-workspace`. Callers must
use the mutation functions rather than changing returned plists.

`etaf-desktop-close` unmounts the Runtime created by `etaf-desktop-mount` and
kills a buffer created by that call. An existing target buffer remains with its
caller. When embedding `etaf-desktop-view` in another ETAF application, the
caller owns the enclosing Runtime and buffer and unmounts them; closing the
Desktop controller leaves that shared surface mounted. Closing is idempotent.
A controller can be mounted only once at a time.

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
`inactive`, `suspended`, `closing`, `closed` or `error`) and all window cleanup.
Applications may update their serializable state with
`etaf-desktop-set-instance-state`; they do not mutate desktop internals. A
callback error is isolated to that instance and produces a visible error
placeholder so the remaining desktop can continue operating.
`etaf-desktop-instances` and `etaf-desktop-instance`
return detached state snapshots.

`etaf-desktop-session-state` excludes View and Runtime objects. It records
desktop geometry, settings (including tile spacing), workspaces, instance
options, application-owned data from `:serialize`, and every workspace's layout
mode/tree/split ratios and floating membership. `etaf-desktop-save-session`
writes this plist. `etaf-desktop-restore-session` invokes the registered
`:restore` callback, reapplies saved window state, then restores the saved
layout policy. If an application is no longer registered, its instance is
restored as an error placeholder instead of aborting the session. Sessions
written before layout records were introduced remain readable.

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
`monocle` keeps the tree but gives every leaf the inset canvas rectangle and
raises the focused window, allowing a quick return to tiling.

Tile spacing defaults to one cell around the canvas and between panes. A cell
is one frame character width horizontally and one text row vertically; a
horizontal inner gap normally reserves at least three pixels for its divider.
Outer gaps shrink when the canvas needs that space for pane minimum sizes.
If those minimums still cannot fit, the allocator reduces pane sizes and inner
gaps as needed to keep panes inside the canvas where possible. Divider handles
stay centered and confined to their gaps, including in nested trees; a gap
reduced to zero has no handle. Splitter gestures change the ratio within that
split's own span. Monocle uses the same outer spacing without reserving inner
gaps for its retained split tree.

Use Desktop Settings or the public settings API to adjust spacing. For example,
this removes the outer margin and leaves two cells between tiled panes:

```elisp
(etaf-desktop-set-setting desktop :tile-outer-gap 0)
(etaf-desktop-set-setting desktop :tile-inner-gap 2)
```

Each change immediately reflows the active tiled workspace, preserving its
split tree and ratios. Other workspaces apply the current gaps when selected.
Floating windows retain their rectangles, and maximized windows retain the
full canvas until restored. Gap preferences are saved and restored with the
session settings. The [public API inventory](../etaf-desktop.el) specifies the
accepted integer ranges and error behavior; invalid values are rejected without
changing the setting or geometry.

`etaf-desktop-layout-tile-window` and `etaf-desktop-layout-untile-window`
control individual leaves. An explicitly untiled window remains a floating
overlay while other leaves reflow. Closing a window removes its leaf and
collapses empty split branches. The runtime invokes
`etaf-desktop-layout-refresh` after state publication, so a newly opened window
is inserted into an active tiling or master-stack workspace without a second
event loop. Applications that publish through a custom mutation path should
call the same refresh hook.

Maximizing a window temporarily fills the canvas without discarding its tiling
tree. Restoring that window returns it to the current layout. Changing a
workspace's layout mode exits the temporary maximized view and publishes the
new mode and window rectangles together, so all tiles become visible.

The title bar uses a macOS-style traffic-light control group on the left:
close is red, minimize is yellow and maximize/restore is green. The taskbar,
workspace bar, launcher, switcher and splitter are reusable ETAF UI components;
their callbacks call these desktop APIs while the application layer retains
window, focus and lifecycle policy.
