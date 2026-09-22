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

;;; performance-scenarios.el ends here
