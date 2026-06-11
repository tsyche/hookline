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
