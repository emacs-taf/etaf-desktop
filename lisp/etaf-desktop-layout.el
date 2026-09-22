;;; etaf-desktop-layout.el --- Floating and tiling desktop layouts -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Layout policy stays above the Ebox/ETAF geometry providers.  A layout is a
;; small immutable-looking tree owned by a desktop controller; applying it
;; publishes one copied desktop state through the existing runtime ref.  The
;; tree never becomes a second geometry store: window records remain
;; authoritative for currently published rectangles.

(require 'cl-lib)
(require 'etaf-desktop-runtime)

(defvar etaf-desktop--layout-table
  (make-hash-table :test #'eq :weakness 'key)
  "Weak map from desktop controllers to their layout policy state.")

(defvar etaf-desktop--layout-refreshing nil
  "Non-nil while a layout refresh is publishing its calculated state.")

(cl-defstruct (etaf-desktop--layout-workspace
               (:constructor etaf-desktop--layout-workspace-create))
  mode tree floating pending)

(cl-defstruct (etaf-desktop--layout-state
               (:constructor etaf-desktop--layout-state-create))
  workspaces)

(defun etaf-desktop--layout-fail (format-string &rest arguments)
  "Signal `etaf-desktop-error' with FORMAT-STRING and ARGUMENTS."
  (etaf-desktop--fail format-string arguments))

(defun etaf-desktop--layout-valid-mode-p (mode)
  "Return non-nil when MODE is a supported layout mode."
  (memq mode '(floating tiling master-stack monocle)))

(defun etaf-desktop--layout-valid-orientation-p (orientation)
  "Return non-nil when ORIENTATION splits a tree in two dimensions.

`horizontal' means left/right side-by-side regions and `vertical' means
top/bottom regions."
  (memq orientation '(horizontal vertical)))

(defun etaf-desktop--layout-ratio (ratio)
  "Validate and normalize split RATIO to a number strictly between zero/one."
  (unless (and (numberp ratio) (> ratio 0) (< ratio 1))
    (etaf-desktop--fail "Layout split ratio must be between 0 and 1: %S" ratio))
  (float ratio))

(defun etaf-desktop--layout-leaf (id)
  "Return a layout leaf for window ID."
  (list :leaf id))

(defun etaf-desktop--layout-split-node (orientation ratio first second)
  "Return a split node for ORIENTATION, RATIO, FIRST and SECOND."
  (list :split orientation (etaf-desktop--layout-ratio ratio) first second))

(defun etaf-desktop--layout-leaf-p (node)
  "Return non-nil when NODE is a layout leaf."
  (and (consp node) (eq (car node) :leaf) (= (length node) 2)))

(defun etaf-desktop--layout-split-p (node)
  "Return non-nil when NODE is a valid split node."
  (and (consp node) (eq (car node) :split) (= (length node) 5)
       (etaf-desktop--layout-valid-orientation-p (nth 1 node))
       (numberp (nth 2 node)) (> (nth 2 node) 0) (< (nth 2 node) 1)))

(defun etaf-desktop--layout-node-p (node)
  "Return non-nil when NODE is a recursively valid layout node."
  (or (and (etaf-desktop--layout-leaf-p node)
           (not (null (nth 1 node))))
      (and (etaf-desktop--layout-split-p node)
           (etaf-desktop--layout-node-p (nth 3 node))
           (etaf-desktop--layout-node-p (nth 4 node)))))

(defun etaf-desktop--layout-copy-tree (tree)
  "Return a detached copy of TREE."
  (copy-tree tree))

(defun etaf-desktop--layout-workspace-ids (state workspace)
  "Return all window IDs belonging to WORKSPACE in STATE."
  (mapcar #'etaf-desktop--window-id
          (cl-remove-if-not
           (lambda (window)
             (equal workspace (etaf-desktop--window-workspace window)))
           (etaf-desktop--state-windows state))))

(defun etaf-desktop--layout-find-workspace (layout workspace)
  "Return the workspace policy for WORKSPACE in LAYOUT."
  (cdr (assq workspace (etaf-desktop--layout-state-workspaces layout))))

(defun etaf-desktop--layout-put-workspace (layout workspace value)
  "Set WORKSPACE policy VALUE in LAYOUT."
  (let ((entry (assq workspace (etaf-desktop--layout-state-workspaces layout))))
    (if entry
        (setcdr entry value)
      (push (cons workspace value)
            (etaf-desktop--layout-state-workspaces layout))))
  value)

(defun etaf-desktop--layout-state-for (desktop)
  "Return or initialize layout policy for DESKTOP."
  (etaf-desktop--controller desktop)
  (or (gethash desktop etaf-desktop--layout-table)
      (let ((layout (etaf-desktop--layout-state-create :workspaces nil)))
        (puthash desktop layout etaf-desktop--layout-table)
        layout)))

(defun etaf-desktop--layout-ensure-workspace (desktop workspace)
  "Return WORKSPACE policy, creating a floating one when needed."
  (let* ((layout (etaf-desktop--layout-state-for desktop))
         (value (etaf-desktop--layout-find-workspace layout workspace)))
    (or value
        (etaf-desktop--layout-put-workspace
         layout workspace
         (etaf-desktop--layout-workspace-create
          :mode 'floating :tree nil :floating nil :pending nil)))))

(defun etaf-desktop--layout-tree-leaves (tree)
  "Return leaf IDs in TREE from left/top to right/bottom."
  (cond
   ((null tree) nil)
   ((etaf-desktop--layout-leaf-p tree) (list (nth 1 tree)))
   ((etaf-desktop--layout-split-p tree)
    (append (etaf-desktop--layout-tree-leaves (nth 3 tree))
            (etaf-desktop--layout-tree-leaves (nth 4 tree))))
   (t (etaf-desktop--fail "Invalid layout tree: %S" tree))))

(defun etaf-desktop--layout-delete-id (tree id)
  "Remove ID from TREE and collapse now-empty split branches.

Return a new tree, or nil when no leaves remain."
  (cond
   ((null tree) nil)
   ((etaf-desktop--layout-leaf-p tree)
    (unless (equal id (nth 1 tree)) tree))
   ((etaf-desktop--layout-split-p tree)
    (let ((first (etaf-desktop--layout-delete-id (nth 3 tree) id))
          (second (etaf-desktop--layout-delete-id (nth 4 tree) id)))
      (cond
       ((and first second)
        (etaf-desktop--layout-split-node (nth 1 tree) (nth 2 tree)
                                         first second))
       (first first)
       (second second)
       (t nil))))
   (t (etaf-desktop--fail "Invalid layout tree: %S" tree))))

(defun etaf-desktop--layout-replace-id (tree id replacement)
  "Replace leaf ID in TREE with REPLACEMENT and return a copy."
  (cond
   ((etaf-desktop--layout-leaf-p tree)
    (if (equal id (nth 1 tree))
        replacement
      (etaf-desktop--layout-copy-tree tree)))
   ((etaf-desktop--layout-split-p tree)
    (etaf-desktop--layout-split-node
     (nth 1 tree) (nth 2 tree)
     (etaf-desktop--layout-replace-id (nth 3 tree) id replacement)
     (etaf-desktop--layout-replace-id (nth 4 tree) id replacement)))
   (t (etaf-desktop--fail "Invalid layout tree: %S" tree))))

(defun etaf-desktop--layout-insert-next-to (tree target replacement orientation ratio)
  "Insert REPLACEMENT next to TARGET in TREE.

Return `(FOUND . TREE)' where FOUND indicates that TARGET was found."
  (cond
   ((null tree) (cons nil nil))
   ((etaf-desktop--layout-leaf-p tree)
    (if (equal target (nth 1 tree))
        (cons t (etaf-desktop--layout-split-node
                 orientation ratio tree replacement))
      (cons nil (etaf-desktop--layout-copy-tree tree))))
   ((etaf-desktop--layout-split-p tree)
    (let ((left (etaf-desktop--layout-insert-next-to
                 (nth 3 tree) target replacement orientation ratio)))
      (if (car left)
          (cons t (etaf-desktop--layout-split-node
                   (nth 1 tree) (nth 2 tree) (cdr left) (nth 4 tree)))
        (let ((right (etaf-desktop--layout-insert-next-to
                      (nth 4 tree) target replacement orientation ratio)))
          (cons (car right)
                (etaf-desktop--layout-split-node
                 (nth 1 tree) (nth 2 tree) (nth 3 tree) (cdr right)))))))
   (t (etaf-desktop--fail "Invalid layout tree: %S" tree))))

(defun etaf-desktop--layout-validate-tree (desktop workspace tree)
  "Validate TREE's shape, IDs and workspace ownership for DESKTOP."
  (unless (or (null tree) (etaf-desktop--layout-node-p tree))
    (etaf-desktop--fail "Invalid layout tree: %S" tree))
  (let* ((state (etaf-desktop--state desktop))
         (ids (etaf-desktop--layout-tree-leaves tree))
         (known (etaf-desktop--layout-workspace-ids state workspace)))
    (when (/= (length ids) (length (delete-dups (copy-sequence ids))))
      (etaf-desktop--fail "Layout tree contains duplicate windows"))
    (dolist (id ids)
      (unless (member id known)
        (etaf-desktop--fail "Window %S is not in workspace %S" id workspace)))
    t))

(defun etaf-desktop--layout-clean-tree (node known)
  "Remove leaves absent from KNOWN IDs and collapse empty split branches."
  (cond
   ((null node) nil)
   ((etaf-desktop--layout-leaf-p node)
    (when (member (nth 1 node) known) node))
   ((etaf-desktop--layout-split-p node)
    (let ((first (etaf-desktop--layout-clean-tree (nth 3 node) known))
          (second (etaf-desktop--layout-clean-tree (nth 4 node) known)))
      (cond
       ((and first second)
        (etaf-desktop--layout-split-node
         (nth 1 node) (nth 2 node) first second))
       (first first)
       (second second)
       (t nil))))
   (t (etaf-desktop--fail "Invalid layout tree: %S" node))))

(defun etaf-desktop-layout-sync (desktop &optional workspace)
  "Synchronize layout membership with DESKTOP's current windows.

New windows become floating in their workspace.  Closed windows are removed
from their tree and floating set.  When WORKSPACE is non-nil, only that
workspace is synchronized.  Return DESKTOP."
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--state desktop))
         (layout (etaf-desktop--layout-state-for desktop))
         (targets (or (and workspace (list workspace))
                      (etaf-desktop--state-workspaces state))))
    (when workspace (etaf-desktop--assert-workspace state workspace))
    (setf (etaf-desktop--layout-state-workspaces layout)
          (cl-remove-if-not
           (lambda (entry)
             (member (car entry) (etaf-desktop--state-workspaces state)))
           (etaf-desktop--layout-state-workspaces layout)))
    (dolist (name targets)
      (let* ((policy (etaf-desktop--layout-ensure-workspace desktop name))
             (known (etaf-desktop--layout-workspace-ids state name))
             (tree-ids (etaf-desktop--layout-tree-leaves
                        (etaf-desktop--layout-workspace-tree policy)))
             (floating (etaf-desktop--layout-workspace-floating policy))
             (pending (etaf-desktop--layout-workspace-pending policy)))
        (setf (etaf-desktop--layout-workspace-tree policy)
              (etaf-desktop--layout-clean-tree
               (etaf-desktop--layout-workspace-tree policy) known))
        (setq tree-ids
              (etaf-desktop--layout-tree-leaves
               (etaf-desktop--layout-workspace-tree policy)))
        (setf floating (cl-remove-if-not (lambda (id) (member id known)) floating))
        (setq pending (cl-remove-if-not (lambda (id) (member id known)) pending))
        (dolist (id known)
          (unless (or (member id tree-ids) (member id floating))
            (push id floating)
            (push id pending)))
        (setf (etaf-desktop--layout-workspace-floating policy)
              (delete-dups floating)
              (etaf-desktop--layout-workspace-pending policy)
              (delete-dups pending))))
    desktop))

(defun etaf-desktop-layout-refresh (desktop &optional workspace)
  "Synchronize and, when needed, apply DESKTOP's WORKSPACE layout.

This is the safe integration hook for desktop mutations: it applies `tiling'
and `monocle' modes in one guarded publication, while floating mode only
updates membership.  The guard prevents a caller that refreshes from a
publication callback from recursively publishing forever.  Return DESKTOP."
  (let* ((desktop (etaf-desktop--controller desktop))
         (workspace (or workspace
                        (etaf-desktop--state-active-workspace
                         (etaf-desktop--state desktop)))))
    (unless etaf-desktop--layout-refreshing
      (let ((etaf-desktop--layout-refreshing t))
        (etaf-desktop-layout-sync desktop workspace)
        (let ((mode (etaf-desktop-layout-mode desktop workspace)))
          (when (memq mode '(tiling master-stack monocle))
            (etaf-desktop--layout-tile-pending desktop workspace)
            (etaf-desktop-layout-apply desktop workspace)))))
    desktop))

(defun etaf-desktop--layout-tile-pending (desktop workspace)
  "Move newly opened pending windows into WORKSPACE's active tree."
  (let* ((state (etaf-desktop--state desktop))
         (workspace (or workspace
                        (etaf-desktop--state-active-workspace state)))
         (policy (etaf-desktop--layout-ensure-workspace desktop workspace))
         (tree (etaf-desktop--layout-workspace-tree policy))
         (pending (etaf-desktop--layout-workspace-pending policy))
         (mode (etaf-desktop--layout-workspace-mode policy)))
    (if (eq mode 'master-stack)
        (let* ((ids (append (etaf-desktop--layout-tree-leaves tree) pending))
               (visible (etaf-desktop--layout-all-visible-ids state workspace)))
          (setq ids (cl-remove-if-not (lambda (id) (member id visible)) ids))
          (setf tree (etaf-desktop--layout-master-tree (delete-dups ids))
                (etaf-desktop--layout-workspace-tree policy) tree
                (etaf-desktop--layout-workspace-floating policy) nil
                (etaf-desktop--layout-workspace-pending policy) nil)
          tree)
      (dolist (id pending)
        (when (and (etaf-desktop--window-for state id)
                   (not (member id (etaf-desktop--layout-tree-leaves tree))))
          (setq tree (if tree
                         (etaf-desktop--layout-split-node
                          'vertical 0.5 tree (etaf-desktop--layout-leaf id))
                       (etaf-desktop--layout-leaf id))))
        (setf (etaf-desktop--layout-workspace-floating policy)
              (delete id (etaf-desktop--layout-workspace-floating policy))))
      (setf (etaf-desktop--layout-workspace-tree policy) tree
            (etaf-desktop--layout-workspace-pending policy) nil)
      tree)))

(defun etaf-desktop-layout-mode (desktop &optional workspace)
  "Return DESKTOP's layout mode for WORKSPACE.

WORKSPACE defaults to the active workspace.  Modes are `floating', `tiling',
`master-stack' and `monocle'."
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--state desktop))
         (workspace (or workspace (etaf-desktop--state-active-workspace state))))
    (etaf-desktop--assert-workspace state workspace)
    (etaf-desktop-layout-sync desktop workspace)
    (etaf-desktop--layout-workspace-mode
     (etaf-desktop--layout-ensure-workspace desktop workspace))))

(defun etaf-desktop-layout-tree (desktop &optional workspace)
  "Return a detached layout tree for DESKTOP's WORKSPACE.

The tree uses `(:leaf WINDOW-ID)' and
`(:split ORIENTATION RATIO FIRST SECOND)' nodes."
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--state desktop))
         (workspace (or workspace (etaf-desktop--state-active-workspace state))))
    (etaf-desktop--assert-workspace state workspace)
    (etaf-desktop-layout-sync desktop workspace)
    (etaf-desktop--layout-copy-tree
     (etaf-desktop--layout-workspace-tree
      (etaf-desktop--layout-ensure-workspace desktop workspace)))))

(defun etaf-desktop-layout-floating-windows (desktop &optional workspace)
  "Return floating window IDs for DESKTOP's WORKSPACE."
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--state desktop))
         (workspace (or workspace (etaf-desktop--state-active-workspace state))))
    (etaf-desktop--assert-workspace state workspace)
    (etaf-desktop-layout-sync desktop workspace)
    (copy-sequence
     (etaf-desktop--layout-workspace-floating
      (etaf-desktop--layout-ensure-workspace desktop workspace)))))

(defun etaf-desktop--layout-all-visible-ids (state workspace)
  "Return visible non-minimized IDs for WORKSPACE in STATE."
  (mapcar #'etaf-desktop--window-id
          (sort
           (cl-remove-if-not
            (lambda (window)
              (and (equal workspace (etaf-desktop--window-workspace window))
                   (etaf-desktop--window-visible window)
                   (not (etaf-desktop--window-minimized window))))
            (copy-sequence (etaf-desktop--state-windows state)))
           (lambda (first second)
             (< (etaf-desktop--window-z-index first)
                (etaf-desktop--window-z-index second))))))

(defun etaf-desktop--layout-master-tree (ids)
  "Build a master/stack tree from visible IDS in z-order.

The first ID gets 60 percent of the width.  Remaining IDs form a vertical
stack whose ratios make each leaf the same height."
  (when ids
    (let ((master (etaf-desktop--layout-leaf (car ids)))
          (stack (cdr ids)))
      (if (null stack)
          master
        (cl-labels
            ((stack-tree (values)
               (if (null (cdr values))
                   (etaf-desktop--layout-leaf (car values))
                 (etaf-desktop--layout-split-node
                  'vertical (/ 1.0 (float (length values)))
                  (etaf-desktop--layout-leaf (car values))
                  (stack-tree (cdr values))))))
          (etaf-desktop--layout-split-node
           'horizontal 0.6 master (stack-tree stack)))))))

(defun etaf-desktop--layout-window (state id)
  "Return ID's internal window from STATE or signal an error."
  (or (etaf-desktop--window-for state id)
      (etaf-desktop--fail "Unknown desktop window: %S" id)))

(defun etaf-desktop--layout-min-size (state node axis)
  "Return minimum size for NODE along AXIS (`width' or `height')."
  (if (etaf-desktop--layout-leaf-p node)
      (let ((window (etaf-desktop--layout-window state (nth 1 node))))
        (if (eq axis 'width)
            (etaf-desktop--window-min-width window)
          (etaf-desktop--window-min-height window)))
    (let ((orientation (nth 1 node))
          (first (nth 3 node))
          (second (nth 4 node)))
      (if (and (eq axis 'width) (eq orientation 'horizontal))
          (+ (etaf-desktop--layout-min-size state first axis)
             (etaf-desktop--layout-min-size state second axis))
        (if (and (eq axis 'height) (eq orientation 'vertical))
            (+ (etaf-desktop--layout-min-size state first axis)
               (etaf-desktop--layout-min-size state second axis))
          (max (etaf-desktop--layout-min-size state first axis)
               (etaf-desktop--layout-min-size state second axis)))))))

(defun etaf-desktop--layout-max-size (state node axis)
  "Return maximum size for NODE along AXIS, or nil when unbounded."
  (if (etaf-desktop--layout-leaf-p node)
      (let ((window (etaf-desktop--layout-window state (nth 1 node))))
        (if (eq axis 'width)
            (etaf-desktop--window-max-width window)
          (etaf-desktop--window-max-height window)))
    (let* ((orientation (nth 1 node))
           (first (etaf-desktop--layout-max-size state (nth 3 node) axis))
           (second (etaf-desktop--layout-max-size state (nth 4 node) axis)))
      (if (eq axis (if (eq orientation 'horizontal) 'width 'height))
          (and first second (+ first second))
        (cond
         ((and first second) (max first second))
         (first first)
         (second second)
         (t nil))))))

(defun etaf-desktop--layout-split-pixel
    (total ratio first-min second-min first-max second-max)
  "Return first integer split of TOTAL according to RATIO and bounds."
  (let* ((ideal (round (* (float total) ratio)))
         (low (max 1 first-min))
         (high (min (1- total) (- total (max 1 second-min)))))
    (setq low (max low (if second-max (- total second-max) 1)))
    (setq high (min high (or first-max (1- total))))
    (if (> low high)
        (max 1 (min (1- total) ideal))
      (max low (min high ideal)))))

(defconst etaf-desktop--layout-divider-px 3
  "Divider width reserved beside a left/right tile (see `etaf-splitter').")

(defconst etaf-desktop--layout-divider-rows 1
  "Divider row reserved between top/bottom tiles (see `etaf-splitter').")

(defun etaf-desktop--layout-rectangles (state node x y width height)
  "Return `(ID X Y WIDTH HEIGHT)' rectangles for NODE.

Each split reserves its divider so the visible separator owns its own row or
column instead of covering the second tile's title bar."
  (if (etaf-desktop--layout-leaf-p node)
      (list (list (nth 1 node) x y (max 1 width) (max 1 height)))
    (let* ((orientation (nth 1 node))
           (ratio (nth 2 node))
           (first (nth 3 node))
           (second (nth 4 node)))
      (if (eq orientation 'horizontal)
           (let* ((first-width
                  (etaf-desktop--layout-split-pixel
                   width ratio
                   (etaf-desktop--layout-min-size state first 'width)
                   (etaf-desktop--layout-min-size state second 'width)
                   (etaf-desktop--layout-max-size state first 'width)
                   (etaf-desktop--layout-max-size state second 'width))))
            (append
             (etaf-desktop--layout-rectangles
              state first x y first-width height)
             (etaf-desktop--layout-rectangles
              state second (+ x first-width etaf-desktop--layout-divider-px) y
              (max 1 (- width first-width etaf-desktop--layout-divider-px))
              height)))
        (let* ((first-height
                (etaf-desktop--layout-split-pixel
                 height ratio
                 (etaf-desktop--layout-min-size state first 'height)
                 (etaf-desktop--layout-min-size state second 'height)
                 (etaf-desktop--layout-max-size state first 'height)
                 (etaf-desktop--layout-max-size state second 'height))))
          (append
           (etaf-desktop--layout-rectangles
            state first x y width first-height)
           (etaf-desktop--layout-rectangles
            state second x (+ y first-height etaf-desktop--layout-divider-rows) width
            (max 1 (- height first-height etaf-desktop--layout-divider-rows)))))))))

(defun etaf-desktop-layout-apply (desktop &optional workspace)
  "Apply DESKTOP's current layout to WORKSPACE and return its rectangles.

Tiling layouts fill the desktop canvas while respecting each window's minimum
size.  Floating windows retain their own rectangles.  Monocle lays every leaf
over the canvas and raises the active window, giving a single-window view while
retaining the tree for instant return to tiling."
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--state desktop))
         (workspace (or workspace (etaf-desktop--state-active-workspace state))))
    (etaf-desktop--assert-workspace state workspace)
    (etaf-desktop-layout-sync desktop workspace)
    (let* ((policy (etaf-desktop--layout-ensure-workspace desktop workspace))
           (mode (etaf-desktop--layout-workspace-mode policy))
           (tree (etaf-desktop--layout-workspace-tree policy))
           (canvas-width (etaf-desktop--canvas-width-value desktop))
           (canvas-height (etaf-desktop--canvas-height-value desktop))
           (active (etaf-desktop--state-active-window state))
           (rectangles
            (cond
             ((eq mode 'floating) nil)
             ((eq mode 'monocle)
              (mapcar (lambda (id) (list id 0 0 canvas-width canvas-height))
                      (etaf-desktop--layout-tree-leaves tree)))
             (t (and tree (etaf-desktop--layout-rectangles
                           state tree 0 0 canvas-width canvas-height)))))
           (result rectangles))
      (etaf-desktop--update
       desktop
       (lambda (next-state)
         (dolist (rectangle rectangles)
           (pcase-let ((`(,id ,x ,y ,width ,height) rectangle))
             (let ((window (etaf-desktop--window-for next-state id)))
               (when window
                 (setf (etaf-desktop--window-x window) x
                       (etaf-desktop--window-y window) y
                       (etaf-desktop--window-width window) width
                       (etaf-desktop--window-height window) height
                       (etaf-desktop--window-normal-geometry window)
                       (list x y width height))))))
         (when (and (eq mode 'monocle) active
                    (member active (etaf-desktop--layout-tree-leaves tree)))
           (let ((window (etaf-desktop--window-for next-state active)))
             (when window
               (setf (etaf-desktop--window-z-index window)
                     (etaf-desktop--state-next-z next-state)
                     (etaf-desktop--state-next-z next-state)
                     (1+ (etaf-desktop--state-next-z next-state)))))
         result))))))

(defun etaf-desktop-toggle-layout-mode (desktop &optional workspace)
  "Switch DESKTOP's WORKSPACE between `floating' and `tiling'.
Return DESKTOP.  Other modes (`master-stack' and `monocle') return to tiling,
so the trailing workspace control always has one predictable meaning."
  (let* ((desktop (etaf-desktop--controller desktop))
         (current (etaf-desktop-layout-mode desktop workspace)))
    (etaf-desktop-set-layout-mode
     desktop (if (eq current 'floating) 'tiling 'floating) workspace)
    desktop))

(defun etaf-desktop-set-layout-mode (desktop mode &optional workspace)
  "Set DESKTOP's WORKSPACE layout MODE and apply it.

MODE must be `floating', `tiling', `master-stack' or `monocle'.  Switching to
tiling makes all visible non-minimized windows leaves in insertion order;
`master-stack' gives the first window a wide master region and stacks the rest
vertically.  Switching to floating preserves the tree and current rectangles
for a later return."
  (unless (etaf-desktop--layout-valid-mode-p mode)
    (etaf-desktop--fail "Unknown desktop layout mode: %S" mode))
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--state desktop))
         (workspace (or workspace (etaf-desktop--state-active-workspace state))))
    (etaf-desktop--assert-workspace state workspace)
    (etaf-desktop-layout-sync desktop workspace)
    (let* ((policy (etaf-desktop--layout-ensure-workspace desktop workspace))
           (tree (etaf-desktop--layout-workspace-tree policy))
           (ids (etaf-desktop--layout-all-visible-ids state workspace))
           (leaves (etaf-desktop--layout-tree-leaves tree)))
      (when (memq mode '(tiling master-stack monocle))
        (dolist (id ids)
          (unless (member id leaves)
            (setq tree (if tree
                           (etaf-desktop--layout-split-node
                            'vertical 0.5 tree (etaf-desktop--layout-leaf id))
                         (etaf-desktop--layout-leaf id)))))
        (setf (etaf-desktop--layout-workspace-tree policy)
              (if (eq mode 'master-stack)
                  (etaf-desktop--layout-master-tree ids)
                tree)
              (etaf-desktop--layout-workspace-floating policy) nil
              (etaf-desktop--layout-workspace-pending policy) nil))
      (setf (etaf-desktop--layout-workspace-mode policy) mode)
      (etaf-desktop-layout-apply desktop workspace)
      mode)))

(defun etaf-desktop-layout-tile-window (desktop id &optional workspace)
  "Add window ID to WORKSPACE's tiling tree and apply the layout.

When no tree exists ID becomes its root leaf.  Existing windows remain in
place and the new leaf is appended with a balanced vertical split."
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--state desktop))
         (window (etaf-desktop--layout-window state id))
         (workspace (or workspace (etaf-desktop--window-workspace window))))
    (etaf-desktop--assert-workspace state workspace)
    (unless (equal workspace (etaf-desktop--window-workspace window))
      (etaf-desktop--fail "Window %S is not in workspace %S" id workspace))
    (etaf-desktop-layout-sync desktop workspace)
    (let* ((policy (etaf-desktop--layout-ensure-workspace desktop workspace))
           (tree (etaf-desktop--layout-workspace-tree policy)))
      (unless (member id (etaf-desktop--layout-tree-leaves tree))
        (setf (etaf-desktop--layout-workspace-tree policy)
              (if tree
                  (etaf-desktop--layout-split-node
                   'vertical 0.5 tree (etaf-desktop--layout-leaf id))
                (etaf-desktop--layout-leaf id))
              (etaf-desktop--layout-workspace-floating policy)
              (delete id (etaf-desktop--layout-workspace-floating policy))
              (etaf-desktop--layout-workspace-pending policy)
              (delete id (etaf-desktop--layout-workspace-pending policy))))
      (setf (etaf-desktop--layout-workspace-mode policy) 'tiling)
      (etaf-desktop-layout-apply desktop workspace)
      (etaf-desktop-layout-tree desktop workspace))))

(defun etaf-desktop-layout-untile-window (desktop id &optional workspace)
  "Remove ID from WORKSPACE's tree and leave it floating with its rectangle."
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--state desktop))
         (window (etaf-desktop--layout-window state id))
         (workspace (or workspace (etaf-desktop--window-workspace window))))
    (etaf-desktop--assert-workspace state workspace)
    (unless (equal workspace (etaf-desktop--window-workspace window))
      (etaf-desktop--fail "Window %S is not in workspace %S" id workspace))
    (etaf-desktop-layout-sync desktop workspace)
    (let ((policy (etaf-desktop--layout-ensure-workspace desktop workspace)))
      (setf (etaf-desktop--layout-workspace-tree policy)
            (etaf-desktop--layout-delete-id
             (etaf-desktop--layout-workspace-tree policy) id)
            (etaf-desktop--layout-workspace-floating policy)
            (cons id (delete id (etaf-desktop--layout-workspace-floating policy)))
            (etaf-desktop--layout-workspace-pending policy)
            (delete id (etaf-desktop--layout-workspace-pending policy)))
      (etaf-desktop-layout-apply desktop workspace)
      (etaf-desktop-layout-tree desktop workspace))))

(defun etaf-desktop-layout-split
    (desktop target new-id orientation ratio &optional workspace)
  "Split TARGET and add NEW-ID beside it in WORKSPACE.

ORIENTATION is `horizontal' (left/right) or `vertical' (top/bottom), and RATIO
is the fraction allocated to TARGET's existing region.  NEW-ID must already be
an open window in the same workspace."
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--state desktop))
         (target-window (etaf-desktop--layout-window state target))
         (new-window (etaf-desktop--layout-window state new-id))
         (workspace (or workspace (etaf-desktop--window-workspace target-window))))
    (unless (etaf-desktop--layout-valid-orientation-p orientation)
      (etaf-desktop--fail "Unknown split orientation: %S" orientation))
    (etaf-desktop--layout-ratio ratio)
    (etaf-desktop--assert-workspace state workspace)
    (unless (equal workspace (etaf-desktop--window-workspace target-window))
      (etaf-desktop--fail "Target window is not in workspace %S" workspace))
    (unless (equal workspace (etaf-desktop--window-workspace new-window))
      (etaf-desktop--fail "New window is not in workspace %S" workspace))
    (when (equal target new-id)
      (etaf-desktop--fail "Cannot split a window with itself"))
    (etaf-desktop-layout-sync desktop workspace)
    (let* ((policy (etaf-desktop--layout-ensure-workspace desktop workspace))
           (tree (etaf-desktop--layout-workspace-tree policy))
           (tree (if (member new-id (etaf-desktop--layout-tree-leaves tree))
                     (etaf-desktop--layout-delete-id tree new-id)
                   tree))
           (tree (if (member target (etaf-desktop--layout-tree-leaves tree))
                     tree
                   (if tree
                       (etaf-desktop--layout-split-node
                        orientation ratio tree (etaf-desktop--layout-leaf target))
                     (etaf-desktop--layout-leaf target))))
           (result (etaf-desktop--layout-insert-next-to
                    tree target (etaf-desktop--layout-leaf new-id)
                    orientation ratio)))
      (unless (car result)
        (etaf-desktop--fail "Target window is not in the layout tree: %S" target))
      (setf (etaf-desktop--layout-workspace-tree policy) (cdr result)
            (etaf-desktop--layout-workspace-mode policy) 'tiling
            (etaf-desktop--layout-workspace-floating policy)
            (delete target (delete new-id
                                    (etaf-desktop--layout-workspace-floating policy)))
            (etaf-desktop--layout-workspace-pending policy)
            (delete target (delete new-id
                                   (etaf-desktop--layout-workspace-pending policy))))
      (etaf-desktop-layout-apply desktop workspace)
      (etaf-desktop-layout-tree desktop workspace))))

(defun etaf-desktop-layout-resize-split
    (desktop path ratio &optional workspace)
  "Set a split RATIO at PATH in WORKSPACE and reapply the layout.

PATH is a list of zero-based child selectors: 0 descends into the first child,
1 into the second.  The empty path addresses WORKSPACE's root split."
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--state desktop))
         (workspace (or workspace (etaf-desktop--state-active-workspace state)))
         (policy nil))
    (etaf-desktop--assert-workspace state workspace)
    (unless (and (listp path) (cl-every (lambda (value) (memq value '(0 1))) path))
      (etaf-desktop--fail "Split path must contain only 0 or 1: %S" path))
    (etaf-desktop--layout-ratio ratio)
    (etaf-desktop-layout-sync desktop workspace)
    (setq policy (etaf-desktop--layout-ensure-workspace desktop workspace))
    (let ((tree (etaf-desktop--layout-workspace-tree policy)))
      (unless tree (etaf-desktop--fail "Workspace has no tiling tree"))
      (cl-labels
          ((resize (node remaining)
             (if (null remaining)
                 (if (etaf-desktop--layout-split-p node)
                     (etaf-desktop--layout-split-node
                      (nth 1 node) ratio (nth 3 node) (nth 4 node))
                   (etaf-desktop--fail "Split path addresses a leaf"))
               (if (etaf-desktop--layout-split-p node)
                   (etaf-desktop--layout-split-node
                    (nth 1 node) (nth 2 node)
                    (if (= (car remaining) 0)
                        (resize (nth 3 node) (cdr remaining))
                      (nth 3 node))
                    (if (= (car remaining) 1)
                        (resize (nth 4 node) (cdr remaining))
                      (nth 4 node)))
                 (etaf-desktop--fail "Split path descends through a leaf")))))
        (setf (etaf-desktop--layout-workspace-tree policy)
              (resize tree path)))
      (etaf-desktop-layout-apply desktop workspace)
      (etaf-desktop-layout-tree desktop workspace))))

(defun etaf-desktop-layout-remove-window (desktop id &optional workspace)
  "Remove ID from WORKSPACE's tree and floating set after window close.

This operation only changes layout policy; callers that want to close the
window itself should call `etaf-desktop-close-window'."
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--state desktop))
         (workspace (or workspace (etaf-desktop--window-workspace
                                   (etaf-desktop--layout-window state id)))))
    (etaf-desktop--assert-workspace state workspace)
    (etaf-desktop-layout-sync desktop workspace)
    (let ((policy (etaf-desktop--layout-ensure-workspace desktop workspace)))
      (setf (etaf-desktop--layout-workspace-tree policy)
            (etaf-desktop--layout-delete-id
             (etaf-desktop--layout-workspace-tree policy) id)
            (etaf-desktop--layout-workspace-floating policy)
            (delete id (etaf-desktop--layout-workspace-floating policy))
            (etaf-desktop--layout-workspace-pending policy)
            (delete id (etaf-desktop--layout-workspace-pending policy)))
      (etaf-desktop-layout-apply desktop workspace)
      desktop)))

(provide 'etaf-desktop-layout)
;;; etaf-desktop-layout.el ends here
