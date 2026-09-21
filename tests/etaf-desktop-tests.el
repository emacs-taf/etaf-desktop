;;; etaf-desktop-tests.el --- Public desktop application scenarios -*- lexical-binding: t; -*-

(require 'ert)
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
  (let ((desktop (etaf-desktop-create :name " *desktop-test*")))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'notes :title "Notes"
                                    :view (etaf-view (text "Hello desktop")))
          (let ((buffer (etaf-desktop-mount desktop)))
            (should (buffer-live-p buffer))
            (with-current-buffer buffer
              (should (string-match-p "desktop" (buffer-string))))
            (etaf-desktop-minimize-window desktop 'notes)
            (with-current-buffer buffer
              (should-not (string-match-p "Hello desktop" (buffer-string)))
              (should (string-match-p "Notes" (buffer-string))))
            (etaf-desktop-restore-window desktop 'notes)
            (with-current-buffer buffer
              (should (string-match-p "desktop" (buffer-string))))))
      (etaf-desktop-close desktop))
    (etaf-desktop-close desktop)))

(provide 'etaf-desktop-tests)
;;; etaf-desktop-tests.el ends here
