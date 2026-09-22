;;; etaf-desktop-tests.el --- Public desktop application scenarios -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'etaf-desktop)
(require 'etaf)

(ert-deftest etaf-desktop-window-lifecycle-and-state-isolation ()
  "Public mutations preserve identity and detached reads cannot mutate state."
  (let ((desktop (etaf-desktop-create)))
    (etaf-desktop-open-window desktop 'notes :title "Notes" :x 2 :y 3)
    (etaf-desktop-open-window desktop 'clock :title "Clock")
    (should (eq (etaf-desktop-active-window desktop) 'clock))
    (etaf-desktop-focus-window desktop 'notes)
    (should (eq (etaf-desktop-active-window desktop) 'notes))
    (should (> (plist-get (etaf-desktop-window-state desktop 'notes) :z-index)
               (plist-get (etaf-desktop-window-state desktop 'clock) :z-index)))
    (let ((snapshot (etaf-desktop-window-state desktop 'notes)))
      (setf (plist-get snapshot :x) 99)
      (should (= 2 (plist-get (etaf-desktop-window-state desktop 'notes) :x))))
    (should (etaf-desktop-close-window desktop 'clock))
    (should-not (etaf-desktop-close-window desktop 'clock))
    (should-error (etaf-desktop-window-state desktop 'clock)
                  :type 'etaf-desktop-error)))

(ert-deftest etaf-desktop-geometry-limits-maximize-minimize-restore ()
  "Desktop policy saves a restore rectangle and preserves it across minimization."
  (let ((desktop (etaf-desktop-create :canvas-width 120 :canvas-height 36)))
    (etaf-desktop-open-window desktop 'notes :x 2 :y 3 :width 40 :height 12
                              :min-width 20 :min-height 6 :max-width 70 :max-height 20)
    (etaf-desktop-resize-window desktop 'notes 5 80)
    (let ((window (etaf-desktop-window-state desktop 'notes)))
      (should (= 20 (plist-get window :width)))
      (should (= 20 (plist-get window :height))))
    (etaf-desktop-move-window desktop 'notes 6 8)
    (etaf-desktop-maximize-window desktop 'notes)
    (etaf-desktop-maximize-window desktop 'notes)
    (should (etaf-desktop-window-maximized-p desktop 'notes))
    (let ((window (etaf-desktop-window-state desktop 'notes)))
      (should (= 120 (plist-get window :width)))
      (should (= 36 (plist-get window :height)))
      (should (equal '(6 8 20 20) (plist-get window :normal-geometry))))
    (etaf-desktop-minimize-window desktop 'notes)
    (should (plist-get (etaf-desktop-window-state desktop 'notes) :minimized))
    (etaf-desktop-restore-window desktop 'notes)
    (let ((window (etaf-desktop-window-state desktop 'notes)))
      (should-not (plist-get window :minimized))
      (should-not (plist-get window :maximized))
      (should (plist-get window :visible))
      (should (equal '(6 8 20 20) (list (plist-get window :x)
                                         (plist-get window :y)
                                         (plist-get window :width)
                                         (plist-get window :height)))))))

(ert-deftest etaf-desktop-workspace-policy ()
  "Workspace selection and removal preserve window ownership."
  (let ((desktop (etaf-desktop-create :workspaces '(main second))))
    (etaf-desktop-open-window desktop 'one :workspace 'main)
    (etaf-desktop-open-window desktop 'two :workspace 'second)
    (should (eq 'second (etaf-desktop-active-workspace desktop)))
    (etaf-desktop-switch-workspace desktop 'main)
    (should (eq 'one (etaf-desktop-active-window desktop)))
    (etaf-desktop-add-workspace desktop 'third)
    (etaf-desktop-remove-workspace desktop 'second)
    (should (eq 'main (plist-get (etaf-desktop-window-state desktop 'two) :workspace)))
    (should-error (etaf-desktop-switch-workspace desktop 'missing)
                  :type 'etaf-desktop-error)
    (should (eq 'main (etaf-desktop-active-workspace desktop)))
    (etaf-desktop-remove-workspace desktop 'third)
    (should-error (etaf-desktop-remove-workspace desktop 'main)
                  :type 'etaf-desktop-error)))

(ert-deftest etaf-desktop-mounted-window-and-taskbar ()
  "A mounted desktop displays current workspace windows and restores via taskbar."
  (let ((desktop (etaf-desktop-create :name " *desktop-test*"
                                      :canvas-width 400 :canvas-height 20)))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'notes :title "Notes"
                                    :view (etaf-view (text "Hello desktop")))
          (let ((buffer (etaf-desktop-mount desktop)))
            (should (buffer-live-p buffer))
            (with-current-buffer buffer
              (should-not mode-line-format)
              (should-not header-line-format)
              (should (string-match-p "Notes" (buffer-string))))
            (etaf-desktop-minimize-window desktop 'notes)
            (with-current-buffer buffer
              (should-not (string-match-p "Hello desktop" (buffer-string)))
              (should (string-match-p "Notes" (buffer-string))))
            (etaf-desktop-restore-window desktop 'notes)
            (with-current-buffer buffer
              (should (string-match-p "Hello desktop" (buffer-string))))))
      (etaf-desktop-close desktop))
    (etaf-desktop-close desktop)))

(ert-deftest etaf-desktop-mounted-buffer-uses-configured-local-shortcuts ()
  "Mounted Desktop buffers dispatch configured single-letter actions locally."
  (let ((desktop (etaf-desktop-create :name " *desktop-keymap-test*"
                                      :canvas-width 80 :canvas-height 16)))
    (unwind-protect
        (let ((buffer (etaf-desktop-mount desktop)))
          (with-current-buffer buffer
            (should (commandp (key-binding (kbd "n"))))
            (should (commandp (key-binding (kbd "o")))))
          (etaf-desktop-set-setting
           desktop :keybindings
           (plist-put (copy-sequence
                       (plist-get (etaf-desktop-settings desktop) :keybindings))
                      :focus-next "f"))
          (with-current-buffer buffer
            (should (commandp (key-binding (kbd "f"))))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-view-installs-shortcuts-in-named-target-buffer ()
  "A View mounted by name binds shortcuts in its target, not the caller."
  (let* ((desktop (etaf-desktop-create :name " *desktop-keymap-target*"
                                       :canvas-width 80 :canvas-height 16))
         (target (get-buffer-create " *desktop-keymap-target-buffer*"))
         (caller (current-buffer)))
    (unwind-protect
        (progn
          ;; Deliberately call from CALLER without selecting TARGET.  The
          ;; target buffer is the only buffer that should receive the local
          ;; Desktop keymap.
          (etaf-mount target (etaf-desktop-view desktop))
          (let ((target-next
                 (with-current-buffer target (key-binding (kbd "n"))))
                (target-settings
                 (with-current-buffer target (key-binding (kbd "o"))))
                (caller-next (with-current-buffer caller
                               (key-binding (kbd "n")))))
            (should (commandp target-next))
            (should (commandp target-settings))
            (should-not (eq caller-next target-next))))
      (when-let* ((runtime (etaf-runtime-for-buffer target)))
        (etaf-unmount runtime))
      (when (buffer-live-p target)
        (kill-buffer target))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-body-activation-raises-window ()
  "Pressing application content focuses and raises that window."
  (let ((desktop (etaf-desktop-create :name " *desktop-body-focus*")))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'notes :x 2 :y 2
                                    :view (etaf-view (text "Notes body")))
          (etaf-desktop-open-window desktop 'files :x 30 :y 2
                                    :view (etaf-view (text "Files body")))
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer))
                 (content-refs
                  (sort
                   (cl-loop for entry in (etaf-runtime-handler-entries runtime)
                            for ref = (car entry)
                            for props = (etaf-runtime-host-props-for runtime ref)
                            when (and (equal (plist-get props :class)
                                             "etaf-window-content")
                                      (assq 'press entry))
                            collect (cons (car (etaf-host-ref-bounds runtime ref)) ref))
                   (lambda (a b) (< (car a) (car b))))))
            (should (= 2 (length content-refs)))
            (should (eq 'files (etaf-desktop-active-window desktop)))
            (etaf-dispatch-event runtime (cdr (car content-refs)) 'press)
            (should (eq 'notes (etaf-desktop-active-window desktop)))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-nested-content-activation-raises-window ()
  "Pressing an interactive descendant also focuses and raises its window."
  (let ((desktop (etaf-desktop-create :name " *desktop-nested-focus*")))
    (unwind-protect
        (progn
          (etaf-desktop-open-window
           desktop 'notes :x 2 :y 2
           :view (etaf-view
                  (etaf-button :label "Open notes"
                               :on-press (lambda () nil))))
          (etaf-desktop-open-window
           desktop 'files :x 30 :y 2
           :view (etaf-view (text "Files body")))
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer))
                 (button-ref
                  (cl-loop for entry in (etaf-runtime-handler-entries runtime)
                           for ref = (car entry)
                           for props = (etaf-runtime-host-props-for runtime ref)
                           when (and (assq 'press entry)
                                     (equal (plist-get props :class)
                                            "etaf-button enabled"))
                           return ref)))
            (should button-ref)
            (should (eq 'files (etaf-desktop-active-window desktop)))
            (etaf-dispatch-event runtime button-ref 'press)
            (should (eq 'notes (etaf-desktop-active-window desktop)))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-native-title-drag-converts-pixels-to-rows ()
  "A native title gesture changes desktop Y by text rows, not raw pixels."
  (let ((desktop (etaf-desktop-create :name " *desktop-drag-test*")))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'notes :title "Notes")
          (let ((buffer (etaf-desktop-mount desktop)))
            (save-window-excursion
              (set-window-buffer (selected-window) buffer)
              (with-current-buffer buffer
                (let* ((runtime (etaf-runtime-for-buffer buffer))
                       (window (selected-window))
                       (line-height (max 1 (frame-char-height)))
                       (gesture-start (list :phase 'start :delta '(0 . 0)
                                            :window window))
                       (gesture-end (list :phase 'end
                                          :delta (cons 4 line-height)
                                          :window window)))
                  (etaf-dispatch-event runtime 'etaf-desktop-chrome-notes
                                       'drag gesture-start t)
                  (etaf-dispatch-event runtime 'etaf-desktop-chrome-notes
                                       'drag gesture-end t))))))
      (etaf-desktop-close desktop))
    (should (= 1 (plist-get (etaf-desktop-window-state desktop 'notes) :y)))))

(ert-deftest etaf-desktop-native-drag-keeps-behavior-origin-across-rerenders ()
  "A controlled title drag keeps its origin through multiple publications."
  (let ((desktop (etaf-desktop-create :name " *desktop-drag-origin*")))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'notes :x 0 :y 0)
          (let ((buffer (etaf-desktop-mount desktop)))
            (let ((runtime (etaf-runtime-for-buffer buffer)))
              (etaf-dispatch-event runtime 'etaf-desktop-chrome-notes
                                   'drag '(:phase start :delta (0 . 0)) t)
              (etaf-dispatch-event runtime 'etaf-desktop-chrome-notes
                                   'drag '(:phase move :delta (3 . 2)) t)
              (etaf-dispatch-event runtime 'etaf-desktop-chrome-notes
                                   'drag '(:phase move :delta (7 . 4)) t)
              (etaf-dispatch-event runtime 'etaf-desktop-chrome-notes
                                   'drag '(:phase end :delta (10 . 6)) t)))
            (let ((state (etaf-desktop-window-state desktop 'notes)))
              (should (= 10 (plist-get state :x)))
              (should (= 6 (plist-get state :y))))))
      (etaf-desktop-close desktop)))

(ert-deftest etaf-desktop-application-registry-and-lifecycle ()
  "A manifest launches an isolated instance and owns lifecycle callbacks."
  (let* ((app 'etaf-desktop-test-registry)
         (opened nil) (closed nil)
         (desktop (etaf-desktop-create :name " *desktop-app-registry*")))
    (unwind-protect
        (progn
          (etaf-desktop-register-app
           app :title "Registry"
           :capabilities '(multiple-instances resizable)
           :open (lambda (context)
                   (setq opened (plist-get context :instance-id))
                   (list :state '(:counter 1)
                         :windows (list (list :id 'main :title "Registry"
                                              :view (etaf-view (text "Registry"))
                                              :x 3 :y 2 :width 240 :height 8
                                              :min-width 20))))
           :close (lambda (context reason)
                    (setq closed (list (plist-get context :instance-id) reason))))
          (let* ((manifest (etaf-desktop-app app))
                 (instance (etaf-desktop-launch desktop app :options '(:mode test)))
                 (id (plist-get instance :id)))
            (should (equal "Registry" (plist-get manifest :title)))
            (should (equal '(multiple-instances resizable)
                           (plist-get manifest :capabilities)))
            (should (eq 'active (plist-get instance :status)))
            (should (equal id opened))
            (should (equal '(:counter 1)
                           (progn (etaf-desktop-set-instance-state desktop id
                                                                    '(:counter 1))
                                  (plist-get (etaf-desktop-instance desktop id)
                                             :state))))
            ;; Lifecycle state remains observable while controls use public APIs.
            (should (eq 'suspended
                        (plist-get (etaf-desktop-suspend-instance desktop id)
                                   :status)))
            (should (eq 'active
                        (plist-get (etaf-desktop-restore-instance desktop id)
                                   :status)))
            (should (eq 'closed
                        (plist-get (etaf-desktop-close-instance desktop id 'quit)
                                   :status)))
            (should (equal (list id 'quit) closed))))
      (etaf-desktop-unregister-app app t)
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-direct-window-close-syncs-app-lifecycle ()
  "Closing app windows directly keeps instance ownership and lifecycle state exact."
  (let* ((app 'etaf-desktop-test-window-close-sync)
         (closed nil)
         (desktop (etaf-desktop-create :name " *desktop-window-close-sync*")))
    (unwind-protect
        (progn
          (etaf-desktop-register-app
           app :title "Window sync" :capabilities '(multiple-instances)
           :open (lambda (_context)
                   (list :windows
                         (list (list :id 'first :title "First")
                               (list :id 'second :title "Second"))))
           :close (lambda (context reason)
                    (setq closed (list (plist-get context :instance-id) reason))))
          (let* ((instance (etaf-desktop-launch desktop app))
                 (id (plist-get instance :id))
                 (windows (copy-sequence (plist-get instance :windows)))
                 (active (etaf-desktop-active-window desktop)))
            (should (= 2 (length windows)))
            (should (equal (car (last windows)) active))
            ;; Closing the focused second view raises the remaining first view.
            (should (etaf-desktop-close-window desktop active))
            (let ((current (etaf-desktop-instance desktop id)))
              (should (equal (list (car windows)) (plist-get current :windows)))
              (should (eq 'active (plist-get current :status)))
              (should (equal (car windows) (etaf-desktop-active-window desktop))))
            ;; Closing the last view is the app-level close operation.
            (should (etaf-desktop-close-window desktop (car windows)))
            (should (eq 'closed (plist-get (etaf-desktop-instance desktop id)
                                           :status)))
            (should (equal (list id 'window-close) closed))))
      (etaf-desktop-unregister-app app t)
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-inactive-windows-show-gray-traffic-lights ()
  "Only the active window renders the colored macOS traffic lights."
  (let* ((app 'etaf-desktop-test-controls)
         (active-color "#FF5F57")
         (inactive-color "#B7BDC6")
         (desktop (etaf-desktop-create :name " *desktop-controls*"
                                       :canvas-width 80 :canvas-height 16)))
    (unwind-protect
        (progn
          (etaf-desktop-register-app
           app :title "Controls" :capabilities '(multiple-instances)
           :open (lambda (_context)
                   (list :windows
                         (list (list :id 'main :title "Controls"
                                     :view (etaf-view (text "Body"))
                                     :x 1 :y 1 :width 40 :height 6
                                     :min-width 10)))))
          (etaf-desktop-launch desktop app :instance-id "controls-1")
          (etaf-desktop-launch desktop app :instance-id "controls-2")
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer))
                 (colors (lambda ()
                           (cl-loop for (_ref . props) in
                                    (etaf-runtime-host-props-entries runtime)
                                    when (equal "Close" (plist-get props :aria-label))
                                    collect (plist-get props :color)))))
            (let ((first (funcall colors)))
              (should (= 2 (length first)))
              (should (= 1 (cl-count active-color first :test #'equal)))
              (should (= 1 (cl-count inactive-color first :test #'equal))))
            ;; Focusing the other window swaps which lights are colored.
            (let ((other (car (cl-remove-if
                               (lambda (instance)
                                 (equal (etaf-desktop-active-window desktop)
                                        (car (plist-get instance :windows))))
                               (etaf-desktop-instances desktop)))))
              (etaf-desktop-focus-instance desktop (plist-get other :id))
              (let ((second (funcall colors)))
                (should (= 1 (cl-count active-color second :test #'equal)))
                (should (= 1 (cl-count inactive-color second :test #'equal)))))))
      (etaf-desktop-unregister-app app t)
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-application-errors-are-isolated ()
  "A failing application gets an error instance without breaking the desktop."
  (let* ((app 'etaf-desktop-test-failing)
         (desktop (etaf-desktop-create :name " *desktop-app-error*")))
    (unwind-protect
        (progn
          (etaf-desktop-register-app
           app :open (lambda (_context) (error "application boom")))
          (let ((instance (etaf-desktop-launch desktop app)))
            (should (eq 'error (plist-get instance :status)))
            (should (string-match-p "application boom"
                                    (plist-get instance :error)))
            (should (equal 1 (length (etaf-desktop-windows desktop))))
            (etaf-desktop-open-window desktop 'still-usable :title "Still usable")
            (should (etaf-desktop-window-state desktop 'still-usable))))
      (etaf-desktop-unregister-app app t)
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-session-roundtrip-restores-app-state ()
  "Session state uses app callbacks and restores windows without View objects."
  (let* ((app 'etaf-desktop-test-session)
         (desktop (etaf-desktop-create :name " *desktop-session-a*"))
         (restored (etaf-desktop-create :name " *desktop-session-b*"))
         (restore-seen nil))
    (unwind-protect
        (progn
          (etaf-desktop-register-app
           app :title "Session"
           :open (lambda (_context)
                   (list :state '(:counter 7)
                         :windows (list (list :id 'main :title "Session"
                                              :view (etaf-view (text "Session"))
                                              :x 11 :y 4 :width 200 :height 9))))
           :serialize (lambda (context)
                        (list :counter (plist-get (plist-get context :state)
                                                  :counter)))
           :restore (lambda (context data)
                      (setq restore-seen data)
                      (list :state '(:counter 8)
                            :windows (list (list :id 'main :title "Session restored"
                                                 :view (etaf-view (text "Restored")))))))
          (let* ((instance (etaf-desktop-launch desktop app))
                 (id (plist-get instance :id))
                 (session (etaf-desktop-session-state desktop)))
            (etaf-desktop-set-instance-state desktop id '(:counter 7))
            (setq session (etaf-desktop-session-state desktop))
            (etaf-desktop-restore-session restored session)
            (should (equal '(:counter 7) restore-seen))
            (should (equal '(active)
                           (mapcar (lambda (item) (plist-get item :status))
                                   (etaf-desktop-instances restored))))
            (should (= 11 (plist-get
                           (etaf-desktop-window-state restored
                                                       (car (plist-get
                                                             (car (etaf-desktop-instances restored))
                                                             :windows)))
                           :x)))))
      (etaf-desktop-unregister-app app t)
      (etaf-desktop-close desktop)
      (etaf-desktop-close restored))))

(ert-deftest etaf-desktop-session-unknown-app-isolated ()
  "Restoring a session with an unavailable app creates an error placeholder."
  (let ((desktop (etaf-desktop-create :name " *desktop-session-missing*")))
    (unwind-protect
        (progn
          (etaf-desktop-restore-session
           desktop
           '(:version 1
             :desktop (:name "saved" :canvas-width 120 :canvas-height 20
                       :active-workspace main :workspaces (main)
                       :windows ((:id "manual" :title "Manual" :x 5 :y 2
                                  :width 200 :height 6 :min-width 160 :min-height 3
                                  :visible t :movable t :resizable t)))
             :instances ((:id "missing-1" :app-id missing-app :status active
                           :options nil :state nil :data nil :windows nil
                           :window-states nil))))
          (let ((instance (car (etaf-desktop-instances desktop))))
            (should (eq 'error (plist-get instance :status)))
            (should (string-match-p "not registered"
                                    (plist-get instance :error)))
            (should (= 2 (length (etaf-desktop-windows desktop))))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-default-canvas-fills-the-render-window ()
  "A desktop without explicit dimensions fills the window it renders into.

Headless callers keep the selected window as the render target, so the rendered
surface spans that window body: workspace bar, canvas rows and taskbar, with no
row wider than the window.
"
  (let ((app 'etaf-desktop-test-viewport)
        (desktop (etaf-desktop-create :name " *desktop-viewport*")))
    (unwind-protect
        (progn
          (etaf-desktop-register-app
           app :title "Viewport"
           :open (lambda (_context)
                   (list :windows
                         (list (list :id 'main :title "Viewport"
                                     :view (etaf-view (text "Viewport"))
                                     :x 1 :y 1 :width 40 :height 5
                                     :min-width 10)))))
          (etaf-desktop-launch desktop app)
          (let ((buffer (etaf-mount "*desktop-viewport-surface*"
                                    (etaf-desktop-view desktop))))
            (unwind-protect
                (with-current-buffer buffer
                  (let* ((lines (split-string
                                 (buffer-substring-no-properties (point-min) (point-max))
                                 "\n"))
                         (window (selected-window)))
                    ;; Workspace bar + canvas rows + taskbar own the window.
                    (should (= (+ 2 (max 8 (- (window-body-height window) 2)))
                               (length lines)))
                    (should (<= (apply #'max (mapcar #'length lines))
                                (window-body-width window)))))
              (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
                (etaf-unmount runtime)))))
      (etaf-desktop-unregister-app app t)
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-toggle-layout-mode-switches-the-workspace ()
  "The workspace control switches between floating and tiling."
  (let ((desktop (etaf-desktop-create :name " *desktop-toggle*"
                                      :canvas-width 90 :canvas-height 18)))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'one :x 4 :y 3 :width 30 :height 6
                                    :min-width 10 :min-height 2)
          (etaf-desktop-open-window desktop 'two :x 40 :y 8 :width 30 :height 6
                                    :min-width 10 :min-height 2)
          (should (eq 'floating (etaf-desktop-layout-mode desktop)))
          (etaf-desktop-toggle-layout-mode desktop)
          (should (eq 'tiling (etaf-desktop-layout-mode desktop)))
          ;; Tiling reflows the tree across the canvas.
          (should (= 90 (plist-get (etaf-desktop-window-state desktop 'one) :width)))
          (etaf-desktop-toggle-layout-mode desktop)
          (should (eq 'floating (etaf-desktop-layout-mode desktop)))
          ;; Floating keeps the rectangles the layout last applied, and a move
          ;; now persists because the layout no longer reflows the window.
          (should (= 90 (plist-get (etaf-desktop-window-state desktop 'one) :width)))
          (etaf-desktop-move-window desktop 'one 7 5)
          (etaf-desktop-layout-refresh desktop)
          (let ((state (etaf-desktop-window-state desktop 'one)))
            (should (= 7 (plist-get state :x)))
            (should (= 5 (plist-get state :y))))
          ;; Other modes return to floating through the same control.
          (etaf-desktop-set-layout-mode desktop 'master-stack)
          (etaf-desktop-toggle-layout-mode desktop)
          (should (eq 'floating (etaf-desktop-layout-mode desktop))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-shell-controls-and-live-tiling-refresh ()
  "The mounted shell exposes launcher/switcher controls and refreshes tiling on mutation."
  (let ((desktop (etaf-desktop-create :name " *desktop-shell-controls*"
                                      :canvas-width 80 :canvas-height 16
                                      :workspaces '(main dev))))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'one :title "One" :width 20 :height 4
                                    :min-width 5 :min-height 2)
          (etaf-desktop-open-window desktop 'two :title "Two" :width 20 :height 4
                                    :min-width 5 :min-height 2)
          (etaf-desktop-set-layout-mode desktop 'tiling)
          (let ((buffer (etaf-desktop-mount desktop)))
            (should (buffer-live-p buffer))
            (etaf-desktop-toggle-launcher desktop t)
            (should (etaf-desktop-launcher-open-p desktop))
            (with-current-buffer buffer
              (should (string-match-p "Applications" (buffer-string))))
            (etaf-desktop-toggle-switcher desktop t)
            (should (etaf-desktop-switcher-open-p desktop))
            (let ((props (etaf-runtime-host-props-entries
                          (etaf-runtime-for-buffer buffer))))
              (should (cl-some
                       (lambda (entry)
                         (equal "Switch application"
                                (plist-get (cdr entry) :aria-label)))
                       props)))
            (etaf-desktop-open-window desktop 'three :title "Three"
                                      :width 20 :height 4 :min-width 5 :min-height 2)
            (should (= 80 (plist-get (etaf-desktop-window-state desktop 'three)
                                     :width)))
            (should (> (plist-get (etaf-desktop-window-state desktop 'three) :y)
                       (plist-get (etaf-desktop-window-state desktop 'two) :y)))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-settings-modal-overlays-live-shell ()
  "Settings remain application state and open as a retained modal over windows."
  (let ((desktop (etaf-desktop-create :name " *desktop-settings*"
                                      :canvas-width 80 :canvas-height 16)))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'one :title "One"
                                    :view (etaf-view (text "Window content"))
                                    :width 24 :height 5 :min-width 10 :min-height 2)
          (let ((buffer (etaf-desktop-mount desktop)))
            (progn
                  (etaf-desktop-set-setting desktop :theme 'dark)
                  (etaf-desktop-set-setting desktop :title-font-size 16)
                  (etaf-desktop-toggle-settings desktop t)
                  (should (etaf-desktop-settings-open-p desktop))
                  (with-current-buffer buffer
                    ;; The retained desktop remains in the buffer while the
                    ;; dialog is projected on the root layer above it.
                    (should (string-match-p "One" (buffer-string)))
                    (should (string-match-p "Desktop Settings" (buffer-string))))
                  (should (equal 'dark (plist-get (etaf-desktop-settings desktop)
                                                  :theme)))
                  (should (= 16 (plist-get (etaf-desktop-settings desktop)
                                           :title-font-size)))
                  (etaf-desktop-close-settings desktop)
                  (should-not (etaf-desktop-settings-open-p desktop))))
      (etaf-desktop-close desktop)))))

(provide 'etaf-desktop-tests)
;;; etaf-desktop-tests.el ends here
