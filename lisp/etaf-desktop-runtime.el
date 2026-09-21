;;; etaf-desktop-runtime.el --- Desktop application state and view -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)

(declare-function etaf-desktop-layout-mode "etaf-desktop-layout"
                  (desktop &optional workspace))
(declare-function etaf-desktop-layout-tree "etaf-desktop-layout"
                  (desktop &optional workspace))
(declare-function etaf-desktop-layout-resize-split "etaf-desktop-layout"
                  (desktop path ratio &optional workspace))

(define-error 'etaf-desktop-error "Invalid ETAF Desktop operation")

(cl-defstruct (etaf-desktop--window
               (:constructor etaf-desktop--window-create))
  id title view x y width height min-width min-height max-width max-height
  visible minimized maximized workspace normal-geometry z-index movable resizable)

(cl-defstruct (etaf-desktop--state
               (:constructor etaf-desktop--state-create))
  windows workspaces active-workspace active-window next-z)

(cl-defstruct (etaf-desktop--controller
               (:constructor etaf-desktop--controller-create))
  name canvas-width canvas-height state-ref buffer runtime launcher-ref switcher-ref)

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

(defvar etaf-desktop--geometry-behaviors
  (make-hash-table :test #'eq :weakness 'key)
  "Weak map from desktop controllers to stable gesture Behavior tables.
The cache holds only transient Behavior origins; committed geometry remains in
the desktop state and is read afresh by each gesture start.")

(defun etaf-desktop--geometry-behavior (desktop key factory)
  "Return the stable Behavior for DESKTOP and KEY, creating it with FACTORY."
  (let ((table (or (gethash desktop etaf-desktop--geometry-behaviors)
                   (puthash desktop (make-hash-table :test #'equal)
                            etaf-desktop--geometry-behaviors))))
    (or (gethash key table)
        (puthash key (funcall factory) table))))

(defun etaf-desktop--clear-geometry-behaviors (desktop &optional id)
  "Clear cached gesture Behaviors for DESKTOP, optionally only window ID."
  (let ((table (gethash desktop etaf-desktop--geometry-behaviors)))
    (when table
      (if id
          (let (keys)
            (maphash (lambda (key _value)
                       (when (equal (car key) id) (push key keys))) table)
            (dolist (key keys) (remhash key table)))
        (remhash desktop etaf-desktop--geometry-behaviors)))))

(defun etaf-desktop--canvas-window (desktop)
  "Return the live Emacs window displaying DESKTOP, when available."
  (or (and (buffer-live-p (etaf-desktop--controller-buffer desktop))
           (get-buffer-window (etaf-desktop--controller-buffer desktop) t))
      (selected-window)))

(defun etaf-desktop--canvas-width-value (desktop)
  "Return DESKTOP's effective canvas width in pixels."
  (or (etaf-desktop--controller-canvas-width desktop)
      (let ((window (etaf-desktop--canvas-window desktop)))
        (if (window-live-p window)
            (let ((pixel-width (window-body-width window t)))
              (if (> pixel-width 10)
                  pixel-width
                (* (max 1 (window-body-width window))
                   (max 1 (frame-char-width)))))
          (* 80 (max 1 (frame-char-width)))))))

(defun etaf-desktop--canvas-height-value (desktop)
  "Return DESKTOP's effective canvas height in text rows."
  (or (etaf-desktop--controller-canvas-height desktop)
      (let ((window (etaf-desktop--canvas-window desktop)))
        (if (window-live-p window)
            (max 8 (- (window-body-height window) 4))
          24))))

(defun etaf-desktop--copy-window (window)
  "Copy WINDOW's application state."
  (etaf-desktop--window-create
   :id (etaf-desktop--window-id window)
   :title (etaf-desktop--window-title window)
   :view (etaf-desktop--window-view window)
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
   :normal-geometry (copy-sequence (etaf-desktop--window-normal-geometry window))
   :z-index (etaf-desktop--window-z-index window)
   :movable (etaf-desktop--window-movable window)
   :resizable (etaf-desktop--window-resizable window)))

(defun etaf-desktop--copy-state (state)
  "Copy STATE without copying caller-owned View values."
  (etaf-desktop--state-create
   :windows (mapcar #'etaf-desktop--copy-window
                    (etaf-desktop--state-windows state))
   :workspaces (copy-sequence (etaf-desktop--state-workspaces state))
   :active-workspace (etaf-desktop--state-active-workspace state)
   :active-window (etaf-desktop--state-active-window state)
   :next-z (etaf-desktop--state-next-z state)))

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

(defun etaf-desktop--publish (desktop state)
  "Publish STATE through DESKTOP's reactive state ref."
  (etaf-set-value (etaf-desktop--controller-state-ref desktop) state)
  ;; Layout policy is an optional application-layer consumer of the runtime.
  ;; Its guarded refresh applies an active tiling/monocle tree after ordinary
  ;; window mutations, while avoiding a recursive publish during layout apply.
  (when (fboundp 'etaf-desktop-layout-refresh)
    (etaf-desktop-layout-refresh desktop))
  state)

(defun etaf-desktop--update (desktop function)
  "Copy DESKTOP state, call FUNCTION with it, and publish the copy."
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--copy-state (etaf-desktop--state desktop)))
         (result (funcall function state)))
    (etaf-desktop--publish desktop state)
    result))

(defun etaf-desktop--raise (state window)
  "Raise WINDOW in STATE and make it active."
  (setf (etaf-desktop--window-z-index window)
        (etaf-desktop--state-next-z state)
        (etaf-desktop--state-next-z state)
        (1+ (etaf-desktop--state-next-z state))
        (etaf-desktop--state-active-window state)
        (etaf-desktop--window-id window)
        (etaf-desktop--state-active-workspace state)
        (etaf-desktop--window-workspace window))
  window)

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
  "Return a controlled move Behavior for WINDOW ID."
  (etaf-desktop--geometry-behavior
   desktop (list id 'move)
   (lambda ()
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
                  (etaf-desktop-focus-window desktop id))))))

(defun etaf-desktop--resize-behavior (desktop id edge)
  "Return a controlled resize Behavior for WINDOW ID on EDGE."
  (etaf-desktop--geometry-behavior
   desktop (list id edge)
   (lambda ()
     (let ((state (etaf-desktop-window-state desktop id)))
       (etaf-resizable-controlled
        (lambda ()
          (let ((current (etaf-desktop-window-state desktop id)))
            (list :x (plist-get current :x)
                  :y (plist-get current :y)
                  :width (plist-get current :width)
                  :height (plist-get current :height))))
        (lambda (next)
          (etaf-desktop-resize-window desktop id
                                       (plist-get next :width)
                                       (plist-get next :height)))
        :edges edge :delta #'etaf-desktop--delta
        :min-width (plist-get state :min-width)
        :max-width (plist-get state :max-width)
        :min-height (plist-get state :min-height)
        :max-height (plist-get state :max-height))))))

(defun etaf-desktop--window-node (desktop window)
  "Build the retained ETAF UI Window for WINDOW in DESKTOP."
  (let* ((id (etaf-desktop--window-id window))
         (title (or (etaf-desktop--window-title window) (format "%s" id)))
         (body (or (etaf-desktop--window-view window)
                   (etaf-node 'text nil (list title))))
         (mode (cond ((etaf-desktop--window-minimized window) 'minimized)
                     ((etaf-desktop--window-maximized window) 'maximized)
                     (t 'normal)))
         (move (and (etaf-desktop--window-movable window)
                    (etaf-desktop--move-behavior desktop id)))
         (resize-right (and (etaf-desktop--window-resizable window)
                            (etaf-desktop--resize-behavior desktop id 'right)))
         (resize-bottom (and (etaf-desktop--window-resizable window)
                             (etaf-desktop--resize-behavior desktop id 'bottom))))
    (etaf-node
     'etaf-window
     (list :key id :id (format "%s" id) :ref (etaf-desktop--window-ref id)
           :chrome-ref (intern (format "etaf-desktop-chrome-%s" id))
           :title title :mode mode :visible (etaf-desktop--window-visible window)
           :x (list 'px (etaf-desktop--window-x window))
           :y (list 'lh (etaf-desktop--window-y window))
           :width (list 'px (etaf-desktop--window-width window))
           :height (list 'lh (etaf-desktop--window-height window))
           :z-index (etaf-desktop--window-z-index window)
           :min-width (list 'px (etaf-desktop--window-min-width window))
           :min-height (list 'lh (etaf-desktop--window-min-height window))
           :max-width (and (etaf-desktop--window-max-width window)
                           (list 'px (etaf-desktop--window-max-width window)))
           :max-height (and (etaf-desktop--window-max-height window)
                            (list 'lh (etaf-desktop--window-max-height window)))
           :resizable (etaf-desktop--window-resizable window)
           :resize-edges '(right bottom)
           :move-use move
           :resize-use (delq nil
                             (list (and resize-right (cons 'right resize-right))
                                   (and resize-bottom (cons 'bottom resize-bottom))))
           :on-minimize (lambda () (etaf-desktop-minimize-window desktop id))
           :on-maximize (lambda () (etaf-desktop-maximize-window desktop id))
           :on-restore (lambda () (etaf-desktop-restore-window desktop id))
           :on-close (lambda () (etaf-desktop-close-window desktop id)))
     (list body))))

(defun etaf-desktop--taskbar-node (desktop state)
  "Build the taskbar for STATE using the reusable ETAF UI component."
  (let ((items
         (cl-loop for window in (etaf-desktop--state-windows state)
                  when (equal (etaf-desktop--window-workspace window)
                              (etaf-desktop--state-active-workspace state))
                  collect
                  (list :key (etaf-desktop--window-id window)
                        :ref (etaf-desktop--window-ref
                              (format "taskbar-%s"
                                      (etaf-desktop--window-id window)))
                        :label (or (etaf-desktop--window-title window)
                                   (format "%s" (etaf-desktop--window-id window)))
                        :state (cond
                                ((etaf-desktop--window-minimized window) 'minimized)
                                ((equal (etaf-desktop--window-id window)
                                        (etaf-desktop--state-active-window state)) 'active)
                                (t nil))))))
    (etaf-node 'etaf-taskbar
               (list :items items
                     :active (etaf-desktop--state-active-window state)
                     :on-select (lambda (id)
                                  (etaf-desktop-focus-window desktop id))
                     :on-launch (and (fboundp 'etaf-desktop-toggle-launcher)
                                     (lambda ()
                                       (etaf-desktop-toggle-launcher desktop))))
               nil)))

(defun etaf-desktop--workspace-node (desktop state)
  "Build workspace controls for STATE using the reusable ETAF UI component."
  (etaf-node 'etaf-workspace-bar
             (list :workspaces (etaf-desktop--state-workspaces state)
                   :active (etaf-desktop--state-active-workspace state)
                   :brand "ETAF Desktop"
                   :status "File   Edit   View   Window   Help"
                   :on-select
                   (lambda (workspace)
                     (etaf-desktop-switch-workspace desktop workspace)))
             nil))

(defun etaf-desktop--splitter-ratio-change
    (desktop workspace path orientation ratio gesture)
  "Apply one controlled SPLITTER GESTURE to a layout ratio.
The gesture remains an ETAF UI input fact; this application callback converts
its axis delta into the caller-owned layout tree ratio through the public
layout API."
  (when (memq (plist-get gesture :phase) '(move end))
    (let* ((delta (etaf-desktop--delta gesture))
           (offset (if (eq orientation 'horizontal)
                       (car delta) (cdr delta)))
           (total (if (eq orientation 'horizontal)
                      (etaf-desktop--canvas-width-value desktop)
                    (etaf-desktop--canvas-height-value desktop)))
           (next (max 0.1 (min 0.9 (+ ratio (/ (float offset)
                                                (max 1 total)))))))
      (when (fboundp 'etaf-desktop-layout-resize-split)
        (etaf-desktop-layout-resize-split desktop path next workspace)))))

(defun etaf-desktop--splitter-overlay
    (desktop state tree workspace &optional path)
  "Render an ETAF UI splitter overlay for TREE in WORKSPACE.
The overlay contributes only divider interaction and delegates ratio updates
to the desktop layout policy; windows remain the runtime's positioned shells."
  (when (and tree (eq (car tree) :split))
    (let* ((orientation (nth 1 tree))
           (ratio (nth 2 tree))
           (first (nth 3 tree))
           (second (nth 4 tree))
           (first-child (or (etaf-desktop--splitter-overlay
                             desktop state first workspace (append path '(0)))
                            (etaf-node 'box
                                       (list :width 'stretch :height 'stretch
                                             :visibility 'hidden)
                                       nil)))
           (second-child (or (etaf-desktop--splitter-overlay
                              desktop state second workspace (append path '(1)))
                             (etaf-node 'box
                                        (list :width 'stretch :height 'stretch
                                              :visibility 'hidden)
                                        nil)))
           (splitter
            (etaf-node 'etaf-splitter
                       (list :orientation orientation :ratio ratio
                             :class "etaf-desktop-layout-splitter"
                             :overlay t
                             :on-change
                             (lambda (gesture)
                               (etaf-desktop--splitter-ratio-change
                                desktop workspace path orientation ratio gesture)))
                       nil
                       (list (cons 'first (list first-child))
                             (cons 'second (list second-child))))))
      ;; The overlay splitter itself renders only the divider.  Do not wrap it
      ;; in a full-size box: an empty positioned wrapper would paint spaces
      ;; over the caller-owned window contents in a text buffer.
      splitter)))

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

(etaf-define-component etaf-desktop--application (&key desktop)
  "Render DESKTOP as a controlled desktop surface."
  :render
  (let* ((state (etaf-desktop--state desktop))
         (workspace (etaf-desktop--state-active-workspace state))
         (layout-mode (when (fboundp 'etaf-desktop-layout-mode)
                        (etaf-desktop-layout-mode desktop workspace)))
         (layout-tree (when (and layout-mode
                                 (memq layout-mode '(tiling master-stack monocle)))
                        (etaf-desktop-layout-tree desktop workspace)))
         (windows
          (sort (cl-remove-if-not
                 (lambda (window)
                   ;; Keep minimized windows in the retained Component tree so
                   ;; their child state survives; `etaf-window' projects the
                   ;; controlled hidden/minimized presentation.
                   (equal (etaf-desktop--window-workspace window) workspace))
                 (copy-sequence (etaf-desktop--state-windows state)))
                (lambda (a b) (< (etaf-desktop--window-z-index a)
                                 (etaf-desktop--window-z-index b))))))
    (etaf-node
     'column
     (list :width (list 'px (etaf-desktop--canvas-width-value desktop))
           :height (list 'lh (+ (etaf-desktop--canvas-height-value desktop) 4))
           :background-color "#CFD8DC" :color "#17202A")
     (list
      (etaf-desktop--workspace-node desktop state)
      (etaf-node
       'box
       (list :position 'relative
             :width (list 'px (etaf-desktop--canvas-width-value desktop))
             :height (list 'lh (etaf-desktop--canvas-height-value desktop))
             :background-color "#ECEFF1")
       (mapcar (lambda (window) (etaf-desktop--window-node desktop window)) windows))
       (when layout-tree
         (etaf-desktop--splitter-overlay desktop state layout-tree workspace))
       (etaf-desktop--taskbar-node desktop state)
      (etaf-desktop--launcher-node desktop)
      (etaf-desktop--switcher-node desktop state)))))

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
           :active-workspace (car workspaces) :active-window nil :next-z 1)
           :name 'etaf-desktop-state)
          (etaf-desktop--controller-launcher-ref controller)
          (etaf-ref nil :name 'etaf-desktop-launcher-open)
          (etaf-desktop--controller-switcher-ref controller)
          (etaf-ref nil :name 'etaf-desktop-switcher-open))
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
                 :id id :title title :view view :x x :y y :width width :height height
                 :min-width min-width :min-height min-height :max-width max-width
                 :max-height max-height :visible visible :minimized nil
                 :maximized nil :workspace workspace
                 :normal-geometry (list x y width height)
                 :z-index (etaf-desktop--state-next-z state)
                 :movable movable :resizable resizable)))
           (push window (etaf-desktop--state-windows state))
           (setf (etaf-desktop--state-next-z state)
                 (1+ (etaf-desktop--state-next-z state)))
           (etaf-desktop--raise state window)
           (etaf-desktop--window-plist window)))))))

(defun etaf-desktop-close-window (desktop id)
  "Close window ID in DESKTOP and return non-nil when it existed."
  (let ((result
         (etaf-desktop--update
          desktop
          (lambda (state)
            (let ((window (etaf-desktop--window-for state id)))
              (if (not window)
                  nil
                (setf (etaf-desktop--state-windows state)
                      (delq window (etaf-desktop--state-windows state)))
                (when (equal id (etaf-desktop--state-active-window state))
                  (setf (etaf-desktop--state-active-window state) nil))
                t))))))
    (when result (etaf-desktop--clear-geometry-behaviors desktop id))
    result))

(defun etaf-desktop-focus-window (desktop id)
  "Focus and raise window ID, switching to its workspace."
  (etaf-desktop--update
   desktop
   (lambda (state)
     (let ((window (etaf-desktop--window-for state id)))
       (unless window (etaf-desktop--fail "Unknown desktop window: %S" id))
       (setf (etaf-desktop--window-minimized window) nil
             (etaf-desktop--window-visible window) t)
       (etaf-desktop--raise state window)
       id))))

(defun etaf-desktop-move-window (desktop id x y)
  "Move window ID to X and Y, returning its public state plist."
  (etaf-desktop--number x "x" 0)
  (etaf-desktop--number y "y" 0)
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
       (etaf-desktop--window-plist window)))))

(defun etaf-desktop-resize-window (desktop id width height)
  "Resize window ID to WIDTH and HEIGHT, respecting its size limits."
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
       (etaf-desktop--window-plist window)))))

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
  (etaf-desktop--update
   desktop
   (lambda (state)
     (let ((window (etaf-desktop--window-for state id)))
       (unless window (etaf-desktop--fail "Unknown desktop window: %S" id))
       (setf (etaf-desktop--window-minimized window) t
             (etaf-desktop--window-visible window) nil)
       (when (equal id (etaf-desktop--state-active-window state))
         (setf (etaf-desktop--state-active-window state) nil))
       (etaf-desktop--window-plist window)))))

(defun etaf-desktop-restore-window (desktop id)
  "Restore minimized or maximized window ID and focus it."
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
       (etaf-desktop--window-plist window)))))

(defun etaf-desktop-window-maximized-p (desktop id)
  "Return non-nil when window ID is maximized."
  (etaf-desktop--window-maximized
   (or (etaf-desktop--window-for (etaf-desktop--state desktop) id)
       (etaf-desktop--fail "Unknown desktop window: %S" id))))

(defun etaf-desktop-switch-workspace (desktop workspace)
  "Make WORKSPACE the active desktop workspace."
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
     workspace)))

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
  (etaf-desktop--update
   desktop
   (lambda (state)
     (when (= (length (etaf-desktop--state-workspaces state)) 1)
       (etaf-desktop--fail "Cannot remove the last desktop workspace"))
     (etaf-desktop--assert-workspace state workspace)
     (let ((replacement (car (delete workspace
                                    (copy-sequence (etaf-desktop--state-workspaces state))))))
       (dolist (window (etaf-desktop--state-windows state))
         (when (equal (etaf-desktop--window-workspace window) workspace)
           (setf (etaf-desktop--window-workspace window) replacement)))
       (setf (etaf-desktop--state-workspaces state)
             (delete workspace (etaf-desktop--state-workspaces state)))
       (when (equal workspace (etaf-desktop--state-active-workspace state))
         (setf (etaf-desktop--state-active-workspace state) replacement
               (etaf-desktop--state-active-window state) nil))
       replacement))))

(defun etaf-desktop-view (desktop)
  "Return the root View for DESKTOP without mounting it."
  (etaf-desktop--controller desktop)
  (etaf-view (etaf-desktop--application :desktop desktop)))

(defun etaf-desktop-mount (desktop &optional buffer-or-name)
  "Mount DESKTOP into BUFFER-OR-NAME and return the buffer.
When BUFFER-OR-NAME is nil, DESKTOP's configured name is used.  A desktop can
be mounted once; callers use `etaf-desktop-close' to release the Runtime."
  (let ((desktop (etaf-desktop--controller desktop)))
    (when (etaf-desktop--controller-runtime desktop)
      (etaf-desktop--fail "Desktop is already mounted"))
    (let* ((buffer (etaf-mount (or buffer-or-name
                                   (etaf-desktop--controller-name desktop))
                               (etaf-desktop-view desktop)))
           (runtime (etaf-runtime-for-buffer buffer)))
      (setf (etaf-desktop--controller-buffer desktop) buffer
            (etaf-desktop--controller-runtime desktop) runtime)
      buffer)))

(defun etaf-desktop-close (desktop)
  "Unmount DESKTOP and kill its owned buffer, returning nil.
Closing is idempotent and releases the Runtime's event and reactive resources."
  (let ((desktop (etaf-desktop--controller desktop))
        (runtime (etaf-desktop--controller-runtime desktop))
        (buffer (etaf-desktop--controller-buffer desktop)))
    (when runtime (etaf-unmount runtime))
    (when (buffer-live-p buffer) (kill-buffer buffer))
    (setf (etaf-desktop--controller-runtime desktop) nil
          (etaf-desktop--controller-buffer desktop) nil)
    (etaf-desktop--clear-geometry-behaviors desktop)
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
