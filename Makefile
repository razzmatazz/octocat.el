# The Emacs release to run, e.g. 29.1, 30.2 or 31.1, see the Dockerfile.
EMACS ?= 31.1
# The releases CI runs, as in .github/workflows/ci.yml, for `make ci-all'.
EMACS_ALL := 29.1 30.2 31.1
IMAGE := octocat-test:emacs-$(EMACS)

DOCKER := $(shell command -v docker 2>/dev/null || command -v podman 2>/dev/null)
ifeq ($(DOCKER),)
  $(error Neither docker nor podman found on PATH)
endif

RUN = $(DOCKER) run --rm -v "$(CURDIR)":/src -w /src $(IMAGE)

.PHONY: ci ci-all image deps clean compile lint test screenshots

# Build the image and install the dependencies, then run compile, lint and
# test in parallel, as they are independent.  compile, lint and test can
# also run on their own once ci has run.
ci: clean
	$(MAKE) image
	$(MAKE) deps
	$(MAKE) -j3 compile lint test

# ci on every release CI runs, at once: each has its own image, and its
# own .eask/VERSION.  Each run's output goes to .ci/VERSION.log; a failed
# one's end is printed.
ci-all:
	@mkdir -p .ci
	@for v in $(EMACS_ALL); do \
	  ( $(MAKE) ci EMACS=$$v > .ci/$$v.log 2>&1; echo $$? > .ci/$$v.status ) & \
	done; wait; \
	failed=0; \
	for v in $(EMACS_ALL); do \
	  if [ "$$(cat .ci/$$v.status)" = 0 ]; then echo "Emacs $$v: ok"; \
	  else failed=1; echo "Emacs $$v: failed, see .ci/$$v.log"; \
	    grep -E "\.el:[0-9]+: |FAILED|Error" .ci/$$v.log | tail -20; fi; \
	done; exit $$failed

image:
	$(DOCKER) build --build-arg EMACS=$(EMACS) -t $(IMAGE) .

deps:
	$(RUN) eask install-deps --dev

clean:
	find . -maxdepth 1 -name '*.elc' -delete

# Compile a copy, so the .elc files do not land next to the sources while
# lint and test run alongside.  Only what compiling reads: copying .git
# fails when git rewrites its index meanwhile.  The screenshot driver is
# compiled too, but not run: that is `make screenshots'.
compile:
	$(RUN) sh -c "mkdir -p /tmp/build/.eask \
	  && cp -a /src/Eask /src/*.el /src/test /tmp/build \
	  && cp -a /src/.eask/$(EMACS) /tmp/build/.eask \
	  && cd /tmp/build && eask compile --strict \
	  && eask compile --strict test/screenshots/fixtures.el test/screenshots/screenshots.el"

# checkdoc only prints its findings, so fail on any FILE:LINE: message.
lint:
	$(RUN) sh -c 'eask lint checkdoc 2>&1 | tee /tmp/checkdoc.log && ! grep -E "\.el:[0-9]+: " /tmp/checkdoc.log > /dev/null && eask lint package'

# Each eask start takes seconds, so the tests share one process, but for
# the evil one, which must load octocat itself (see its Commentary).
EVIL_TEST := test/octocat-evil-repo-tests.el

test:
	$(RUN) sh -c 'eask test ert $(EVIL_TEST) && eask test ert $(filter-out $(EVIL_TEST),$(wildcard test/*-tests.el))'

SCREENSHOTS_IMAGE := octocat-screenshots

# Rewrite docs/screenshots/, from made-up data, in a GUI Emacs
# under a virtual X display.  After compile, which checks the driver: a GUI
# Emacs failing to load it would wait for good.
screenshots: compile
	$(DOCKER) build -q -t $(SCREENSHOTS_IMAGE) -f test/screenshots/Dockerfile .
	$(DOCKER) run --rm --init -v "$(CURDIR)":/src -w /src $(SCREENSHOTS_IMAGE) \
	  test/screenshots/run.sh
