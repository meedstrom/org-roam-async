;;; org-roam-async.el --- Sync the org-roam-db faster -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Martin Edström

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.

;; Author:   Martin Edström <meedstrom@runbox.eu>
;; URL:      https://github.com/meedstrom/org-roam-async
;; Created:  2025-10-06
;; Keywords: org-mode, roam, convenience
;; Package-Requires: ((emacs "29.1") (org-roam "2.3.1") (el-job "2.5.0"))

;;; Commentary:

;; Provide `org-roam-async-db-sync', a faster alternative to `org-roam-db-sync'.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'org-roam-db)
(require 'el-job-ng)

(defcustom org-roam-async-file-name-handler-alist nil
  "Override for `file-name-handler-alist'."
  :type 'alist
  :group 'org-roam)


;;;; STAGE 1: Pick files to update

(defvar org-roam-async--time-at-start nil)
(defun org-roam-async-db-sync (&optional force)
  (interactive "P")
  (el-job-ng-kill 'org-roam-async)
  (setq org-roam-async--time-at-start (current-time))
  (message "(org-roam) Beginning DB sync...")
  (redisplay)
  (org-roam-db--close)
  (when force (delete-file org-roam-db-location))
  (org-roam-db)
  (let* ((file-name-handler-alist org-roam-async-file-name-handler-alist)
         (gc-cons-threshold org-roam-db-gc-threshold)
         (disk-files (org-roam-async-list-files))
         (db-mtimes (cl-loop
                     with tbl = (make-hash-table :test #'equal)
                     for (file mtime) in (org-roam-db-query
                                          [:select [file mtime] :from files])
                     do (puthash file mtime tbl)
                     finally return tbl))
         (modified-files nil))
    (dolist (file disk-files)
      (let* ((disk-mtime (file-attribute-modification-time (file-attributes file))))
        (unless (time-equal-p disk-mtime (gethash file db-mtimes))
          (push file modified-files)))
      (remhash file db-mtimes))
    (unless (hash-table-empty-p db-mtimes)
      (emacsql-with-transaction (org-roam-db)
        (dolist-with-progress-reporter (file (hash-table-keys db-mtimes))
            "(org-roam) Clearing removed files..."
          (org-roam-db-clear-file file))))
    (when modified-files
      (message "(org-roam) Processing modified files in the background...")
      (redisplay)
      (el-job-ng-run :id 'org-roam-async
                     :require '( org-roam-async )
                     :inject-vars (org-roam-async--relevant-user-settings)
                     :inputs modified-files
                     :funcall-per-input #'org-roam-async--parse-file
                     :callback #'org-roam-async--insert-into-db)
      (org-roam-async-spinner-mode))
    (unless modified-files
      (message "(org-roam) Synced the DB in total %.2fs"
               (float-time (time-since org-roam-async--time-at-start))))))

(define-minor-mode org-roam-async-spinner-mode
  "Mode for showing animation in modeline while subprocesses at work.
Also watches if they take too long, and kills them.
Turns itself off."
  :lighter (:eval (format " (%.2fs)org-roam-async..."
                          (float-time (time-since org-roam-async--time-at-start))))
  :global t
  :group 'org-roam
  (if org-roam-async-spinner-mode
      (run-with-timer 1 nil #'org-roam-async--maybe-stop-spinner)))

(defun org-roam-async--maybe-stop-spinner ()
  (let ((elapsed (float-time (time-since org-roam-async--time-at-start))))
    (if (< elapsed 500)
        (if (el-job-ng-busy-p 'org-roam-async)
            (run-with-timer 1 nil #'org-roam-async--maybe-stop-spinner)
          (org-roam-async-spinner-mode 0))
      (el-job-ng-kill-keep-bufs 'org-roam-async)
      (message "(org-roam) Killed DB-sync because it took %.2fs" elapsed))))

;; NOTE: Cannot yet inject `org-roam-db-node-include-function' thru el-job-ng.
(defun org-roam-async--relevant-user-settings ()
  (list (cons 'org-roam-db-extra-links-elements        org-roam-db-extra-links-elements)
        (cons 'org-roam-db-extra-links-exclude-keys    org-roam-db-extra-links-exclude-keys)
        (cons 'org-roam-directory                      org-roam-directory)
        (cons 'org-roam-db-gc-threshold                org-roam-db-gc-threshold)
        (cons 'org-roam-async-file-name-handler-alist  org-roam-async-file-name-handler-alist)))


;;;; STAGE 2: Work in child processes.

(defvar org-roam-async--stored-queries nil
  "List of \((SQL ARGS...) (SQL ARGS...) ...).")

(defun org-roam-async--store-query (&rest arglist)
  "Add ARGLIST to `org-roam-async--stored-queries'."
  (push arglist org-roam-async--stored-queries))

(defun org-roam-async--store-query! (_handler &rest arglist)
  "Add ARGLIST to `org-roam-async--stored-queries'.
Ignore first arg HANDLER because this expects to run in a subprocess."
  (apply #'org-roam-async--store-query arglist))

(defvar org-roam-async--hashes-tbl (make-hash-table :test #'equal))
(defvar org-roam-async--attrs-tbl (make-hash-table :test #'equal))
(defun org-roam-async--init-work-buffer (files)
  "Read FILES into buffers and return an Org work buffer."
  ;; Pre-read all files, in case file-names change during parsing.
  (save-current-buffer
    (dolist (file files)
      (set-buffer (get-buffer-create file t))
      (cl-assert (and (bobp) (eobp) (eq major-mode 'fundamental-mode)))
      (insert-file-contents file)
      ;; TODO: Profile with the empty string instead.
      ;; (puthash file "" org-roam-async--hashes-tbl)
      (puthash file (org-roam-db--file-hash file) org-roam-async--hashes-tbl)
      (puthash file (file-attributes file) org-roam-async--attrs-tbl)))
  ;; Enable `org-mode' only once for this process.
  (with-current-buffer (get-buffer-create "*org-roam-async scratch*" t)
    (let ((org-element-cache-persistent nil)
          (org-agenda-files nil)
          (org-inhibit-startup t))
      (delay-mode-hooks
        (org-mode)))
    (setq-local org-element-cache-persistent nil)
    (current-buffer)))

;; Called for every file (by `el-job-ng--child-work')
(defvar org-roam-async--work-buf nil)
(defun org-roam-async--parse-file (file rest)
  "Parse FILE and return a list of EmacSQL queries reflecting it.
REST is the remaining files for this subprocess."
  (let ((file-name-handler-alist org-roam-async-file-name-handler-alist)
        (gc-cons-threshold org-roam-db-gc-threshold))
    (unless (eq org-roam-async--work-buf (current-buffer))
      (switch-to-buffer
       (setq org-roam-async--work-buf
             (org-roam-async--init-work-buffer (cons file rest)))))
    (erase-buffer)
    (org-element-cache-reset) ;; TODO: Profile with cache disabled.
    (insert-buffer-substring (get-buffer file))
    ;; HACK: Simulate a file-visiting buffer.
    (let ((buffer-file-name file)
          (default-directory (file-name-directory file)))
      (org-roam-async--mk-sql-queries))))

(defun org-roam-async--mk-sql-queries ()
  "The meat of what was `org-roam-db-update-file'."
  (require 'org-ref nil t)
  (require 'oc)
  (org-set-regexps-and-options 'tags-only)
  (setq org-roam-async--stored-queries nil)
  (org-roam-async--store-query [:delete :from files :where (= file $s1)]
                               buffer-file-name)
  (org-roam-async--store-file-query)
  (cl-letf* (((symbol-function #'org-roam-db-query) #'org-roam-async--store-query)
             ((symbol-function #'org-roam-db-query!) #'org-roam-async--store-query!))
    (org-roam-db-insert-file-node)
    (setq org-outline-path-cache nil) ;; REVIEW: Why?
    (org-roam-db-map-nodes (list #'org-roam-db-insert-node-data
                                 #'org-roam-db-insert-aliases
                                 #'org-roam-db-insert-tags
                                 #'org-roam-db-insert-refs))
    (setq org-outline-path-cache nil) ;; REVIEW: Why?
    (let ((info (org-element-parse-buffer)))  ;; REVIEW: Why?
      (org-roam-db-map-links (list #'org-roam-db-insert-link))
      (org-roam-db-map-citations info (list #'org-roam-db-insert-citation))))
  ;; Put deletion queries before insertion queries.
  (nreverse org-roam-async--stored-queries))

;; A work-around because our `org-roam-async--init-work-buffer' pre-reads all
;; files before we begin any parsing, so we should not use
;; `org-roam-db-insert-file' during parsing, as it re-accesses the filesystem.

(defun org-roam-async--store-file-query (&optional _)
  "Like `org-roam-db-insert-file', but avoid the filesystem."
  (let* ((file (buffer-file-name))
         (file-title (org-roam-db--file-title))
         (attr (gethash file org-roam-async--attrs-tbl))
         (atime (file-attribute-access-time attr))
         (mtime (file-attribute-modification-time attr))
         (hash (gethash file org-roam-async--hashes-tbl)))
    (org-roam-async--store-query
     [:insert :into files
              :values $v1]
     (list (vector file file-title hash atime mtime)))))


;;; STAGE 3: All children returned, process their combined results.

(defvar org-roam-async--last-outputs nil)
(defun org-roam-async--insert-into-db (outputs)
  (setq org-roam-async--last-outputs outputs) ;; inspect this for fun
  (let ((n-files (length outputs))
        (n-queries (apply #'+ (mapcar #'length outputs)))
        (ctr 0)
        (gc-cons-threshold org-roam-db-gc-threshold))
    (emacsql-with-transaction (org-roam-db)
      (dolist (arg-sets outputs)
        (message "(org-roam) Running %d SQL queries... (for %d/%d files)"
                 n-queries (cl-incf ctr) n-files)
        (dolist (args arg-sets)
          (apply #'org-roam-db-query args))))
    (message "(org-roam) Synced the DB in total %.2fs"
             (float-time (time-since org-roam-async--time-at-start)))))


;;; OPTIONAL STUFF

(defun org-roam-async-open-db ()
  "Browse the DB contents."
  (interactive)
  (require 'sqlite-mode)
  (sqlite-mode-open-file org-roam-db-location))

;; NOTE: Here's a possible reimplementation of `org-roam-db-update-file' for
;;       purpose of after-save-hook, although you could go with the original.
;;       But I think it'd be cleaner to throw it away altogether and reuse
;;       `org-roam-async-db-sync' everywhere.

(defun org-roam-async-db-update-file (&optional file-path _)
  "An alternative to `org-roam-db-update-file'.
Since it is asynchronous, it may be unsuitable if you depend on a
certain order of events on your save hook."
  (setq file-path (or file-path (buffer-file-name (buffer-base-buffer))))
  (let ((content-hash (org-roam-db--file-hash file-path))
        (db-hash (caar (org-roam-db-query [ :select hash :from files
                                            :where (= file $s1)]
                                          file-path))))
    (unless (string= content-hash db-hash)
      (el-job-ng-run :require '( org-roam-async )
                     :inject-vars (org-roam-async--relevant-user-settings)
                     :inputs (list file-path)
                     :funcall-per-input #'org-roam-async--parse-file
                     :callback #'org-roam-async--insert-into-db))))

;;;; Faster `org-roam-list-files'  (that thing takes 5 full seconds on a SSD)

(defun org-roam-async-list-files ()
  "Replacement for `org-roam-list-files'."
  (org-roam-async--list-files (expand-file-name org-roam-directory)))

(defvar org-roam-async--suffixes nil)
(defvar org-roam-async--suffixes-re nil)
(defun org-roam-async--recalc-suffixes ()
  (setq org-roam-async--suffixes
        (cl-loop for ext in org-roam-file-extensions
                 append (list (concat "." ext)
                              (concat "." ext ".age")
                              (concat "." ext ".gpg"))))
  (setq org-roam-async--suffixes-re
        (rx (regexp (regexp-opt org-roam-async--suffixes)) eos)))

(defun org-roam-async--list-files (dir)
  "Replacement for `org-roam--list-files'."
  (org-roam-async--recalc-suffixes)
  (cl-loop for file in (directory-files-recursively
                        dir
                        org-roam-async--suffixes-re
                        nil
                        nil
                        ;; REVIEW: Why?
                        t)
           when (and (file-readable-p file)
                     (org-roam-async--roam-file-p file))
           collect file))

(defun org-roam-async--roam-file-p (&optional file)
  "Replacement for `org-roam-file-p'."
  (and (setq file (or file (buffer-file-name (buffer-base-buffer))))
       (cl-loop for suffix in org-roam-async--suffixes
                thereis (string-suffix-p suffix file))
       (cl-loop for exclude-re in org-roam-file-exclude-regexp
                never (string-match-p exclude-re file))
       (file-in-directory-p file org-roam-directory))) ;; FIXME: Perf hotspot

(provide 'org-roam-async)

;;; org-roam-async.el ends here
