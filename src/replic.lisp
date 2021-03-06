(defpackage replic
  (:use :cl)
  (:shadow #:set)
  (:import-from :alexandria
                :curry
                :assoc-value)
  (:import-from :replic.utils
                :truthy
                :falsy)
  (:export :main
           :confirm
           :repl
           :functions-to-commands
           :load-init
           :help
           :set
           :reload
           :version
           ;; settings
           :*custom-complete*
           :*help-preamble*
           :*help-postamble*
           :*prompt*
           :*prompt-prefix*
           :*confirm-exit*
           :*history*
           :*write-history*
           :*verbose*
           :*version*))

;; The package to be used in the user's init files.
(defpackage replic.user
  (:use :cl))

(in-package :replic)

;; (defvar *version* (asdf/driver:read-file-form "version.lisp-expr"))
;; fails when loaded from another lib.
(defvar *version* 0.10)

(defun version ()
  *version*)

(defparameter *init-file* #p"~/.replic.lisp"
              "The init file to load at startup, containing any lisp
              code to be `load`ed. It exports variables and functions
              to be used at the CLI, and how to complete them and
              their arguments.")

;;
;; Prompt
;;
(defvar *prompt* "> "
  "The base prompt, usually the application name. Can contain ansi colours (use cl-ansi-text:green etc). The full prompt is built with (prompt).")

(defvar *prompt-prefix* nil
  "A prefix, supposed to change during the application (current directory, venv,...)")

(defvar *confirm-exit* t
  "If true (the default), ask for confirmation when you try to exit
  the program (with a C-d). The `quit` command doesn't ask for
  confirmation.")

;;
;; History
;;
(defvar *history* t
  "If true (the default), read and write the history.")

(defvar *write-history* t
  "If true (the default), write the commands in the history.")

;;
;; Colorize words on output.
;;
(defparameter *colors-functions* '(
                                   (:blue . cl-ansi-text:blue)
                                   (:green . cl-ansi-text:green)
                                   (:yellow . cl-ansi-text:yellow)
                                   (:cyan . cl-ansi-text:cyan)
                                   (:magenta . cl-ansi-text:magenta)
                                   (:red . cl-ansi-text:red))
  "Alist of a symbol - its function to colorize text. From cl-ansi-text.")
;;
;; Examples
;;

(defparameter *verbose* nil "Example setting.")

(defparameter *help-preamble* ""
  "Text to display before the list of commands and variables.")

(defparameter *help-postamble* "For details, see the help of each command or variable."
  "Text to display after the list of commands and variables.")

;; shadow works with build but not on Slime ??
(defun set (&optional var arg)
  "Change a variable or see values.

   With no arguments, see what parameters are available. With one argument, see the value of this variable.
   With a second argument, set it.

   \"yes\", \"true\" or \"t\" and \"no\", \"false\" or \"nil\"  denote true and false, respectively.

   See base.lisp for what this command takes as completion candidates (in short, all variables)."
  ;; xxx: input validation.

  ;; print all current paramaters.
  (when (and (null var)
             (null arg))
    (format t "Available parameters:~{ ~a~#[~;, and ~:;,~]~}.~&" (replic.completion:variables)))

  (when (and var
             (null arg))
    (format t "~a is: ~a~&" var (symbol-value (replic.completion:get-symbol var))))

  (when (and var arg)
    (setf (symbol-value (replic.completion:get-symbol var))
          (cond
            ((truthy arg)
             t)
            ((falsy arg)
             nil)
            (t
             (handler-case
                 (parse-integer arg)
               (error ()
                 arg)))))
    (format t "~a set to ~a~&" var arg)))

(defun common-prefix (items)
  ;; tmp waiting for cl-str 0.5 in Quicklisp february.
  (when items (subseq
               (car items)
               0
               (apply
                #'min
                (mapcar
                 #'(lambda (i) (or (mismatch (car items) i) (length i)))
                 (cdr items))))))


(defun complete-from-list (text list)
  "Select all commands from `list' that start with `text'."
  (let ((els (remove-if-not (curry #'str:starts-with? text)
                            list)))
    (if (cdr els)
        (cons (common-prefix els) els)
        els)))

(defun complete-args (text line)
  "Completion for arguments."
  (let* ((verb (first (str:words line)))
         (candidates (replic.completion:candidates verb)))
    (when candidates
      (complete-from-list text candidates))))

(defun custom-complete (text start end &optional (line-buffer rl:*line-buffer*))
  "Complete a symbol.

  `text` is the partially entered word. start and end are the position on `rl:*line-buffer*'.

  When the cursor is at the beginning of the prompt, complete from commands.
  When `text` starts with `*`, complete from variables.

  line-buffer: as argument for direct call in tests.
  "
  (declare (ignore end))
  (if (zerop start)
      (if (str:starts-with? "*" text)
          (complete-from-list text (replic.completion:variables))
          (complete-from-list text (replic.completion:commands)))
      (complete-args text line-buffer)))

(defparameter *custom-complete* #'custom-complete
  "Completion function.

   When the cursor is at the beginning of the prompt, the default
   function tries to complete a command or a variable (starting with
   `*`.

   Afterwards, it reads how to complete the function/variable
   arguments from `complete-args`.")


(defun functions-to-commands (package &key exclude)
  (declare (ignore package exclude))
  (error "deprecated: use replic.completions:functions-to-command."))

(defvar *prompt-exit* "Do you want to quit ?")

(defun confirm (&key (prompt *prompt-exit*) (show-prompt-p *confirm-exit*))
  "Ask confirmation. No input means yes.
   Change the prompt string with :prompt. If :show-prompt-p evaluates
   to true, skip the prompt and confirm."
  (if show-prompt-p
      (member (rl:readline :prompt (format nil (str:concat "~%" prompt " [Y]/n : ")))
              '("y" "Y" "")
              :test 'equal)
      t))


(defun prompt ()
  "Return the prompt to display."
  (str:concat *prompt-prefix* *prompt*))

(defun repl ()
  (in-package :replic) ;; needed for executable

  ;; register completion
  (rl:register-function :complete #'custom-complete)

  ;; read history.
  (rl:read-history "/tmp/readline_history")

  (handler-case
      (do ((i 0 (1+ i))
           (text "")
           (verb "")
           (function nil)
           (variable nil)
           (args ""))
          ((string= "quit" (str:trim text)))

        (handler-case
            (setf text
                  (rl:readline :prompt (prompt)
                               :add-history t))
          (#+sbcl sb-sys:interactive-interrupt ()
                  (progn
                    (when (confirm)
                      (uiop:quit)))))

        (if (string= text "NIL")
            ;; that's a C-d, a blank input is just "".
            (when (confirm)
              (uiop:quit)))

        (unless (str:blank? text)
          (setf verb (first (str:words text)))
          (setf function (if (replic.completion:is-function verb)
                             ;; might do better than this or.
                             (replic.completion:get-function verb)))
          (setf variable (if (replic.completion:is-variable verb)
                             (replic.completion:get-variable verb)))
          (setf args (rest (str:words text)))


          (if (and verb function)
              (handler-case
                  ;; Call the function.
                  (apply function args)
                (#+sbcl sb-sys:interactive-interrupt (c)
                        (declare (ignore c))
                        (terpri))
                (error (c) (format t "Error: ~a~&" c)))

              (if variable
                  (format t "~a~&" (symbol-value variable))
                  (format t "No command or variable bound to ~a~&" verb)))

          (finish-output)

          (when (and *history*
                     *write-history*)
            (rl:write-history "/tmp/readline_history"))
          ))

    (error (c)
      (format t "~&Unknown error: ~&~a~&" c)))
  )

(defun format-error (msg)
  "Print this message in red on error output."
  (format *error-output* (cl-ansi-text:red msg)))

(defun handle-parser-error (c)
  (format t "Bad command line argument: ~a~&" (opts:option c))
  (opts:describe)
  (uiop:quit))

(defun load-init (&optional file)
  "Load `~/.replic.lisp`, or the given file.
   The file name must be valid.

   To call this function with a valid filename, you can use

       (merge-pathnames \".foo.lisp\" (user-homedir-pathname))

   Note: to load an ini-style config file, use replic.config:apply-config."
  (if file
      (if (probe-file file)
          (progn (load file)
                 (setf *init-file* file)))
      (when (probe-file *init-file*)
        (load *init-file*))))

(defun reload ()
  "Reload the lisp file loaded at startup."
  (load-init *init-file*))

(defun main ()
  "Parse command line arguments and start the repl.

  Read the configuration file(s) first, apply cli args second.
  "
  (replic.config:apply-config :replic)

  (opts:define-opts
    (:name :help
           :description "Print this help and exit."
           :short #\h
           :long "help")

    (:name :quiet
           :description "Do not load the init file."
           :short #\q
           :long "quiet")

    (:name :load
           :description "Load the given file."
           :short #\l
           :long "load"
           :arg-parser #'string))

  (multiple-value-bind (options)
      (handler-bind ((error #'handle-parser-error))
        (opts:get-opts))

    (handler-case
        (progn
          (if (getf options :help)
              (progn (opts:describe)
                     (uiop:quit)))

          (unless (getf options :quiet)
            (load-init (getf options :load)))

          (setf *prompt* (cl-ansi-text:green "replic > "))

          ;; create commands from the exported functions and variables.
          (replic.completion:functions-to-commands :replic.base)

          ;; load commands from the .replic.lisp init file.
          (replic.completion:functions-to-commands :replic.user)

          ;; launch the repl.
          (repl))
      (error (c) (progn (format *error-output* "~a~&" c)
                        (uiop:quit))))))
