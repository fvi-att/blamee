;;; blamee-test.el --- Tests for blamee.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 fvi-att
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'seq)
(require 'blamee)

(defun blamee-test--git (&rest args)
  "Run git with ARGS in `default-directory'."
  (let ((status (apply #'call-process "git" nil nil nil args)))
    (unless (eq status 0)
      (error "git %s failed with status %s"
             (string-join args " ")
             status))))

(defun blamee-test--write-file (file contents)
  "Write CONTENTS to FILE."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert contents)))

(defun blamee-test--commit (message author date)
  "Commit all changes as AUTHOR at DATE with MESSAGE."
  (let ((process-environment
         (append
          (list (format "GIT_AUTHOR_NAME=%s" author)
                (format "GIT_AUTHOR_EMAIL=%s@example.invalid" author)
                (format "GIT_COMMITTER_NAME=%s" author)
                (format "GIT_COMMITTER_EMAIL=%s@example.invalid" author)
                (format "GIT_AUTHOR_DATE=%s" date)
                (format "GIT_COMMITTER_DATE=%s" date))
          process-environment)))
    (blamee-test--git "add" ".")
    (blamee-test--git "commit" "-q" "-m" message)))

(defmacro blamee-test--with-temp-repo (&rest body)
  "Create a throwaway git repository and evaluate BODY inside it."
  (declare (indent 0) (debug t))
  `(let* ((repo (make-temp-file "blamee-test-" t))
          (default-directory repo))
     (unwind-protect
         (progn
           (blamee-test--git "init" "-q")
           (blamee-test--git "config" "user.name" "Test User")
           (blamee-test--git "config" "user.email" "test@example.invalid")
           ,@body)
       (delete-directory repo t))))

(defun blamee-test--make-two-commit-file (repo)
  "Create a file in REPO with two blamed chunks and return its path."
  (let ((file (expand-file-name "sample.txt" repo)))
    (blamee-test--write-file file "one\ntwo\nthree\n")
    (blamee-test--commit "initial" "Alice" "2026-04-23T12:00:00 +0000")
    (blamee-test--write-file file "one\ntwo\nTHREE\n")
    (blamee-test--commit "change third" "Bob" "2026-04-24T12:00:00 +0000")
    file))

(defmacro blamee-test--with-blamed-buffer (file &rest body)
  "Visit FILE with `blamee-mode' enabled and evaluate BODY."
  (declare (indent 1) (debug t))
  `(let ((buffer (find-file-noselect ,file))
         (blamee-popup-enabled nil)
         (blamee-inline-columns '(date author))
         (blamee-date-format "%y-%m-%d")
         (blamee-separator " |")
         (blamee-separator-tty " |"))
     (unwind-protect
         (with-current-buffer buffer
           (blamee-mode 1)
           ,@body)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when (bound-and-true-p blamee-mode)
             (blamee-mode -1)))
         (kill-buffer buffer)))))

(defun blamee-test--goto-line (lineno)
  "Move point to the beginning of line LINENO."
  (goto-char (point-min))
  (forward-line (1- lineno)))

(defun blamee-test--prefix-at-line (lineno)
  "Return the line prefix string shown on line LINENO.
This looks the `line-prefix' property up at the line beginning, exactly
like the display engine does."
  (save-excursion
    (blamee-test--goto-line lineno)
    (get-char-property (line-beginning-position) 'line-prefix)))

(defun blamee-test--align-to-px (prefix)
  "Return the final `:align-to' pixel position of PREFIX, or nil."
  (let ((display (get-text-property (1- (length prefix)) 'display prefix)))
    (pcase display
      (`(space :align-to (,px)) px))))

(defun blamee-test--line-count ()
  "Return the number of non-phantom lines in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((count 0))
      (while (not (eobp))
        (cl-incf count)
        (forward-line 1))
      count)))

(defun blamee-test--should-cover-every-line ()
  "Assert that every line shows a blamee prefix aligned to the same position."
  (let ((target nil))
    (dotimes (index (blamee-test--line-count))
      (let ((prefix (blamee-test--prefix-at-line (1+ index))))
        (should prefix)
        (let ((px (blamee-test--align-to-px prefix)))
          (should px)
          (if target
              (should (= target px))
            (setq target px)))))))

(ert-deftest blamee-parse-porcelain-reuses-commit-metadata ()
  (let ((hash (make-string 40 ?a)))
    (with-temp-buffer
      (insert hash " 1 1 2\n"
              "author Alice\n"
              "author-time 1776945600\n"
              "summary initial\n"
              "\tone\n"
              hash " 2 2\n"
              "\ttwo\n")
      (let ((entries (blamee--parse-porcelain)))
        (should (= 2 (length entries)))
        (should (= 1 (caar entries)))
        (should (= 2 (caadr entries)))
        (should (equal "Alice" (plist-get (cdar entries) :author)))
        (should (equal "initial" (plist-get (cdadr entries) :summary)))))))

(ert-deftest blamee-chunks-groups-consecutive-same-commit-lines ()
  (let* ((alice (list :hash (make-string 40 ?a) :author "Alice"))
         (bob (list :hash (make-string 40 ?b) :author "Bob"))
         (entries (list (cons 1 alice) (cons 2 alice)
                        (cons 3 bob)
                        (cons 4 alice)))
         (chunks (blamee--chunks entries)))
    (should (equal (list (list 1 2 alice)
                         (list 3 3 bob)
                         (list 4 4 alice))
                   chunks))))

(ert-deftest blamee-prefix-strings-align-to-the-same-pixel-position ()
  (let* ((blamee-inline-columns '(date author hash))
         (blamee-date-format "%y-%m-%d")
         (blamee-separator " |")
         (blamee-separator-tty " |")
         (commit (list :hash (concat "abcdef" (make-string 34 ?0))
                       :author "Alice"
                       :author-time 1776945600
                       :summary "initial"))
         (columns (blamee--inline-columns commit))
         (layout (blamee--compute-layout (list columns)))
         (prefix (blamee--prefix-string columns layout commit nil))
         (blank (blamee--blank-string layout commit nil)))
    (should (string-match-p "Alice" prefix))
    (should (string-match-p "abcdef" prefix))
    (should-not (string-match-p "Alice" blank))
    ;; Both variants end with a stretch glyph snapping the source text
    ;; to the same pixel position, so they cannot disagree on width.
    (should (= (plist-get layout :total-px)
               (blamee-test--align-to-px prefix)))
    (should (= (plist-get layout :total-px)
               (blamee-test--align-to-px blank)))))

(ert-deftest blamee-compute-layout-keeps-inter-column-gap ()
  "Column slots must include the gap so adjacent columns never touch."
  (let* ((blamee-inline-columns '(date author))
         (blamee-date-format "%y-%m-%d")
         (blamee-separator-tty " |")
         (commit (list :hash (make-string 40 ?a)
                       :author "Alice"
                       :author-time 1776945600
                       :summary "x"))
         (layout (blamee--compute-layout
                  (list (blamee--inline-columns commit)))))
    ;; date = 8 columns + 1 gap → 9; author "Alice" = 5 → 14 (no
    ;; trailing gap; the separator's own leading space provides it).
    (should (equal '((date . 9) (author . 14))
                   (plist-get layout :columns)))
    (should (= 14 (plist-get layout :separator-px)))
    ;; " |" = 2 columns, plus the trailing gap before the source text.
    (should (= 17 (plist-get layout :total-px)))))

(ert-deftest blamee-compute-layout-skips-empty-columns ()
  (let* ((blamee-inline-columns '(date author))
         (blamee-date-format "%y-%m-%d")
         (commit (list :hash blamee--zero-hash))
         (layout (blamee--compute-layout
                  (list (blamee--inline-columns commit)))))
    ;; Uncommitted lines have no date, so only the author slot remains.
    (should (= 1 (length (plist-get layout :columns))))
    (should (eq 'author (caar (plist-get layout :columns))))))

(ert-deftest blamee-mode-renders-git-blame-chunks ()
  (blamee-test--with-temp-repo
    (let ((file (blamee-test--make-two-commit-file repo)))
      (blamee-test--with-blamed-buffer file
        ;; Chunk 1 (lines 1-2, Alice): full + continuation overlay.
        ;; Chunk 2 (line 3, Bob): full overlay only.
        (should (= 3 (length blamee--overlays)))
        (blamee-test--should-cover-every-line)
        (let ((first (blamee-test--prefix-at-line 1))
              (second (blamee-test--prefix-at-line 2))
              (third (blamee-test--prefix-at-line 3)))
          (should (string-match-p "26-04-23" first))
          (should (string-match-p "Alice" first))
          (should-not (string-match-p "Alice" second))
          (should (string-match-p (regexp-quote blamee-separator) second))
          (should (string-match-p "26-04-24" third))
          (should (string-match-p "Bob" third)))))))

(ert-deftest blamee-mode-keeps-cursor-off-the-prefix ()
  "The prefix must not be a string at BOL that swallows the cursor."
  (blamee-test--with-temp-repo
    (let ((file (blamee-test--make-two-commit-file repo)))
      (blamee-test--with-blamed-buffer file
        (dolist (ov blamee--overlays)
          (should-not (overlay-get ov 'before-string))
          (should (get-char-property (overlay-start ov) 'line-prefix)))))))

(ert-deftest blamee-mode-keeps-coverage-while-editing-inside-a-chunk ()
  (blamee-test--with-temp-repo
    (let ((file (blamee-test--make-two-commit-file repo)))
      (blamee-test--with-blamed-buffer file
        ;; Split line 1: the new line stays inside the chunk overlay.
        (goto-char (point-min))
        (end-of-line)
        (insert "\ndraft")
        (should (= 4 (blamee-test--line-count)))
        (blamee-test--should-cover-every-line)

        ;; Merge it back by deleting the newline.
        (goto-char (point-min))
        (end-of-line)
        (delete-char 1)
        (should (= 3 (blamee-test--line-count)))
        (blamee-test--should-cover-every-line)

        ;; In-line edits keep the prefix on the first chunk line.
        (goto-char (point-min))
        (insert "X")
        (should (string-match-p "Alice" (blamee-test--prefix-at-line 1)))
        (blamee-test--should-cover-every-line)))))

(ert-deftest blamee-mode-backfills-lines-appended-at-buffer-end ()
  (blamee-test--with-temp-repo
    (let ((file (blamee-test--make-two-commit-file repo)))
      (blamee-test--with-blamed-buffer file
        (goto-char (point-max))
        (insert "appended\nlines")
        (should (= 5 (blamee-test--line-count)))
        (blamee-test--should-cover-every-line)
        ;; The backfilled lines carry no commit, so the popup stays away.
        (save-excursion
          (blamee-test--goto-line 4)
          (should-not (blamee--commit-at-point)))))))

(ert-deftest blamee-commit-at-point-works-on-continuation-lines ()
  (blamee-test--with-temp-repo
    (let ((file (blamee-test--make-two-commit-file repo)))
      (blamee-test--with-blamed-buffer file
        (save-excursion
          (blamee-test--goto-line 2)
          (let ((commit (blamee--commit-at-point)))
            (should commit)
            (should (equal "Alice" (plist-get commit :author)))))))))

(ert-deftest blamee-copy-commit-hash-at-point-copies-current-line-hash ()
  (blamee-test--with-temp-repo
    (let ((file (blamee-test--make-two-commit-file repo)))
      (blamee-test--with-blamed-buffer file
        (let (kill-ring)
          (goto-char (point-min))
          (blamee-copy-commit-hash-at-point)
          (should (string-match-p "\\`[0-9a-f]\\{40\\}\\'" (car kill-ring))))))))

(ert-deftest blamee-mode-disabling-removes-all-overlays ()
  (blamee-test--with-temp-repo
    (let ((file (blamee-test--make-two-commit-file repo)))
      (blamee-test--with-blamed-buffer file
        (should blamee--overlays)
        (blamee-mode -1)
        (should-not blamee--overlays)
        (should-not (seq-some (lambda (ov) (overlay-get ov 'blamee))
                              (overlays-in (point-min) (point-max))))))))

(provide 'blamee-test)

;;; blamee-test.el ends here
