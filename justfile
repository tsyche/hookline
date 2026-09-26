# Project task runner. Run `just --list` to see all available commands.

# Default: show available commands
default:
    @just --list

# Install hookline (hook, daemon, CLI, launchd registration)
install:
    bash install.sh

# Uninstall hookline (removes hook, daemon, launchd entry)
uninstall:
    bash uninstall.sh

# Send a test notification to verify hookline is wired up
test:
    bash scripts/test.sh

# Show config, daemon status, connectivity, recent log
status:
    hookline status

# Tail hook and daemon logs
logs:
    tail -f ~/.local/share/hookline/hookline.log ~/.local/share/hookline/daemon.log

# Start the background daemon
daemon-start:
    hookline daemon start

# Stop the background daemon
daemon-stop:
    hookline daemon stop

# Restart the background daemon
daemon-restart:
    hookline daemon restart

# Lint shell scripts (shellcheck) and syntax-check the Python daemon
lint:
    @command -v shellcheck >/dev/null || { echo "shellcheck not installed — run: brew install shellcheck"; exit 1; }
    shellcheck hooks/hookline.sh hooks/core.sh hooks/adapters/*.sh install.sh uninstall.sh hookline scripts/*.sh
    /usr/bin/python3 -m py_compile daemon/hookline-daemon
    @echo "lint ok"

# Auto-fix is a no-op for shell (shellcheck has no fixer) — kept as convention alias
lintfix: lint

# Golden stdout tests for the hook entry point (sandboxed, no network)
golden:
    bash scripts/hook-golden.sh

# Sync CLAUDE.md <-> AGENTS.md (copy whichever is newer onto the other)
sync-docs:
    @if [ AGENTS.md -nt CLAUDE.md ]; then cp AGENTS.md CLAUDE.md && echo "synced AGENTS.md -> CLAUDE.md"; \
     elif [ CLAUDE.md -nt AGENTS.md ]; then cp CLAUDE.md AGENTS.md && echo "synced CLAUDE.md -> AGENTS.md"; \
     else echo "already in sync"; fi

# Validate documentation claims (agent-doc sync, justfile/README consistency)
check-docs:
    ./scripts/check-docs.sh

# Remove build/test artifacts
clean:
    rm -rf daemon/__pycache__ __pycache__

# Full reset: clean + reinstall
fresh: clean install
