# Changelog

All notable changes to ETAF Desktop are documented here.

## Unreleased

### Changed

- Session snapshots now persist each workspace's layout mode, split tree and
  floating membership, so restore keeps tiling topology and ratios.

- An implicit launch of an application without the `multiple-instances`
  capability focuses its running instance instead of creating a second one.
  Session restore still passes explicit instance ids and recreates every
  recorded instance.

### Fixed

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
