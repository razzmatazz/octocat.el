#!/bin/sh
# Run screenshots.el in a GUI Emacs on a virtual X display.  Not
# xvfb-run: as a container's first process it can hang for good.
set -e
# Its socket shows before it takes connections; -displayfd says when it does.
Xvfb :99 -screen 0 2560x4000x24 -nolisten tcp -displayfd 3 3> /tmp/xvfb-ready &
for i in $(seq 1000); do [ -s /tmp/xvfb-ready ] && break; sleep 0.02; done
# A GUI Emacs shows an error in its frame and waits for good, so one in
# loading the driver is printed, and exits.
DISPLAY=:99 timeout 60 emacs -Q --eval '
(condition-case err
    (progn (load (expand-file-name "test/screenshots/screenshots.el"))
           (octocat-screenshots-update-and-exit))
  (error (princ (format "%s\n" (error-message-string err)) (function external-debugging-output))
         (kill-emacs 1)))'
