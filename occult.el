;;; occult.el --- Collapse and reveal buffer regions -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2025 Ag Ibragimov
;;
;; Author: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Maintainer: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Created: March 25, 2026
;; Version: 0.1.0
;; Keywords: convenience
;; Homepage: https://github.com/agzam/occult.el
;; Package-Requires: ((emacs "29.1"))
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is not part of GNU Emacs.
;;
;;; Commentary:
;;
;; Occult (from Latin occultus - "hidden, secret") lets you collapse any
;; buffer region into a single-line summary using overlays.  The hidden text
;; remains fully present in the buffer - accessible to `buffer-string',
;; `buffer-substring-no-properties', org-export, copy/kill, and LLM context
;; extraction tools.
;;
;; Usage:
;;   Select a region and call `occult-toggle' to collapse it.
;;   Call `occult-toggle' with point on a collapsed fold to expand it.
;;   Call `occult-reveal-all' to expand all folds in the buffer.
;;
;;; Code:

(require 'cl-lib)

;; Silence byte-compiler about evil functions
(declare-function evil-ex-search-forward "evil-ex" ())
(declare-function evil-ex-search-backward "evil-ex" ())
(declare-function evil-ex-search-next "evil-ex" ())
(declare-function evil-ex-search-previous "evil-ex" ())

;;; Customization

(defgroup occult nil
  "Collapse and reveal buffer regions."
  :group 'convenience
  :prefix "occult-")

(defcustom occult-indicator "📎 "
  "Prefix string displayed before the summary text of a fold."
  :type 'string)

(defcustom occult-ellipsis "..."
  "Suffix string appended to truncated fold summaries."
  :type 'string)

(defcustom occult-summary-max-length 80
  "Maximum number of characters from the first line to display in a fold."
  :type 'integer)

(defcustom occult-auto-reveal nil
  "How to automatically reveal folds when point enters them.

nil       - folds stay collapsed until explicitly toggled
`echo'    - show fold content in echo area when point is on a fold
`expand'  - temporarily expand when point enters, re-collapse on exit

Note: isearch integration is always active regardless of this setting."
  :type '(choice (const :tag "No auto-reveal" nil)
                 (const :tag "Show in echo area" echo)
                 (const :tag "Temporarily expand" expand)))

(defcustom occult-lighter " Occ"
  "Mode-line lighter shown when occult folds exist in the buffer."
  :type 'string)

(defcustom occult-edit-lighter " OccEdit"
  "Mode-line lighter shown in an active `occult-edit-mode' session."
  :type 'string)

(defcustom occult-edit-commit-key "C-c C-c"
  "Key sequence that commits an `occult-edit-mode' session.
Takes effect the next time `occult-edit-mode' is enabled."
  :type 'key-sequence
  :set (lambda (sym val)
         (set-default sym val)
         (when (and (fboundp 'occult-edit--rebuild-keymap)
                    (boundp 'occult-edit-mode-map))
           (occult-edit--rebuild-keymap))))

(defcustom occult-edit-abort-key "C-c C-k"
  "Key sequence that aborts an `occult-edit-mode' session.
Takes effect the next time `occult-edit-mode' is enabled."
  :type 'key-sequence
  :set (lambda (sym val)
         (set-default sym val)
         (when (and (fboundp 'occult-edit--rebuild-keymap)
                    (boundp 'occult-edit-mode-map))
           (occult-edit--rebuild-keymap))))

;;; Faces

(defface occult-summary
  '((t :inherit shadow :slant italic))
  "Face for the summary text of a collapsed region.")

(defface occult-indicator
  '((t :inherit font-lock-constant-face))
  "Face for the indicator glyph prefixing a fold summary.")

(defface occult-edit-header
  '((t :weight bold :inherit font-lock-function-name-face))
  "Face for the edit-session label in the header line.")

(defface occult-edit-commit-key
  '((t :weight bold :inherit success))
  "Face for the commit key in the edit-session header line.")

(defface occult-edit-abort-key
  '((t :weight bold :inherit error))
  "Face for the abort key in the edit-session header line.")

(defface occult-edit-header-separator
  '((t :inherit shadow))
  "Face for labels and separators in the edit-session header line.")

;;; Internal variables

(defvar-local occult--saved-overlays nil
  "Saved overlay state for `revert-buffer' persistence.
List of (BEG END CONTENT-HASH) tuples.")

(defvar-local occult--auto-reveal-ov nil
  "Overlay currently auto-revealed by cursor proximity or evil search.")

;;; Overlay keymap

(defvar occult-overlay-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'occult-toggle)
    (define-key map (kbd "e") #'occult-edit-region)
    (define-key map [mouse-1] #'occult-toggle)
    map)
  "Keymap active on occult fold overlays.")

;;; Internal helpers

(defun occult--overlays-in (beg end)
  "Return all occult overlays overlapping BEG..END."
  (cl-remove-if-not
   (lambda (ov) (overlay-get ov 'occult))
   (overlays-in beg end)))

(defun occult--overlay-at-point ()
  "Return the occult overlay at point, or nil."
  (cl-find-if
   (lambda (ov) (overlay-get ov 'occult))
   (overlays-at (point))))

(defun occult--visible-end (beg end)
  "Return the position where the visible summary line ends.
BEG is the start of the visible content of the fold - i.e. the
first non-whitespace position, as returned by
`occult--leading-whitespace', not necessarily the fold's outer
start.  END is the fold's outer end.

The result is capped at the end of the line containing BEG, the
fold END, or BEG plus `occult-summary-max-length' characters,
whichever comes first.  This means `occult-summary-max-length'
is measured from the first non-whitespace character of the fold,
so leading blank lines do not consume any of the budget."
  (save-excursion
    (goto-char beg)
    (min (line-end-position) end (+ beg occult-summary-max-length))))

(defun occult--leading-whitespace (beg end)
  "Return the first non-whitespace position in the range BEG..END.
Scans ASCII whitespace (space, tab, newline, carriage return,
form feed, vertical tab) forward from BEG, stopping at END at
the latest.  Returns END if the range is entirely whitespace.

Used by `occult--create-overlay' to skip leading blank lines
when computing where the visible summary begins, so the summary
is not wasted on empty leading whitespace."
  (save-excursion
    (goto-char beg)
    (skip-chars-forward " \t\n\r\f\v" end)
    (point)))

(defun occult--content-hash (beg end)
  "Compute a SHA-256 hash of buffer text between BEG and END."
  (secure-hash 'sha256 (buffer-substring-no-properties beg end)))

;;; Overlay lifecycle

(defun occult--create-overlay (beg end)
  "Create an occult fold spanning BEG to END.
The fold is backed by three overlays: a head overlay over any
leading whitespace that carries the indicator `before-string', a
body overlay over the hidden tail that carries the ellipsis
`before-string', and a parent overlay spanning the whole region
that owns the face, keymap, and modification-hook.

The head overlay is always created, even when there is no leading
whitespace to hide; in that case it is a zero-length overlay at
BEG.  Keeping the indicator on a single overlay (head) gives a
uniform rendering rule and avoids the ordering ambiguity that
arises when two overlays starting at the same position both
carry a `before-string'.

Returns the parent overlay."
  (let* ((head-split (occult--leading-whitespace beg end))
         (body-split (occult--visible-end head-split end))
         (body-text (buffer-substring-no-properties body-split end))
         (indicator (propertize occult-indicator 'face 'occult-indicator))
         (ellipsis (concat (propertize occult-ellipsis 'face 'occult-summary)
                           (if (string-match-p "\n" body-text) "\n" "")))
         (parent (make-overlay beg end nil t nil))
         (head (make-overlay beg head-split nil t nil))
         (body (make-overlay body-split end nil t nil)))
    ;; Parent overlay - spans the whole fold and owns the face, keymap,
    ;; and modification-hook.  Non-evaporating so that an edit which
    ;; collapses the region does not drop the parent before the
    ;; modification-hook has a chance to clean up head and body.
    (overlay-put parent 'occult t)
    (overlay-put parent 'occult-body body)
    (overlay-put parent 'occult-head head)
    (overlay-put parent 'face 'occult-summary)
    (overlay-put parent 'keymap occult-overlay-map)
    (overlay-put parent 'help-echo "Press TAB to expand")
    (overlay-put parent 'evaporate nil)
    (overlay-put parent 'modification-hooks (list #'occult--modification-hook))
    ;; Head overlay - always present (zero-length when no leading
    ;; whitespace) so that the indicator has a single, uniform home.
    ;; `invisible 'occult' hides any leading whitespace it covers;
    ;; on a zero-length head it is a no-op but harmless.
    (overlay-put head 'occult-parent parent)
    (overlay-put head 'before-string indicator)
    (overlay-put head 'invisible 'occult)
    (overlay-put head 'evaporate nil)
    ;; Body overlay - hides everything after the visible portion and
    ;; is the primary surface for isearch reveal.
    (overlay-put body 'occult-parent parent)
    (overlay-put body 'invisible 'occult)
    (overlay-put body 'before-string ellipsis)
    (overlay-put body 'evaporate t)
    (overlay-put body 'isearch-open-invisible #'occult--isearch-reveal)
    (overlay-put body 'isearch-open-invisible-temporary
                 #'occult--isearch-reveal-temporary)
    (occult--ensure-mode)
    parent))

(defun occult--delete-fold (ov)
  "Delete fold OV and its associated body overlay."
  (when (and ov (overlay-buffer ov))
    (when-let ((body (overlay-get ov 'occult-body)))
      (when (overlay-buffer body)
        (delete-overlay body)))
    (when-let ((head (overlay-get ov 'occult-head)))
      (when (overlay-buffer head)
        (delete-overlay head)))
    (delete-overlay ov)))

(defun occult--remove-overlay (ov)
  "Delete fold OV and clean up mode if no folds remain."
  (occult--delete-fold ov)
  (occult--maybe-disable-mode))

;;; isearch integration

(defun occult--isearch-reveal (body-ov)
  "Permanently reveal fold when isearch exits inside BODY-OV."
  (let ((parent (overlay-get body-ov 'occult-parent)))
    (when parent (occult--remove-overlay parent))))

(defun occult--isearch-reveal-temporary (body-ov hide-p)
  "Toggle body overlay BODY-OV visibility during isearch.
When HIDE-P is non-nil, re-hide.  Otherwise, reveal."
  (if hide-p
      (let* ((parent (overlay-get body-ov 'occult-parent))
             (split (overlay-start body-ov))
             (end (if parent (overlay-end parent) (overlay-end body-ov)))
             (body-text (buffer-substring-no-properties split end))
             (trailing (if (string-match-p "\n" body-text) "\n" "")))
        (overlay-put body-ov 'invisible 'occult)
        (overlay-put body-ov 'before-string
                     (concat (propertize occult-ellipsis 'face 'occult-summary)
                             trailing)))
    (overlay-put body-ov 'invisible nil)
    (overlay-put body-ov 'before-string nil)))

;;; Modification hook

(defun occult--modification-hook (ov after-p &rest _args)
  "Delete fold OV and its body when text is modified.
Only acts on the after-modification call (AFTER-P non-nil)."
  (when (and after-p (overlay-buffer ov))
    (occult--delete-fold ov)))

;;; Revert-buffer persistence

(defun occult--save-overlays ()
  "Snapshot all occult overlays before `revert-buffer'.
Stores position and content hash for later restoration."
  (setq occult--saved-overlays
        (mapcar (lambda (ov)
                  (list (overlay-start ov)
                        (overlay-end ov)
                        (occult--content-hash
                         (overlay-start ov) (overlay-end ov))))
                (occult--overlays-in (point-min) (point-max)))))

(defun occult--restore-overlays ()
  "Restore occult overlays after `revert-buffer'.
Only restores folds whose content hash still matches."
  (when occult--saved-overlays
    (dolist (entry occult--saved-overlays)
      (let ((beg (nth 0 entry))
            (end (nth 1 entry))
            (hash (nth 2 entry)))
        (when (and (<= end (point-max))
                   (string= hash (occult--content-hash beg end)))
          (occult--create-overlay beg end))))
    (setq occult--saved-overlays nil)))

;;; Auto-reveal and evil search support

(defun occult--re-hide-auto-revealed ()
  "Re-hide a previously auto-revealed overlay if point has left it."
  (when-let* ((parent occult--auto-reveal-ov)
              (live (overlay-buffer parent))
              (outside (or (< (point) (overlay-start parent))
                           (<= (overlay-end parent) (point)))))
    (when-let ((body (overlay-get parent 'occult-body)))
      (when (overlay-buffer body)
        (let* ((body-text (buffer-substring-no-properties
                           (overlay-start body) (overlay-end body)))
               (trailing (if (string-match-p "\n" body-text) "\n" "")))
          (overlay-put body 'invisible 'occult)
          (overlay-put body 'before-string
                       (concat (propertize occult-ellipsis 'face 'occult-summary)
                               trailing)))))
    (setq occult--auto-reveal-ov nil)))

(defun occult--auto-reveal-at-point ()
  "Temporarily reveal or describe the fold at point.
Behavior depends on `occult-auto-reveal'."
  (when-let ((parent (occult--overlay-at-point)))
    (pcase occult-auto-reveal
      ('echo
       (message "%s"
                (truncate-string-to-width
                 (buffer-substring-no-properties
                  (overlay-start parent) (overlay-end parent))
                 (* 5 (frame-width)) nil nil occult-ellipsis)))
      ('expand
       (when-let ((body (overlay-get parent 'occult-body)))
         (when (overlay-buffer body)
           (overlay-put body 'invisible nil)
           (overlay-put body 'before-string nil)))
       (setq occult--auto-reveal-ov parent)))))

(defun occult--post-command ()
  "Post-command handler for auto-reveal management."
  (occult--re-hide-auto-revealed)
  (occult--auto-reveal-at-point))

;;; Evil integration

(defun occult--evil-search-reveal (&rest _args)
  "After an evil search command, temporarily reveal the fold at point."
  (when-let ((parent (occult--overlay-at-point)))
    (when-let ((body (overlay-get parent 'occult-body)))
      (when (overlay-buffer body)
        (overlay-put body 'invisible nil)
        (overlay-put body 'before-string nil)))
    (setq occult--auto-reveal-ov parent)))

(defvar occult--evil-advised nil
  "Non-nil if evil search advice has been installed.")

(defun occult--setup-evil ()
  "Install advice on evil search commands for fold reveal."
  (unless occult--evil-advised
    (dolist (fn '(evil-ex-search-forward
                  evil-ex-search-backward
                  evil-ex-search-next
                  evil-ex-search-previous))
      (advice-add fn :after #'occult--evil-search-reveal))
    (setq occult--evil-advised t)))

;;; Internal minor mode

(define-minor-mode occult--mode
  "Internal mode managing occult hooks in the current buffer.
Not intended for direct use - activates automatically when folds
are created and deactivates when the last fold is removed."
  :lighter occult-lighter
  (if occult--mode
      (progn
        (add-to-invisibility-spec 'occult)
        (add-hook 'before-revert-hook #'occult--save-overlays nil t)
        (add-hook 'after-revert-hook #'occult--restore-overlays nil t)
        (add-hook 'post-command-hook #'occult--post-command nil t))
    (remove-from-invisibility-spec 'occult)
    (remove-hook 'before-revert-hook #'occult--save-overlays t)
    (remove-hook 'after-revert-hook #'occult--restore-overlays t)
    (remove-hook 'post-command-hook #'occult--post-command t)
    (setq occult--auto-reveal-ov nil)))

(defun occult--ensure-mode ()
  "Activate the internal mode if not already active."
  (unless occult--mode
    (occult--mode 1))
  (when (and (not occult--evil-advised)
             (featurep 'evil))
    (occult--setup-evil)))

(defun occult--maybe-disable-mode ()
  "Deactivate the internal mode if no folds remain in the buffer."
  (when (and occult--mode
             (null (occult--overlays-in (point-min) (point-max))))
    (occult--mode -1)))

(defun occult--determine-end ()
  (let ((end (region-end)))
    (if (= end (pos-eol))
        (+ 1 end)
      end)))

;;; Public commands

;;;###autoload
(defun occult-hide-region (beg end)
  "Collapse the region between BEG and END into a summary fold.
Existing folds overlapping the region are absorbed: their bounds
extend the new fold so no hidden content is lost.  Empty or blank
regions are silently refused."
  (when (and beg end (< beg end)
             (not (string-blank-p
                   (buffer-substring-no-properties beg end))))
    (dolist (ov (occult--overlays-in beg end))
      (setq beg (min beg (overlay-start ov))
            end (max end (overlay-end ov)))
      (occult--delete-fold ov))
    (occult--create-overlay beg end)
    (deactivate-mark)
    t))

;;;###autoload
(defun occult-toggle ()
  "Toggle an occult fold at point or on the active region.

With an active region, collapse it into a summary line.
With point on an existing fold (no region), expand it and
reactivate the region at the fold's original boundaries.
Otherwise, do nothing."
  (interactive)
  (if (use-region-p)
      (occult-hide-region (region-beginning)
                          (occult--determine-end))
    (if-let ((ov (occult--overlay-at-point)))
        (let ((beg (overlay-start ov))
              (end (overlay-end ov)))
          (occult--remove-overlay ov)
          (when (and beg end)
            (goto-char end)
            (set-mark beg)
            (activate-mark)))
      (user-error "No region selected and no occult fold at point"))))

;;;###autoload
(defun occult-reveal-all ()
  "Remove all occult folds in the current buffer."
  (interactive)
  (let ((ovs (occult--overlays-in (point-min) (point-max))))
    (mapc #'occult--delete-fold ovs)
    (occult--maybe-disable-mode)
    (message "Revealed %d fold(s)" (length ovs))))

;;; Edit mode for indirect-buffer editing

(defvar-local occult-edit--original-text nil
  "Text of the fold region at the moment the edit session began.
Used by `occult-edit-abort' to restore the original content.")

(defvar-local occult-edit--base-buffer nil
  "Base buffer the current edit session is attached to.")

(defvar-local occult-edit--read-only-p nil
  "Non-nil when the current session is a read-only (view) session.
Set from the base buffer's `buffer-read-only' at session start.")

(defvar occult-edit-mode-map (make-sparse-keymap)
  "Keymap active inside `occult-edit-mode'.
Rebuilt from `occult-edit-commit-key' and `occult-edit-abort-key'
by `occult-edit--rebuild-keymap'.")

(defun occult-edit--rebuild-keymap ()
  "Rebuild `occult-edit-mode-map' from the user custom key variables."
  (setcdr occult-edit-mode-map nil)
  (define-key occult-edit-mode-map (kbd occult-edit-commit-key)
              #'occult-edit-commit)
  (define-key occult-edit-mode-map (kbd occult-edit-abort-key)
              #'occult-edit-abort)
  occult-edit-mode-map)

;; Populate the keymap from the default custom values.
(occult-edit--rebuild-keymap)

(defun occult-edit--key-for (command)
  "Return human-readable key description for COMMAND in the edit keymap.
Falls back to the extended-command form when no key is bound."
  (let* ((result (where-is-internal command occult-edit-mode-map nil t))
         ;; `where-is-internal' can return either a single key sequence or
         ;; a list containing one, depending on Emacs version; normalise.
         (keys (if (and (consp result) (not (vectorp result)))
                   (car result)
                 result)))
    (if keys
        (key-description keys)
      (format "M-x %s" command))))

(defun occult-edit--header-line ()
  "Build the header-line string for the active edit session.
Renders a read-only-aware view when `occult-edit--read-only-p' is
non-nil (only a close action is shown)."
  (if occult-edit--read-only-p
      (let ((close (occult-edit--key-for #'occult-edit-abort)))
        (concat
         (propertize " View Occult Fold " 'face 'occult-edit-header)
         (propertize " │ " 'face 'occult-edit-header-separator)
         (propertize close 'face 'occult-edit-abort-key)
         (propertize " close " 'face 'occult-edit-header-separator)))
    (let ((commit (occult-edit--key-for #'occult-edit-commit))
          (abort (occult-edit--key-for #'occult-edit-abort)))
      (concat
       (propertize " Edit Occult Fold " 'face 'occult-edit-header)
       (propertize " │ " 'face 'occult-edit-header-separator)
       (propertize commit 'face 'occult-edit-commit-key)
       (propertize " commit " 'face 'occult-edit-header-separator)
       (propertize "│ " 'face 'occult-edit-header-separator)
       (propertize abort 'face 'occult-edit-abort-key)
       (propertize " abort " 'face 'occult-edit-header-separator)))))

(define-minor-mode occult-edit-mode
  "Minor mode active inside an occult fold edit session.
Provides a header-line with commit and abort bindings."
  :lighter occult-edit-lighter
  :keymap occult-edit-mode-map
  (if occult-edit-mode
      (progn
        (occult-edit--rebuild-keymap)
        (setq-local header-line-format '(:eval (occult-edit--header-line))))
    (kill-local-variable 'header-line-format)))

(defun occult-edit--cleanup-overlays ()
  "Remove occult overlays in the current (indirect) buffer.
Called right after creating the indirect buffer so the full fold
content becomes visible and editable, and no fold
modification-hooks fire on shared text edits."
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (or (overlay-get ov 'occult)
              (overlay-get ov 'occult-parent))
      (delete-overlay ov))))

;;;###autoload
(defun occult-edit-region ()
  "Edit the occult fold at point in a narrowed indirect buffer.
The fold overlay remains collapsed in the base buffer; the
indirect buffer shows the fold content in full for editing.  Text
is shared, so edits propagate immediately to the base buffer.
Use `occult-edit-commit' to keep the changes and close the
indirect buffer, or `occult-edit-abort' to restore the original
content.

If the base buffer is read-only, the session starts in a view-only
mode with a close binding and no commit/abort semantics."
  (interactive)
  (unless (occult--overlay-at-point)
    (user-error "No occult fold at point"))
  (let* ((ov (occult--overlay-at-point))
         (beg (overlay-start ov))
         (end (overlay-end ov))
         (original (buffer-substring-no-properties beg end))
         (base-buffer (current-buffer))
         (read-only-p buffer-read-only)
         (edit-name (generate-new-buffer-name
                     (format "*occult-%s: %s*"
                             (if read-only-p "view" "edit")
                             (buffer-name))))
         (buf (make-indirect-buffer base-buffer edit-name t)))
    (with-current-buffer buf
      (occult-edit--cleanup-overlays)
      (narrow-to-region beg end)
      (goto-char (point-min))
      (setq-local occult-edit--original-text original)
      (setq-local occult-edit--base-buffer base-buffer)
      (setq-local occult-edit--read-only-p read-only-p)
      (occult-edit-mode 1)
      (set-buffer-modified-p nil))
    (pop-to-buffer buf)
    buf))

(defun occult-edit--close-session ()
  "Kill the edit buffer and remove the window that was showing it.
Also removes the buffer from any other window that was displaying
it, deleting deletable windows and restoring the previous buffer
in dedicated or sole windows."
  (let ((buf (current-buffer)))
    (set-buffer-modified-p nil)
    (dolist (win (get-buffer-window-list buf nil t))
      (quit-window nil win))
    (when (buffer-live-p buf)
      (kill-buffer buf))))

(defun occult-edit-commit ()
  "Commit the current edit session and close the indirect buffer.
Changes already live in the base buffer because text is shared.
In a read-only view session this simply closes the view buffer."
  (interactive)
  (unless occult-edit-mode
    (user-error "Not in an occult edit session"))
  (let ((view-p occult-edit--read-only-p))
    (occult-edit--close-session)
    (message (if view-p "Occult view closed" "Occult edit committed"))))

(defun occult-edit-abort ()
  "Abort the current edit session, restoring the original fold content.
Prompts for confirmation if the buffer has unsaved modifications.
In a read-only view session this simply closes the view buffer
without touching the base buffer."
  (interactive)
  (unless occult-edit-mode
    (user-error "Not in an occult edit session"))
  (let ((view-p occult-edit--read-only-p)
        (original occult-edit--original-text))
    (if view-p
        (progn
          (occult-edit--close-session)
          (message "Occult view closed"))
      (when (and (buffer-modified-p)
                 (not (yes-or-no-p "Abort edit and discard changes? ")))
        (user-error "Aborted"))
      (let ((inhibit-modification-hooks t)
            (src (generate-new-buffer " *occult-orig*")))
        (unwind-protect
            (progn
              (with-current-buffer src (insert original))
              (replace-buffer-contents src))
          (kill-buffer src)))
      (occult-edit--close-session)
      (message "Occult edit aborted"))))

(provide 'occult)
;;; occult.el ends here
