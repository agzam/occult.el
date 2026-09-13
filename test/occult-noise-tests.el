;;; occult-noise-tests.el --- Tests for noise folding -*- lexical-binding: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  Tests for `occult-fold-noise' and the options behind it, with org
;;  source blocks as the reference client.
;;
;;; Code:

(require 'buttercup)
(require 'occult)
(require 'org)

;;; Helpers

(defconst noise-test-src-block-regexp
  "^[ \t]*#\\+begin_src\\(?:.*\n\\)*?[ \t]*#\\+end_src.*"
  "One org source block, first line to last.")

(defmacro noise-test-with-buffer (text &rest body)
  "Run BODY in a temp buffer holding TEXT, point at the start."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (goto-char (point-min))
     ,@body))

(defun noise-test-folds ()
  "Fold bounds in the buffer, sorted by start."
  (sort (mapcar (lambda (ov) (cons (overlay-start ov) (overlay-end ov)))
                (occult--overlays-in (point-min) (point-max)))
        (lambda (a b) (< (car a) (car b)))))

(defun noise-test-lines (region)
  "REGION as (FIRST-LINE . LAST-LINE)."
  (cons (line-number-at-pos (car region))
        (line-number-at-pos (cdr region))))

(defun noise-test-summary (region)
  "The text of the first line of REGION."
  (save-excursion
    (goto-char (car region))
    (buffer-substring-no-properties (point) (line-end-position))))

(defconst noise-test-org
  "* Heading one
Prose before.
#+begin_src elisp
(+ 1 2)
#+end_src

#+begin_src sh
ls
#+end_src
Prose between.
#+begin_src sh
pwd
#+end_src
** Sub heading
Sub prose.
  #+begin_src elisp
  (message \"indented\")
  #+end_src
* Heading two
Tail prose.
"
  "Blocks adjacent across a blank line, across prose, and inside a subtree.")

(defun noise-test-org-buffer ()
  "Set up the org fixture in the current buffer."
  (insert noise-test-org)
  (org-mode)
  (setq-local occult-noise-regexps (list noise-test-src-block-regexp))
  (goto-char (point-min)))

;;; Regions from regexps

(describe "occult--noise-regions"
  (it "widens a match to whole lines"
    (noise-test-with-buffer "keep\nsome DEBUG here\nkeep\n"
      (setq-local occult-noise-regexps '("DEBUG"))
      (expect (occult--noise-regions) :to-equal '((6 . 21)))))

  (it "stops a match ending on a newline at that line"
    (noise-test-with-buffer "keep\nDEBUG one\nkeep\n"
      (setq-local occult-noise-regexps '("^DEBUG.*\n"))
      (expect (mapcar #'noise-test-lines (occult--noise-regions))
              :to-equal '((2 . 2)))))

  (it "merges matches that only blank lines separate"
    (noise-test-with-buffer "keep\nDEBUG one\n\n\nDEBUG two\nkeep\n"
      (setq-local occult-noise-regexps '("^DEBUG.*"))
      (expect (mapcar #'noise-test-lines (occult--noise-regions))
              :to-equal '((2 . 5)))))

  (it "keeps matches apart across prose"
    (noise-test-with-buffer "DEBUG one\nprose\nDEBUG two\n"
      (setq-local occult-noise-regexps '("^DEBUG.*"))
      (expect (mapcar #'noise-test-lines (occult--noise-regions))
              :to-equal '((1 . 1) (3 . 3)))))

  (it "merges adjacent and overlapping matches from several regexps"
    (noise-test-with-buffer "DEBUG one\nTRACE two\nkeep\nDEBUG TRACE\n"
      (setq-local occult-noise-regexps '("^DEBUG.*" "TRACE.*"))
      (expect (mapcar #'noise-test-lines (occult--noise-regions))
              :to-equal '((1 . 2) (4 . 4)))))

  (it "marks nothing on an empty match and does not spin"
    (noise-test-with-buffer "one\ntwo\n"
      (setq-local occult-noise-regexps '("q*"))
      (expect (occult--noise-regions) :to-equal nil)))

  (it "honors case-fold-search"
    (noise-test-with-buffer "debug one\nkeep\n"
      (setq-local occult-noise-regexps '("^DEBUG"))
      (let ((case-fold-search t))
        (expect (length (occult--noise-regions)) :to-equal 1))
      (let ((case-fold-search nil))
        (expect (occult--noise-regions) :to-equal nil))))

  (it "leaves the caller's match data alone"
    (noise-test-with-buffer "DEBUG one\n"
      (setq-local occult-noise-regexps '("^DEBUG.*"))
      (string-match "\\(b\\)c" "abc")
      (occult--noise-regions)
      (expect (match-string 1 "abc") :to-equal "b")))

  (it "takes the stretches from occult-noise-regions-function instead"
    (noise-test-with-buffer "one\ntwo\nthree\nfour\n"
      (setq-local occult-noise-regexps '("^one")
                  occult-noise-regions-function
                  (lambda () (list (cons 9 14) (cons 1 4))))
      (expect (occult--noise-regions) :to-equal '((1 . 4) (9 . 14)))))

  (it "returns nothing when neither option is set"
    (noise-test-with-buffer "one\ntwo\n"
      (expect (occult--noise-regions) :to-equal nil))))

;;; The command

(describe "occult-fold-noise"
  (it "folds one fold per stretch and returns the count"
    (noise-test-with-buffer "keep\nDEBUG one\nDEBUG two\nkeep\nDEBUG three\nkeep\n"
      (setq-local occult-noise-regexps '("^DEBUG.*"))
      (expect (occult-fold-noise) :to-equal 2)
      (expect (mapcar #'noise-test-lines (noise-test-folds))
              :to-equal '((2 . 3) (5 . 5)))))

  (it "shows the first line of each stretch as the summary"
    (noise-test-with-buffer "keep\nDEBUG one\nDEBUG two\nkeep\n"
      (setq-local occult-noise-regexps '("^DEBUG.*"))
      (occult-fold-noise)
      (let ((fold (car (noise-test-folds))))
        (expect (noise-test-summary fold) :to-equal "DEBUG one")
        (expect (invisible-p (save-excursion (goto-char (car fold))
                                             (forward-line 1) (point)))
                :to-be-truthy))))

  (it "folds nothing on a second run and keeps the folds it made"
    (noise-test-with-buffer "keep\nDEBUG one\nDEBUG two\nkeep\n"
      (setq-local occult-noise-regexps '("^DEBUG.*"))
      (occult-fold-noise)
      (let ((before (occult--overlays-in (point-min) (point-max))))
        (expect (occult-fold-noise) :to-equal 0)
        (expect (occult--overlays-in (point-min) (point-max)) :to-equal before))))

  (it "leaves a stretch a larger fold already hides alone"
    (noise-test-with-buffer "keep\nDEBUG one\nkeep\nDEBUG two\nkeep\n"
      (setq-local occult-noise-regexps '("^DEBUG.*"))
      (occult-hide-region 1 (point-max))
      (expect (occult-fold-noise) :to-equal 0)
      (expect (noise-test-folds) :to-equal (list (cons 1 (point-max))))))

  (it "absorbs a fold overlapping a stretch"
    (noise-test-with-buffer "keep\nDEBUG one\nDEBUG two\nkeep\n"
      (setq-local occult-noise-regexps '("^DEBUG.*"))
      (occult-hide-region 1 15)
      (expect (occult-fold-noise) :to-equal 1)
      (expect (mapcar #'noise-test-lines (noise-test-folds)) :to-equal '((1 . 3)))))

  (it "folds only the stretches reaching into BEG..END"
    (noise-test-with-buffer "DEBUG one\nkeep\nDEBUG two\nkeep\nDEBUG three\n"
      (setq-local occult-noise-regexps '("^DEBUG.*"))
      (let ((two (save-excursion (goto-char (point-min)) (forward-line 2) (point))))
        (expect (occult-fold-noise two (+ two 3)) :to-equal 1)
        (expect (mapcar #'noise-test-lines (noise-test-folds)) :to-equal '((3 . 3))))))

  (it "folds a stretch that straddles END"
    (noise-test-with-buffer "keep\nDEBUG one\nDEBUG two\nkeep\n"
      (setq-local occult-noise-regexps '("^DEBUG.*"))
      (expect (occult-fold-noise 1 8) :to-equal 1)
      (expect (mapcar #'noise-test-lines (noise-test-folds)) :to-equal '((2 . 3)))))

  (it "keeps the mark active when called from Lisp"
    (noise-test-with-buffer "keep\nDEBUG one\nkeep\n"
      (setq-local occult-noise-regexps '("^DEBUG.*"))
      (let ((transient-mark-mode t))
        (push-mark (point-min) t t)
        (goto-char 4)
        (occult-fold-noise)
        (expect mark-active :to-be-truthy)
        (expect (length (noise-test-folds)) :to-equal 1))))

  (it "deactivates the mark when called interactively on a region"
    (noise-test-with-buffer "keep\nDEBUG one\nkeep\nDEBUG two\n"
      (setq-local occult-noise-regexps '("^DEBUG.*"))
      (let ((transient-mark-mode t))
        (push-mark (point-min) t t)
        (goto-char 8)
        (funcall-interactively #'occult-fold-noise (point-min) 8)
        (expect mark-active :to-be nil)
        (expect (mapcar #'noise-test-lines (noise-test-folds)) :to-equal '((2 . 2))))))

  (it "is undone by occult-reveal-all"
    (noise-test-with-buffer "keep\nDEBUG one\nkeep\nDEBUG two\n"
      (setq-local occult-noise-regexps '("^DEBUG.*"))
      (occult-fold-noise)
      (occult-reveal-all)
      (expect (noise-test-folds) :to-equal nil)
      (expect (buffer-string) :to-equal "keep\nDEBUG one\nkeep\nDEBUG two\n"))))

;;; Org source blocks, the reference client

(describe "occult-fold-noise in org"
  (it "folds every source block and no prose"
    (with-temp-buffer
      (noise-test-org-buffer)
      (expect (occult-fold-noise) :to-equal 3)
      (expect (mapcar #'noise-test-lines (noise-test-folds))
              :to-equal '((3 . 9) (11 . 13) (16 . 18)))
      (dolist (fold (noise-test-folds))
        (expect (noise-test-summary fold) :to-match "#\\+begin_src"))))

  (it "keeps a fold inside a subtree through hide and show"
    (with-temp-buffer
      (noise-test-org-buffer)
      (occult-fold-noise)
      (let ((before (noise-test-folds)))
        (goto-char (point-min))
        (search-forward "** Sub heading")
        (org-fold-hide-subtree)
        (expect (noise-test-folds) :to-equal before)
        (org-fold-show-all)
        (expect (noise-test-folds) :to-equal before))))

  (it "leaves a fold made while its subtree is hidden intact once shown"
    (with-temp-buffer
      (noise-test-org-buffer)
      (goto-char (point-min))
      (search-forward "** Sub heading")
      (org-fold-hide-subtree)
      (occult-fold-noise)
      (org-fold-show-all)
      (let ((fold (car (last (noise-test-folds)))))
        (expect (noise-test-lines fold) :to-equal '(16 . 18))
        (expect (noise-test-summary fold) :to-equal "  #+begin_src elisp")
        (let ((parent (car (occult--overlays-in (car fold) (cdr fold)))))
          (expect (overlay-end (overlay-get parent 'occult-head))
                  :to-equal (+ (car fold) 2))))))

  (it "folds 2000 blocks in a 20k-line document within the budget"
    (with-temp-buffer
      (dotimes (i 2000)
        (insert (format "* Heading %d\nProse %d.\n" i i))
        (insert "#+begin_src elisp\n(+ 1 2)\n(+ 3 4)\n#+end_src\n")
        (dotimes (_ 6) (insert "More prose.\n")))
      (org-mode)
      (setq-local occult-noise-regexps (list noise-test-src-block-regexp))
      (expect (count-lines (point-min) (point-max)) :to-equal 24000)
      (let ((start (float-time)))
        (expect (occult-fold-noise) :to-equal 2000)
        (expect (- (float-time) start) :to-be-less-than 10.0))
      (let ((start (float-time)))
        (occult-reveal-all)
        (expect (- (float-time) start) :to-be-less-than 10.0))
      (expect (noise-test-folds) :to-equal nil))))

(provide 'occult-noise-tests)
;;; occult-noise-tests.el ends here
