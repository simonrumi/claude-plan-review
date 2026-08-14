#!/usr/bin/env bash
# session-init.sh — initialise a new plan-review session
#
# Usage:
#   session-init.sh <project-root> <plan-path> <plan-name>
#
# Arguments:
#   <project-root>  Absolute path to the project the session should be
#                    created under (resolved by the calling command from
#                    CPR_PROJECT_ROOT — see commands/review-plan.md Step 1)
#   <plan-path>      Absolute or relative (to <project-root>) path to the
#                    input plan file
#   <plan-name>      Short label (no spaces) recorded in state.json
#
# Outputs (to stdout, one per line):
#   SESSION_ID=plan-review-YYYY-MM-DD-NNN
#   SESSION_DIR=plans/sessions/plan-review-YYYY-MM-DD-NNN
#   STATE_FILE=plans/sessions/plan-review-YYYY-MM-DD-NNN/state.json
#
# Side effects:
#   Creates plans/sessions/<session-id>/
#   Copies plan to plans/sessions/<session-id>/plan-v0.md
#   Writes plans/sessions/<session-id>/state.json
#
# This script is bundled inside the claude-plan-review plugin and is invoked
# via an explicit `bash "${PLUGIN_ROOT}/scripts/session-init.sh" ...` call
# from commands/review-plan.md — it is not run from a fixed location, so the
# project root is passed in as an explicit argument rather than derived from
# this script's own location.

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve Python (no jq on this machine)
# ---------------------------------------------------------------------------
PYTHON_BIN=""
if command -v jq &>/dev/null && jq --version &>/dev/null 2>&1; then
  USE_JQ=1
else
  USE_JQ=0
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PYTHON_BIN=$(bash "$SCRIPT_DIR/find-python.sh")
  if [ -z "$PYTHON_BIN" ]; then
    echo "ERROR: neither jq nor a working Python installation found (Windows Store alias stubs are detected and rejected, not just PATH lookups)" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------
if [ "$#" -ne 3 ]; then
  echo "Usage: $(basename "$0") <project-root> <plan-path> <plan-name>" >&2
  exit 1
fi

PROJECT_ROOT="$1"
PLAN_PATH="$2"
PLAN_NAME="$3"

if [ ! -d "$PROJECT_ROOT" ]; then
  echo "ERROR: project root not found or not a directory: $PROJECT_ROOT" >&2
  exit 1
fi

# Resolve plan path relative to PROJECT_ROOT if not absolute
if [[ "$PLAN_PATH" != /* ]]; then
  PLAN_PATH="$PROJECT_ROOT/$PLAN_PATH"
fi

if [ ! -f "$PLAN_PATH" ]; then
  echo "ERROR: plan file not found: $PLAN_PATH" >&2
  exit 1
fi

if [ ! -s "$PLAN_PATH" ]; then
  echo "ERROR: plan file is empty: $PLAN_PATH" >&2
  exit 1
fi

if [[ "$PLAN_NAME" =~ [[:space:]] ]]; then
  echo "ERROR: plan-name must not contain spaces: '$PLAN_NAME'" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 1 — Generate session ID
# ---------------------------------------------------------------------------
TODAY="$(date -u +%Y-%m-%d)"
SESSIONS_DIR="$PROJECT_ROOT/plans/sessions"
mkdir -p "$SESSIONS_DIR"

# Find existing sessions for today and determine next NNN
MAX_NNN=0
for dir in "$SESSIONS_DIR"/plan-review-"$TODAY"-*/; do
  if [ -d "$dir" ]; then
    # Extract the NNN suffix (last 3 chars of directory basename)
    BASENAME="$(basename "$dir")"
    NNN_STR="${BASENAME##*-}"
    # Strip leading zeros for arithmetic, guard against non-numeric
    if [[ "$NNN_STR" =~ ^[0-9]+$ ]]; then
      NNN_INT=$(( 10#$NNN_STR ))
      if [ "$NNN_INT" -gt "$MAX_NNN" ]; then
        MAX_NNN=$NNN_INT
      fi
    fi
  fi
done

NEXT_NNN=$(( MAX_NNN + 1 ))
SESSION_NNN="$(printf '%03d' "$NEXT_NNN")"
SESSION_ID="plan-review-${TODAY}-${SESSION_NNN}"

# ---------------------------------------------------------------------------
# Step 2 — Create session directory
# ---------------------------------------------------------------------------
SESSION_DIR_ABS="$SESSIONS_DIR/$SESSION_ID"
mkdir -p "$SESSION_DIR_ABS"

# ---------------------------------------------------------------------------
# Step 3 — Copy plan to plan-v0.md
# ---------------------------------------------------------------------------
PLAN_V0="$SESSION_DIR_ABS/plan-v0.md"
cp "$PLAN_PATH" "$PLAN_V0"

# ---------------------------------------------------------------------------
# Step 4 — Compute SHA-256 of plan-v0.md
# ---------------------------------------------------------------------------
PLAN_HASH="$( (command -v sha256sum >/dev/null 2>&1 && sha256sum "$PLAN_V0" | awk '{print $1}') || shasum -a 256 "$PLAN_V0" | awk '{print $1}')"

# ---------------------------------------------------------------------------
# Step 5 — Write initial state.json
# ---------------------------------------------------------------------------
STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
STATE_FILE_ABS="$SESSION_DIR_ABS/state.json"

# Relative paths from project root
SESSION_DIR_REL="plans/sessions/$SESSION_ID"
PLAN_V0_REL="$SESSION_DIR_REL/plan-v0.md"
STATE_FILE_REL="$SESSION_DIR_REL/state.json"

if [ "$USE_JQ" = "1" ]; then
  jq -n \
    --arg session_id "$SESSION_ID" \
    --arg plan_name "$PLAN_NAME" \
    --arg started_at "$STARTED_AT" \
    --arg current_plan_path "$PLAN_V0_REL" \
    --arg plan_v0_path "$PLAN_V0_REL" \
    --arg plan_hash "$PLAN_HASH" \
    '{
      session_id: $session_id,
      plan_name: $plan_name,
      started_at: $started_at,
      status: "running",
      current_plan_path: $current_plan_path,
      current_round: 0,
      max_rounds: 8,
      min_rounds: 2,
      version_counter: 0,
      plan_versions: [
        {
          version: 0,
          path: $plan_v0_path,
          hash: $plan_hash,
          produced_by: "human"
        }
      ],
      rounds: [],
      all_hashes_seen: [$plan_hash],
      unresolved_concerns: [],
      contested_sections: {},
      escalation_reason: null,
      arbiter_response: null
    }' > "$STATE_FILE_ABS"
else
  # Pass values via environment variables to avoid heredoc interpolation issues
  # (paths containing slashes can break string interpolation in heredocs)
  SESSION_ID_VAL="$SESSION_ID" \
  PLAN_NAME_VAL="$PLAN_NAME" \
  STARTED_AT_VAL="$STARTED_AT" \
  PLAN_V0_REL_VAL="$PLAN_V0_REL" \
  PLAN_HASH_VAL="$PLAN_HASH" \
  STATE_FILE_ABS_VAL="$STATE_FILE_ABS" \
  "$PYTHON_BIN" -c '
import json, os

state = {
    "session_id": os.environ["SESSION_ID_VAL"],
    "plan_name": os.environ["PLAN_NAME_VAL"],
    "started_at": os.environ["STARTED_AT_VAL"],
    "status": "running",
    "current_plan_path": os.environ["PLAN_V0_REL_VAL"],
    "current_round": 0,
    "max_rounds": 8,
    "min_rounds": 2,
    "version_counter": 0,
    "plan_versions": [
        {
            "version": 0,
            "path": os.environ["PLAN_V0_REL_VAL"],
            "hash": os.environ["PLAN_HASH_VAL"],
            "produced_by": "human"
        }
    ],
    "rounds": [],
    "all_hashes_seen": [os.environ["PLAN_HASH_VAL"]],
    "unresolved_concerns": [],
    "contested_sections": {},
    "escalation_reason": None,
    "arbiter_response": None
}

with open(os.environ["STATE_FILE_ABS_VAL"], "w") as f:
    json.dump(state, f, indent=2)
'
fi

# ---------------------------------------------------------------------------
# Step 6 — Emit output variables to stdout
# ---------------------------------------------------------------------------
echo "SESSION_ID=$SESSION_ID"
echo "SESSION_DIR=$SESSION_DIR_REL"
echo "STATE_FILE=$STATE_FILE_REL"
