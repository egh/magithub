;;; magithub.el --- Magit interfaces for GitHub  -*- lexical-binding: t; -*-

;; Copyright (C) 2016-2017  Sean Allred

;; Author: Sean Allred <code@seanallred.com>
;; Keywords: git, tools, vc
;; Homepage: https://github.com/vermiculus/magithub
;; Package-Requires: ((emacs "25") (magit "2.8.0") (s "20170428.1026") (ghub+ "0.1.4"))
;; Package-Version: 0.1.3

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Magithub is a Magit-based interface to GitHub.
;;
;; Integrated into Magit workflows, Magithub allows easy GitHub
;; repository management.  Supported actions include:
;;
;;  - pushing brand-new local repositories up to GitHub
;;  - creating forks of existing repositories
;;  - submitting pull requests upstream
;;  - viewing and creating issues
;;  - seeing status checks
;;
;; all from the `magit-status' buffer.
;;
;; Press `H' in the status buffer to get started -- happy hacking!

;;; Code:

(require 'magit)
(require 'magit-process)
(require 'magit-popup)
(require 'cl-lib)
(require 's)
(require 'dash)

(require 'magithub-core)
(require 'magithub-issue)
(require 'magithub-cache)
(require 'magithub-ci)
(require 'magithub-proxy)
(require 'magithub-issue-status)
(require 'magithub-issue-post)
(require 'magithub-issue-tricks)
(require 'magithub-orgs)

(magit-define-popup magithub-dispatch-popup
  "Popup console for dispatching other Magithub popups."
  'magithub-commands
  :actions '("Actions"
             (?H "Browse on GitHub" magithub-browse)
             (?c "Create" magithub-create)
             (?f "Fork" magithub-fork)
             (?i "Issues" magithub-issue-new)
             (?p "Submit a pull request" magithub-pull-request-new)
             (?x "Use a proxy repository for issues/PRs" magithub-proxy-set)
             (?O "Toggle online/offline" magithub-toggle-offline)
             "Meta"
             (?` "Toggle Magithub-Status integration" magithub-enabled-toggle)
             (?g "Refresh all GitHub data" magithub-refresh)
             (?& "Request a feature or report a bug" magithub--meta-new-issue)
             (?h "Ask for help on Gitter" magithub--meta-help)))

(magit-define-popup-action 'magit-dispatch-popup
  ?H "Magithub" #'magithub-dispatch-popup ?!)
(define-key magit-status-mode-map
  "H" #'magithub-dispatch-popup)

(defun magithub-browse ()
  "Open the repository in your browser."
  (interactive)
  (unless (magithub-github-repository-p)
    (user-error "Not a GitHub repository"))
  (let-alist (magithub-source-repo)
    (unless (stringp .html_url)
      (user-error "No GitHub repository to visit"))
    (browse-url .html_url)))

(defvar magithub-after-create-messages
  '("Don't be shy!"
    "Don't let your dreams be dreams!")
  "One of these messages will be displayed after you create a
GitHub repository.")

(defvar magithub-preferred-remote-method 'ssh_url
  "Preferred method when cloning or adding remotes.
One of the following:

  `clone_url' (https://github.com/octocat/Hello-World.git)
  `git_url'   (git:github.com/octocat/Hello-World.git)
  `ssh_url'   (git@github.com:octocat/Hello-World.git)")

(defun magithub-create (repo &optional org)
  "Create REPO on GitHub.

If ORG is non-nil, it is an organization object under which to
create the new repository.  You must be a member of this
organization."
  (interactive (if (or (not (magit-toplevel)) (magithub-github-repository-p))
                   (list nil nil)
                 (let* ((ghub-username (ghub--username)) ;performance
                        (account (magithub--read-user-or-org))
                        (priv (yes-or-no-p "Will this be a private repository? "))
                        (reponame (magithub--read-repo-name account))
                        (desc (read-string "Description (optional): ")))
                   (list
                    `((name . ,reponame)
                      (private . ,priv)
                      (description . ,desc))
                    (unless (string= ghub-username account)
                      `((login . ,account)))))))
  (when (magithub-github-repository-p)
    (error "Already in a GitHub repository"))
  (if (not (magit-toplevel))
      (when (y-or-n-p "Not inside a Git repository; initialize one here? ")
        (magit-init default-directory)
        (call-interactively #'magithub-create))
    (with-temp-message "Creating repository on GitHub..."
      (setq repo
            (if org
                (ghubp-post-orgs-org-repos org repo)
              (ghubp-post-user-repos repo))))
    (magithub--random-message "Creating repository on GitHub...done!")
    (magit-status-internal default-directory)
    (magit-remote-add "origin" (alist-get magithub-preferred-remote-method repo))
    (magit-refresh)
    (when (magit-rev-verify "HEAD")
      (magit-push-popup))))

(defun magithub--read-user-or-org ()
  "Prompt for an account with completion.

Candidates will include the current user and all organizations,
public and private, of which they're a part.  If there is only
one candidate (i.e., no organizations), the single candidate will
be returned without prompting the user."
  (let ((user (ghub--username))
        (orgs (magithub-get-in-all '(login)
                (magithub-orgs-list)))
        candidates)
    (setq candidates orgs)
    (when user (push user candidates))
    (cl-case (length candidates)
      (0 (user-error "No accounts found"))
      (1 (car candidates))
      (t (completing-read "Account: " candidates nil t)))))

(defun magithub--read-repo-name (for-user)
  (let* ((prompt (format "Repository name: %s/" for-user))
         (dirnam (file-name-nondirectory (substring default-directory 0 -1)))
         (valid-regexp (rx bos (+ (any alnum "." "-" "_")) eos))
         ret)
    ;; This is not very clever, but it gets the job done.  I'd like to
    ;; either have instant feedback on what's valid or not allow users
    ;; to enter invalid names at all.  Could code from Ivy be used?
    (while (not (s-matches-p valid-regexp (setq ret (read-string prompt nil nil dirnam))))
      (message "invalid name")
      (sit-for 1))
    ret))

(defun magithub--random-message (&optional prefix)
  (let ((msg (nth (random (length magithub-after-create-messages))
                  magithub-after-create-messages)))
    (if prefix (format "%s  %s" prefix msg) msg)))

(defun magithub-fork ()
  "Fork 'origin' on GitHub."
  (interactive)
  (unless (magithub-github-repository-p)
    (user-error "Not a GitHub repository"))
  (let* ((repo (magithub-source-repo))
         (fork (with-temp-message "Forking repository on GitHub..."
                 (ghubp-post-repos-owner-repo-forks repo))))
    (when (y-or-n-p "Create a spinoff branch? ")
      (call-interactively #'magit-branch-spinoff))
    (magithub--random-message
     (let-alist repo (format "%s/%s forked!" .owner.login .name)))
    (let-alist fork
      (when (y-or-n-p (format "Add %s as a remote in this repository? " .owner.login))
        (magit-remote-add .owner.login (alist-get magithub-preferred-remote-method fork))
        (magit-set .owner.login "branch" (magit-get-current-branch) "pushRemote")))
    (let-alist repo
      (when (y-or-n-p (format "Set upstream to %s? " .owner.login))
        (call-interactively #'magit-set-branch*merge/remote)))))

(defun magithub-clone--get-repo ()
  "Prompt for a user and a repository.
Returns a sparse repository object."
  (let ((user (ghub--username))
        (repo-regexp  (rx bos (group (+ (not (any " "))))
                          "/" (group (+ (not (any " ")))) eos))
        repo)
    (while (not (and repo (string-match repo-regexp repo)))
      (setq repo (read-from-minibuffer
                  (concat
                   "Clone GitHub repository "
                   (if repo "(format is \"user/repo\"; C-g to quit)" "(user/repo)")
                   ": ")
                  (when user (concat user "/")))))
    `((owner (login . ,(match-string 1 repo)))
      (name . ,(match-string 2 repo)))))

(defcustom magithub-clone-default-directory nil
  "Default directory to clone to when using `magithub-clone'.
When nil, the current directory at invocation is used."
  :type 'directory
  :group 'magithub)

(defun magithub-clone (repo dir)
  "Clone REPO.
Banned inside existing GitHub repositories if
`magithub-clone-default-directory' is nil.

See also `magithub-preferred-remote-method'."
  (interactive (if (and (not magithub-clone-default-directory)
                        (magithub-github-repository-p))
                   (user-error "Already in a GitHub repo")
                 (let ((repo (magithub-clone--get-repo)))
                   (condition-case _
                       (let* ((repo (ghubp-get-repos-owner-repo repo))
                              (dirname (read-directory-name
                                        "Destination: "
                                        magithub-clone-default-directory
                                        (alist-get 'name repo))))
                         (list repo dirname))
                     (ghub-404 (let-alist repo
                                 (user-error "Repository %s/%s does not exist"
                                             .owner.login .name)))))))
  ;; Argument validation
  (unless (called-interactively-p 'any)
    (condition-case _
        (setq repo (ghubp-get-repos-owner-repo repo))
      (ghub-404
       (let-alist repo
         (user-error "Repository %s/%s does not exist"
                     .owner.login .name)))))
  (unless (file-writable-p dir)
    (user-error "%s does not exist or is not writable" dir))

  (let-alist repo
    (when (y-or-n-p (format "Clone %s to %s? " .full_name dir))
      (let ((default-directory dir)
            (magit-clone-set-remote.pushDefault t)
            set-upstream set-proxy)

        (setq set-upstream
              (and .fork (y-or-n-p (format (concat "This repository appears to be a fork of %s; "
                                                   "set upstream to that remote?")
                                           .parent.full_name)))
              set-proxy
              (and set-upstream (y-or-n-p "Use upstream as a proxy for issues, etc.? ")))

        (condition-case _
            (progn
              (mkdir dir t)
              (magit-clone (alist-get magithub-preferred-remote-method repo) dir)
              (while (process-live-p magit-this-process)
                (magit-process-buffer)
                (message "Waiting for clone to finish...")
                (sit-for 1))
              (when set-upstream
                (let ((upstream "upstream"))
                  (when set-proxy (magithub-proxy-set upstream))
                  (magit-remote-add upstream (alist-get magithub-preferred-remote-method .parent))
                  (magit-set-branch*merge/remote (magit-get-current-branch) upstream)))))))))

(let-alist (ghubp-get-repos-owner-repo '((owner (login . "vermiculus")) (name . "ghub")))
  .parent)

(defun magithub-clone--finished (user repo dir)
  "After finishing the clone, allow the user to jump to their new repo."
  (when (y-or-n-p (format "%s/%s has finished cloning to %s.  Open? " user repo dir))
    (magit-status-internal (s-chop-suffix "/" dir))))

(defun magithub-feature-autoinject (feature)
  "Configure FEATURE to recommended settings.
If FEATURE is `all' or t, all known features will be loaded.

Features:

- `pull-request-merge'
  (`magithub-pull-request-merge' inserted into `magit-am-popup')

- `pull-request-checkout'
  (`magithub-pull-request-checkout' inserted into `magit-branch-popup')"
  (if (memq feature '(t all))
      (mapc #'magithub-feature-autoinject magithub-feature-list)
    (cl-case feature

      (pull-request-merge
       (magit-define-popup-action 'magit-am-popup
         ?P "Apply patches from pull request" #'magithub-pull-request-merge))

      (pull-request-checkout
       (magit-define-popup-action 'magit-branch-popup
         ?P "Checkout pull request" #'magithub-pull-request-checkout))

      (t (user-error "unknown feature %S" feature)))
    (add-to-list 'magithub-features (cons feature t))))

(defun magithub-visit-thing ()
  (interactive)
  (let-alist (magithub-thing-at-point 'all)
    (cond (.label (magithub-label-browse .label))
          (.issue (magithub-issue-browse .issue))
          (.pull-request (magithub-pull-browse .pull-request))
          (t (message "Nothing recognizable at point")))))

(provide 'magithub)
;;; magithub.el ends here
