EMACS ?= emacs
# notmuch.el is installed with the notmuch program, outside package.el.
NOTMUCH_LISP ?= $(HOME)/.local/share/emacs/site-lisp

BATCH = $(EMACS) -Q --batch --eval '(setq load-prefer-newer t)' \
	-L $(NOTMUCH_LISP) -L .

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
