# notmuch-live

Keep notmuch's search lists up to date as your mail changes.

notmuch's lists show the database as it was when they were drawn. A thread
you trash while reading it is still in the list you opened it from, still
marked unread, until you press `g`.

With `notmuch-live-mode` on, every open list follows the database instead:

- a thread's row is redrawn when the thread changes;
- a thread that no longer matches the list's search leaves it;
- a thread that newly matches, such as new mail, is put in by date.

This covers thread lists and unthreaded lists (`U`). The tree view (`z`) and
the thread being read are left as notmuch draws them. The start page is
redrawn while it is shown; notmuch already redraws it whenever it comes back
into a window.

Point stays on its row. When its own row leaves the list, point goes to the
row that followed it and `notmuch-live-row-removed-hook` runs.

## Requirements

- Emacs 29.1 or later.
- notmuch 0.34 or later, with the notmuch.el that came with it. Tested with
  0.34 and 0.40.

notmuch.el is not declared as a dependency. It has to match the installed
`notmuch` program, so it is installed along with it -- by `make install`, or
a distribution's notmuch Emacs package -- and declaring it would have
package.el fetch a second, unmatched copy.

## Installation

With Emacs 30's `use-package`:

```elisp
(use-package notmuch-live
  :vc (:url "https://github.com/OSadovy/notmuch-live.el")
  :after notmuch
  :config (notmuch-live-mode 1))
```

On Emacs 29, install it first with
`M-x package-vc-install RET https://github.com/OSadovy/notmuch-live.el RET`
and drop the `:vc` line.

Changes made through notmuch.el are caught on their own. After changing the
database outside Emacs, as by `notmuch new` or a sync, call
`notmuch-live-update`; a list shown again catches up regardless.

Lists opened before the mode was turned on are left alone.

## How it works

Every message in a notmuch database records the revision at which it last
changed. Each list remembers the revision it is current to, and once a
command that changed tags has finished, asks notmuch for the threads changed
since then: a query of its own search, limited to those threads, gives their
rows as they should be now.

Catching up waits for the command to finish because commands like archiving
move point to the next row themselves; taking the row out first would make
them skip one.

Each open list costs a query or two per catch-up: about 15 ms for a single
tag change, and 40-90 ms after a sync that changed some 900 threads, on a
mailbox of 14,000 messages.

notmuch.el draws its rows through functions that are not a public interface,
and notmuch-live draws them the same way. A test checks that those functions
are still there, so after upgrading notmuch, run the tests.

Before notmuch 0.38, an unthreaded list whose search is still running when
the database changes catches up only at the next change, or when it is shown
again.

## Tests

```sh
make test
```

The tests build a mail database of their own in a temporary directory. The
Makefile looks for notmuch.el beside the `notmuch` program; `NOTMUCH_LISP`
names it otherwise.
