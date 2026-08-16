SHELL := /bin/bash

REPO         := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
BIN_DIR      := $(HOME)/.local/bin
UNIT_DIR     := $(HOME)/.config/systemd/user
# Mirrors bin/claude-rc-window's own default so `make enable`'s directory
# check agrees with what the running instance will actually use.
PROJECTS_DIR := $(if $(CLAUDE_RC_PROJECTS_DIR),$(CLAUDE_RC_PROJECTS_DIR),$(HOME)/projects)
# Reserved instance name for claude-rc-general.service; see bin/claude-rc-window.
GENERAL_NAME := general

SCRIPTS   := $(notdir $(wildcard $(REPO)/bin/*))
UNITS     := $(notdir $(wildcard $(REPO)/units/*))

.PHONY: help install uninstall enable disable enable-general disable-general check status link relink

help:
	@echo "claude-rc -- systemd-managed 'claude rc' windows in a shared tmux session"
	@echo
	@echo "  make install           Symlink scripts + units, enable linger, start the target"
	@echo "  make enable NAME=foo   Enable and start an instance for \$$PROJECTS_DIR/foo"
	@echo "  make disable NAME=foo  Stop and disable that instance"
	@echo "  make enable-general    Enable and start the instance for the projects root itself"
	@echo "  make disable-general   Stop and disable it"
	@echo "  make status            Show the target, the timer and every instance"
	@echo "  make check             Preflight: tmux, projects dir, claude, linger"
	@echo "  make uninstall         Remove symlinks (leaves ~/projects and the repo alone)"
	@echo
	@echo "Instances are tracked by systemd itself, in"
	@echo "$(UNIT_DIR)/claude-rc.target.wants/ -- there is no list in this repo."

# Symlink rather than copy: `git pull` becomes the deploy, and an edit made
# on any machine is an edit to the repo instead of a silent local fork.
link:
	@mkdir -p "$(BIN_DIR)" "$(UNIT_DIR)"
	@for f in $(SCRIPTS); do \
	  dest="$(BIN_DIR)/$$f"; \
	  if [[ -e "$$dest" && ! -L "$$dest" ]]; then \
	    echo "  backup   $$dest -> $$dest.bak"; mv "$$dest" "$$dest.bak"; \
	  fi; \
	  ln -sfn "$(REPO)/bin/$$f" "$$dest"; echo "  link     $$dest"; \
	done
	@for f in $(UNITS); do \
	  dest="$(UNIT_DIR)/$$f"; \
	  if [[ -e "$$dest" && ! -L "$$dest" ]]; then \
	    echo "  backup   $$dest -> $$dest.bak"; mv "$$dest" "$$dest.bak"; \
	  fi; \
	  ln -sfn "$(REPO)/units/$$f" "$$dest"; echo "  link     $$dest"; \
	done
	@chmod +x $(REPO)/bin/*

relink: link
	@systemctl --user daemon-reload
	@echo "Reloaded. Running instances were not restarted; use"
	@echo "  systemctl --user reload claude-rc@<name>.service"
	@echo "to re-run claude-rc-window for one (it respawns only dead windows)."

install: check link
	@# Lingering is what makes any of this start at boot rather than at first login.
	@# Enabling it goes through polkit, which has nothing to prompt on over a
	@# plain ssh session -- so try, but don't fail the install over it.
	@if [[ "$$(loginctl show-user "$$USER" -p Linger --value 2>/dev/null)" != "yes" ]]; then \
	  loginctl enable-linger "$$USER" 2>/dev/null \
	    || echo "  !!       could not enable linger; run: sudo loginctl enable-linger $$USER"; \
	fi
	@systemctl --user daemon-reload
	@systemctl --user enable --now claude-rc.target
	@systemctl --user enable --now claude-rc-healthcheck.timer
	@echo
	@echo "Installed. Enable an instance with:  make enable NAME=<project>"

enable:
	@[[ -n "$(NAME)" ]] || { echo "usage: make enable NAME=<project>" >&2; exit 1; }
	@[[ "$(NAME)" != "$(GENERAL_NAME)" ]] || { echo "NAME=$(GENERAL_NAME) is reserved for the projects-root instance; use 'make enable-general'" >&2; exit 1; }
	@[[ -d "$(PROJECTS_DIR)/$(NAME)" ]] || { echo "no such project: $(PROJECTS_DIR)/$(NAME)" >&2; exit 1; }
	systemctl --user enable --now "claude-rc@$(NAME).service"

disable:
	@[[ -n "$(NAME)" ]] || { echo "usage: make disable NAME=<project>" >&2; exit 1; }
	systemctl --user disable --now "claude-rc@$(NAME).service"

enable-general:
	systemctl --user enable --now claude-rc-general.service

disable-general:
	systemctl --user disable --now claude-rc-general.service

check:
	@fail=0; \
	if command -v tmux >/dev/null; then echo "  ok       tmux $$(tmux -V | cut -d' ' -f2)"; \
	  else echo "  MISSING  tmux"; fail=1; fi; \
	if [[ -d "$(PROJECTS_DIR)" ]]; then echo "  ok       projects dir ($(PROJECTS_DIR))"; \
	  else echo "  MISSING  projects dir ($(PROJECTS_DIR))"; fail=1; fi; \
	if [[ -x "$(HOME)/.claude/local/claude" ]]; then echo "  ok       claude (~/.claude/local/claude)"; \
	  elif [[ -x "$(HOME)/.local/bin/claude" ]]; then echo "  ok       claude (~/.local/bin/claude)"; \
	  elif command -v claude >/dev/null; then echo "  ok       claude ($$(command -v claude)) -- only on your shell's PATH;" \
	    "systemd --user units use a minimal PATH and won't find it there. Set CLAUDE_BIN" \
	    "(see README) or symlink it into ~/.local/bin."; \
	  else echo "  MISSING  claude -- install it and run 'claude' once to log in"; fail=1; fi; \
	if [[ "$$(loginctl show-user "$$USER" -p Linger --value 2>/dev/null)" == "yes" ]]; then \
	  echo "  ok       linger enabled"; else echo "  todo     linger off (make install turns it on)"; fi; \
	exit $$fail

status:
	@systemctl --user --no-pager --legend=false list-units \
	  'claude-rc*' 2>/dev/null || true
	@echo
	@systemctl --user --no-pager list-timers claude-rc-healthcheck.timer 2>/dev/null || true

uninstall:
	@for f in $(SCRIPTS); do rm -f "$(BIN_DIR)/$$f"; done
	@for f in $(UNITS); do rm -f "$(UNIT_DIR)/$$f"; done
	@systemctl --user daemon-reload
	@echo "Symlinks removed. Instance enablement in claude-rc.target.wants/ was left"
	@echo "in place; run 'make disable NAME=<project>' first if you want it gone."
