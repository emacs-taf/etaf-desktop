;;; etaf-desktop-runtime.el --- Desktop application state and view -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)

(define-error 'etaf-desktop-error "Invalid ETAF Desktop operation")

(cl-defstruct (etaf-desktop--window
               (:constructor etaf-desktop--window-create))
  id title view x y width height min-width min-height max-width max-height
  visible minimized maximized workspace normal-geometry z-index movable resizable)

(cl-defstruct (etaf-desktop--state
               (:constructor etaf-desktop--state-create))
  windows workspaces active-workspace active-window next-z)

(cl-defstruct (etaf-desktop--drag
               (:constructor etaf-desktop--drag-create))
  id kind x y width height)

(cl-defstruct (etaf-desktop--controller
               (:constructor etaf-desktop--controller-create))
  name canvas-width canvas-height state-ref sessions buffer runtime)

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
  "Return integer X and Y displacement from GESTURE."
  (let ((delta (plist-get gesture :delta)))
    (cons (or (car delta) 0) (or (cdr delta) 0))))

(defun etaf-desktop--drag-callback (desktop id kind)
  "Return a gesture callback for DESKTOP window ID and KIND."
  (lambda (gesture)
    (let ((phase (plist-get gesture :phase))
          (sessions (etaf-desktop--controller-sessions desktop)))
      (cond
       ((eq phase 'start)
        (when-let* ((window (etaf-desktop--window-for
                            (etaf-desktop--state desktop) id)))
          (etaf-desktop-focus-window desktop id)
          (puthash id
                   (etaf-desktop--drag-create
                    :id id :kind kind
                    :x (etaf-desktop--window-x window)
                    :y (etaf-desktop--window-y window)
                    :width (etaf-desktop--window-width window)
                    :height (etaf-desktop--window-height window))
                   sessions)))
       ((memq phase '(move end))
        (when-let* ((session (gethash id sessions)))
          (let* ((delta (etaf-desktop--delta gesture))
                 (dx (car delta)) (dy (cdr delta)))
            (if (eq kind 'move)
                (etaf-desktop-move-window
                 desktop id (+ (etaf-desktop--drag-x session) dx)
                 (+ (etaf-desktop--drag-y session) dy))
              (etaf-desktop-resize-window
               desktop id
               (+ (etaf-desktop--drag-width session) dx)
               (+ (etaf-desktop--drag-height session) dy)))
            (when (eq phase 'end) (remhash id sessions)))))
       ((eq phase 'cancel) (remhash id sessions))))))

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
                    (etaf-desktop--drag-callback desktop id 'move)))
         (resize (and (etaf-desktop--window-resizable window)
                      (lambda (_edge gesture)
                        (funcall (etaf-desktop--drag-callback desktop id 'resize)
                                 gesture)))))
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
           :on-move move :on-resize resize
           :on-minimize (lambda () (etaf-desktop-minimize-window desktop id))
           :on-maximize (lambda () (etaf-desktop-maximize-window desktop id))
           :on-restore (lambda () (etaf-desktop-restore-window desktop id))
           :on-close (lambda () (etaf-desktop-close-window desktop id)))
     (list body))))

(defun etaf-desktop--taskbar-node (desktop state)
  "Build the taskbar for STATE."
  (let ((items
         (cl-loop for window in (etaf-desktop--state-windows state)
                  when (and (eq (etaf-desktop--window-workspace window)
                                (etaf-desktop--state-active-workspace state))
                            (etaf-desktop--window-minimized window))
                  collect
                  (etaf-node 'etaf-button
                             (list :key (etaf-desktop--window-id window)
                                   :label (or (etaf-desktop--window-title window)
                                              (format "%s" (etaf-desktop--window-id window)))
                                   :variant 'ghost
                                   :on-press
                                   (lambda ()
                                     (etaf-desktop-restore-window
                                      desktop (etaf-desktop--window-id window))))
                             nil))))
    (etaf-node 'row
               (list :class "etaf-desktop-taskbar" :height '(lh 2)
                     :background-color "#263238" :color "#FFFFFF"
                     :padding '((lh 0) (ch 1)) :item-gap '(ch 1))
               (or items (list (etaf-node 'text nil (list "Desktop")))))))

(defun etaf-desktop--workspace-node (desktop state)
  "Build workspace controls for STATE."
  (etaf-node 'row
             (list :height '(lh 2) :background-color "#37474F"
                   :color "#FFFFFF" :padding '((lh 0) (ch 1))
                   :item-gap '(ch 1))
             (mapcar
              (lambda (workspace)
                (etaf-node 'etaf-button
                           (list :key workspace :label (format "%s" workspace)
                                 :variant (if (equal workspace
                                                    (etaf-desktop--state-active-workspace state))
                                              'primary 'ghost)
                                 :on-press
                                 (lambda ()
                                   (etaf-desktop-switch-workspace desktop workspace)))
                           nil))
              (etaf-desktop--state-workspaces state))))

(etaf-define-component etaf-desktop--application (&key desktop)
  "Render DESKTOP as a controlled desktop surface."
  :render
  (let* ((state (etaf-desktop--state desktop))
         (workspace (etaf-desktop--state-active-workspace state))
         (windows
          (sort (cl-remove-if-not
                 (lambda (window)
                   (and (equal (etaf-desktop--window-workspace window) workspace)
                        (etaf-desktop--window-visible window)
                        (not (etaf-desktop--window-minimized window))))
                 (copy-sequence (etaf-desktop--state-windows state)))
                (lambda (a b) (< (etaf-desktop--window-z-index a)
                                 (etaf-desktop--window-z-index b))))))
    (etaf-node
     'column
     (list :width (list 'px (etaf-desktop--controller-canvas-width desktop))
           :height (list 'lh (+ (etaf-desktop--controller-canvas-height desktop) 4))
           :background-color "#CFD8DC" :color "#17202A")
     (list
      (etaf-desktop--workspace-node desktop state)
      (etaf-node
       'box
       (list :position 'relative
             :width (list 'px (etaf-desktop--controller-canvas-width desktop))
             :height (list 'lh (etaf-desktop--controller-canvas-height desktop))
             :background-color "#ECEFF1")
       (mapcar (lambda (window) (etaf-desktop--window-node desktop window)) windows))
      (etaf-desktop--taskbar-node desktop state)))))

(cl-defun etaf-desktop-create
    (&key (name "*ETAF Desktop*") (canvas-width 120)
          (canvas-height 36) (workspaces '(main)))
  "Create an application desktop with CANVAS-WIDTH and CANVAS-HEIGHT.
WORKSPACES is a nonempty list of stable workspace keys.  The returned desktop
owns its reactive state and does not mount a buffer until `etaf-desktop-mount'."
  (unless (and (stringp name) (not (string-empty-p name)))
    (etaf-desktop--fail "Desktop name must be a nonempty string"))
  (etaf-desktop--number canvas-width "canvas-width" 1)
  (etaf-desktop--number canvas-height "canvas-height" 1)
  (unless (and (listp workspaces) workspaces
               (not (cl-some #'null workspaces))
               (= (length workspaces) (length (delete-dups (copy-sequence workspaces)))))
    (etaf-desktop--fail "Workspaces must be a nonempty list of unique keys"))
  (let ((controller
         (etaf-desktop--controller-create
          :name name :canvas-width canvas-width :canvas-height canvas-height
          :state-ref nil :sessions (make-hash-table :test #'equal))))
    (setf (etaf-desktop--controller-state-ref controller)
          (etaf-ref
           (etaf-desktop--state-create
            :windows nil :workspaces (copy-sequence workspaces)
            :active-workspace (car workspaces) :active-window nil :next-z 1)
           :name 'etaf-desktop-state))
    controller))

(defun etaf-desktop-state (desktop)
  "Return DESKTOP's detached state plist, including windows and workspaces."
  (let ((desktop (etaf-desktop--controller desktop))
        (state (etaf-desktop--state desktop)))
    (list :name (etaf-desktop--controller-name desktop)
          :canvas-width (etaf-desktop--controller-canvas-width desktop)
          :canvas-height (etaf-desktop--controller-canvas-height desktop)
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
    (desktop id &key title view (x 0) (y 0) (width 40) (height 12)
          (min-width 12) (min-height 3) max-width max-height workspace
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
         (remhash id (etaf-desktop--controller-sessions desktop))
         t)))))

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
             (etaf-desktop--controller-canvas-width desktop)
             (etaf-desktop--window-height window)
             (etaf-desktop--controller-canvas-height desktop)
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
