# SPDX-License-Identifier: Apache-2.0
# Every check lives here. The CI workflow only sets up the environment and
# calls a target, so a run on a laptop matches a run on GitHub.
#
# Run inside the kube-devenv image. Platform values arrive as Make variables:
#   BASE_REF  commit the branch started from; empty skips commit-messages

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

CHECKS   ?= /usr/share/kube-devenv/checks
SCRIPTS  := bin/e2e $(wildcard lib/*.sh) $(wildcard tests/*.sh) tests/fakes/curl tests/fakes/kubectl tests/fakes/gh .githooks/pre-commit
TESTS    := $(wildcard tests/test-*.sh)
BASE_REF ?= $(shell git rev-parse --verify --quiet origin/main)

# This repo has no DCO, so commits need no Signed-off-by line.
export REQUIRE_SIGNOFF := 0

.PHONY: test-commit test-fast hooks fmt lint-scripts lint-pipelines test-scripts \
	secrets commit-messages

test-commit: test-fast lint-scripts lint-pipelines test-scripts commit-messages

test-fast: fmt secrets

hooks:
	git config core.hooksPath .githooks

fmt:
	shfmt -d -i 2 -ci $(SCRIPTS)

lint-scripts:
	bash -n $(SCRIPTS)
	shellcheck -x -S warning $(SCRIPTS)

lint-pipelines:
	$(CHECKS)/pipeline-lint.sh .

test-scripts:
	@for t in $(TESTS); do echo "== $$t"; bash "$$t"; done

secrets:
	$(CHECKS)/secrets.sh .

commit-messages:
	$(CHECKS)/commit-messages.sh "$(BASE_REF)"
