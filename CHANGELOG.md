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

- An inactive desktop window renders gray traffic lights and only the active
  window keeps the colored macOS lights.

- Tiling layouts reserve their divider row or column, so the splitter is
  visible between tiles and never covers the second window's title bar.  The
  reserved cells are asserted by the layout acceptance cases.

- Tiling dividers are canvas overlays again: they are positioned in canvas
  coordinates, sized to the canvas they separate and painted above every
  window, so the splitter can be seen and dragged.

- A desktop without explicit `:canvas-width`/`:canvas-height` measures the
  Emacs window that displays it, so the mounted surface fills the visible
  window body instead of whichever window happened to be selected first.
