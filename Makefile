# Astronomy Shop sampling demo — KubeCon NA 2026
#
#   make start      kind cluster + everything, at the baseline (scenario 00)
#   make run 01     rung 0:   one instrumentation library off (don't create it)
#   make run 02     rungs 2+3: drop named noise, then keep 10% of traces
#   make run 03     rung 4:   tail sampling on a gateway tier
#   make run 04     rung 4+:  adaptive tail sampling, a budget instead of a percentage
#   make surge      triple the traffic (3 load generator pods); `make surge off` to stop
#   make stop       delete the cluster and everything in it
#
# Every `make run` prints why the scenario exists, what changed in the cluster
# (read back from Kubernetes) and where to look. `make run 00` goes back to the
# baseline. Settings live in settings.env; the dry-run tools are in scripts/
# (see README.md).

SHELL := /bin/bash
.DEFAULT_GOAL := help
MAKEFLAGS += --no-print-directory

SCENARIOS := 00 01 02 03 04
SCENARIO := $(firstword $(filter $(SCENARIOS),$(MAKECMDGOALS)))
SURGE_MODE := $(or $(firstword $(filter on off,$(MAKECMDGOALS))),on)

.PHONY: help start run surge stop $(SCENARIOS) on off

# `make run 02`, `make surge off`: the argument is a goal too; make it a no-op.
$(SCENARIOS) on off:
	@:

start:
	@bash scripts/start.sh

run:
	@test -n "$(SCENARIO)" || { echo "usage: make run 01 | 02 | 03 | 04   (make run 00 = back to the baseline)"; exit 1; }
	@bash scripts/run.sh $(SCENARIO)

surge:
	@bash scripts/surge.sh $(SURGE_MODE)

stop:
	@bash scripts/stop.sh

help:
	@echo "Astronomy Shop sampling demo"
	@echo
	@echo "  make start     create the kind cluster and deploy everything, at the baseline"
	@echo "  make run 01    rung 0:    stop creating telemetry nobody needs"
	@echo "  make run 02    rungs 2+3: drop named noise, keep 10% of traces"
	@echo "  make run 03    rung 4:    tail sampling on a gateway tier"
	@echo "  make run 04    rung 4+:   adaptive tail sampling: a budget, not a percentage"
	@echo "  make surge     triple the traffic (3 load generator pods); make surge off to stop"
	@echo "  make stop      delete the cluster and everything in it"
	@echo
	@echo "  make run 00 goes back to the baseline. Each run prints what changed and where to look."
	@echo "  Every make run also ends a surge."
