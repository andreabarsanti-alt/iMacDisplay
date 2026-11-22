#!/bin/bash
# Claude Code PreToolUse hook: blocks every tool call while a STOP file exists
# in the repo root. Create it from either Mac with `touch STOP`; remove to resume.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$ROOT/STOP" ]; then
  echo "STOP file present in $ROOT: agent halted. Remove it to resume." >&2
  exit 2
fi
exit 0
