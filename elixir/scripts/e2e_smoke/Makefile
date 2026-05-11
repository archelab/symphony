# Convenience targets for the Symphony e2e smoke harness.
#
# All targets assume the orchestrator (mix run) and gh CLI are available.
# Inherits configuration from environment:
#   SYMPHONY_E2E_PROJECT_OWNER, SYMPHONY_E2E_PROJECT_NUMBER, SYMPHONY_E2E_REPO

SHELL := /usr/bin/env bash
HERE  := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))

.PHONY: e2e e2e-fast e2e-clean

# Run the full smoke suite
e2e:
	@bash $(HERE)/run.sh

# Run only the fast negative tests (no Codex calls)
e2e-fast:
	@SYMPHONY_E2E_TESTS=e2e-5-terminal-or-at-dispatch,e2e-6-no-status bash $(HERE)/run.sh

# Clean smoke artifacts (workspace, logs, project items)
e2e-clean:
	@rm -rf /tmp/symphony-smoke-workspaces /tmp/symphony-smoke-log
	@bash -c 'source $(HERE)/lib.sh && \
		export SYMPHONY_E2E_PROJECT_OWNER=$${SYMPHONY_E2E_PROJECT_OWNER:-archelab} && \
		export SYMPHONY_E2E_PROJECT_NUMBER=$${SYMPHONY_E2E_PROJECT_NUMBER:-1} && \
		export SYMPHONY_E2E_REPO=$${SYMPHONY_E2E_REPO:-symphony} && \
		e2e::resolve_project_ids && \
		e2e::cleanup_smoke_items'
