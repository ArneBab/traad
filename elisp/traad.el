;;; traad.el --- emacs interface to the traad xmlrpc refactoring server.
;;
;; Author: Austin Bingham <austin.bingham@gmail.com>
;; Version: 0.1
;; URL: https://github.com/abingham/traad
;;
;; This file is not part of GNU Emacs.
;;
;; Copyright (c) 2012 Austin Bingham
;;
;;; Commentary:
;;
;; Description:
;;
;; traad is an xmlrpc server built around the rope refactoring library. This
;; file provides an API for talking to that server - and thus to rope - from
;; emacs lisp. Or, put another way, it's another way to use rope from emacs.
;;
;; For more details, see the project page at
;; https://github.com/abingham/traad.
;;
;; Installation:
;;
;; Make sure xml-rpc.el is in your load path. Check the emacswiki for more info:
;;
;;    http://www.emacswiki.org/emacs/XmlRpc
;;
;; Copy traad.el to some location in your emacs load path. Then add
;; "(require 'traad)" to your emacs initialization (.emacs,
;; init.el, or something). 
;; 
;; Example config:
;; 
;;   (require 'traad)
;;
;;; License:
;;
;; Permission is hereby granted, free of charge, to any person
;; obtaining a copy of this software and associated documentation
;; files (the "Software"), to deal in the Software without
;; restriction, including without limitation the rights to use, copy,
;; modify, merge, publish, distribute, sublicense, and/or sell copies
;; of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:
;;
;; The above copyright notice and this permission notice shall be
;; included in all copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
;; NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
;; BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
;; ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
;; CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Code:

(require 'xml-rpc)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; user variables

(defcustom traad-host "127.0.0.1"
  "The host on which the traad server is running."
  :type '(string)
  :group 'traad)

(defcustom traad-port 6942
  "The port on which the traad server is listening."
  :type '(integer)
  :group 'traad)

(defcustom traad-server-program "traad"
  "The name of the traad server program. This may be a string or a list. For python3 projects this commonly needs to be set to 'traad3'."
  :type '(string)
  :group 'traad)

(defcustom traad-auto-revert nil
  "Whether proximal buffers should be automatically reverted \
after successful refactorings."
  :type '(boolean)
  :group 'traad)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; open-close 

(defun traad-open (directory)
  "Open a traad project on the files in DIRECTORY."
  (interactive
   (list
    (read-directory-name "Directory: ")))
  (traad-close)
  (let ((program+args
         (append (if (listp traad-server-program)
                     traad-server-program
                   (list traad-server-program))
                 (list "-V" directory)))
        (default-directory "~/"))
    (apply #'start-process "traad-server" "*traad-server*" program+args)))

(defun traad-close ()
  "Close the current traad project, if any."
  (interactive)
  (if (traad-running?)
      (delete-process "traad-server")))

(defun traad-running? ()
  "Determine if a traad server is running."
  (interactive)
  (if (get-process "traad-server") 't nil))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; resource access

(defun traad-get-all-resources ()
  "Get all resources in a project."
  (traad-call 'get_all_resources))

(defun traad-get-children (path)
  "Get all child resources for PATH. PATH may be absolute or relative to
the project root."
  (traad-call 'get_children path))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; history

(defun traad-undo ()
  "Undo last operation."
  (interactive)
  (traad-call 'undo)
  (traad-maybe-revert))

(defun traad-redo ()
  "Redo last undone operation."
  (interactive)
  (traad-call 'redo)
  (traad-maybe-revert))

(defun traad-history-core (func buffname)
  (let ((history (traad-call func))
	(buff (get-buffer-create buffname)))
    (erase-buffer buff)
    (switch-to-buffer buff)
    ; TODO: These should probably be numbered, since that's what we'll
    ; communicate back to the server for (undo <history index>)
    (if history (insert (pp-to-string history)))))

(defun traad-undo-history ()
  "Get a list of undo-able changes."
  (interactive)
  (traad-history-core 'undo_history "*traad-undo-history*"))

(defun traad-redo-history ()
  "Get a list of redo-able changes."
  (interactive)
  (traad-history-core 'redo_history "*traad-redo-history*"))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; renaming support

(defun traad-rename-core (new-name path &optional offset)
  "Rename PATH (or the subelement at OFFSET) to NEW-NAME."
  (if offset
      (traad-call 'rename new-name path offset)
      (traad-call 'rename new-name path))
  (traad-maybe-revert))

(defun traad-rename-current-file (new-name)
  "Rename the current file/module."
  (interactive
   (list
    (read-string "New file name: ")))
  (traad-rename-core new-name buffer-file-name)
  (let ((dirname (file-name-directory buffer-file-name))
	(extension (file-name-extension buffer-file-name))
	(old-buff (current-buffer)))
    (switch-to-buffer 
     (find-file
      (expand-file-name 
       (concat new-name "." extension) 
       dirname)))
    (kill-buffer old-buff)))

(defun traad-rename (new-name)
  "Rename the object at the current location."
  (interactive
   (list
    (read-string "New name: ")))
  (traad-rename-core new-name buffer-file-name (point)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; extraction support

(defun traad-extract-core (type name begin end)
  (traad-call type 
	      name 
	      (buffer-file-name)
	      begin
	      end)
  (traad-maybe-revert))

(defun traad-extract-method (name begin end)
  "Extract the currently selected region to a new method."
  (interactive "sMethod name: \nr")
  (traad-extract-core 'extract_method name begin end))

(defun traad-extract-variable (name begin end)
  "Extract the currently selected region to a new variable."
  (interactive "sVariable name: \nr")
  (traad-extract-core 'extract_variable name begin end))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; code assist

(defun traad-code-assist (pos)
  "Get possible completions at POS in current buffer. This returns a list of \
lists: ((name, documentation, scope, type), . . .)."
  (interactive "d")
  (traad-call 'code_assist
	      (buffer-substring-no-properties (point-min) (point-max))
	      pos
	      (buffer-file-name)))
  
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; low-level support

(defun traad-call (func &rest args)
  "Make an XMLRPC to FUNC with ARGS on the traad server."
  (apply
   #'xml-rpc-method-call
   (concat
    "http://" traad-host ":"
    (number-to-string traad-port))
   func args))

(defun traad-maybe-revert ()
  "If configured, revert the current buffer without asking."
  (if traad-auto-revert (revert-buffer nil 't)))

; TODO: undo/redo...history support
; TODO: invalidation support?
; TODO: Improved error reporting when server can't be contacted. The
; traad-call function should probably say something friendlier like "No
; traad server found. Have you called traad-open?"

(provide 'traad)
