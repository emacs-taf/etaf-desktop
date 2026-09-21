;;; etaf-desktop-layout-tests.el --- Public layout scenarios -*- lexical-binding: t; -*-

(require 'ert)
(require 'etaf-desktop)

(ert-deftest etaf-desktop-tiling-layout-and-split-resize ()
  "Tiling assigns non-overlapping rectangles and split ratios are adjustable."
  (let ((desktop (etaf-desktop-create :canvas-width 100 :canvas-height 20)))
    (etaf-desktop-open-window desktop 'one :width 20 :height 4
                              :min-width 5 :min-height 2)
    (etaf-desktop-open-window desktop 'two :width 20 :height 4
                              :min-width 5 :min-height 2)
    (etaf-desktop-open-window desktop 'three :width 20 :height 4
                              :min-width 5 :min-height 2)
    (etaf-desktop-set-layout-mode desktop 'tiling)
    (should (eq 'tiling (etaf-desktop-layout-mode desktop)))
    (let ((tree (etaf-desktop-layout-tree desktop)))
      (should (equal :split (car tree)))
      (should (= 3 (length (etaf-desktop--test-leaves tree)))))
    (let ((one (etaf-desktop-window-state desktop 'one))
          (two (etaf-desktop-window-state desktop 'two))
          (three (etaf-desktop-window-state desktop 'three)))
      (should (= 100 (plist-get one :width)))
      (should (= 100 (plist-get two :width)))
      (should (= 100 (plist-get three :width)))
      (should (= 0 (plist-get one :y)))
      (should (< (plist-get one :y) (plist-get two :y)))
      (should (< (plist-get two :y) (plist-get three :y)))
      (should (= 20 (+ (plist-get one :height)
                       (plist-get two :height)
                       (plist-get three :height)))))
    (etaf-desktop-layout-resize-split desktop nil 0.75)
    (let ((three (etaf-desktop-window-state desktop 'three)))
      (should (= 15 (plist-get three :y))))))

(ert-deftest etaf-desktop-layout-floating-and-untile ()
  "Untiling preserves a window as a floating overlay while tree leaves reflow."
  (let ((desktop (etaf-desktop-create :canvas-width 80 :canvas-height 16)))
    (dolist (id '(one two))
      (etaf-desktop-open-window desktop id :width 20 :height 4
                                :min-width 5 :min-height 2))
    (etaf-desktop-set-layout-mode desktop 'tiling)
    (etaf-desktop-layout-untile-window desktop 'two)
    (should (member 'two (etaf-desktop-layout-floating-windows desktop)))
    (should-not (member 'two (etaf-desktop--test-leaves
                              (etaf-desktop-layout-tree desktop))))
    (should (eq 'tiling (etaf-desktop-layout-mode desktop)))
    (etaf-desktop-set-layout-mode desktop 'tiling)
    (should-not (member 'two (etaf-desktop-layout-floating-windows desktop)))
    (should (member 'two (etaf-desktop--test-leaves
                          (etaf-desktop-layout-tree desktop))))))

(ert-deftest etaf-desktop-layout-horizontal-split-and-minimums ()
  "Horizontal splits allocate width and respect each leaf's minimum width."
  (let ((desktop (etaf-desktop-create :canvas-width 100 :canvas-height 12)))
    (etaf-desktop-open-window desktop 'left :width 30 :height 4
                              :min-width 30 :min-height 2)
    (etaf-desktop-open-window desktop 'right :width 20 :height 4
                              :min-width 20 :min-height 2)
    (etaf-desktop-layout-split desktop 'left 'right 'horizontal 0.8)
    (let ((left (etaf-desktop-window-state desktop 'left))
          (right (etaf-desktop-window-state desktop 'right)))
      (should (= 80 (plist-get left :width)))
      (should (= 20 (plist-get right :width)))
      (should (= 80 (plist-get right :x))))
    (etaf-desktop-layout-resize-split desktop nil 0.2)
    (let ((left (etaf-desktop-window-state desktop 'left)))
      (should (= 30 (plist-get left :width))))))

(ert-deftest etaf-desktop-layout-monocle-and-close-sync ()
  "Monocle fills the canvas and closing a leaf removes it from the tree."
  (let ((desktop (etaf-desktop-create :canvas-width 90 :canvas-height 18)))
    (dolist (id '(one two))
      (etaf-desktop-open-window desktop id :width 20 :height 4
                                :min-width 5 :min-height 2))
    (etaf-desktop-set-layout-mode desktop 'tiling)
    (etaf-desktop-focus-window desktop 'two)
    (etaf-desktop-set-layout-mode desktop 'monocle)
    (dolist (id '(one two))
      (let ((window (etaf-desktop-window-state desktop id)))
        (should (= 90 (plist-get window :width)))
        (should (= 18 (plist-get window :height)))))
    (should (> (plist-get (etaf-desktop-window-state desktop 'two) :z-index)
               (plist-get (etaf-desktop-window-state desktop 'one) :z-index)))
    (etaf-desktop-close-window desktop 'one)
    (etaf-desktop-layout-sync desktop)
    (should-not (member 'one (etaf-desktop--test-leaves
                              (etaf-desktop-layout-tree desktop))))))

(defun etaf-desktop--test-leaves (tree)
  "Return public tree leaves for the layout assertions."
  (cond
   ((null tree) nil)
   ((eq :leaf (car tree)) (list (cadr tree)))
   (t (append (etaf-desktop--test-leaves (nth 3 tree))
              (etaf-desktop--test-leaves (nth 4 tree))))))

(provide 'etaf-desktop-layout-tests)
;;; etaf-desktop-layout-tests.el ends here
