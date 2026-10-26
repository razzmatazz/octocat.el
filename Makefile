# The Emacs release to run, e.g. 29.1, 30.2 or 31.1, see the Dockerfile.
EMACS ?= 31.1
# The releases CI runs, as in .github/workflows/ci.yml, for `make ci-all'.
EMACS_ALL := 29.1 30.2 31.1
IMAGE := octocat-test:emacs-$(EMACS)

DOCKER := $(shell command -v docker 2>/dev/null || command -v podman 2>/dev/null)
ifeq ($(DOCKER),)
  $(error Neither docker nor podman found on PATH)
endif

# CI, as GitHub Actions sets it, turns on Eldev's retrying of failed
# package archive fetches.
RUN = $(DOCKER) run --rm -e CI -v "$(CURDIR)":/src -w /src $(IMAGE)

.PHONY: ci ci-all image deps clean compile lint test screenshots

# Build the image and install the dependencies, then run compile, lint and
# test in parallel, as they are independent.  compile, lint and test can
# also run on their own once ci has run.
ci: clean
	$(MAKE) image
	$(MAKE) deps
	$(MAKE) -j3 compile lint test

# ci on every release CI runs, at once: each has its own image, and its
# own .eldev/VERSION.  Each run's output goes to .ci/VERSION.log; a failed
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

# The linters too, as lint and test run at once, against the same .eldev.
deps:
	$(RUN) eldev prepare build test lint

clean:
	find . -maxdepth 1 -name '*.elc' -delete

# Compile a copy, so the .elc files do not land next to the sources while
# lint and test run alongside.  Only what compiling reads: copying .git
# fails when git rewrites its index meanwhile.  The tests are compiled
# too, and the screenshot driver, which only `make screenshots' runs.
compile:
	$(RUN) sh -c "mkdir -p /tmp/build/.eldev \
	  && cp -a /src/Eldev /src/*.el /src/test /tmp/build \
	  && cp -a /src/.eldev/$(EMACS) /tmp/build/.eldev \
	  && cd /tmp/build && eldev compile --warnings-as-errors --set all"

# checkdoc and package-lint, as the Eldev file says.
lint:
	$(RUN) eldev lint

# The tests share one process, but for the evil one, which must load
# octocat itself (see its Commentary).
EVIL_TEST := test/octocat-evil-repo-tests.el

test:
	$(RUN) sh -c 'eldev test $(EVIL_TEST) && eldev test $(filter-out $(EVIL_TEST),$(wildcard test/*-tests.el))'

SCREENSHOTS_IMAGE := octocat-screenshots

# Rewrite docs/screenshots/, from made-up data, in a GUI Emacs
# under a virtual X display.  After compile, which checks the driver: a GUI
# Emacs failing to load it would wait for good.
screenshots: compile
	$(DOCKER) build -q -t $(SCREENSHOTS_IMAGE) -f test/screenshots/Dockerfile .
	$(DOCKER) run --rm --init -v "$(CURDIR)":/src -w /src $(SCREENSHOTS_IMAGE) \
	  test/screenshots/run.sh
