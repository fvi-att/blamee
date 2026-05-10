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
         (blamee-separator " |"))
     (unwind-protect
         (progn
           (set-window-buffer (selected-window) buffer)
           (with-current-buffer buffer
             (blamee-mode 1)
             (blamee--update-visible-layout (selected-window))
             ,@body))
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when (bound-and-true-p blamee-mode)
             (blamee-mode -1)))
         (kill-buffer buffer)))))

(defun blamee-test--line-overlays (lineno)
  "Return blamee overlays on line LINENO in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- lineno))
    (let ((bol (line-beginning-position)))
      (seq-filter (lambda (overlay) (overlay-get overlay 'blamee))
                  (overlays-in bol (1+ bol))))))

(defun blamee-test--before-string-at-line (lineno)
  "Return the unpropertized blamee before-string on line LINENO."
  (substring-no-properties
   (or (overlay-get (car (blamee-test--line-overlays lineno))
                    'before-string)
       "")))

(defun blamee-test--line-count ()
  "Return the number of non-phantom lines in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((count 0))
      (while (not (eobp))
        (cl-incf count)
        (forward-line 1))
      count)))

(defun blamee-test--should-have-one-overlay-per-line ()
  "Assert that every real line has exactly one blamee overlay at BOL."
  (dotimes (index (blamee-test--line-count))
    (let* ((lineno (1+ index))
           (overlays (blamee-test--line-overlays lineno)))
      (should (= 1 (length overlays)))
      (save-excursion
        (goto-char (point-min))
        (forward-line index)
        (should (= (line-beginning-position)
                   (overlay-start (car overlays))))))))

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

(ert-deftest blamee-format-prefix-keeps-continuation-width ()
  (let* ((blamee-inline-columns '(date author hash))
         (blamee-date-format "%y-%m-%d")
         (blamee-separator " |")
         (commit (list :hash (concat "abcdef" (make-string 34 ?0))
                       :author "Alice"
                       :author-time 1776945600
                       :summary "initial"))
         (columns (blamee--inline-columns commit))
         (widths (blamee--inline-widths columns))
         (prefix (blamee--format-prefix columns widths))
         (blank (blamee--format-prefix columns widths t)))
    (should (string-match-p "Alice" prefix))
    (should (string-match-p "abcdef" prefix))
    (should-not (string-match-p "Alice" blank))
    (should (= (string-width prefix) (string-width blank)))))

(ert-deftest blamee-mode-renders-git-blame-chunks ()
  (blamee-test--with-temp-repo
    (let ((file (blamee-test--make-two-commit-file repo)))
      (blamee-test--with-blamed-buffer file
        (should (= 3 (length blamee--overlays)))
        (blamee-test--should-have-one-overlay-per-line)
        (let ((first (blamee-test--before-string-at-line 1))
              (second (blamee-test--before-string-at-line 2))
              (third (blamee-test--before-string-at-line 3)))
          (should (string-match-p "26-04-23" first))
          (should (string-match-p "Alice" first))
          (should-not (string-match-p "Alice" second))
          (should (= (string-width first) (string-width second)))
          (should (string-match-p "26-04-24" third))
          (should (string-match-p "Bob" third)))))))

(ert-deftest blamee-mode-keeps-overlay-coverage-after-local-edits ()
  (blamee-test--with-temp-repo
    (let ((file (blamee-test--make-two-commit-file repo)))
      (blamee-test--with-blamed-buffer file
        (goto-char (point-min))
        (end-of-line)
        (insert "\ndraft")
        (blamee--update-visible-layout (selected-window))
        (should (= 4 (blamee-test--line-count)))
        (blamee-test--should-have-one-overlay-per-line)
        (should (overlay-get (car (blamee-test--line-overlays 2))
                             'blamee-placeholder))
        (let ((real-width (string-width (blamee-test--before-string-at-line 1)))
              (placeholder-width
               (string-width (blamee-test--before-string-at-line 2))))
          (should (= real-width placeholder-width)))

        (goto-char (point-min))
        (end-of-line)
        (delete-char 1)
        (blamee--update-visible-layout (selected-window))
        (should (= 3 (blamee-test--line-count)))
        (blamee-test--should-have-one-overlay-per-line)))))

(ert-deftest blamee-mode-keeps-overlay-coverage-after-in-line-edits ()
  (blamee-test--with-temp-repo
    (let ((file (blamee-test--make-two-commit-file repo)))
      (blamee-test--with-blamed-buffer file
        (let ((original-width
               (string-width (blamee-test--before-string-at-line 1))))
          (goto-char (point-min))
          (forward-char 1)
          (insert "X")
          (blamee--update-visible-layout (selected-window))
          (should (= 3 (blamee-test--line-count)))
          (blamee-test--should-have-one-overlay-per-line)
          (should (= original-width
                     (string-width (blamee-test--before-string-at-line 1))))
          (should (= original-width
                     (string-width (blamee-test--before-string-at-line 2))))

          (goto-char (point-min))
          (forward-char 1)
          (delete-char 1)
          (blamee--update-visible-layout (selected-window))
          (should (= 3 (blamee-test--line-count)))
          (blamee-test--should-have-one-overlay-per-line)
          (should (= original-width
                     (string-width (blamee-test--before-string-at-line 1)))))))))

(ert-deftest blamee-copy-commit-hash-at-point-copies-current-line-hash ()
  (blamee-test--with-temp-repo
    (let ((file (blamee-test--make-two-commit-file repo)))
      (blamee-test--with-blamed-buffer file
        (let (kill-ring)
          (goto-char (point-min))
          (blamee-copy-commit-hash-at-point)
          (should (string-match-p "\\`[0-9a-f]\\{40\\}\\'" (car kill-ring))))))))

(provide 'blamee-test)

;;; blamee-test.el ends here
