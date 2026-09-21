;;; etaf-desktop-apps.el --- ETAF application registry and sessions -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'cl-lib)
(require 'etaf)
(require 'etaf-desktop-runtime)

;; This module owns application policy only.  Geometry and rendering continue
;; to go through the public `etaf-desktop-open-window' and related APIs.

(cl-defstruct (etaf-desktop--app
               (:constructor etaf-desktop--app-create))
  id title icon open close serialize restore capabilities default-window)

(cl-defstruct (etaf-desktop--instance
               (:constructor etaf-desktop--instance-create))
  id app-id status options state windows error restore-data)

(cl-defstruct (etaf-desktop--app-store
               (:constructor etaf-desktop--app-store-create))
  instances next-id)

(defvar etaf-desktop--apps (make-hash-table :test #'equal)
  "Registered ETAF application manifests keyed by application ID.")

;; A weak key keeps a controller's application instances from keeping the
;; controller alive after its buffer and caller references are released.
(defvar etaf-desktop--app-stores
  (make-hash-table :test #'eq :weakness 'key)
  "Per-desktop application instance stores.")

(defun etaf-desktop--validate-app-id (id)
  "Validate and return stable application ID ID."
  (unless (or (and (symbolp id) (not (null id)))
              (and (stringp id) (not (string-empty-p id))))
    (etaf-desktop--fail "Application ID must be a symbol or nonempty string: %S" id))
  id)

(defun etaf-desktop--app-store (desktop)
  "Return the instance store for DESKTOP, creating it when needed."
  (let ((desktop (etaf-desktop--controller desktop)))
    (or (gethash desktop etaf-desktop--app-stores)
        (puthash desktop
                 (etaf-desktop--app-store-create
                  :instances (make-hash-table :test #'equal) :next-id 1)
                 etaf-desktop--app-stores))))

(defun etaf-desktop--app (id)
  "Return registered app ID ID or signal a public desktop error."
  (or (gethash id etaf-desktop--apps)
      (etaf-desktop--fail "Unknown ETAF application: %S" id)))

(defun etaf-desktop--app-plist (app)
  "Return a detached manifest plist for APP."
  (list :id (etaf-desktop--app-id app)
        :title (etaf-desktop--app-title app)
        :icon (etaf-desktop--app-icon app)
        :capabilities (copy-sequence (etaf-desktop--app-capabilities app))
        :default-window (copy-tree (etaf-desktop--app-default-window app))))

(defun etaf-desktop--instance-plist (instance)
  "Return a detached public state plist for INSTANCE."
  (list :id (etaf-desktop--instance-id instance)
        :app-id (etaf-desktop--instance-app-id instance)
        :status (etaf-desktop--instance-status instance)
        :options (copy-tree (etaf-desktop--instance-options instance))
        :state (copy-tree (etaf-desktop--instance-state instance))
        :windows (copy-sequence (etaf-desktop--instance-windows instance))
        :error (etaf-desktop--instance-error instance)))

(defun etaf-desktop--instance-context (desktop instance)
  "Build callback context for INSTANCE in DESKTOP."
  (list :desktop desktop
        :app-id (etaf-desktop--instance-app-id instance)
        :instance-id (etaf-desktop--instance-id instance)
        :options (copy-tree (etaf-desktop--instance-options instance))
        :state (etaf-desktop--instance-state instance)
        :restore-data (etaf-desktop--instance-restore-data instance)
        :windows (copy-sequence (etaf-desktop--instance-windows instance))))

(defun etaf-desktop--instance (desktop id)
  "Return instance ID ID for DESKTOP or signal an error."
  (or (gethash id (etaf-desktop--app-store-instances
                   (etaf-desktop--app-store desktop)))
      (etaf-desktop--fail "Unknown ETAF application instance: %S" id)))

(defun etaf-desktop--window-specs (result default-window)
  "Normalize callback RESULT into a list of window spec plists.
DEFAULT-WINDOW supplies missing values from an app manifest."
  (let ((windows (plist-get result :windows)))
    (cond
     ((listp windows) windows)
     ((or (plist-member result :view) (plist-member result :title))
      (list result))
     ((and (listp default-window) default-window)
      (list default-window))
     (t nil))))

(defun etaf-desktop--window-option (spec key fallback)
  "Get KEY from SPEC, falling back to FALLBACK when absent."
  (if (plist-member spec key) (plist-get spec key) fallback))

(defun etaf-desktop--open-instance-windows (desktop instance result app &optional workspace)
  "Open windows described by RESULT for INSTANCE and return their IDs.
When WORKSPACE is non-nil it fills a missing spec workspace."
  (let ((specs (etaf-desktop--window-specs
                (or result '()) (etaf-desktop--app-default-window app)))
        (index 0)
        ids)
    (dolist (spec specs (nreverse ids))
      (setq index (1+ index))
      (when (and workspace (not (plist-member spec :workspace)))
        (setq spec (plist-put (copy-sequence spec) :workspace workspace)))
      (let* ((local-id (or (plist-get spec :id) index))
             (id (format "%s/%s" (etaf-desktop--instance-id instance) local-id))
             (window (etaf-desktop-open-window
                      desktop id
                      :title (or (plist-get spec :title)
                                 (etaf-desktop--app-title app)
                                 (format "%s" (etaf-desktop--instance-app-id instance)))
                      :view (plist-get spec :view)
                      :x (or (plist-get spec :x) 0)
                      :y (or (plist-get spec :y) 0)
                      :width (or (plist-get spec :width) 400)
                      :height (or (plist-get spec :height) 12)
                      :min-width (or (plist-get spec :min-width) 160)
                      :min-height (or (plist-get spec :min-height) 3)
                      :max-width (plist-get spec :max-width)
                      :max-height (plist-get spec :max-height)
                      :workspace (plist-get spec :workspace)
                      :visible (if (plist-member spec :visible)
                                   (plist-get spec :visible) t)
                      :movable (if (plist-member spec :movable)
                                   (plist-get spec :movable) t)
                      :resizable (if (plist-member spec :resizable)
                                     (plist-get spec :resizable) t))))
        (push (plist-get window :id) ids)))))

(defun etaf-desktop--placeholder (desktop instance message)
  "Open a visible error placeholder for INSTANCE with MESSAGE."
  (condition-case _err
      (let ((window (etaf-desktop-open-window
                     desktop (format "%s/error" (etaf-desktop--instance-id instance))
                     :title (format "ETAF app error: %s"
                                    (etaf-desktop--instance-app-id instance))
                     :view (etaf-view (text (expr message)))
                     :min-width 260 :min-height 4)))
        (setf (etaf-desktop--instance-windows instance)
              (list (plist-get window :id))))
    (error nil)))

(defun etaf-desktop--record-instance-error (desktop instance err)
  "Record ERR on INSTANCE and isolate it from DESKTOP."
  (setf (etaf-desktop--instance-status instance) 'error
        (etaf-desktop--instance-error instance)
        (error-message-string err))
  (etaf-desktop--placeholder desktop instance (etaf-desktop--instance-error instance))
  (etaf-desktop--instance-plist instance))

(defun etaf-desktop--next-instance-id (store app-id)
  "Allocate an instance ID from STORE for APP-ID."
  (let ((id nil))
    (while (progn
             (setq id (format "%s-%d" app-id (etaf-desktop--app-store-next-id store)))
             (setf (etaf-desktop--app-store-next-id store)
                   (1+ (etaf-desktop--app-store-next-id store)))
             (gethash id (etaf-desktop--app-store-instances store))))
    id))

(defun etaf-desktop--restore-window-state (desktop id state)
  "Apply saved window STATE to window ID in DESKTOP when it exists."
  (when (and (listp state)
             (condition-case nil (etaf-desktop-window-state desktop id)
               (etaf-desktop-error nil)))
    (let ((maximized (plist-get state :maximized))
          (minimized (plist-get state :minimized)))
      (etaf-desktop-move-window desktop id (or (plist-get state :x) 0)
                                (or (plist-get state :y) 0))
      (etaf-desktop-resize-window desktop id
                                  (or (plist-get state :width) 400)
                                  (or (plist-get state :height) 12))
      (when maximized (etaf-desktop-maximize-window desktop id))
      (when minimized (etaf-desktop-minimize-window desktop id)))))

(cl-defun etaf-desktop-register-app
    (id &key title icon open close serialize restore capabilities default-window replace)
  "Register application ID with its manifest callbacks.

OPEN receives one context plist containing `:desktop', `:app-id',
`:instance-id', `:options', `:state' and `:restore-data'.  It returns either a
window spec plist or `:windows' followed by a list of window specs.  Each spec
may contain the arguments accepted by `etaf-desktop-open-window'.  CLOSE,
SERIALIZE and RESTORE receive the same context; CLOSE additionally receives a
reason symbol, SERIALIZE returns application-owned data, and RESTORE returns
an OPEN-compatible result.  `:replace' allows replacing an idle manifest."
  (setq id (etaf-desktop--validate-app-id id))
  (when (and (gethash id etaf-desktop--apps) (not replace))
    (etaf-desktop--fail "ETAF application already registered: %S" id))
  (when (and open (not (functionp open)))
    (etaf-desktop--fail "Application OPEN callback is not callable: %S" open))
  (dolist (callback (list close serialize restore))
    (when (and callback (not (functionp callback)))
      (etaf-desktop--fail "Application callback is not callable: %S" callback)))
  (puthash id (etaf-desktop--app-create
               :id id :title title :icon icon :open open :close close
               :serialize serialize :restore restore
               :capabilities (copy-sequence capabilities)
               :default-window (copy-tree default-window))
           etaf-desktop--apps)
  (etaf-desktop--app-plist (gethash id etaf-desktop--apps)))

(defun etaf-desktop-unregister-app (id &optional force)
  "Remove manifest ID and return non-nil.
When FORCE is nil, signal if any desktop still has a live instance of ID."
  (setq id (etaf-desktop--validate-app-id id))
  (unless force
    (maphash
     (lambda (_desktop store)
       (maphash
        (lambda (_instance-id instance)
          (when (and (equal id (etaf-desktop--instance-app-id instance))
                     (not (memq (etaf-desktop--instance-status instance)
                                '(closed error))))
            (etaf-desktop--fail "Application has a live instance: %S" id)))
        (etaf-desktop--app-store-instances store)))
     etaf-desktop--app-stores))
  (remhash id etaf-desktop--apps))

(defun etaf-desktop-app (id)
  "Return a detached manifest plist for registered application ID."
  (etaf-desktop--app-plist (etaf-desktop--app id)))

(defun etaf-desktop-apps ()
  "Return detached manifests for all registered applications."
  (let (result)
    (maphash (lambda (_id app) (push (etaf-desktop--app-plist app) result))
             etaf-desktop--apps)
    (sort result (lambda (a b) (string< (format "%s" (plist-get a :id))
                                        (format "%s" (plist-get b :id)))))))

(defun etaf-desktop-app-registered-p (id)
  "Return non-nil when application ID is registered."
  (and (gethash id etaf-desktop--apps) t))

(cl-defun etaf-desktop-launch
    (desktop app-id &key instance-id options restore-data restore workspace)
  "Launch APP-ID in DESKTOP and return its instance state plist.
An application failure is isolated to an `error' instance and an error
placeholder window; the desktop remains usable.  INSTANCE-ID is stable across
session restore.  RESTORE-DATA is passed to the app's restore callback;
RESTORE forces that callback even when its saved value is nil."
  (let* ((desktop (etaf-desktop--controller desktop))
         (app (etaf-desktop--app (etaf-desktop--validate-app-id app-id)))
         (store (etaf-desktop--app-store desktop))
         (id (or instance-id (etaf-desktop--next-instance-id store app-id)))
         (instances (etaf-desktop--app-store-instances store)))
    (when (gethash id instances)
      (etaf-desktop--fail "Application instance already exists: %S" id))
    (let ((instance (etaf-desktop--instance-create
                     :id id :app-id app-id :status 'launching
                     :options (copy-tree options) :state nil :windows nil
                     :error nil :restore-data restore-data)))
      (puthash id instance instances)
      (condition-case err
          (let* ((context (etaf-desktop--instance-context desktop instance))
                 (result (if (and (or restore restore-data)
                                  (etaf-desktop--app-restore app))
                             (funcall (etaf-desktop--app-restore app) context restore-data)
                           (if (etaf-desktop--app-open app)
                               (funcall (etaf-desktop--app-open app) context)
                             (list :title (etaf-desktop--app-title app)
                                   :workspace workspace))))
                 (ids (etaf-desktop--open-instance-windows desktop instance result app workspace)))
            (setf (etaf-desktop--instance-state instance)
                  (if (plist-member result :state)
                      (plist-get result :state)
                    (etaf-desktop--instance-state instance))
                  (etaf-desktop--instance-windows instance) ids
                  (etaf-desktop--instance-status instance) 'active
                  (etaf-desktop--instance-error instance) nil)
            (etaf-desktop--instance-plist instance))
        (error (etaf-desktop--record-instance-error desktop instance err))))))

(defun etaf-desktop-instances (desktop)
  "Return detached application instance states for DESKTOP."
  (let (result)
    (maphash (lambda (_id instance) (push (etaf-desktop--instance-plist instance) result))
             (etaf-desktop--app-store-instances (etaf-desktop--app-store desktop)))
    (sort result (lambda (a b) (string< (format "%s" (plist-get a :id))
                                        (format "%s" (plist-get b :id)))))))

(defun etaf-desktop-instance (desktop id)
  "Return detached state for application instance ID in DESKTOP."
  (etaf-desktop--instance-plist (etaf-desktop--instance desktop id)))

(defun etaf-desktop-set-instance-state (desktop id state)
  "Set caller-owned application STATE for instance ID and return its state."
  (let ((instance (etaf-desktop--instance desktop id)))
    (setf (etaf-desktop--instance-state instance) state)
    state))

(defun etaf-desktop-focus-instance (desktop id)
  "Focus the first visible window belonging to application instance ID."
  (let ((instance (etaf-desktop--instance desktop id)))
    (unless (memq (etaf-desktop--instance-status instance) '(closed error))
      (let ((window (cl-find-if
                     (lambda (window-id)
                       (let ((state (condition-case nil
                                         (etaf-desktop-window-state desktop window-id)
                                       (etaf-desktop-error nil))))
                         (and state (plist-get state :visible))))
                     (etaf-desktop--instance-windows instance))))
        (if window
            (progn
              (etaf-desktop-focus-window desktop window)
              (setf (etaf-desktop--instance-status instance) 'active)
              (etaf-desktop--instance-plist instance))
          (setf (etaf-desktop--instance-status instance) 'suspended)
          (etaf-desktop--instance-plist instance))))))

(defun etaf-desktop-suspend-instance (desktop id)
  "Minimize all windows of instance ID and mark it suspended."
  (let ((instance (etaf-desktop--instance desktop id)))
    (dolist (window-id (copy-sequence (etaf-desktop--instance-windows instance)))
      (when (condition-case nil (etaf-desktop-window-state desktop window-id)
              (etaf-desktop-error nil))
        (etaf-desktop-minimize-window desktop window-id)))
    (setf (etaf-desktop--instance-status instance) 'suspended)
    (etaf-desktop--instance-plist instance)))

(defun etaf-desktop-restore-instance (desktop id)
  "Restore all windows of instance ID and focus it."
  (let ((instance (etaf-desktop--instance desktop id)))
    (dolist (window-id (copy-sequence (etaf-desktop--instance-windows instance)))
      (when (condition-case nil (etaf-desktop-window-state desktop window-id)
              (etaf-desktop-error nil))
        (etaf-desktop-restore-window desktop window-id)))
    (etaf-desktop-focus-instance desktop id)))

(defun etaf-desktop-close-instance (desktop id &optional reason)
  "Close application instance ID and release its windows.
REASON is passed to the manifest close callback.  Callback failures are
recorded on the instance while all desktop windows are still released."
  (let* ((desktop (etaf-desktop--controller desktop))
         (instance (etaf-desktop--instance desktop id))
         (app (gethash (etaf-desktop--instance-app-id instance) etaf-desktop--apps))
         (callback-error nil))
    (unless (eq (etaf-desktop--instance-status instance) 'closed)
      (setf (etaf-desktop--instance-status instance) 'closing)
      (when (and app (etaf-desktop--app-close app))
        (condition-case err
            (funcall (etaf-desktop--app-close app)
                     (etaf-desktop--instance-context desktop instance)
                     (or reason 'close))
          (error (setq callback-error (error-message-string err)))))
      (dolist (window-id (copy-sequence (etaf-desktop--instance-windows instance)))
        (ignore-errors (etaf-desktop-close-window desktop window-id)))
      (setf (etaf-desktop--instance-status instance) (if callback-error 'error 'closed)
            (etaf-desktop--instance-error instance) callback-error))
    (etaf-desktop--instance-plist instance)))

(defun etaf-desktop--serialize-instance (desktop instance)
  "Return serializable state for INSTANCE."
  (let* ((app (gethash (etaf-desktop--instance-app-id instance) etaf-desktop--apps))
         (data (when (and app (etaf-desktop--app-serialize app))
                 (condition-case err
                     (funcall (etaf-desktop--app-serialize app)
                              (etaf-desktop--instance-context desktop instance))
                   (error (list :error (error-message-string err)))))))
    (list :id (etaf-desktop--instance-id instance)
          :app-id (etaf-desktop--instance-app-id instance)
          :status (etaf-desktop--instance-status instance)
          :options (copy-tree (etaf-desktop--instance-options instance))
          :state (copy-tree (etaf-desktop--instance-state instance))
          :data (copy-tree data)
          :windows (copy-sequence (etaf-desktop--instance-windows instance))
          :window-states
          (mapcar (lambda (id)
                    (cons id (condition-case nil
                                 (etaf-desktop-window-state desktop id)
                               (etaf-desktop-error nil))))
                  (etaf-desktop--instance-windows instance)))))

(defun etaf-desktop-session-state (desktop)
  "Return a serializable session plist for DESKTOP.
Application-owned data is obtained only through registered serialize
callbacks; View objects and Runtime internals are excluded."
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop-state desktop))
         (instances (mapcar (lambda (instance)
                              (etaf-desktop--serialize-instance desktop instance))
                            (hash-table-values
                             (etaf-desktop--app-store-instances
                              (etaf-desktop--app-store desktop))))))
    (list :version 1 :desktop (copy-tree state) :instances instances)))

(defun etaf-desktop-save-session (desktop file)
  "Write `etaf-desktop-session-state' for DESKTOP to FILE and return FILE."
  (unless (stringp file) (etaf-desktop--fail "Session file must be a string: %S" file))
  (with-temp-file file
    (let ((print-level nil) (print-length nil))
      (prin1 (etaf-desktop-session-state desktop) (current-buffer))
      (insert "\n")))
  file)

(defun etaf-desktop--read-session (session-or-file)
  "Read SESSION-OR-FILE as a session plist."
  (if (and (stringp session-or-file) (file-readable-p session-or-file))
      (with-temp-buffer
        (insert-file-contents session-or-file)
        (read (current-buffer)))
    session-or-file))

(defun etaf-desktop--clear-apps (desktop)
  "Close all known app instances in DESKTOP."
  (maphash (lambda (id _instance) (ignore-errors (etaf-desktop-close-instance desktop id 'restore)))
           (copy-hash-table (etaf-desktop--app-store-instances (etaf-desktop--app-store desktop)))))

(defun etaf-desktop--clear-windows (desktop)
  "Close all remaining windows in DESKTOP."
  (dolist (window (etaf-desktop-windows desktop))
    (ignore-errors (etaf-desktop-close-window desktop (plist-get window :id)))))

(defun etaf-desktop--restore-workspaces (desktop workspaces)
  "Make DESKTOP's workspace keys exactly WORKSPACES when possible."
  (unless (and (listp workspaces) workspaces)
    (etaf-desktop--fail "Session has no valid workspaces"))
  (dolist (workspace workspaces)
    (unless (member workspace (plist-get (etaf-desktop-state desktop) :workspaces))
      (etaf-desktop-add-workspace desktop workspace)))
  (dolist (workspace (copy-sequence (plist-get (etaf-desktop-state desktop) :workspaces)))
    (when (and (not (member workspace workspaces))
               (> (length (plist-get (etaf-desktop-state desktop) :workspaces)) 1))
      (ignore-errors (etaf-desktop-remove-workspace desktop workspace))))
  (etaf-desktop-switch-workspace desktop (car workspaces)))

(defun etaf-desktop-restore-session (desktop session-or-file)
  "Restore DESKTOP from a session plist or FILE and return its state.
Unknown applications become isolated error instances with a visible placeholder;
other applications continue restoring."
  (let* ((desktop (etaf-desktop--controller desktop))
         (session (etaf-desktop--read-session session-or-file))
         (saved-desktop (plist-get session :desktop))
         (saved-instances (plist-get session :instances)))
    (unless (and (listp session) (= (or (plist-get session :version) 0) 1)
                 (listp saved-desktop))
      (etaf-desktop--fail "Unsupported ETAF desktop session"))
    (etaf-desktop--clear-apps desktop)
    (etaf-desktop--clear-windows desktop)
    (etaf-desktop--restore-workspaces desktop
                                      (plist-get saved-desktop :workspaces))
    (dolist (saved saved-instances)
      (let* ((id (plist-get saved :id))
             (app-id (plist-get saved :app-id))
             (data (plist-get saved :data))
             (app (gethash app-id etaf-desktop--apps))
             (saved-window-states (plist-get saved :window-states))
             (saved-workspace (plist-get (cdr (car saved-window-states))
                                         :workspace)))
        (if app
            (progn
              (etaf-desktop-launch desktop app-id :instance-id id
                                   :options (plist-get saved :options)
                                   :restore-data data
                                   :restore t
                                   :workspace saved-workspace)
              (etaf-desktop-set-instance-state desktop id (plist-get saved :state))
              (dolist (pair (plist-get saved :window-states))
                (etaf-desktop--restore-window-state desktop (car pair)
                                                    (cdr pair))))
          (let ((instance (etaf-desktop--instance-create
                           :id id :app-id app-id :status 'error
                           :options (plist-get saved :options) :windows nil
                           :error (format "Application is not registered: %S" app-id)
                           :restore-data data)))
            (puthash id instance
                     (etaf-desktop--app-store-instances
                      (etaf-desktop--app-store desktop)))
            (etaf-desktop--placeholder desktop instance
                                        (etaf-desktop--instance-error instance))))))
    (etaf-desktop-switch-workspace desktop (or (plist-get saved-desktop :active-workspace)
                                               (car (plist-get saved-desktop :workspaces))))
    (etaf-desktop-state desktop)))

(provide 'etaf-desktop-apps)
;;; etaf-desktop-apps.el ends here
