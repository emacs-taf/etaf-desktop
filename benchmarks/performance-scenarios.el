;;; performance-scenarios.el --- ETAF Desktop interaction workloads -*- lexical-binding: t; -*-

;;; Commentary:
;; The workspace performance driver owns sampling, settlement and diagnostics.
;; This adapter owns only a deterministic Desktop fixture and public gesture
;; actions, so the workload measures the same controlled geometry path used by
;; the mounted shell without introducing a second timer or event loop.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-desktop)

(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defun etaf-desktop-benchmark--fixture (mode)
  "Create a Desktop fixture for MODE and return its driver contract."
  (let* ((buffer (generate-new-buffer " *ETAF Desktop benchmark*"))
         (desktop (etaf-desktop-create
                   :name (buffer-name buffer)
                   :canvas-width 900 :canvas-height 30))
         (view (etaf-view (text "Desktop benchmark window")))
         (move-id 'move-window)
         (resize-id 'resize-window)
         (step 0)
         (runtime nil)
         (last-kind nil)
         (before nil))
    (etaf-desktop-open-window desktop move-id :title "Move"
                              :view view :x 40 :y 3 :width 260 :height 8
                              :min-width 120 :min-height 3)
    (etaf-desktop-open-window desktop resize-id :title "Resize"
                              :view (etaf-view (text "Resize benchmark window"))
                              :x 360 :y 12 :width 260 :height 8
                              :min-width 120 :min-height 3)
    (let ((mounted (etaf-desktop-mount desktop buffer)))
      (setq runtime (etaf-runtime-for-buffer mounted))
      (list
       :buffer mounted
       :ready (lambda () t)
       :environment (lambda ()
                      (list :mode (symbol-name mode)
                            :canvas-width (plist-get (etaf-desktop-state desktop)
                                                     :canvas-width)
                            :canvas-height (plist-get (etaf-desktop-state desktop)
                                                      :canvas-height)))
       :prepare (lambda ()
                  (setq step (1+ step)
                        last-kind (if (oddp step) 'move 'resize)
                        before (etaf-desktop-window-state
                                desktop (if (eq last-kind 'move) move-id resize-id))))
       :invoke (lambda (_sample)
                 (let* ((id (if (eq last-kind 'move) move-id resize-id))
                        (ref (if (eq last-kind 'move)
                                 (intern (format "etaf-desktop-chrome-%s" id))
                               (intern (format "etaf-desktop-resize-%s-right" id))))
                        (delta (if (eq last-kind 'move) '(8 . 1) '(8 . 0))))
                   (etaf-dispatch-event runtime ref 'drag '(:phase start) t)
                   (etaf-dispatch-event runtime ref 'drag
                                        (list :phase 'move :delta delta) t)
                   (etaf-dispatch-event runtime ref 'drag
                                        (list :phase 'end :delta delta) t)))
       :verify (lambda ()
                 (let ((after (etaf-desktop-window-state
                               desktop (if (eq last-kind 'move) move-id resize-id))))
                   (if (eq last-kind 'move)
                       (> (plist-get after :x) (plist-get before :x))
                     (> (plist-get after :width) (plist-get before :width)))))
       :outcome (lambda ()
                  (let ((state (etaf-desktop-window-state
                                desktop (if (eq last-kind 'move) move-id resize-id))))
                    (list :kind (symbol-name last-kind)
                          :x (plist-get state :x)
                          :y (plist-get state :y)
                          :width (plist-get state :width)
                          :height (plist-get state :height))))
       :cleanup (lambda ()
                  (etaf-desktop-close desktop)
                  (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(taf-benchmark-register
 "etaf-desktop.geometry.move-resize"
 :version 1 :modes '(batch gui) :isolation 'series :required-providers '(ebox)
 :budget-ms 50 :impact 'mixed
 :description "Alternating controlled Desktop title move and right-edge resize"
 :setup #'etaf-desktop-benchmark--fixture)

(defun etaf-desktop-benchmark--policy-fixture (mode)
  "Create a public-policy workload for MODE.

MODE selects focus/stacking, window lifecycle, workspace, layout or shell
controls.  The adapter deliberately calls public Desktop operations so these
samples measure application policy without duplicating an interaction loop."
  (let* ((buffer (generate-new-buffer " *ETAF Desktop policy benchmark*"))
         (desktop (etaf-desktop-create
                   :name (buffer-name buffer)
                   :canvas-width 900 :canvas-height 30
                   :workspaces '(main dev)))
         (one 'policy-one)
         (two 'policy-two)
         (three 'policy-three)
         (step 0)
         (expected nil))
    (etaf-desktop-open-window desktop one :title "One" :workspace 'main
                              :view (etaf-view (text "One"))
                              :x 20 :y 2 :width 240 :height 8)
    (etaf-desktop-open-window desktop two :title "Two" :workspace 'main
                              :view (etaf-view (text "Two"))
                              :x 300 :y 10 :width 240 :height 8)
    (etaf-desktop-open-window desktop three :title "Three" :workspace 'dev
                              :view (etaf-view (text "Three"))
                              :x 20 :y 2 :width 240 :height 8)
    (when (eq mode 'layout)
      (etaf-desktop-layout-split desktop one two 'horizontal 0.5 'main))
    (let ((mounted (etaf-desktop-mount desktop buffer)))
      (list
       :buffer mounted
       :ready (lambda () t)
       :environment (lambda () (list :mode (symbol-name mode)))
       :prepare (lambda ()
                  (setq step (1+ step))
                  (pcase mode
                    ('focus (setq expected (if (oddp step) two one)))
                    ('state (setq expected (mod step 3)))
                    ('workspace (setq expected (if (oddp step) 'dev 'main)))
                    ('layout (setq expected (if (oddp step) 0.4 0.6)))
                    ('shell (setq expected (mod step 3)))))
       :invoke (lambda (_sample)
                 (cond
                  ((eq mode 'focus)
                   (etaf-desktop-focus-window desktop expected))
                  ((eq mode 'state)
                   (pcase expected
                     (1 (etaf-desktop-maximize-window desktop one))
                     (2 (etaf-desktop-minimize-window desktop one))
                     (_ (etaf-desktop-restore-window desktop one))))
                  ((eq mode 'workspace)
                   (etaf-desktop-switch-workspace desktop expected))
                  ((eq mode 'layout)
                   (etaf-desktop-layout-resize-split desktop nil expected 'main))
                  ((eq mode 'shell)
                   (pcase expected
                     (1 (etaf-desktop-toggle-launcher desktop t))
                     (2 (etaf-desktop-toggle-switcher desktop t))
                     (_ (etaf-desktop-toggle-settings desktop t))))))
       :verify (lambda ()
                 (pcase mode
                   ('focus (equal expected (etaf-desktop-active-window desktop)))
                   ('state (if (= expected 1)
                               (etaf-desktop-window-maximized-p desktop one)
                             (if (= expected 2)
                                 (plist-get (etaf-desktop-window-state desktop one)
                                            :minimized)
                               (and (not (etaf-desktop-window-maximized-p desktop one))
                                    (not (plist-get
                                          (etaf-desktop-window-state desktop one)
                                          :minimized))))))
                   ('workspace (eq expected (etaf-desktop-active-workspace desktop)))
                   ('layout (equal 'tiling (etaf-desktop-layout-mode desktop 'main)))
                   ('shell (pcase expected
                             (1 (etaf-desktop-launcher-open-p desktop))
                             (2 (etaf-desktop-switcher-open-p desktop))
                             (_ (etaf-desktop-settings-open-p desktop))))))
       :outcome (lambda ()
                  (list :mode (symbol-name mode)
                        :active (format "%s" (etaf-desktop-active-window desktop))
                        :workspace (format "%s" (etaf-desktop-active-workspace desktop))
                        :layout (format "%s" (etaf-desktop-layout-mode desktop 'main))))
       :cleanup (lambda ()
                  (etaf-desktop-close desktop)
                  (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(dolist (mode '(focus state workspace layout shell))
  (taf-benchmark-register
   (format "etaf-desktop.policy.%s" mode)
   :version 1 :modes '(batch gui) :isolation 'series :required-providers '(ebox)
   :budget-ms 50 :impact 'mixed
   :description (format "Desktop %s policy interaction" mode)
   :setup (let ((selected-mode mode))
            (lambda (_run-mode)
              (etaf-desktop-benchmark--policy-fixture selected-mode)))))

;;; performance-scenarios.el ends here
