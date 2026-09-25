# Changelog

All notable changes to ETAF Desktop are documented here.

## Unreleased

### Changed

- Tiling layouts publish window rectangles and divider positions, labels and
  visibility through retained geometry cells. Ratio drags, focus changes,
  maximize and minimize under tiling update the affected windows in place;
  the desktop tree is rebuilt only when a new divider appears. Performance
  scenarios `etaf-desktop.policy.tiled-{focus,maximize,minimize,close}`
  cover these paths.

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
