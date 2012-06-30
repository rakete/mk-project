;;; mk-project-helm.el --- Emacs helm integration for mk-project

;; Copyright (C) 2008  Andreas Raster <lazor at affenbande dot org>
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

(require 'helm-config)
(require 'helm-locate)
(require 'helm-buffers)

(defvar helm-c-source-mk-project-projects
  '((name . "Mk-Project projects")
    (candidates . (lambda ()
                    (let ((ps '()))
                      (maphash (lambda (k p)
                                 (progn
                                   ;;(print (assoc 'org-header p))
                                   (let ((h (cadr (assoc 'org-header p))))
                                     (if h
                                         (setq ps (cons `(,h ,k) ps))
                                       (setq ps (cons k ps))))
                                   ))
                               mk-proj-list)
                      ps)))
    (action . (lambda (entry)
                (if (listp entry)
                    (mk-proj-load (car entry))
                  (mk-proj-load entry)))))
  "All configured mk-project projects.")


(defvar helm-c-source-mk-project-files
  `((name . "Mk-Project files")
    (disable-shortcuts)
    (candidates . (lambda ()
                    (condition-case nil
                        (mapcar (lambda (s)
                                  (replace-regexp-in-string "/\\./" "/" (concat (file-name-as-directory mk-proj-basedir) s)))
                                (if mk-proj-patterns-are-regex
                                    (mk-proj-fib-matches mk-proj-src-patterns)
                                  (mk-proj-fib-matches nil))) (error nil))))
    (candidate-number-limit . 9999)
    (volatile)
    (keymap . ,helm-generic-files-map)
    (help-message . helm-generic-file-help-message)
    (mode-line . helm-generic-file-mode-line-string)
    (match helm-c-match-on-file-name)
    (type . file)
    ;;(delayed)
    )
  "All files of the currently active project.")

(defvar helm-c-source-mk-project-open-buffers
  `((name . "Mk-Project buffers")
    (candidates . (lambda () (mapcar 'buffer-name (condition-case nil
                                                      (remove-if (lambda (buf) (string-match "\*[^\*]\*" (buffer-name buf))) (mk-proj-buffers))
                                                    (error nil)))))
    (type . buffer)
    (match helm-c-buffer-match-major-mode)
    (persistent-action . helm-c-buffers-list-persistent-action)
    (keymap . ,helm-c-buffer-map)
    (volatile)
    (mode-line . helm-buffer-mode-line-string)
    (persistent-help
     . "Show this buffer / C-u \\[helm-execute-persistent-action]: Kill this buffer"))
  "All buffers of the currently active project.")

(defvar helm-c-source-mk-project-friendly-files
  `((name . "Mk-Project friendly files")
    (candidates . (lambda ()
                    (condition-case nil (mk-proj-fib-friend-matches) (error nil))))
    (candidate-number-limit . 9999)
    (volatile)
    (keymap . ,helm-generic-files-map)
    (help-message . helm-generic-file-help-message)
    (mode-line . helm-generic-file-mode-line-string)
    (match helm-c-match-on-file-name
           helm-c-match-on-directory-name)
    (type . file)
    (delayed))
  "All files of projects which are friends of this project.")

(defvar helm-c-source-mk-project-open-friendly-buffers
  `((name . "Mk-Project friendly buffers")
    (candidates . (lambda () (mapcar 'buffer-name (condition-case nil
                                                      (mk-proj-friendly-buffers t)
                                                    (error nil)))))
    (type . buffer)
    (match helm-c-buffer-match-major-mode)
    (persistent-action . helm-c-buffers-list-persistent-action)
    (keymap . ,helm-c-buffer-map)
    (volatile)
    (mode-line . helm-buffer-mode-line-string)
    (persistent-help
     . "Show this buffer / C-u \\[helm-execute-persistent-action]: Kill this buffer"))
  "All friendly buffers of the currently active project." )

(defvar helm-c-source-mk-project-open-special-buffers
  `((name . "Mk-Project special buffers")
    (candidates . (lambda () (mapcar 'buffer-name (condition-case nil
                                                      (mk-proj-special-buffers)
                                                    (error nil)))))
    (type . buffer)
    (match helm-c-buffer-match-major-mode)
    (persistent-action . helm-c-buffers-list-persistent-action)
    (keymap . ,helm-c-buffer-map)
    (volatile)
    (mode-line . helm-buffer-mode-line-string)
    (persistent-help
     . "Show this buffer / C-u \\[helm-execute-persistent-action]: Kill this buffer"))
  "All special buffers of the currently active project." )


(defun helm-mkproject ()
  (interactive)
  (helm :sources '(helm-c-source-mk-project-open-buffers
                   helm-c-source-mk-project-open-friendly-buffers
                   helm-c-source-mk-project-open-special-buffers
                   helm-c-source-mk-project-files
                   helm-c-source-mk-project-friendly-files)
        :buffer "*helm mk-project*"
        :history 'helm-file-name-history))
