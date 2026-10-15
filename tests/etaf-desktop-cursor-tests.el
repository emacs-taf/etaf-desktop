;;; etaf-desktop-cursor-tests.el --- Native cursor visibility -*- lexical-binding: t; -*-

(require 'ert)
(require 'etaf-desktop)
(require 'etaf)

(defun etaf-desktop-cursor-test--redisplay (window)
  "Deliver Emacs's pre-redisplay event for WINDOW, including in batch tests."
  (with-current-buffer (window-buffer window)
    (run-hook-with-args 'pre-redisplay-functions window)))

(ert-deftest etaf-desktop-image-cursor-is-window-local-and-restored ()
  "Only native image glyphs hide cursors; text and other windows stay usable.
GUI runs exercise native images; batch runs exercise their text fallback."
  (save-window-excursion
    (let* ((desktop (etaf-desktop-create :name " *desktop-cursor-test*"
                                        :canvas-width 400 :canvas-height 12))
           (other (generate-new-buffer " *desktop-cursor-other*"))
           (window (selected-window))
           (initial-visibility (internal-show-cursor-p window))
           (shape (default-value 'cursor-type)))
      (unwind-protect
          (progn
            (etaf-desktop-open-window
             desktop 'picture :title "Picture"
             :view (etaf-view
                    (column :padding '((lh 0) (ch 2) (lh 1) (ch 2))
                     (image :ref 'art :columns 8 :rows 2
                            :src '(image :type svg :data
                                         "<svg xmlns='http://www.w3.org/2000/svg' width='80' height='40'><rect width='80' height='40' fill='#203040'/></svg>"))
                     (text :ref 'copy "Navigate here"))))
            (let* ((buffer (etaf-desktop-mount desktop))
                   (runtime (etaf-runtime-for-buffer buffer))
                   (art (etaf-host-ref-position runtime 'art))
                   (copy (etaf-host-ref-position runtime 'copy))
                   (second (split-window-right))
                   native)
              (should (integerp art))
              (should (integerp copy))
              (set-window-buffer window buffer)
              (set-window-buffer second buffer)
              (setq native (display-graphic-p))
              (internal-show-cursor window t)
              (internal-show-cursor second t)
              (set-window-point window art)
              (set-window-point second copy)
              (etaf-desktop-cursor-test--redisplay window)
              (etaf-desktop-cursor-test--redisplay second)
              (should (eq (internal-show-cursor-p window) (not native)))
              (should (internal-show-cursor-p second))
              (should (equal shape (buffer-local-value 'cursor-type buffer)))
              ;; Moving off the image restores the cursor without an edit session.
              (set-window-point window copy)
              (etaf-desktop-cursor-test--redisplay window)
              (should (internal-show-cursor-p window))
              ;; An already hidden cursor must not be enabled by Desktop.
              (internal-show-cursor window nil)
              (set-window-point window art)
              (etaf-desktop-cursor-test--redisplay window)
              (set-window-point window copy)
              (etaf-desktop-cursor-test--redisplay window)
              (should-not (internal-show-cursor-p window))
              (internal-show-cursor window t)
              ;; Switching to an unrelated buffer releases image suppression.
              (set-window-point window art)
              (etaf-desktop-cursor-test--redisplay window)
              (set-window-buffer window other)
              (etaf-desktop-cursor-test--redisplay window)
              (should (internal-show-cursor-p window))
              ;; Unmounting also releases suppression before another redisplay.
              (set-window-buffer window buffer)
              (set-window-point window art)
              (etaf-desktop-cursor-test--redisplay window)
              (etaf-desktop-close desktop)
              (should (internal-show-cursor-p window))
              (should (internal-show-cursor-p second))))
        (etaf-desktop-close desktop)
        (internal-show-cursor window initial-visibility)
        (kill-buffer other)))))

(ert-deftest etaf-desktop-launcher-keeps-visible-keyboard-navigation ()
  "A opens the launcher; arrows retain a cursor and RET opens the chosen app."
  (save-window-excursion
    (let ((desktop (etaf-desktop-demo-open " *desktop-cursor-launcher*")))
      (unwind-protect
          (let* ((buffer (get-buffer " *desktop-cursor-launcher*"))
                 (runtime (etaf-runtime-for-buffer buffer)))
            (switch-to-buffer buffer)
            (execute-kbd-macro (kbd "a"))
            (should (etaf-desktop-launcher-open-p desktop))
            (let ((first (etaf-focused-host-ref runtime)))
              (should first)
              (should cursor-type)
              (etaf-desktop-cursor-test--redisplay (selected-window))
              (should (internal-show-cursor-p (selected-window)))
              (execute-kbd-macro (kbd "<down>"))
              (let ((next (etaf-focused-host-ref runtime)))
                (should (not (equal first next))))
              (execute-kbd-macro (kbd "<up>"))
              (let ((back (etaf-focused-host-ref runtime)))
                (should (equal first back)))
              (should cursor-type)
              (execute-kbd-macro (kbd "RET"))
              (should-not (etaf-desktop-launcher-open-p desktop))
              (let ((active (etaf-desktop-window-state
                             desktop (etaf-desktop-active-window desktop))))
                (should (equal "Calculator" (plist-get active :title))))))
        (etaf-desktop-close desktop)))))

(provide 'etaf-desktop-cursor-tests)
;;; etaf-desktop-cursor-tests.el ends here
