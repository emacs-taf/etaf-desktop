;;; etaf-desktop-tests.el --- Public desktop application scenarios -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'etaf-desktop)
(require 'etaf)
(require 'ebox)
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

(ert-deftest etaf-desktop-floating-window-overflows-canvas-but-stays-reachable ()
  "A floating window may cross the left, right and bottom canvas edges.
The canvas clips the overflow while part of the window and its title row stay
inside, so a drag past an edge continues instead of failing and the window
can always be grabbed again."
  (let ((desktop (etaf-desktop-create :name " *desktop-overflow*"
                                      :canvas-width 300 :canvas-height 20)))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'notes :x 10 :y 2 :width 200 :height 6
                                    :min-width 40 :min-height 2)
          (let ((moved (etaf-desktop-move-window desktop 'notes -120 3)))
            (should (= -120 (plist-get moved :x)))
            (should (= 3 (plist-get moved :y))))
          ;; The window never leaves the canvas entirely.
          (let ((moved (etaf-desktop-move-window desktop 'notes -190 60)))
            (should (= -152 (plist-get moved :x)))
            (should (= 19 (plist-get moved :y))))
          (let ((moved (etaf-desktop-move-window desktop 'notes 400 -5)))
            (should (= 252 (plist-get moved :x)))
            (should (= 0 (plist-get moved :y))))
          (should-error (etaf-desktop-move-window desktop 'notes 1.5 0)
                        :type 'etaf-desktop-error)
          ;; The clipped window still renders inside the canvas rows.
          (let ((buffer (etaf-desktop-mount desktop)))
            (unwind-protect
                (progn
                  (etaf-desktop-move-window desktop 'notes -100 2)
                  (with-current-buffer buffer
                    (should (string-match-p "notes" (buffer-string)))
                    (should (= 22 (count-lines (point-min) (point-max)))))
                  (etaf-desktop-move-window desktop 'notes 250 15)
                  (with-current-buffer buffer
                    (should (= 22 (count-lines (point-min) (point-max))))))
              (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
                (etaf-unmount runtime)))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-minimize-and-workspace-removal-preserve-focus ()
  "Minimizing or removing the active workspace selects a visible replacement."
  (let ((desktop (etaf-desktop-create :name " *desktop-focus-fallback*"
                                      :workspaces '(main second)
                                      :canvas-width 100 :canvas-height 20)))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'one :workspace 'main)
          (etaf-desktop-open-window desktop 'two :workspace 'second)
          (etaf-desktop-switch-workspace desktop 'main)
          (etaf-desktop-minimize-window desktop 'one)
          (should-not (etaf-desktop-active-window desktop))
          (etaf-desktop-restore-window desktop 'one)
          (etaf-desktop-open-window desktop 'three :workspace 'main)
          (etaf-desktop-minimize-window desktop 'three)
          (should (eq 'one (etaf-desktop-active-window desktop)))
          (etaf-desktop-restore-window desktop 'three)
          (etaf-desktop-switch-workspace desktop 'second)
          (etaf-desktop-remove-workspace desktop 'second)
          (should (eq 'main (etaf-desktop-active-workspace desktop)))
          (should (etaf-desktop-active-window desktop)))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-tiling-minimize-reflows-visible-leaves ()
  "A minimized tiled window leaves no blank tile until it is restored."
  (let ((desktop (etaf-desktop-create :name " *desktop-minimized-tile*"
                                      :canvas-width 100 :canvas-height 20)))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'one :min-width 10 :min-height 2)
          (etaf-desktop-open-window desktop 'two :min-width 10 :min-height 2)
          (etaf-desktop-set-layout-mode desktop 'tiling)
          (etaf-desktop-minimize-window desktop 'two)
          (should-not (member 'two
                              (flatten-tree (etaf-desktop-layout-tree desktop))))
          (let ((window (etaf-desktop-window-state desktop 'one)))
            (should (= 1 (plist-get window :y)))
            (should (= 18 (plist-get window :height))))
          (etaf-desktop-restore-window desktop 'two)
          (should (member 'two
                          (flatten-tree (etaf-desktop-layout-tree desktop)))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-maximize-in-tiling-keeps-full-geometry ()
  "Maximizing a tiled window keeps the canvas rectangle until restore."
  (let ((desktop (etaf-desktop-create :name " *desktop-maximize-tile*"
                                      :canvas-width 100 :canvas-height 20)))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'one :min-width 10 :min-height 2)
          (etaf-desktop-open-window desktop 'two :min-width 10 :min-height 2)
          (etaf-desktop-set-layout-mode desktop 'tiling)
          (etaf-desktop-maximize-window desktop 'two)
          (let ((state (etaf-desktop-window-state desktop 'two)))
            (should (plist-get state :maximized))
            (should (= 100 (plist-get state :width)))
            (should (= 20 (plist-get state :height))))
          (etaf-desktop-open-window desktop 'three
                                    :min-width 10 :min-height 2)
          (should (member 'three
                          (flatten-tree (etaf-desktop-layout-tree desktop))))
          (should (equal '(two 0 0 100 20)
                         (assq 'two (etaf-desktop-layout-apply desktop))))
          (should (= 100 (plist-get (etaf-desktop-window-state desktop 'two)
                                    :width)))
          (etaf-desktop-restore-window desktop 'two)
          (should-not (plist-get (etaf-desktop-window-state desktop 'two)
                                 :maximized))
          (etaf-desktop-set-layout-mode desktop 'master-stack)
          (etaf-desktop-maximize-window desktop 'one)
          (should (= 100 (plist-get (etaf-desktop-window-state desktop 'one)
                                    :width)))
          (etaf-desktop-restore-window desktop 'one))
      (etaf-desktop-close desktop))))

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

(ert-deftest etaf-desktop-bars-follow-focus-and-membership ()
  "Focus updates bar selection and status across window lifecycle changes."
  (let ((desktop (etaf-desktop-create :name " *desktop-bar-focus*"
                                      :canvas-width 400 :canvas-height 12)))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'notes :title "Notes")
          (etaf-desktop-open-window desktop 'files :title "Files")
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer))
                 (notes
                  (car (cl-find-if
                        (lambda (entry)
                          (and (equal "Notes" (plist-get (cdr entry) :aria-label))
                               (string-match-p "etaf-taskbar-item"
                                               (or (plist-get (cdr entry) :class) ""))))
                        (etaf-runtime-host-props-entries runtime)))))
            (should notes)
            (etaf-desktop-focus-window desktop 'notes)
            (should (string-match-p
                     "active" (plist-get (etaf-runtime-host-props-for runtime notes) :class)))
            (with-current-buffer buffer
              (save-excursion
                (goto-char (point-min))
                (should (string-match-p
                         "Notes" (buffer-substring-no-properties (point) (line-end-position))))))
            (etaf-desktop-focus-window desktop 'files)
            (should-not (string-match-p
                         "active" (plist-get (etaf-runtime-host-props-for runtime notes) :class)))
            (with-current-buffer buffer
              (save-excursion
                (goto-char (point-min))
                (should (string-match-p
                         "Files" (buffer-substring-no-properties (point) (line-end-position))))))
            (etaf-desktop-minimize-window desktop 'notes)
            (should (string-match-p
                     "minimized" (plist-get (etaf-runtime-host-props-for runtime notes) :class)))
            (etaf-dispatch-event runtime notes 'press)
            (should (eq 'notes (etaf-desktop-active-window desktop)))
            (should-not (plist-get (etaf-desktop-window-state desktop 'notes) :minimized))
            (etaf-desktop-close-window desktop 'files)
            (should (etaf-host-ref-position runtime notes))
            (should (string-match-p
                     "active" (plist-get (etaf-runtime-host-props-for runtime notes) :class)))))
      (etaf-desktop-close desktop))))

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

(ert-deftest etaf-desktop-view-direct-mount-resolves-current-runtime-for-gestures ()
  "A View mounted directly by a consumer still routes gestures to its Runtime."
  (let* ((desktop (etaf-desktop-create :name " *desktop-direct-gesture*"))
         (target (get-buffer-create " *desktop-direct-gesture-target*")))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'notes :x 2 :y 1)
          (etaf-mount target (etaf-desktop-view desktop))
          (let ((runtime (etaf-runtime-for-buffer target)))
            (etaf-dispatch-event
             runtime 'etaf-desktop-chrome-notes 'drag
             '(:phase start :delta (0 . 0)) t)
            (etaf-dispatch-event
             runtime 'etaf-desktop-chrome-notes 'drag
             '(:phase end :delta (8 . 1)) t)
            (should (= 10 (plist-get
                           (etaf-desktop-window-state desktop 'notes) :x)))))
      (when-let* ((runtime (etaf-runtime-for-buffer target)))
        (etaf-unmount runtime))
      (when (buffer-live-p target) (kill-buffer target))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-close-preserves-caller-owned-runtime-and-buffer ()
  "Closing a direct View does not unmount its caller's Runtime or buffer."
  (let* ((desktop (etaf-desktop-create :name " *desktop-owned-buffer*"))
         (buffer (get-buffer-create " *desktop-caller-buffer*")))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'notes :x 2 :y 1)
          (etaf-mount buffer (etaf-desktop-view desktop))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-desktop-close desktop)
            (should (buffer-live-p buffer))
            (should (eq runtime (etaf-runtime-for-buffer buffer)))
            (etaf-dispatch-event runtime 'etaf-desktop-chrome-notes 'drag
                                 '(:phase start :delta (0 . 0)) t)
            (etaf-dispatch-event runtime 'etaf-desktop-chrome-notes 'drag
                                 '(:phase end :delta (8 . 1)) t)
            (should (= 10 (plist-get
                           (etaf-desktop-window-state desktop 'notes) :x)))
            (etaf-unmount runtime)
            (should-not (etaf-runtime-for-buffer buffer)))
          ;; A convenience mount also borrows an existing caller buffer while
          ;; owning the Runtime it creates there.
          (etaf-desktop-mount desktop buffer)
          (etaf-desktop-close desktop)
          (should (buffer-live-p buffer))
          (should-not (etaf-runtime-for-buffer buffer)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

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

(ert-deftest etaf-desktop-instance-status-follows-visible-focus ()
  "An app with windows elsewhere is inactive when focus leaves its workspace."
  (let* ((app 'etaf-desktop-test-focus-status)
         (desktop (etaf-desktop-create :name " *desktop-app-focus*"
                                       :workspaces '(main dev empty))))
    (unwind-protect
        (progn
          (etaf-desktop-register-app
           app :title "Focus status"
           :open (lambda (_context)
                   (list :windows
                         (list (list :id 'main :workspace 'main :title "Main")
                               (list :id 'dev :workspace 'dev :title "Dev")))))
          (let* ((instance (etaf-desktop-launch desktop app))
                 (id (plist-get instance :id))
                 (main-window (car (plist-get instance :windows))))
            (etaf-desktop-switch-workspace desktop 'main)
            (should (eq 'active
                        (plist-get (etaf-desktop-instance desktop id) :status)))
            (etaf-desktop-minimize-window desktop main-window)
            (should-not (etaf-desktop-active-window desktop))
            (should (eq 'inactive
                        (plist-get (etaf-desktop-instance desktop id) :status)))
            (etaf-desktop-switch-workspace desktop 'dev)
            (should (eq 'active
                        (plist-get (etaf-desktop-instance desktop id) :status)))
            (etaf-desktop-switch-workspace desktop 'empty)
            (should-not (etaf-desktop-active-window desktop))
            (should (eq 'inactive
                        (plist-get (etaf-desktop-instance desktop id) :status)))
            (etaf-desktop-restore-window desktop main-window)
            (should (eq 'active
                        (plist-get (etaf-desktop-instance desktop id) :status)))
            (etaf-desktop-close-window desktop main-window)
            (should-not (etaf-desktop-active-window desktop))
            (should (eq 'inactive
                        (plist-get (etaf-desktop-instance desktop id) :status)))))
      (etaf-desktop-unregister-app app t)
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-launch-cleans-partial-window-creation ()
  "A failed multi-window launch leaves only its isolated error placeholder."
  (let* ((app 'etaf-desktop-test-partial-launch)
         (desktop (etaf-desktop-create :name " *desktop-partial-launch*")))
    (unwind-protect
        (progn
          (etaf-desktop-register-app
           app :title "Partial" :capabilities '(multiple-instances)
           :open (lambda (_context)
                   (list :windows
                         (list (list :id 'first :title "First" :width 220)
                               (list :id 'broken :width 1 :min-width 20)))))
          (let* ((instance (etaf-desktop-launch desktop app))
                 (id (plist-get instance :id))
                 (windows (etaf-desktop-windows desktop)))
            (should (eq 'error (plist-get instance :status)))
            (should (= 1 (length (plist-get instance :windows))))
            (should (string-match-p "error" (format "%s" (car (plist-get instance :windows)))))
            (should (= 1 (length windows)))
            (should (equal (plist-get instance :windows)
                           (mapcar (lambda (window) (plist-get window :id)) windows)))
            (should (eq 'error (plist-get (etaf-desktop-instance desktop id) :status)))))
      (etaf-desktop-unregister-app app t)
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-inactive-windows-show-gray-traffic-lights ()
  "Only the active window renders the colored macOS traffic lights."
  (let* ((app 'etaf-desktop-test-controls)
         (active-color "#FF5F57")
         (desktop (etaf-desktop-create :name " *desktop-controls*"
                                       :canvas-width 80 :canvas-height 16))
         (inactive-color
          (plist-get (etaf-desktop-theme-tokens
                      (plist-get (etaf-desktop-settings desktop) :theme))
                     :ui-window-title-fg)))
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
                                    collect (let ((color (plist-get props :color)))
                                              ;; Theme-bound colors publish
                                              ;; through retained paint slots.
                                              (if (ebox-paint-slot-p color)
                                                  (plist-get (ebox-paint-slot-spec color)
                                                             :foreground)
                                                color))))))
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

(ert-deftest etaf-desktop-session-roundtrip-restores-layout-policy ()
  "Session restore keeps each workspace's tiling tree and split ratios."
  (let* ((desktop (etaf-desktop-create :name " *desktop-layout-session-a*"
                                       :canvas-width 120 :canvas-height 24
                                       :workspaces '(main second)))
         (restored (etaf-desktop-create :name " *desktop-layout-session-b*"
                                        :canvas-width 120 :canvas-height 24)))
    (unwind-protect
        (progn
          (dolist (id '(one two three))
            (etaf-desktop-open-window
             desktop id :title (format "%s" id)
             :view (etaf-view (text (expr (format "%s" id))))
             :workspace 'main :min-width 10 :min-height 3))
          (etaf-desktop-set-layout-mode desktop 'tiling 'main)
          (etaf-desktop-layout-split desktop 'one 'two 'horizontal 0.7 'main)
          (etaf-desktop-layout-split desktop 'two 'three 'vertical 0.4 'main)
          ;; Give the second workspace an independent policy to prove that
          ;; restoration does not collapse per-workspace state into one mode.
          (etaf-desktop-open-window
           desktop 'other :title "Other"
           :view (etaf-view (text "Other")) :workspace 'second
           :min-width 10 :min-height 3)
          (etaf-desktop-set-layout-mode desktop 'tiling 'second)
          (let* ((session (etaf-desktop-session-state desktop))
                 (layouts (plist-get session :layouts))
                 (main-layout (cl-find 'main layouts :key (lambda (item)
                                                            (plist-get item :workspace))))
                 (main-tree (plist-get main-layout :tree)))
            (should (equal 'tiling (plist-get main-layout :mode)))
            (should (equal 'horizontal (nth 1 main-tree)))
            (etaf-desktop-restore-session restored session)
            (should (equal main-tree (etaf-desktop-layout-tree restored 'main)))
            (should (eq 'tiling (etaf-desktop-layout-mode restored 'main)))
            (should (eq 'tiling (etaf-desktop-layout-mode restored 'second)))
            (should (= (plist-get (etaf-desktop-window-state restored 'one) :width)
                       (plist-get (etaf-desktop-window-state desktop 'one) :width)))))
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

(ert-deftest etaf-desktop-canvas-follows-window-resize ()
  "A default desktop refits its canvas when its Emacs window changes size.

Shrinking the window reflows tiles, refills a maximized window and pulls a
floating window back inside the canvas; growing it again restores the full
shell without a structural re-render."
  (let ((desktop (etaf-desktop-create :name " *desktop-resize*"
                                      :workspaces '(main float))))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'one :x 0 :y 0 :width 200 :height 4
                                    :min-width 20 :min-height 2)
          (etaf-desktop-open-window desktop 'two :x 0 :y 0 :width 200 :height 4
                                    :min-width 20 :min-height 2)
          (etaf-desktop-open-window desktop 'float :x 5 :y 40 :width 200 :height 4
                                    :min-width 20 :min-height 2 :workspace 'float)
          (etaf-desktop-set-layout-mode desktop 'tiling 'main)
          (let ((buffer (etaf-mount "*desktop-resize-surface*"
                                    (etaf-desktop-view desktop)))
                (window (selected-window)))
            (delete-other-windows window)
            (set-window-buffer window buffer)
            (unwind-protect
                (let* ((lines (lambda ()
                                (with-current-buffer buffer
                                  (split-string (buffer-substring-no-properties
                                                 (point-min) (point-max))
                                                "\n"))))
                       (canvas-height (lambda ()
                                        (max 8 (- (window-body-height window) 2))))
                       (full (funcall canvas-height)))
                  ;; Nothing changes while the window keeps its size.
                  (should (etaf-desktop-fit-canvas desktop))
                  (should-not (etaf-desktop-fit-canvas desktop))
                  (should (= full (plist-get (etaf-desktop-state desktop)
                                             :canvas-height)))
                  (etaf-desktop-maximize-window desktop 'two)
                  (should (= full (plist-get (etaf-desktop-window-state desktop 'two)
                                             :height)))
                  ;; Shrinking the window reflows the tiled workspace.
                  (let ((other (split-window window)))
                    (unwind-protect
                        (let ((small (funcall canvas-height)))
                          (should (< small full))
                          (should (equal (cons (plist-get (etaf-desktop-state desktop)
                                                          :canvas-width)
                                               small)
                                         (etaf-desktop-fit-canvas desktop)))
                          (should (= small (plist-get (etaf-desktop-state desktop)
                                                      :canvas-height)))
                          (should (= (+ small 2) (length (funcall lines))))
                          (should (= small
                                     (plist-get (etaf-desktop-window-state desktop 'two)
                                                :height)))
                          (let ((one (etaf-desktop-window-state desktop 'one)))
                            (should (<= (+ (plist-get one :y) (plist-get one :height))
                                        small)))
                          ;; A floating window whose title row lies beyond the
                          ;; new canvas is pulled back onto it when its
                          ;; workspace becomes active; overflow below stays.
                          (etaf-desktop-switch-workspace desktop 'float)
                          (delete-window other)
                          (should (etaf-desktop-fit-canvas desktop))
                          (should (= full (plist-get (etaf-desktop-state desktop)
                                                     :canvas-height)))
                          (should (= (+ full 2) (length (funcall lines))))
                          (let ((float (etaf-desktop-window-state desktop 'float)))
                            (should (< (plist-get float :y) full))
                            (should (= 4 (plist-get float :height)))))
                      (when (window-live-p other) (delete-window other)))))
              (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
                (etaf-unmount runtime)))))
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
          ;; Tiling reflows the tree inside the default outer margin.
          (should (= (- 90 (* 2 (frame-char-width)))
                     (plist-get (etaf-desktop-window-state desktop 'one) :width)))
          (etaf-desktop-toggle-layout-mode desktop)
          (should (eq 'floating (etaf-desktop-layout-mode desktop)))
          ;; Floating keeps the rectangles the layout last applied, and a move
          ;; now persists because the layout no longer reflows the window.
          (should (= (- 90 (* 2 (frame-char-width)))
                     (plist-get (etaf-desktop-window-state desktop 'one) :width)))
          (etaf-desktop-move-window desktop 'one 7 5)
          (etaf-desktop-layout-refresh desktop)
          (let ((state (etaf-desktop-window-state desktop 'one)))
            (should (= 7 (plist-get state :x)))
            (should (= 5 (plist-get state :y))))
          ;; Other modes return to tiling through the same control.
          (etaf-desktop-set-layout-mode desktop 'master-stack)
          (etaf-desktop-toggle-layout-mode desktop)
          (should (eq 'tiling (etaf-desktop-layout-mode desktop))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-mounted-layout-toggle-rerenders-both-directions ()
  "The mounted Floating/Tiled control stays live and publishes without re-render."
  (let ((desktop (etaf-desktop-create :name " *desktop-toggle-mounted*"
                                      :canvas-width 360 :canvas-height 16
                                      :workspaces '(main dev))))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'one :title "One")
          (etaf-desktop-open-window desktop 'two :title "Two")
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer))
                 (label-visible-p
                  (lambda (label)
                    (with-current-buffer buffer
                      (string-match-p (regexp-quote label) (buffer-string))))))
            (should (funcall label-visible-p "Floating"))
            (should-not (funcall label-visible-p "Tiled"))
            ;; The first tiling of two windows allocates a divider node.
            (etaf-dispatch-event runtime 'etaf-workspace-layout 'press)
            (should (eq 'tiling (etaf-desktop-layout-mode desktop)))
            (should (funcall label-visible-p "Tiled"))
            (should-not (funcall label-visible-p "Floating"))
            ;; Later toggles rewrite retained cells only: the runtime
            ;; generation, and so every prepared cohort, stays the same.
            (let ((generation (etaf-runtime-current-generation runtime)))
              (etaf-dispatch-event runtime 'etaf-workspace-layout 'press)
              (should (eq 'floating (etaf-desktop-layout-mode desktop)))
              (should (eq generation (etaf-runtime-current-generation runtime)))
              (should (funcall label-visible-p "Floating"))
              (should-not (funcall label-visible-p "Tiled"))
              (etaf-dispatch-event runtime 'etaf-workspace-layout 'press)
              (should (eq 'tiling (etaf-desktop-layout-mode desktop)))
              (should (eq generation (etaf-runtime-current-generation runtime)))
              (should (funcall label-visible-p "Tiled"))
              (should (= 2 (length (etaf-desktop-layout-apply desktop)))))
            ;; The label follows the active workspace, whose mode is its own.
            (etaf-desktop-switch-workspace desktop 'dev)
            (should (funcall label-visible-p "Floating"))
            (should-not (funcall label-visible-p "Tiled"))
            (etaf-desktop-set-layout-mode desktop 'tiling 'main)
            (should (funcall label-visible-p "Floating"))
            (etaf-desktop-switch-workspace desktop 'main)
            (should (funcall label-visible-p "Tiled"))
            (should-not (funcall label-visible-p "Floating"))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-settings-layout-select-follows-workspace-mode ()
  "The Layout tab shows the active workspace's live mode, not a stale preference."
  (let ((desktop (etaf-desktop-create :name " *desktop-settings-layout*"
                                      :canvas-width 360 :canvas-height 24
                                      :workspaces '(main dev))))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'one :title "One")
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer))
                 (select-shows-p
                  (lambda (label)
                    (with-current-buffer buffer
                      (string-match-p (concat "Window layout +" (regexp-quote label))
                                      (buffer-string))))))
            (etaf-desktop-toggle-settings desktop t)
            (etaf-dispatch-event runtime 'settings-tab-layout 'press)
            (should (funcall select-shows-p "Floating"))
            ;; The `l' shortcut and the bar control both go through the
            ;; layout API rather than the settings ref.
            (etaf-desktop-toggle-layout-mode desktop)
            (should (eq 'tiling (etaf-desktop-layout-mode desktop)))
            (should (etaf-desktop-settings-open-p desktop))
            (should (funcall select-shows-p "Tiling"))
            (etaf-desktop-set-layout-mode desktop 'monocle)
            (should (funcall select-shows-p "Monocle"))
            (etaf-desktop-switch-workspace desktop 'dev)
            (should (funcall select-shows-p "Floating"))
            (should (equal 'floating
                           (plist-get (etaf-desktop-settings desktop) :layout-mode)))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-mounted-workspace-switch-is-retained ()
  "Switching workspaces hides and shows windows without a structural publish."
  (let ((desktop (etaf-desktop-create :name " *desktop-switch-mounted*"
                                      :canvas-width 360 :canvas-height 16
                                      :workspaces '(main dev))))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'one :title "One"
                                    :view (etaf-view (text "Main body one"))
                                    :min-width 10 :min-height 2)
          (etaf-desktop-open-window desktop 'two :title "Two"
                                    :view (etaf-view (text "Main body two"))
                                    :min-width 10 :min-height 2)
          (etaf-desktop-switch-workspace desktop 'dev)
          (etaf-desktop-open-window desktop 'three :title "Three"
                                    :view (etaf-view (text "Dev body three"))
                                    :min-width 10 :min-height 2)
          (etaf-desktop-switch-workspace desktop 'main)
          (etaf-desktop-set-layout-mode desktop 'tiling 'main)
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer))
                 (visible-p
                  (lambda (text)
                    (with-current-buffer buffer
                      (string-match-p (regexp-quote text) (buffer-string)))))
                 (generation (etaf-runtime-current-generation runtime)))
            (should (funcall visible-p "Main body one"))
            (should (funcall visible-p "Main body two"))
            (should-not (funcall visible-p "Dev body three"))
            ;; The taskbar lists every workspace's windows.
            (should (funcall visible-p "Three"))
            (etaf-desktop-switch-workspace desktop 'dev)
            (should (eq generation (etaf-runtime-current-generation runtime)))
            (should (eq 'dev (etaf-desktop-active-workspace desktop)))
            (should (eq 'three (etaf-desktop-active-window desktop)))
            (should (funcall visible-p "Dev body three"))
            (should-not (funcall visible-p "Main body one"))
            (should-not (funcall visible-p "Main body two"))
            (should (funcall visible-p "Floating"))
            (etaf-desktop-switch-workspace desktop 'main)
            (should (eq generation (etaf-runtime-current-generation runtime)))
            (should (eq 'two (etaf-desktop-active-window desktop)))
            (should (funcall visible-p "Main body one"))
            (should (funcall visible-p "Main body two"))
            (should-not (funcall visible-p "Dev body three"))
            (should (funcall visible-p "Tiled"))
            ;; Focusing a window of another workspace switches to it retained.
            (etaf-desktop-focus-window desktop 'three)
            (should (eq generation (etaf-runtime-current-generation runtime)))
            (should (eq 'dev (etaf-desktop-active-workspace desktop)))
            (should (funcall visible-p "Dev body three"))
            (should-not (funcall visible-p "Main body two"))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-mode-switch-reveals-tiles-after-maximize ()
  "Switching from a maximized floating view reveals every tiled window."
  (let ((desktop (etaf-desktop-create :name " *desktop-maximized-toggle*"
                                      :canvas-width 360 :canvas-height 16)))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'one :title "One"
                                    :view (etaf-view (text "First tile body"))
                                    :min-width 10 :min-height 2)
          (etaf-desktop-open-window desktop 'two :title "Two"
                                    :view (etaf-view (text "Second tile body"))
                                    :min-width 10 :min-height 2)
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer)))
            (etaf-desktop-maximize-window desktop 'two)
            (etaf-dispatch-event runtime 'etaf-workspace-layout 'press)
            (should (eq 'tiling (etaf-desktop-layout-mode desktop)))
            (should-not (etaf-desktop-window-maximized-p desktop 'two))
            (with-current-buffer buffer
              (should (string-match-p "First tile body" (buffer-string)))
              (should (string-match-p "Second tile body" (buffer-string))))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-close-tiled-window-keeps-other-workspace-isolated ()
  "Closing a tile cannot show an error placeholder from another workspace."
  (let* ((app 'etaf-desktop-test-isolated-error)
         (desktop (etaf-desktop-create :name " *desktop-isolated-tile*"
                                       :canvas-width 360 :canvas-height 16
                                       :workspaces '(main dev))))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'notes :title "Notes"
                                    :view (etaf-view (text "Notes body"))
                                    :min-width 10 :min-height 2)
          (etaf-desktop-open-window desktop 'files :title "Files"
                                    :view (etaf-view (text "Files body"))
                                    :min-width 10 :min-height 2)
          (etaf-desktop-open-window desktop 'chat :title "Chat"
                                    :view (etaf-view (text "Chat body"))
                                    :workspace 'dev :min-width 10 :min-height 2)
          (etaf-desktop-register-app
           app :title "Broken"
           :open (lambda (_context) (error "isolated launch failure")))
          (let* ((buffer (etaf-desktop-mount desktop))
                 (instance (progn
                             (etaf-desktop-switch-workspace desktop 'dev)
                             (etaf-desktop-launch desktop app)))
                 (error-window (car (plist-get instance :windows))))
            (should (eq 'dev (plist-get
                              (etaf-desktop-window-state desktop error-window)
                              :workspace)))
            (etaf-desktop-switch-workspace desktop 'main)
            (etaf-desktop-maximize-window desktop 'notes)
            (etaf-desktop-set-layout-mode desktop 'tiling)
            (etaf-desktop-layout-resize-split desktop nil 0.6)
            (etaf-desktop-focus-window desktop 'files)
            (etaf-desktop-toggle-layout-mode desktop)
            (etaf-desktop-toggle-layout-mode desktop)
            (etaf-desktop-focus-window desktop 'notes)
            (etaf-desktop-close-window desktop 'notes)
            (should (eq 'main (etaf-desktop-active-workspace desktop)))
            (should (equal 'files (etaf-desktop-active-window desktop)))
            (should (equal '(:leaf files)
                           (etaf-desktop-layout-tree desktop)))
            (with-current-buffer buffer
              (should (string-match-p "Files body" (buffer-string)))
              (should-not (string-match-p "Notes body" (buffer-string)))
              (should-not (string-match-p "isolated launch failure"
                                          (buffer-string))))
            (etaf-desktop-switch-workspace desktop 'dev)
            (with-current-buffer buffer
              (should (string-match-p "isolated launch failure"
                                      (buffer-string)))
              (should-not (string-match-p "Files body" (buffer-string))))
            (etaf-desktop-switch-workspace desktop 'main)
            (with-current-buffer buffer
              (should (string-match-p "Files body" (buffer-string)))
              (should-not (string-match-p "isolated launch failure"
                                          (buffer-string))))))
      (etaf-desktop-unregister-app app t)
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-tiled-error-window-keeps-title-visible ()
  "An error placeholder joining a tiled workspace keeps its title row."
  (let* ((app 'etaf-desktop-test-tiled-error)
         (desktop (etaf-desktop-create :name " *desktop-tiled-error*"
                                       :canvas-width 600 :canvas-height 20)))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'files :title "Files"
                                    :view (etaf-view (text "Files body"))
                                    :min-width 10 :min-height 2)
          (etaf-desktop-register-app
           app :title "Broken"
           :open (lambda (_context) (error "visible failure body")))
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer)))
            (etaf-desktop-set-layout-mode desktop 'tiling)
            (let* ((instance (etaf-desktop-launch desktop app))
                   (id (car (plist-get instance :windows)))
                   (files (etaf-desktop-window-state desktop 'files))
                   (error-window (etaf-desktop-window-state desktop id))
                   (chrome (intern (format "etaf-desktop-chrome-%s" id)))
                   (position (etaf-host-ref-position runtime chrome)))
              (should (= (1+ (+ (plist-get files :y)
                                (plist-get files :height)))
                         (plist-get error-window :y)))
              (should position)
              (with-current-buffer buffer
                (should (string-match-p "visible failure body" (buffer-string)))
                (save-excursion
                  (goto-char position)
                  (should (string-match-p
                           "ETAF app error"
                           (buffer-substring-no-properties
                            (line-beginning-position) (line-end-position)))))))))
      (etaf-desktop-unregister-app app t)
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
            (let ((window (etaf-desktop-window-state desktop 'three)))
              (should (= (frame-char-width) (plist-get window :x)))
              (should (= (- 80 (* 2 (frame-char-width)))
                         (plist-get window :width))))
            (should (> (plist-get (etaf-desktop-window-state desktop 'three) :y)
                       (plist-get (etaf-desktop-window-state desktop 'two) :y)))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-presses-outside-a-modal-dismiss-it ()
  "Pressing a window control or the shell closes the open modal; the taskbar swaps it."
  (let ((desktop (etaf-desktop-create :name " *desktop-outside-press*"
                                      :canvas-width 240 :canvas-height 16))
        (pressed 0))
    (unwind-protect
        (progn
          (etaf-desktop-open-window
           desktop 'one :title "One"
           :view (etaf-view (etaf-button :ref 'probe :label "Probe"
                                         :on-press (lambda () (cl-incf pressed))))
           :width 60 :height 6 :min-width 10 :min-height 2)
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer)))
            (etaf-desktop-toggle-launcher desktop t)
            (should (etaf-desktop-launcher-open-p desktop))
            (etaf-dispatch-event runtime 'probe 'press)
            (should (= pressed 1))
            (should-not (etaf-desktop-launcher-open-p desktop))
            (etaf-desktop-toggle-settings desktop t)
            (should (etaf-desktop-settings-open-p desktop))
            (etaf-dispatch-event runtime 'etaf-taskbar-launcher 'press)
            (should-not (etaf-desktop-settings-open-p desktop))
            (should (etaf-desktop-launcher-open-p desktop))
            (etaf-dispatch-event runtime 'etaf-taskbar-launcher 'press)
            (should-not (etaf-desktop-launcher-open-p desktop))
            (etaf-desktop-toggle-switcher desktop t)
            (etaf-dispatch-event runtime 'probe 'press)
            (should (= pressed 2))
            (should-not (etaf-desktop-switcher-open-p desktop))
            (with-current-buffer buffer
              (should-not (string-match-p "Switch application" (buffer-string))))))
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

(ert-deftest etaf-desktop-geometry-queries-stay-reactive-and-atomic ()
  "Public snapshots observe complete geometry and focus after floating mutations."
  (let ((desktop (etaf-desktop-create :canvas-width 240 :canvas-height 24))
        (scope (etaf-effect-scope :detached t))
        observed)
    (unwind-protect
        (progn
          (dolist (id '(one two))
            (etaf-desktop-open-window desktop id :width 40 :height 6
                                      :min-width 10 :min-height 2))
          (etaf-scope-run
           scope
           (lambda ()
             (etaf-watch
              (lambda ()
                (let ((window (etaf-desktop-window-state desktop 'one)))
                  (list (plist-get window :x) (plist-get window :y)
                        (plist-get window :width) (plist-get window :height)
                        (etaf-desktop-active-window desktop))))
              (lambda (next _previous) (push next observed))
              :flush 'sync)))
          (etaf-desktop-move-window desktop 'one 7 3)
          (should observed)
          (should (cl-every (lambda (value) (equal '(7 3 40 6 one) value)) observed))
          (setq observed nil)
          (etaf-desktop-resize-window desktop 'one 60 9)
          (should observed)
          (should (cl-every (lambda (value) (equal '(7 3 60 9 one) value)) observed))
          (let ((snapshot (etaf-desktop-window-state desktop 'one)))
            (should-error (etaf-desktop-move-window desktop 'one 1.5 2)
                          :type 'etaf-desktop-error)
            (should (equal snapshot (etaf-desktop-window-state desktop 'one)))))
      (etaf-scope-stop scope)
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-mounted-geometry-survives-membership-and-settings ()
  "Live geometry and nested input remain usable across structural publications."
  (let ((desktop (etaf-desktop-create :name " *desktop-live-geometry*"
                                      :canvas-width 400 :canvas-height 24))
        (draft (etaf-ref "initial")))
    (unwind-protect
        (progn
          (etaf-desktop-open-window
           desktop 'editor :width 180 :height 8 :min-width 20 :min-height 3
           :view (etaf-view (etaf-text-input :ref 'editor-input
                                           :label "Draft" :bind draft)))
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer))
                 (before (etaf-desktop-window-state desktop 'editor)))
            (dolist (position '((5 2) (9 4)))
              (etaf-desktop-move-window desktop 'editor (car position) (cadr position))
              (etaf-desktop-resize-window desktop 'editor 200 10)
              (let ((props (etaf-runtime-host-props-for
                            runtime 'etaf-desktop-window-editor)))
                (should (equal (list 'px (car position)) (plist-get props :left)))
                (should (equal (list 'lh (cadr position)) (plist-get props :top)))
                (should (equal '(px 200) (plist-get props :width)))
                (should (equal '(lh 10) (plist-get props :height))))
              (etaf-desktop-open-window desktop 'peer :min-width 10 :min-height 2)
              (etaf-desktop-close-window desktop 'peer)
              (etaf-desktop-set-setting desktop :theme 'dark))
            (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "edited")))
              (etaf-dispatch-event runtime 'editor-input 'press))
            (should (equal "edited" (etaf-value draft)))
            (should (etaf-host-ref-position runtime 'editor-input))
            (should (= 0 (plist-get before :x) (plist-get before :y)))
            (should (= 180 (plist-get before :width)))
            (should (= 8 (plist-get before :height)))
            (should (equal '(0 0 180 8) (plist-get before :normal-geometry)))
            (should (equal '(9 4 200 10)
                           (plist-get (etaf-desktop-window-state desktop 'editor)
                                      :normal-geometry)))))
      (etaf-desktop-close desktop))))

(provide 'etaf-desktop-tests)
;;; etaf-desktop-tests.el ends here
