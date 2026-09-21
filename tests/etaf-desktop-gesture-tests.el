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
  (let ((desktop (etaf-desktop-create :name " *desktop-gesture-retained*")))
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

(provide 'etaf-desktop-gesture-tests)
;;; etaf-desktop-gesture-tests.el ends here
