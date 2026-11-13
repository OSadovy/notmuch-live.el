# notmuch-live

Keep notmuch's search lists up to date as your mail changes.

notmuch's lists show the database as it was when they were drawn. A thread
you trash while reading it is still in the list you opened it from, still
marked unread, until you press `g`.

With `notmuch-live-mode` on, every open list follows the database instead:

- a thread's row is redrawn when the thread changes;
- a thread that no longer matches the list's search leaves it;
- a thread that newly matches, such as new mail, is put in by date.

This covers thread lists and unthreaded lists (`U`). The tree view (`z`) is
left as notmuch draws it. The start page is redrawn while it is shown;
notmuch already redraws it whenever it comes back into a window.

Point stays on its row. When its own row leaves the list, point goes to the
row that followed it and `notmuch-live-row-removed-hook` runs.

## Setup

```elisp
(use-package notmuch-live
  :after notmuch
  :config (notmuch-live-mode 1))
```

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

It relies on how notmuch.el 0.40 draws its rows, which is not a public
interface, so a notmuch upgrade wants the tests run again.

## Tests

```sh
make test
```

The tests build a mail database of their own in a temporary directory.
`NOTMUCH_LISP` names where notmuch.el is installed, by default
`~/.local/share/emacs/site-lisp`.
