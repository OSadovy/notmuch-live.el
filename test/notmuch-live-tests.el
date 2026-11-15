;;; notmuch-live-tests.el --- Tests for notmuch-live -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Oleksii Sadovyi

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;;; Commentary:

;; Each test builds a mail database of its own in a temporary directory and
;; drives notmuch.el's real lists and tagging against it, through the
;; timer that catches lists up.  Not tested: catching up when a list is
;; shown again (needs redisplay), the start page, and a database replaced
;; under a list.  The last test checks that the parts of notmuch.el used
;; outside its documented interface are still there.

;;; Code:

(require 'ert)
(require 'notmuch-live)

(defvar notmuch-live-test--dir nil
  "The current test's temporary directory.")

(defun notmuch-live-test--write (id date subject &optional reply-to)
  "Put a message with ID, DATE and SUBJECT in the test maildir.
DATE is days since 2026-01-01.  REPLY-TO is the id it answers."
  (with-temp-file (expand-file-name (format "mail/cur/%s:2," id)
                                    notmuch-live-test--dir)
    (insert (format "From: Sender <sender@example.com>\nTo: test@example.com\n"
                    )
            (format "Subject: %s\n" subject)
            (format "Message-ID: <%s@test>\n" id)
            (if reply-to (format "In-Reply-To: <%s@test>\n" reply-to) "")
            (format "Date: %s\n\nBody of %s.\n"
                    (format-time-string "%a, %d %b %Y %H:%M:%S +0000"
                                        (+ 1767225600 (* date 86400)) t)
                    id))))

(defun notmuch-live-test--notmuch (&rest args)
  "Run notmuch with ARGS on the test database."
  (unless (eql 0 (apply #'call-process notmuch-command nil nil nil args))
    (error "notmuch %S failed" args)))

(defmacro notmuch-live-test--with-mail (messages &rest body)
  "Run BODY against a new database holding MESSAGES.
MESSAGES are argument lists for `notmuch-live-test--write'."
  (declare (indent 1))
  `(let* ((notmuch-live-test--dir (make-temp-file "notmuch-live" t))
          (process-environment
           (cons (concat "NOTMUCH_CONFIG="
                         (expand-file-name "config" notmuch-live-test--dir))
                 process-environment))
          (notmuch-search-oldest-first nil)
          (notmuch-search-hide-excluded t)
          (notmuch-archive-tags '("-inbox")))
     (unwind-protect
         (progn
           (dolist (dir '("mail/cur" "mail/new" "mail/tmp"))
             (make-directory (expand-file-name dir notmuch-live-test--dir) t))
           (with-temp-file (expand-file-name "config" notmuch-live-test--dir)
             (insert (format "[database]\npath=%s/mail\n" notmuch-live-test--dir)
                     "[user]\nname=Test\nprimary_email=test@example.com\n"
                     "[new]\ntags=inbox;unread;\n[search]\nexclude_tags=\n"))
           (dolist (message ,messages)
             (apply #'notmuch-live-test--write message))
           (notmuch-live-test--notmuch "new" "--quiet")
           (notmuch-live-mode 1)
           ,@body)
       (notmuch-live-mode -1)
       (dolist (buffer (buffer-list))
         (when (with-current-buffer buffer
                 (derived-mode-p 'notmuch-search-mode 'notmuch-tree-mode))
           (kill-buffer buffer)))
       (delete-directory notmuch-live-test--dir t))))

(defun notmuch-live-test--settle ()
  "Wait for searches to finish and the lists to catch up."
  (let ((deadline (+ (float-time) 10)))
    (while (and (or notmuch-live--timer
                    (seq-some (lambda (p) (string-prefix-p "notmuch" (process-name p)))
                              (process-list)))
                (< (float-time) deadline))
      (accept-process-output nil 0.02))))

(defun notmuch-live-test--search (query)
  "Open the thread list for QUERY in the selected window and return it."
  ;; notmuch.el takes whether to hide excluded mail from 0.39.
  (apply #'notmuch-search query notmuch-search-oldest-first
         (if (boundp 'notmuch-search-hide-excluded) '(nil nil nil t) '(nil nil t)))
  (let ((buffer (current-buffer)))
    (set-window-buffer (selected-window) buffer)
    (notmuch-live-test--settle)
    buffer))

(defun notmuch-live-test--unthreaded (query)
  "Open the unthreaded list for QUERY in the selected window and return it."
  (notmuch-unthreaded query)
  (let ((buffer (current-buffer)))
    (set-window-buffer (selected-window) buffer)
    (notmuch-live-test--settle)
    buffer))

(defun notmuch-live-test--subjects ()
  "Return the subjects of this thread list's rows, in order."
  (mapcar (lambda (row)
            (plist-get (notmuch-search-get-result (cdr row)) :subject))
          (notmuch-live--search-rows)))

(defun notmuch-live-test--message-subjects ()
  "Return the subjects of this unthreaded list's rows, in order."
  (mapcar (lambda (row)
            (plist-get (plist-get (get-text-property
                                   (cdr row) :notmuch-message-properties)
                                  :headers)
                       :Subject))
          (notmuch-live--message-rows)))

(defun notmuch-live-test--goto (subject)
  "Move point to the thread list's row for SUBJECT."
  (goto-char (point-min))
  (while (not (equal (plist-get (notmuch-search-get-result) :subject) subject))
    (forward-line)))

(defun notmuch-live-test--at ()
  "Return the subject of the thread list's row at point."
  (plist-get (notmuch-search-get-result) :subject))

(defconst notmuch-live-test--three
  '(("a" 3 "Alpha") ("b" 2 "Bravo") ("c" 1 "Charlie"))
  "Three threads of one message each, newest first.")

(ert-deftest notmuch-live-test-tagging-out-moves-point-on ()
  "Tagging the row at point out of the list leaves point on the next row."
  (notmuch-live-test--with-mail notmuch-live-test--three
    (with-current-buffer (notmuch-live-test--search "tag:inbox")
      (let ((removed 0))
        (add-hook 'notmuch-live-row-removed-hook
                  (lambda () (setq removed (1+ removed))) nil t)
        (notmuch-live-test--goto "Bravo")
        ;; As `k' does: tags, and does not move.
        (notmuch-search-tag '("+trash" "-inbox"))
        (should (equal (notmuch-live-test--subjects) '("Alpha" "Bravo" "Charlie")))
        (notmuch-live-test--settle)
        (should (equal (notmuch-live-test--subjects) '("Alpha" "Charlie")))
        (should (equal (notmuch-live-test--at) "Charlie"))
        (should (= removed 1))))))

(ert-deftest notmuch-live-test-last-row-out-leaves-point-past-rows ()
  (notmuch-live-test--with-mail notmuch-live-test--three
    (with-current-buffer (notmuch-live-test--search "tag:inbox")
      (notmuch-live-test--goto "Charlie")
      (notmuch-search-tag '("-inbox"))
      (notmuch-live-test--settle)
      (should (equal (notmuch-live-test--subjects) '("Alpha" "Bravo")))
      (should (null (notmuch-live-test--at)))
      (should (= (point) (notmuch-search-result-end
                          (cdar (last (notmuch-live--search-rows)))))))))

(ert-deftest notmuch-live-test-archive-does-not-skip ()
  "Archiving moves on by itself; catching up must not move point again."
  (notmuch-live-test--with-mail notmuch-live-test--three
    (with-current-buffer (notmuch-live-test--search "tag:inbox")
      (let ((removed 0))
        (add-hook 'notmuch-live-row-removed-hook
                  (lambda () (setq removed (1+ removed))) nil t)
        (notmuch-live-test--goto "Alpha")
        (notmuch-search-archive-thread)
        (notmuch-live-test--settle)
        (should (equal (notmuch-live-test--subjects) '("Bravo" "Charlie")))
        (should (equal (notmuch-live-test--at) "Bravo"))
        (should (= removed 0))))))

(ert-deftest notmuch-live-test-change-from-elsewhere-redraws-row ()
  "A change made outside the list, as by reading the thread, shows in it."
  (notmuch-live-test--with-mail notmuch-live-test--three
    (with-current-buffer (notmuch-live-test--search "tag:inbox")
      (notmuch-live-test--goto "Bravo")
      (let ((pos (point)))
        (forward-char 3)
        (setq pos (point))
        (with-temp-buffer
          (notmuch-tag "id:b@test" '("-unread")))
        (notmuch-live-test--settle)
        (should (equal (notmuch-live-test--subjects) '("Alpha" "Bravo" "Charlie")))
        (should (equal (notmuch-search-get-tags) '("inbox")))
        ;; The row was drawn with unread, which it still shows struck out.
        (should (member "unread" (plist-get (notmuch-search-get-result) :orig-tags)))
        (should (= (point) pos))))))

(ert-deftest notmuch-live-test-thread-out-of-a-hidden-list ()
  "A list that is not shown catches up too."
  (notmuch-live-test--with-mail notmuch-live-test--three
    (let ((list (notmuch-live-test--search "tag:inbox")))
      (set-window-buffer (selected-window) (get-buffer-create "*elsewhere*"))
      (with-temp-buffer
        (notmuch-tag "thread:{id:b@test}" '("+trash" "-inbox")))
      (notmuch-live-test--settle)
      (with-current-buffer list
        (should (equal (notmuch-live-test--subjects) '("Alpha" "Charlie")))))))

(ert-deftest notmuch-live-test-new-mail-goes-in-date-order ()
  "Mail indexed outside Emacs is put in by date and point stays on its row."
  (notmuch-live-test--with-mail notmuch-live-test--three
    (with-current-buffer (notmuch-live-test--search "tag:inbox")
      (notmuch-live-test--goto "Bravo")
      (notmuch-live-test--write "d" 4 "Delta")
      (notmuch-live-test--write "e" 1.5 "Echo")
      (notmuch-live-test--notmuch "new" "--quiet")
      (notmuch-live-update)
      (notmuch-live-test--settle)
      (should (equal (notmuch-live-test--subjects)
                     '("Delta" "Alpha" "Bravo" "Echo" "Charlie")))
      (should (equal (notmuch-live-test--at) "Bravo")))))

(ert-deftest notmuch-live-test-new-mail-just-above-point ()
  "A row put in right where point's row starts does not take point."
  (notmuch-live-test--with-mail notmuch-live-test--three
    (with-current-buffer (notmuch-live-test--search "tag:inbox")
      (notmuch-live-test--goto "Bravo")
      (notmuch-live-test--write "d" 2.5 "Delta")
      (notmuch-live-test--notmuch "new" "--quiet")
      (notmuch-live-update)
      (notmuch-live-test--settle)
      (should (equal (notmuch-live-test--subjects)
                     '("Alpha" "Delta" "Bravo" "Charlie")))
      (should (equal (notmuch-live-test--at) "Bravo")))))

(ert-deftest notmuch-live-test-oldest-first ()
  (notmuch-live-test--with-mail notmuch-live-test--three
    (let ((notmuch-search-oldest-first t))
      (with-current-buffer (notmuch-live-test--search "tag:inbox")
        (notmuch-live-test--write "d" 2.5 "Delta")
        (notmuch-live-test--notmuch "new" "--quiet")
        (notmuch-live-update)
        (notmuch-live-test--settle)
        (should (equal (notmuch-live-test--subjects)
                       '("Charlie" "Bravo" "Delta" "Alpha")))))))

(ert-deftest notmuch-live-test-thread-stays-while-a-message-matches ()
  (notmuch-live-test--with-mail '(("a" 1 "Alpha") ("a2" 2 "Re: Alpha" "a")
                                  ("b" 3 "Bravo"))
    (with-current-buffer (notmuch-live-test--search "tag:inbox")
      (with-temp-buffer (notmuch-tag "id:a2@test" '("-inbox")))
      (notmuch-live-test--settle)
      (should (equal (length (notmuch-live-test--subjects)) 2))
      (with-temp-buffer (notmuch-tag "id:a@test" '("-inbox")))
      (notmuch-live-test--settle)
      (should (equal (notmuch-live-test--subjects) '("Bravo"))))))

(ert-deftest notmuch-live-test-taken-out-and-put-back ()
  "Undoing puts the row back where it was."
  (notmuch-live-test--with-mail notmuch-live-test--three
    (with-current-buffer (notmuch-live-test--search "tag:inbox")
      (with-temp-buffer (notmuch-tag "id:b@test" '("-inbox")))
      (notmuch-live-test--settle)
      (should (equal (notmuch-live-test--subjects) '("Alpha" "Charlie")))
      (with-temp-buffer (notmuch-tag "id:b@test" '("+inbox")))
      (notmuch-live-test--settle)
      (should (equal (notmuch-live-test--subjects) '("Alpha" "Bravo" "Charlie"))))))

(ert-deftest notmuch-live-test-unthreaded ()
  (notmuch-live-test--with-mail '(("a" 1 "Alpha") ("a2" 3 "Re: Alpha" "a")
                                  ("b" 2 "Bravo"))
    (with-current-buffer (notmuch-live-test--unthreaded "tag:inbox")
      (should (equal (notmuch-live-test--message-subjects)
                     '("Re: Alpha" "Bravo" "Alpha")))
      (goto-char (cdr (assoc "b@test" (notmuch-live--message-rows))))
      (let ((removed nil))
        (add-hook 'notmuch-live-row-removed-hook (lambda () (setq removed t)) nil t)
        (with-temp-buffer (notmuch-tag "id:b@test" '("-inbox")))
        (notmuch-live-test--settle)
        (should (equal (notmuch-live-test--message-subjects) '("Re: Alpha" "Alpha")))
        (should (equal (plist-get (notmuch-tree-get-message-properties) :id) "a@test"))
        (should removed))
      (notmuch-live-test--write "c" 2.5 "Charlie")
      (notmuch-live-test--notmuch "new" "--quiet")
      (with-temp-buffer (notmuch-tag "id:a2@test" '("-unread")))
      (notmuch-live-test--settle)
      (should (equal (notmuch-live-test--message-subjects)
                     '("Re: Alpha" "Charlie" "Alpha")))
      (should (equal (plist-get (notmuch-tree-get-message-properties) :id) "a@test"))
      (should (equal (plist-get (get-text-property
                                 (cdr (assoc "a2@test" (notmuch-live--message-rows)))
                                 :notmuch-message-properties)
                                :tags)
                     '("inbox"))))))

(ert-deftest notmuch-live-test-lists-opened-before-are-left ()
  (notmuch-live-test--with-mail notmuch-live-test--three
    (notmuch-live-mode -1)
    (let ((list (notmuch-live-test--search "tag:inbox")))
      (notmuch-live-mode 1)
      (with-temp-buffer (notmuch-tag "id:b@test" '("-inbox")))
      (notmuch-live-test--settle)
      (with-current-buffer list
        (should (equal (notmuch-live-test--subjects) '("Alpha" "Bravo" "Charlie")))))))

;; Renamed or removed in an upgrade, these would break catching up while
;; every list still looked as notmuch drew it.
(ert-deftest notmuch-live-test-notmuch-internals ()
  (dolist (function '(notmuch--process-lines
                      notmuch-call-notmuch-sexp
                      notmuch-search-get-result
                      notmuch-search-result-end
                      notmuch-search-show-result
                      notmuch-search-process-sentinel
                      notmuch-tree-insert-forest-thread
                      notmuch-tree-get-query
                      notmuch-refresh-this-buffer))
    (should (fboundp function)))
  (dolist (variable '(notmuch-search-query-string
                      notmuch-search-oldest-first
                      notmuch-tree-unthreaded
                      notmuch-tree-target-msg
                      notmuch-tree-previous-subject
                      notmuch-after-tag-hook
                      notmuch-hello-refresh-hook))
    (should (boundp variable))))

;;; notmuch-live-tests.el ends here
