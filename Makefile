# =============================================================================
# Makefile - Virtualization & Infrastructure Lab
# =============================================================================
# Cross-platform wrapper around scripts/python/labctl.py.
# On Windows, use scripts/make.ps1 which has the same targets.
# =============================================================================

LAB       ?= lab.yaml
PY        ?= python3
LABCTL    := scripts/python/labctl.py
SHELL     := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

.PHONY: help validate plan apply inventory start stop backup drill clean

help:                   ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

validate:               ## Parse and validate lab.yaml
	$(PY) $(LABCTL) --lab $(LAB) validate

plan:                   ## Preview the create commands (no changes)
	$(PY) $(LABCTL) --lab $(LAB) plan

apply:                  ## Apply lab.yaml (dry-run in v1.4)
	$(PY) $(LABCTL) --lab $(LAB) apply

inventory:              ## Print current VM inventory
	$(PY) $(LABCTL) --lab $(LAB) inventory

start:                  ## Power on every VM in start order
	$(PY) $(LABCTL) --lab $(LAB) start

stop:                   ## Power off every VM in reverse order
	$(PY) $(LABCTL) --lab $(LAB) stop

backup:                 ## Show the backup commands
	$(PY) $(LABCTL) --lab $(LAB) backup

drill:                  ## Walk the DR runbook for one VM
	@test -n "$(VM)" || (echo "VM= required, e.g. make drill VM=web01" >&2; exit 2)
	$(PY) $(LABCTL) --lab $(LAB) drill --vm $(VM)

clean:                  ## Remove transient plan output
	rm -rf .lab-plan/
