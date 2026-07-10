#!/usr/bin/env bash
# scroll-trace.sh — runtime instrument for the LIVE per-keystroke editor jump.
#
# Builds the debug binary (DWARF embedded — lldb symbolicates directly, no dSYM)
# and drops you at an lldb prompt with the scroll/layout breakpoints armed
# (see scroll-trace.lldb). Stop guessing; measure who moves the viewport.
#
# Usage:   bash scripts/scroll-trace.sh
# Then at the (lldb) prompt:
#   run
#   → open a document, switch to EDITOR-ONLY mode, click in the text,
#     scroll so the caret is mid-screen (IN VIEW), type ONE character.
#   → watch the terminal: which marker fires, and the Pensieve frame above it.
#   → Ctrl-C then 'quit' (or just quit the app) to end.
set -euo pipefail

# SIGXFSZ guard: the harness shell caps file size at ~31MiB; a debug link can
# exceed it. Lift it so the build does not die on signal 25 (exit 153).
ulimit -f unlimited 2>/dev/null || true

cd "$(dirname "$0")/.."

echo "[scroll-trace] building debug (Pensieve/.build/debug/Pensieve)…"
( cd Pensieve && swift build )

BIN="Pensieve/.build/debug/Pensieve"
if [[ ! -x "$BIN" ]]; then
  echo "[scroll-trace] FATAL: $BIN not found after build" >&2
  exit 1
fi

echo
echo "[scroll-trace] launching lldb — at the (lldb) prompt type:  run"
echo "[scroll-trace] type ONE char with the caret IN VIEW; read the marker that fires."
echo
exec lldb -s scripts/scroll-trace.lldb "$BIN"
