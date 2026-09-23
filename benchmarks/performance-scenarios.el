;;; performance-scenarios.el --- ETAF Desktop interaction workloads -*- lexical-binding: t; -*-

;;; Commentary:
;; The workspace performance driver owns sampling, settlement and diagnostics.
;; Each workload keeps four text windows in the active workspace.  A sample
;; performs one real public operation; its precondition is restored and flushed
;; before timing, and its publication is flushed inside the timed operation.
;; Geometry alternates direction so long sample sets never reach size limits.
;; Version 2 separates individual actions and replaces the smaller version 1
;; fixtures.  Results from those workloads are not comparable.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'ebox)
(require 'etaf-desktop)

(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defconst etaf-desktop-benchmark--ids
  '(desktop-one desktop-two desktop-three desktop-four))

(defun etaf-desktop-benchmark--open-window (desktop id index workspace)
  "Open text window ID at INDEX in DESKTOP's WORKSPACE."
  (etaf-desktop-open-window
   desktop id :workspace workspace :title (format "Window %s" id)
   :view (etaf-view (text (expr (format "Content %s" id))))
   :x (+ 20 (* 440 (mod index 2))) :y (+ 2 (* 14 (/ index 2)))
   :width 360 :height 10 :min-width 120 :min-height 5))

(defun etaf-desktop-benchmark--rectangle (state)
  "Return the public geometry fields from window STATE."
  (mapcar (lambda (key) (plist-get state key)) '(:x :y :width :height)))

(defun etaf-desktop-benchmark--focused-p (desktop id)
  "Check that ID is active and above the other visible workspace windows."
  (let ((state (etaf-desktop-window-state desktop id)))
    (and (equal id (etaf-desktop-active-window desktop))
         (plist-get state :visible)
         (not (plist-get state :minimized))
         (cl-every
          (lambda (other)
            (or (equal id (plist-get other :id))
                (not (equal (plist-get state :workspace)
                            (plist-get other :workspace)))
                (not (plist-get other :visible))
                (plist-get other :minimized)
                (> (plist-get state :z-index) (plist-get other :z-index))))
          (etaf-desktop-windows desktop)))))

(defun etaf-desktop-benchmark--content-p (buffer id)
  "Return non-nil when BUFFER visibly contains window ID's body marker."
  (with-current-buffer buffer
    (not (null (string-match-p (regexp-quote (format "Content %s" id))
                               (buffer-string))))))

(defun etaf-desktop-benchmark--fixture (operation)
  "Create a four-window workload for public OPERATION."
  (let* ((buffer (generate-new-buffer " *ETAF Desktop benchmark*"))
         (desktop (etaf-desktop-create
                   :name (buffer-name buffer) :canvas-width 900 :canvas-height 30
                   :workspaces '(main dev)))
         (ids etaf-desktop-benchmark--ids)
         (step 0)
         (target (car ids))
         (runtime nil)
         (generation nil)
         (event-window nil)
         (before nil)
         (expected nil)
         (delta nil)
         (edge (and (string-prefix-p "resize-" (symbol-name operation))
                    (substring (symbol-name operation) 7)))
         (shell (cond ((string-prefix-p "launcher-" (symbol-name operation)) 'launcher)
                      ((string-prefix-p "switcher-" (symbol-name operation)) 'switcher)
                      ((string-prefix-p "settings-" (symbol-name operation)) 'settings)))
         (shell-open (string-suffix-p "-open" (symbol-name operation))))
    (cl-loop for id in ids for index from 0 do
             (etaf-desktop-benchmark--open-window desktop id index 'main))
    (when (eq operation 'workspace)
      (cl-loop for index below 4 do
               (etaf-desktop-benchmark--open-window
                desktop (intern (format "desktop-dev-%s" index)) index 'dev)))
    (etaf-desktop-switch-workspace desktop 'main)
    (etaf-desktop-focus-window desktop (car (last ids)))
    (when (eq operation 'layout-ratio)
      (etaf-desktop-layout-set-tree
       desktop '(:split horizontal 0.5
                        (:split vertical 0.5 (:leaf desktop-one) (:leaf desktop-three))
                        (:split vertical 0.5 (:leaf desktop-two) (:leaf desktop-four)))
       'main)
      (etaf-desktop-set-layout-mode desktop 'tiling 'main))
    (setq runtime (etaf-runtime-for-buffer (etaf-desktop-mount desktop buffer)))
    (cl-labels
        ((flush () (etaf-runtime-flush runtime))
         (open-shell ()
           (pcase shell
             ('launcher (etaf-desktop-toggle-launcher desktop t))
             ('switcher (etaf-desktop-toggle-switcher desktop t))
             ('settings (etaf-desktop-toggle-settings desktop t))))
         (close-shell ()
           (pcase shell
             ('launcher (etaf-desktop-close-launcher desktop))
             ('switcher (etaf-desktop-close-switcher desktop))
             ('settings (etaf-desktop-close-settings desktop))))
         (shell-visible-p ()
           (pcase shell
             ('launcher (etaf-desktop-launcher-open-p desktop))
             ('switcher (etaf-desktop-switcher-open-p desktop))
             ('settings (etaf-desktop-settings-open-p desktop))))
         (state () (etaf-desktop-window-state desktop target)))
      (list
       :buffer buffer
       :ready (lambda () t)
       :environment (lambda ()
                      (list :operation (symbol-name operation)
                            :canvas-width 900 :canvas-height 30
                            :workspace-window-count 4))
       :prepare
       (lambda ()
         (cl-incf step)
         (setq target (nth (mod (1- step) 4) ids))
         (cond
          (shell (if shell-open (close-shell) (open-shell)))
          ((eq operation 'close)
           ;; Reopen the preceding closed window so every timed close starts
           ;; from four windows, then make the target the active one.
           (cl-loop for id in ids for index from 0
                    unless (cl-find id (etaf-desktop-windows desktop)
                                    :key (lambda (window) (plist-get window :id)))
                    do (etaf-desktop-benchmark--open-window desktop id index 'main))
           (etaf-desktop-focus-window desktop target))
          ((memq operation '(maximize minimize restore-maximized restore-minimized))
           (dolist (id ids) (etaf-desktop-restore-window desktop id))
           (etaf-desktop-focus-window desktop target)
           (setq expected (etaf-desktop-benchmark--rectangle (state)))
           (pcase operation
             ('restore-maximized (etaf-desktop-maximize-window desktop target))
             ('restore-minimized (etaf-desktop-minimize-window desktop target))))
          ((eq operation 'workspace)
           (setq expected (if (eq (etaf-desktop-active-workspace desktop) 'main)
                              'dev 'main)))
          ((eq operation 'layout-ratio)
           (setq expected (if (= (nth 2 (etaf-desktop-layout-tree desktop 'main)) 0.4)
                              0.6 0.4)))
          ((eq operation 'layout-mode)
           (setq expected (if (eq (etaf-desktop-layout-mode desktop) 'floating)
                              'tiling 'floating))))
         (flush)
         (setq before (etaf-desktop-windows desktop)
               generation (etaf-runtime-current-generation runtime)
               event-window (get-buffer-window buffer t))
         (when (or edge (eq operation 'move))
           (let* ((direction (if (cl-evenp (/ (1- step) 4)) 1 -1))
                  (dx (if (or (eq operation 'move)
                              (string-match-p "left\\|right" edge)) (* direction 8) 0))
                  (dy (if (or (eq operation 'move)
                              (string-match-p "top\\|bottom" edge)) direction 0))
                  (rectangle (etaf-desktop-benchmark--rectangle (state)))
                  (left (and edge (string-match-p "left" edge)))
                  (top (and edge (string-match-p "top" edge))))
             (setq delta (cons dx (* dy (if (window-live-p event-window)
                                           (frame-char-height (window-frame event-window))
                                         1)))
                   expected
                   (list (+ (nth 0 rectangle) (if (or left (eq operation 'move)) dx 0))
                         (+ (nth 1 rectangle) (if (or top (eq operation 'move)) dy 0))
                         (+ (nth 2 rectangle) (if edge (if left (- dx) dx) 0))
                         (+ (nth 3 rectangle) (if edge (if top (- dy) dy) 0)))))))
       :invoke
       (lambda (_sample)
         (cond
          (shell (if shell-open (open-shell) (close-shell)))
          ((or edge (eq operation 'move))
           (let ((ref (intern (if edge
                                  (format "etaf-desktop-resize-%s-%s" target edge)
                                (format "etaf-desktop-chrome-%s" target)))))
             (etaf-dispatch-event runtime ref 'drag
                                  (list :phase 'start :delta '(0 . 0) :window event-window) t)
             (etaf-dispatch-event runtime ref 'drag
                                  (list :phase 'move :delta delta :window event-window) t)
             (etaf-dispatch-event runtime ref 'drag
                                  (list :phase 'end :delta delta :window event-window) t)))
          (t
           (pcase operation
             ('focus (etaf-desktop-focus-window desktop target))
             ('maximize (etaf-desktop-maximize-window desktop target))
             ('minimize (etaf-desktop-minimize-window desktop target))
             ((or 'restore-maximized 'restore-minimized)
              (etaf-desktop-restore-window desktop target))
             ('close (etaf-desktop-close-window desktop target))
             ('workspace (etaf-desktop-switch-workspace desktop expected))
             ('layout-ratio (etaf-desktop-layout-resize-split desktop nil expected 'main))
             ('layout-mode (etaf-desktop-set-layout-mode desktop expected 'main)))))
         (flush))
       :settled (lambda () (not (eq (etaf-runtime-current-generation runtime) generation)))
       :verify
       (lambda ()
         (or
          (cond
           (shell (eq (not (null (shell-visible-p))) shell-open))
           ((or edge (eq operation 'move))
            (and (equal expected (etaf-desktop-benchmark--rectangle (state)))
                 (etaf-desktop-benchmark--focused-p desktop target)
                 (etaf-desktop-benchmark--content-p buffer target)
                 (cl-every
                  (lambda (old)
                    (or (equal target (plist-get old :id))
                        (equal (etaf-desktop-benchmark--rectangle old)
                               (etaf-desktop-benchmark--rectangle
                                (etaf-desktop-window-state desktop (plist-get old :id))))))
                  before)))
           ((eq operation 'focus)
            (and (etaf-desktop-benchmark--focused-p desktop target)
                 (cl-every (lambda (id) (etaf-desktop-benchmark--content-p buffer id)) ids)))
           ((eq operation 'maximize)
            (and (etaf-desktop-window-maximized-p desktop target)
                 (equal '(0 0 900 30) (etaf-desktop-benchmark--rectangle (state)))
                 (etaf-desktop-benchmark--content-p buffer target)))
           ((eq operation 'minimize)
            (and (plist-get (state) :minimized)
                 (not (equal target (etaf-desktop-active-window desktop)))
                 (not (etaf-desktop-benchmark--content-p buffer target))))
           ((memq operation '(restore-maximized restore-minimized))
            (and (not (plist-get (state) :minimized))
                 (not (etaf-desktop-window-maximized-p desktop target))
                 (equal expected (etaf-desktop-benchmark--rectangle (state)))
                 (etaf-desktop-benchmark--focused-p desktop target)
                 (etaf-desktop-benchmark--content-p buffer target)))
           ((eq operation 'close)
            (and (= 3 (length (etaf-desktop-windows desktop)))
                 (not (cl-find target (etaf-desktop-windows desktop)
                               :key (lambda (window) (plist-get window :id))))
                 (not (etaf-desktop-benchmark--content-p buffer target))
                 (etaf-desktop-benchmark--focused-p
                  desktop (etaf-desktop-active-window desktop))))
           ((eq operation 'workspace)
            (and (eq expected (etaf-desktop-active-workspace desktop))
                 (cl-every
                  (lambda (window)
                    (eq (equal expected (plist-get window :workspace))
                        (etaf-desktop-benchmark--content-p buffer (plist-get window :id))))
                  (etaf-desktop-windows desktop))))
           ((eq operation 'layout-ratio)
            (and (= expected (nth 2 (etaf-desktop-layout-tree desktop 'main)))
                 (not (equal (etaf-desktop-benchmark--rectangle (car before))
                             (etaf-desktop-benchmark--rectangle
                              (etaf-desktop-window-state desktop (plist-get (car before) :id)))))))
           ((eq operation 'layout-mode)
            (and (eq expected (etaf-desktop-layout-mode desktop))
                 (cl-every (lambda (id) (etaf-desktop-benchmark--content-p buffer id)) ids))))
          (format "%s did not publish the expected window state and content" operation)))
       :outcome
       (lambda ()
         (let* ((windows (etaf-desktop-windows desktop))
                (window (cl-find target windows :key (lambda (value) (plist-get value :id)))))
           (list :operation (symbol-name operation) :target (symbol-name target)
                 :window-count (length windows)
                 :active (format "%s" (etaf-desktop-active-window desktop))
                 :workspace (format "%s" (etaf-desktop-active-workspace desktop))
                 :layout (format "%s" (etaf-desktop-layout-mode desktop 'main))
                 :rectangle (and window (vconcat (etaf-desktop-benchmark--rectangle window)))
                 :shell-open (and shell (if (shell-visible-p) t :false)))))
       :observe (lambda (sink)
                  (ebox-buffer-set-observer buffer sink)
                  (lambda () (ebox-buffer-set-observer buffer nil)))
       :cleanup (lambda ()
                  (etaf-desktop-close desktop)
                  (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(dolist (operation '(move resize-left resize-right resize-top resize-bottom
                         resize-top-left resize-top-right resize-bottom-left resize-bottom-right
                         focus maximize minimize restore-maximized restore-minimized close
                         workspace layout-ratio layout-mode
                         launcher-open launcher-close switcher-open switcher-close
                         settings-open settings-close))
  (taf-benchmark-register
   (format "etaf-desktop.%s.%s"
           (if (or (eq operation 'move)
                   (string-prefix-p "resize-" (symbol-name operation))) "geometry" "policy")
           operation)
   :version 2 :modes '(batch gui) :isolation 'series :required-providers '(ebox)
   :budget-ms 10 :impact 'mixed
   :description (format "Four-window Desktop %s with completed publication" operation)
   :setup (let ((selected-operation operation))
            (lambda (_mode) (etaf-desktop-benchmark--fixture selected-operation)))))

;;; performance-scenarios.el ends here
