;;; etaf-desktop-runtime.el --- Desktop application state and view -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)

(declare-function ebox-viewport-window-width "ebox-viewport" (window))
(defvar ebox-viewport-width)
(defvar ebox-viewport-height)
(defvar etaf-desktop--layout-divider-px)
(defvar etaf-desktop--layout-divider-rows)
(declare-function etaf-desktop-layout-mode "etaf-desktop-layout"
                  (desktop &optional workspace))
(declare-function etaf-desktop--layout-ensure-workspace "etaf-desktop-layout"
                  (desktop workspace))
(declare-function etaf-desktop--layout-workspace-mode "etaf-desktop-layout" (workspace))
(declare-function etaf-desktop-set-layout-mode "etaf-desktop-layout"
                  (desktop mode &optional workspace))
(declare-function etaf-desktop-layout-tree "etaf-desktop-layout"
                  (desktop &optional workspace))
(declare-function etaf-desktop-toggle-layout-mode "etaf-desktop-layout"
                  (desktop &optional workspace))
(declare-function etaf-desktop-layout-refresh "etaf-desktop-layout"
                  (desktop &optional workspace))
(declare-function etaf-desktop-layout-resize-split "etaf-desktop-layout"
                  (desktop path ratio &optional workspace))
(declare-function etaf-desktop-layout-split "etaf-desktop-layout"
                  (desktop target new-id orientation ratio &optional workspace))
(declare-function etaf-desktop--layout-partition "etaf-desktop-layout"
                  (state node spacing x y width height))
(declare-function etaf-desktop--layout-spacing "etaf-desktop-layout" (desktop))
(declare-function etaf-desktop--layout-canvas-rect "etaf-desktop-layout"
                  (desktop state tree spacing mode))
(declare-function etaf-desktop-app "etaf-desktop-apps" (id))

(define-error 'etaf-desktop-error "Invalid ETAF Desktop operation")

(cl-defstruct (etaf-desktop--window
               (:constructor etaf-desktop--window-create))
  id title view x-source y-source width-source height-source
  min-width min-height max-width max-height
  visible minimized maximized workspace normal-geometry z-index-source movable resizable
  geometry-input geometry-writer focus-writer)

(cl-defstruct (etaf-desktop--state
               (:constructor etaf-desktop--state-create))
  windows workspaces active-workspace active-window-source next-z)

(defmacro etaf-desktop--define-state-field (record field &optional unit)
  "Define FIELD access on RECORD with one authoritative reactive cell.
Detached mutation candidates store scalars; retained records store refs.
UNIT describes the canonical value supplied directly to UI geometry props."
  (let ((reader (intern (format "etaf-desktop--%s-%s" record field)))
        (writer (intern (format "etaf-desktop--set-%s-%s" record field)))
        (source (intern (format "etaf-desktop--%s-%s-source" record field)))
        (retain (intern (format "etaf-desktop--retain-%s-%s" record field))))
    `(progn
       (defun ,reader (record)
         ,(format "Read %s from RECORD without exposing its reactive cell." field)
         (let ((source (,source record)))
           (if (etaf-ref-p source)
               ,(if unit '(cadr (etaf-value source)) '(etaf-value source))
             source)))
       (defun ,writer (record value)
         ,(format "Write %s VALUE to RECORD's scalar or retained cell." field)
         (let ((source (,source record)))
           (if (etaf-ref-p source)
               ,(if unit
                    `(let ((current (etaf-value source)))
                       (etaf-set-value source
                                       (if (equal (cadr current) value)
                                           current
                                         (list ',unit value))))
                  '(etaf-set-value source value))
             (setf (,source record) value)))
         value)
       (gv-define-simple-setter ,reader ,writer)
       (defun ,retain (record previous)
         ,(format "Retain %s's authoritative source in RECORD from PREVIOUS." field)
         (let* ((value (,reader record))
                (source (and previous (,source previous))))
           (if (etaf-ref-p source)
               (progn
                 (setf (,source record) source)
                 (,writer record value))
             (setf (,source record)
                   (etaf-ref ,(if unit `(list ',unit value) 'value)
                             :test #'equal))))))))

(etaf-desktop--define-state-field window x px)
(etaf-desktop--define-state-field window y lh)
(etaf-desktop--define-state-field window width px)
(etaf-desktop--define-state-field window height lh)
(etaf-desktop--define-state-field window z-index)
(etaf-desktop--define-state-field state active-window)

(cl-defstruct (etaf-desktop--controller
               (:constructor etaf-desktop--controller-create))
  name canvas-width canvas-height state-ref buffer runtime launcher-ref switcher-ref
  settings-ref settings-open-ref owns-runtime-p owns-buffer-p)

(defun etaf-desktop--default-settings ()
  "Return the detached default settings for a new Desktop controller."
  (list :theme 'system
        :accent-color "#3657D6"
        :layout-mode 'floating
        :tile-outer-gap 1
        :tile-inner-gap 1
        :title-font-size 14
        :content-font-size 14
        :font-family nil
        :drag-lock-modifier 'shift
        :resize-enabled t
        :confirm-close nil
        :taskbar-grouping 'window
        :keybindings
        (list :focus-next "n"
              :focus-previous "p"
              :launcher "a"
              :switcher "w"
              :settings "o"
              :toggle-layout "l"
              :split-window "s"
              :swap-window "x"
              :maximize-window "m"
              :restore-window "r"
              :minimize-window "i"
              :close-window "q")))

(defun etaf-desktop--fail (format-string &rest arguments)
  "Signal `etaf-desktop-error' with FORMAT-STRING and ARGUMENTS."
  (signal 'etaf-desktop-error (list (apply #'format format-string arguments))))

(defun etaf-desktop--controller (desktop)
  "Validate and return DESKTOP."
  (unless (etaf-desktop--controller-p desktop)
    (etaf-desktop--fail "Expected an ETAF desktop, got %S" desktop))
  desktop)

(defun etaf-desktop--state (desktop)
  "Return DESKTOP's current state."
  (etaf-value (etaf-desktop--controller-state-ref desktop)))

(defun etaf-desktop--settings (desktop)
  "Return DESKTOP's current settings plist."
  (copy-tree
   (etaf-value (etaf-desktop--controller-settings-ref
                (etaf-desktop--controller desktop)))))

(defun etaf-desktop-settings (desktop)
  "Return a detached settings plist for DESKTOP.

Settings are caller-visible configuration, not a second geometry store.  Use
`etaf-desktop-set-setting' or `etaf-desktop-reset-settings' to change them."
  (etaf-desktop--settings desktop))

(defun etaf-desktop-settings-open-p (desktop)
  "Return non-nil when DESKTOP's settings dialog is open."
  (etaf-value (etaf-desktop--controller-settings-open-ref
               (etaf-desktop--controller desktop))))

(defun etaf-desktop-toggle-settings (desktop &optional open)
  "Set DESKTOP's settings dialog to OPEN, or toggle it when OPEN is nil."
  (let* ((desktop (etaf-desktop--controller desktop))
         (ref (etaf-desktop--controller-settings-open-ref desktop))
         (value (if (null open) (not (etaf-value ref)) open)))
    (etaf-set-value ref value)
    value))

(defun etaf-desktop-close-settings (desktop)
  "Close DESKTOP's settings dialog and return nil."
  (etaf-set-value
   (etaf-desktop--controller-settings-open-ref
    (etaf-desktop--controller desktop))
   nil)
  nil)

(defun etaf-desktop--valid-setting-p (key value)
  "Return non-nil when KEY accepts VALUE as a Desktop setting."
  (pcase key
    (:theme (memq value '(system light dark)))
    (:accent-color
     (and (stringp value)
          (string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'" value)))
    (:layout-mode (memq value '(floating tiling master-stack monocle)))
    (:tile-outer-gap (and (integerp value) (<= 0 value 4)))
    (:tile-inner-gap (and (integerp value) (<= 1 value 4)))
    ((or :title-font-size :content-font-size)
     (and (numberp value) (>= value 8) (<= value 32)))
    (:font-family (or (null value) (stringp value)))
    (:drag-lock-modifier (memq value '(nil shift control meta super hyper)))
    (:resize-enabled (booleanp value))
    (:confirm-close (booleanp value))
    (:taskbar-grouping (memq value '(window application)))
    (:keybindings
     (and (listp value)
          (cl-loop for (name binding) on value by #'cddr
                   always (and (keywordp name) (stringp binding)
                               (not (string-empty-p binding))
                               (condition-case nil
                                   (progn (ignore (kbd binding)) t)
                                 (error nil))))))
    (_ nil)))

(defun etaf-desktop-set-setting (desktop key value)
  "Set DESKTOP setting KEY to VALUE and return its detached settings.

Layout mode and tile spacing changes apply to the active workspace
immediately; other settings project through the next retained shell publication."
  (let ((desktop (etaf-desktop--controller desktop)))
    (unless (and (keywordp key) (etaf-desktop--valid-setting-p key value))
      (etaf-desktop--fail "Invalid Desktop setting %S=%S" key value))
    (let ((settings (etaf-desktop--settings desktop)))
      (setq settings (plist-put settings key (copy-tree value)))
      (etaf-set-value (etaf-desktop--controller-settings-ref desktop) settings)
      (when (eq key :layout-mode)
        (etaf-desktop-set-layout-mode
         desktop value (etaf-desktop-active-workspace desktop)))
      (when (memq key '(:tile-outer-gap :tile-inner-gap))
        (etaf-desktop-layout-refresh desktop))
      (when (eq key :keybindings)
        (etaf-desktop--refresh-buffer-keymap desktop))
      (etaf-desktop-settings desktop))))

(defun etaf-desktop-reset-settings (desktop)
  "Restore DESKTOP's default settings and return them."
  (let ((desktop (etaf-desktop--controller desktop)))
    (etaf-set-value (etaf-desktop--controller-settings-ref desktop)
                    (etaf-desktop--default-settings))
    (etaf-desktop-set-layout-mode
     desktop 'floating (etaf-desktop-active-workspace desktop))
    (etaf-desktop-settings desktop)))

(defun etaf-desktop--set-keybinding (desktop key value)
  "Set one keybinding KEY in DESKTOP settings to VALUE."
  (unless (and (keywordp key) (stringp value) (not (string-empty-p value)))
    (etaf-desktop--fail "Invalid Desktop keybinding %S=%S" key value))
  (let ((bindings (copy-tree
                   (plist-get (etaf-desktop--settings desktop) :keybindings))))
    (setq bindings (plist-put bindings key value))
    (etaf-desktop-set-setting desktop :keybindings bindings)))

(defun etaf-desktop--focus-relative (desktop direction)
  "Focus the next or previous visible window in the active workspace."
  (let* ((state (etaf-desktop--state desktop))
         (windows (sort
                   (cl-remove-if-not
                    (lambda (window)
                      (and (equal (etaf-desktop--window-workspace window)
                                  (etaf-desktop--state-active-workspace state))
                           (etaf-desktop--window-visible window)
                           (not (etaf-desktop--window-minimized window))))
                    (copy-sequence (etaf-desktop--state-windows state)))
                   (lambda (left right)
                     (< (etaf-desktop--window-z-index left)
                        (etaf-desktop--window-z-index right)))))
         (ids (mapcar #'etaf-desktop--window-id windows))
         (active (etaf-desktop--state-active-window state))
         (index (or (cl-position active ids :test #'equal)
                    (if (> direction 0) -1 (length ids))))
         (next (and ids (nth (mod (+ index direction) (length ids)) ids))))
    (when next (etaf-desktop-focus-window desktop next))))

(defun etaf-desktop--active-window-id (desktop)
  "Return the active window ID or nil."
  (etaf-desktop-active-window desktop))

(defun etaf-desktop--split-active-window (desktop)
  "Split the active window beside the next visible workspace window."
  (let* ((active (etaf-desktop--active-window-id desktop))
         (windows (etaf-desktop-windows desktop))
         (other (cl-find-if
                 (lambda (window)
                   (and (equal (plist-get window :workspace)
                               (etaf-desktop-active-workspace desktop))
                        (not (equal (plist-get window :id) active))))
                 windows)))
    (when (and active other (fboundp 'etaf-desktop-layout-split))
      (etaf-desktop-layout-split desktop active (plist-get other :id)
                                  'horizontal 0.5)
      (etaf-desktop-set-layout-mode desktop 'tiling)))
  desktop)

(defun etaf-desktop--swap-active-window (desktop)
  "Swap the active window's floating rectangle with the next window."
  (let* ((state (etaf-desktop--state desktop))
         (active (etaf-desktop--state-active-window state))
         (windows (etaf-desktop--state-windows state))
         (other
          (cl-find-if
           (lambda (window)
             (and (equal (etaf-desktop--window-workspace window)
                         (etaf-desktop--state-active-workspace state))
                  (not (equal (etaf-desktop--window-id window) active))))
           windows)))
    (when-let* ((first (etaf-desktop--window-for state active))
                (second other))
      (let ((first-geometry (etaf-desktop--geometry first))
            (second-geometry (etaf-desktop--geometry second)))
        (etaf-desktop--update
         desktop
         (lambda (next)
           (let ((left (etaf-desktop--window-for next active))
                 (right (etaf-desktop--window-for next
                                                   (etaf-desktop--window-id second))))
             (dolist (pair (list (cons left second-geometry)
                                 (cons right first-geometry)))
               (setf (etaf-desktop--window-x (car pair)) (nth 0 (cdr pair))
                     (etaf-desktop--window-y (car pair)) (nth 1 (cdr pair))
                     (etaf-desktop--window-width (car pair)) (nth 2 (cdr pair))
                     (etaf-desktop--window-height (car pair)) (nth 3 (cdr pair))
                     (etaf-desktop--window-normal-geometry (car pair))
                     (copy-sequence (cdr pair))))
             (etaf-desktop--raise next left))))))
  desktop))

(defun etaf-desktop--buffer-keymap (desktop)
  "Build the current Desktop buffer keymap from user settings."
  (let* ((bindings (plist-get (etaf-desktop--settings desktop) :keybindings))
         (active (lambda () (etaf-desktop--active-window-id desktop)))
         (actions
          (list
           (cons :focus-next (lambda () (etaf-desktop--focus-relative desktop 1)))
           (cons :focus-previous (lambda () (etaf-desktop--focus-relative desktop -1)))
           (cons :launcher (lambda () (etaf-desktop-toggle-launcher desktop)))
           (cons :switcher (lambda () (etaf-desktop-toggle-switcher desktop)))
           (cons :settings (lambda () (etaf-desktop-toggle-settings desktop)))
           (cons :toggle-layout
                 (lambda () (etaf-desktop-toggle-layout-mode desktop)))
           (cons :split-window
                 (lambda () (etaf-desktop--split-active-window desktop)))
           (cons :swap-window
                 (lambda () (etaf-desktop--swap-active-window desktop)))
           (cons :maximize-window
                 (lambda () (when-let* ((id (funcall active)))
                              (etaf-desktop-maximize-window desktop id))))
           (cons :restore-window
                 (lambda () (when-let* ((id (funcall active)))
                              (etaf-desktop-restore-window desktop id))))
           (cons :minimize-window
                 (lambda () (when-let* ((id (funcall active)))
                              (etaf-desktop-minimize-window desktop id))))
           (cons :close-window
                 (lambda () (when-let* ((id (funcall active)))
                              (etaf-desktop-close-window desktop id)))))))
    (let ((map (make-sparse-keymap)))
      (cl-loop for (key action) on bindings by #'cddr do
               (let ((callback (cdr (assq key actions))))
                 (when (and callback (stringp action))
                   (condition-case nil
                       (define-key map (kbd action)
                                   (let ((handler callback))
                                     (lambda ()
                                       (interactive)
                                       (funcall handler))))
                     (error nil)))))
      map)))

(defvar-local etaf-desktop--keymap-active nil
  "Non-nil while the Desktop buffer-local keymap is active.")

(defun etaf-desktop--lifecycle-buffer (desktop)
  "Return the buffer owned by DESKTOP's current lifecycle Runtime.

`etaf-mount' may be called with a buffer name while another buffer is
current.  Lifecycle callbacks therefore use the Runtime supplied by ETAF;
fall back to DESKTOP's recorded buffer for callbacks outside a live Runtime."
  (or (when-let* ((runtime (etaf-current-runtime)))
        (etaf-runtime-buffer runtime))
      (etaf-desktop--controller-buffer desktop)
      (current-buffer)))

(defun etaf-desktop--refresh-buffer-keymap (desktop &optional buffer)
  "Install DESKTOP's settings keymap in BUFFER or its owned mount."
  (when-let* ((buffer (or buffer (etaf-desktop--controller-buffer desktop)))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      ;; `minor-mode-overriding-map-alist' activates an entry only while the
      ;; corresponding buffer-local mode variable is non-nil.  Desktop is a
      ;; mounted surface rather than a user-visible minor mode, so retain the
      ;; same local precedence contract with a private marker variable.
      (setq-local etaf-desktop--keymap-active t)
      (let ((entry (assq 'etaf-desktop--keymap-active
                         minor-mode-overriding-map-alist)))
        (if entry
            (setcdr entry (etaf-desktop--buffer-keymap desktop))
          (push (cons 'etaf-desktop--keymap-active
                      (etaf-desktop--buffer-keymap desktop))
                minor-mode-overriding-map-alist))))))

(defun etaf-desktop--clear-buffer-keymap (desktop &optional buffer)
  "Remove DESKTOP's local keymap from BUFFER or its owned mount."
  (when-let* ((buffer (or buffer (etaf-desktop--controller-buffer desktop)))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (setq minor-mode-overriding-map-alist
            (assq-delete-all 'etaf-desktop--keymap-active
                             minor-mode-overriding-map-alist)
            etaf-desktop--keymap-active nil))))

(defvar etaf-desktop--mount-window nil
  "Window mounting the current desktop while its first View renders.")

(defun etaf-desktop--canvas-window (desktop)
  "Return the live Emacs window displaying DESKTOP, when available.

A consumer may render this View itself (for example a Playground preview), so
the window currently displaying the rendered buffer wins over the window that
happens to be selected."
  (or (and (buffer-live-p (etaf-desktop--controller-buffer desktop))
           (get-buffer-window (etaf-desktop--controller-buffer desktop) t))
      (get-buffer-window (current-buffer) t)
      (and (window-live-p etaf-desktop--mount-window) etaf-desktop--mount-window)
      (selected-window)))

(defun etaf-desktop--canvas-box-width (desktop)
  "Return the shell/canvas width value for DESKTOP's mounted surface.

A rendered viewport fits exactly and needs no pixel conversion, so the shell
uses `stretch' there; outside a window (headless or batch callers) the
measured pixel canvas keeps deterministic geometry."
  (if (and (numberp ebox-viewport-width) (> ebox-viewport-width 0))
      'stretch
    (list 'px (etaf-desktop--canvas-width-value desktop))))

(defun etaf-desktop--window-canvas-size (window)
  "Return the (WIDTH . HEIGHT) an unconfigured desktop filling WINDOW uses.

WIDTH is the window body's pixel width and HEIGHT leaves one row for the
workspace bar and one for the taskbar, so a default desktop owns exactly the
visible window body."
  (cons (or (ebox-viewport-window-width window)
            (let ((pixel-width (window-body-width window t)))
              (if (> pixel-width 10)
                  pixel-width
                (* (max 1 (window-body-width window))
                   (max 1 (frame-char-width))))))
        (max 8 (- (window-body-height window) 2))))

(defun etaf-desktop--canvas-width-value (desktop)
  "Return DESKTOP's effective canvas width in pixels.

A default desktop follows the render viewport, so a consumer that mounts the
View itself (for example a Playground preview) still fills the window it is
displayed in; the window measurement remains the fallback outside rendering."
  (if-let* ((explicit (etaf-desktop--controller-canvas-width desktop)))
      explicit
    ;; A default desktop fills the viewport it renders in; the window
    ;; measurement is the fallback for callers that render outside a displayed
    ;; window.  The result stays on the character grid so a rounded-up pixel
    ;; column cannot push a row into Emacs continuation.
    (let* ((viewport (and (numberp ebox-viewport-width) (> ebox-viewport-width 0)
                          ebox-viewport-width))
           (width (or viewport
                      (let ((window (etaf-desktop--canvas-window desktop)))
                        (if (window-live-p window)
                            (car (etaf-desktop--window-canvas-size window))
                          (* 80 (max 1 (frame-char-width)))))))
           (char-width (max 1 (frame-char-width))))
      (max char-width (* char-width (floor (/ width char-width)))))))

(defun etaf-desktop--canvas-height-value (desktop)
  "Return DESKTOP's effective canvas height in text rows.

One row is reserved for the workspace bar and one for the taskbar; the mounted
desktop hides buffer chrome, so no extra padding row is needed at the bottom."
  (or (etaf-desktop--controller-canvas-height desktop)
      (and (numberp ebox-viewport-height) (> ebox-viewport-height 0)
           (max 8 (- ebox-viewport-height 2)))
      (let ((window (etaf-desktop--canvas-window desktop)))
        (if (window-live-p window)
            (cdr (etaf-desktop--window-canvas-size window))
          24))))

(defun etaf-desktop--copy-window (window)
  "Copy WINDOW's application state."
  (etaf-desktop--window-create
   :id (etaf-desktop--window-id window)
   :title (etaf-desktop--window-title window)
   :view (etaf-desktop--window-view window)
   :x-source (etaf-desktop--window-x window)
   :y-source (etaf-desktop--window-y window)
   :width-source (etaf-desktop--window-width window)
   :height-source (etaf-desktop--window-height window)
   :min-width (etaf-desktop--window-min-width window)
   :min-height (etaf-desktop--window-min-height window)
   :max-width (etaf-desktop--window-max-width window)
   :max-height (etaf-desktop--window-max-height window)
   :visible (etaf-desktop--window-visible window)
   :minimized (etaf-desktop--window-minimized window)
   :maximized (etaf-desktop--window-maximized window)
   :workspace (etaf-desktop--window-workspace window)
   :normal-geometry (copy-sequence (etaf-desktop--window-normal-geometry window))
   :z-index-source (etaf-desktop--window-z-index window)
   :movable (etaf-desktop--window-movable window)
   :resizable (etaf-desktop--window-resizable window)))

(defun etaf-desktop--copy-state (state)
  "Copy STATE without copying caller-owned View values."
  (etaf-desktop--state-create
   :windows (mapcar #'etaf-desktop--copy-window
                    (etaf-desktop--state-windows state))
   :workspaces (copy-sequence (etaf-desktop--state-workspaces state))
   :active-workspace (etaf-desktop--state-active-workspace state)
   :active-window-source (etaf-desktop--state-active-window state)
   :next-z (etaf-desktop--state-next-z state)))

(defun etaf-desktop--state-signature (state)
  "Return the mutable Desktop facts used to detect a no-op update.

Window Views are caller-owned retained trees and must not participate in this
comparison.  Geometry and lifecycle updates only change the scalar fields
below, so avoiding a publication when those facts are unchanged keeps a drag's
terminal event from rebuilding the retained Runtime tree a second time."
  (list
   (etaf-desktop--state-workspaces state)
   (etaf-desktop--state-active-workspace state)
   (etaf-desktop--state-active-window state)
   (etaf-desktop--state-next-z state)
   (mapcar
    (lambda (window)
      (list (etaf-desktop--window-id window)
            (etaf-desktop--window-title window)
            (etaf-desktop--window-x window)
            (etaf-desktop--window-y window)
            (etaf-desktop--window-width window)
            (etaf-desktop--window-height window)
            (etaf-desktop--window-min-width window)
            (etaf-desktop--window-min-height window)
            (etaf-desktop--window-max-width window)
            (etaf-desktop--window-max-height window)
            (etaf-desktop--window-visible window)
            (etaf-desktop--window-minimized window)
            (etaf-desktop--window-maximized window)
            (etaf-desktop--window-workspace window)
            (etaf-desktop--window-normal-geometry window)
            (etaf-desktop--window-z-index window)
            (etaf-desktop--window-movable window)
            (etaf-desktop--window-resizable window)))
    (etaf-desktop--state-windows state))))

(defun etaf-desktop--window-for (state id)
  "Return the window named ID in STATE, or nil."
  (cl-find id (etaf-desktop--state-windows state)
           :key #'etaf-desktop--window-id :test #'equal))

(defun etaf-desktop--workspace-present-p (state workspace)
  "Return non-nil when WORKSPACE is present in STATE."
  (member workspace (etaf-desktop--state-workspaces state)))

(defun etaf-desktop--assert-workspace (state workspace)
  "Signal when WORKSPACE is not in STATE."
  (unless (etaf-desktop--workspace-present-p state workspace)
    (etaf-desktop--fail "Unknown desktop workspace: %S" workspace))
  workspace)

(defun etaf-desktop--number (value name minimum)
  "Validate numeric VALUE named NAME and bounded by MINIMUM."
  (unless (and (integerp value) (>= value minimum))
    (etaf-desktop--fail "%s must be an integer >= %d, got %S"
                        name minimum value))
  value)

(defun etaf-desktop--prepare-window-writers (state window)
  "Prepare reusable scalar writers for WINDOW in retained STATE.
INPUT is invocation storage, never queried as desktop state.  Geometry refs
remain authoritative; NORMAL belongs to this record and public snapshots
copy it before returning it to callers."
  (let ((input (vector 0 0 0 0))
        (normal (etaf-desktop--window-normal-geometry window)))
    (setf (etaf-desktop--window-geometry-input window) input
          (etaf-desktop--window-geometry-writer window)
          (lambda ()
            (let ((x (aref input 0)) (y (aref input 1))
                  (width (aref input 2)) (height (aref input 3)))
              (setf (etaf-desktop--window-x window) x
                    (etaf-desktop--window-y window) y
                    (etaf-desktop--window-width window) width
                    (etaf-desktop--window-height window) height)
              (setcar normal x)
              (setcar (cdr normal) y)
              (setcar (cddr normal) width)
              (setcar (cdddr normal) height)
              (etaf-desktop--raise state window)))
          (etaf-desktop--window-focus-writer window)
          (lambda ()
            (etaf-desktop--raise state window)
            (etaf-desktop--window-id window)))))

(defun etaf-desktop--publish (desktop state)
  "Publish a detached structural STATE while retaining live scalar sources."
  (let ((previous (etaf-desktop--state desktop)))
    (etaf-call-with-batch
     (lambda ()
       (dolist (window (etaf-desktop--state-windows state))
         (let ((old (etaf-desktop--window-for
                     previous (etaf-desktop--window-id window))))
           (etaf-desktop--retain-window-x window old)
           (etaf-desktop--retain-window-y window old)
           (etaf-desktop--retain-window-width window old)
           (etaf-desktop--retain-window-height window old)
           (etaf-desktop--retain-window-z-index window old)
           (etaf-desktop--prepare-window-writers state window)))
       (etaf-desktop--retain-state-active-window state previous)
       (etaf-set-value (etaf-desktop--controller-state-ref desktop) state))))
  ;; Layout policy is an optional application-layer consumer of the runtime.
  ;; Its guarded refresh applies an active tiling/monocle tree after ordinary
  ;; window mutations, while avoiding a recursive publish during layout apply.
  (when (fboundp 'etaf-desktop-layout-refresh)
    (etaf-desktop-layout-refresh desktop))
  state)

(defun etaf-desktop--floating-window-p (desktop state window)
  "Return whether WINDOW permits direct scalar changes in current STATE."
  (and (equal (etaf-desktop--state-active-workspace state)
              (etaf-desktop--window-workspace window))
       (not (etaf-desktop--window-maximized window))
       (eq 'floating
           (etaf-desktop--layout-workspace-mode
            (etaf-desktop--layout-ensure-workspace
             desktop (etaf-desktop--state-active-workspace state))))))

(defun etaf-desktop--write-geometry (window x y width height)
  "Write WINDOW's known geometry and raise it without rebuilding desktop state.
The four geometry cells are authoritative.  The normal rectangle is the
separate lifecycle value used when entering and leaving maximization."
  (let ((input (etaf-desktop--window-geometry-input window)))
    (aset input 0 x)
    (aset input 1 y)
    (aset input 2 width)
    (aset input 3 height)
    (etaf-call-with-batch (etaf-desktop--window-geometry-writer window)))
  (etaf-desktop--window-plist window))

(defun etaf-desktop--update (desktop function &optional force-publication)
  "Copy DESKTOP state, call FUNCTION with it, and publish the copy.
FORCE-PUBLICATION also commits a layout policy change when geometry is equal."
  (let* ((desktop (etaf-desktop--controller desktop))
         (current (etaf-desktop--state desktop))
         (state (etaf-desktop--copy-state current))
         (result (funcall function state)))
    ;; Ebox emits a terminal drag event with the same geometry as its final
    ;; move event.  Do not publish an unchanged state: the retained Runtime
    ;; tree and Ebox surface are already current.
    (when (or force-publication
              (not (equal (etaf-desktop--state-signature current)
                          (etaf-desktop--state-signature state))))
      (etaf-desktop--publish desktop state))
    result))

(defun etaf-desktop--raise (state window)
  "Raise WINDOW in STATE and make it active."
  (unless (and (equal (etaf-desktop--state-active-window state)
                      (etaf-desktop--window-id window))
               (equal (etaf-desktop--state-active-workspace state)
                      (etaf-desktop--window-workspace window))
               ;; NEXT-Z is the monotone allocation cursor, so its preceding
               ;; value identifies the highest layer without scanning peers.
               (>= (etaf-desktop--window-z-index window)
                   (1- (etaf-desktop--state-next-z state))))
    (setf (etaf-desktop--window-z-index window)
          (etaf-desktop--state-next-z state)
          (etaf-desktop--state-next-z state)
          (1+ (etaf-desktop--state-next-z state))))
  (setf (etaf-desktop--state-active-window state)
        (etaf-desktop--window-id window)
        (etaf-desktop--state-active-workspace state)
        (etaf-desktop--window-workspace window))
  window)

(defun etaf-desktop--notify-window-event (desktop id event)
  "Notify the application registry that window ID experienced EVENT.

The runtime owns window geometry and deliberately does not require the
application registry (which depends on this module).  The optional callback is
installed by `etaf-desktop-apps' when the full package is loaded, keeping the
provider dependency acyclic while allowing app-instance lifecycle state to
follow direct window interactions."
  (when (fboundp 'etaf-desktop--application-window-event)
    (funcall #'etaf-desktop--application-window-event desktop id event)))

(defun etaf-desktop--geometry (window)
  "Return WINDOW's current geometry as `(X Y WIDTH HEIGHT)'."
  (list (etaf-desktop--window-x window)
        (etaf-desktop--window-y window)
        (etaf-desktop--window-width window)
        (etaf-desktop--window-height window)))

(defun etaf-desktop--clamp (value minimum maximum)
  "Clamp VALUE to MINIMUM and optional MAXIMUM."
  (max minimum (if maximum (min maximum value) value)))

(defun etaf-desktop--window-plist (window)
  "Return a detached public state plist for WINDOW."
  (list :id (etaf-desktop--window-id window)
        :title (etaf-desktop--window-title window)
        :x (etaf-desktop--window-x window)
        :y (etaf-desktop--window-y window)
        :width (etaf-desktop--window-width window)
        :height (etaf-desktop--window-height window)
        :min-width (etaf-desktop--window-min-width window)
        :min-height (etaf-desktop--window-min-height window)
        :max-width (etaf-desktop--window-max-width window)
        :max-height (etaf-desktop--window-max-height window)
        :visible (etaf-desktop--window-visible window)
        :minimized (etaf-desktop--window-minimized window)
        :maximized (etaf-desktop--window-maximized window)
        :workspace (etaf-desktop--window-workspace window)
        :z-index (etaf-desktop--window-z-index window)
        :normal-geometry (copy-sequence (etaf-desktop--window-normal-geometry window))
        :movable (etaf-desktop--window-movable window)
        :resizable (etaf-desktop--window-resizable window)))

(defun etaf-desktop--window-ref (id)
  "Return a stable host ref for window ID."
  (intern (format "etaf-desktop-window-%s" id)))

(defun etaf-desktop--delta (gesture)
  "Return desktop-unit X and Y displacement from GESTURE.

Ebox reports both pointer coordinates and DELTA in text-area pixels.  Desktop
state uses pixels horizontally and text rows vertically, so normalize the
vertical component against the originating window's actual frame line height
at this boundary."
  (let* ((delta (plist-get gesture :delta))
         (window (plist-get gesture :window))
         (line-height
          (when (window-live-p window)
            (max 1 (frame-char-height (window-frame window))))))
    (cons (round (or (car delta) 0))
          (round (/ (float (or (cdr delta) 0)) (or line-height 1))))))

(defun etaf-desktop--move-behavior (desktop id)
  "Construct a controlled move Behavior for window ID in DESKTOP."
  (etaf-draggable-controlled
   (lambda ()
     (let ((state (etaf-desktop-window-state desktop id)))
       (list :x (plist-get state :x) :y (plist-get state :y))))
   (lambda (next)
     (etaf-desktop-move-window desktop id
                              (plist-get next :x)
                              (plist-get next :y)))
   :axis 'both :delta #'etaf-desktop--delta
   :on-start (lambda (_gesture)
               (etaf-desktop-focus-window desktop id))))

(defun etaf-desktop--resize-behavior (desktop id edge)
  "Construct a controlled resize Behavior for window ID on EDGE."
  (let ((state (etaf-desktop-window-state desktop id))
        (edges (pcase edge
                 ('top-left '(left top))
                 ('top-right '(right top))
                 ('bottom-left '(left bottom))
                 ('bottom-right '(right bottom))
                 (_ (list edge)))))
    (etaf-resizable-controlled
     (lambda ()
       (let ((current (etaf-desktop-window-state desktop id)))
         (list :x (plist-get current :x)
               :y (plist-get current :y)
               :width (plist-get current :width)
               :height (plist-get current :height))))
     (lambda (next)
       (etaf-desktop--set-window-geometry
        desktop id (plist-get next :x) (plist-get next :y)
        (plist-get next :width) (plist-get next :height)))
     :edges edges :delta #'etaf-desktop--delta
     :min-width (plist-get state :min-width)
     :max-width (plist-get state :max-width)
     :min-height (plist-get state :min-height)
     :max-height (plist-get state :max-height)
     :on-start (lambda (_gesture)
                 (etaf-desktop-focus-window desktop id)))))

(etaf-define-component etaf-desktop--window-surface (&key desktop id)
  "Own one window's gesture Behaviors for its retained Component lifetime."
  :bindings ((active (etaf-computed
                     (lambda ()
                       (equal id (etaf-desktop--state-active-window
                                  (etaf-desktop--state desktop))))))
             (move (etaf-desktop--move-behavior desktop id))
             (resize-left (etaf-desktop--resize-behavior desktop id 'left))
             (resize-right (etaf-desktop--resize-behavior desktop id 'right))
             (resize-top (etaf-desktop--resize-behavior desktop id 'top))
             (resize-bottom (etaf-desktop--resize-behavior desktop id 'bottom))
             (resize-top-left (etaf-desktop--resize-behavior desktop id 'top-left))
             (resize-top-right (etaf-desktop--resize-behavior desktop id 'top-right))
             (resize-bottom-left (etaf-desktop--resize-behavior desktop id 'bottom-left))
             (resize-bottom-right (etaf-desktop--resize-behavior desktop id 'bottom-right)))
  :render
  (when-let* ((window (etaf-desktop--window-for
                      (etaf-desktop--state desktop) id)))
    (etaf-desktop--window-shell desktop window active move
                                 resize-left resize-right resize-top resize-bottom
                                 resize-top-left resize-top-right
                                 resize-bottom-left resize-bottom-right)))

(defun etaf-desktop--window-node (desktop window)
  "Return the keyed retained Component for WINDOW in DESKTOP."
  (etaf-node 'etaf-desktop--window-surface
             (list :key (etaf-desktop--window-id window)
                   :desktop desktop :id (etaf-desktop--window-id window))
             nil))

(defun etaf-desktop--request-close-window (desktop id)
  "Close ID, optionally asking for confirmation from Desktop settings."
  (if (plist-get (etaf-desktop--settings desktop) :confirm-close)
      (when (etaf-confirm-dialog
             (format "Close the %s window?"
                     (or (plist-get (etaf-desktop-window-state desktop id) :title)
                         id)))
        (etaf-desktop-close-window desktop id))
    (etaf-desktop-close-window desktop id)))

(defun etaf-desktop--window-shell
    (desktop window active move resize-left resize-right resize-top resize-bottom
             resize-top-left resize-top-right resize-bottom-left resize-bottom-right)
  "Build WINDOW's ETAF UI shell with its retained geometry Behaviors.
MOVE, RESIZE-RIGHT and RESIZE-BOTTOM are owned by the window Component."
  (let* ((id (etaf-desktop--window-id window))
         (settings (etaf-desktop--settings desktop))
         (title (or (etaf-desktop--window-title window) (format "%s" id)))
         (body (or (etaf-desktop--window-view window)
                   (etaf-node 'text nil (list title))))
         (resize-enabled (plist-get settings :resize-enabled))
         (mode (cond ((etaf-desktop--window-minimized window) 'minimized)
                     ((etaf-desktop--window-maximized window) 'maximized)
                     (t 'normal)))
         (move (and (etaf-desktop--window-movable window) move))
         (resize-left (and resize-enabled (etaf-desktop--window-resizable window) resize-left))
         (resize-right (and resize-enabled (etaf-desktop--window-resizable window) resize-right))
         (resize-top (and resize-enabled (etaf-desktop--window-resizable window) resize-top))
         (resize-bottom (and resize-enabled (etaf-desktop--window-resizable window) resize-bottom))
         (resize-top-left (and resize-enabled (etaf-desktop--window-resizable window) resize-top-left))
         (resize-top-right (and resize-enabled (etaf-desktop--window-resizable window) resize-top-right))
         (resize-bottom-left (and resize-enabled (etaf-desktop--window-resizable window) resize-bottom-left))
         (resize-bottom-right (and resize-enabled (etaf-desktop--window-resizable window) resize-bottom-right)))
    (etaf-node
     'etaf-window
     (list :key id :id (format "%s" id) :ref (etaf-desktop--window-ref id)
           :chrome-ref (intern (format "etaf-desktop-chrome-%s" id))
           ;; macOS presentation: only the active window shows colored
           ;; traffic lights; every other window renders gray lights.
           :controls-active active
           :title title :mode mode :visible (etaf-desktop--window-visible window)
           :title-font-size (plist-get settings :title-font-size)
           :content-font-size (plist-get settings :content-font-size)
           :font-family (plist-get settings :font-family)
           :drag-lock-modifier (plist-get settings :drag-lock-modifier)
           :x (etaf-desktop--window-x-source window)
           :y (etaf-desktop--window-y-source window)
           :width (etaf-desktop--window-width-source window)
           :height (etaf-desktop--window-height-source window)
           :z-index (etaf-desktop--window-z-index-source window)
           :min-width (list 'px (etaf-desktop--window-min-width window))
           :min-height (list 'lh (etaf-desktop--window-min-height window))
           :max-width (and (etaf-desktop--window-max-width window)
                           (list 'px (etaf-desktop--window-max-width window)))
           :max-height (and (etaf-desktop--window-max-height window)
                            (list 'lh (etaf-desktop--window-max-height window)))
           :resizable (and (etaf-desktop--window-resizable window) resize-enabled)
           :resize-edges '(top right bottom left top-left top-right bottom-right bottom-left)
           :resize-refs
           (mapcar (lambda (edge)
                     (cons edge (intern (format "etaf-desktop-resize-%s-%s" id edge))))
                   '(top right bottom left top-left top-right bottom-right bottom-left))
           :move-use move
           :resize-use (delq nil
                             (list (and resize-left (cons 'left resize-left))
                                   (and resize-right (cons 'right resize-right))
                                   (and resize-top (cons 'top resize-top))
                                   (and resize-bottom (cons 'bottom resize-bottom))
                                   (and resize-top-left (cons 'top-left resize-top-left))
                                   (and resize-top-right (cons 'top-right resize-top-right))
                                   (and resize-bottom-left (cons 'bottom-left resize-bottom-left))
                                   (and resize-bottom-right (cons 'bottom-right resize-bottom-right))))
           :on-minimize (lambda () (etaf-desktop-minimize-window desktop id))
           :on-maximize (lambda () (etaf-desktop-maximize-window desktop id))
           :on-restore (lambda () (etaf-desktop-restore-window desktop id))
           :on-close (lambda () (etaf-desktop--request-close-window desktop id))
           :on-focus (lambda () (etaf-desktop-focus-window desktop id)))
     (list body))))

(defun etaf-desktop--taskbar-key (id grouping)
  "Return the taskbar key for window ID according to GROUPING."
  (let ((id (cond ((null id) "")
                  ((stringp id) id)
                  ((symbolp id) (symbol-name id))
                  (t (format "%s" id)))))
    (if (and (eq grouping 'application)
             (string-match "\\`\\([^/]+\\)/" id))
        (match-string 1 id)
      id)))

(defun etaf-desktop--taskbar-node (desktop state active)
  "Project STATE's taskbar membership with a live ACTIVE selection source."
  (let* ((settings (etaf-desktop--settings desktop))
         (accent-color (plist-get settings :accent-color))
         (grouping (plist-get settings :taskbar-grouping))
         (windows (cl-remove-if-not
                   (lambda (window)
                     (equal (etaf-desktop--window-workspace window)
                            (etaf-desktop--state-active-workspace state)))
                   (etaf-desktop--state-windows state)))
         (groups nil))
    (dolist (window windows)
      (let* ((key (etaf-desktop--taskbar-key
                   (etaf-desktop--window-id window) grouping))
             (entry (assoc key groups)))
        (if entry
            (setcdr entry (append (cdr entry) (list window)))
          (setq groups (append groups (list (cons key (list window))))))))
    (let ((items
           (mapcar
            (lambda (group)
              (let* ((key (car group))
                     (members (cdr group))
                     (first (car members))
                     (minimized (cl-every #'etaf-desktop--window-minimized members))
                     (label (if (eq grouping 'application)
                                (or (ignore-errors
                                      (plist-get (etaf-desktop-app key) :title))
                                    key)
                              (or (etaf-desktop--window-title first) key))))
                (list :key key
                      :ref (etaf-desktop--window-ref (format "taskbar-%s" key))
                      :label (format "%s" label)
                      :state (and minimized 'minimized)
                      :window-id (etaf-desktop--window-id first))))
            groups)))
    (etaf-node 'etaf-taskbar
               (list :items items
                     :accent-color accent-color
                     :active active
                     :on-select (lambda (id)
                                  (let ((target (or (plist-get
                                                     (cl-find id items :key (lambda (item)
                                                                            (plist-get item :key))
                                                                  :test #'equal)
                                                     :window-id)
                                                    id)))
                                    (etaf-desktop-focus-window desktop target)))
                     :on-launch (and (fboundp 'etaf-desktop-toggle-launcher)
                                     (lambda ()
                                       (etaf-desktop-toggle-launcher desktop))))
               nil))))

(defun etaf-desktop--workspace-node (desktop state status)
  "Project STATE's workspace controls with a live focused-window STATUS."
  (let ((accent-color (plist-get (etaf-desktop--settings desktop) :accent-color)))
    (etaf-node 'etaf-workspace-bar
               (list :workspaces (etaf-desktop--state-workspaces state)
                     :accent-color accent-color
                     :active (etaf-desktop--state-active-workspace state)
                     ;; The right side reports the focused application and the
                     ;; workspace's window-management mode, which the trailing
                     ;; control switches without leaving the desktop.
                     :status status
                     :layout-label
                     (if (eq (etaf-desktop-layout-mode desktop
                                                       (etaf-desktop--state-active-workspace state))
                             'tiling)
                         "Tiled" "Floating")
                     :layout-action
                     (lambda ()
                       (etaf-desktop-toggle-layout-mode
                        desktop (etaf-desktop--state-active-workspace state)))
                     :settings-label "Settings"
                     :settings-action
                     (lambda () (etaf-desktop-toggle-settings desktop))
                     :on-select
                     (lambda (workspace)
                       (etaf-desktop-switch-workspace desktop workspace)))
               nil)))

(defun etaf-desktop--splitter-ratio-change
    (desktop workspace path orientation ratio span gesture)
  "Apply one controlled SPLITTER GESTURE to a layout ratio.
The gesture remains an ETAF UI input fact; this application callback converts
its axis delta into the caller-owned layout tree ratio through the public
layout API."
  (when (memq (plist-get gesture :phase) '(move end))
    (let* ((delta (etaf-desktop--delta gesture))
           (offset (if (eq orientation 'horizontal)
                       (car delta) (cdr delta)))
           (next (max 0.1 (min 0.9 (+ ratio (/ (float offset)
                                                (max 1 span)))))))
      (when (fboundp 'etaf-desktop-layout-resize-split)
        (etaf-desktop-layout-resize-split desktop path next workspace)))))

(defun etaf-desktop--windows-max-z (state)
  "Return the highest z-index among STATE's windows, or zero."
  (let ((max-z 0))
    (dolist (window (etaf-desktop--state-windows state) max-z)
      (setq max-z (max max-z (or (etaf-desktop--window-z-index window) 0))))))

(defun etaf-desktop--splitter-overlays
    (desktop state tree workspace spacing x y width height &optional path)
  "Render all split dividers in TREE at their allocated canvas positions.
X, Y, WIDTH and HEIGHT bound this subtree.  The layout policy owns pane and
divider rectangles; ETAF UI owns only each divider's presentation and input."
  (when (and tree (eq (car tree) :split))
    (let* ((orientation (nth 1 tree))
           (ratio (nth 2 tree))
           (first (nth 3 tree))
           (second (nth 4 tree))
           (parts (etaf-desktop--layout-partition
                   state tree spacing x y width height))
           (first-rect (nth 0 parts))
           (divider-rect (nth 1 parts))
           (second-rect (nth 2 parts))
           (divider-x (nth 0 divider-rect))
           (divider-y (nth 1 divider-rect))
           (divider-width (nth 2 divider-rect))
           (divider-height (nth 3 divider-rect))
           (handle-width (if (eq orientation 'horizontal)
                             (min etaf-desktop--layout-divider-px divider-width)
                           divider-width))
           (handle-height (if (eq orientation 'vertical)
                              (min etaf-desktop--layout-divider-rows
                                   divider-height)
                            divider-height))
           (handle-x (+ divider-x
                        (floor (/ (- divider-width handle-width) 2))))
           (handle-y (+ divider-y
                        (floor (/ (- divider-height handle-height) 2))))
           (span (if (eq orientation 'horizontal)
                     (- width divider-width)
                   (- height divider-height)))
           (divider
            (when (and (> divider-width 0) (> divider-height 0))
              (etaf-node
               'etaf-splitter
               (list :key (format "desktop-splitter-%S" path)
                     :orientation orientation :ratio ratio
                     :class "etaf-desktop-layout-splitter"
                     :overlay t
                     :overlay-rect
                     (list :left (list 'px handle-x)
                           :top (list 'lh handle-y)
                           :width (list 'px handle-width)
                           :height (list 'lh handle-height))
                     :z-index (+ 1 (etaf-desktop--windows-max-z state))
                     :divider-content
                     (if (eq orientation 'horizontal)
                         (mapconcat (lambda (_row) " ")
                                    (number-sequence 1 handle-height) "\n")
                       (make-string
                        (max 1 (ceiling (/ (float handle-width)
                                           (max 1 (frame-char-width)))))
                        ?\s))
                     :on-change
                     (lambda (gesture)
                       (etaf-desktop--splitter-ratio-change
                        desktop workspace path orientation ratio span gesture)))
               nil))))
      (append
       (when divider (list divider))
       (etaf-desktop--splitter-overlays
        desktop state first workspace spacing
        (nth 0 first-rect) (nth 1 first-rect)
        (nth 2 first-rect) (nth 3 first-rect) (append path '(0)))
       (etaf-desktop--splitter-overlays
        desktop state second workspace spacing
        (nth 0 second-rect) (nth 1 second-rect)
        (nth 2 second-rect) (nth 3 second-rect) (append path '(1)))))))

(defun etaf-desktop--launcher-node (desktop)
  "Build the controlled application launcher for DESKTOP."
  (when (and (fboundp 'etaf-desktop-launcher-open-p)
             (etaf-desktop-launcher-open-p desktop))
    (let ((items
           (if (fboundp 'etaf-desktop-apps)
               (mapcar (lambda (app)
                         (list :key (plist-get app :id)
                               :ref (intern (format "etaf-desktop-launcher-%s"
                                                    (plist-get app :id)))
                               :label (or (plist-get app :title)
                                          (format "%s" (plist-get app :id)))
                               :description "ETAF application"))
                       (etaf-desktop-apps))
             nil)))
      (etaf-node 'etaf-launcher
                 (list :open (etaf-desktop--controller-launcher-ref desktop)
                       :items items
                       :on-select
                       (lambda (app-id)
                         (when (fboundp 'etaf-desktop-launch)
                           (etaf-desktop-launch desktop app-id))
                         (etaf-desktop-toggle-launcher desktop nil))
                       :on-close (lambda ()
                                   (etaf-desktop-toggle-launcher desktop nil)))
                 nil))))

(defun etaf-desktop--switcher-node (desktop state)
  "Build the controlled window switcher for DESKTOP and STATE."
  (when (and (fboundp 'etaf-desktop-switcher-open-p)
             (etaf-desktop-switcher-open-p desktop))
    (let ((items
           (mapcar (lambda (window)
                     (list :key (etaf-desktop--window-id window)
                           :ref (etaf-desktop--window-ref
                                 (format "switcher-%s"
                                         (etaf-desktop--window-id window)))
                           :label (or (etaf-desktop--window-title window)
                                      (format "%s" (etaf-desktop--window-id window)))
                           :state (when (equal (etaf-desktop--window-id window)
                                               (etaf-desktop--state-active-window state))
                                    'active)))
                   (etaf-desktop--state-windows state))))
      (etaf-node 'etaf-switcher
                 (list :open (etaf-desktop--controller-switcher-ref desktop)
                       :selected (etaf-desktop--state-active-window state)
                       :items items
                       :on-select (lambda (id)
                                    (etaf-desktop-focus-window desktop id)
                                    (etaf-desktop-toggle-switcher desktop nil))
                       :on-close (lambda ()
                                   (etaf-desktop-toggle-switcher desktop nil)))
                 nil))))

(defun etaf-desktop--theme-colors (desktop)
  "Return shell colors for DESKTOP's selected theme."
  (let* ((settings (etaf-desktop--settings desktop))
         (theme (plist-get settings :theme))
         (dark (if (eq theme 'system)
                   (eq (etaf-theme-current-mode) 'dark)
                 (eq theme 'dark)))
         (accent (plist-get settings :accent-color)))
    (if dark
        (list :shell-bg "#17202A" :shell-fg "#F8FAFC"
              :canvas-bg "#202B36" :canvas-fg "#F8FAFC"
              :canvas-border "#4B5D6D" :accent accent)
      (list :shell-bg "#CBD7E1" :shell-fg "#17202A"
            :canvas-bg "#EDF2F7" :canvas-fg "#17202A"
            :canvas-border "#D7E0E8" :accent accent))))

(defun etaf-desktop--settings-control (kind props paper ink)
  "Build a flat settings control of KIND with PROPS on PAPER in INK."
  (let ((style (list :border (list '(px 0) 'solid paper)
                     :background-color paper :color ink
                     :font-weight 'normal :padding '((lh 0) (ch 0)))))
    (while props
      (setq style (plist-put style (pop props) (pop props))))
    (etaf-node kind style nil)))

(etaf-define-component etaf-desktop--settings-panel (&key desktop)
  "Render a compact, sectioned settings form for DESKTOP."
  :bindings
  ((section (etaf-ref 'appearance))
   (palette
    (etaf-computed
     (lambda ()
       (let* ((mode (plist-get (etaf-desktop--settings desktop) :theme))
              (dark (eq (if (eq mode 'system) (etaf-theme-current-mode) mode) 'dark))
              (paper (if dark "#292724" "#FAF9F5"))
              (ink (if dark "#E7E3DA" "#35332E")))
         (list :ui-fg ink :ui-panel-fg ink :ui-panel-bg paper
               :ui-panel-border (if dark "#5A5349" "#D9D4CA")
               :ui-button-ghost-fg ink :ui-button-ghost-bg paper
               :ui-button-ghost-border paper))))))
  :setup (etaf-theme-provide palette)
  :render
  (when (etaf-desktop-settings-open-p desktop)
   (let* ((settings (etaf-desktop--settings desktop))
         (active (etaf-value section))
         (dark (if (eq (plist-get settings :theme) 'system)
                   (eq (etaf-theme-current-mode) 'dark)
                 (eq (plist-get settings :theme) 'dark)))
         (paper (if dark "#292724" "#FAF9F5"))
         (ink (if dark "#E7E3DA" "#35332E"))
         (muted (if dark "#AAA398" "#777267"))
         (selected (if dark "#44382F" "#EEE4D9"))
         (bindings (plist-get settings :keybindings))
         (fields
          (pcase active
            ('appearance
             '((etaf-select :theme "Theme" :options
                            ((system . "System") (light . "Light") (dark . "Dark")))
               (etaf-text-input :accent-color "Accent color")
               (etaf-text-input :font-family "Font family" :placeholder "Emacs default")
               (etaf-number-input :title-font-size "Title font size" :min 8 :max 32)
               (etaf-number-input :content-font-size "Content font size" :min 8 :max 32)))
            ('layout
             '((etaf-select :layout-mode "Window layout" :options
                            ((floating . "Floating") (tiling . "Tiling")
                             (master-stack . "Master and stack") (monocle . "Monocle")))
               (etaf-number-input :tile-outer-gap "Outer gap" :min 0 :max 4)
               (etaf-number-input :tile-inner-gap "Inner gap" :min 1 :max 4)))
            ('behavior
             '((etaf-select :drag-lock-modifier "Drag lock modifier" :options
                            ((shift . "Shift") (control . "Control")
                             (meta . "Meta") (super . "Super") (hyper . "Hyper")))
               (etaf-checkbox :resize-enabled "Allow window resizing")
               (etaf-checkbox :confirm-close "Confirm before closing")
               (etaf-select :taskbar-grouping "Taskbar grouping" :options
                            ((window . "Every window") (application . "By application")))))
            ('shortcuts
             (mapcar (lambda (entry)
                       (list 'etaf-text-input (car entry) (cdr entry)))
                     '((:focus-next . "Focus next") (:focus-previous . "Focus previous")
                       (:launcher . "Applications") (:switcher . "Window switcher")
                       (:settings . "Settings") (:toggle-layout . "Toggle layout")
                       (:split-window . "Split window") (:swap-window . "Swap windows")
                       (:maximize-window . "Maximize") (:restore-window . "Restore")
                       (:minimize-window . "Minimize") (:close-window . "Close window")))))))
    (etaf-node
     'etaf-dialog
     (list :open (etaf-desktop-settings-open-p desktop)
           :title "Desktop Settings" :width '(ch 64) :height '(lh 22) :compact t
           :close-label "Done" :backdrop nil
           :on-close (lambda () (etaf-desktop-close-settings desktop)))
     (list
      (etaf-node
       'column (list :width 'stretch :item-gap '(lh 1)
                     :padding '((lh 1) (ch 1)) :background-color paper :color ink)
       (list
        (etaf-node
         'row (list :item-gap '(ch 2))
         (mapcar
          (lambda (entry)
            (let ((key (car entry)))
              (etaf-desktop--settings-control
               'etaf-button
               (list :ref (intern (format "settings-tab-%s" key))
                     :label (cdr entry) :aria-label (cdr entry) :variant 'ghost
                     :background-color (if (eq active key) selected paper)
                     :font-weight (if (eq active key) 'bold 'normal)
                     :on-press (lambda () (etaf-set-value section key)))
               paper ink)))
          '((appearance . "Appearance") (layout . "Layout")
            (behavior . "Behavior") (shortcuts . "Shortcuts"))))
        (etaf-node 'etaf-label
                   (list :text (pcase active
                                 ('appearance "A comfortable place to work.")
                                 ('layout "Give tiled windows room to breathe.")
                                 ('behavior "Choose how your desktop responds.")
                                 (_ "Keys apply only while the desktop is active."))
                         :color muted) nil)
        (etaf-node
         'grid (list :width 'stretch
                     :grid-template-columns (if (eq active 'shortcuts)
                                                '((fr 1) (fr 1)) '((fr 1)))
                     :column-gap '(ch 2) :row-gap '(lh 1))
         (mapcar
          (lambda (field)
            (let* ((kind (nth 0 field)) (key (nth 1 field)) (label (nth 2 field))
                   (value (plist-get (if (eq active 'shortcuts) bindings settings) key)))
              (etaf-desktop--settings-control
               kind
               (append
                (list :key key :label label :aria-label label
                      (if (eq kind 'etaf-checkbox) :checked :value)
                      (if (eq kind 'etaf-text-input) (or value "") value)
                      :on-change
                      (lambda (next)
                        (if (eq active 'shortcuts)
                            (etaf-desktop--set-keybinding desktop key next)
                          (etaf-desktop-set-setting
                           desktop key (if (and (eq key :font-family)
                                               (string-empty-p next)) nil next)))))
                (nthcdr 3 field))
               paper ink))) fields))
        (etaf-node 'etaf-label
                   (list :text (if (eq active 'layout)
                                   "Gap units: character widths across, text rows down."
                                 "Changes are saved with your desktop session.")
                         :color muted) nil)
        (etaf-desktop--settings-control
         'etaf-button
         (list :label "Reset settings" :variant 'ghost :aria-label "Reset settings"
               :on-press (lambda () (etaf-desktop-reset-settings desktop)))
         paper muted))))))))

(defun etaf-desktop--settings-node (desktop)
  "Render DESKTOP's settings through its retained section controller."
  (etaf-node 'etaf-desktop--settings-panel (list :desktop desktop) nil))

(etaf-define-component etaf-desktop--workspace-surface (&key desktop)
  "Keep focus-dependent workspace controls independent of window membership."
  :bindings
  ((controller (etaf-prop 'desktop))
   (status
    (etaf-computed
     (lambda ()
       (let* ((state (etaf-desktop--state (etaf-value controller)))
              (id (etaf-desktop--state-active-window state))
              (window (and id (etaf-desktop--window-for state id))))
         (when window
           (or (etaf-desktop--window-title window) (format "%s" id)))))
     :test #'equal)))
  :render
  (etaf-desktop--workspace-node desktop (etaf-desktop--state desktop) status))

(etaf-define-component etaf-desktop--taskbar-surface (&key desktop)
  "Project taskbar selection independently of the desktop canvas."
  :bindings
  ((controller (etaf-prop 'desktop))
   (active
    (etaf-computed
     (lambda ()
       (let ((desktop (etaf-value controller)))
         (etaf-desktop--taskbar-key
          (etaf-desktop--state-active-window (etaf-desktop--state desktop))
          (plist-get (etaf-value (etaf-desktop--controller-settings-ref desktop))
                     :taskbar-grouping))))
     :test #'equal)))
  :render
  (etaf-desktop--taskbar-node desktop (etaf-desktop--state desktop) active))

(etaf-define-component etaf-desktop--switcher-surface (&key desktop)
  "Project switcher focus only while the switcher is visible."
  :render (etaf-desktop--switcher-node desktop (etaf-desktop--state desktop)))

(etaf-define-component etaf-desktop--application (&key desktop)
  "Render DESKTOP as a controlled desktop surface."
  :setup
  (progn
    ;; Playground mounts the public View directly instead of calling
    ;; `etaf-desktop-mount'; keep the buffer-local shortcut lifecycle at the
    ;; Desktop Component boundary so both consumers behave identically.
    (etaf-on-mounted
     (lambda ()
       ;; Record the owning Runtime for direct View consumers.  Event callbacks
       ;; may run with a different current buffer, so use ETAF's lifecycle
       ;; context rather than relying on `current-buffer'.
       (when-let* ((runtime (etaf-current-runtime)))
         (setf (etaf-desktop--controller-runtime desktop) runtime
               (etaf-desktop--controller-buffer desktop)
               (etaf-runtime-buffer runtime)
               (etaf-desktop--controller-owns-runtime-p desktop) nil
               (etaf-desktop--controller-owns-buffer-p desktop) nil))
       (etaf-desktop--refresh-buffer-keymap
        desktop (etaf-desktop--lifecycle-buffer desktop))))
    (etaf-on-unmounted
     (lambda ()
       (etaf-desktop--clear-buffer-keymap
        desktop (etaf-desktop--lifecycle-buffer desktop))
       (when (eq (etaf-desktop--controller-runtime desktop)
                 (etaf-current-runtime))
         (setf (etaf-desktop--controller-runtime desktop) nil
               (etaf-desktop--controller-buffer desktop) nil
               (etaf-desktop--controller-owns-runtime-p desktop) nil
               (etaf-desktop--controller-owns-buffer-p desktop) nil))))
    nil)
  :render
  (let* ((state (etaf-desktop--state desktop))
         (colors (etaf-desktop--theme-colors desktop))
         (workspace (etaf-desktop--state-active-workspace state))
         (layout-mode (when (fboundp 'etaf-desktop-layout-mode)
                        (etaf-desktop-layout-mode desktop workspace)))
         (layout-tree (when (and layout-mode
                                 (memq layout-mode '(tiling master-stack monocle)))
                        (etaf-desktop-layout-tree desktop workspace)))
         (windows
          (cl-remove-if-not
                 (lambda (window)
                   ;; Keep minimized windows in the retained Component tree so
                   ;; their child state survives; `etaf-window' projects the
                   ;; controlled hidden/minimized presentation.
                   (equal (etaf-desktop--window-workspace window) workspace))
                 (etaf-desktop--state-windows state))))
    (etaf-node
     'column
     ;; The shell width fits the render viewport when one exists: the concrete
     ;; pixel canvas in `etaf-desktop--canvas-width-value' only measures
     ;; application geometry, so no pixel rounding can push a shell row into
     ;; Emacs continuation.  The row count stays explicit so headless renders
     ;; keep canvas-height rows between the workspace bar and the taskbar.
     (list :width (etaf-desktop--canvas-box-width desktop)
           :height (list 'lh (+ (etaf-desktop--canvas-height-value desktop) 2))
           :background-color (plist-get colors :shell-bg)
           :color (plist-get colors :shell-fg))
     (list
      (etaf-node 'etaf-desktop--workspace-surface (list :desktop desktop) nil)
      (etaf-node
       'box
       (list :position 'relative
             :width (etaf-desktop--canvas-box-width desktop)
             :height (list 'lh (etaf-desktop--canvas-height-value desktop))
             :background-color (plist-get colors :canvas-bg)
             :color (plist-get colors :canvas-fg)
             :border (list '(px 1) 'solid (plist-get colors :canvas-border)))
       (append
        (mapcar (lambda (window) (etaf-desktop--window-node desktop window)) windows)
        ;; Tiling dividers are canvas overlays: they must be positioned in
        ;; canvas coordinates and painted after the windows they separate.
        (when layout-tree
          (let* ((spacing (etaf-desktop--layout-spacing desktop))
                 (canvas-rect
                  (etaf-desktop--layout-canvas-rect
                   desktop state layout-tree spacing layout-mode)))
            (apply #'etaf-desktop--splitter-overlays
                   desktop state layout-tree workspace spacing
                   canvas-rect)))))
      (etaf-node 'etaf-desktop--taskbar-surface (list :desktop desktop) nil)
      (etaf-desktop--launcher-node desktop)
      (etaf-node 'etaf-desktop--switcher-surface (list :desktop desktop) nil)
      (etaf-desktop--settings-node desktop)))))

(cl-defun etaf-desktop-create
    (&key (name "*ETAF Desktop*") canvas-width canvas-height
          (workspaces '(main)))
  "Create an application desktop with CANVAS-WIDTH and CANVAS-HEIGHT.
WORKSPACES is a nonempty list of stable workspace keys.  The returned desktop
owns its reactive state and does not mount a buffer until `etaf-desktop-mount'."
  (unless (and (stringp name) (not (string-empty-p name)))
    (etaf-desktop--fail "Desktop name must be a nonempty string"))
  (when canvas-width (etaf-desktop--number canvas-width "canvas-width" 1))
  (when canvas-height (etaf-desktop--number canvas-height "canvas-height" 8))
  (unless (and (listp workspaces) workspaces
               (not (cl-some #'null workspaces))
               (= (length workspaces) (length (delete-dups (copy-sequence workspaces)))))
    (etaf-desktop--fail "Workspaces must be a nonempty list of unique keys"))
  (let ((controller
         (etaf-desktop--controller-create
          :name name :canvas-width canvas-width :canvas-height canvas-height
          :state-ref nil)))
    (setf (etaf-desktop--controller-state-ref controller)
          (etaf-ref
           (etaf-desktop--state-create
            :windows nil :workspaces (copy-sequence workspaces)
           :active-workspace (car workspaces)
            :active-window-source (etaf-ref nil :name 'etaf-desktop-focus) :next-z 1)
           :name 'etaf-desktop-state)
          (etaf-desktop--controller-launcher-ref controller)
          (etaf-ref nil :name 'etaf-desktop-launcher-open)
          (etaf-desktop--controller-switcher-ref controller)
          (etaf-ref nil :name 'etaf-desktop-switcher-open)
          (etaf-desktop--controller-settings-ref controller)
          (etaf-ref (etaf-desktop--default-settings)
                    :name 'etaf-desktop-settings)
          (etaf-desktop--controller-settings-open-ref controller)
          (etaf-ref nil :name 'etaf-desktop-settings-open))
    controller))

(defun etaf-desktop-launcher-open-p (desktop)
  "Return non-nil when DESKTOP's application launcher is open."
  (etaf-value (etaf-desktop--controller-launcher-ref
               (etaf-desktop--controller desktop))))

(defun etaf-desktop-toggle-launcher (desktop &optional open)
  "Set DESKTOP's launcher visibility to OPEN and return its new value.
When OPEN is nil, toggle the current value unless an explicit nil is needed;
callers can use `etaf-desktop-close-launcher' to close it unambiguously."
  (let* ((desktop (etaf-desktop--controller desktop))
         (ref (etaf-desktop--controller-launcher-ref desktop))
         (value (if (null open) (not (etaf-value ref)) open)))
    (etaf-set-value ref value)
    value))

(defun etaf-desktop-close-launcher (desktop)
  "Close DESKTOP's application launcher and return nil."
  (let ((desktop (etaf-desktop--controller desktop)))
    (etaf-set-value (etaf-desktop--controller-launcher-ref desktop) nil)
    nil))

(defun etaf-desktop-switcher-open-p (desktop)
  "Return non-nil when DESKTOP's window switcher is open."
  (etaf-value (etaf-desktop--controller-switcher-ref
               (etaf-desktop--controller desktop))))

(defun etaf-desktop-toggle-switcher (desktop &optional open)
  "Set DESKTOP's switcher visibility to OPEN, or toggle it when omitted."
  (let* ((desktop (etaf-desktop--controller desktop))
         (ref (etaf-desktop--controller-switcher-ref desktop))
         (value (if (null open) (not (etaf-value ref)) open)))
    (etaf-set-value ref value)
    value))

(defun etaf-desktop-close-switcher (desktop)
  "Close DESKTOP's window switcher and return nil."
  (let ((desktop (etaf-desktop--controller desktop)))
    (etaf-set-value (etaf-desktop--controller-switcher-ref desktop) nil)
    nil))

(defun etaf-desktop-state (desktop)
  "Return DESKTOP's detached state plist, including windows and workspaces."
  (let ((desktop (etaf-desktop--controller desktop))
        (state (etaf-desktop--state desktop)))
    (list :name (etaf-desktop--controller-name desktop)
          :canvas-width (etaf-desktop--canvas-width-value desktop)
          :canvas-height (etaf-desktop--canvas-height-value desktop)
          :settings (etaf-desktop-settings desktop)
          :active-workspace (etaf-desktop--state-active-workspace state)
          :active-window (etaf-desktop--state-active-window state)
          :workspaces (copy-sequence (etaf-desktop--state-workspaces state))
          :windows (mapcar #'etaf-desktop--window-plist
                           (etaf-desktop--state-windows state)))))

(defun etaf-desktop-windows (desktop)
  "Return DESKTOP's windows as detached plists in z-order insertion order."
  (plist-get (etaf-desktop-state desktop) :windows))

(defun etaf-desktop-window-state (desktop id)
  "Return a detached state plist for window ID in DESKTOP."
  (let ((window (etaf-desktop--window-for (etaf-desktop--state (etaf-desktop--controller desktop)) id)))
    (or (and window (etaf-desktop--window-plist window))
        (etaf-desktop--fail "Unknown desktop window: %S" id))))

(defun etaf-desktop-active-window (desktop)
  "Return the active window ID of DESKTOP, or nil."
  (etaf-desktop--state-active-window
   (etaf-desktop--state (etaf-desktop--controller desktop))))

(defun etaf-desktop-active-workspace (desktop)
  "Return DESKTOP's active workspace key."
  (etaf-desktop--state-active-workspace
   (etaf-desktop--state (etaf-desktop--controller desktop))))

(cl-defun etaf-desktop-open-window
    (desktop id &key title view (x 0) (y 0) (width 400) (height 12)
          (min-width 160) (min-height 3) max-width max-height workspace
          (visible t) (movable t) (resizable t))
  "Open window ID in DESKTOP and return its public state plist.
VIEW is an ETAF View created by `etaf-view' or nil for a text placeholder.
Geometry and size limits are logical desktop units; callers retain VIEW.
WORKSPACE defaults to the active workspace."
  (let ((desktop (etaf-desktop--controller desktop)))
    (etaf-desktop--number x "x" 0)
    (etaf-desktop--number y "y" 0)
    (etaf-desktop--number width "width" min-width)
    (etaf-desktop--number height "height" min-height)
    (etaf-desktop--number min-width "min-width" 1)
    (etaf-desktop--number min-height "min-height" 1)
    (when max-width (etaf-desktop--number max-width "max-width" min-width))
    (when max-height (etaf-desktop--number max-height "max-height" min-height))
    (etaf-desktop--update
     desktop
     (lambda (state)
       (when (etaf-desktop--window-for state id)
         (etaf-desktop--fail "Desktop window already exists: %S" id))
       (let ((workspace (or workspace (etaf-desktop--state-active-workspace state))))
         (etaf-desktop--assert-workspace state workspace)
         (let ((window
                (etaf-desktop--window-create
                 :id id :title title :view view :x-source x :y-source y
                 :width-source width :height-source height
                 :min-width min-width :min-height min-height :max-width max-width
                 :max-height max-height :visible visible :minimized nil
                 :maximized nil :workspace workspace
                 :normal-geometry (list x y width height)
                 :z-index-source (etaf-desktop--state-next-z state)
                 :movable movable :resizable resizable)))
           (push window (etaf-desktop--state-windows state))
           (setf (etaf-desktop--state-next-z state)
                 (1+ (etaf-desktop--state-next-z state)))
           (etaf-desktop--raise state window)
           (etaf-desktop--window-plist window)))))))

(defun etaf-desktop--highest-visible-window (state workspace)
  "Return the highest visible, non-minimized window in WORKSPACE."
  (car
   (sort
    (cl-remove-if-not
     (lambda (candidate)
       (and (equal workspace (etaf-desktop--window-workspace candidate))
            (etaf-desktop--window-visible candidate)
            (not (etaf-desktop--window-minimized candidate))))
     (copy-sequence (etaf-desktop--state-windows state)))
    (lambda (left right)
      (> (etaf-desktop--window-z-index left)
         (etaf-desktop--window-z-index right))))))

(defun etaf-desktop-close-window (desktop id)
  "Close window ID in DESKTOP and return non-nil when it existed.

When the active window is removed, the highest visible window in the same
workspace becomes active so closing a window never leaves the desktop without
a focused target while other windows remain available."
  (let* ((desktop (etaf-desktop--controller desktop))
         (was-active (equal id (etaf-desktop-active-window desktop)))
         (result
          (etaf-desktop--update
           desktop
           (lambda (state)
             (let ((window (etaf-desktop--window-for state id)))
               (if (not window)
                   nil
                 (let ((workspace (etaf-desktop--window-workspace window))
                       (was-active
                        (equal id (etaf-desktop--state-active-window state))))
                   (setf (etaf-desktop--state-windows state)
                         (delq window (etaf-desktop--state-windows state)))
                   (when was-active
                     (let ((replacement
                            (etaf-desktop--highest-visible-window state workspace)))
                       (setf (etaf-desktop--state-active-window state)
                             (and replacement
                                  (etaf-desktop--window-id replacement)))))
                   t)))))))
    (when result
      (etaf-desktop--notify-window-event desktop id 'closed)
      (when was-active
        (if-let* ((replacement-id (etaf-desktop-active-window desktop)))
            (etaf-desktop--notify-window-event desktop replacement-id 'focused)
          (etaf-desktop--notify-window-event desktop nil 'focus-cleared))))
    result))

(defun etaf-desktop-focus-window (desktop id)
  "Focus and raise window ID, switching to its workspace."
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--state desktop))
         (window (etaf-desktop--window-for state id))
         (result
          (if (and window
                   (etaf-desktop--floating-window-p desktop state window)
                   (etaf-desktop--window-visible window)
                   (not (etaf-desktop--window-minimized window)))
              (etaf-call-with-batch (etaf-desktop--window-focus-writer window))
            (etaf-desktop--update
             desktop
             (lambda (state)
               (let ((window (etaf-desktop--window-for state id)))
                 (unless window (etaf-desktop--fail "Unknown desktop window: %S" id))
                 (setf (etaf-desktop--window-minimized window) nil
                       (etaf-desktop--window-visible window) t)
                 (etaf-desktop--raise state window)
                 id))))))
    (etaf-desktop--notify-window-event desktop id 'focused)
    result))

(defun etaf-desktop-move-window (desktop id x y)
  "Move window ID to X and Y, returning its public state plist."
  (etaf-desktop--number x "x" 0)
  (etaf-desktop--number y "y" 0)
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--state desktop))
         (window (etaf-desktop--window-for state id)))
    (unless window (etaf-desktop--fail "Unknown desktop window: %S" id))
    (if (etaf-desktop--floating-window-p desktop state window)
        (etaf-desktop--write-geometry
         window x y (etaf-desktop--window-width window)
         (etaf-desktop--window-height window))
      (etaf-desktop--update
       desktop
       (lambda (state)
         (let ((window (etaf-desktop--window-for state id)))
           (unless window (etaf-desktop--fail "Unknown desktop window: %S" id))
           (when (etaf-desktop--window-maximized window)
             (setf (etaf-desktop--window-x window) (nth 0 (etaf-desktop--window-normal-geometry window))
                   (etaf-desktop--window-y window) (nth 1 (etaf-desktop--window-normal-geometry window))
                   (etaf-desktop--window-width window) (nth 2 (etaf-desktop--window-normal-geometry window))
                   (etaf-desktop--window-height window) (nth 3 (etaf-desktop--window-normal-geometry window))
                   (etaf-desktop--window-maximized window) nil))
           (setf (etaf-desktop--window-x window) x
                 (etaf-desktop--window-y window) y
                 (etaf-desktop--window-normal-geometry window)
                 (list x y (etaf-desktop--window-width window) (etaf-desktop--window-height window)))
           (etaf-desktop--raise state window)
           (etaf-desktop--window-plist window)))))))

(defun etaf-desktop--set-window-geometry (desktop id x y width height)
  "Commit one atomic geometry update for window ID.
X, Y, WIDTH and HEIGHT are logical desktop units.  This internal path is used
by combined edge and corner resize Behaviors so a left/top resize publishes
its position and size together." 
  ;; Preserve the opposite edge when a left/top drag crosses the origin.
  ;; Clamping only X or Y would grow the window past that fixed edge.
  (when (< x 0)
    (setq width (+ width x)
          x 0))
  (when (< y 0)
    (setq height (+ height y)
          y 0))
  (etaf-desktop--number x "x" 0)
  (etaf-desktop--number y "y" 0)
  (etaf-desktop--number width "width" 1)
  (etaf-desktop--number height "height" 1)
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--state desktop))
         (window (etaf-desktop--window-for state id)))
    (unless window (etaf-desktop--fail "Unknown desktop window: %S" id))
    (unless (etaf-desktop--window-resizable window)
      (etaf-desktop--fail "Desktop window is not resizable: %S" id))
    (if (etaf-desktop--floating-window-p desktop state window)
        (etaf-desktop--write-geometry
         window x y
         (etaf-desktop--clamp width (etaf-desktop--window-min-width window)
                              (etaf-desktop--window-max-width window))
         (etaf-desktop--clamp height (etaf-desktop--window-min-height window)
                              (etaf-desktop--window-max-height window)))
      (etaf-desktop--update
       desktop
       (lambda (state)
         (let ((window (etaf-desktop--window-for state id)))
           (unless window (etaf-desktop--fail "Unknown desktop window: %S" id))
           (unless (etaf-desktop--window-resizable window)
             (etaf-desktop--fail "Desktop window is not resizable: %S" id))
           (when (etaf-desktop--window-maximized window)
             (setf (etaf-desktop--window-maximized window) nil))
           (setq width (etaf-desktop--clamp width
                                            (etaf-desktop--window-min-width window)
                                            (etaf-desktop--window-max-width window))
                 height (etaf-desktop--clamp height
                                             (etaf-desktop--window-min-height window)
                                             (etaf-desktop--window-max-height window)))
           (setf (etaf-desktop--window-x window) x
                 (etaf-desktop--window-y window) y
                 (etaf-desktop--window-width window) width
                 (etaf-desktop--window-height window) height
                 (etaf-desktop--window-normal-geometry window)
                 (list x y width height))
           (etaf-desktop--raise state window)
           (etaf-desktop--window-plist window)))))))

(defun etaf-desktop-resize-window (desktop id width height)
  "Resize window ID to WIDTH and HEIGHT, respecting its size limits."
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--state desktop))
         (window (etaf-desktop--window-for state id)))
    (unless window (etaf-desktop--fail "Unknown desktop window: %S" id))
    (unless (etaf-desktop--window-resizable window)
      (etaf-desktop--fail "Desktop window is not resizable: %S" id))
    (if (etaf-desktop--floating-window-p desktop state window)
        (etaf-desktop--write-geometry
         window (etaf-desktop--window-x window)
         (etaf-desktop--window-y window)
         (etaf-desktop--clamp width (etaf-desktop--window-min-width window)
                              (etaf-desktop--window-max-width window))
         (etaf-desktop--clamp height (etaf-desktop--window-min-height window)
                              (etaf-desktop--window-max-height window)))
      (etaf-desktop--update
       desktop
       (lambda (state)
         (let ((window (etaf-desktop--window-for state id)))
           (unless window (etaf-desktop--fail "Unknown desktop window: %S" id))
           (unless (etaf-desktop--window-resizable window)
             (etaf-desktop--fail "Desktop window is not resizable: %S" id))
           (when (etaf-desktop--window-maximized window)
             (setf (etaf-desktop--window-x window) (nth 0 (etaf-desktop--window-normal-geometry window))
                   (etaf-desktop--window-y window) (nth 1 (etaf-desktop--window-normal-geometry window))
                   (etaf-desktop--window-width window) (nth 2 (etaf-desktop--window-normal-geometry window))
                   (etaf-desktop--window-height window) (nth 3 (etaf-desktop--window-normal-geometry window))
                   (etaf-desktop--window-maximized window) nil))
           (setf width (etaf-desktop--clamp width (etaf-desktop--window-min-width window)
                                            (etaf-desktop--window-max-width window))
                 height (etaf-desktop--clamp height (etaf-desktop--window-min-height window)
                                             (etaf-desktop--window-max-height window))
                 (etaf-desktop--window-width window) width
                 (etaf-desktop--window-height window) height
                 (etaf-desktop--window-normal-geometry window)
                 (list (etaf-desktop--window-x window) (etaf-desktop--window-y window)
                       width height))
           (etaf-desktop--raise state window)
           (etaf-desktop--window-plist window)))))))

(defun etaf-desktop-maximize-window (desktop id)
  "Maximize window ID to DESKTOP's canvas and remember its geometry."
  (etaf-desktop--update
   desktop
   (lambda (state)
     (let ((window (etaf-desktop--window-for state id)))
       (unless window (etaf-desktop--fail "Unknown desktop window: %S" id))
       (unless (etaf-desktop--window-maximized window)
         (setf (etaf-desktop--window-normal-geometry window)
               (etaf-desktop--geometry window)))
       (setf (etaf-desktop--window-x window) 0
             (etaf-desktop--window-y window) 0
             (etaf-desktop--window-width window)
             (etaf-desktop--canvas-width-value desktop)
             (etaf-desktop--window-height window)
             (etaf-desktop--canvas-height-value desktop)
             (etaf-desktop--window-minimized window) nil
             (etaf-desktop--window-visible window) t
             (etaf-desktop--window-maximized window) t)
       (etaf-desktop--raise state window)
       (etaf-desktop--window-plist window)))))

(defun etaf-desktop-minimize-window (desktop id)
  "Minimize window ID into DESKTOP's taskbar."
  (let* ((desktop (etaf-desktop--controller desktop))
         (was-active (equal id (etaf-desktop-active-window desktop)))
         (result
         (etaf-desktop--update
          desktop
          (lambda (state)
            (let ((window (etaf-desktop--window-for state id)))
              (unless window (etaf-desktop--fail "Unknown desktop window: %S" id))
              (setf (etaf-desktop--window-minimized window) t
                    (etaf-desktop--window-visible window) nil)
              (when (equal id (etaf-desktop--state-active-window state))
                (let ((replacement
                       (etaf-desktop--highest-visible-window
                        state (etaf-desktop--window-workspace window))))
                  (setf (etaf-desktop--state-active-window state)
                        (and replacement
                             (etaf-desktop--window-id replacement)))))
              (etaf-desktop--window-plist window))))))
    (etaf-desktop--notify-window-event desktop id 'minimized)
    (when was-active
      (if-let* ((replacement-id (etaf-desktop-active-window desktop)))
          (etaf-desktop--notify-window-event desktop replacement-id 'focused)
        (etaf-desktop--notify-window-event desktop nil 'focus-cleared)))
    result))

(defun etaf-desktop-restore-window (desktop id)
  "Restore minimized or maximized window ID and focus it."
  (let ((result
         (etaf-desktop--update
          desktop
          (lambda (state)
            (let ((window (etaf-desktop--window-for state id)))
              (unless window (etaf-desktop--fail "Unknown desktop window: %S" id))
              (when (etaf-desktop--window-maximized window)
                (pcase-let ((`(,x ,y ,width ,height)
                             (etaf-desktop--window-normal-geometry window)))
                  (setf (etaf-desktop--window-x window) x
                        (etaf-desktop--window-y window) y
                        (etaf-desktop--window-width window) width
                        (etaf-desktop--window-height window) height)))
              (setf (etaf-desktop--window-maximized window) nil
                    (etaf-desktop--window-minimized window) nil
                    (etaf-desktop--window-visible window) t)
              (etaf-desktop--raise state window)
              (etaf-desktop--window-plist window))))))
    (etaf-desktop--notify-window-event desktop id 'restored)
    result))

(defun etaf-desktop-window-maximized-p (desktop id)
  "Return non-nil when window ID is maximized."
  (etaf-desktop--window-maximized
   (or (etaf-desktop--window-for (etaf-desktop--state desktop) id)
       (etaf-desktop--fail "Unknown desktop window: %S" id))))

(defun etaf-desktop-switch-workspace (desktop workspace)
  "Make WORKSPACE the active desktop workspace."
  (let* ((desktop (etaf-desktop--controller desktop))
         (result
          (etaf-desktop--update
           desktop
           (lambda (state)
             (etaf-desktop--assert-workspace state workspace)
             (let ((windows (cl-remove-if-not
                             (lambda (window)
                               (and (equal (etaf-desktop--window-workspace window) workspace)
                                    (etaf-desktop--window-visible window)
                                    (not (etaf-desktop--window-minimized window))))
                             (copy-sequence (etaf-desktop--state-windows state)))))
               (setq windows (sort windows (lambda (a b)
                                            (> (etaf-desktop--window-z-index a)
                                               (etaf-desktop--window-z-index b)))))
               (setf (etaf-desktop--state-active-workspace state) workspace
                     (etaf-desktop--state-active-window state)
                     (and windows (etaf-desktop--window-id (car windows)))))
             workspace))))
    (when-let* ((active (etaf-desktop-active-window desktop)))
      (etaf-desktop--notify-window-event desktop active 'focused))
    (unless (etaf-desktop-active-window desktop)
      (etaf-desktop--notify-window-event desktop nil 'focus-cleared))
    result))

(defun etaf-desktop-add-workspace (desktop workspace)
  "Add WORKSPACE to DESKTOP and return its key."
  (etaf-desktop--update
   desktop
   (lambda (state)
     (when (or (null workspace) (etaf-desktop--workspace-present-p state workspace))
       (etaf-desktop--fail "Workspace already exists or is nil: %S" workspace))
     (setf (etaf-desktop--state-workspaces state)
           (append (etaf-desktop--state-workspaces state) (list workspace)))
     workspace)))

(defun etaf-desktop-remove-workspace (desktop workspace)
  "Remove WORKSPACE, moving its windows to another remaining workspace."
  (let* ((desktop (etaf-desktop--controller desktop))
         (was-active (equal workspace (etaf-desktop-active-workspace desktop)))
         (result
          (etaf-desktop--update
           desktop
           (lambda (state)
             (when (= (length (etaf-desktop--state-workspaces state)) 1)
               (etaf-desktop--fail "Cannot remove the last desktop workspace"))
             (etaf-desktop--assert-workspace state workspace)
             (let ((replacement
                    (car (delete workspace
                                 (copy-sequence
                                  (etaf-desktop--state-workspaces state))))))
               (dolist (window (etaf-desktop--state-windows state))
                 (when (equal (etaf-desktop--window-workspace window) workspace)
                   (setf (etaf-desktop--window-workspace window) replacement)))
               (setf (etaf-desktop--state-workspaces state)
                     (delete workspace (etaf-desktop--state-workspaces state)))
               (when (equal workspace (etaf-desktop--state-active-workspace state))
                 (let ((replacement-window
                        (etaf-desktop--highest-visible-window state replacement)))
                   (setf (etaf-desktop--state-active-workspace state) replacement
                         (etaf-desktop--state-active-window state)
                         (and replacement-window
                              (etaf-desktop--window-id replacement-window)))))
               replacement)))))
    (when was-active
      (if-let* ((replacement-id (etaf-desktop-active-window desktop)))
          (etaf-desktop--notify-window-event desktop replacement-id 'focused)
        (etaf-desktop--notify-window-event desktop nil 'focus-cleared)))
    result))

(defun etaf-desktop-view (desktop)
  "Return the root View for DESKTOP without mounting it."
  (etaf-desktop--controller desktop)
  (etaf-view (etaf-desktop--application :desktop desktop)))

(defun etaf-desktop-mount (desktop &optional buffer-or-name)
  "Mount DESKTOP into BUFFER-OR-NAME and return the buffer.
When BUFFER-OR-NAME is nil, DESKTOP's configured name is used.  A desktop
without explicit canvas dimensions measures the window that will display it,
so it fills the visible Emacs window body.  A desktop can be mounted once;
callers use `etaf-desktop-close' to release the Runtime."
  (let* ((desktop (etaf-desktop--controller desktop))
         (name (or buffer-or-name (etaf-desktop--controller-name desktop)))
         (target (get-buffer name)))
    (when (etaf-desktop--controller-runtime desktop)
      (etaf-desktop--fail "Desktop is already mounted"))
    ;; A desktop without explicit dimensions fills the window that displays
    ;; it.  The first render happens inside `etaf-mount', before the mounted
    ;; buffer is recorded, so measure the target window for that render and
    ;; re-apply the layout once the display settles.
    (let* ((mount-target (or target (get-buffer-create name)))
           (mount-window (get-buffer-window mount-target))
           (old-mode-line (buffer-local-value 'mode-line-format mount-target))
           (old-header-line (buffer-local-value 'header-line-format mount-target))
           ;; Window measurements must already describe the chrome-free
           ;; Desktop before its first View is evaluated.  Otherwise the first
           ;; state update grows the canvas by the retired mode-line row.
           (_ (with-current-buffer mount-target
                (setq-local mode-line-format nil header-line-format nil)))
           (buffer (condition-case error-data
                       (let ((etaf-desktop--mount-window mount-window))
                         (etaf-mount mount-target (etaf-desktop-view desktop)))
                     (error
                      (with-current-buffer mount-target
                        (setq-local mode-line-format old-mode-line
                                    header-line-format old-header-line))
                      (unless target (kill-buffer mount-target))
                      (signal (car error-data) (cdr error-data)))))
           (runtime (etaf-runtime-for-buffer buffer)))
      ;; The mounted desktop owns the complete Emacs window body.  Hiding the
      ;; buffer mode line avoids an extra application-looking row below the
      ;; taskbar; status and app actions are projected by the desktop shell.
      (with-current-buffer buffer
        (setq-local mode-line-format nil)
        (setq-local header-line-format nil))
      (setf (etaf-desktop--controller-buffer desktop) buffer
            (etaf-desktop--controller-runtime desktop) runtime
            (etaf-desktop--controller-owns-runtime-p desktop) t
            (etaf-desktop--controller-owns-buffer-p desktop) (not target))
      (etaf-desktop--refresh-buffer-keymap desktop)
      ;; Displaying a buffer can resize its window after the first render.
      ;; Re-apply the default layout so the shell matches the settled window.
      (when (and mount-window
                 (null (etaf-desktop--controller-canvas-width desktop))
                 (null (etaf-desktop--controller-canvas-height desktop)))
        (run-at-time
         0.2 nil
         (lambda ()
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (etaf-desktop-layout-refresh desktop))))))
      buffer)))

(defun etaf-desktop-close (desktop)
  "Release DESKTOP's mounted surface and return nil.
Only a Runtime created by `etaf-desktop-mount' is unmounted, and only a buffer
created by that call is killed.  Direct `etaf-desktop-view' consumers own their
Runtime and buffer.  Closing is idempotent."
  (let ((desktop (etaf-desktop--controller desktop))
        (runtime (etaf-desktop--controller-runtime desktop))
        (buffer (etaf-desktop--controller-buffer desktop))
        (owns-runtime (etaf-desktop--controller-owns-runtime-p desktop))
        (owns-buffer (etaf-desktop--controller-owns-buffer-p desktop)))
    (when owns-runtime
      (when runtime (etaf-unmount runtime))
      (when (and owns-buffer (buffer-live-p buffer))
        (kill-buffer buffer))
      (setf (etaf-desktop--controller-runtime desktop) nil
            (etaf-desktop--controller-buffer desktop) nil
            (etaf-desktop--controller-owns-runtime-p desktop) nil
            (etaf-desktop--controller-owns-buffer-p desktop) nil))
    nil))

(defun etaf-desktop-open (&optional desktop buffer-or-name)
  "Create and mount DESKTOP, returning the desktop controller.
When DESKTOP is nil, create a default desktop.  Interactive calls display its
buffer; applications may then use the window/workspace mutation APIs."
  (interactive)
  (let* ((desktop (or desktop (etaf-desktop-create)))
         (buffer (etaf-desktop-mount desktop buffer-or-name)))
    (when (called-interactively-p 'interactive) (pop-to-buffer buffer))
    desktop))

(provide 'etaf-desktop-runtime)
;;; etaf-desktop-runtime.el ends here
