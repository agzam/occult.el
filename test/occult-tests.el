;;; occult-tests.el --- Tests for occult.el -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  Tests for occult - collapse and reveal buffer regions.
;;
;;; Code:

(require 'buttercup)
(require 'occult)

;;; Helpers

(defmacro occult-test-with-buffer (text &rest body)
  "Run BODY in a temp buffer with TEXT inserted."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (goto-char (point-min))
     ,@body))

(defun occult-test--fold-count ()
  "Count occult folds (parent overlays) in the current buffer."
  (length (occult--overlays-in (point-min) (point-max))))

(defun occult-test--body-overlay (parent)
  "Get the body overlay associated with PARENT."
  (overlay-get parent 'occult-body))

(defun occult-test--head-overlay (parent)
  "Get the head overlay associated with PARENT."
  (overlay-get parent 'occult-head))

(defun occult-test--summary-text (parent)
  "Return the text the summary line of PARENT puts on screen.
Walks the visible part of the fold and takes the `display' string
wherever a replacement covers the buffer text."
  (let* ((body (overlay-get parent 'occult-body))
         (pos (overlay-end (occult-test--head-overlay parent)))
         (end (if (overlay-buffer body)
                  (overlay-start body)
                (overlay-end parent)))
         parts)
    (while (< pos end)
      (let ((next (next-single-char-property-change pos 'display nil end))
            (shown (get-char-property pos 'display)))
        (push (if (stringp shown)
                  shown
                (buffer-substring-no-properties pos next))
              parts)
        (setq pos next)))
    (apply #'concat (nreverse parts))))

;;; Visible end calculation

(describe "occult--visible-end"
  (it "returns end-of-first-line for short lines"
    (occult-test-with-buffer "Short\nSecond line\n"
      (expect (occult--visible-end 1 19) :to-equal 6)))

  (it "caps at occult-summary-max-length"
    (let ((occult-summary-max-length 5))
      (occult-test-with-buffer "This is a long first line\nSecond\n"
        (expect (occult--visible-end 1 33) :to-equal 6))))

  (it "does not exceed end"
    (occult-test-with-buffer "Hi\n"
      (expect (occult--visible-end 1 3) :to-equal 3))))


;;; Trim leading whitespace

(describe "occult--leading-whitespace"
  (it "does nothing for no leading whitespace"
    (occult-test-with-buffer "line with 17 char"
      (expect (occult--leading-whitespace 1 18) :to-be 1)))

  (it "gives first char that is not whitespace"
    (occult-test-with-buffer " \n\r\tline with 21 char"
      (expect (occult--leading-whitespace 1 22) :to-be 5)))

  (it "gives END when there is only whitespace"
    (occult-test-with-buffer " \n\r\t"
      (expect (occult--leading-whitespace 1 5) :to-be 5))))

;;; Ellipsis trailing newline

(describe "occult--ellipsis"
  (it "ends with a newline when the hidden text ends with one"
    (expect (occult--ellipsis "\nLine 3\n")
            :to-equal (concat occult-ellipsis "\n")))

  (it "has no newline when the hidden text stops before its newline"
    (expect (occult--ellipsis "\nLine 3") :to-equal occult-ellipsis))

  (it "has no newline for a single-line body"
    (expect (occult--ellipsis "rest of the line") :to-equal occult-ellipsis))

  (it "has no newline for an empty body"
    (expect (occult--ellipsis "") :to-equal occult-ellipsis)))

;;; Overlay creation - two-overlay structure

(describe "occult-hide-region"
  (it "creates a parent overlay spanning the full region"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\n"
      (occult-hide-region 1 22)
      (let ((parent (occult--overlay-at-point)))
        (expect parent :to-be-truthy)
        (expect (overlay-start parent) :to-equal 1)
        (expect (overlay-end parent) :to-equal 22))))

  (it "creates a body overlay for the hidden portion"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\n"
      (occult-hide-region 1 22)
      (let* ((parent (occult--overlay-at-point))
             (body (occult-test--body-overlay parent)))
        (expect body :to-be-truthy)
        (expect (overlay-get body 'invisible) :to-equal 'occult))))

  (it "leaves the first line as navigable text"
    (occult-test-with-buffer "Visible first line\nHidden second\n"
      (occult-hide-region 1 34)
      (let* ((parent (occult--overlay-at-point))
             (body (occult-test--body-overlay parent)))
        ;; Body starts after first line, not at fold start
        (expect (overlay-start body) :to-be-greater-than 1))))

  (it "shows indicator in head before-string"
    (occult-test-with-buffer "Hello\nWorld\n"
      (occult-hide-region 1 13)
      (let* ((parent (occult--overlay-at-point))
             (head (occult-test--head-overlay parent)))
        (expect (overlay-get head 'before-string) :to-match "📎")
        (expect (overlay-get parent 'before-string) :not :to-be-truthy))))

  (it "shows ellipsis in body before-string"
    (occult-test-with-buffer "Hello\nWorld\n"
      (occult-hide-region 1 13)
      (let* ((parent (occult--overlay-at-point))
             (body (occult-test--body-overlay parent)))
        (expect (overlay-get body 'before-string) :to-match "\\.\\.\\."))))

  (it "omits the ellipsis newline when the fold stops at end of line"
    ;; The newline after "Line 3" stays outside the fold and breaks the
    ;; line by itself; a newline in the ellipsis would add an empty line.
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\nLine 4\n"
      (occult-hide-region 8 21)
      (goto-char 8)
      (let ((body (occult-test--body-overlay (occult--overlay-at-point))))
        (expect (overlay-get body 'before-string) :to-equal occult-ellipsis))))

  (it "keeps the ellipsis newline when the fold ends after a newline"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\nLine 4\n"
      (occult-hide-region 8 22)
      (goto-char 8)
      (let ((body (occult-test--body-overlay (occult--overlay-at-point))))
        (expect (overlay-get body 'before-string)
                :to-equal (concat occult-ellipsis "\n")))))

  (it "absorbs a fully-contained overlapping fold"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\n"
      (occult-hide-region 8 15)
      (occult-hide-region 1 22)
      (let ((ovs (occult--overlays-in (point-min) (point-max))))
        (expect (length ovs) :to-equal 1)
        (expect (overlay-start (car ovs)) :to-equal 1)
        (expect (overlay-end (car ovs)) :to-equal 22))))

  (it "extends the new fold's end to absorb a partial overlap"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\n"
      (occult-hide-region 8 22)
      (occult-hide-region 1 15)
      (let ((ovs (occult--overlays-in (point-min) (point-max))))
        (expect (length ovs) :to-equal 1)
        (expect (overlay-start (car ovs)) :to-equal 1)
        (expect (overlay-end (car ovs)) :to-equal 22))))

  (it "extends the new fold's start to absorb a partial overlap"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\n"
      (occult-hide-region 1 8)
      (occult-hide-region 5 22)
      (let ((ovs (occult--overlays-in (point-min) (point-max))))
        (expect (length ovs) :to-equal 1)
        (expect (overlay-start (car ovs)) :to-equal 1)
        (expect (overlay-end (car ovs)) :to-equal 22))))

  (it "absorbs multiple overlapping folds into one span"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\n"
      (occult-hide-region 1 8)
      (occult-hide-region 15 22)
      (occult-hide-region 5 18)
      (let ((ovs (occult--overlays-in (point-min) (point-max))))
        (expect (length ovs) :to-equal 1)
        (expect (overlay-start (car ovs)) :to-equal 1)
        (expect (overlay-end (car ovs)) :to-equal 22))))

  (it "refuses empty regions"
    (occult-test-with-buffer "Hello\n"
      (expect (occult-hide-region 3 3) :not :to-be-truthy)))

  (it "refuses blank regions"
    (occult-test-with-buffer "   \n  \n"
      (expect (occult-hide-region 1 7) :not :to-be-truthy)))

  (it "returns truthy on success"
    (occult-test-with-buffer "Hello world\n"
      (expect (occult-hide-region 1 13) :to-be-truthy)))

  (it "works in read-only buffers"
    (occult-test-with-buffer "Read only content\n"
      (setq buffer-read-only t)
      (occult-hide-region 1 19)
      (expect (occult-test--fold-count) :to-equal 1)))

  (it "creates a head overlay for leading whitespace"
    (occult-test-with-buffer " \t\r\nLine 1\nLine 2\nLine 3\n"
      (occult-hide-region 1 26)
      (let* ((parent (occult--overlay-at-point))
             (head (occult-test--head-overlay parent)))
        (expect head :to-be-truthy)
        (expect (overlay-end head) :to-be 5)
        (expect (overlay-get head 'invisible) :to-equal 'occult))))

  (it "creates a zero-length head overlay when there is no leading whitespace"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\n"
      (occult-hide-region 1 22)
      (let* ((parent (occult--overlay-at-point))
             (head (occult-test--head-overlay parent)))
        (expect head :to-be-truthy)
        (expect (overlay-buffer head) :to-be-truthy)
        (expect (overlay-start head) :to-equal 1)
        (expect (overlay-end head) :to-equal 1)
        (expect (overlay-get head 'before-string) :to-match "📎"))))

  (it "shows indicator in head before-string with leading whitespace"
    (occult-test-with-buffer " \t\r\nLine 1\nLine 2\nLine 3\n"
      (occult-hide-region 1 26)
      (let* ((parent (occult--overlay-at-point))
             (head (occult-test--head-overlay parent)))
        (expect (overlay-get parent 'before-string) :not :to-be-truthy)
        (expect (overlay-get head 'before-string) :to-match "📎"))))

  (it "measures summary-max-length from first non-whitespace position"
    ;; With two leading newlines and cap = 3, the visible content
    ;; starts at pos 3 and body-split lands at pos 3+3 = 6.  Before
    ;; the leading-whitespace fix the cap was measured from beg (pos
    ;; 1) and body-split would have been at pos 4.
    (let ((occult-summary-max-length 3))
      (occult-test-with-buffer "\n\nHello World\n"
        (occult-hide-region 1 15)
        (let* ((parent (occult--overlay-at-point))
               (body (occult-test--body-overlay parent))
               (head (occult-test--head-overlay parent)))
          (expect (overlay-end head) :to-equal 3)
          (expect (overlay-start body) :to-equal 6))))))

;;; Toggle

(describe "occult-toggle"
  (it "collapses active region"
    (occult-test-with-buffer "Line 1\nLine 2\n"
      (set-mark 1)
      (goto-char 15)
      (activate-mark)
      (occult-toggle)
      (expect (occult-test--fold-count) :to-equal 1)))

  (it "absorbs existing folds when called with an overlapping region"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\n"
      (occult-hide-region 8 15)
      (set-mark 1)
      (goto-char 22)
      (activate-mark)
      (occult-toggle)
      (let ((ovs (occult--overlays-in (point-min) (point-max))))
        (expect (length ovs) :to-equal 1)
        (expect (overlay-start (car ovs)) :to-equal 1)
        (expect (overlay-end (car ovs)) :to-equal 22))))

  (it "folds a backward selection the same as a forward one"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\nLine 4\n"
      (set-mark 21)
      (goto-char 8)
      (activate-mark)
      (occult-toggle)
      (let* ((parent (car (occult--overlays-in (point-min) (point-max))))
             (body (occult-test--body-overlay parent)))
        (expect (overlay-start parent) :to-equal 8)
        (expect (overlay-end parent) :to-equal 21)
        (expect (overlay-get body 'before-string) :to-equal occult-ellipsis))))

  (it "collapses a selection that reaches point-max without a trailing newline"
    (occult-test-with-buffer "Line 1\nLine 2"
      (set-mark 8)
      (goto-char (point-max))
      (activate-mark)
      (occult-toggle)
      (let ((parent (car (occult--overlays-in (point-min) (point-max)))))
        (expect (overlay-start parent) :to-equal 8)
        (expect (overlay-end parent) :to-equal (point-max)))))

  (it "collapses a selection that reaches the end of a narrowed buffer"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\nLine 4\n"
      (narrow-to-region 8 21)
      (set-mark 8)
      (goto-char (point-max))
      (activate-mark)
      (occult-toggle)
      (let ((parent (car (occult--overlays-in (point-min) (point-max)))))
        (expect (overlay-start parent) :to-equal 8)
        (expect (overlay-end parent) :to-equal 21))))

  (it "expands fold at point - removes both overlays"
    (occult-test-with-buffer "Line 1\nLine 2\n"
      (occult-hide-region 1 15)
      (goto-char 1)
      (occult-toggle)
      (expect (occult-test--fold-count) :to-equal 0)
      ;; Verify no stale body overlays remain
      (expect (length (overlays-in (point-min) (point-max))) :to-equal 0)))

  (it "signals when nothing to toggle"
    (occult-test-with-buffer "Hello\n"
      (goto-char 1)
      (expect (occult-toggle) :to-throw 'user-error))))

;;; Toggle region restore

(describe "occult-toggle region restore"
  (it "activates region after expanding a fold"
    (occult-test-with-buffer "Line 1\nLine 2\n"
      (occult-hide-region 1 15)
      (goto-char 1)
      (occult-toggle)
      (expect (region-active-p) :to-be-truthy)))

  (it "restored region matches original fold boundaries"
    (occult-test-with-buffer "Line 1\nLine 2\n"
      (occult-hide-region 1 15)
      (goto-char 1)
      (occult-toggle)
      (expect (region-beginning) :to-equal 1)
      (expect (region-end) :to-equal 15)))

  (it "places point at end and mark at beg"
    (occult-test-with-buffer "Line 1\nLine 2\n"
      (occult-hide-region 1 15)
      (goto-char 1)
      (occult-toggle)
      (expect (point) :to-equal 15)
      (expect (mark) :to-equal 1)))

  (it "overrides a pre-existing deactivated mark elsewhere"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\n"
      (push-mark 20 t nil)
      (occult-hide-region 1 8)
      (goto-char 1)
      (occult-toggle)
      (expect (region-beginning) :to-equal 1)
      (expect (region-end) :to-equal 8)
      (expect (region-active-p) :to-be-truthy)))

  (it "does not activate region after occult-reveal-all"
    (occult-test-with-buffer "Line 1\nLine 2\n"
      (occult-hide-region 1 15)
      (goto-char 1)
      (occult-reveal-all)
      (expect (region-active-p) :not :to-be-truthy))))

;;; Reveal all

(describe "occult-reveal-all"
  (it "removes all folds including body overlays"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\nLine 4\n"
      (occult-hide-region 1 8)
      (occult-hide-region 15 22)
      (expect (occult-test--fold-count) :to-equal 2)
      (occult-reveal-all)
      (expect (occult-test--fold-count) :to-equal 0)
      (expect (length (overlays-in (point-min) (point-max))) :to-equal 0)))

  (it "disables internal mode after revealing all"
    (occult-test-with-buffer "Hello world\n"
      (occult-hide-region 1 13)
      (expect occult--mode :to-be-truthy)
      (occult-reveal-all)
      (expect occult--mode :not :to-be-truthy))))

;;; Internal mode lifecycle

(describe "occult--mode"
  (it "activates when first fold is created"
    (occult-test-with-buffer "Hello world\n"
      (expect occult--mode :not :to-be-truthy)
      (occult-hide-region 1 13)
      (expect occult--mode :to-be-truthy)))

  (it "deactivates when last fold is removed"
    (occult-test-with-buffer "Hello world\n"
      (occult-hide-region 1 13)
      (goto-char 1)
      (occult-toggle)
      (expect occult--mode :not :to-be-truthy)))

  (it "adds occult to invisibility spec when active"
    (occult-test-with-buffer "Hello world\n"
      (occult-hide-region 1 13)
      (expect (memq 'occult buffer-invisibility-spec) :to-be-truthy)))

  (it "removes occult from invisibility spec when deactivated"
    (occult-test-with-buffer "Hello world\n"
      (occult-hide-region 1 13)
      (occult-reveal-all)
      (expect (memq 'occult buffer-invisibility-spec) :not :to-be-truthy))))

;;; Buffer text preservation

(describe "buffer text preservation"
  (it "buffer-string returns full text with active folds"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\n"
      (occult-hide-region 1 22)
      (expect (buffer-string) :to-equal "Line 1\nLine 2\nLine 3\n")))

  (it "buffer-substring-no-properties returns full text"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\n"
      (occult-hide-region 1 22)
      (expect (buffer-substring-no-properties 1 22)
              :to-equal "Line 1\nLine 2\nLine 3\n"))))

;;; Revert persistence

(describe "revert persistence"
  (it "saves overlay state"
    (occult-test-with-buffer "Hello world\n"
      (occult-hide-region 1 13)
      (occult--save-overlays)
      (expect occult--saved-overlays :to-be-truthy)
      (expect (length occult--saved-overlays) :to-equal 1)))

  (it "restores overlays when content matches"
    (occult-test-with-buffer "Hello world\n"
      (occult-hide-region 1 13)
      (occult--save-overlays)
      ;; Simulate revert - remove all overlays manually
      (dolist (ov (overlays-in (point-min) (point-max)))
        (delete-overlay ov))
      (expect (occult-test--fold-count) :to-equal 0)
      (occult--restore-overlays)
      (expect (occult-test--fold-count) :to-equal 1)))

  (it "skips restoration when content hash mismatches"
    (occult-test-with-buffer "Hello world\n"
      (occult-hide-region 1 13)
      (occult--save-overlays)
      (dolist (ov (overlays-in (point-min) (point-max)))
        (delete-overlay ov))
      ;; Mutate buffer content
      (goto-char 1)
      (delete-char 5)
      (insert "Goodbye")
      (occult--restore-overlays)
      (expect (occult-test--fold-count) :to-equal 0))))

;;; Content hash

(describe "occult--content-hash"
  (it "returns consistent hash for same content"
    (occult-test-with-buffer "Hello world\n"
      (let ((h1 (occult--content-hash 1 13))
            (h2 (occult--content-hash 1 13)))
        (expect h1 :to-equal h2))))

  (it "returns different hash for different content"
    (occult-test-with-buffer "Hello world, goodbye world\n"
      (let ((h1 (occult--content-hash 1 13))
            (h2 (occult--content-hash 13 28)))
        (expect h1 :not :to-equal h2)))))

;;; isearch integration

(describe "isearch integration"
  (it "sets isearch-open-invisible on body overlay"
    (occult-test-with-buffer "First line\nSecond line\n"
      (occult-hide-region 1 23)
      (let* ((parent (occult--overlay-at-point))
             (body (occult-test--body-overlay parent)))
        (expect (overlay-get body 'isearch-open-invisible) :to-be-truthy))))

  (it "permanently reveals via isearch-open-invisible on body"
    (occult-test-with-buffer "First line\nSecond line\n"
      (occult-hide-region 1 23)
      (let* ((parent (occult--overlay-at-point))
             (body (occult-test--body-overlay parent)))
        (occult--isearch-reveal body)
        (expect (occult-test--fold-count) :to-equal 0)
        ;; Both overlays gone
        (expect (length (overlays-in (point-min) (point-max))) :to-equal 0))))

  (it "temporarily reveals and re-hides body"
    (occult-test-with-buffer "First line\nSecond line\n"
      (occult-hide-region 1 23)
      (let* ((parent (occult--overlay-at-point))
             (body (occult-test--body-overlay parent)))
        ;; Reveal
        (occult--isearch-reveal-temporary body nil)
        (expect (overlay-get body 'invisible) :to-equal nil)
        (expect (overlay-get body 'before-string) :to-equal nil)
        ;; Re-hide
        (occult--isearch-reveal-temporary body t)
        (expect (overlay-get body 'invisible) :to-equal 'occult)
        (expect (overlay-get body 'before-string) :to-be-truthy))))

  (it "re-hides without the ellipsis newline when the fold stops at end of line"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\nLine 4\n"
      (occult-hide-region 8 21)
      (goto-char 8)
      (let ((body (occult-test--body-overlay (occult--overlay-at-point))))
        (occult--isearch-reveal-temporary body nil)
        (occult--isearch-reveal-temporary body t)
        (expect (overlay-get body 'before-string) :to-equal occult-ellipsis)))))

;;; Auto-reveal re-hide

(describe "occult--re-hide-auto-revealed"
  (it "re-hides without the ellipsis newline when the fold stops at end of line"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\nLine 4\n"
      (occult-hide-region 8 21)
      (goto-char 8)
      (let ((occult-auto-reveal 'expand))
        (occult--auto-reveal-at-point)
        (let ((body (occult-test--body-overlay occult--auto-reveal-ov)))
          (expect (overlay-get body 'before-string) :to-be nil)
          (goto-char 22)
          (occult--re-hide-auto-revealed)
          (expect (overlay-get body 'invisible) :to-equal 'occult)
          (expect (overlay-get body 'before-string)
                  :to-equal occult-ellipsis))))))

;;; Navigability

(describe "cursor navigation"
  (it "allows point on the visible portion of a fold"
    (occult-test-with-buffer "Visible text here\nHidden text\n"
      (occult-hide-region 1 30)
      ;; Point should be placeable within the visible first line
      (goto-char 5)
      (expect (point) :to-equal 5)
      (expect (occult--overlay-at-point) :to-be-truthy)))

  (it "body overlay starts after visible text"
    (occult-test-with-buffer "First line\nSecond line\nThird line\n"
      (let ((occult-summary-max-length 50))
        (occult-hide-region 1 35)
        (let* ((parent (occult--overlay-at-point))
               (body (occult-test--body-overlay parent)))
          ;; Body should not start at position 1
          (expect (overlay-start body) :to-be-greater-than 1)
          ;; Body should start at end of first line (pos 11)
          (expect (overlay-start body) :to-equal 11))))))

;;; Indirect-buffer editing

(defmacro occult-test-with-edit-session (text fold-beg fold-end &rest body)
  "Run BODY inside an active occult-edit session.
TEXT is inserted into a new base buffer with a fold at FOLD-BEG..FOLD-END.
BODY runs in the edit buffer; bindings BASE and EDIT are available.
The edit buffer and base buffer are cleaned up at the end."
  (declare (indent 3))
  `(let ((base (generate-new-buffer "*occult-test-base*")))
     (unwind-protect
         (let (edit)
           (with-current-buffer base
             (insert ,text)
             (goto-char (point-min))
             (occult-hide-region ,fold-beg ,fold-end)
             (goto-char (+ ,fold-beg 1))
             (setq edit (save-window-excursion (occult-edit-region))))
           (unwind-protect
               (with-current-buffer edit ,@body)
             (when (buffer-live-p edit) (kill-buffer edit))))
       (when (buffer-live-p base) (kill-buffer base)))))

(describe "occult-edit-region"
  (it "opens a narrowed indirect buffer for the fold at point"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\n"
      (occult-hide-region 1 15)
      (goto-char 3)
      (let* ((base (current-buffer))
             (buf (save-window-excursion (occult-edit-region))))
        (unwind-protect
            (with-current-buffer buf
              (expect (buffer-base-buffer) :to-equal base)
              (expect (point-min) :to-equal 1)
              (expect (point-max) :to-equal 15))
          (when (buffer-live-p buf) (kill-buffer buf))))))

  (it "signals when no fold is at point"
    (occult-test-with-buffer "Hello\n"
      (goto-char 1)
      (expect (occult-edit-region) :to-throw 'user-error)))

  (it "works for buffers without file association"
    (occult-test-with-edit-session "Line 1\nLine 2\nLine 3\n" 1 15
      (expect (buffer-live-p (current-buffer)) :to-be-truthy)
      (expect (buffer-base-buffer) :not :to-be nil)))

  (it "removes occult overlays inside the indirect buffer"
    (occult-test-with-edit-session "Line 1\nLine 2\nLine 3\n" 1 15
      (let ((occult-ovs
             (cl-remove-if-not
              (lambda (ov)
                (or (overlay-get ov 'occult)
                    (overlay-get ov 'occult-parent)))
              (overlays-in (point-min) (point-max)))))
        (expect (length occult-ovs) :to-equal 0))))

  (it "keeps fold collapsed in the base buffer"
    (occult-test-with-edit-session "Line 1\nLine 2\nLine 3\n" 1 15
      (with-current-buffer (buffer-base-buffer)
        (expect (cl-find-if (lambda (ov) (overlay-get ov 'occult))
                            (overlays-in (point-min) (point-max)))
                :to-be-truthy))))

  (it "activates occult-edit-mode in the indirect buffer"
    (occult-test-with-edit-session "Line 1\nLine 2\nLine 3\n" 1 15
      (expect occult-edit-mode :to-be-truthy)
      (expect header-line-format :not :to-be nil)))

  (it "does not dissolve fold when editing inside the indirect buffer"
    (occult-test-with-edit-session "Line 1\nLine 2\nLine 3\n" 1 15
      (goto-char 3)
      (insert "X")
      (with-current-buffer (buffer-base-buffer)
        (expect (cl-find-if (lambda (ov) (overlay-get ov 'occult))
                            (overlays-in (point-min) (point-max)))
                :to-be-truthy)))))

(describe "occult-edit-commit"
  (it "keeps user changes in the base buffer and kills the indirect buffer"
    (let ((base (generate-new-buffer "*occult-commit-test*")))
      (unwind-protect
          (let (edit)
            (with-current-buffer base
              (insert "Line 1\nLine 2\nLine 3\n")
              (goto-char (point-min))
              (occult-hide-region 1 15)
              (goto-char 3)
              (setq edit (save-window-excursion (occult-edit-region))))
            (with-current-buffer edit
              (goto-char 3)
              (insert "EDIT ")
              (occult-edit-commit))
            (expect (buffer-live-p edit) :not :to-be-truthy)
            (expect (with-current-buffer base
                      (buffer-substring-no-properties (point-min) (point-max)))
                    :to-match "LiEDIT "))
        (when (buffer-live-p base) (kill-buffer base)))))

  (it "signals when called outside an edit session"
    (with-temp-buffer
      (expect (occult-edit-commit) :to-throw 'user-error))))

(describe "occult-edit-abort"
  (it "restores original fold content in the base buffer"
    (let ((base (generate-new-buffer "*occult-abort-test*")))
      (unwind-protect
          (let ((original "Line 1\nLine 2\nLine 3\n")
                edit)
            (with-current-buffer base
              (insert original)
              (goto-char (point-min))
              (occult-hide-region 1 15)
              (goto-char 3)
              (setq edit (save-window-excursion (occult-edit-region))))
            (with-current-buffer edit
              (goto-char 3)
              (insert "EDIT ")
              ;; Bypass confirmation prompt
              (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
                (occult-edit-abort)))
            (expect (buffer-live-p edit) :not :to-be-truthy)
            (expect (with-current-buffer base
                      (buffer-substring-no-properties (point-min) (point-max)))
                    :to-equal original))
        (when (buffer-live-p base) (kill-buffer base)))))

  (it "preserves fold overlays in the base buffer after abort"
    (let ((base (generate-new-buffer "*occult-abort-ov-test*")))
      (unwind-protect
          (let (edit)
            (with-current-buffer base
              (insert "Line 1\nLine 2\nLine 3\n")
              (goto-char (point-min))
              (occult-hide-region 1 15)
              (goto-char 3)
              (setq edit (save-window-excursion (occult-edit-region))))
            (with-current-buffer edit
              (goto-char 3)
              (insert "EDIT ")
              (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
                (occult-edit-abort)))
            (with-current-buffer base
              (expect (cl-find-if (lambda (ov) (overlay-get ov 'occult))
                                  (overlays-in (point-min) (point-max)))
                      :to-be-truthy)
              (expect (cl-find-if (lambda (ov) (overlay-get ov 'occult-parent))
                                  (overlays-in (point-min) (point-max)))
                      :to-be-truthy)))
        (when (buffer-live-p base) (kill-buffer base)))))

  (it "signals when called outside an edit session"
    (with-temp-buffer
      (expect (occult-edit-abort) :to-throw 'user-error))))

(describe "occult-edit header-line"
  (it "includes the configured commit and abort key descriptions"
    (occult-test-with-edit-session "Line 1\nLine 2\nLine 3\n" 1 15
      (let ((header (occult-edit--header-line)))
        (expect header :to-match (regexp-quote "C-c C-c"))
        (expect header :to-match (regexp-quote "C-c C-k"))
        (expect header :to-match "commit")
        (expect header :to-match "abort"))))

  (it "reflects re-bound keys dynamically"
    (occult-test-with-edit-session "Line 1\nLine 2\nLine 3\n" 1 15
      ;; Re-bind commit to a different key in the mode map
      (let ((occult-edit-mode-map (copy-keymap occult-edit-mode-map)))
        (define-key occult-edit-mode-map (kbd "C-c C-c") nil)
        (define-key occult-edit-mode-map (kbd "C-c C-s") #'occult-edit-commit)
        (let ((header (occult-edit--header-line)))
          (expect header :to-match "C-c C-s"))))))

(describe "occult-edit read-only (view) session"
  (it "starts a view session when base buffer is read-only"
    (let ((base (generate-new-buffer "*occult-ro-test*")))
      (unwind-protect
          (let (edit)
            (with-current-buffer base
              (insert "Line 1\nLine 2\nLine 3\n")
              (goto-char (point-min))
              (occult-hide-region 1 15)
              (setq buffer-read-only t)
              (goto-char 3)
              (setq edit (save-window-excursion (occult-edit-region))))
            (unwind-protect
                (with-current-buffer edit
                  (expect occult-edit--read-only-p :to-be-truthy))
              (when (buffer-live-p edit) (kill-buffer edit))))
        (when (buffer-live-p base) (kill-buffer base)))))

  (it "shows View label and close key in header-line"
    (let ((base (generate-new-buffer "*occult-ro-header-test*")))
      (unwind-protect
          (let (edit)
            (with-current-buffer base
              (insert "Line 1\nLine 2\nLine 3\n")
              (goto-char (point-min))
              (occult-hide-region 1 15)
              (setq buffer-read-only t)
              (goto-char 3)
              (setq edit (save-window-excursion (occult-edit-region))))
            (unwind-protect
                (with-current-buffer edit
                  (let ((header (occult-edit--header-line)))
                    (expect header :to-match "View Occult Fold")
                    (expect header :to-match "close")
                    (expect header :not :to-match "commit")
                    (expect header :not :to-match "abort")))
              (when (buffer-live-p edit) (kill-buffer edit))))
        (when (buffer-live-p base) (kill-buffer base)))))

  (it "abort in view session just closes without modifying base"
    (let ((base (generate-new-buffer "*occult-ro-abort-test*")))
      (unwind-protect
          (let ((original "Line 1\nLine 2\nLine 3\n")
                edit)
            (with-current-buffer base
              (insert original)
              (goto-char (point-min))
              (occult-hide-region 1 15)
              (setq buffer-read-only t)
              (goto-char 3)
              (setq edit (save-window-excursion (occult-edit-region))))
            (with-current-buffer edit (occult-edit-abort))
            (expect (buffer-live-p edit) :not :to-be-truthy)
            (with-current-buffer base
              (expect (buffer-substring-no-properties
                       (point-min) (point-max)) :to-equal original)
              (expect (cl-find-if (lambda (ov) (overlay-get ov 'occult))
                                  (overlays-in (point-min) (point-max)))
                      :to-be-truthy)))
        (when (buffer-live-p base) (kill-buffer base)))))

  (it "commit in view session also just closes"
    (let ((base (generate-new-buffer "*occult-ro-commit-test*")))
      (unwind-protect
          (let (edit)
            (with-current-buffer base
              (insert "Line 1\nLine 2\nLine 3\n")
              (goto-char (point-min))
              (occult-hide-region 1 15)
              (setq buffer-read-only t)
              (goto-char 3)
              (setq edit (save-window-excursion (occult-edit-region))))
            (with-current-buffer edit (occult-edit-commit))
            (expect (buffer-live-p edit) :not :to-be-truthy))
        (when (buffer-live-p base) (kill-buffer base))))))

(describe "occult-edit session window cleanup"
  (it "commit deletes the window opened by the edit session"
    (let ((base (generate-new-buffer "*occult-win-commit*")))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (switch-to-buffer base)
            (with-current-buffer base
              (insert "Line 1\nLine 2\nLine 3\n")
              (goto-char (point-min))
              (occult-hide-region 1 15)
              (goto-char 3))
            (let* ((edit (occult-edit-region))
                   (during (length (window-list))))
              (with-current-buffer edit (occult-edit-commit))
              (expect during :to-equal 2)
              (expect (length (window-list)) :to-equal 1)))
        (when (buffer-live-p base) (kill-buffer base)))))

  (it "abort deletes the window opened by the edit session"
    (let ((base (generate-new-buffer "*occult-win-abort*")))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (switch-to-buffer base)
            (with-current-buffer base
              (insert "Line 1\nLine 2\nLine 3\n")
              (goto-char (point-min))
              (occult-hide-region 1 15)
              (goto-char 3))
            (let* ((edit (occult-edit-region))
                   (during (length (window-list))))
              (with-current-buffer edit
                (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
                  (occult-edit-abort)))
              (expect during :to-equal 2)
              (expect (length (window-list)) :to-equal 1)))
        (when (buffer-live-p base) (kill-buffer base)))))

  (it "does not error when edit buffer shares window with base"
    (let ((base (generate-new-buffer "*occult-win-same*")))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (switch-to-buffer base)
            (with-current-buffer base
              (insert "Line 1\nLine 2\nLine 3\n")
              (goto-char (point-min))
              (occult-hide-region 1 15)
              (goto-char 3))
            (let* ((display-buffer-alist
                    '((".*" display-buffer-same-window)))
                   (edit (occult-edit-region)))
              (with-current-buffer edit (occult-edit-commit))
              (expect (length (window-list)) :to-equal 1)
              ;; base buffer should be visible again in the sole window
              (expect (window-buffer) :to-equal base)))
        (when (buffer-live-p base) (kill-buffer base))))))

(describe "occult with leading whitespace"
  (it "cleans up head overlay inside the indirect edit buffer"
    (occult-test-with-edit-session "\n\nLine 1\nLine 2\nLine 3\n" 1 24
      (let ((occult-ovs
             (cl-remove-if-not
              (lambda (ov)
                (or (overlay-get ov 'occult)
                    (overlay-get ov 'occult-parent)))
              (overlays-in (point-min) (point-max)))))
        (expect (length occult-ovs) :to-equal 0))))

  (it "keeps head overlay alive in the base buffer during edit session"
    (occult-test-with-edit-session "\n\nLine 1\nLine 2\nLine 3\n" 1 24
      (with-current-buffer (buffer-base-buffer)
        (let* ((parent (cl-find-if (lambda (ov) (overlay-get ov 'occult))
                                   (overlays-in (point-min) (point-max))))
               (head (overlay-get parent 'occult-head)))
          (expect head :to-be-truthy)
          (expect (overlay-buffer head) :to-be-truthy)
          (expect (overlay-end head) :to-equal 3)
          (expect (overlay-get head 'before-string) :to-match "📎")))))

  (it "restores head overlay after revert-buffer round-trip"
    (occult-test-with-buffer "\n\nHello world\n"
      (occult-hide-region 1 15)
      (occult--save-overlays)
      (dolist (ov (overlays-in (point-min) (point-max)))
        (delete-overlay ov))
      (expect (occult-test--fold-count) :to-equal 0)
      (occult--restore-overlays)
      (expect (occult-test--fold-count) :to-equal 1)
      (let* ((parent (cl-find-if (lambda (ov) (overlay-get ov 'occult))
                                 (overlays-in (point-min) (point-max))))
             (head (overlay-get parent 'occult-head)))
        (expect head :to-be-truthy)
        (expect (overlay-end head) :to-equal 3)
        (expect (overlay-get head 'before-string) :to-match "📎")))))

;;; Revert persistence

(describe "occult--restore-overlays"
  (it "does not duplicate a fold whose overlays survived the revert"
    (occult-test-with-buffer "Hello world\nmore\n"
      (occult-hide-region 1 (point-max))
      (occult--save-overlays)
      ;; No overlay deletion in between: `insert-file-contents' leaves
      ;; unchanged text alone, so the fold's overlays outlive the revert.
      (occult--restore-overlays)
      (expect (occult-test--fold-count) :to-equal 1)))

  (it "keeps one fold across revert-buffer of a file"
    (let ((file (make-temp-file "occult-test-" nil nil "Hello world\nmore\n")))
      (unwind-protect
          (with-temp-buffer
            (insert-file-contents file)
            (setq buffer-file-name file)
            (occult-hide-region 1 (point-max))
            (revert-buffer t t t)
            (expect (occult-test--fold-count) :to-equal 1)
            (with-temp-file file (insert "Hello world\nmore\nappended\n"))
            (revert-buffer t t t)
            (expect (occult-test--fold-count) :to-equal 1)
            (let ((parent (car (occult--overlays-in (point-min) (point-max)))))
              (expect (overlay-start parent) :to-equal 1)
              (expect (overlay-end parent) :to-equal 18))
            (set-buffer-modified-p nil))
        (delete-file file)))))

;;; Summary replacements

(describe "occult-summary-replace-alist"
  (it "leaves the summary alone when nil"
    (occult-test-with-buffer "Reading MANIFEST.md ✅ 0s\nbody\n"
      (occult-hide-region 1 (point-max))
      (expect (occult-test--summary-text (occult--overlay-at-point))
              :to-equal "Reading MANIFEST.md ✅ 0s")))

  (it "displays a match as its replacement"
    (occult-test-with-buffer "Reading MANIFEST.md ✅ 0s\nbody\n"
      (setq-local occult-summary-replace-alist '((" ✅ [0-9]+s" . "")))
      (occult-hide-region 1 (point-max))
      (expect (occult-test--summary-text (occult--overlay-at-point))
              :to-equal "Reading MANIFEST.md")))

  (it "keeps the text that follows the match"
    (occult-test-with-buffer "Editing a.el +8 -5 ✅ 0s view diff\nbody\n"
      (setq-local occult-summary-replace-alist '((" ✅ [0-9]+s" . "")))
      (occult-hide-region 1 (point-max))
      (expect (occult-test--summary-text (occult--overlay-at-point))
              :to-equal "Editing a.el +8 -5 view diff")))

  (it "leaves the buffer text as it was"
    (occult-test-with-buffer "Reading MANIFEST.md ✅ 0s\nbody\n"
      (setq-local occult-summary-replace-alist '((" ✅ [0-9]+s" . "")))
      (occult-hide-region 1 (point-max))
      (expect (buffer-substring-no-properties 1 25)
              :to-equal "Reading MANIFEST.md ✅ 0s")))

  (it "replaces every match on the line, not only the first"
    (occult-test-with-buffer "a X b X c\nbody\n"
      (setq-local occult-summary-replace-alist '(("X" . "-")))
      (occult-hide-region 1 (point-max))
      (expect (occult-test--summary-text (occult--overlay-at-point))
              :to-equal "a - b - c")))

  (it "applies entries in the order they are listed"
    (occult-test-with-buffer "Thought 8s\nbody\n"
      (setq-local occult-summary-replace-alist
                  '(("Thought" . "think:") (" \\([0-9]+\\)s" . " [\\1]")))
      (occult-hide-region 1 (point-max))
      (expect (occult-test--summary-text (occult--overlay-at-point))
              :to-equal "think: [8]")))

  (it "takes a function of the matched text"
    (occult-test-with-buffer "Called tool: grep\nbody\n"
      (setq-local occult-summary-replace-alist
                  `(("Called tool: " . ,(lambda (match) (upcase match)))))
      (occult-hide-region 1 (point-max))
      (expect (occult-test--summary-text (occult--overlay-at-point))
              :to-equal "CALLED TOOL: grep")))

  (it "leaves the match alone when the function returns no string"
    (occult-test-with-buffer "Called tool: grep\nbody\n"
      (setq-local occult-summary-replace-alist
                  `(("Called tool: " . ,(lambda (_match) 42))))
      (occult-hide-region 1 (point-max))
      (expect (occult-test--summary-text (occult--overlay-at-point))
              :to-equal "Called tool: grep")
      (expect (overlay-get (occult--overlay-at-point) 'occult-summary-overlays)
              :to-equal nil)))

  (it "skips a match overlapping an earlier replacement"
    (occult-test-with-buffer "abcd\nbody\n"
      (setq-local occult-summary-replace-alist '(("abc" . "X") ("bcd" . "Y")))
      (occult-hide-region 1 (point-max))
      (expect (occult-test--summary-text (occult--overlay-at-point))
              :to-equal "Xd")))

  (it "steps over a regexp that matches the empty string"
    (occult-test-with-buffer "empty match test\nbody\n"
      (setq-local occult-summary-replace-alist '(("x*" . "#")))
      (occult-hide-region 1 (point-max))
      (expect (occult-test--summary-text (occult--overlay-at-point))
              :to-equal "empty match test")))

  (it "replaces up to the cap when the match runs past it"
    (let ((occult-summary-max-length 13))
      (occult-test-with-buffer "Called tool ✅ 0s\nbody\n"
        (setq-local occult-summary-replace-alist '((" ✅ [0-9]+s" . "")))
        (occult-hide-region 1 (point-max))
        (expect (occult-test--summary-text (occult--overlay-at-point))
                :to-equal "Called tool"))))

  (it "ignores a match that starts past the cap"
    (let ((occult-summary-max-length 11))
      (occult-test-with-buffer "Called tool ✅ 0s\nbody\n"
        (setq-local occult-summary-replace-alist '((" ✅ [0-9]+s" . "X")))
        (occult-hide-region 1 (point-max))
        (expect (occult-test--summary-text (occult--overlay-at-point))
                :to-equal "Called tool"))))

  (it "keeps the fold reachable when everything is replaced away"
    (occult-test-with-buffer "all of it goes\nbody\n"
      (setq-local occult-summary-replace-alist '((".*" . "")))
      (occult-hide-region 1 (point-max))
      (goto-char 1)
      (expect (occult-test--summary-text (occult--overlay-at-point)) :to-equal "")
      (expect (occult--overlay-at-point) :to-be-truthy)))

  (it "does not disturb the caller's match data"
    (occult-test-with-buffer "Reading MANIFEST.md ✅ 0s\nbody\n"
      (setq-local occult-summary-replace-alist '((" ✅ [0-9]+s" . "")))
      (goto-char (point-min))
      (re-search-forward "MANIFEST")
      (let ((start (match-beginning 0)))
        (occult-hide-region 1 (point-max))
        (expect (match-beginning 0) :to-equal start))))

  (it "is buffer-local when set"
    (occult-test-with-buffer "Reading MANIFEST.md ✅ 0s\nbody\n"
      (setq occult-summary-replace-alist '((" ✅ [0-9]+s" . "")))
      (expect (local-variable-p 'occult-summary-replace-alist) :to-be-truthy)
      (expect (default-value 'occult-summary-replace-alist) :to-be nil))))

;;; Summary line prefix

(describe "occult-summary-line-prefix"
  (it "replaces the prefix the buffer draws on the summary line"
    (occult-test-with-buffer
        (concat (propertize "Reading MANIFEST.md" 'line-prefix "⏵ ") "\nbody\n")
      (setq-local occult-summary-line-prefix "")
      (occult-hide-region 1 (point-max))
      (expect (get-char-property 1 'line-prefix) :to-equal "")))

  (it "keeps the buffer's prefix when nil"
    (occult-test-with-buffer
        (concat (propertize "Reading MANIFEST.md" 'line-prefix "⏵ ") "\nbody\n")
      (occult-hide-region 1 (point-max))
      (expect (get-char-property 1 'line-prefix) :to-equal "⏵ ")))

  (it "stops at the end of the summary"
    (occult-test-with-buffer
        (concat (propertize "Reading MANIFEST.md\nbody\n" 'line-prefix "⏵ "))
      (setq-local occult-summary-line-prefix "")
      (occult-hide-region 1 (point-max))
      (let ((body (occult-test--body-overlay (occult--overlay-at-point))))
        (expect (get-char-property (overlay-start body) 'line-prefix)
                :to-equal "⏵ ")))))

;;; Per-buffer indicator

(describe "occult-indicator"
  (it "takes the value the buffer set"
    (occult-test-with-buffer "Hello\nWorld\n"
      (setq occult-indicator "⧟ ")
      (occult-hide-region 1 13)
      (expect (overlay-get (occult-test--head-overlay (occult--overlay-at-point))
                           'before-string)
              :to-match "⧟")
      (expect (default-value 'occult-indicator) :to-equal "📎 "))))

;;; Summary overlay lifecycle

(describe "summary overlays"
  (it "die with the fold"
    (occult-test-with-buffer "Reading MANIFEST.md ✅ 0s\nbody\n"
      (setq-local occult-summary-replace-alist '((" ✅ [0-9]+s" . ""))
                  occult-summary-line-prefix "")
      (occult-hide-region 1 (point-max))
      (let* ((parent (occult--overlay-at-point))
             (extras (overlay-get parent 'occult-summary-overlays)))
        (expect (length extras) :to-equal 2)
        (occult--delete-fold parent)
        (expect (cl-remove-if-not #'overlay-buffer extras) :to-equal nil))))

  (it "come back with the fold after a revert"
    (occult-test-with-buffer "Reading MANIFEST.md ✅ 0s\nbody\n"
      (setq-local occult-summary-replace-alist '((" ✅ [0-9]+s" . "")))
      (occult-hide-region 1 (point-max))
      (occult--save-overlays)
      (dolist (ov (overlays-in (point-min) (point-max)))
        (delete-overlay ov))
      (occult--restore-overlays)
      (goto-char 1)
      (expect (occult-test--summary-text (occult--overlay-at-point))
              :to-equal "Reading MANIFEST.md")))

  (it "are gone from the indirect edit buffer"
    ;; `let' on a variable with `:local t' binds the default, which the
    ;; base buffer the macro makes has no local value to shadow.
    (let ((occult-summary-replace-alist '((" ✅ [0-9]+s" . ""))))
      (occult-test-with-edit-session "Reading MANIFEST.md ✅ 0s\nbody\n" 1 31
        (expect (cl-remove-if-not
                 (lambda (ov) (or (overlay-get ov 'occult)
                                  (overlay-get ov 'occult-parent)))
                 (overlays-in (point-min) (point-max)))
                :to-equal nil)))))

(provide 'occult-tests)

;; Local Variables:
;; package-lint-main-file: "occult.el"
;; End:
;;; occult-tests.el ends here
