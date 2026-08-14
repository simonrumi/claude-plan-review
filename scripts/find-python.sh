#!/usr/bin/env bash
# find-python.sh — resolve a working Python interpreter, rejecting Windows'
# Store-alias stub.
#
# On Windows, %LOCALAPPDATA%\Microsoft\WindowsApps\python.exe is a real file
# on PATH (an app-execution-alias placeholder) whenever Python isn't
# installed from python.org and the Store alias hasn't been disabled.
# `command -v python` / `command -v python3` happily find it and return its
# path, since command -v only checks PATH existence — it never runs the
# binary. Actually executing that stub does nothing useful (or opens the
# Microsoft Store), so a resolver that stops at "command -v found something"
# silently hands back a dead interpreter instead of erroring or falling
# through to a real one.
#
# Prints the path to a verified-working interpreter on stdout and exits 0,
# or prints nothing and exits 1 if none of the candidates actually run.
set -uo pipefail

try_candidate() {
  local bin="$1"
  [ -z "$bin" ] && return 1
  "$bin" -c "" >/dev/null 2>&1
}

for bin in "$(command -v python3 2>/dev/null || true)" "$(command -v python 2>/dev/null || true)"; do
  if try_candidate "$bin"; then
    printf '%s' "$bin"
    exit 0
  fi
done

exit 1
