;;; blamee.el --- Chunked git-blame overlays with popup details -*- lexical-binding: t; -*-
;; Copyright (C) 2026 fvi-att

;; Author: fvi-att <jshimizujp@gmail.com>
;; Maintainer: fvi-att <jshimizujp@gmail.com>
;; Assisted-by: Claude:claude-fable-5
;; Version: 2.0.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, vc, git
;; URL: https://github.com/fvi-att/blamee
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; blamee.el displays `git blame' information inline between the
;; display-line-numbers gutter and the source text.  Consecutive lines
;; sharing the same commit are grouped into a chunk; only the first line
;; of each chunk shows the blame prefix, the rest show a blank spacer of
;; the same width so the source code stays aligned.
;;
;; The inline prefix defaults to a small date + author layout,
;; but its visible columns can be customized.  A per-commit background
;; color identifies chunk boundaries at a glance.  When point enters a
;; blamed line, a child-frame popup (or echo area on TTY) shows the
;; full commit detail: author, full timestamp, 12-char hash and
;; summary.
;;
;; Usage:
;;
;;   (require 'blamee)
;;   (global-blamee-mode 1)   ; auto-enable in file buffers inside a git tree
;;
;;   M-x blamee-mode          ; toggle in a single buffer
;;
;; See README.md for installation recipes, customization and screenshots.

;;; Code:

(require 'subr-x)
(require 'seq)
(require 'color)

(defun blamee--refresh-active-buffers ()
  "Refresh all live buffers with `blamee-mode' enabled."
  (when (fboundp 'blamee--refresh)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (bound-and-true-p blamee-mode)
          (blamee--refresh))))))

(defun blamee--set-and-refresh (symbol value)
  "Set SYMBOL to VALUE, then refresh active blamee buffers."
  (set-default symbol value)
  (blamee--refresh-active-buffers))

(defgroup blamee nil
  "Show git blame info grouped by chunk."
  :group 'tools
  :prefix "blamee-")

(defcustom blamee-hash-length 6
  "Maximum number of characters of the inline commit hash to show."
  :type 'integer
  :set #'blamee--set-and-refresh
  :group 'blamee)

(defcustom blamee-date-format "%y-%m-%d"
  "`format-time-string' spec used for the blame date column."
  :type 'string
  :set #'blamee--set-and-refresh
  :group 'blamee)

(defcustom blamee-inline-columns '(date author)
  "Ordered list of columns shown in the inline blame prefix.
Supported column symbols are `author', `date', `summary' and `hash'."
  :type '(repeat
          (choice (const :tag "Author" author)
                  (const :tag "Date" date)
                  (const :tag "Summary" summary)
                  (const :tag "Hash" hash)))
  :set #'blamee--set-and-refresh
  :group 'blamee)

(defcustom blamee-uncommitted-label "Uncommitted"
  "Author label used for lines not yet committed."
  :type 'string
  :set #'blamee--set-and-refresh
  :group 'blamee)

(defcustom blamee-uncommitted-summary "(not yet committed)"
  "Summary shown for lines not yet committed."
  :type 'string
  :set #'blamee--set-and-refresh
  :group 'blamee)

(defcustom blamee-separator " │"
  "String used to separate the blame prefix from the source line.
On text terminals `blamee-separator-tty' is used instead."
  :type 'string
  :set #'blamee--set-and-refresh
  :group 'blamee)

(defcustom blamee-separator-tty " |"
  "Separator used instead of `blamee-separator' on text terminals.
East Asian Ambiguous characters such as │ (U+2502) are counted as two
columns by Emacs in some language environments (Japanese, for example)
while most terminal emulators render them in a single cell; that
disagreement shifts the terminal cursor one column to the right of
every character drawn after the separator.  Stick to ASCII here unless
your terminal and Emacs agree on ambiguous character widths."
  :type 'string
  :set #'blamee--set-and-refresh
  :group 'blamee)

(defcustom blamee-idle-delay 0.3
  "Idle seconds before refreshing blame after a save."
  :type 'number
  :group 'blamee)

(defcustom blamee-popup-delay 0.5
  "Idle seconds after point settles before showing the commit popup."
  :type 'number
  :group 'blamee)

(defcustom blamee-popup-enabled t
  "Non-nil to show a detail popup when point is on a blamed line."
  :type 'boolean
  :group 'blamee)

(defcustom blamee-popup-detail-date-format "%Y-%m-%d %H:%M"
  "Date format used inside the detail popup."
  :type 'string
  :group 'blamee)

(defcustom blamee-popup-max-width 70
  "Maximum inner width of the commit detail popup in columns."
  :type 'integer
  :group 'blamee)

(defcustom blamee-background-saturation 0.32
  "Saturation (0.0-1.0) of per-commit background colors."
  :type 'number
  :group 'blamee)

(defcustom blamee-background-lightness 0.22
  "Lightness (0.0-1.0) of per-commit background colors.
Use a small value for dark themes and a larger one (around 0.85) for
light themes."
  :type 'number
  :group 'blamee)

(defface blamee-face
  '((t :inherit shadow :height 0.6))
  "Base face used by all blamee columns."
  :group 'blamee)

(defface blamee-author-face
  '((t :inherit blamee-face :weight bold))
  "Face used for the author column."
  :group 'blamee)

(defface blamee-date-face
  '((t :inherit blamee-face))
  "Face used for the commit date column."
  :group 'blamee)

(defface blamee-comment-face
  '((t :inherit blamee-face :slant italic))
  "Face used for the commit summary column."
  :group 'blamee)

(defface blamee-hash-face
  '((t :inherit blamee-face))
  "Face used for the commit hash column."
  :group 'blamee)

(defface blamee-separator-face
  '((t :inherit blamee-face))
  "Face used for the column separator."
  :group 'blamee)

(defvar blamee-mode)

(defvar-local blamee--overlays nil
  "List of overlays created by `blamee-mode' in the current buffer.")

(defvar-local blamee--refresh-timer nil
  "Pending idle timer for `blamee--refresh'.")

(defvar-local blamee--blank-prefix nil
  "Blank prefix string matching the current layout, or nil before a render.
Used as the `line-prefix' of placeholder overlays that keep newly
inserted lines aligned until the next refresh.")

(defconst blamee--zero-hash (make-string 40 ?0)
  "Pseudo hash git uses for uncommitted lines.")

(defun blamee--uncommitted-p (commit)
  "Return non-nil when COMMIT represents an uncommitted line."
  (equal (plist-get commit :hash) blamee--zero-hash))

(defun blamee--commit-background (commit)
  "Return a stable hex color for COMMIT, or nil for uncommitted lines."
  (let ((hash (plist-get commit :hash)))
    (unless (equal hash blamee--zero-hash)
      (let* ((seed (string-to-number (substring hash 0 6) 16))
             (hue (/ (float (mod seed 360)) 360.0))
             (rgb (color-hsl-to-rgb hue
                                    blamee-background-saturation
                                    blamee-background-lightness)))
        (apply #'color-rgb-to-hex (append rgb '(2)))))))

(defun blamee--inside-worktree-p ()
  "Return non-nil when the current buffer's file is inside a git worktree."
  (and buffer-file-name
       (file-exists-p buffer-file-name)
       (let ((default-directory (file-name-directory
                                 (file-truename buffer-file-name))))
         (eq 0 (call-process "git" nil nil nil
                             "rev-parse" "--is-inside-work-tree")))))

(defun blamee--format-inline-column (column commit)
  "Render inline COLUMN for COMMIT at full natural width."
  (let* ((hash (plist-get commit :hash))
         (uncommitted (blamee--uncommitted-p commit))
         (time (plist-get commit :author-time)))
    (pcase column
      ('author
       (propertize
        (if uncommitted
            blamee-uncommitted-label
          (or (plist-get commit :author) ""))
        'face 'blamee-author-face))
      ('date
       (if (and time (not uncommitted))
           (propertize
            (format-time-string blamee-date-format time)
            'face 'blamee-date-face)
         ""))
      ('summary
       (propertize
        (if uncommitted
            blamee-uncommitted-summary
          (or (plist-get commit :summary) ""))
        'face 'blamee-comment-face))
      ('hash
       (if uncommitted
           ""
         (propertize
          (substring hash 0 (min blamee-hash-length (length hash)))
          'face 'blamee-hash-face)))
      (_ ""))))

(defun blamee--inline-columns (commit)
  "Return the configured inline columns for COMMIT as a (COLUMN . STRING) alist."
  (mapcar (lambda (column)
            (cons column (blamee--format-inline-column column commit)))
          blamee-inline-columns))

(defun blamee--format-detail (commit)
  "Return a multi-line human-readable COMMIT summary for the popup."
  (let* ((hash (plist-get commit :hash))
         (uncommitted (blamee--uncommitted-p commit))
         (author (if uncommitted
                     blamee-uncommitted-label
                   (or (plist-get commit :author) "?")))
         (time (plist-get commit :author-time))
         (summary (if uncommitted
                      blamee-uncommitted-summary
                    (or (plist-get commit :summary) "")))
         (date-str (if (and time (not uncommitted))
                       (format-time-string blamee-popup-detail-date-format time)
                     "-"))
         (short (substring hash 0 (min 12 (length hash)))))
    (concat
     (propertize "Author: " 'face 'bold) author "\n"
     (propertize "Date:   " 'face 'bold) date-str "\n"
     (propertize "Commit: " 'face 'bold) short "\n"
     (propertize (make-string (min blamee-popup-max-width 40) ?─)
                 'face 'shadow) "\n"
     summary)))


;;; Pixel layout ---------------------------------------------------------------

(defconst blamee--measure-buffer " *blamee-measure*"
  "Work buffer reused to measure rendered string widths.")

(defun blamee--string-pixel-width (string)
  "Return the displayed width of STRING in pixels.
On text terminals and in batch mode the unit degenerates to character
cells, which is what stretch glyphs use there as well.  The measurement
honors the calling buffer's `face-remapping-alist' so `text-scale-mode'
adjustments are reflected."
  (cond
   ((zerop (length string)) 0)
   (noninteractive (string-width string))
   (t
    (let ((remapping (and (boundp 'face-remapping-alist)
                          face-remapping-alist)))
      (with-current-buffer (get-buffer-create blamee--measure-buffer)
        (setq-local face-remapping-alist remapping)
        (delete-region (point-min) (point-max))
        (insert string)
        (if (fboundp 'buffer-text-pixel-size)
            (car (buffer-text-pixel-size nil nil t))
          ;; Emacs 27/28: `window-text-pixel-size' needs a window that
          ;; shows the buffer (same trick as `shr-pixel-column').
          (save-window-excursion
            (set-window-dedicated-p nil nil)
            (set-window-buffer nil (current-buffer))
            (car (window-text-pixel-size nil (point-min) (point-max))))))))))

(defun blamee--separator ()
  "Return the active separator string for the current display type."
  (if (display-graphic-p) blamee-separator blamee-separator-tty))

(defun blamee--compute-layout (column-alists)
  "Compute the pixel layout of the inline prefix from COLUMN-ALISTS.
COLUMN-ALISTS is the list of rendered column alists, one per distinct
commit in the file.  Return a plist with `:columns' (alist of column
symbol to the pixel position the column's slot ends at; every slot but
the last includes the inter-column gap), `:separator-px' (where the
separator starts) and `:total-px' (where the source text starts), or
nil when no column has any content."
  (let ((gap (max 1 (blamee--string-pixel-width
                     (propertize " " 'face 'blamee-face))))
        (widths (mapcar (lambda (column) (cons column 0))
                        blamee-inline-columns)))
    (dolist (columns column-alists)
      (dolist (slot widths)
        (setcdr slot (max (cdr slot)
                          (blamee--string-pixel-width
                           (or (alist-get (car slot) columns) ""))))))
    (when-let ((visible (seq-filter (lambda (slot) (> (cdr slot) 0))
                                    widths)))
      (let ((pos 0)
            (slots nil)
            (last (car (last visible))))
        (dolist (slot visible)
          ;; The align position is where the next column's text starts,
          ;; so it includes the gap — except after the last column,
          ;; where the separator follows immediately.
          (setq pos (+ pos (cdr slot) (if (eq slot last) 0 gap)))
          (push (cons (car slot) pos) slots))
        (let ((sep-width (blamee--string-pixel-width
                          (propertize (blamee--separator)
                                      'face 'blamee-separator-face))))
          (list :columns (nreverse slots)
                :separator-px pos
                :total-px (+ pos sep-width gap)))))))

(defun blamee--stretch-to (px)
  "Return a stretch glyph padding to PX pixels from the text-area edge.
The display engine fills the exact remaining distance, so alignment no
longer depends on font metrics of the characters before it."
  (propertize " " 'display `(space :align-to (,px))))

(defun blamee--decorate-prefix (string commit detail)
  "Apply base face, DETAIL help text and COMMIT background to prefix STRING."
  (add-face-text-property 0 (length string) 'blamee-face t string)
  (when detail
    (put-text-property 0 (length string) 'help-echo detail string))
  (when-let ((bg (and commit (blamee--commit-background commit))))
    ;; Skip the final stretch so the gap right before the source text is
    ;; not painted with the chunk color.
    (add-face-text-property 0 (max 0 (1- (length string)))
                            `(:background ,bg) nil string))
  string)

(defun blamee--prefix-string (columns layout commit detail)
  "Render the full inline prefix for a chunk's first line.
COLUMNS is the rendered column alist of COMMIT, LAYOUT the plist from
`blamee--compute-layout' and DETAIL the popup/help-echo text."
  (let ((parts nil))
    (dolist (slot (plist-get layout :columns))
      (push (or (alist-get (car slot) columns) "") parts)
      (push (blamee--stretch-to (cdr slot)) parts))
    (push (propertize (blamee--separator) 'face 'blamee-separator-face)
          parts)
    (push (blamee--stretch-to (plist-get layout :total-px)) parts)
    (blamee--decorate-prefix (apply #'concat (nreverse parts))
                             commit detail)))

(defun blamee--blank-string (layout commit detail)
  "Render the blank continuation prefix for LAYOUT.
The separator is still drawn so the vertical rule runs through the whole
chunk; COMMIT (may be nil) provides the chunk background and DETAIL the
help-echo text."
  (blamee--decorate-prefix
   (concat (blamee--stretch-to (plist-get layout :separator-px))
           (propertize (blamee--separator) 'face 'blamee-separator-face)
           (blamee--stretch-to (plist-get layout :total-px)))
   commit detail))


;;; Blame parsing and rendering ------------------------------------------------

(defun blamee--parse-porcelain ()
  "Parse `git blame --porcelain' output in the current temp buffer.
Return a list of (LINENO . COMMIT-PLIST) pairs sorted by LINENO."
  (goto-char (point-min))
  (let ((commits (make-hash-table :test 'equal))
        (entries nil))
    (while (not (eobp))
      (unless (looking-at
               "^\\([0-9a-f]\\{40\\}\\) [0-9]+ \\([0-9]+\\)\\(?: [0-9]+\\)?$")
        (error "Blamee: unexpected porcelain line: %s"
               (buffer-substring-no-properties
                (point) (line-end-position))))
      (let* ((hash (match-string 1))
             (result-line (string-to-number (match-string 2)))
             (commit (or (gethash hash commits) (list :hash hash))))
        (forward-line 1)
        (while (and (not (eobp))
                    (not (looking-at "^\t")))
          (cond
           ((looking-at "^author \\(.*\\)$")
            (setq commit (plist-put commit :author (match-string 1))))
           ((looking-at "^author-time \\([0-9]+\\)$")
            (setq commit (plist-put commit :author-time
                                    (string-to-number (match-string 1)))))
           ((looking-at "^summary \\(.*\\)$")
            (setq commit (plist-put commit :summary (match-string 1)))))
          (forward-line 1))
        (puthash hash commit commits)
        (push (cons result-line commit) entries)
        ;; Move past the \t source content line.
        (forward-line 1)))
    (nreverse entries)))

(defun blamee--chunks (entries)
  "Group ENTRIES into chunks of consecutive same-commit lines.
ENTRIES is a sorted list of (LINENO . COMMIT-PLIST).  Return a list of
\(START-LINE END-LINE COMMIT-PLIST) with both bounds inclusive."
  (let ((chunks nil)
        (current nil))
    (dolist (entry entries)
      (let ((line (car entry))
            (commit (cdr entry)))
        (if (and current
                 (= line (1+ (nth 1 current)))
                 (equal (plist-get (nth 2 current) :hash)
                        (plist-get commit :hash)))
            (setf (nth 1 current) line)
          (when current (push current chunks))
          (setq current (list line line commit)))))
    (when current (push current chunks))
    (nreverse chunks)))

(defun blamee--clear ()
  "Remove all blamee overlays from the current buffer.
Scan the whole buffer so stale overlays left behind by reloads or
duplicate mode activations are also removed."
  (save-restriction
    (widen)
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (overlay-get ov 'blamee)
        (delete-overlay ov))))
  (setq blamee--overlays nil
        blamee--blank-prefix nil))

(defun blamee--make-overlay (beg end commit prefix wrap)
  "Create a blamee overlay over BEG..END rendering PREFIX as its line prefix.
COMMIT (may be nil for placeholders) is attached for the detail popup;
WRAP is used as the `wrap-prefix' of visually wrapped lines."
  (let ((ov (make-overlay beg end)))
    (overlay-put ov 'blamee t)
    (when commit
      (overlay-put ov 'blamee-commit commit))
    (overlay-put ov 'line-prefix prefix)
    (overlay-put ov 'wrap-prefix wrap)
    (push ov blamee--overlays)
    ov))

(defun blamee--render (entries)
  "Create chunk overlays for ENTRIES, a list of (LINENO . COMMIT-PLIST).
Each chunk gets one overlay carrying the full prefix on its first line
and, when the chunk spans several lines, a second overlay carrying the
blank continuation prefix over the rest."
  (save-excursion
    (save-restriction
      (widen)
      (let ((columns-by-hash (make-hash-table :test 'equal)))
        (dolist (entry entries)
          (let ((hash (plist-get (cdr entry) :hash)))
            (unless (gethash hash columns-by-hash)
              (puthash hash (blamee--inline-columns (cdr entry))
                       columns-by-hash))))
        (when-let ((layout (blamee--compute-layout
                            (hash-table-values columns-by-hash))))
          (setq blamee--blank-prefix (blamee--blank-string layout nil nil))
          (goto-char (point-min))
          (let ((current-line 1))
            (dolist (chunk (blamee--chunks entries))
              (pcase-let ((`(,start ,end ,commit) chunk))
                (forward-line (- start current-line))
                (let* ((beg (point))
                       (first-end (progn (forward-line 1) (point)))
                       (rest-end (progn (forward-line (- end start)) (point)))
                       (columns (gethash (plist-get commit :hash)
                                         columns-by-hash))
                       (detail (blamee--format-detail commit))
                       (blank (blamee--blank-string layout commit detail)))
                  (setq current-line (1+ end))
                  (when (< beg first-end)
                    (blamee--make-overlay
                     beg first-end commit
                     (blamee--prefix-string columns layout commit detail)
                     blank))
                  (when (< first-end rest-end)
                    (blamee--make-overlay first-end rest-end commit
                                          blank blank)))))))))))

(defun blamee--run-blame (file)
  "Run `git blame --porcelain' on FILE and return parsed entries or nil."
  (let ((default-directory (file-name-directory (file-truename file))))
    (with-temp-buffer
      (let ((status (call-process "git" nil (list (current-buffer) nil) nil
                                  "--no-pager" "blame" "--porcelain" "--"
                                  (file-name-nondirectory file))))
        (when (eq status 0)
          (condition-case err
              (blamee--parse-porcelain)
            (error
             (message "blamee: parse failed: %s" (error-message-string err))
             nil)))))))

(defun blamee--refresh ()
  "Refresh blame overlays in the current buffer."
  (blamee--clear)
  (when (and buffer-file-name
             (file-exists-p buffer-file-name)
             (blamee--inside-worktree-p))
    (when-let ((entries (blamee--run-blame buffer-file-name)))
      (blamee--render entries))))

(defun blamee--schedule-refresh (&rest _)
  "Schedule a blame refresh after `blamee-idle-delay' seconds."
  (when (timerp blamee--refresh-timer)
    (cancel-timer blamee--refresh-timer))
  (let ((buffer (current-buffer)))
    (setq blamee--refresh-timer
          (run-with-idle-timer
           blamee-idle-delay nil
           (lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (when blamee-mode
                   (blamee--refresh)))))))))


;;; Mid-edit coverage ----------------------------------------------------------

(defun blamee--line-covered-p ()
  "Return non-nil when the current line is covered by a live blamee overlay.
A line is covered when an overlay overlaps its beginning, which is where
the display engine looks up the `line-prefix' property."
  (let* ((bol (line-beginning-position))
         (probe-end (min (1+ bol) (point-max))))
    (seq-some (lambda (ov)
                (and (overlay-get ov 'blamee)
                     (< (overlay-start ov) (overlay-end ov))))
              (overlays-in bol probe-end))))

(defun blamee--ensure-coverage (beg end)
  "Backfill blank placeholder prefixes for uncovered lines in BEG..END.
Chunk overlays absorb most edits on their own; lines created outside any
overlay (typically appended at the end of the buffer) would otherwise
lose the inline gutter and shift the source text to the left until the
next refresh."
  (when blamee--blank-prefix
    (save-excursion
      (goto-char (min beg (point-max)))
      (forward-line 0)
      (let ((stop (min end (point-max))))
        (while (and (<= (point) stop)
                    (< (point) (point-max)))
          (unless (blamee--line-covered-p)
            (blamee--make-overlay (point)
                                  (min (point-max)
                                       (line-beginning-position 2))
                                  nil
                                  blamee--blank-prefix
                                  blamee--blank-prefix))
          (forward-line 1))))))

(defun blamee--after-change (beg end _len)
  "Keep the inline gutter aligned across BEG..END after a buffer change.
Overlay markers track edits by themselves; the only thing left to do is
covering newly created lines that fall outside every chunk overlay."
  (when (bound-and-true-p blamee-mode)
    (blamee--ensure-coverage beg end)))


;;; Detail popup --------------------------------------------------------------

(defvar blamee--popup-frame nil
  "Child frame reused to render the commit detail popup.")

(defvar blamee--popup-buffer-name " *blamee-popup*"
  "Buffer rendered inside the popup frame.")

(defvar blamee--popup-timer nil
  "Idle timer that brings up the popup after point settles.")

(defvar blamee--popup-visible-commit nil
  "Commit plist currently shown in the popup, or nil when hidden.")

(defun blamee--commit-at-point ()
  "Return the commit plist attached to any blamee overlay on the current line."
  (let* ((bol (line-beginning-position))
         (probe-end (min (1+ bol) (point-max))))
    (seq-some (lambda (o) (overlay-get o 'blamee-commit))
              (overlays-in bol probe-end))))

(defun blamee--popup-hide ()
  "Hide the detail popup, if any."
  (when (and blamee--popup-frame (frame-live-p blamee--popup-frame)
             (frame-visible-p blamee--popup-frame))
    (make-frame-invisible blamee--popup-frame))
  (setq blamee--popup-visible-commit nil))

(defun blamee--popup-ensure-frame (parent)
  "Create the popup child frame parented under PARENT if missing.
An existing frame is re-parented when the user moved to another frame."
  (if (and blamee--popup-frame (frame-live-p blamee--popup-frame))
      (unless (eq (frame-parent blamee--popup-frame) parent)
        (set-frame-parameter blamee--popup-frame 'parent-frame parent))
    (let ((buf (get-buffer-create blamee--popup-buffer-name))
          (bg (or (face-attribute 'tooltip :background nil t)
                  (face-attribute 'default :background nil t)))
          (fg (or (face-attribute 'tooltip :foreground nil t)
                  (face-attribute 'default :foreground nil t))))
      (with-current-buffer buf
        (setq-local mode-line-format nil)
        (setq-local header-line-format nil)
        (setq-local cursor-type nil)
        (setq-local show-trailing-whitespace nil)
        (setq-local display-line-numbers nil)
        (setq-local truncate-lines nil))
      (setq blamee--popup-frame
            (make-frame
             `((parent-frame . ,parent)
               (no-focus-on-map . t)
               (no-accept-focus . t)
               (minibuffer . nil)
               (min-width . 20) (min-height . 4)
               (width . ,blamee-popup-max-width) (height . 7)
               (left-fringe . 6) (right-fringe . 6)
               (internal-border-width . 2)
               (vertical-scroll-bars . nil)
               (horizontal-scroll-bars . nil)
               (tool-bar-lines . 0)
               (menu-bar-lines . 0)
               (tab-bar-lines . 0)
               (line-spacing . 0)
               (visibility . nil)
               (undecorated . t)
               (unsplittable . t)
               (no-other-frame . t)
               (desktop-dont-save . t)
               (background-color . ,bg)
               (foreground-color . ,fg))))
      (let ((win (frame-selected-window blamee--popup-frame)))
        (set-window-buffer win buf)
        (set-window-dedicated-p win t)
        (set-window-parameter win 'mode-line-format 'none))))
  blamee--popup-frame)

(defun blamee--popup-show (commit)
  "Display the detail for COMMIT next to point."
  (if (not (display-graphic-p))
      (let ((message-log-max nil))
        (message "%s" (blamee--format-detail commit)))
    (let* ((parent (window-frame))
           (frame (blamee--popup-ensure-frame parent))
           (detail (blamee--format-detail commit)))
      (with-current-buffer (get-buffer-create blamee--popup-buffer-name)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert detail)
          (goto-char (point-min))))
      (let* ((posn (posn-at-point))
             (xy (and posn (posn-x-y posn)))
             (edges (window-inside-pixel-edges))
             (line-h (default-line-height))
             (x (and xy (+ (nth 0 edges) (or (car xy) 0))))
             (y (and xy (+ (nth 1 edges) (or (cdr xy) 0) line-h))))
        (when (and x y)
          (set-frame-position frame (max 0 x) (max 0 y))))
      (unless (frame-visible-p frame)
        (make-frame-visible frame))
      (setq blamee--popup-visible-commit commit))))

(defun blamee--popup-update ()
  "Show or update the popup for the commit at point."
  (when (and blamee-popup-enabled (bound-and-true-p blamee-mode))
    (let ((commit (blamee--commit-at-point)))
      (cond
       ((null commit) (blamee--popup-hide))
       ((eq commit blamee--popup-visible-commit) nil)
       (t (blamee--popup-show commit))))))

(defun blamee--post-command ()
  "Trigger or hide the blame popup based on the current point context."
  (when (timerp blamee--popup-timer)
    (cancel-timer blamee--popup-timer)
    (setq blamee--popup-timer nil))
  (cond
   ((and blamee-popup-enabled
         (bound-and-true-p blamee-mode)
         (blamee--commit-at-point))
    (setq blamee--popup-timer
          (run-with-idle-timer blamee-popup-delay nil
                               #'blamee--popup-update)))
   (t (blamee--popup-hide))))

(defvar blamee--post-command-installed nil
  "Non-nil once `blamee--post-command' has been added to the global hook.")

(defun blamee--install-post-command ()
  "Install the global post-command hook lazily."
  (unless blamee--post-command-installed
    (add-hook 'post-command-hook #'blamee--post-command)
    (setq blamee--post-command-installed t)))

;;;###autoload
(define-minor-mode blamee-mode
  "Show git blame information for the current file grouped by chunks."
  :lighter " Blame"
  :group 'blamee
  (cond
   (blamee-mode
    (add-hook 'after-save-hook #'blamee--schedule-refresh nil t)
    (add-hook 'after-revert-hook #'blamee--schedule-refresh nil t)
    (add-hook 'after-change-functions #'blamee--after-change nil t)
    (add-hook 'text-scale-mode-hook #'blamee--schedule-refresh nil t)
    (blamee--install-post-command)
    (blamee--refresh))
   (t
    (remove-hook 'after-save-hook #'blamee--schedule-refresh t)
    (remove-hook 'after-revert-hook #'blamee--schedule-refresh t)
    (remove-hook 'after-change-functions #'blamee--after-change t)
    (remove-hook 'text-scale-mode-hook #'blamee--schedule-refresh t)
    (when (timerp blamee--refresh-timer)
      (cancel-timer blamee--refresh-timer)
      (setq blamee--refresh-timer nil))
    (blamee--popup-hide)
    (blamee--clear))))

;;;###autoload
(defun blamee-show-commit-at-point ()
  "Show the commit detail popup for the blame chunk at point."
  (interactive)
  (let ((commit (blamee--commit-at-point)))
    (if commit
        (blamee--popup-show commit)
      (user-error "No blame information on this line"))))

;;;###autoload
(defun blamee-copy-commit-hash-at-point ()
  "Copy the full commit hash of the blame chunk at point to the kill ring."
  (interactive)
  (let ((commit (blamee--commit-at-point)))
    (if commit
        (let ((hash (plist-get commit :hash)))
          (kill-new hash)
          (message "Copied %s" hash))
      (user-error "No blame information on this line"))))

;;;###autoload
(defun blamee-refresh ()
  "Recompute git blame overlays for the current buffer."
  (interactive)
  (if blamee-mode
      (blamee--refresh)
    (user-error "Blamee-mode is not enabled in this buffer")))

(defun blamee--maybe-enable ()
  "Turn on `blamee-mode' when the buffer visits a file inside a git worktree."
  (when (and buffer-file-name
             (not (minibufferp))
             (blamee--inside-worktree-p))
    (blamee-mode 1)))

;;;###autoload
(define-globalized-minor-mode global-blamee-mode
  blamee-mode blamee--maybe-enable
  :group 'blamee)

(provide 'blamee)

;;; blamee.el ends here
