#!/bin/sh
# Run screenshots.el in a GUI Emacs on a virtual X display.  Not
# xvfb-run: as a container's first process it can hang for good.
# Its socket shows before it takes connections; -displayfd says when it does.
Xvfb :99 -screen 0 2560x4000x24 -nolisten tcp -displayfd 3 3> /tmp/xvfb-ready &
for i in $(seq 1000); do [ -s /tmp/xvfb-ready ] && break; sleep 0.02; done
# Even then, about one connection in fifteen never reaches the server.
# Emacs then exits before doing anything, so it is run again; any other
# failure is the run's.
for try in 1 2 3 4 5; do
  # A GUI Emacs shows an error in its frame and waits for good, so one
  # in loading the driver is printed, and exits.
  { DISPLAY=:99 timeout 60 emacs -Q --eval '
(condition-case err
    (progn (load (expand-file-name "test/screenshots/screenshots.el"))
           (octocat-screenshots-update-and-exit))
  (error (princ (format "%s\n" (error-message-string err)) (function external-debugging-output))
         (kill-emacs 1)))'
    echo $? > /tmp/emacs-status
  } 2>&1 | tee /tmp/emacs-output
  status=$(cat /tmp/emacs-status)
  grep -q "Cannot connect to X server" /tmp/emacs-output || exit "$status"
  echo "Retrying: Emacs could not connect to Xvfb"
  sleep 0.2
done
exit "$status"
