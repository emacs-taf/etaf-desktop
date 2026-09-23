;;; etaf-desktop.el --- Desktop application for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf "0.2.1") (etaf-ui "0.1.0"))
;; Keywords: ui, desktop, tools
;; URL: https://github.com/ginqi7/etaf-desktop

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-desktop) after adding this repository
;; and the ETAF and ETAF UI roots to `load-path'.  The package owns application
;; policy for windows and workspaces.  Ebox remains the geometry and retained
;; publication provider; ETAF owns state and lifecycle; ETAF UI supplies the
;; controls used by the desktop surface.
;;
;; Function: etaf-desktop-create (&key (name "*ETAF Desktop*") canvas-width canvas-height (workspaces '(main)))
;;;###autoload (autoload 'etaf-desktop-create "etaf-desktop" nil nil)
;; Create an unmounted desktop controller.  WORKSPACES is a nonempty list of
;; unique keys.  When CANVAS-WIDTH or CANVAS-HEIGHT is nil, the mounted desktop
;; derives its canvas from the displaying Emacs window and fills its visible
;; body.  The controller owns a reactive state source and can be mounted with
;; `etaf-desktop-mount'.
;;
;; Error: etaf-desktop-error
;; Invalid desktop operation, unknown window/workspace, or rejected geometry.
;;
;; Function: etaf-desktop-state (desktop)
;;;###autoload (autoload 'etaf-desktop-state "etaf-desktop" nil nil)
;; Return a detached plist describing canvas, workspaces, active window and all
;; windows.  The plist and window entries are safe for callers to retain.
;;
;; Function: etaf-desktop-windows (desktop)
;;;###autoload (autoload 'etaf-desktop-windows "etaf-desktop" nil nil)
;; Return detached public window state plists for DESKTOP.
;;
;; Function: etaf-desktop-window-state (desktop id)
;;;###autoload (autoload 'etaf-desktop-window-state "etaf-desktop" nil nil)
;; Return the detached public state for window ID, or signal
;; `etaf-desktop-error' when it is unknown.
;;
;; Function: etaf-desktop-active-window (desktop)
;;;###autoload (autoload 'etaf-desktop-active-window "etaf-desktop" nil nil)
;; Return the active window ID, or nil when the active workspace has no window.
;;
;; Function: etaf-desktop-active-workspace (desktop)
;;;###autoload (autoload 'etaf-desktop-active-workspace "etaf-desktop" nil nil)
;; Return the active workspace key.
;;
;; Function: etaf-desktop-open-window (desktop id &key title view (x 0) (y 0) (width 400) (height 12) (min-width 160) (min-height 3) max-width max-height workspace (visible t) (movable t) (resizable t))
;;;###autoload (autoload 'etaf-desktop-open-window "etaf-desktop" nil nil)
;; Add a window to DESKTOP.  VIEW is caller-owned ETAF View content.  Geometry
;; is in logical desktop units; movable and resizable default to non-nil.  Raise
;; and focus policy is applied when the window opens.
;;
;; Function: etaf-desktop-close-window (desktop id)
;;;###autoload (autoload 'etaf-desktop-close-window "etaf-desktop" nil nil)
;; Remove ID and return non-nil when it existed.
;;
;; Function: etaf-desktop-focus-window (desktop id)
;;;###autoload (autoload 'etaf-desktop-focus-window "etaf-desktop" nil nil)
;; Raise and focus ID, switching to its workspace and restoring it from the
;; minimized taskbar when needed.
;;
;; Function: etaf-desktop-move-window (desktop id x y)
;;;###autoload (autoload 'etaf-desktop-move-window "etaf-desktop" nil nil)
;; Set ID's top-left position.  Moving a maximized window restores its saved
;; rectangle first.
;;
;; Function: etaf-desktop-resize-window (desktop id width height)
;;;###autoload (autoload 'etaf-desktop-resize-window "etaf-desktop" nil nil)
;; Set ID's size, clamped to its minimum and optional maximum.  Resizing a
;; maximized window restores its saved rectangle first.
;;
;; Function: etaf-desktop-maximize-window (desktop id)
;;;###autoload (autoload 'etaf-desktop-maximize-window "etaf-desktop" nil nil)
;; Maximize ID to the desktop canvas and retain its prior rectangle for restore.
;;
;; Function: etaf-desktop-minimize-window (desktop id)
;;;###autoload (autoload 'etaf-desktop-minimize-window "etaf-desktop" nil nil)
;; Hide ID and expose it through the current workspace's taskbar.
;;
;; Function: etaf-desktop-restore-window (desktop id)
;;;###autoload (autoload 'etaf-desktop-restore-window "etaf-desktop" nil nil)
;; Restore ID from minimized or maximized state, then raise and focus it.
;;
;; Function: etaf-desktop-window-maximized-p (desktop id)
;;;###autoload (autoload 'etaf-desktop-window-maximized-p "etaf-desktop" nil nil)
;; Return non-nil when ID is maximized.
;;
;; Function: etaf-desktop-switch-workspace (desktop workspace)
;;;###autoload (autoload 'etaf-desktop-switch-workspace "etaf-desktop" nil nil)
;; Select WORKSPACE and choose its highest visible, non-minimized window.
;;
;; Function: etaf-desktop-add-workspace (desktop workspace)
;;;###autoload (autoload 'etaf-desktop-add-workspace "etaf-desktop" nil nil)
;; Add a unique workspace key and return it.
;;
;; Function: etaf-desktop-remove-workspace (desktop workspace)
;;;###autoload (autoload 'etaf-desktop-remove-workspace "etaf-desktop" nil nil)
;; Remove WORKSPACE, moving its windows to another workspace.  The final
;; workspace cannot be removed.
;;
;; Function: etaf-desktop-view (desktop)
;;;###autoload (autoload 'etaf-desktop-view "etaf-desktop" nil nil)
;; Return the root View for DESKTOP without mounting it.  A caller that mounts
;; this View owns the enclosing ETAF Runtime and buffer and must unmount them.
;;
;; Function: etaf-desktop-mount (desktop &optional buffer-or-name)
;;;###autoload (autoload 'etaf-desktop-mount "etaf-desktop" nil nil)
;; Mount DESKTOP and return its buffer.  A desktop may have one mounted Runtime.
;; This call owns the Runtime it creates; an existing target buffer remains
;; caller-owned.
;; Mutations publish through ETAF's reactive path and retain Ebox's committed
;; target and incremental display semantics.
;;
;; Function: etaf-desktop-close (desktop)
;;;###autoload (autoload 'etaf-desktop-close "etaf-desktop" nil nil)
;; Unmount the Runtime created by `etaf-desktop-mount' and kill its newly
;; created buffer.  A caller-mounted View and an existing target buffer remain
;; caller-owned.  Repeated calls are harmless.
;;
;; Function: etaf-desktop-open (&optional desktop buffer-or-name)
;;;###autoload (autoload 'etaf-desktop-open "etaf-desktop" nil t)
;; Create a default desktop when DESKTOP is nil, mount it, and return the
;; controller.  Interactive calls display the mounted buffer.

;; Function: etaf-desktop-launcher-open-p (desktop)
;;;###autoload (autoload 'etaf-desktop-launcher-open-p "etaf-desktop" nil nil)
;; Return whether DESKTOP's controlled application launcher is visible.

;; Function: etaf-desktop-toggle-launcher (desktop &optional open)
;;;###autoload (autoload 'etaf-desktop-toggle-launcher "etaf-desktop" nil nil)
;; Set or toggle the application launcher visibility and return the new value.

;; Function: etaf-desktop-close-launcher (desktop)
;;;###autoload (autoload 'etaf-desktop-close-launcher "etaf-desktop" nil nil)
;; Close the application launcher.

;; Function: etaf-desktop-switcher-open-p (desktop)
;;;###autoload (autoload 'etaf-desktop-switcher-open-p "etaf-desktop" nil nil)
;; Return whether DESKTOP's controlled window switcher is visible.

;; Function: etaf-desktop-toggle-switcher (desktop &optional open)
;;;###autoload (autoload 'etaf-desktop-toggle-switcher "etaf-desktop" nil nil)
;; Set or toggle the window switcher visibility and return the new value.

;; Function: etaf-desktop-close-switcher (desktop)
;;;###autoload (autoload 'etaf-desktop-close-switcher "etaf-desktop" nil nil)
;; Close the window switcher.

;; Function: etaf-desktop-settings (desktop)
;;;###autoload (autoload 'etaf-desktop-settings "etaf-desktop" nil nil)
;; Return detached user settings for DESKTOP: theme, layout mode, title/content
;; font sizes, optional font family and tiling keybindings.

;; Function: etaf-desktop-set-setting (desktop key value)
;;;###autoload (autoload 'etaf-desktop-set-setting "etaf-desktop" nil nil)
;; Validate and set one user setting.  `:layout-mode' applies immediately to
;; the active workspace; the other values are projected by the retained shell.

;; Function: etaf-desktop-reset-settings (desktop)
;;;###autoload (autoload 'etaf-desktop-reset-settings "etaf-desktop" nil nil)
;; Restore the default Desktop settings and return the detached plist.

;; Function: etaf-desktop-settings-open-p (desktop)
;;;###autoload (autoload 'etaf-desktop-settings-open-p "etaf-desktop" nil nil)
;; Return whether the in-buffer settings modal is visible.

;; Function: etaf-desktop-toggle-settings (desktop &optional open)
;;;###autoload (autoload 'etaf-desktop-toggle-settings "etaf-desktop" nil nil)
;; Open or toggle the reusable ETAF UI settings modal.

;; Function: etaf-desktop-close-settings (desktop)
;;;###autoload (autoload 'etaf-desktop-close-settings "etaf-desktop" nil nil)
;; Close the settings modal without changing its values.
;;
;; Function: etaf-desktop-layout-sync (desktop &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-sync "etaf-desktop" nil nil)
;; Synchronize the layout registry with open windows.  New windows are
;; floating until tiled explicitly; closed windows are removed from trees.
;; Call this after application-level window mutations when using a custom
;; mutation path.
;;
;; Function: etaf-desktop-layout-refresh (desktop &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-refresh "etaf-desktop" nil nil)
;; Synchronize membership and apply `tiling' or `monocle' policy in one guarded
;; publication.  This is the integration hook for desktop mutation paths.
;;
;; Function: etaf-desktop-layout-mode (desktop &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-mode "etaf-desktop" nil nil)
;; Return WORKSPACE's `floating', `tiling', `master-stack' or `monocle' policy mode.
;; WORKSPACE defaults to the active workspace.
;;
;; Function: etaf-desktop-toggle-layout-mode (desktop &optional workspace)
;;;###autoload (autoload 'etaf-desktop-toggle-layout-mode "etaf-desktop" nil t)
;; Switch WORKSPACE between `floating' and `tiling' and return DESKTOP.
;;
;; This is the interactive counterpart of `etaf-desktop-set-layout-mode': the
;; workspace bar's trailing control calls it, and other modes return to tiling.
;;
;; Function: etaf-desktop-set-layout-mode (desktop mode &optional workspace)
;;;###autoload (autoload 'etaf-desktop-set-layout-mode "etaf-desktop" nil nil)
;; Set and apply a workspace layout mode.  Tiling fills the canvas using its
;; layout tree; master-stack gives the first window a wide master region and
;; stacks the rest; monocle fills it with every tree leaf and raises the active
;; window; floating preserves each window's own rectangle.  A mode change exits
;; a temporary maximized view so it cannot cover the new layout.
;;
;; Function: etaf-desktop-layout-tree (desktop &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-tree "etaf-desktop" nil nil)
;; Return a detached layout tree using `(:leaf ID)' and
;; `(:split ORIENTATION RATIO FIRST SECOND)' nodes.
;;
;; Function: etaf-desktop-layout-set-tree (desktop tree &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-set-tree "etaf-desktop" nil nil)
;; Validate and apply a detached layout TREE for WORKSPACE.  Windows omitted
;; from TREE remain floating; this is also the public restore boundary for
;; persisted split topology and ratios.

;; Function: etaf-desktop-layout-floating-windows (desktop &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-floating-windows "etaf-desktop" nil nil)
;; Return floating window IDs for WORKSPACE as a detached list.
;;
;; Function: etaf-desktop-layout-apply (desktop &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-apply "etaf-desktop" nil nil)
;; Apply the current workspace layout and return the calculated rectangle list.
;; Horizontal splits divide width (left/right); vertical splits divide height
;; (top/bottom).  The allocator reserves a three-pixel or one-row divider gap
;; and respects minimum dimensions where possible.  A maximized window keeps
;; its full canvas view until restored or the mode changes.
;;
;; Function: etaf-desktop-layout-tile-window (desktop id &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-tile-window "etaf-desktop" nil nil)
;; Add ID to the workspace tiling tree and apply it.  Existing rectangles are
;; recomputed from the tree.
;;
;; Function: etaf-desktop-layout-untile-window (desktop id &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-untile-window "etaf-desktop" nil nil)
;; Remove ID from the tiling tree and leave it as a floating window.
;;
;; Function: etaf-desktop-layout-split (desktop target new-id orientation ratio &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-split "etaf-desktop" nil nil)
;; Insert NEW-ID beside TARGET using a horizontal or vertical split.  RATIO
;; controls the existing TARGET side and must be strictly between zero and one.
;; Both windows must already belong to WORKSPACE.
;;
;; Function: etaf-desktop-layout-resize-split (desktop path ratio &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-resize-split "etaf-desktop" nil nil)
;; Change the split at PATH, where each path element is 0 (first child) or 1
;; (second child), then apply the layout.
;;
;; Function: etaf-desktop-layout-remove-window (desktop id &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-remove-window "etaf-desktop" nil nil)
;; Remove ID from layout policy after its owning window is closed.  This does
;; not close the window itself.

;; Function: etaf-desktop-register-app (id &key title icon open close serialize restore capabilities default-window replace)
;;;###autoload (autoload 'etaf-desktop-register-app "etaf-desktop" nil nil)
;; Register an ETAF application manifest.  Its callbacks receive a context
;; plist and may create one or more desktop windows.  Return a detached
;; manifest plist.

;; Function: etaf-desktop-unregister-app (id &optional force)
;;;###autoload (autoload 'etaf-desktop-unregister-app "etaf-desktop" nil nil)
;; Remove an application manifest, rejecting live instances unless FORCE is
;; non-nil.

;; Function: etaf-desktop-app (id)
;;;###autoload (autoload 'etaf-desktop-app "etaf-desktop" nil nil)
;; Return a detached manifest plist for ID.

;; Function: etaf-desktop-apps ()
;;;###autoload (autoload 'etaf-desktop-apps "etaf-desktop" nil nil)
;; Return all registered application manifests.

;; Function: etaf-desktop-app-registered-p (id)
;;;###autoload (autoload 'etaf-desktop-app-registered-p "etaf-desktop" nil nil)
;; Return non-nil when ID is registered.

;; Function: etaf-desktop-launch (desktop app-id &key instance-id options restore-data restore workspace)
;;;###autoload (autoload 'etaf-desktop-launch "etaf-desktop" nil nil)
;; Start an application instance.  Callback failures are isolated in an error
;; instance and placeholder window while the desktop remains usable.

;; Function: etaf-desktop-instances (desktop)
;;;###autoload (autoload 'etaf-desktop-instances "etaf-desktop" nil nil)
;; Return detached application instance states for DESKTOP.

;; Function: etaf-desktop-instance (desktop id)
;;;###autoload (autoload 'etaf-desktop-instance "etaf-desktop" nil nil)
;; Return detached state for application instance ID.

;; Function: etaf-desktop-set-instance-state (desktop id state)
;;;###autoload (autoload 'etaf-desktop-set-instance-state "etaf-desktop" nil nil)
;; Set application-owned serializable state for an instance.

;; Function: etaf-desktop-focus-instance (desktop id)
;;;###autoload (autoload 'etaf-desktop-focus-instance "etaf-desktop" nil nil)
;; Focus the first visible window belonging to application instance ID.

;; Function: etaf-desktop-suspend-instance (desktop id)
;;;###autoload (autoload 'etaf-desktop-suspend-instance "etaf-desktop" nil nil)
;; Minimize an application's windows and mark its lifecycle suspended.

;; Function: etaf-desktop-restore-instance (desktop id)
;;;###autoload (autoload 'etaf-desktop-restore-instance "etaf-desktop" nil nil)
;; Restore an application's windows and focus its instance.

;; Function: etaf-desktop-close-instance (desktop id &optional reason)
;;;###autoload (autoload 'etaf-desktop-close-instance "etaf-desktop" nil nil)
;; Close an application instance, invoke its callback and release its windows.

;; Function: etaf-desktop-session-state (desktop)
;;;###autoload (autoload 'etaf-desktop-session-state "etaf-desktop" nil nil)
;; Return a serializable desktop and application session plist.

;; Function: etaf-desktop-save-session (desktop file)
;;;###autoload (autoload 'etaf-desktop-save-session "etaf-desktop" nil nil)
;; Save a session plist to FILE.

;; Function: etaf-desktop-restore-session (desktop session-or-file)
;;;###autoload (autoload 'etaf-desktop-restore-session "etaf-desktop" nil nil)
;; Restore a session plist or saved FILE; unknown applications become isolated
;; error placeholders.

;;; Code:

;;;###autoload
(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name "lisp"
                                 (file-name-directory
                                  (or load-file-name
                                      (bound-and-true-p byte-compile-current-file)
                                      buffer-file-name)))))

(require 'etaf-desktop-runtime)
(require 'etaf-desktop-layout)
(require 'etaf-desktop-apps)

(provide 'etaf-desktop)
;;; etaf-desktop.el ends here
