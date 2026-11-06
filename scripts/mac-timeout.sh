#!/usr/bin/env bash
# Run a command with a hard time limit (macOS has no `timeout`).
# Usage: scripts/mac-timeout.sh SECONDS command [args...]
# Exit status: the command's, or 124 on timeout.
set -uo pipefail
secs="$1"; shift
"$@" &
pid=$!
elapsed=0
while kill -0 "$pid" 2>/dev/null; do
  if (( elapsed >= secs * 2 )); then
    echo "TIMEOUT after ${secs}s: $*" >&2
    kill -TERM "$pid" 2>/dev/null
    sleep 3
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    exit 124
  fi
  sleep 0.5
  elapsed=$((elapsed + 1))
done
wait "$pid"
