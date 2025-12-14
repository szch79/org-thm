;;; org-thm.el --- Org Theorem Environments -*- lexical-binding: t; -*-

;; Copyright (C) 2025 MT Lin

;; Author: MT Lin <https://github.com/szch79>
;; Homepage: https://github.com/szch79/org-thm
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A package for declaring theorem environments in Org mode with special
;; blocks.  There also a minor mode `org-thm-mode' that hooks into the HTML and
;; LaTeX export.

;;; Code:

(require 'org)
(require 'ox)
(require 'cl-lib)

(declare-function org-html-special-block "ox-html" (special-block contents info))
(declare-function org-latex-special-block "ox-latex" (special-block contents info))
(declare-function org-babel-parse-header-arguments "ob-core" (string))


;;; Customization
;;;

(defgroup org-thm nil
  "Org theorem-like environments."
  :group 'org-export
  :prefix "org-thm-")

(defcustom org-thm-latex-packages '(("amsthm"))
  "LaTeX packages for theorem environments.
Each element is a list (PACKAGE . OPTIONS) where PACKAGE is the package name and
OPTIONS is an optional string of package options."
  :type '(alist :key-type (string :tag "Package name")
                :value-type (choice (const nil)
                                    (string :tag "Package options")))
  :group 'org-thm)

(defcustom org-thm-environments nil
  "Alist of recognized theorem environments.

Each entry is (KEY . SPEC) where KEY is a symbol matching the special block type
\(e.g., `thm' for #+begin_thm), and will be referenced as the unique symbol
representing the environment.

SPEC is a plist that may contain:

`:name'

  Optional; a string for the environment name.  When provided, the string will
  be used instead of the symbol name of special block type during export.

`:reset'

  Defines a counter for this environment that resets at:

    t            global counter, never resets
    `section'    resets at each headline
    `section-N'  resets at headline level N (e.g., `section-2' for subsection)
    ENV          resets when another ENV's counter increments (ENV must have
                 `:reset')

  Mutually exclusive with `:use'.

`:use'

  Symbol naming another environment whose counter to share.  That environment
  must have `:reset' defined.  Mutually exclusive with `:reset'.

If neither `:reset' nor `:use' is present, the environment is unnumbered.

`:style'

  Theorem style symbol, must be one of `org-thm-theorem-styles'.  Used to
  select LaTeX theorem style and mimic LaTeX typesetting in HTML export.

`:display'

  Display name string (e.g., \"Theorem\").  Defaults to capitalized KEY."
  :type '(alist :key-type symbol
                :value-type
                (plist :options
                       ((:name string)
                        (:reset
                         (choice
                          (const :tag "Global" t)
                          (const :tag "By section" section)
                          (symbol :tag "By section level or another env")))
                        (:use symbol)
                        (:style symbol)
                        (:display string))))
  :group 'org-thm)

(defcustom org-thm-theorem-styles
  '(plain definition remark proof)
  "List of theorem styles.

Each element is either:
- A symbol: a built-in style (e.g., `plain', `definition', `remark' for amsthm)
- A cons (SYMBOL . DEFINITION): a custom style with its LaTeX definition string

Example:
  \\='(plain
    definition
    (note . \"\\newtheoremstyle{note}...\"))

The default styles `plain', `definition', `remark' are built-in to amsthm.
The `proof' style is special and handled separately."
  :type '(repeat (choice symbol
                         (cons symbol string)))
  :group 'org-thm)

(defcustom org-thm-latex-theoremstyle-template "\\theoremstyle{%s}"
  "Template for switching theorem style, or nil for declarative packages.
%s is replaced with the style name.

If the value is nil, no style switching is inserted.  This is useful when using
packages like thmtools."
  :type '(choice (string :tag "Template")
                 (const :tag "None (declarative)" nil))
  :group 'org-thm)

(defcustom org-thm-latex-def-env-function #'org-thm-latex-def-env-amsthm
  "Function to generate a single theorem definition.

Called with the following arguments:

  NAME        environment name string
  DISPLAY     display string
  STYLE       style symbol
  RESET       reset spec: t for global, `section' or `section-N' symbol for
              section reset, string for another environment's name, or nil
  USE         another environment's name string, or nil

Must return a string."
  :type 'function
  :group 'org-thm)

(defcustom org-thm-numbering-backends '(html)
  "A list of backends that need explicit numbering.
Any derived backend of them will also be treated as needing explicit numbering."
  :type '(repeat symbol)
  :group 'org-thm)

(defcustom org-thm-html-output-function #'org-thm-html-output-default
  "Function to format theorem blocks for HTML export.

Called with the following arguments:

  TYPE        special block type symbol
  NAME        environment name string
  DISPLAY     display name string
  STYLE       theorem style symbol
  NUMBER      formatted number string or nil
  LABEL       optional label string
  BODY        original block body
  TRANSCODED  full output from `org-html-special-block'

Must return an HTML string."
  :type 'function
  :group 'org-thm)

(defcustom org-thm-latex-output-function #'org-thm-latex-output-default
  "Function to format theorem blocks for LaTeX export.

Called with the following arguments:

  TYPE        special block type symbol
  NAME        environment name string
  LABEL       optional label string
  BODY        original block body
  TRANSCODED  full output from `org-html-special-block'

Returns a LaTeX string."
  :type 'function
  :group 'org-thm)


;;; Processing parse tree
;;;

(defun org-thm--validate-counter-env (env context)
  "Validate that ENV is a valid counter-defining environment.
ENV is a symbol.  CONTEXT is a string for error messages.  Return the
environment spec if valid."
  (let ((spec (alist-get env org-thm-environments)))
    (unless spec
      (user-error
       "org-thm: %s `%s' references undefined environment" context env))
    (unless (plist-get spec :reset)
      (user-error
       "org-thm: %s `%s' references unnumbered environment" context env))
    spec))

(defun org-thm--resolve-counter-reset (spec type)
  "Return the `:reset' value for environment TYPE with SPEC.
For `:use' environments, return the used environment's `:reset' value.  Return
nil if unnumbered."
  (let ((reset (plist-get spec :reset))
        (use (plist-get spec :use)))
    (cond
     (reset
      (when (and (symbolp reset)
                 (not (eq reset t))
                 (not (eq reset 'section))
                 (not (string-prefix-p "section-" (symbol-name reset))))
        (org-thm--validate-counter-env reset (format "`%s' :reset" type)))
      reset)
     (use
      (let ((target-spec
             (org-thm--validate-counter-env use (format "`%s' :use" type))))
        (plist-get target-spec :reset))))))

(defun org-thm--reset-prefix (element info reset reset-numbers)
  "Compute the number prefix based on reset context.

ELEMENT is the special block element.
INFO is the export communication channel.
RESET is the `:reset' value.
RESET-NUMBERS is a hash-table mapping reset env symbols to number lists."
  (pcase reset
    ;; Global counter.
    ('t nil)
    ;; Reset at each headline (closest headline).
    ('section
     ;; NOTE: the headline may be explicitly set to unnumbered; fall back to 0.
     (or (when-let ((hl (org-export-get-parent-headline element)))
           (org-export-get-headline-number hl info))
         '(0)))
    ;; Reset at certain headline level.
    ((and (pred symbolp)
          (let s (symbol-name reset))
          (guard (string-prefix-p "section-" s)))
     (or (when-let ((hl (org-export-get-parent-headline element)))
           (seq-take (org-export-get-headline-number hl info)
                     (string-to-number (substring s 8))))
         '(0)))
    ;; Reset after another environment.
    ((pred symbolp)
     (or (gethash reset reset-numbers)
         ;; If appears before the reset environment, count from 0 (matches
         ;; LaTeX's behavior).
         '(0)))))

(defun org-thm--annotate-theorem-blocks-with-numbering (info)
  "Annotate theorem blocks after tree properties are collected.
INFO is the communication channel with `:headline-numbering' populated."
  (let ((tree (plist-get info :parse-tree))
        (counter-trie (make-hash-table :test #'equal))
        (reset-numbers (make-hash-table :test #'eq)))
    (org-element-map tree 'special-block
      (lambda (blk)
        (when-let* ((type (intern (org-element-property :type blk)))
                    (spec (alist-get type org-thm-environments))
                    (counter (if (plist-get spec :reset)
                                 type
                               (plist-get spec :use)))
                    (counter-reset (org-thm--resolve-counter-reset spec type)))
          (let* ((prefix (org-thm--reset-prefix
                          blk info counter-reset reset-numbers))
                 (key (cons counter prefix))
                 (n (1+ (gethash key counter-trie 0)))
                 (number (if prefix
                             (append prefix (list n))
                           (list n))))
            (puthash key n counter-trie)
            (when (plist-get spec :reset)
              (puthash type number reset-numbers))
            (org-element-put-property blk :thm-number number))))
      info))
  info)

(defun org-thm--collect-theorem-environments (info)
  "Collect theorem environments used in the document.
A list of used environments will be inserted to the `:org-thm-envs' property of
INFO."
  (let ((tree (plist-get info :parse-tree))
        (thm-envs '()))
    (org-element-map tree 'special-block
      (lambda (blk)
        (let ((type (intern (org-element-property :type blk))))
          (when (alist-get type org-thm-environments)
            (cl-pushnew type thm-envs))))
      info)
    (when thm-envs
      (plist-put info :org-thm-envs thm-envs)))
  info)


;;; Default output functions & def env function
;;;

(defun org-thm-html-output-default (_type name display _style number
                                          label _body transcoded)
  "Default HTML output function for theorem blocks.
For arguments, see `org-thm-html-output-function'."
  (let* ((header (concat
                  (format "<span class=\"%s-title\">%s%s</span>"
                          name display
                          (if number (format " %s" number) ""))
                  (when label
                    (format " <span class=\"%s-label\">(%s)</span>"
                            name label))))
         (header-line (format "<span class=\"%s-header\">%s</span>.\n"
                              name header)))
    (if (string-match (rx (group "<" (+ (not (any ">"))) ">" "\n"))
                      transcoded)
        (concat (match-string 0 transcoded)
                header-line
                (substring transcoded (match-end 0)))
      transcoded)))

(defun org-thm-latex-output-default (type name label _body transcoded)
  "Default LaTeX output function for theorem blocks.
For arguments, see `org-thm-latex-output-function'."
  (let* ((old-env (symbol-name type))
         (new-begin (if label
                        (format "\\begin{%s}[%s]" name label)
                      (format "\\begin{%s}" name)))
         (new-end (format "\\end{%s}" name)))
    (if (string-match (rx string-start
                          "\\begin{" (literal old-env) "}"
                          (group (* anything))
                          "\\end{" (literal old-env) "}"
                          string-end)
                      transcoded)
        (concat new-begin (match-string 1 transcoded) new-end)
      transcoded)))

(defun org-thm-latex-def-env-amsthm (name display _style reset use)
  "Generate amsthm \\newtheorem declaration.
For arguments, see `org-thm-latex-def-env-function'."
  (cond
   ;; Unnumbered.
   ((not (or reset use))
    (format "\\newtheorem*{%s}{%s}" name display))
   ;; Use another env as the counter.
   (use
    (format "\\newtheorem{%s}[%s]{%s}" name use display))
   ;; Global counter.
   ((eq reset t)
    (format "\\newtheorem{%s}{%s}" name display))
   ;; Resets by section or section-N.
   ((or (eq reset 'section)
        (string-prefix-p "section-" reset))
    (let ((level (if (eq reset 'section)
                     "section"
                   (pcase (substring reset 8)
                     ("1" "section")
                     ("2" "subsection")
                     ;; LaTeX has at most 3 levels.
                     (_ "subsubsection")))))
      (format "\\newtheorem{%s}{%s}[%s]" name display level)))
   ;; Resets by another env's counter
   ((stringp reset)
    (format "\\newtheorem{%s}{%s}[%s]" name display reset))))


;;; Register ox-latex feature
;;;

(defun org-thm--toposort-envs (envs)
  "Topologically sort ENVS by dependency, prioritizing same-style adjacency."
  (let* ((env-set (make-hash-table :test #'eq))
         (dep-of (make-hash-table :test #'eq))  ; env -> what it depends on
         (remaining (make-hash-table :test #'eq))
         (result nil)
         (current-style nil))
    ;; Initialize
    (dolist (env envs)
      (puthash env t env-set)
      (puthash env t remaining))
    ;; Build dependencies (only those within envs)
    (dolist (env envs)
      (let* ((spec (alist-get env org-thm-environments))
             (use (plist-get spec :use))
             (reset (plist-get spec :reset))
             (dep (cond (use use)
                        ((and reset (symbolp reset)
                              (not (eq reset t))
                              (not (eq reset 'section))
                              (not (string-prefix-p "section-"
                                                    (symbol-name reset))))
                         reset))))
        (when (gethash dep env-set)
          (puthash env dep dep-of))))
    ;; Greedy topo sort
    (while (> (hash-table-count remaining) 0)
      (let* ((ready (cl-loop for env being the hash-keys of remaining
                             unless (gethash (gethash env dep-of) remaining)
                             collect env))
             (same-style (cl-remove-if-not
                          (lambda (env)
                            (eq (plist-get (alist-get env org-thm-environments)
                                           :style)
                                current-style))
                          ready))
             (chosen (or (car same-style) (car ready))))
        (unless chosen
          (error "org-thm: circular dependency detected"))
        (push chosen result)
        (remhash chosen remaining)
        (setq current-style (plist-get (alist-get chosen org-thm-environments)
                                       :style))))
    (nreverse result)))

(defun org-thm--group-consecutive-by-style (sorted-envs)
  "Group SORTED-ENVS into consecutive runs of same theorem style.
Returns alist of (STYLE . (ENV ...))."
  (let ((result nil)
        (current-style nil)
        (current-group nil))
    (dolist (env sorted-envs)
      (let ((style (plist-get (alist-get env org-thm-environments) :style)))
        (if (eq style current-style)
            (push env current-group)
          (when current-group
            (push (cons current-style (nreverse current-group)) result))
          (setq current-style style
                current-group (list env)))))
    (when current-group
      (push (cons current-style (nreverse current-group)) result))
    (nreverse result)))

(defun org-thm--generate-latex-usepackage (_info)
  "Generate \\usepackage lines for theorem packages."
  (mapconcat
   (lambda (pkg)
     (let ((name (car pkg))
           (opts (cdr pkg)))
       (if (and opts (not (string-empty-p opts)))
           (format "\\usepackage[%s]{%s}" opts name)
         (format "\\usepackage{%s}" name))))
   org-thm-latex-packages
   "\n"))

(defun org-thm--generate-latex-style-defs (styles)
  "Generate necessary theorem style definitions from STYLES."
  (let ((defs (cl-loop for style in styles
                       for entry = (assq style org-thm-theorem-styles)
                       when (consp entry)
                       collect (cdr entry))))
    (when defs (string-join defs "\n"))))

(defun org-thm--env-name (env)
  "Return the name string for ENV symbol."
  (when-let ((spec (alist-get env org-thm-environments)))
    (or (plist-get spec :name) (symbol-name env))))

(defun org-thm--generate-latex-env-defs (envs)
  "Generate theorem environment definitions grouped by style.
ENVS is an alist of (STYLE . (ENV ...))."
  (string-join
   (cl-loop for (style . envs) in envs
            when (and style org-thm-latex-theoremstyle-template)
            collect (format org-thm-latex-theoremstyle-template style)
            append
            (cl-loop for env in envs
                     for spec = (alist-get env org-thm-environments)
                     for reset = (plist-get spec :reset)
                     collect
                     (funcall org-thm-latex-def-env-function
                              (or (plist-get spec :name) (symbol-name env))
                              (or (plist-get spec :display)
                                  (capitalize (symbol-name env)))
                              style
                              (if (and reset
                                       (symbolp reset)
                                       (not (eq reset t))
                                       (not (eq reset 'section))
                                       (not (string-prefix-p
                                             "section-" (symbol-name reset))))
                                  (org-thm--env-name reset)
                                reset)
                              (org-thm--env-name (plist-get spec :use)))))
   "\n"))

(defun org-thm--generate-latex-definitions (info)
  "Generate LaTeX preamble for theorem style and environment definitions.
The used styles and environments are in `:org-thm-envs' in INFO."
  (let* ((envs (plist-get info :org-thm-envs))
         (sorted-envs (org-thm--toposort-envs envs))
         (envs-by-style (org-thm--group-consecutive-by-style sorted-envs))
         (styles (delete-dups (mapcar #'car envs-by-style)))
         (style-defs (org-thm--generate-latex-style-defs styles))
         (env-defs (org-thm--generate-latex-env-defs envs-by-style)))
    (if (and style-defs env-defs)
        (concat style-defs "\n" env-defs)
      (or style-defs env-defs))))

(org-export-update-features 'latex
  (org-thm-usepackage
   :condition (plist-get info :org-thm-envs)
   :snippet org-thm--generate-latex-usepackage
   :order 3)
  (org-thm-definitions
   :condition (plist-get info :org-thm-envs)
   :snippet org-thm--generate-latex-definitions
   :order 4))


;;; Export advice
;;;

(defun org-thm--collect-tree-properties-advice (orig-fun tree info)
  "Advice to run theorem annotation after tree properties are collected."
  (let ((result (funcall orig-fun tree info))
        (backend (org-export-backend-name (plist-get info :back-end))))
    (cond
     ((org-export-derived-backend-p backend 'latex)
      (org-thm--collect-theorem-environments result))
     ((cl-some (lambda (b)
                 (org-export-derived-backend-p backend b))
               org-thm-numbering-backends)
      (org-thm--annotate-theorem-blocks-with-numbering result))
     (t result))))

(defun org-thm--special-block-advice (orig-fun special-block contents info)
  "Advice for special block transcoders to handle theorem environments."
  (let* ((type (intern (org-element-property :type special-block)))
         (spec (alist-get type org-thm-environments)))
    (if (not spec)
        (funcall orig-fun special-block contents info)
      (let* ((transcoded (funcall orig-fun special-block contents info))
             (params (org-babel-parse-header-arguments
                      (or (org-element-property :parameters special-block) "")))
             (label (alist-get :label params)))
        (pcase org-export-current-backend
          ('html
           (let ((number (when-let ((n (org-element-property :thm-number
                                                             special-block)))
                           (mapconcat #'number-to-string n "."))))
             (funcall org-thm-html-output-function
                      type
                      (or (plist-get spec :name) (symbol-name type))
                      (plist-get spec :display)
                      (plist-get spec :style)
                      number
                      label
                      (or contents "")
                      transcoded)))
          ('latex
           (funcall org-thm-latex-output-function
                    type
                    (or (plist-get spec :name) (symbol-name type))
                    label
                    (or contents "")
                    transcoded))
          (_ transcoded))))))


;;; Minor mode
;;;

;;;###autoload
(define-minor-mode org-thm-mode
  "Global minor mode for theorem environments in Org export."
  :global t
  :group 'org-thm
  (if org-thm-mode
      (progn
        (advice-add 'org-export--collect-tree-properties :around
                    #'org-thm--collect-tree-properties-advice)
        (advice-add 'org-html-special-block :around
                    #'org-thm--special-block-advice)
        (advice-add 'org-latex-special-block :around
                    #'org-thm--special-block-advice))
    (advice-remove 'org-export--collect-tree-properties
                   #'org-thm--collect-tree-properties-advice)
    (advice-remove 'org-html-special-block
                   #'org-thm--special-block-advice)
    (advice-remove 'org-latex-special-block
                   #'org-thm--special-block-advice)))

(provide 'org-thm)

;;; org-thm.el ends here
