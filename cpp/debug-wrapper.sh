#!/bin/bash
# Debug wrapper: logs all stdin/stdout/stderr between Claude Code and the MCP server
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$SCRIPT_DIR/mcp-debug.log"
BIN="$SCRIPT_DIR/build/screen-capture-mcp"

echo "=== Session started: $(date) ===" >> "$LOG"

# Use tee to capture stdin/stdout while passing through
exec > >(tee -a "$LOG.stdout") 2>>"$LOG.stderr"
exec < <(tee -a "$LOG.stdin")

"$BIN" 2>>"$LOG.stderr"
EXIT_CODE=$?
echo "=== Session ended: $(date), exit=$EXIT_CODE ===" >> "$LOG"
