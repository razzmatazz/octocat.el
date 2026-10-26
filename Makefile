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

# What ci runs at once.  ci-all runs melpazoid, which is the same on every
# release, with 31.1's only.
CI_CHECKS ?= compile lint test melpazoid

# Build the image and install the dependencies, then run compile, lint,
# test and melpazoid in parallel, as they are independent.  Each can also
# run on its own once ci has run.
ci: clean
	$(MAKE) image
	$(MAKE) deps
	$(MAKE) -j4 $(CI_CHECKS)

# ci on every release CI runs, at once: each release has its own image,
# and its own .eldev/VERSION.  Each run's output goes to .ci/VERSION.log;
# a failed one's end is printed.
ci-all:
	@mkdir -p .ci
	@for v in $(EMACS_ALL); do \
	  checks="compile lint test"; [ $$v = 31.1 ] && checks="$$checks melpazoid"; \
	  ( $(MAKE) ci EMACS=$$v CI_CHECKS="$$checks" > .ci/$$v.log 2>&1; \
	    echo $$? > .ci/$$v.status ) & \
	done; \
	wait; \
	failed=0; \
	for v in $(EMACS_ALL); do \
	  if [ "$$(cat .ci/$$v.status)" = 0 ]; then echo "Emacs $$v: ok"; \
	  else failed=1; echo "Emacs $$v: failed, see .ci/$$v.log"; \
	    grep -E "\.el:[0-9]+: |FAILED|Error|melpazoid: " .ci/$$v.log | tail -20; fi; \
	done; \
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

# melpazoid, as MELPA's reviewers run it on a submission, in two
# containers, so it does not run on the host.  First its checks of the
# recipe and the package: tools/melpazoid.py runs melpazoid.py in our
# image, given a copy of what MELPA packages (it copies the whole tree),
# up to where melpazoid would build its own image.  It exits 0 on what it
# only reports, so any "━" section, which it prints for each check that
# found something, fails here too.  Then the byte-compile, checkdoc and
# package-lint in melpazoid's own image, an Emacs 31 built without SQLite,
# so a function only some builds have shows.  It is built and run with
# melpazoid's Makefile, from a copy of its checkout with the files the
# first step wrote, and fails on a "━" section too.  Its make, under ci's
# -j, would warn of the jobserver.
MELPAZOID_COMMIT := fcf5d883c6ced74ba16963d48c9e9e0bf0a1ff37
MELPAZOID_RECIPE := (octocat :fetcher github :repo "razzmatazz/octocat.el")
# As the host's user, as without capabilities root cannot write to its
# directory; rootless podman maps the container's users to others.
MELPAZOID_USER = $(if $(findstring podman,$(DOCKER)),--userns=keep-id,--user $$(id -u):$$(id -g))
MELPAZOID_MAKE = MAKEFLAGS= MFLAGS= $(MAKE) -s -C .ci/melpazoid-build DOCKER="$(DOCKER)" \
  DOCKER_OUTPUT=--quiet PACKAGE_MAIN="$$(cat .ci/melpazoid-out/package-main)"

melpazoid:
	@if [ ! -d .ci/melpazoid/.git ]; then \
	  git clone -q https://github.com/riscy/melpazoid .ci/melpazoid; fi
	@git -C .ci/melpazoid cat-file -e $(MELPAZOID_COMMIT) 2>/dev/null \
	  || git -C .ci/melpazoid fetch -q origin
	@git -C .ci/melpazoid checkout -q $(MELPAZOID_COMMIT)
	@rm -rf .ci/melpazoid-src .ci/melpazoid-out .ci/melpazoid-build
	@mkdir -p .ci/melpazoid-src/octocat .ci/melpazoid-out
	@cp -p *.el LICENSE .ci/melpazoid-src/octocat
	@$(DOCKER) run --rm --cap-drop all --security-opt=no-new-privileges --pids-limit=100 \
	  $(MELPAZOID_USER) -e HOME=/tmp \
	  -v "$(CURDIR)/.ci/melpazoid:/melpazoid:ro" \
	  -v "$(CURDIR)/.ci/melpazoid-src/octocat:/octocat:ro" \
	  -v "$(CURDIR)/tools/melpazoid.py:/melpazoid-checks.py:ro" \
	  -v "$(CURDIR)/.ci/melpazoid-out:/out" -w /out \
	  -e RECIPE='$(MELPAZOID_RECIPE)' -e LOCAL_REPO=/octocat -e WARN_IS_ERROR=true -e NO_COLOR=1 \
	  $(IMAGE) python3 -I /melpazoid-checks.py /melpazoid > .ci/melpazoid-report.txt 2>&1; \
	  status=$$?; cat .ci/melpazoid-report.txt; \
	  if [ $$status != 0 ] || grep -q '^━ ' .ci/melpazoid-report.txt; then \
	    echo "melpazoid: found something, see above"; exit 1; fi
	@cp -a .ci/melpazoid .ci/melpazoid-build && cp -a .ci/melpazoid-out/. .ci/melpazoid-build
	@$(MELPAZOID_MAKE) image > /dev/null
	@$(MELPAZOID_MAKE) test > .ci/melpazoid-test.txt 2>&1; cat .ci/melpazoid-test.txt; \
	  if grep -q '^━ ' .ci/melpazoid-test.txt; then \
	    echo "melpazoid: found something, see above"; exit 1; fi

SCREENSHOTS_IMAGE := octocat-screenshots

# Rewrite docs/screenshots/, from made-up data, in a GUI Emacs
# under a virtual X display.  After compile, which checks the driver: a GUI
# Emacs failing to load it would wait for good.
screenshots: compile
	$(DOCKER) build -q -t $(SCREENSHOTS_IMAGE) -f test/screenshots/Dockerfile .
	$(DOCKER) run --rm --init -v "$(CURDIR)":/src -w /src $(SCREENSHOTS_IMAGE) \
	  test/screenshots/run.sh
