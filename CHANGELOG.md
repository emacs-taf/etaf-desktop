# Changelog

All notable changes to ETAF Desktop are documented here.

## Unreleased

### Added

- Selectable desktop themes. `etaf-desktop-define-theme` registers a named
  light or dark token set; `daylight`, `paper`, `midnight`, `forest` and
  `graphite` are built in and `etaf-desktop-themes` lists them. The `:theme`
  setting accepts `system`, `light`, `dark` or a theme name, and the
  Appearance tab offers every registered theme. `:accent-color` now defaults
  to nil, meaning the theme's own accent; a `#RRGGBB` value overrides it.
  Theme changes repaint the mounted shell in place, and an open launcher,
  switcher or settings dialog dims the desktop behind it while the dialog
  keeps its own theme colors. `etaf-desktop-theme-tokens` exposes the resolved
  colors for companion applications and tests.

- A default desktop now follows its Emacs window. Resizing the window refits
  the shell frame, tiled and monocle workspaces, maximized windows and
  floating windows in one batch through retained bindings, and
  `etaf-desktop-fit-canvas` runs the same refit on demand (for example after
  `split-window` in batch Emacs).

### Fixed

- The Layout tab's "Window layout" select shows the active workspace's
  current mode. It read the `:layout-mode` preference, which the bar
  control, the `l` shortcut and workspace switches never write, so it kept
  showing "Floating" for a tiled workspace. The bar label also names
  `master-stack` ("Master") and `monocle` modes instead of "Floating".
- Pressing anywhere outside the launcher, switcher or settings dialog closes
  it: window content, window controls, bar controls and shell background all
  dismiss the open modal, and a taskbar control that opens another modal
  swaps them in one press. Pressing the shell background no longer sets the
  mark through `mouse-drag-region`. The modals' own close requests close
  unambiguously instead of toggling, so a second dismissal in the same press
  cannot reopen them.
- Floating windows can be dragged past the left, right and bottom canvas
  edges again. `etaf-desktop-move-window` and the shell's move and resize
  gestures accept any integer position and keep at least 48 pixels of the
  window and its title row inside the canvas instead of signalling an error
  at the first negative coordinate, which aborted the drag and left the window
  wherever the pointer had last been tracked.
- Dragging a tiling divider follows the pointer one row or pixel at a time.
  The split allocation rounded half values to even, so on an odd span every
  other step produced the same pane size and the divider stuck for one step
  and then jumped two.

- The Applications launcher lists every registered application by title
  (with its icon when declared) and shows whether it is running and how many
  windows it owns. The launcher and window switcher open centered over the
  retained desktop instead of covering it with an opaque backdrop.
- Dragging a tiling divider now follows the pointer one-to-one. Each motion
  applies the displacement from the press to the ratio the drag started from,
  so the divider no longer runs ahead of the mouse, and a cancelled drag
  restores that start ratio.

### Changed

- Desktop Settings is one card with a tab row and a labelled two-column
  form. Theme, layout, drag-lock modifier and taskbar grouping are chip or
  dropdown selects, numbers are `[−] value [+]` steppers and booleans are
  On/Off switches, so choosing a theme no longer opens the minibuffer.
- "Confirm before closing" asks through an in-desktop "Close window?" card
  with Cancel and Close window actions instead of a `yes-or-no-p` prompt.
- Themes follow the ETAF UI tonal control palette: `:ui-button-secondary-*`
  tints controls with the theme accent, and the `:ui-button-*-border`,
  `:ui-selection-*`, `:ui-checkbox-*-bg`/`-border` and
  `:ui-button-ghost-bg` tokens are no longer part of a theme. Custom themes
  that set them are still accepted; the values are ignored.
- Switching workspaces, including through `etaf-desktop-focus-window` on a
  window of another workspace, publishes through retained cells. Every
  workspace's windows and tiling dividers stay mounted; the active workspace
  is a reactive source that shows or hides them, updates the workspace bar
  and layout label and focuses the highest visible window. The desktop tree
  is no longer rebuilt on a switch. The taskbar now lists the windows of
  every workspace, not only the active one.
- Tiling layouts publish window rectangles and divider positions, labels and
  visibility through retained geometry cells. Ratio drags, focus changes,
  maximize and minimize under tiling update the affected windows in place;
  the desktop tree is rebuilt only when a new divider appears. Performance
  scenarios `etaf-desktop.policy.tiled-{focus,maximize,minimize,close}`
  cover these paths.

- Toggling between floating and tiling layouts publishes through retained
  bindings. The workspace bar label reads a reactive source, tiling divider
  overlays stay mounted and hide through their visibility cells, and
  `etaf-desktop-set-layout-mode` batches the label and geometry writes, so a
  toggle keeps the committed generation once its dividers exist. Requires
  ETAF's prepared bindings under a reactive Theme.

- Window shells and taskbar items receive each window's mode, visibility and
  taskbar state as retained reactive sources, so maximizing, minimizing or
  restoring a window publishes through prepared Host bindings instead of
  rebuilding the desktop tree. `etaf-desktop-layout-mode` is now a pure
  query that no longer resynchronizes layout membership; mutation entry
  points still call `etaf-desktop-layout-refresh`.

- The configured drag-lock modifier now applies to all resize handles as well
  as the title. Locked resizing confirms at the next press. Explicit user
  cancellation restores the starting rectangle through the controlled
  geometry writer; target invalidation and unrelated input retain the last
  accepted geometry without restoring a replacement window.

- Tiled workspaces now default to one cell of outer and inner spacing.
  Configure `:tile-outer-gap` (0–4 cells) and `:tile-inner-gap` (1–4 cells)
  through Desktop Settings or `etaf-desktop-set-setting`; changes reflow the
  active workspace immediately and persist in saved sessions. Set the outer
  gap to zero for tiles flush with the canvas. Divider handles stay centered
  within inner gaps, and outer gaps shrink to preserve pane minimum sizes.

- Desktop Settings now groups appearance, layout, behavior and shortcuts into
  tabs in a compact panel, with Done and Reset settings actions.

- Session snapshots now persist each workspace's layout mode, split tree and
  floating membership, so restore keeps tiling topology and ratios.

- An implicit launch of an application without the `multiple-instances`
  capability focuses its running instance instead of creating a second one.
  Session restore still passes explicit instance ids and recreates every
  recorded instance.

### Fixed

- Session restore preserves floating rectangles, fixed-size windows and tiles
  compressed below their preferred minimum dimensions on small canvases.

- Closing an embedded Desktop View no longer unmounts its host application or
  kills the caller's buffer. Direct mounts and Playground cleanup now share the
  same Runtime ownership rule.

- Minimizing or closing the active window selects a visible replacement and
  keeps application status aligned with the focused window. A maximized tiled
  window keeps its full rectangle while other tiles change. Switching layout
  modes exits temporary maximization so the new tiles remain visible.

- An inactive desktop window renders gray traffic lights and only the active
  window keeps the colored macOS lights.

- Tiling layouts reserve their divider row or column, so the splitter is
  visible between tiles and never covers the second window's title bar.  The
  reserved cells are asserted by the layout acceptance cases.

- Tiling dividers use the same allocated gap as their adjacent windows.
  Nested dividers now render at each subtree's position and size, so their
  overlays remain visible without covering another window's title bar.

- A desktop without explicit `:canvas-width`/`:canvas-height` measures the
  Emacs window that displays it, so the mounted surface fills the visible
  window body instead of whichever window happened to be selected first.
