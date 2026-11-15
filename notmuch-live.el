;;; notmuch-live.el --- Keep notmuch's search lists up to date as your mail changes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Oleksii Sadovyi

;; Author: Oleksii Sadovyi <3742880+OSadovy@users.noreply.github.com>
;; Version: 0.1.0
;; Keywords: mail
;; Package-Requires: ((emacs "29.1"))
;; URL: https://github.com/OSadovy/notmuch-live.el

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;;; Commentary:

;; notmuch draws a search list once.  Afterwards only the rows its own
;; commands touch change, and no row is ever taken out, so a thread trashed
;; while reading it is still in the list it was opened from.
;;
;; With `notmuch-live-mode' on, every open list follows the database: a
;; thread's row is redrawn when the thread changes, taken out when the thread
;; no longer matches, and put in, in date order, when it newly matches.  This
;; covers the thread lists and the unthreaded message lists; the tree view is
;; left as notmuch draws it.  The start page is redrawn while it is shown, as
;; notmuch already redraws it whenever it comes back into a window.
;;
;; Lists catch up once the command that changed the database has finished,
;; whether through `notmuch-tag', which all of notmuch.el's tagging goes
;; through, or after `notmuch-live-update', for changes made outside Emacs.
;;
;; Point stays on its row.  When its row is taken out, point goes to the row
;; that followed it and `notmuch-live-row-removed-hook' runs.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'notmuch)
(require 'notmuch-tree)
(require 'notmuch-hello)

(defgroup notmuch-live nil
  "Keep notmuch's lists in step with the database."
  :group 'notmuch)

(defcustom notmuch-live-row-removed-hook nil
  "Hook run in a list whose row at point was taken out.
Point is on the row that followed it, or past the last row."
  :type 'hook)

(defvar-local notmuch-live--revision nil
  "The database's (UUID . REVISION) this buffer is current to.")

(defvar notmuch-live--timer nil
  "The timer that will bring the lists up to date, if one is due.")

(defun notmuch-live--database-revision ()
  "Return the database's (UUID . REVISION)."
  (let ((fields (split-string (car (notmuch--process-lines
                                    notmuch-command "count" "--lastmod" "*"))
                              "\t")))
    (cons (nth 1 fields) (string-to-number (nth 2 fields)))))

(defun notmuch-live--note-revision ()
  "Record the revision this buffer is about to be drawn at."
  (setq notmuch-live--revision (notmuch-live--database-revision)))

(defun notmuch-live--list-p ()
  "Non-nil if this buffer is a list this package keeps current."
  (or (derived-mode-p 'notmuch-search-mode)
      (and (derived-mode-p 'notmuch-tree-mode) notmuch-tree-unthreaded)))

(defun notmuch-live--changed (output since cache)
  "Return a table of the bare ids of OUTPUT changed after revision SINCE.
OUTPUT is \"threads\" or \"messages\".  CACHE holds the tables already
asked for in this catch-up."
  (let ((key (cons output since)))
    (or (gethash key cache)
        (let ((table (make-hash-table :test #'equal)))
          (dolist (line (notmuch--process-lines
                         notmuch-command "search" (concat "--output=" output)
                         "--exclude=false" (format "lastmod:%d.." (1+ since))))
            (puthash (substring line (1+ (string-search ":" line))) t table))
          (puthash key table cache)))))

;;;; Reconciling rows

;; notmuch.el chooses whether a search hides excluded messages only from
;; 0.39; before, it passes nothing and notmuch's default applies.
(defun notmuch-live--exclude-args ()
  "Return the exclusion argument this buffer's search was run with, in a list."
  (when (boundp 'notmuch-search-hide-excluded)
    (list (if notmuch-search-hide-excluded "--exclude=true" "--exclude=false"))))

;; A kind of list is a plist of functions:
;;   :rows            () -> the rows in buffer order, each (ID . START)
;;   :row-end         (START) -> where that row ends
;;   :row-data        (START) -> what the row was drawn from
;;   :timestamp       (DATA) -> the date it is sorted by
;;   :item-id         (ITEM) -> the id of ITEM, fresh from notmuch
;;   :item-timestamp  (ITEM) -> its date
;;   :insert          (ITEM POS OLD) -> draw ITEM at POS, in place of the
;;                    row drawn from OLD if there was one

(defun notmuch-live--rows-end (kind)
  "Return where a row after the last of KIND would go."
  (let ((last (car (last (funcall (plist-get kind :rows))))))
    (if last (funcall (plist-get kind :row-end) (cdr last)) (point-min))))

(defun notmuch-live--insert-position (kind item oldest-first)
  "Return where ITEM goes among the rows of KIND, sorted by OLDEST-FIRST."
  (let ((time (funcall (plist-get kind :item-timestamp) item)))
    (or (cl-loop for (_ . start) in (funcall (plist-get kind :rows))
                 for row-time = (funcall (plist-get kind :timestamp)
                                         (funcall (plist-get kind :row-data) start))
                 when (if oldest-first (> row-time time) (< row-time time))
                 return start)
        (notmuch-live--rows-end kind))))

(defun notmuch-live--rows-from (kind rows pos)
  "Return the tail of ROWS, of KIND, that starts with the row at POS."
  (cl-member-if (lambda (row)
                  (and (<= (cdr row) pos)
                       (< pos (funcall (plist-get kind :row-end) (cdr row)))))
                rows))

(defun notmuch-live--anchor (kind rows removed pos)
  "Return what POS should follow once the REMOVED rows are gone.
ROWS are all the rows, of KIND.  The result is (ID . OFFSET) for a row,
`end' for past the last row, or a marker when POS is on no row."
  (let ((tail (notmuch-live--rows-from kind rows pos)))
    (cond
     ((null tail) (copy-marker pos t))
     ((not (gethash (caar tail) removed)) (cons (caar tail) (- pos (cdar tail))))
     (t (let ((next (seq-find (lambda (row) (not (gethash (car row) removed)))
                              (cdr tail))))
          (if next (cons (car next) 0) 'end))))))

(defun notmuch-live--resolve (kind anchor)
  "Return the position ANCHOR now stands for among the rows of KIND.
ANCHOR is from `notmuch-live--anchor'."
  (cond
   ((markerp anchor) (prog1 (marker-position anchor) (set-marker anchor nil)))
   ((eq anchor 'end) (notmuch-live--rows-end kind))
   (t (let ((start (cdr (assoc (car anchor) (funcall (plist-get kind :rows))))))
        (if start
            (min (+ start (cdr anchor))
                 (1- (funcall (plist-get kind :row-end) start)))
          (notmuch-live--rows-end kind))))))

(defun notmuch-live--reconcile (kind changed fresh oldest-first)
  "Bring the rows of KIND up to date.
CHANGED is a table of the ids changed since the rows were current, and
FRESH the output, in list order, for those of them that match now.
OLDEST-FIRST is the list's order.  Return non-nil if the row point
was on was taken out."
  (let* ((rows (funcall (plist-get kind :rows)))
         (item-id (plist-get kind :item-id))
         (row-end (plist-get kind :row-end))
         (fresh-by-id (make-hash-table :test #'equal))
         (removed (make-hash-table :test #'equal))
         (inhibit-read-only t)
         point-row point-anchor window-anchors)
    (dolist (item fresh)
      (puthash (funcall item-id item) item fresh-by-id))
    (dolist (row rows)
      (when (and (gethash (car row) changed)
                 (not (gethash (car row) fresh-by-id)))
        (puthash (car row) t removed)))
    (setq point-row (car (notmuch-live--rows-from kind rows (point))))
    (setq point-anchor (notmuch-live--anchor kind rows removed (point)))
    (setq window-anchors
          (mapcar (lambda (window)
                    (cons window (notmuch-live--anchor kind rows removed
                                                       (window-point window))))
                  (get-buffer-window-list nil nil t)))
    ;; From the last row back, so that the rows before keep their starts.
    (dolist (row (reverse rows))
      (let ((item (gethash (car row) fresh-by-id)))
        (when (or item (gethash (car row) removed))
          (let ((old (funcall (plist-get kind :row-data) (cdr row))))
            (delete-region (cdr row) (funcall row-end (cdr row)))
            (when item
              (funcall (plist-get kind :insert) item (cdr row) old)
              (remhash (car row) fresh-by-id))))))
    (dolist (item fresh)
      (when (gethash (funcall item-id item) fresh-by-id)
        (funcall (plist-get kind :insert) item
                 (notmuch-live--insert-position kind item oldest-first) nil)))
    (goto-char (notmuch-live--resolve kind point-anchor))
    (pcase-dolist (`(,window . ,anchor) window-anchors)
      (set-window-point window (notmuch-live--resolve kind anchor)))
    (and point-row (gethash (car point-row) removed))))

;;;; Thread lists

(defun notmuch-live--search-rows ()
  "Return the rows of this thread list, each (THREAD . START)."
  (let ((pos (point-min)) rows)
    (while (< pos (point-max))
      (when-let* ((result (notmuch-search-get-result pos)))
        (push (cons (plist-get result :thread) pos) rows))
      (setq pos (next-single-property-change pos 'notmuch-search-result
                                             nil (point-max))))
    (nreverse rows)))

(defun notmuch-live--search-insert (result pos old)
  "Draw RESULT at POS in place of the row drawn from OLD, if any.
A row shows its tags against those it was first drawn with, so a
replacement keeps OLD's."
  (notmuch-search-show-result
   (plist-put result :orig-tags (plist-get (or old result)
                                           (if old :orig-tags :tags)))
   pos))

(defconst notmuch-live--search-kind
  (list :rows #'notmuch-live--search-rows
        :row-end #'notmuch-search-result-end
        :row-data #'notmuch-search-get-result
        :timestamp (lambda (result) (plist-get result :timestamp))
        :item-id (lambda (result) (plist-get result :thread))
        :item-timestamp (lambda (result) (plist-get result :timestamp))
        :insert #'notmuch-live--search-insert)
  "How to reconcile a thread list.")

(defun notmuch-live--search-catch-up (since cache)
  "Bring this thread list up to date from revision SINCE, with CACHE.
Return non-nil if the row point was on was taken out."
  (notmuch-live--reconcile
   notmuch-live--search-kind
   (notmuch-live--changed "threads" since cache)
   (seq-remove
    ;; notmuch leaves these out of the list.
    (lambda (result) (eql (plist-get result :matched) 0))
    (apply #'notmuch-call-notmuch-sexp
           "search" "--format=sexp" "--format-version=5"
           (if notmuch-search-oldest-first "--sort=oldest-first" "--sort=newest-first")
           `(,@(notmuch-live--exclude-args)
             ,(format "(%s) and thread:{lastmod:%d..}"
                      notmuch-search-query-string (1+ since)))))
   notmuch-search-oldest-first))

;;;; Unthreaded lists

;; Each row is a line, and each message comes from notmuch as a thread of
;; its own.

(defun notmuch-live--message-rows ()
  "Return the rows of this unthreaded list, each (MESSAGE-ID . START)."
  (save-excursion
    (goto-char (point-min))
    (let (rows)
      (while (not (eobp))
        (when-let* ((msg (get-text-property (point) :notmuch-message-properties)))
          (push (cons (plist-get msg :id) (point)) rows))
        (forward-line))
      (nreverse rows))))

(defun notmuch-live--message-insert (thread pos _old)
  "Draw THREAD, one message from notmuch, at POS."
  ;; notmuch draws a message only at the end of the buffer, and moves point
  ;; to it unless the message it was asked to open has been found.
  (save-excursion
    (save-restriction
      (narrow-to-region (point-min) pos)
      (let ((notmuch-tree-target-msg "found")
            (notmuch-tree-previous-subject nil))
        (notmuch-tree-insert-forest-thread thread)))))

(defconst notmuch-live--message-kind
  (list :rows #'notmuch-live--message-rows
        :row-end (lambda (start)
                   (save-excursion (goto-char start) (line-beginning-position 2)))
        :row-data (lambda (start)
                    (get-text-property start :notmuch-message-properties))
        :timestamp (lambda (msg) (plist-get msg :timestamp))
        :item-id (lambda (thread) (plist-get (caar thread) :id))
        :item-timestamp (lambda (thread) (plist-get (caar thread) :timestamp))
        :insert #'notmuch-live--message-insert)
  "How to reconcile an unthreaded list.")

(defun notmuch-live--message-catch-up (since cache)
  "Bring this unthreaded list up to date from revision SINCE, with CACHE.
Return non-nil if the row point was on was taken out."
  (notmuch-live--reconcile
   notmuch-live--message-kind
   (notmuch-live--changed "messages" since cache)
   (apply #'notmuch-call-notmuch-sexp
          "show" "--body=false" "--format=sexp" "--format-version=5" "--unthreaded"
          (if notmuch-search-oldest-first "--sort=oldest-first" "--sort=newest-first")
          `(,@(notmuch-live--exclude-args)
            ,(format "(%s) and lastmod:%d.." (notmuch-tree-get-query) (1+ since))))
   notmuch-search-oldest-first))

;;;; Catching up

(defvar-local notmuch-live--hello-revision nil
  "The database's (UUID . REVISION) the start page was drawn at.")

(defun notmuch-live--note-hello-revision ()
  "Record the revision the start page has just been drawn at."
  (setq notmuch-live--hello-revision (notmuch-live--database-revision)))

(defun notmuch-live--catch-up (revision cache)
  "Bring this list up to REVISION, sharing CACHE with other lists.
A list drawn from another database is searched again."
  (let ((since notmuch-live--revision))
    (if (not (equal (car since) (car revision)))
        (notmuch-refresh-this-buffer)
      (setq notmuch-live--revision revision)
      (when (if (derived-mode-p 'notmuch-search-mode)
                (notmuch-live--search-catch-up (cdr since) cache)
              (notmuch-live--message-catch-up (cdr since) cache))
        (run-hooks 'notmuch-live-row-removed-hook)))))

(defun notmuch-live--catch-up-hello (revision)
  "Redraw the start page if it is shown and older than REVISION."
  (when-let* ((hello (get-buffer "*notmuch-hello*"))
              ((get-buffer-window hello t)))
    (with-current-buffer hello
      (unless (equal notmuch-live--hello-revision revision)
        ;; From a timer `this-command' can still name the last command, which
        ;; code reacting to how the page came to be redrawn would take for it.
        (let ((this-command nil))
          (notmuch-hello t))))))

(defun notmuch-live--run ()
  "Bring every list, and the start page if shown, up to date."
  (setq notmuch-live--timer nil)
  (let ((revision (notmuch-live--database-revision))
        (cache (make-hash-table :test #'equal)))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and notmuch-live--revision
                   (notmuch-live--list-p)
                   (not (equal notmuch-live--revision revision))
                   ;; Caught up once its search has finished.
                   (not (get-buffer-process buffer)))
          (with-demoted-errors "notmuch-live: %S"
            (notmuch-live--catch-up revision cache)))))
    (with-demoted-errors "notmuch-live: %S"
      (notmuch-live--catch-up-hello revision))))

(defun notmuch-live--schedule (&rest _)
  "Bring the lists up to date once the current command has finished."
  (unless notmuch-live--timer
    (setq notmuch-live--timer (run-at-time 0 nil #'notmuch-live--run))))

;;;###autoload
(defun notmuch-live-update ()
  "Bring every open notmuch list up to date with the database.
Call this after changing the database outside Emacs, as by `notmuch new'
or a sync; changes made through `notmuch-tag' are caught already."
  (interactive)
  (notmuch-live--schedule))

(defun notmuch-live--after-search (proc &rest _)
  "Catch up the list of PROC, a search, if it has finished."
  (when (memq (process-status proc) '(exit signal))
    (notmuch-live--schedule)))

(defun notmuch-live--window-buffers-changed (frame)
  "Catch up any list just shown in FRAME.
For changes made outside Emacs without `notmuch-live-update'."
  (when (seq-some (lambda (window)
                    (with-current-buffer (window-buffer window)
                      (and notmuch-live--revision (notmuch-live--list-p))))
                  (window-list frame 'never))
    (notmuch-live--schedule)))

;;;###autoload
(define-minor-mode notmuch-live-mode
  "Keep notmuch's lists in step with the database.
Lists opened while this is on follow every change to the database,
and the start page is redrawn while it is shown."
  :global t
  (let ((hook (if notmuch-live-mode #'add-hook #'remove-hook)))
    (funcall hook 'notmuch-search-mode-hook #'notmuch-live--note-revision)
    (funcall hook 'notmuch-tree-mode-hook #'notmuch-live--note-revision)
    (funcall hook 'notmuch-hello-refresh-hook #'notmuch-live--note-hello-revision)
    (funcall hook 'notmuch-after-tag-hook #'notmuch-live--schedule)
    (funcall hook 'notmuch-tree-process-exit-functions #'notmuch-live--after-search)
    (funcall hook 'window-buffer-change-functions
             #'notmuch-live--window-buffers-changed))
  (if notmuch-live-mode
      (advice-add 'notmuch-search-process-sentinel :after
                  #'notmuch-live--after-search)
    (advice-remove 'notmuch-search-process-sentinel #'notmuch-live--after-search)))

(provide 'notmuch-live)
;;; notmuch-live.el ends here
