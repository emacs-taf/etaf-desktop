;;; etaf-desktop-gesture-tests.el --- Retained desktop gesture scenarios -*- lexical-binding: t; -*-

;;; Commentary:
;; These scenarios exercise the public desktop mount and event APIs.  They do
;; not inspect Behavior closures or Runtime tables; the observable contract is
;; that a mounted window keeps its gesture origin across publications.

;;; Code:

(require 'ert)
(require 'etaf)
(require 'etaf-desktop)

(defun etaf-desktop-gesture-test--dispatch (runtime host-ref gestures)
  "Dispatch GESTURES to HOST-REF through mounted RUNTIME."
  (dolist (gesture gestures)
    (etaf-dispatch-event runtime host-ref 'drag gesture t)))

(ert-deftest etaf-desktop-gesture-retains-origin-through-multiple-motions ()
  "A move and resize gesture survives every publication in one gesture."
  (let ((desktop (etaf-desktop-create :name " *desktop-gesture-retained*"
                                      :canvas-width 400 :canvas-height 30)))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'notes :x 4 :y 2
                                    :width 240 :height 10
                                    :min-width 20 :min-height 3)
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer)))
            (etaf-desktop-gesture-test--dispatch
             runtime 'etaf-desktop-chrome-notes
             '((:phase start :delta (0 . 0))
               (:phase move :delta (10 . 2))
               (:phase move :delta (21 . 4))
               (:phase end :delta (37 . 6))))
            (let ((state (etaf-desktop-window-state desktop 'notes)))
              (should (equal '(41 8)
                             (list (plist-get state :x)
                                   (plist-get state :y)))))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-gesture-repeated-sequences-reset-origin ()
  "A second gesture starts from the committed geometry of the first one."
  (let ((desktop (etaf-desktop-create :name " *desktop-gesture-repeat*")))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'notes :x 2 :y 1)
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer)))
            (etaf-desktop-gesture-test--dispatch
             runtime 'etaf-desktop-chrome-notes
             '((:phase start :delta (0 . 0))
               (:phase move :delta (8 . 2))
               (:phase end :delta (8 . 2))))
            (garbage-collect)
            (etaf-desktop-gesture-test--dispatch
             runtime 'etaf-desktop-chrome-notes
             '((:phase start :delta (0 . 0))
               (:phase move :delta (5 . 1))
               (:phase end :delta (5 . 1))))
            (let ((state (etaf-desktop-window-state desktop 'notes)))
              (should (equal '(15 4)
                             (list (plist-get state :x)
                                   (plist-get state :y)))))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-gesture-close-and-reopen-releases-retained-component ()
  "Closing a window releases its retained gesture component before reuse."
  (let ((desktop (etaf-desktop-create :name " *desktop-gesture-reopen*")))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'notes :x 1 :y 1)
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer)))
            (etaf-desktop-gesture-test--dispatch
             runtime 'etaf-desktop-chrome-notes
             '((:phase start :delta (0 . 0))
               (:phase end :delta (4 . 1))))
            (should (= 5 (plist-get (etaf-desktop-window-state desktop 'notes) :x)))
            (should (etaf-desktop-close-window desktop 'notes))
            (etaf-desktop-open-window desktop 'notes :x 7 :y 3)
            (etaf-desktop-gesture-test--dispatch
             runtime 'etaf-desktop-chrome-notes
             '((:phase start :delta (0 . 0))
               (:phase end :delta (2 . 1))))
            (let ((state (etaf-desktop-window-state desktop 'notes)))
              (should (equal '(9 4)
                             (list (plist-get state :x)
                                   (plist-get state :y)))))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-gesture-resizes-every-enabled-edge-and-corner ()
  "The title row's edge and corners publish controlled resize updates.

The body edges carry no handle so window content reaches the window edge; the
bottom-right handle stays solely as the keyboard M-S-<arrow> resize anchor."
  (let ((desktop (etaf-desktop-create :name " *desktop-gesture-edges*")))
    (unwind-protect
        (progn
          (dolist (id '(top top-left top-right bottom-right))
            (etaf-desktop-open-window desktop id :x 10 :y 4
                                      :width 100 :height 12
                                      :min-width 20 :min-height 3))
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer)))
            (etaf-desktop-gesture-test--dispatch
             runtime 'etaf-desktop-resize-top-top
             '((:phase start :delta (0 . 0)) (:phase end :delta (0 . 1))))
            (etaf-desktop-gesture-test--dispatch
             runtime 'etaf-desktop-resize-top-left-top-left
             '((:phase start :delta (0 . 0)) (:phase end :delta (5 . 1))))
            (etaf-desktop-gesture-test--dispatch
             runtime 'etaf-desktop-resize-top-right-top-right
             '((:phase start :delta (0 . 0)) (:phase end :delta (5 . 1))))
            (should (equal '(10 5 100 11)
                           (let ((s (etaf-desktop-window-state desktop 'top)))
                             (list (plist-get s :x) (plist-get s :y)
                                   (plist-get s :width) (plist-get s :height)))))
            (should (equal '(15 5 95 11)
                           (let ((s (etaf-desktop-window-state desktop 'top-left)))
                             (list (plist-get s :x) (plist-get s :y)
                                   (plist-get s :width) (plist-get s :height)))))
            (should (equal '(10 5 105 11)
                           (let ((s (etaf-desktop-window-state desktop 'top-right)))
                             (list (plist-get s :x) (plist-get s :y)
                                   (plist-get s :width) (plist-get s :height)))))
            ;; The bottom-right handle stays as the keyboard resize anchor;
            ;; every other body edge keeps no handle at all.
            (should (etaf-host-ref-position
                     runtime 'etaf-desktop-resize-top-bottom-right))
            (dolist (edge '(left right bottom bottom-left))
              (should-not (etaf-host-ref-position
                           runtime (intern (format "etaf-desktop-resize-top-%s" edge)))))
            ;; The title row's middle is the move gesture, not a second top
            ;; edge: the same drag moves the window instead of resizing it.
            (etaf-desktop-gesture-test--dispatch
             runtime 'etaf-desktop-chrome-top
             '((:phase start :delta (0 . 0)) (:phase end :delta (0 . 1))))
            (should (equal '(10 6 100 11)
                           (let ((s (etaf-desktop-window-state desktop 'top)))
                             (list (plist-get s :x) (plist-get s :y)
                                   (plist-get s :width) (plist-get s :height)))))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-gesture-clamps-resize-at-desktop-origin ()
  "Dragging a left edge past the canvas overflows it; a top edge stops at zero.
Neither gesture aborts, and each preserves its opposite edge."
  (let ((desktop (etaf-desktop-create :name " *desktop-gesture-origin*"
                                      :canvas-width 400 :canvas-height 30)))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'notes :x 2 :y 2
                                    :width 100 :height 12
                                    :min-width 20 :min-height 3)
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer)))
            (etaf-desktop-gesture-test--dispatch
             runtime 'etaf-desktop-resize-notes-top-left
             '((:phase start :delta (0 . 0)) (:phase end :delta (-20 . 0))))
            (etaf-desktop-gesture-test--dispatch
             runtime 'etaf-desktop-resize-notes-top
             '((:phase start :delta (0 . 0)) (:phase end :delta (0 . -20))))
            (let ((state (etaf-desktop-window-state desktop 'notes)))
              (should (= -18 (plist-get state :x)))
              (should (= 0 (plist-get state :y)))
              (should (= 102 (+ (plist-get state :x)
                                (plist-get state :width))))
              (should (= 14 (+ (plist-get state :y)
                               (plist-get state :height)))))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-gesture-divider-tracks-cumulative-displacement ()
  "A tiling divider follows the pointer instead of compounding each motion.
Ebox reports every motion as the displacement from the press, so the ratio
after several moves equals the start ratio plus the final displacement, and a
cancelled gesture restores the ratio it started from."
  (let ((desktop (etaf-desktop-create :name " *desktop-gesture-divider*"
                                      :canvas-width 400 :canvas-height 20)))
    (unwind-protect
        (progn
          (dolist (id '(one two))
            (etaf-desktop-open-window desktop id :title (format "%s" id)
                                      :width 100 :min-width 10 :min-height 2))
          (etaf-desktop-set-setting desktop :tile-outer-gap 0)
          (etaf-desktop-set-setting desktop :tile-inner-gap 2)
          (etaf-desktop-set-layout-mode desktop 'tiling)
          (etaf-desktop-layout-set-tree
           desktop '(:split horizontal 0.5 (:leaf one) (:leaf two)))
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer))
                 (divider (cl-loop for (ref . props)
                                   in (etaf-runtime-host-props-entries runtime)
                                   when (equal "etaf-splitter-divider"
                                               (plist-get props :class))
                                   return ref))
                 (span (- 400 (* 2 (frame-char-width))))
                 (ratio (lambda ()
                          (nth 2 (etaf-desktop-layout-tree desktop))))
                 (right-edge (lambda ()
                               (let ((one (etaf-desktop-window-state desktop 'one)))
                                 (+ (plist-get one :x) (plist-get one :width)))))
                 (edge (funcall right-edge)))
            (should divider)
            (etaf-desktop-gesture-test--dispatch
             runtime divider
             '((:phase start :delta (0 . 0))
               (:phase move :delta (40 . 0))
               (:phase move :delta (80 . 0))
               (:phase end :delta (80 . 0))))
            (should (< (abs (- (+ 0.5 (/ 80.0 span)) (funcall ratio)))
                       0.001))
            (should (<= (abs (- (funcall right-edge) (+ edge 80))) 1))
            (etaf-desktop-gesture-test--dispatch
             runtime divider
             '((:phase start :delta (0 . 0))
               (:phase move :delta (-40 . 0))
               (:phase cancel :delta (-40 . 0))
               (:phase start :delta (0 . 0))
               (:phase end :delta (-80 . 0))))
            (should (< (abs (- 0.5 (funcall ratio))) 0.001))))
      (etaf-desktop-close desktop))))

(provide 'etaf-desktop-gesture-tests)
;;; etaf-desktop-gesture-tests.el ends here
