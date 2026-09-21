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
;; Function: etaf-desktop-create (&key (name "*ETAF Desktop*") (canvas-width 120) (canvas-height 36) (workspaces '(main)))
;;;###autoload (autoload 'etaf-desktop-create "etaf-desktop" nil nil)
;; Create an unmounted desktop controller.  WORKSPACES is a nonempty list of
;; unique keys.  The controller owns a reactive state source and can be mounted
;; with `etaf-desktop-mount'.
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
;; Function: etaf-desktop-open-window (desktop id &key title view (x 0) (y 0) (width 40) (height 12) (min-width 12) (min-height 3) max-width max-height workspace (visible t) (movable t) (resizable t))
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
;; Return the root View for DESKTOP without mounting it.
;;
;; Function: etaf-desktop-mount (desktop &optional buffer-or-name)
;;;###autoload (autoload 'etaf-desktop-mount "etaf-desktop" nil nil)
;; Mount DESKTOP and return its buffer.  A desktop may have one mounted Runtime.
;; Mutations publish through ETAF's reactive path and retain Ebox's committed
;; target and incremental display semantics.
;;
;; Function: etaf-desktop-close (desktop)
;;;###autoload (autoload 'etaf-desktop-close "etaf-desktop" nil nil)
;; Unmount and kill DESKTOP's owned buffer.  Repeated calls are harmless.
;;
;; Function: etaf-desktop-open (&optional desktop buffer-or-name)
;;;###autoload (autoload 'etaf-desktop-open "etaf-desktop" nil t)
;; Create a default desktop when DESKTOP is nil, mount it, and return the
;; controller.  Interactive calls display the mounted buffer.

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

(provide 'etaf-desktop)
;;; etaf-desktop.el ends here
