#!/bin/bash
# Runs as a SessionStart hook subprocess, where CLAUDE_PROJECT_DIR and
# CLAUDE_PLUGIN_ROOT ARE reliably set (see Context — this is not true inside
# a command's own Bash tool calls, which is why this hook exists at all).
# Persists them under plugin-namespaced names via CLAUDE_ENV_FILE so every
# subsequent Bash tool call in the session — including the ones
# commands/review-plan.md issues — inherits them as ordinary exported vars.
#
# Idempotency guard (anthropics/claude-code#67067): SessionStart re-fires on
# resume/clear/compact, and CLAUDE_ENV_FILE is never truncated between
# re-fires, so an unguarded append would grow unboundedly and risks the
# torn-export-line Bash-tool wedging reported in anthropics/claude-code#78146.
# Skipping the write when our lines are already present caps this script's
# own contribution at exactly two lines for the life of the session.
#
# Lock guard (new round 2, agent_b): a bare "grep -q ... || append" is a
# check-then-act race — if this hook's own process is ever dispatched twice
# in close succession (e.g. rapid resume/clear/compact cycling), both
# invocations can pass the grep check before either has written, producing
# the exact duplicate/torn-line outcome the guard exists to prevent. #78146's
# own report describes two hook processes appending to CLAUDE_ENV_FILE
# concurrently and producing a torn line, so this is not a theoretical
# concern. A short-lived mkdir-based lock closes that race for THIS script's
# own writes (mkdir is atomic on both POSIX filesystems and NTFS via
# git-bash) — it does NOT, and cannot, protect against a *different*
# hook/plugin writing to the same CLAUDE_ENV_FILE without using the same
# lock; that remains an accepted residual risk, unchanged from the round 2
# Context addendum (anthropics/claude-code#78146 stays open upstream).
#
# Round 3 fix (agent_a): the round-2 version released the lock with an
# unconditional `rmdir` at the end, regardless of whether this invocation
# actually acquired it. Under exactly the contention scenario the lock
# exists for, that meant a process whose mkdir loop timed out (never holding
# the lock) would still `rmdir` on its way out — deleting a *different*,
# still-in-critical-section process's lock directory out from under it. A
# third invocation arriving at that moment could then `mkdir` successfully
# and run concurrently with the process that still believes it holds the
# lock, reopening the exact race the lock was added to close. Fixed by
# gating `rmdir` on a `LOCK_HELD` flag set only when this invocation's own
# `mkdir` succeeded — release is now symmetric with acquisition.
if [ -n "$CLAUDE_ENV_FILE" ]; then
  LOCK_DIR="${CLAUDE_ENV_FILE}.cpr.lock"
  i=0
  LOCK_HELD=0
  while [ "$i" -lt 20 ]; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_HELD=1
      break
    fi
    sleep 0.05
    i=$((i + 1))
  done
  # Falls through to the check-and-write below even if the lock could not be
  # acquired within ~1s — better to risk a rare duplicate line under extreme
  # contention than to leave CPR_PROJECT_ROOT/CPR_PLUGIN_ROOT unset and trip
  # Step 1's "hook hasn't run" guard for no real reason.
  if ! grep -q '^export CPR_PROJECT_ROOT=' "$CLAUDE_ENV_FILE" 2>/dev/null; then
    {
      echo "export CPR_PROJECT_ROOT=\"$CLAUDE_PROJECT_DIR\""
      echo "export CPR_PLUGIN_ROOT=\"$CLAUDE_PLUGIN_ROOT\""
    } >> "$CLAUDE_ENV_FILE"
  fi
  # Only release the lock if this invocation actually acquired it — see the
  # round 3 fix note above.
  if [ "$LOCK_HELD" -eq 1 ]; then
    rmdir "$LOCK_DIR" 2>/dev/null
  fi
fi
exit 0
