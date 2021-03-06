;;; mk-project-orgmode.el ---  Org-Mode integration for mk-project

;; Copyright (C) 2011  Andreas Raster <lazor at affenbande dot org>
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

(require 'mk-project)

(require 'org-install)
(require 'org-protocol)
(require 'org-agenda)
;;(require 'org-depend)
(require 'ob)

(defvar mk-org-project-search-files nil
  "List of .org files that mk-org searches for project definitions.")

(defvar mk-org-todo-keywords '("TODO")
  "Todo keywords that mk-org will recognize as tasks. Every org entry that
does not have any of those keywords as todo will not be visited by `mk-org-map-entries'")

(defvar mk-org-ignore-todos '("DONE"))

(defvar mk-org-active-todo-keyword nil
  "Active keyword is a special keyword that subtrees can have to specify a task
that has lots of other tasks as children but is not a complete project itself.

So far this is only used when creating project-todos, to put the todo under
the active subtree, instead of the parent subtree.")

(defvar mk-org-config-save-location t
  "Where to store project org trees. Can be either a directory name to use
one org file per project stored in a single directory, can be a filename
to use a single org file for all projects, for every other non-nil value
a single org file is stored in the projects basedir.")

(defvar mk-org-config-save-section "Projects"
  "A headline under which to store project org trees.")


(eval-after-load "mk-project-orgmode"
  '(progn
     (add-to-list 'mk-proj-optional-vars '(org-file . (stringp)))
     (add-to-list 'mk-proj-optional-vars '(org-headline . (stringp)))

     (add-to-list 'mk-proj-internal-vars 'org-file)
     (add-to-list 'mk-proj-internal-vars 'org-headline)

     (add-hook 'org-clock-in-hook (lambda ()
                                    (when (and (mk-org-entry-is-in-project-p)
                                               (or (not (boundp 'mk-proj-name))
                                                   (and (boundp 'mk-proj-name)
                                                        mk-proj-name
                                                        (not (string-equal mk-proj-name (mk-org-entry-name))))))
                                      (unless (mk-proj-find-alist (mk-org-entry-name))
                                        (project-def (mk-org-entry-name) (mk-org-entry-alist)))
                                      (mk-proj-load (mk-org-entry-name)))))
     (add-hook 'org-after-todo-state-change-hook (lambda ()
                                                   (beginning-of-line)
                                                   (when (some (lambda (x) (string-equal (org-get-todo-state) x)) org-done-keywords)
                                                     (mk-org-clock-from-parent-to-todo))))
     (add-hook 'org-after-todo-state-change-hook (lambda ()
                                                   (beginning-of-line)
                                                   (when (and (some (lambda (x) (string-equal (org-get-todo-state) x)) mk-org-todo-keywords)
                                                              (mk-org-entry-is-in-project-p))
                                                     (mk-org-entry-define-project))))
     (add-hook 'org-after-todo-state-change-hook (lambda ()
                                                   (beginning-of-line)
                                                   (let ((proj-name (mk-org-entry-name)))
                                                     (when (and proj-name
                                                                (some (lambda (x) (string-equal (org-get-todo-state) x)) mk-org-todo-keywords)
                                                                (mk-org-entry-is-in-project-p)
                                                                (functionp 'mk-sourcemarker-save-all)
                                                                (not (file-exists-p (mk-proj-get-config-val 'sourcemarker-db-path proj-name))))
                                                       (mk-proj-with-current-project proj-name (mk-sourcemarker-save-all))))))

     (mk-proj-define-backend 'org-mode
                             :buffer-fun 'mk-org-config-buffer
                             :save-fun 'mk-org-config-save
                             :insert-fun 'mk-org-config-insert
                             :test-fun (lambda (ca)
                                         (assoc 'org-file ca)))

     (add-hook 'mk-proj-before-load-hook (lambda ()
                                           (unless (mk-proj-get-config-val 'org-file proj-name)
                                             (let ((org-file (concat (mk-proj-get-config-val 'basedir proj-name) "/" proj-name ".org")))
                                               (when (file-exists-p org-file)
                                                 (mk-org-search-projects org-file))))))
     (add-hook 'mk-proj-after-load-hook (lambda ()
                                          (when (mk-proj-get-config-val 'org-file)
                                            (project-clock-in))))
     (add-hook 'mk-proj-before-unload-hook (lambda ()
                                             (when (mk-proj-get-config-val 'org-file)
                                               (project-clock-out))))
     (add-hook 'after-save-hook 'mk-org-after-save-search)))

(defun mk-org-after-save-search ()
  (when mk-proj-name
    (unless (or (string-match ".*recentf.*" (buffer-name (current-buffer)))
                (string-match ".*file-list-cache.*" (buffer-name (current-buffer)))
                (string-match ".*sourcemarker-db.*" (buffer-name (current-buffer)))
                (string-match ".*continue-db.*" (buffer-name (current-buffer))))
      (let ((filename (buffer-file-name (current-buffer))))
        (when (and filename
                   (eq major-mode 'org-mode)
                   (mk-proj-get-config-val 'org-file)
                   (string-equal (file-truename filename)
                                 (file-truename (mk-proj-get-config-val 'org-file))))
          (mk-org-search-projects filename))))))

(defun mk-org-concatl (&rest sequences-sequence)
  (let ((r '()))
    (mapc (lambda (l1)
           (mapc (lambda (l2)
                (mapc (lambda (x)
                        (add-to-list 'r x t)) l2))
                 l1))
         sequences-sequence)
   r))

(defun mk-org-files-containing-projects ()
  "Searches all defined projects and returns a list of all .org files
in which projects have been defined as well as the files specified by
`mk-org-project-search-files'.
Also tries to find org files with projects in files from `recentf-list'."
  (let ((org-files '()))
    (maphash (lambda (k p)
               ;; - first check for org-file config option
               ;; - second check if a file named $projectname.org is in $basedir
               (cond ((cdr (assoc 'org-file p))
                      (add-to-list 'org-files (cadr (assoc 'org-file p))))
                     ((let ((project-org-filename (concat (expand-file-name (cadr (assoc 'basedir p))) (cadr (assoc 'name p)) ".org")))
                        (when (file-exists-p project-org-filename)
                          (add-to-list 'org-files project-org-filename))))))
             mk-proj-list)
    (when (boundp 'recentf-list)
      (dolist (recent-file recentf-list)
        (when (and (file-exists-p recent-file)
                   (string-match ".*\\.org" recent-file)
                   (= (call-process "bash" nil nil nil "-c" (concat "grep \"MKP_NAME\\|mkp_name\" \"" recent-file "\"")) 0))
          (add-to-list 'org-files recent-file 'string-equal))))
    (let* ((find-cmd (concat (if (eq system-type 'windows-nt) "gfind" "find") " -iname open-files-cache"))
           (default-directory mk-global-cache-root)
           (directory-table (make-hash-table :test 'equal)))
      (with-temp-buffer
        (call-process-shell-command find-cmd nil t)
        (loop for cache in (split-string (buffer-string) "\n" t)
              do (with-temp-buffer
                   (insert-file-contents cache)
                   (loop for line in (split-string (buffer-string) "\n" t)
                         do (unless (gethash (mk-proj-dirname line) directory-table)
                              (puthash (mk-proj-dirname line) t directory-table)
                              (dolist (org-file (directory-files (mk-proj-dirname line) t ".*\.org$"))
                                (add-to-list 'org-files org-file))))))))
    (remove-if (lambda (x)
                 (or (not (file-exists-p x))
                     (eq x nil)))
               (remove-duplicates
                (append org-files (mk-org-concatl (mapcar (lambda (path)
                                                            (let ((path (file-name-as-directory path)))
                                                              (cond ((condition-case nil (directory-files path) (error nil))
                                                                     (let ((currentdir default-directory))
                                                                       (cd path)
                                                                       (let ((result (split-string (shell-command-to-string "grep -ls \"MKP_NAME\\|mkp_name\" *.org") "\n" t)))
                                                                         (cd currentdir)
                                                                         (mapcar (lambda (f) (expand-file-name (concat path f))) result))))
                                                                    ((file-exists-p path)
                                                                     `(,(expand-file-name path)))
                                                                    (t (file-expand-wildcards path)))))
                                                          ;; - mk-org-project-search-files can contain directories, is appending here the right thing to do? have
                                                          ;; I coded this so that somewhere down the line I check for directories? I hope so...
                                                          (append mk-org-project-search-files
                                                                  (let ((xs '()))
                                                                    (maphash (lambda (k v)
                                                                               (let ((path (cadr (assoc 'basedir v))))
                                                                                 (when path
                                                                                   (add-to-list 'xs path))))
                                                                             mk-proj-list)
                                                                    xs)))))
                :test #'string-equal))))

;; (setq mk-org-project-search-files '("~/org/" "~/org/projects.org"))
;; (mk-org-files-containing-projects)

;; (defun mk-org-find-recent-org-files ()
;;   (let ((project-files (mk-org-files-containing-projects)))
;;     (remove-if (lambda (recent-file)
;;                  (or (not (string-equal (file-name-extension recent-file) "org"))
;;                      (some (lambda (proj-file)
;;                              (string-equal (file-name-nondirectory recent-file)
;;                                            (file-name-nondirectory proj-file)))
;;                            project-files)))
;;                recentf-list)))

(defun mk-org-symbol-table (&optional symbol)
  "Creates an alist of (symbol . org-property-string) that can be used
to look up the org property which represents a mk-project config symbol.

Optional argument SYMBOL can be specified if you just want to look up
a single symbol and don't need the whole alist."
  (let* ((proj-vars (append mk-proj-required-vars mk-proj-optional-vars))
         (props '())
         (table (progn
                  (dolist (varchecks proj-vars props)
                    (add-to-list 'props `(,(car varchecks) . ,(concat "mkp_" (replace-regexp-in-string "-" "_" (downcase (symbol-name (car varchecks))))))))
                  )))
    (if symbol
        (cdr (assoc symbol table))
      table)))

;; (mk-org-symbol-table 'name)

(defun mk-org-assert-org (&optional proj-name try-guessing)
  "Same as `mk-proj-assert-proj' but makes sure that the project has
an associated org file.

Optionally PROJ-NAME can be specified to test a specific project other
than the current one."
  (let ((guessed-alist nil))
    (cond
     ;; 1. project loaded, org -> nothing
     ((and (not (condition-case nil (mk-proj-assert-proj) (error t)))
           (mk-proj-get-config-val 'org-file mk-proj-name))
      nil)
     ;; 2. project loaded, not org -> convert and load mk-proj-name
     ((and try-guessing
           (not (condition-case nil (mk-proj-assert-proj) (error t)))
           (not (mk-proj-get-config-val 'org-file mk-proj-name))
           (y-or-n-p (concat "Create .org file for " mk-proj-name "? ")))
      (mk-org-config-save mk-proj-name (mk-proj-find-alist mk-proj-name t))
      (mk-proj-load mk-proj-name)
      nil)
     ;; 3. project not loaded, proj-name and org -> load proj-name
     ((and try-guessing
           (condition-case nil (mk-proj-assert-proj) (error t))
           proj-name
           (mk-proj-get-config-val 'org-file proj-name)
           (y-or-n-p (concat "Load " proj-name "? ")))
      (mk-proj-load proj-name)
      nil)
     ;; 4. project not loaded, proj-name not org -> convert and load proj-name
     ((and try-guessing
           (condition-case nil (mk-proj-assert-proj) (error t))
           proj-name
           (not (mk-proj-get-config-val 'org-file proj-name))
           (y-or-n-p (concat "Create .org file for " proj-name "? ")))
      (mk-org-config-save mk-proj-name (mk-proj-find-alist proj-name t))
      (mk-proj-load proj-name)
      nil)
     ;; 5. guessed exists, org -> load guessed
     ((and try-guessing
           (setq guessed-alist (mk-proj-guess-alist))
           (assoc 'org-file (mk-proj-find-alist (cadr (assoc 'name guessed-alist)) t))
           (y-or-n-p (concat "Load " (cadr (assoc 'name guessed-alist)) "? ")))
      (mk-proj-load (cadr (assoc 'name guessed-alist)))
      nil)
     ;; 6. try-guessing t -> create, convert and load guessed
     ((and try-guessing
           guessed-alist
           (or (not mk-proj-name)
               (not (string-equal mk-proj-name
                                  (cadr (assoc 'name guessed-alist)))))
           (y-or-n-p (concat "Create .org file for guessed project *" (cadr (assoc 'name guessed-alist)) "? ")))
      (mk-org-config-save (cadr (assoc 'name guessed-alist)) guessed-alist)
      (mk-proj-load (cadr (assoc 'name guessed-alist)))
      nil)
     (t
      (error (format "mk-org: Project %s has no associated org file!" mk-proj-name))))))

(defun mk-org-forward-same-level ()
  (interactive)
  (let ((l (save-excursion
             (beginning-of-line)
             (org-outline-level))))
    (outline-next-heading)
    (while (and (> (org-outline-level) l)
                (not (eobp)))
      (outline-next-heading))))











(defun* mk-org-map-entries (&key function
                                 (file nil)
                                 (match nil)
                                 (scope 'project-tree)
                                 (widen nil)
                                 (close-files nil)) ;; dangerous
  "Map over org entries. Similar to `org-map-entries', but implements
scopes better suited to map other org entries that are projects and accepts
a wider variety of matches.

FUNCTION is a function that is called for every match found by searching
for MATCH in sources specified by FILE.

FILE can be either just a filename, a list of files or a buffer.

MATCH can be a marker or sourcemarker, a single number representing a point or
a project name. FUNCTION is called with point on everything MATCH finds.

Furthermore MATCH can be:
a exact headline: '(headline \"A headline\")
a regular expression: '(re \"expression\")
a org property: '(property \"NAME\" \"VALUE\")
a function with arguments '(func args) (some leftover experiment, use at own risk)

SCOPE can be either project-tree to map of a whole tree of projects, including
all child projects, project-single to map over a single project tree excluding
child projects and project-headline to map over just the headline(s) of projects.

If scope is nil or one of the `org-map-entries' scope symbols, `org-map-entries'
will be used internally. You can specify a MATCH to be used in that case with:
'(org \"tags/property/todo match\")"
  (let ((results '())
        (next-point nil)
        (opened-files nil)
        (enable-local-variables :safe))
    (dolist (project-file (setq opened-files (cond ((and (markerp match) (marker-buffer match))
                                                    `(,(marker-buffer match)))
                                                   ((and (functionp 'continue-sourcemarker-p)
                                                         (continue-sourcemarker-p match))
                                                    `(,(marker-buffer (continue-sourcemarker-restore match))))
                                                   ((or (buffer-live-p file) (and (char-or-string-p file) (file-exists-p file)))
                                                    `(,file))
                                                   ((and file (listp file))
                                                    file)
                                                   ((or (eq file nil) (eq file 'current-file))
                                                    (progn (mk-org-assert-org) `(,(mk-proj-get-config-val 'org-file))))
                                                   (t
                                                    (mk-org-files-containing-projects)))))
      (with-current-buffer (or (when (buffer-live-p project-file) project-file)
                               (org-find-base-buffer-visiting project-file)
                               (if (file-exists-p project-file)
                                   (find-file-noselect project-file)
                                 (progn
                                   (message (format "mk-org: No such file %s" project-file))
                                   (return-from "mk-org-map-entries" nil))))
        ;; - call set-auto-mode when buffer not in org-mode so that org-complex-heading-regexp-format
        ;; gets defined
        (unless (eq major-mode 'org-mode)
          (set-auto-mode))
        (save-excursion
          (save-restriction
            (when widen (widen))
            (goto-char (point-min))
            (let* ((project-file (if (buffer-live-p project-file)
                                     (buffer-file-name project-file)
                                   project-file))
                   (re (cond ((and (markerp match) (marker-position match))
                              (marker-position match))
                             ((and (functionp 'continue-sourcemarker-p)
                                   (continue-sourcemarker-p match))
                              (marker-position (continue-sourcemarker-restore match)))
                             ((numberp match)
                              match)
                             ((and match (listp match) (eq (car match) 'headline))
                              (format org-complex-heading-regexp-format (regexp-quote (cadr match))))
                             ((and match (listp match) (eq (car match) 'org))
                              (cadr match))
                             ((and match (listp match) (eq (car match) 're))
                              (regexp-quote (cadr match)))
                             ((and match (listp match) (eq (car match) 'property) (= (list-length match) 3))
                              (concat "^[ \t]*:" (or (second match) "[^:]+") ":[ \t]*\\(" (or (third match) ".*") "\\)"))
                             ((and match (listp match) (functionp (car match)))
                              (funcall (car match) (cadr match)))
                             ((stringp match)
                              (concat "^[ \t]*:\\(MKP_NAME\\|mkp_name\\):[ \t]*\\(\"" match "\"\\)"))
                             (t
                              "^[ \t]*:\\(MKP_NAME\\|mkp_name\\):[ \t]*\\(.*\\)")))
                   (case-fold-search nil)
                   (skip-project-functions nil))
              (while (cond ((numberp re)
                            t)
                           ((stringp re)
                            (re-search-forward re nil t))
                           (t
                            nil))
                (when (numberp re)
                  (goto-char re)
                  (setq re next-point))
                (unless (when skip-project-functions
                          (save-excursion
                            (org-back-to-heading t)
                            (loop for f in skip-project-functions
                                  until (funcall f)
                                  finally return (funcall f))))
                  (let* ((entry-name (save-excursion
                                       (org-back-to-heading t)
                                       (beginning-of-line)
                                       (mk-org-entry-name)))
                         (entry-level (save-excursion
                                        (org-back-to-heading t)
                                        (beginning-of-line)
                                        (mk-org-entry-level)))
                         (entry-point (save-excursion
                                        (org-back-to-heading t)
                                        (beginning-of-line)
                                        (point)))
                         (parent-name (save-excursion
                                        (org-back-to-heading t)
                                        (beginning-of-line)
                                        (mk-org-entry-parent-name)))
                         (parent-level (save-excursion
                                         (org-back-to-heading t)
                                         (beginning-of-line)
                                         (mk-org-entry-parent-level)))
                         (parent-point (save-excursion
                                         (org-back-to-heading t)
                                         (beginning-of-line)
                                         (mk-org-entry-parent-point)))
                         (f-closure (lambda ()
                                      (let ((r nil)
                                            (entry-name (read (or (org-entry-get (point) (mk-org-symbol-table 'name))
                                                                  (org-entry-get (point) (upcase (mk-org-symbol-table 'name)))
                                                                  (concat "\"" parent-name ":" (mk-org-entry-headline) "\"")
                                                                  "nil")))
                                            (entry-level (save-excursion
                                                           (beginning-of-line)
                                                           (org-outline-level)))
                                            (entry-point (point)))
                                        (setq r (save-excursion
                                                  (org-back-to-heading t)
                                                  (beginning-of-line)
                                                  (funcall function))
                                              results (append results `(,r)))
                                        r)))
                         (project-recursion (lambda ()
                                              (funcall f-closure)
                                              (while (and (progn
                                                            (outline-next-heading)
                                                            (> (org-outline-level) entry-level))
                                                          (not (eobp)))
                                                (cond ((and (eq scope 'project-tree)
                                                            (or (org-entry-get (point) (mk-org-symbol-table 'name))
                                                                (org-entry-get (point) (upcase (mk-org-symbol-table 'name)))))
                                                       (let* ((parent-name entry-name)
                                                              (parent-level entry-level)
                                                              (parent-point entry-point)
                                                              (entry-name (read (or (org-entry-get (point) (mk-org-symbol-table 'name))
                                                                                    (org-entry-get (point) (upcase (mk-org-symbol-table 'name)))
                                                                                    "nil")))
                                                              (entry-level (save-excursion
                                                                             (beginning-of-line)
                                                                             (org-outline-level)))
                                                              (entry-point (point)))
                                                         (setq skip-project-functions (append skip-project-functions
                                                                                              `((lambda ()
                                                                                                  (string-equal (read (or (org-entry-get (point) (mk-org-symbol-table 'name))
                                                                                                                          (org-entry-get (point) (upcase (mk-org-symbol-table 'name)))
                                                                                                                          "nil"))
                                                                                                                ,(read (or (org-entry-get (point) (mk-org-symbol-table 'name))
                                                                                                                           (org-entry-get (point) (upcase (mk-org-symbol-table 'name)))
                                                                                                                           "nil")))))))
                                                         (funcall project-recursion)
                                                         (outline-previous-heading)))
                                                      ((and (eq scope 'project-single)
                                                            (or (org-entry-get (point) (mk-org-symbol-table 'name))
                                                                (org-entry-get (point) (upcase (mk-org-symbol-table 'name)))))
                                                       (mk-org-forward-same-level)
                                                       )
                                                      (t
                                                       (let ((parent-name entry-name)
                                                             (parent-level entry-level)
                                                             (parent-point entry-point))
                                                         (funcall f-closure)
                                                         ))))
                                              )))
                    (cond ((eq scope 'project-headline)
                           (save-excursion
                             (org-back-to-heading t)
                             (funcall f-closure)))
                          ((or (eq scope 'project-tree)
                               (eq scope 'project-single))
                           (funcall project-recursion))
                          (t
                           (org-map-entries f-closure re scope nil nil)))))))))))
    (dolist (f opened-files)
      (when (and (stringp f) (file-exists-p f))
        (let ((buf (find-buffer-visiting f)))
          (when (and buf (not (buffer-modified-p buf)) (not (mk-proj-buffer-has-markers-p buf)))
            (kill-buffer buf)))))
    results))

(defun test-mk-org-map-entries ()
  (interactive)
  (mk-org-map-entries
   :file (current-buffer)
   :match (point)
   :scope 'project-single
   :function (lambda ()
               (message (format "%s -> %s" (read (prin1-to-string parent-name)) entry-name))
               )))









(defun mk-org-entry-name (&optional marker)
  (interactive)
  (with-or-without-marker marker
   (if (and (boundp 'entry-name)
            (eq (point) entry-point))
       entry-name
     (or (read (or (org-entry-get (point) (mk-org-symbol-table 'name))
                   (org-entry-get (point) (upcase (mk-org-symbol-table 'name)))
                   "nil"))
         (let ((some-name (or (org-entry-get (point) (mk-org-symbol-table 'name) t)
                              (org-entry-get (point) (upcase (mk-org-symbol-table 'name)) t))))
           (when some-name
             (concat (read some-name) ":" (mk-org-entry-headline))))))))

(defun mk-org-entry-marker (&optional marker)
  (interactive)
  (if (markerp marker)
      marker
    (save-excursion
      (beginning-of-line)
      (when (looking-at org-complex-heading-regexp)
        (let ((point (point)))
          (with-current-buffer (or (buffer-base-buffer (current-buffer)) (current-buffer))
            (copy-marker (point-marker))))))))

(defun mk-org-entry-level (&optional marker)
  (interactive)
  (with-or-without-marker marker
   (if (and (boundp 'entry-level)
            (numberp entry-level)
            (eq (point) entry-point))
       entry-level
     (save-excursion
       (if (not (looking-at org-complex-heading-regexp)) 0
         (beginning-of-line)
         (org-outline-level))))))

(defun mk-org-entry-parent-level (&optional marker)
  (interactive)
  (with-or-without-marker marker
   (if (and (boundp 'parent-level)
            (numberp parent-level)
            (eq (point) entry-point))
       parent-level
     (save-excursion
       (let ((p (mk-org-entry-parent-point)))
         (if (eq p nil) (org-outline-level)
           (goto-char p)
           (beginning-of-line)
           (org-outline-level)))))))

(defun mk-org-entry-parent-name (&optional marker)
  (interactive)
  (with-or-without-marker marker
   (if (and (boundp 'parent-name)
            (eq (point) entry-point))
       parent-name
     (save-excursion
       (let ((p (mk-org-entry-parent-point)))
         (if (eq p nil) nil
           (goto-char p)
           (read (or (org-entry-get (point) (mk-org-symbol-table 'name))
                     (org-entry-get (point) (upcase (mk-org-symbol-table 'name)))))))))))

(defun mk-org-entry-parent-point (&optional marker)
  (interactive)
  (with-or-without-marker marker
   (if (and (boundp 'parent-point)
            (boundp 'entry-point)
            (eq (point) entry-point))
       parent-point
     (save-excursion
       (org-back-to-heading t)
       (let ((parent-point nil)
             (parent-name (or (org-entry-get (point) (mk-org-symbol-table 'name) t)
                              (org-entry-get (point) (upcase (mk-org-symbol-table 'name)) t)))
             (cont nil)
             (is-project (mk-org-entry-is-project-p)))
         (setq cont (org-up-heading-safe))
         (when is-project
           (setq parent-name (or (org-entry-get (point) (mk-org-symbol-table 'name) t)
                                 (org-entry-get (point) (upcase (mk-org-symbol-table 'name)) t))))
         (when (and parent-name cont)
           (while (and cont
                       (setq parent-point (point))
                       (not (string-equal (or (org-entry-get (point) (mk-org-symbol-table 'name))
                                              (org-entry-get (point) (upcase (mk-org-symbol-table 'name))))
                                          parent-name)))
             (setq cont (org-up-heading-safe))))
         parent-point)))))

(defun mk-org-entry-nearest-active (&optional marker)
  (interactive)
  (with-or-without-marker marker
   (if mk-org-active-todo-keyword
       (save-excursion
         (org-back-to-heading t)
         (unless (mk-org-entry-is-project-p)
           (while (and (not (string-equal (org-get-todo-state) mk-org-active-todo-keyword))
                       (not (mk-org-entry-is-project-p)))
             (org-up-heading-all 1)))
         (point))
     (mk-org-entry-parent-point))))

(defun mk-org-entry-headline (&optional marker)
  (interactive)
  (with-or-without-marker marker
   (save-excursion
     (org-back-to-heading t)
     (beginning-of-line)
     (and (looking-at org-complex-heading-regexp)
          (let* ((headline-raw (org-match-string-no-properties 4)))
            (cond ((string-match org-bracket-link-regexp headline-raw)
                   (match-string 2 headline-raw))
                  ((string-match "^\\([^\\[]+\\)\s+\\[\\([0-9]%\\|[0-9][0-9]%\\)\\]$" headline-raw)
                   (match-string 1 headline-raw))
                  (t
                   headline-raw)))))))

;; (when (string-match "^\\([^\\[]+\\)\s+\\[\\([0-9]%\\|[0-9][0-9]%\\)\\]$" "foobar")
;;   (print (match-string 2 "foobar [19%]")))

(defun mk-org-entry-is-link-p (&optional marker)
  (interactive)
  (with-or-without-marker marker
   (save-excursion
     (beginning-of-line)
     (and (looking-at org-complex-heading-regexp)
          (let* ((headline-raw (org-match-string-no-properties 4)))
            (string-match org-bracket-link-regexp headline-raw))))))


(defun mk-org-entry-progress (&optional marker)
  (interactive)
  (with-or-without-marker marker
   (save-excursion
     (beginning-of-line)
     (and (looking-at org-complex-heading-regexp)
          (let* ((headline-raw (org-match-string-no-properties 4)))
            (cond ((string-match "^\\(.*\\)\s+\\[\\([0-9][0-9]%\\)\\]$" headline-raw)
                   (match-string 2 headline-raw))
                  (t
                   "")))))))

(defun mk-org-entry-is-project-p (&optional marker)
  (interactive)
  (with-or-without-marker marker
   (when (save-excursion
           (beginning-of-line)
           (or (org-entry-get (point) (mk-org-symbol-table 'name))
               (org-entry-get (point) (upcase (mk-org-symbol-table 'name)))))
     t)))

(defun mk-org-entry-is-in-project-p (&optional marker)
  (interactive)
  (with-or-without-marker marker
                          (when (save-excursion
                                  (beginning-of-line)
                                  (or (org-entry-get (point) (mk-org-symbol-table 'name) t)
                                      (org-entry-get (point) (upcase (mk-org-symbol-table 'name)) t)))
                            t)))

(defun mk-org-entry-alist (&optional marker)
  "Get config-alist from org entry properties at point."
  (interactive)
  (with-or-without-marker marker
   (save-excursion
     (org-back-to-heading t)
     (beginning-of-line)
     (unless (and (eq major-mode 'org-mode)
                  (looking-at org-complex-heading-regexp))
       (error "mk-org: buffer is not in org-mode or point is not a org heading"))
     (let ((entry-config '()))
       (dolist (prop (mk-org-symbol-table) entry-config)
         (let* ((sym (car prop))
               (propname (cdr prop))
               (value (read (or (org-entry-get (point) propname)
                                (org-entry-get (point) (upcase propname))
                                "nil"))))
           (when value
             (add-to-list 'entry-config `(,sym ,value)))))
       (let ((entry-config (append entry-config `((org-file ,(or (buffer-file-name (current-buffer))
                                                                 (buffer-file-name (buffer-base-buffer (current-buffer)))))
                                                  (org-headline ,(mk-org-entry-headline))
                                                  (org-level ,(- (mk-org-entry-level) (mk-org-entry-parent-level))))))
             (proj-parent (mk-org-entry-parent-name)))
         (when proj-parent
           (add-to-list 'entry-config `(parent ,proj-parent)))
         entry-config)))))

(defun mk-org-entry-define-project (&optional marker)
  (let* ((proj-name (mk-org-entry-name marker))
         (alist (mk-proj-eval-alist proj-name (mk-org-entry-alist marker))))
    (when alist
      (puthash proj-name alist mk-proj-list)
      ;;(message "Defined: %s" proj-name)
      alist)))

(defun mk-org-entry-undefine-project (&optional marker)
  (interactive)
  (with-or-without-marker marker
                          (save-excursion
                            (org-back-to-heading t)
                            (beginning-of-line)
                            (unless (and (eq major-mode 'org-mode)
                                         (looking-at org-complex-heading-regexp))
                              (error "mk-org: buffer is not in org-mode or point is not a org heading"))
                            (project-undef (mk-org-entry-name)))))









(defun mk-org-project-marker (&optional proj-name)
  "Get current or PROJ-NAME projects org entry as marker."
  (interactive)
  (unless proj-name
    (mk-proj-assert-proj)
    (setq proj-name mk-proj-name))
  (mk-org-assert-org proj-name)
  (let ((org-file (mk-proj-config-val 'org-file proj-name t))
        (org-headline (mk-proj-config-val 'org-headline proj-name t))
        (enable-local-variables :safe))
    (with-current-buffer (find-file-noselect org-file)
      (car (mk-org-map-entries
            :file (current-buffer)
            :match `(headline ,org-headline)
            :scope 'project-headline
            :function (lambda ()
                        (save-excursion
                          (org-back-to-heading t)
                          (beginning-of-line)
                          (mk-org-entry-marker)
                          )))))))

(defun mk-org-project-buffer-name (&optional proj-name)
  (let ((proj-name (if proj-name
                  proj-name
                (progn
                  (mk-proj-assert-proj)
                  mk-proj-name))))
    (concat "*mk-org: " (or (mk-proj-config-val 'parent proj-name) proj-name) "*")))


(defun mk-org-create-project-buffer (&optional proj-name bufname)
  (unless proj-name
    (mk-proj-assert-proj)
    (setq proj-name mk-proj-name))
  (mk-org-assert-org proj-name)
  (let* ((marker (mk-org-project-marker))
         (buffername (or bufname (mk-org-project-buffer-name proj-name)))
         (headline (mk-org-entry-headline marker))
         (org-show-hierarchy-above t)
         (org-show-following-heading nil)
         (org-show-siblings nil))
    (let (beg end buf)
      (car (mk-org-map-entries
            :match marker ;; `(eval (format org-complex-heading-regexp-format ,headline))
            :scope 'project-headline
            :function (lambda ()
                        (progn
                          (org-back-to-heading t)
                          (when (not (mk-org-entry-is-project-p))
                            (goto-char (mk-org-entry-parent-point)))
                          (setq beg (point))
                          (org-end-of-subtree t t)
                          (if (org-on-heading-p) (backward-char 1))
                          (setq end (point)
                                buf (or (get-buffer buffername)
                                        (make-indirect-buffer (current-buffer) buffername 'clone)))
                          (with-current-buffer buf
                            (narrow-to-region beg end)
                            (show-all)
                            (beginning-of-buffer)
                            (when (mk-org-entry-is-in-project-p) (org-cycle))
                            (widen)
                            (mk-org-reveal)
                            (goto-char (marker-position marker))
                            (set-frame-name (mk-org-entry-headline))
                            (current-buffer)
                            ))))))))

(defun mk-org-reveal ()
  (interactive)
  ;;(mk-org-assert-org)
  (mk-org-map-entries
   :file (current-buffer)
   :match (point)
   :scope 'project-tree
   :function (lambda ()
               (when (or (and (some (lambda (x) (string-equal (org-get-todo-state) x)) mk-org-todo-keywords)
                              (not (some (lambda (x) (string-equal (org-get-todo-state) x)) mk-org-ignore-todos)))
                         (mk-org-entry-is-project-p))
                 (message "Showing entry: %s" (mk-org-entry-name))
                 (org-show-context)
                 (when (and mk-proj-name
                            ;;(not (mk-org-entry-is-project-p))
                            (string-equal (mk-org-entry-name) mk-proj-name))
                   (org-show-entry))
                 ))))


(defun mk-org-get-project-buffer (&optional proj-name bufname)
  (or (get-buffer (or bufname (mk-org-project-buffer-name proj-name)))
      (mk-org-create-project-buffer proj-name bufname)))

(defun mk-org-kill-project-buffer (&optional proj-name bufname)
  (let ((buf (get-buffer (or bufname (mk-org-project-buffer-name proj-name)))))
    (when buf (kill-buffer buf))))

(defun project-org-buffer (&optional proj-name)
  "Open current projects org tree as indirect buffer."
  (interactive)
  (mk-org-assert-org proj-name t)
  (display-buffer (mk-org-get-project-buffer proj-name)))















;; (defun mk-org-yank-below (&optional arg adjust-subtree)
;;   (interactive "P")
;;   (let (p)
;;     (save-excursion
;;       (save-restriction
;;         (org-save-outline-visibility t
;;           (when (looking-at org-complex-heading-regexp)
;;             (show-all)
;;             (let ((level (org-outline-level))
;;                   (auto-adjust (or (org-entry-get (point) (cdr (assoc 'name (mk-org-symbol-table))))
;;                                    'todo)))
;;               (outline-next-heading)
;;               (while (and (> (org-outline-level) level)
;;                           (not (eobp)))
;;                 (outline-next-heading)
;;                 (when (eq auto-adjust 'todo)
;;                   (setq auto-adjust nil)))
;;               (outline-previous-heading)
;;               (org-end-of-subtree)
;;               (newline)
;;               (let ((org-yank-folded-subtrees t)
;;                     (org-yank-adjusted-subtrees nil))
;;                 (org-yank))
;;               (if (or adjust-subtree auto-adjust)
;;                   (progn
;;                     (outline-previous-heading)
;;                     (org-shiftmetaright))
;;                 (outline-previous-heading))
;;               (setq p (point)))))))
;;     p))

(defun mk-org-paste-below (&optional arg)
  (interactive "P")
  (save-excursion
    (save-restriction
      (org-save-outline-visibility t
        (when (looking-at org-complex-heading-regexp)
          (show-all)
          (let ((level (org-outline-level)))
            (org-end-of-subtree)
            (org-paste-subtree (+ level 1))))
        (point)))))

(defvar mk-org-add-todo-mode-map (make-sparse-keymap))

(defvar mk-org-add-todo-mode-hook nil)

(define-minor-mode mk-org-add-todo-mode nil nil " AddTodo" mk-org-add-todo-mode-map
  (run-hooks 'mk-org-add-todo-mode-hook))

(define-key mk-org-add-todo-mode-map "\C-c\C-c" 'mk-org-add-todo-finalize)
(define-key mk-org-add-todo-mode-map "\C-c\C-k" 'mk-org-add-todo-abort)

(defun mk-org-add-todo-finalize (&optional arg)
  (interactive "P")
  (setq arg (or arg local-prefix-arg))
  (mk-org-assert-org)
  (beginning-of-buffer)
  (outline-next-heading)
  (org-copy-subtree 1 t)
  (mk-org-map-entries
   :file (mk-org-get-project-buffer)
   :match `(headline ,(mk-proj-get-config-val 'org-headline))
   :scope 'project-headline
   :function (lambda ()
               (let* ((active (mk-org-entry-nearest-active))
                      (parent (mk-org-entry-parent-point))
                      (org-show-hierarchy-above t)
                      (org-show-following-heading nil)
                      (org-show-siblings nil))
                 (if arg
                     (when parent (goto-char parent))
                   (when active (goto-char active)))
                 (save-excursion
                   (goto-char (mk-org-paste-below arg))
                   (mk-org-reveal)
                   (mk-org-entry-define-project)
                   (when parent (goto-char parent))
                   (mk-org-reveal)))))
  (kill-buffer))

(defun mk-org-add-todo-abort ()
  (interactive)
  (kill-buffer))

(defun project-todo (&optional arg)
  "Pop up a buffer where the user can create a new org entry to be added to the current
project. Will add it to the nearest entry that has a `mk-org-active-todo-keyword' or to the
parent entry. Adding to the parent can be forced with a prefix argument.

Eventually this could be changed so that the prefix argument asks the user under
which entry (all of them not just the parent or nearest active) to add the todo.

See also `mk-org-entry-nearest-active'."
  (interactive "P")
  (mk-org-assert-org)
  (let* ((proj-b (current-buffer))
         (buf (get-buffer-create "*mk-proj: add todo*"))
         (window (display-buffer buf)))
    (select-window window)
    (set-window-dedicated-p window t)
    (org-mode)
    (mk-org-add-todo-mode 1)
    (with-current-buffer buf
      (set (make-local-variable 'local-prefix-arg) arg)
      (org-insert-heading)
      (org-todo "TODO"))))

(defun mk-org-project-todos (&optional proj-name)
  "Get all todo titles for a PROJ-NAME or the current project."
  (unless (or proj-name
              (condition-case nil (mk-org-assert-org) (error t)))
    (setq proj-name (or (mk-proj-get-config-val 'parent)
                        mk-proj-name)))
  (when (and proj-name
             (mk-proj-find-alist proj-name))
    (let ((todos '()))
      (maphash (lambda (title alist)
                 (when (string-match (concat "^" proj-name ":\\(.*\\)$") title)
                   (add-to-list 'todos title)))
               mk-proj-list)
      todos)))

;; (mk-org-project-todos "diplom")








(defun mk-org-find-save-location-marker (&optional proj-name config-alist)
  (unless proj-name
    (mk-proj-assert-proj)
    (setq proj-name mk-proj-name))
  (let ((enable-local-variables :safe))
    (cond ;; find parent headline
     ((and (mk-proj-get-config-val 'parent proj-name t)
           (mk-proj-get-config-val 'org-file proj-name t)
           (mk-proj-get-config-val 'org-headline proj-name t))
      (with-current-buffer (find-file-noselect (mk-proj-get-config-val 'org-file proj-name t))
        (save-excursion
          (if (condition-case nil (goto-char (org-find-exact-headline-in-buffer (mk-proj-get-config-val 'org-headline proj-name t))) (error nil))
              (point-marker)
            (error "mk-org: could not find a location to save project %s 1" proj-name)))))
     ;; find existing project headline
     ((and (mk-proj-get-config-val 'org-file proj-name t)
           (mk-proj-get-config-val 'org-headline proj-name t))
      (with-current-buffer (find-file-noselect (mk-proj-get-config-val 'org-file proj-name t))
        (save-excursion
          (if (condition-case nil (goto-char (org-find-exact-headline-in-buffer (mk-proj-get-config-val 'org-headline proj-name t))) (error nil))
              (point-marker)
            (error "mk-org: could not find a loctation to save project %s 2" proj-name)))))
     ;; find file in directory named after project
     ((condition-case nil (directory-files (expand-file-name mk-org-config-save-location)) (error nil))
      (with-current-buffer (find-file-noselect (concat (expand-file-name mk-org-config-save-location) proj-name ".org"))
        (save-excursion
          (goto-char (point-max))
          (point-marker))))
     ;; find headline (section) to save under in one big org file
     ((and (stringp mk-org-config-save-location)
           (stringp mk-org-config-save-section)
           (file-exists-p (expand-file-name mk-org-config-save-location)))
      (with-current-buffer (find-file-noselect (expand-file-name mk-org-config-save-location))
        (save-excursion
          (if (condition-case nil (goto-char (org-find-exact-headline-in-buffer mk-org-config-save-section)) (error nil))
              (point-marker)
            (error "mk-org: could not find a location to save project %s 3" proj-name)))))
     ;; find file in project basedir
     ((and mk-org-config-save-location
           (or (mk-proj-get-config-val 'basedir proj-name t)
               (cadr (assoc 'basedir config-alist))))
      (with-current-buffer (find-file-noselect (concat (or (mk-proj-get-config-val 'basedir proj-name t)
                                                           (cadr (assoc 'basedir config-alist))) "/" proj-name ".org"))
        (goto-char (point-max))
        (point-marker)))
     ;; no suitable location found
     (t (error "mk-org: could not find a location to save project %s 4" proj-name)))))







(defun mk-org-config-insert (proj-name config-alist &optional insert-undefined insert-internal headline)
  (interactive)
  (unless (eq major-mode 'org-mode)
    (error "mk-org: current buffer not in org-mode"))
  (unless proj-name
    (setq proj-name (or (cadr (assoc 'name config-alist)) headline "NewProject")))
  (save-excursion
    (save-restriction
      (org-insert-heading)
      (if headline
          (insert headline)
        (insert proj-name))
      (org-set-property "mkp_name" (prin1-to-string proj-name))
      (loop for k in (append mk-proj-required-vars mk-proj-optional-vars)
            if (not (or (eq (car k) 'name)
                        (or (mk-proj-any (lambda (j) (eq (car k) j)) mk-proj-internal-vars)
                            insert-internal)))
            do (when (or insert-undefined
                         (assoc (car k) config-alist))
                 (let* ((prop (cdr (assoc (car k) (mk-org-symbol-table))))
                        (val (cadr (assoc (car k) config-alist))))
                   (org-entry-delete (point) (upcase prop))
                   (org-set-property prop (prin1-to-string val)))))
      (point-marker))))

;; (setq mk-org-config-save-location "~/org/projects.org")
;; (mk-org-find-save-location-marker "cl-horde3d")

(defun mk-org-config-save (proj-name config-alist &optional headline)
  (unless headline
    (setq headline (or (cadr (assoc 'org-headline config-alist)) proj-name)))
  (when mk-org-config-save-location
    (let ((marker (mk-org-find-save-location-marker proj-name config-alist)))
      (with-marker
       marker
       (let* ((org-show-hierarchy-above t)
              (org-show-following-heading nil)
              (org-show-siblings nil)
              (mod (buffer-modified-p))
              (saved-marker (save-excursion
                              (cond ((looking-at (format org-complex-heading-regexp-format headline))
                                     (progn
                                       (org-set-property "mkp_name" (prin1-to-string proj-name))
                                       (loop for k in (append mk-proj-required-vars mk-proj-optional-vars)
                                             if (not (or (eq (car k) 'name)
                                                         (mk-proj-any (lambda (j) (eq (car k) j)) mk-proj-internal-vars)))
                                             do (when (assoc (car k) config-alist)
                                                  (let* ((prop (cdr (assoc (car k) (mk-org-symbol-table))))
                                                         (val (cadr (assoc (car k) config-alist))))
                                                    (org-entry-delete (point) (upcase prop))
                                                    (org-set-property prop (prin1-to-string val)))))
                                       (point-marker)))
                                    ((looking-at org-complex-heading-regexp)
                                     (org-end-of-subtree)
                                     (mk-org-config-insert proj-name config-alist nil nil headline))
                                    ((eq major-mode 'org-mode)
                                     (mk-org-config-insert proj-name config-alist nil nil headline))))))
         (save-buffer)
         (set-buffer-modified-p mod)
         (mk-org-entry-define-project saved-marker))))))

;;(mk-org-config-save "sauerbraten" (mk-proj-find-alist "sauerbraten" t))
;; (mk-org-find-save-location-marker "sauerbraten")
;;(cadr (assoc 'name (mk-proj-find-alist "cl-horde3d" t)))

(defun* mk-org-config-buffer (&optional (state :create) proj-name config-alist)
  (case state
    (:create
     (let* ((buf (get-buffer-create "*mk-proj: new project*"))
            (window (display-buffer buf))
            (config-alist (or config-alist (mk-proj-guess-alist)))
            (headline (and (eq major-mode 'org-mode)
                           (boundp 'org-complex-heading-regexp)
                           (looking-at org-complex-heading-regexp)
                           (mk-org-entry-headline))))
       (select-window window)
       (set-window-dedicated-p window t)
       (org-mode)
       (buffer-disable-undo)
       (mk-org-config-insert (or proj-name
                                 headline
                                 (cadr (assoc 'name config-alist))
                                 "NewProject") config-alist t)
       (goto-char 0)
       (end-of-line)
       (mk-proj-backend-create-project-mode 'org-mode)
       (buffer-enable-undo)))
    (:edit
     (let* ((buf (mk-org-get-project-buffer nil "*mk-proj: edit project*"))
            (window (display-buffer buf)))
       (select-window window)
       (set-window-dedicated-p window t)
       (if (re-search-forward ":PROPERTIES:" (save-excursion (org-end-of-subtree) (point)) t)
           (org-cycle))
       (buffer-disable-undo)
       (mk-proj-backend-edit-project-mode 'org-mode)
       (buffer-enable-undo)))
    (:finalize-create
     (save-excursion
       (let ((has-error t))
         (beginning-of-buffer)
         (outline-next-heading)
         (let* ((headline (mk-org-entry-headline))
                (proj-name (mk-org-entry-name))
                (config-alist (mk-proj-eval-alist proj-name (mk-org-entry-alist)))
                (marker (mk-org-find-save-location-marker proj-name config-alist)))
           (org-copy-subtree 1 nil)
           (when marker
             (with-current-buffer (marker-buffer marker)
               (goto-char (marker-position marker))
               (let* ((org-show-hierarchy-above t)
                      (org-show-following-heading nil)
                      (org-show-siblings nil))
                 (save-excursion
                   (org-back-to-heading t)
                   (let ((beg (point-at-bol))
                         (end (org-end-of-subtree)))
                     (delete-region beg end))))
               (org-yank)
               (when (condition-case nil (mk-org-entry-define-project) (error nil))
                 (progn
                   (print (concat "added: " headline))
                   (mk-org-reveal)
                   (setq has-error nil))))))
         (unless has-error
           (kill-buffer)))))
    (:finalize-edit
     (let ((marker (org-find-exact-headline-in-buffer (mk-proj-get-config-val 'org-headline))))
       (when marker
         (goto-char (marker-position marker))
         (unless (eq (condition-case nil (mk-org-entry-define-project) (error 'error))
                     'error)
           (save-buffer)
           (kill-buffer)))))))














;;(setq mk-proj-config-function 'mk-org-config-buffer)

(defun mk-org-read (cell)
  "Convert the string value of CELL to a number if appropriate.
Otherwise if cell looks like lisp (meaning it starts with a
\"(\" or a \"'\") then read it as lisp, otherwise return it
unmodified as a string.

Also return nil when string equals \"nil\", t when string equals \"t\"

This is taken almost directly from `org-babel-read'."
  (if (and (stringp cell) (not (equal cell "")))
      (or (org-babel-number-p cell)
          (if (or (equal "(" (substring cell 0 1))
                  (equal "'" (substring cell 0 1))
                  (equal "`" (substring cell 0 1))
                  (equal "nil" cell)
                  (equal "t" cell))
              (eval (read cell))
            (progn (set-text-properties 0 (length cell) nil cell) cell)))
    cell))


(defun mk-org-entry-last-clock-position ()
  (save-excursion
    (save-restriction
      (org-save-outline-visibility t
        (show-all)
        (re-search-forward org-clock-string (save-excursion (org-end-of-subtree)) t)))))

(defun mk-org-search-projects (&rest search-files)
  (unless (or search-files mk-org-project-search-files)
    (error "mk-org: could not find any projects, mk-org-project-search-files is not set"))
  (let ((buffer-with-projects nil)
        (pre-define-buffer-list (buffer-list))
        (continue-prevent-save t)
        (continue-prevent-restore t)
        (files (or search-files (mk-org-files-containing-projects)))
        (zeitgeist-prevent-send t))
    (when files
      (mk-org-map-entries
       :file files
       ;;:match "mk-project"
       :scope 'project-tree
       :close-files nil
       :function (lambda ()
                   (when (and (not (mk-org-entry-is-link-p))
                              (or (and (org-get-todo-state)
                                       (and (some (lambda (x) (string-equal (org-get-todo-state) x)) mk-org-todo-keywords)
                                            (not (some (lambda (x) (string-equal (org-get-todo-state) x)) mk-org-ignore-todos))))
                                  (and (mk-org-entry-is-project-p)
                                       (or (not (org-get-todo-state))
                                           (and (org-get-todo-state)
                                                (some (lambda (x) (string-equal (org-get-todo-state) x)) mk-org-todo-keywords)
                                                (not (some (lambda (x) (string-equal (org-get-todo-state) x)) mk-org-ignore-todos)))))))
                     (mk-org-entry-define-project)
                     (unless (eq (last buffer-with-projects) (current-buffer))
                       (add-to-list 'buffer-with-projects (current-buffer))))))
      (dolist (f files)
        (when (file-exists-p f)
          (let ((buf (find-buffer-visiting f)))
            (when (and buf
                       (not (buffer-modified-p buf))
                       (not (some (lambda (b) (eq b buf)) buffer-with-projects))
                       (not (some (lambda (b) (eq b buf)) pre-define-buffer-list)))
              (kill-buffer buf))))))
    nil))

(defun mk-org-undefine-entries ()
  (interactive)
  (mk-org-map-entries
   :file (mk-org-files-containing-projects)
   :scope 'project-tree
   :function (lambda ()
               (when (not (mk-org-entry-is-project-p))
                 (project-undef entry-name)))))

(defun mk-org-clock-cut ()
  (save-excursion
    (org-save-outline-visibility t
      (when (and (looking-at org-complex-heading-regexp)
                 (mk-org-entry-last-clock-position))
        (show-all)
        (goto-char (mk-org-entry-last-clock-position))
        (when (looking-at (concat "\\s-*" org-clock-string))
          (kill-region (point-at-bol) (point-at-bol 2)))))))

(defun mk-org-clock-yank ()
  (save-excursion
    (org-save-outline-visibility t
      (when (and (looking-at org-complex-heading-regexp)
                 (string-match org-clock-string (car kill-ring)))
        (show-all)
        (org-clock-find-position nil)
        (next-line)
        (while (looking-at (concat "\\s-*" org-clock-string))
          (next-line))
        (beginning-of-line)
        (yank)
        (indent-according-to-mode)))))

(defun mk-org-clock-from-parent-to-todo ()
  (save-excursion
    (let ((todo-name (mk-org-entry-name)))
      (when (mk-org-entry-parent-point)
        (goto-char (mk-org-entry-parent-point))
        (when (and org-clock-marker
                   (string-equal (mk-org-entry-headline org-clock-marker)
                                 (mk-org-entry-headline))
                   (y-or-n-p "Move clocked time from %s to %s?" (mk-org-entry-name org-clock-marker) todo-name))
          (org-clock-out)
          (mk-org-clock-cut)
          (org-clock-in)))
      (mk-org-clock-yank))))

(defun project-clock-in (&optional proj-name)
  (interactive)
  (unless proj-name
    (mk-proj-assert-proj)
    (setq proj-name mk-proj-name))
  (mk-org-assert-org proj-name)
  (let ((zeitgeist-prevent-send t)
        (continue-prevent-save t))
    (mk-org-map-entries
     :file (mk-proj-get-config-val 'org-file proj-name)
     :match `(headline ,(mk-proj-get-config-val 'org-headline proj-name))
     :scope 'project-headline
     :function (lambda ()
                 (org-clock-in)
                 ))))

(defun project-clock-out (&optional proj-name)
  (interactive)
  (let ((continue-prevent-save t))
    (unless proj-name
      (mk-proj-assert-proj)
      (setq proj-name mk-proj-name))
    (when (org-clocking-p)
      (mk-org-assert-org proj-name)
      (org-clock-out))))

(provide 'mk-project-orgmode)
