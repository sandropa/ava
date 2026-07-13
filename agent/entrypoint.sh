#!/usr/bin/env bash
set -euo pipefail
# We are the child of `agent-vault run`, so HTTP(S)_PROXY + the MITM CA are in
# this env. Start a detached tmux server (it inherits the brokered env) and park
# PID 1 on wait-for. `docker compose exec agent tmux attach -t work` then drops
# you into a shell where opencode/git/gh are all routed through the vault.
tmux new-session -d -s work
exec tmux wait-for keepalive
