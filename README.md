# Org Theorem Environments

A minor mode `org-thm-mode` that provides theorem environment support for academic writing in Org mode.

**Disclaimer**: this package is intended for personal use, so I might not be responsive to issues.

## Introduction

This package provides a unified interface for defining theorem environments and handles the export of corresponding [special blocks](https://orgmode.org/org.html#Special-blocks-in-LaTeX-export) to LaTeX and HTML (with numbering).

Below are some example usages of the package.  For detailed description of the options, please consult their docstrings.

## Example: `amsthm`

By default, the package is set to work with `amsthm` out of the box.  All you need to do is port your theorem environment definitions to `org-thm-environments`:

```emacs-lisp
(use-package org-thm
  :after org
  :vc (:url "https://github.com/szch79/org-thm")
  :hook (org-mode . org-thm-mode)
  :config
  (setopt org-thm-environments
          '((thm         :reset section :display "Theorem"     :style plain
                         :name "theorem")
            (prop        :use thm       :display "Proposition" :style plain
                         :name "proposition")
            (lemma       :use thm       :display "Lemma"       :style plain)
            (corollary   :reset thm     :display "Corollary"   :style plain)
            (defn        :reset section :display "Definition"  :style definition
                         :name "definition"))))
```

Then, in Org mode, you can write them in special blocks, with a special `:label` header argument being the label.

```org
* Section 1

#+begin_defn :label "Definition 1"
Body of definition 1.
#+end_defn

#+begin_thm :label "Theorem 1"
Body of theorem 1.
#+end_thm

#+begin_corollary :label "Corollary 1"
Body of corollary 1.
#+end_corollary

#+begin_lemma :label "Lemma 1"
Body of lemma 1.
#+end_lemma

#+begin_corollary :label "Corollary 2"
Body of corollary 2.
#+end_corollary

* Section 2

#+begin_defn :label "Definition 2"
Body of definition 2.
#+end_defn

#+begin_thm :label "Theorem 2"
Body of theorem 2.
#+end_thm
```

### LaTeX export

The preamble will automatically include:

```latex
\usepackage{amsthm}

\theoremstyle{plain}
\newtheorem{theorem}{Theorem}[section]
\newtheorem{lemma}[theorem]{Lemma}
\newtheorem{corollary}{Corollary}[theorem]
\theoremstyle{definition}
\newtheorem{definition}{Definition}[section]
```

Note that despite we defined `prop` in `org-thm-environments`, the LaTeX preamble does not have its definition.  This is because `org-thm` inserts definitions *lazily*, and only does so when needed (i.e., when used in the Org file).  For each environment in `org-thm-environments`, the `car` symbol corresponds to the special block type (e.g., `thm` for `#+begin_thm`).  The optional `:name` property allows it to be renamed during export.  The `:use`, `:reset`, `:display`, and `:style` align well with those in `amsthm` environment definitions and should be intuitive to the reader.

### HTML export

In HTML export, a theorem environment will be converted to something like the following:

```html
<div class="thm">
<span class="theorem-header"><span class="theorem-title">Theorem 1.1</span> <span class="theorem-label">(Theorem 1)</span></span>.
<p>
Body of theorem 1.
</p>

</div>
```

Note that the numbering `Theorem 1.1` is automatically computed against the headline number, since we had `:reset` set to `section` in `thm`.  The `:name` value is used for the class names.  The user can set `org-thm-html-output-function` to change the output behavior (there is also `org-thm-latex-output-function` for LaTeX export, which is presumed to be rarely needed).

## Example: custom theorem styles and `tcolorbox`

Apart from `amsthm`, a user might want some stylish theorem styles using additional packages, for instance, `tcolorbox`.  Such scenarios are also supported by `org-thm`:

```emacs-lisp
(use-package org-thm
  :after org
  :vc (:url "https://github.com/szch79/org-thm")
  :hook (org-mode . org-thm-mode)
  :config
  (setopt org-thm-latex-packages '(("amsthm") ("tcolorbox" . "most")))
  (setopt org-thm-theorem-styles
          '(plain remark proof
            (definition . "\\tcolorboxenvironment{definition}{
  colback=gray!10,
  colframe=black,
  boxrule=1pt,
  arc=0pt,
  left=5pt, right=5pt, top=5pt, bottom=5pt
}")))
  ;; Same as before.
  (setopt org-thm-environments
          '((thm         :reset section :display "Theorem"     :style plain
                         :name "theorem")
            (prop        :use thm       :display "Proposition" :style plain
                         :name "proposition")
            (lemma       :use thm       :display "Lemma"       :style plain)
            (corollary   :reset thm     :display "Corollary"   :style plain)
            (defn        :reset section :display "Definition"  :style definition
                         :name "definition"))))
```

In this case, our `defn` environment will use the new `definition` style defined with `tcolorbox`.

Then the LaTeX export of the same Org file will have the following preamble:

```latex
\usepackage{amsthm}
\usepackage[most]{tcolorbox}

\tcolorboxenvironment{definition}{
  colback=gray!10,
  colframe=black,
  boxrule=1pt,
  arc=0pt,
  left=5pt, right=5pt, top=5pt, bottom=5pt
}
\theoremstyle{plain}
\newtheorem{theorem}{Theorem}[section]
\newtheorem{lemma}[theorem]{Lemma}
\newtheorem{corollary}{Corollary}[theorem]
\theoremstyle{definition}
\newtheorem{definition}{Definition}[section]
```

Additionally, the theorem style definition is also lazily inserted.

## Example: `thmtools`

Some users might prefer fancy theorem packages other than vanilla `amsthm`.  Here, we present an example with `thmtools`.

```emacs-lisp
(defun my/org-thm-latex-def-env-thmtools (name display style reset use)
  "Generate thmtools \\declaretheorem declaration.
For arguments, see `org-thm-latex-def-env-function'."
  (let ((opts '()))
    (when style
      (push (format "style=%s" style) opts))
    (push (format "name=%s" display) opts)
    (cond
     ((not (or reset use))
      (push "numbered=no" opts))
     (use
      (push (format "sibling=%s" use) opts))
     ((eq reset 'section)
      (push "parent=section" opts))
     ((and (stringp reset) (string-prefix-p "section-" reset))
      (push (format "parent=%s"
                    (pcase (substring reset 8)
                      ("1" "section")
                      ("2" "subsection")
                      (_ "subsubsection")))
            opts))
     ((stringp reset)
      (push (format "parent=%s" reset) opts)))
    (format "\\declaretheorem[%s]{%s}"
            (string-join (nreverse opts) ",")
            name)))

(use-package org-thm
  :after org
  :vc (:url "https://github.com/szch79/org-thm")
  :hook (org-mode . org-thm-mode)
  :config
  (setopt org-thm-latex-packages '(("amsthm") ("thmtools")))
  (setopt org-thm-latex-theoremstyle-template nil)
  (setopt org-thm-latex-def-env-function #'my/org-thm-latex-def-env-thmtools)
  ;; Same as before.
  (setopt org-thm-environments
          '((thm         :reset section :display "Theorem"     :style plain
                         :name "theorem")
            (prop        :use thm       :display "Proposition" :style plain
                         :name "proposition")
            (lemma       :use thm       :display "Lemma"       :style plain)
            (corollary   :reset thm     :display "Corollary"   :style plain)
            (defn        :reset section :display "Definition"  :style definition
                         :name "definition"))))
```

The generated LaTeX preamble is:

```latex
\usepackage{amsthm}
\usepackage{thmtools}

\declaretheorem[style=plain,name=Theorem,parent=section]{theorem}
\declaretheorem[style=plain,name=Lemma,sibling=theorem]{lemma}
\declaretheorem[style=plain,name=Corollary,parent=theorem]{corollary}
\declaretheorem[style=definition,name=Definition,parent=section]{definition}
```

By setting `org-thm-latex-theoremstyle-template` to `nil`, we prevent `org-thm` from inserting style-switching commands like `\theoremstyle`.  Besides that, we also need to supply a custom function for building environment definitions via `org-thm-latex-def-env-function`, since the default one only works for `amsthm`-styled definitions.
