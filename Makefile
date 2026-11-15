EMACS ?= emacs

# notmuch.el is installed with the notmuch program rather than through
# package.el, into site-lisp under the program's prefix -- or a notmuch
# directory there, as Termux does.  NOTMUCH_LISP names it otherwise.
NOTMUCH_PREFIX := $(abspath $(dir $(shell command -v notmuch))/..)
NOTMUCH_LISP ?= $(wildcard $(NOTMUCH_PREFIX)/share/emacs/site-lisp \
	$(NOTMUCH_PREFIX)/share/emacs/site-lisp/notmuch)

BATCH = $(EMACS) -Q --batch --eval '(setq load-prefer-newer t)' \
	$(addprefix -L ,$(NOTMUCH_LISP)) -L .

EL = $(filter-out %-autoloads.el %-pkg.el, $(wildcard *.el))

.PHONY: all compile test clean

all: compile test

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
		-f batch-byte-compile $(EL)

test:
	$(BATCH) -l test/notmuch-live-tests.el -f ert-run-tests-batch-and-exit

# A stale .elc wins over the source beside it.
clean:
	rm -f *.elc test/*.elc
