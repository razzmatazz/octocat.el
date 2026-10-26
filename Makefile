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

.PHONY: ci ci-all image deps clean compile lint test melpazoid screenshots

# What ci runs at once.  ci-all leaves out melpazoid, which is the same on
# every release, and runs it once beside them.
CI_CHECKS ?= compile lint test melpazoid

# Build the image and install the dependencies, then run compile, lint,
# test and melpazoid in parallel, as they are independent.  Each can also
# run on its own once ci has run.
ci: clean
	$(MAKE) image
	$(MAKE) deps
	$(MAKE) -j4 $(CI_CHECKS)

# ci on every release CI runs, at once, and melpazoid beside them: each
# release has its own image, and its own .eldev/VERSION.  Each run's output
# goes to .ci/VERSION.log, melpazoid's to .ci/melpazoid.log; a failed
# one's end is printed.
ci-all:
	@mkdir -p .ci
	@for v in $(EMACS_ALL); do \
	  ( $(MAKE) ci EMACS=$$v CI_CHECKS="compile lint test" > .ci/$$v.log 2>&1; \
	    echo $$? > .ci/$$v.status ) & \
	done; \
	( $(MAKE) melpazoid > .ci/melpazoid.log 2>&1; echo $$? > .ci/melpazoid.status ) & \
	wait; \
	failed=0; \
	for v in $(EMACS_ALL); do \
	  if [ "$$(cat .ci/$$v.status)" = 0 ]; then echo "Emacs $$v: ok"; \
	  else failed=1; echo "Emacs $$v: failed, see .ci/$$v.log"; \
	    grep -E "\.el:[0-9]+: |FAILED|Error" .ci/$$v.log | tail -20; fi; \
	done; \
	if [ "$$(cat .ci/melpazoid.status)" = 0 ]; then echo "melpazoid: ok"; \
	else failed=1; echo "melpazoid: failed, see .ci/melpazoid.log"; \
	  tail -30 .ci/melpazoid.log; fi; \
	exit $$failed

image:
	$(DOCKER) build --build-arg EMACS=$(EMACS) -t $(IMAGE) .

# The linters too, as lint and test run at once, against the same .eldev.
deps:
	$(RUN) eldev prepare build test lint exec

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

# checkdoc, package-lint and elisp-lint, as the Eldev file says, then
# check-declare.
lint:
	$(RUN) sh -c 'eldev lint && eldev exec -R --file tools/check-declare.el'

# The tests share one process, but for the evil one, which must load
# octocat itself (see its Commentary).
EVIL_TEST := test/octocat-evil-repo-tests.el

test:
	$(RUN) sh -c 'eldev test $(EVIL_TEST) && eldev test $(filter-out $(EVIL_TEST),$(wildcard test/*-tests.el))'

# melpazoid, as MELPA's reviewers run it on a submission: in its own image,
# an Emacs 31 built without SQLite, so a function only some builds have
# shows.  It runs on the host, as it builds and runs that image itself, so
# it needs python3.  It is given a copy of what MELPA packages, as it
# copies the whole tree.  It exits 0 on what it only reports, so any
# "━" section, which it prints for each check that found something,
# fails here too.  It runs make itself, which, given the jobserver of
# `make ci''s -j, warns on stderr, and melpazoid fails on any stderr.
MELPAZOID_COMMIT := fcf5d883c6ced74ba16963d48c9e9e0bf0a1ff37
MELPAZOID_RECIPE := (octocat :fetcher github :repo "razzmatazz/octocat.el")

melpazoid:
	@if [ ! -d .ci/melpazoid/.git ]; then \
	  git clone -q https://github.com/riscy/melpazoid .ci/melpazoid; fi
	@git -C .ci/melpazoid cat-file -e $(MELPAZOID_COMMIT) 2>/dev/null \
	  || git -C .ci/melpazoid fetch -q origin
	@git -C .ci/melpazoid checkout -q $(MELPAZOID_COMMIT)
	@rm -rf .ci/melpazoid-src/octocat && mkdir -p .ci/melpazoid-src/octocat
	@cp -p *.el LICENSE .ci/melpazoid-src/octocat
	@cd .ci/melpazoid && \
	  MAKEFLAGS= MFLAGS= DOCKER="$(DOCKER)" RECIPE='$(MELPAZOID_RECIPE)' \
	  LOCAL_REPO="$(CURDIR)/.ci/melpazoid-src/octocat" WARN_IS_ERROR=true NO_COLOR=1 \
	  python3 -I melpazoid/melpazoid.py > ../melpazoid-report.txt 2>&1; \
	  status=$$?; cat ../melpazoid-report.txt; \
	  if [ $$status != 0 ] || grep -q '^━ ' ../melpazoid-report.txt; then \
	    echo "melpazoid: found something, see above"; exit 1; fi

SCREENSHOTS_IMAGE := octocat-screenshots

# Rewrite docs/screenshots/, from made-up data, in a GUI Emacs
# under a virtual X display.  After compile, which checks the driver: a GUI
# Emacs failing to load it would wait for good.
screenshots: compile
	$(DOCKER) build -q -t $(SCREENSHOTS_IMAGE) -f test/screenshots/Dockerfile .
	$(DOCKER) run --rm --init -v "$(CURDIR)":/src -w /src $(SCREENSHOTS_IMAGE) \
	  test/screenshots/run.sh
