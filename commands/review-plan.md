# review-plan

Usage: `/review-plan <plan-path> <plan-name>`

Orchestrates a dual-AI plan review loop. Two sub-agents (Agent A and Agent B) alternate reviewing and improving a plan document until they converge (both report no changes, no open concerns) or until cycle/max-round escalation occurs.

**You are the orchestrator.** Follow every step below exactly. Do not make architectural decisions not covered here — if something is genuinely ambiguous, halt and surface the question to the human before proceeding.

---

## Step 1: Parse Arguments and Initialize Session

Resolve the project and plugin roots before anything else — the `--cleanup` branch needs these too:

```bash
if [ -z "$CPR_PROJECT_ROOT" ] || [ -z "$CPR_PLUGIN_ROOT" ]; then
  echo "ERROR: CPR_PROJECT_ROOT/CPR_PLUGIN_ROOT are not set." >&2
  echo "This plugin's SessionStart hook hasn't run for this session yet —" >&2
  echo "restart Claude Code (or start a new session) after installing or" >&2
  echo "updating claude-plan-review, then retry." >&2
  exit 1
fi

# Two inlined copies, not one shared function taking $1 — Claude Code's
# slash-command argument substitution replaces literal "$1"/"$2"/etc. tokens
# anywhere in this file's rendered text, including inside an ordinary bash
# function's own positional parameter, before the model ever sees it (no
# code-fence awareness, no documented escape). A shared normalize_path("$1")
# function is exactly the shape that collides with that mechanism; closing
# over each already-named variable directly removes the collision surface
# entirely instead of trying to survive it.
normalize_project_root() {
  local p="$CPR_PROJECT_ROOT"
  # Regex must live in a variable, not inline in [[ =~ ]] — on some bash
  # builds (confirmed: Cygwin/MSYS 5.3.9) an inline [\\/] silently fails to
  # match a literal backslash. Same builds also mis-parse the parameter-
  # expansion form ${var//\\//}, deleting every forward slash instead of
  # converting backslashes — so backslash-to-slash conversion goes through
  # tr, which doesn't have this problem on any tested platform.
  local drive_re='^([A-Za-z]):[\\/](.*)$'
  if [[ "$p" =~ $drive_re ]]; then
    local drive="${BASH_REMATCH[1],,}"
    local rest
    rest="$(printf '%s' "${BASH_REMATCH[2]}" | tr '\\' '/' 2>/dev/null)"
    printf '/%s/%s' "$drive" "$rest"
  else
    printf '%s' "$(printf '%s' "$p" | tr '\\' '/' 2>/dev/null)"
  fi
}

normalize_plugin_root() {
  local p="$CPR_PLUGIN_ROOT"
  local drive_re='^([A-Za-z]):[\\/](.*)$'
  if [[ "$p" =~ $drive_re ]]; then
    local drive="${BASH_REMATCH[1],,}"
    local rest
    rest="$(printf '%s' "${BASH_REMATCH[2]}" | tr '\\' '/' 2>/dev/null)"
    printf '/%s/%s' "$drive" "$rest"
  else
    printf '%s' "$(printf '%s' "$p" | tr '\\' '/' 2>/dev/null)"
  fi
}

PROJECT_ROOT="$(normalize_project_root)"
PLUGIN_ROOT="$(normalize_plugin_root)"
echo "PROJECT_ROOT=$PROJECT_ROOT"
echo "PLUGIN_ROOT=$PLUGIN_ROOT"
```

Check for `--cleanup` flag first. If the first argument is `--cleanup`:
1. Validate that a session-id argument follows. If missing, report "Usage: /review-plan --cleanup <session-id>" and halt.
2. Validate session-id format: must match `^plan-review-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{3}$` (alphanumeric and hyphens only, no path separators, no `..` sequences). If the value does not match, report "Invalid session-id format" and halt.
3. Check for optional `--force` flag: from remaining arguments (after `<session-id>`), scan for the literal string `--force`. If present, remove it from the remaining arguments and set `FORCE=true`; otherwise `FORCE=false`. After removing `--force`, if any arguments still remain, they are unrecognized — report "Unrecognized argument: <arg>" for the first such argument and halt. (Scan for `--force` before checking for unrecognized arguments, so that `--force` is never misidentified as an unrecognized argument.)
4. Jump directly to the **Cleanup Procedure** section. Skip the normal review flow entirely.

If `--cleanup` is not present, fall through to the existing two-argument positional parse:

The user's message will be of the form: `/review-plan <plan-path> <plan-name>`

Extract:
- `PLAN_PATH` — the first argument (absolute or relative path to the input plan)
- `PLAN_NAME` — the second argument (short label, no spaces)

If either argument is missing, report the error and halt.

Run session initialization:

```bash
bash "${PLUGIN_ROOT}/scripts/session-init.sh" "$PROJECT_ROOT" "$PLAN_PATH" "$PLAN_NAME"
```

The script prints three lines to stdout in this exact format:
```
SESSION_ID=plan-review-YYYY-MM-DD-NNN
SESSION_DIR=plans/sessions/plan-review-YYYY-MM-DD-NNN
STATE_FILE=plans/sessions/plan-review-YYYY-MM-DD-NNN/state.json
```

Parse each line by splitting on `=`. Extract:
- `SESSION_ID` — value after `SESSION_ID=`
- `SESSION_DIR_REL` — value after `SESSION_DIR=`
- `STATE_FILE_REL` — value after `STATE_FILE=`

If the script fails (non-zero exit), report the error output and halt.

---

## Step 2: Load Initial State

Read `state.json` from the path `STATE_FILE_REL` (relative to project root `$PROJECT_ROOT`). Parse it as JSON and extract the following loop variables:

- `min_rounds` — integer (default 2)
- `max_rounds` — integer (default 8)
- `V` — set to the value of `version_counter` (0 at session start)
- `current_plan_path` — string path to `plan-v0.md` (relative)
- `round` — set to 1 (loop starts at round 1)
- `unresolved_concerns` — array (empty at start)
- `prior_b_response` — set to `null` (no Agent B has run yet)

Report to the human: `Session initialized: SESSION_ID, plan: PLAN_NAME. Beginning review loop (min_rounds=N, max_rounds=N).`

---

## Main Loop

Repeat the following steps for each round, starting at `round = 1`.

---

### Round Start

Compute `round_context`:
- If `round <= min_rounds`: `round_context = "early"`
- If `round > min_rounds`: `round_context = "late"`

Report to the human: `--- Round ROUND starting (round_context=ROUND_CONTEXT) ---`

---

### Step 3: Pre-Agent-A Size Check

Compute word count of `current_plan_path`:
```bash
wc -w < "$PROJECT_ROOT/$current_plan_path"
```

Build the Agent A JSON input payload (see "Agent Input Payload Construction" below) using `prior_b_response` as `prior_reviewer_response` and `quality_failure: null`.

Compute estimated token count:
```
estimated_tokens = (word_count * 1.3) + (len(json_payload_string) / 4)
```

Use inline Python to compute this. If `estimated_tokens > 80000`, report:
`WARNING: Estimated input size (N tokens) exceeds 80k threshold. Halting to avoid context overflow. Human action required.`
Write state with `status: "escalated"`, `escalation_reason: "pre_spawn_size_exceeded"` (see "State Write Pattern") and halt.

---

### Step 4: Spawn Agent A

Increment V: `V = V + 1`

Assign:
- `output_path_a = SESSION_DIR_REL + "/plan-v" + str(V) + ".md"`

Build the Agent A input payload JSON (see "Agent Input Payload Construction"):
```json
{
  "round": <round>,
  "reviewer": "agent_a",
  "round_context": "<round_context>",
  "current_plan_path": "<current_plan_path>",
  "output_plan_path": "<output_path_a>",
  "prior_reviewer_response": <prior_b_response or null>,
  "unresolved_concerns": <unresolved_concerns array>,
  "quality_failure": null
}
```

Build the agent prompt (see "How to Spawn a Review Agent" below).

Use the Agent tool to spawn Agent A. Capture the agent's final text output as `agent_a_raw`.

**File existence check:** Verify that the file at `output_path_a` (relative to project root) exists and is non-empty:
```bash
test -s "$PROJECT_ROOT/$output_path_a" && echo "ok" || echo "missing"
```
If missing: perform one retry (see "Retry Procedure"). If retry also fails: write escalated state with `escalation_reason: "agent_a_file_missing_after_retry"` and halt.

**Phase structure check (Check 6):** Run Check 6 (see "Quality Check Procedure") on `output_path_a`. If Check 6 fails: perform one retry with the `phase_structure` failure object. If retry also fails: write escalated state with `escalation_reason: "agent_a_quality_failure_after_retry"` and halt.

**Extract post-edit section list:** After the file existence check and Check 6 both pass, extract the section list from `output_path_a` — the plan Agent A just wrote — NOT from `current_plan_path`:
```bash
grep -E "^## " "$PROJECT_ROOT/$output_path_a"
```
Store as `section_list_a` (array of header strings, with `## ` prefix stripped). This must be re-extracted fresh for a retry attempt too, from the retry's own output path — never reuse the section list computed for the original attempt (see "Retry Procedure").

**JSON parse:** Attempt to parse `agent_a_raw` as JSON. If strict `json.loads` fails, attempt to extract JSON using `re.search(r'\{.*\}', agent_a_raw, re.DOTALL)` — agents occasionally prefix their JSON with a prose sentence. If extraction succeeds, use the extracted JSON. If both fail: perform one retry with `quality_failure: {"check": "json_parse_error", "detail": "Response could not be parsed as JSON. Excerpt: <first 200 chars of agent_a_raw>"}`. If retry also fails: write escalated state with `escalation_reason: "agent_a_json_parse_error_after_retry"` and halt.

Store parsed response as `agent_a_response`.

**Quality check:** Apply all 5 quality checks to `agent_a_response` using `section_list_a` (see "Quality Check Procedure"). If any check fails: perform one retry with the `quality_failure` object describing the failure. If retry also fails: write escalated state with `escalation_reason: "agent_a_quality_failure_after_retry"` and halt.

---

### Step 5a: Update Unresolved Concerns (After Agent A)

Run inline Python to update `unresolved_concerns` in memory. Follow this logic exactly:

**Apply section renames first:** Before any add/risk-accept/resolve logic, if `agent_a_response["section_renames"]` is non-empty, build `rename_map = {item["from"]: item["to"] for item in section_renames if item["from"] and item["to"] and item["from"] != item["to"]}` and rewrite `entry["section"]` for EVERY entry in `unresolved_concerns` (regardless of `raised_by`) from old name to new name per `rename_map`, in place. This permanently migrates concerns raised under a now-folded section name to the section that replaced it.

**Add new concerns from Agent A:**
For each item in `agent_a_response["open_concerns"]`:
- If `risk_accepted == false`
- AND no existing entry in `unresolved_concerns` has matching `(section, raised_by="agent_a")`
- Then append: `{"section": item["section"], "description": item["description"], "severity": item["severity"], "raised_by": "agent_a", "raised_in_round": round}`

**Risk-accept Agent A's own prior concerns:**
For each entry in `unresolved_concerns` where `raised_by == "agent_a"`:
- If Agent A includes that section in `open_concerns` with `risk_accepted == true`
- Then remove from `unresolved_concerns`

**Resolve Agent A's concerns by change or approval:**
For each entry in `unresolved_concerns` where `raised_by == "agent_a"`:
- If the entry's section is NOT in Agent A's `open_concerns` this round
- AND (Agent A has a `changes` entry for that section OR an `approvals` entry for that section)
- Then remove from `unresolved_concerns`

---

### Step 5b: Partial State Write (After Agent A)

Compute the SHA-256 hash of `output_path_a`:
```bash
(command -v sha256sum >/dev/null 2>&1 && sha256sum "$PROJECT_ROOT/$output_path_a" | cut -d' ' -f1) || shasum -a 256 "$PROJECT_ROOT/$output_path_a" | cut -d' ' -f1
```
Store as `agent_a_hash`.

Check for hash cycle: if `agent_a_hash` is already in `all_hashes_seen`, set `hash_cycle_a = true`. Otherwise `hash_cycle_a = false`.

Append `agent_a_hash` to `all_hashes_seen`.

Append to `plan_versions`:
```json
{"version": V, "path": "SESSION_DIR_REL/plan-vV.md", "hash": "<agent_a_hash>", "produced_by": "agent_a_round_N"}
```

**Apply section renames to contested_sections first:** Before appending this round's new changes, if `agent_a_response["section_renames"]` is non-empty, for each `{from, to}` pair (excluding no-op renames where `from == to`), merge `contested_sections[from]`'s history array into `contested_sections[to]` (creating `to` as a new key if it does not already exist) and remove the `from` key.

Update `contested_sections` from Agent A's changes: for each item in `agent_a_response["changes"]`, append to `contested_sections[item["section"]]`:
```json
{"round": round, "agent": "agent_a", "action": "changed", "description": item["description"]}
```
If the section key does not exist yet, create it as an empty array first.

Write state using the "State Write Pattern" below, updating these fields:
- `version_counter`: V
- `plan_versions`: updated list
- `all_hashes_seen`: updated list
- `rounds[round-1].agent_a_response`: `agent_a_response` (see rounds array management below)
- `contested_sections`: updated dict
- `unresolved_concerns`: updated list from Step 5a

**Rounds array management:** Before writing, check if a round entry for this round number already exists in the `rounds` array. If it does (from a previous partial write), update it in place. If not, append `{"round": round, "agent_a_response": null, "agent_b_response": null}` and then set the `agent_a_response` field.

---

### Step 5c: Mid-Round Cycle Check

Check for semantic cycle in `contested_sections` (see "Semantic Cycle Detection" below). Store result as `semantic_cycle_a`.

A hash cycle is only a meaningful oscillation signal if the agent reports it made changes — when `agent_a_response["has_changes"] == false`, identical output on consecutive rounds is the expected signature of convergence, not a cycle. `all_hashes_seen` is still appended unconditionally elsewhere (Step 5b) — only the escalation trigger below is gated. Semantic cycle detection is unaffected by this guard (it is a separate mechanism and stays unguarded).

If `(hash_cycle_a == true AND agent_a_response["has_changes"] == true) OR semantic_cycle_a == true`:

1. Write pre-Arbiter state: update only `status = "cycle_detected"` and `current_plan_path = output_path_a` in the state file using inline Python (read state, update those two fields, write back). Do NOT call the full state write — just patch these two fields.

2. Spawn the Arbiter (see "How to Spawn the Arbiter"). The Arbiter writes its plan to `SESSION_DIR_REL/plan-arbiter.md`.

3. Write post-Arbiter state: write all current fields plus `arbiter_response = <arbiter_response>`, `status = "escalated"`, `escalation_reason = "cycle_detected"`, `arbiter_plan_path = SESSION_DIR_REL/plan-arbiter.md`.

4. Surface to human:
   ```
   CYCLE DETECTED (mid-round, after Agent A, round ROUND).
   Arbiter has produced a resolved plan at: SESSION_DIR_REL/plan-arbiter.md
   Arbiter response: <arbiter_response JSON>
   Unresolved concerns: <unresolved_concerns>
   Human action required. Session: SESSION_ID
   ```
5. Halt.

---

### Step 6: Pre-Agent-B Size Check

Compute word count of `output_path_a` and build Agent B's JSON input payload (see below). Estimate tokens using the same formula. If `> 80000`, write escalated state with `escalation_reason: "pre_spawn_size_exceeded"` and halt with warning.

---

### Step 7: Spawn Agent B

Increment V: `V = V + 1`

Assign:
- `output_path_b = SESSION_DIR_REL + "/plan-v" + str(V) + ".md"`

Build the Agent B input payload JSON:
```json
{
  "round": <round>,
  "reviewer": "agent_b",
  "round_context": "<round_context>",
  "current_plan_path": "<output_path_a>",
  "output_plan_path": "<output_path_b>",
  "prior_reviewer_response": <agent_a_response>,
  "unresolved_concerns": <unresolved_concerns after Step 5a>,
  "quality_failure": null
}
```

Build the agent prompt (see "How to Spawn a Review Agent" below).

Use the Agent tool to spawn Agent B. Capture the agent's final text output as `agent_b_raw`.

Apply the same file existence check and Check 6 (phase structure) flow as Step 4, but for Agent B. Once both pass, extract the post-edit section list fresh from `output_path_b` — the plan Agent B just wrote — NOT from `output_path_a` (Agent B's input):
```bash
grep -E "^## " "$PROJECT_ROOT/$output_path_b"
```
Store as `section_list_b`. This must be re-extracted fresh for a retry attempt too, from the retry's own output path — never reuse the section list computed for the original attempt (see "Retry Procedure").

Then apply the same JSON parse and quality check flow as Step 4, but for Agent B using this freshly-extracted `section_list_b`. Escalation reason prefixes: `agent_b_*`.

Store parsed response as `agent_b_response`.

---

### Step 10: Update Unresolved Concerns (After Agent B)

Run inline Python to update `unresolved_concerns`. Same logic as Step 5a but for Agent B:

**Apply section renames first:** Same as Step 5a — before any add/risk-accept/resolve logic, if `agent_b_response["section_renames"]` is non-empty, build the rename map and rewrite `entry["section"]` for EVERY entry in `unresolved_concerns` (regardless of `raised_by`) from old name to new name.

**Add new concerns from Agent B:**
For each item in `agent_b_response["open_concerns"]`:
- If `risk_accepted == false`
- AND no existing entry in `unresolved_concerns` has matching `(section, raised_by="agent_b")`
- Then append: `{"section": item["section"], "description": item["description"], "severity": item["severity"], "raised_by": "agent_b", "raised_in_round": round}`

**Risk-accept Agent B's own prior concerns:**
For each entry in `unresolved_concerns` where `raised_by == "agent_b"`:
- If Agent B includes that section in `open_concerns` with `risk_accepted == true`
- Then remove from `unresolved_concerns`

**Resolve Agent B's concerns by change or approval:**
For each entry in `unresolved_concerns` where `raised_by == "agent_b"`:
- If the entry's section is NOT in Agent B's `open_concerns` this round
- AND (Agent B has a `changes` entry for that section OR an `approvals` entry for that section)
- Then remove from `unresolved_concerns`

---

### Step 11: Full State Write (After Agent B)

Compute the SHA-256 hash of `output_path_b`:
```bash
(command -v sha256sum >/dev/null 2>&1 && sha256sum "$PROJECT_ROOT/$output_path_b" | cut -d' ' -f1) || shasum -a 256 "$PROJECT_ROOT/$output_path_b" | cut -d' ' -f1
```
Store as `agent_b_hash`.

Check for hash cycle: if `agent_b_hash` is already in `all_hashes_seen`, set `hash_cycle_b = true`. Otherwise `hash_cycle_b = false`.

Append `agent_b_hash` to `all_hashes_seen`.

Append to `plan_versions`:
```json
{"version": V, "path": "SESSION_DIR_REL/plan-vV.md", "hash": "<agent_b_hash>", "produced_by": "agent_b_round_N"}
```

**Apply section renames to contested_sections first:** Same as Step 5b — before appending this round's new changes, if `agent_b_response["section_renames"]` is non-empty, merge `contested_sections[from]` into `contested_sections[to]` for each rename pair (excluding no-op renames), creating `to` if absent and removing `from`.

Update `contested_sections` from Agent B's changes: same pattern as Step 5b.

Write full state (see "State Write Pattern"), updating all of:
- `version_counter`: V
- `current_plan_path`: `output_path_b`
- `current_round`: round
- `plan_versions`: updated list
- `all_hashes_seen`: updated list
- `rounds[round-1].agent_b_response`: `agent_b_response`
- `contested_sections`: updated dict
- `unresolved_concerns`: updated list from Step 10

---

### Step 12: Convergence Check

If ALL of the following are true:
- `agent_a_response["has_changes"] == false`
- `agent_b_response["has_changes"] == false`
- `unresolved_concerns` is empty
- `round >= min_rounds`

Then:
1. Write state with `status = "converged"`.
2. Surface to human:
   ```
   CONVERGED after ROUND round(s).
   Final plan: SESSION_DIR_REL/plan-vV.md
   Session: SESSION_ID
   Both agents report no further changes and no open concerns.
   ```
3. Halt.

---

### Step 13: Post-Agent-B Cycle Check

Check for semantic cycle in `contested_sections`. Store as `semantic_cycle_b`.

Same guard as Step 5c: a hash cycle is only a meaningful oscillation signal if the agent reports it made changes — when `agent_b_response["has_changes"] == false`, identical output on consecutive rounds is the expected signature of convergence, not a cycle. `all_hashes_seen` is still appended unconditionally elsewhere (Step 11) — only the escalation trigger below is gated. Semantic cycle detection is unaffected (separate mechanism, stays unguarded).

If `(hash_cycle_b == true AND agent_b_response["has_changes"] == true) OR semantic_cycle_b == true`:

1. Write `status = "cycle_detected"` inline (patch only) to state.
2. Spawn the Arbiter (same procedure as Step 5c, but `current_plan_path = output_path_b`).
3. Write post-Arbiter state with `status = "escalated"`, `escalation_reason = "cycle_detected"`, `arbiter_plan_path`, `arbiter_response`.
4. Surface to human (same format as Step 5c but noting "post-round detection after Agent B").
5. Halt.

---

### Step 14: Max Rounds Check

If `round >= max_rounds`:
1. Write state with `status = "escalated"`, `escalation_reason = "max_rounds_reached"`.
2. Surface to human:
   ```
   MAX ROUNDS REACHED (ROUND rounds completed).
   Current plan: SESSION_DIR_REL/plan-vV.md
   Unresolved concerns: <unresolved_concerns>
   Session: SESSION_ID — human review required.
   ```
3. Halt.

---

### Step 15: Advance Round

Set `prior_b_response = agent_b_response`.
Set `current_plan_path = output_path_b`.
Increment `round = round + 1`.
Go to Round Start.

---

## Quality Check Procedure

Apply all 5 checks to an agent response JSON object. Use the agent's `section_list` — extracted from the plan file the agent just PRODUCED as its own output (`output_path_a` for Agent A, `output_path_b` for Agent B), never from the plan file the agent received as input (`current_plan_path`). The checks are listed below; on the first failure, return a `quality_failure` object and stop checking.

### Check 1: Engagement

**Failure condition:** `approvals` is empty AND `has_changes == false`

Failure object:
```json
{"check": "engagement", "detail": "approvals is empty and has_changes is false — no sections were explicitly approved"}
```

### Check 2: Minimum Content

**Failure condition:** `len(changes) + len(approvals) + len(open_concerns) < 3`

Failure object:
```json
{"check": "minimum_content", "detail": "Response has only N items across changes, approvals, and open_concerns — minimum is 3"}
```

### Check 3: Convergence Consistency

**Failure condition:** `has_changes == false` AND any item in `open_concerns` has `risk_accepted == false`

Failure object:
```json
{"check": "convergence_consistency", "detail": "has_changes is false but open_concerns contains items with risk_accepted: false — agent cannot converge while holding unaccepted concerns"}
```

### Check 4: Specificity

Check each item in `approvals`. The `section` field must match one of the names in `section_list` (exact string match after stripping whitespace). Items in `changes` are exempt from this check — an agent may introduce new sections.

Also check that every item in `changes` and `approvals` has a non-empty `reasoning` field.

**Failure condition (unknown section):**
```json
{"check": "specificity", "detail": "approvals references section 'X' which is not in the current section list: [list of section names]"}
```

**Failure condition (missing reasoning):**
```json
{"check": "specificity", "detail": "changes/approvals item for section 'X' is missing a reasoning field"}
```

**4d — section_renames target validation:** Check each item in `section_renames`. The `to` field must match one of the names in `section_list` (same exact-match rule as approvals). `from` is exempt from this check — it names a section expected to no longer be present.

**Failure condition (rename target not in current plan):**
```json
{"check": "specificity", "detail": "section_renames maps to 'X' which is not in the current plan"}
```

**4e — section_renames completeness validation:** Every item in `section_renames` must have a non-empty `from` field and a non-empty `reasoning` field.

**Failure condition (missing from/reasoning):**
```json
{"check": "specificity", "detail": "A section_renames item is missing a 'from' or reasoning field"}
```

### Check 5: Regression

This check applies only to concerns the current agent raised in previous rounds. Look up in `unresolved_concerns` all entries where `raised_by` matches the current agent's reviewer ID.

Build `rename_map` from this round's `section_renames`: `{item["from"]: item["to"] for item in section_renames}` (entries with empty `from`/`to` excluded).

For each such concern (matching on `section` field), compute `renamed_section = rename_map.get(section, section)`:
- If neither the concern's literal `section` NOR its `renamed_section` is in the agent's `open_concerns` this round
- AND the agent has no `changes` entry targeting either name
- AND the agent has no `approvals` entry targeting either name
- Then this is a regression failure.

In other words, a concern resolves this round if it is addressed (restated, changed, or approved) under EITHER its original section name OR the name it was renamed to per this round's `section_renames`.

Failure object:
```json
{"check": "regression", "detail": "Concern about section 'X' raised by this agent in round N is absent from open_concerns, changes, and approvals — it must be restated, resolved, or risk-accepted"}
```

### Check 6: Phase Structure

> This check validates the output plan file, not the response JSON. It runs after the file existence check and before the JSON parse.

**Pass 1 — phase headers present:**
```bash
grep -cE "^## Phase [0-9]+" "$PROJECT_ROOT/$output_plan_path"
```
where `$output_plan_path` is the path assigned for this agent's output (e.g., `output_path_a` in Step 4).

Failure condition: count is 0.

**Pass 2 — required subsections present:**

Run three additional greps on the output plan file:
```bash
grep -cE "^### Build$" "$PROJECT_ROOT/$output_plan_path"
grep -cE "^### Code Review$" "$PROJECT_ROOT/$output_plan_path"
grep -cE "^### Test$" "$PROJECT_ROOT/$output_plan_path"
```

Each count must be ≥ 1. If any count is 0, the check fails.

> Note: these greps confirm that the subsection names are present at least once; they do not enforce per-phase containment. Per-phase containment is enforced by the Phase Structure Rule in Part 3.

Failure object (either pass):
```json
{
  "check": "phase_structure",
  "detail": "Output plan has no phase headers (## Phase N), or one or more phases are missing ### Build, ### Code Review, or ### Test subsections. The plan must be structured into phases, each with all three subsections."
}
```

On failure: retry using the standard Retry Procedure. The retry prompt includes Part 4 (quality failure context) with this failure object.

---

## How to Spawn a Review Agent

Construct the agent prompt as a single block of text combining four parts in order:

**Part 1 — System role** (varies by agent):

For Agent A:
```
Your job has three angles:

Completeness: Is everything thought through? Are there gaps in coverage? Is anything ambiguous or underspecified? Are there alternative approaches that should be considered or ruled out? Does the plan follow established patterns and best practices?

Consistency: Does the document contradict itself? Trace through each section in sequence: do the inputs and outputs at each step match what the previous step produces? Does any assumption made in one section conflict with a claim in another? Flag self-contradictions explicitly — they are different from gaps.

Implementation tracing: Walk through the build sequence or execution steps end-to-end. At each step, ask: what must already exist for this step to run? Does the preceding step produce it? A step that depends on something built in a later step is a circular dependency, not an ordering preference.

If a section is complete, consistent, and executable, explain specifically why — do not simply approve it.

Conciseness rule: Add content only when it would materially change an implementation decision. Do not add:
- Terminology explanations or tables unless ambiguity in the existing text would cause an implementer to make the wrong choice
- Exhaustive lists of alternatives unless the current approach has an unmitigated failure mode
- Defensive caveats about edge cases that the Test step within each phase will surface

The Build-Review-Test process within each phase is designed to surface implementation issues. A plan that is small and executable is better than one that is comprehensive but overwhelming. When in doubt, leave it out.

Exception: Structural additions required by the Phase Structure Rule are exempt from this constraint.
```

For Agent B:
```
Your job is to ask: what can go wrong? Assume this plan will be implemented exactly as written, and then assume it will fail. Find the failure modes. Identify security vulnerabilities, brittle assumptions, edge cases that break the design, and dependencies that could be unavailable. Where you agree with Agent A's changes, say why — do not just echo them.

Conciseness rule: Add content only when it would materially change an implementation decision. Do not add:
- Terminology explanations or tables unless ambiguity in the existing text would cause an implementer to make the wrong choice
- Exhaustive lists of alternatives unless the current approach has an unmitigated failure mode
- Defensive caveats about edge cases that the Test step within each phase will surface

The Build-Review-Test process within each phase is designed to surface implementation issues. A plan that is small and executable is better than one that is comprehensive but overwhelming. When in doubt, leave it out.

Exception: Structural additions required by the Phase Structure Rule are exempt from this constraint.
```

**Part 2 — Round-aware context** (varies by `round_context`):

For `"early"`:
```
This is an early review cycle. The plan likely still has significant gaps. Approach it with skepticism. Your job is to find issues, not to close them. State at least one concern per major section — if you cannot find a substantive concern, explain in detail why the section is sound rather than simply approving it.
```

For `"late"`:
```
This is a later review cycle. Many issues may already be resolved. Focus on what remains unresolved or was introduced by recent changes. You may approve sections that are now sound — but you must explain specifically why each section passes your scrutiny. Do not raise concerns you have already raised in previous rounds unless the plan has regressed on that point.
```

**Part 3 — Task instructions** (same for all agents):
```
Read the plan at `<current_plan_path>` (relative to project root `<PROJECT_ROOT>`).

Write your improved version of the plan to `<output_plan_path>` (relative to project root). The output file must be written before you produce your JSON response.

Your JSON input is:
<INPUT_JSON>

Phase structure rule: The output plan MUST be structured into phases using `## Phase N: <name>` headers. Each phase must contain exactly three subsections: `### Build`, `### Code Review`, and `### Test`.

- If the input plan has no phase structure, add it.
- If it has phases missing any of the three subsections, add the missing ones.
- Only `## Context` is permitted as a standalone top-level section (before Phase 1, if present in the input plan).
- All other non-phase top-level sections (`## Files to Modify`, `## Implementation Steps`, `## Changes to X`, and any similar structural sections) must be folded into the Build subsection of the phase they belong to.
- Single-step plans use exactly one phase: `## Phase 1: Implementation`.
- If folding or renaming causes an old top-level section name to disappear from the plan, record the mapping as a `section_renames` entry (see JSON response schema below) — this lets later rounds resolve concerns that were raised against the old name without requiring it to still exist.
- More generally, record a `section_renames` entry any time you refer to a section under a materially different label than the one a prior round's concern used to raise it — even when the underlying header still exists, just reworded or elaborated. The old header disappearing entirely (via a structural fold) is only one way this can happen; a lighter reword or relabeling of an existing section that changes how it would be matched by name also qualifies.

The JSON response schema is:
{
  "round": <integer>,
  "reviewer": "<agent_a or agent_b>",
  "has_changes": <boolean — true if you made any changes to the plan>,
  "changes": [
    {
      "section": "<section name you changed>",
      "description": "<what you changed>",
      "reasoning": "<why>"
    }
  ],
  "approvals": [
    {
      "section": "<section name — must match a section in the plan>",
      "reasoning": "<why this section is sound>"
    }
  ],
  "open_concerns": [
    {
      "section": "<section the concern is about>",
      "description": "<the concern>",
      "severity": "<low|medium|high>",
      "risk_accepted": <boolean — true only if you are explicitly accepting this risk>
    }
  ],
  "section_renames": [
    {
      "from": "<old section name a prior round's concern used to refer to this section>",
      "to": "<current section name it should now be matched under — must match a section in the plan>",
      "reasoning": "<why this mapping is correct>"
    }
  ]
}

Rules:
- You must set has_changes: false ONLY if you made no changes AND all your open_concerns have risk_accepted: true (or you have no open_concerns).
- Every section you approve must match a section header in the plan exactly.
- Every item in changes and approvals must include a non-empty reasoning field.
- changes + approvals + open_concerns must total at least 3 items.
- `section_renames` is optional. Populate it whenever you refer to a section under a different label than a prior round's concern used — not only when a structural fold makes the old header disappear entirely, but also when you're just using clearer/reworded wording for a section whose header still exists. Each entry's `to` must match a current section name exactly (same rule as approvals); `from` and `reasoning` must be non-empty. `from` does NOT need to match a current section — it names the label a prior round used, whether or not that label still appears in the plan.
- If quality_failure in your input is non-null, address the specific failure described before producing your response.

Your final message MUST be ONLY the JSON response object — no surrounding prose, no markdown code fences, no explanation. Just the raw JSON.
```

Substitute `<current_plan_path>`, `<output_plan_path>`, `<INPUT_JSON>`, and `<PROJECT_ROOT>` with the actual values for this spawn.

**Part 4 — Quality failure context** (only on retries):

If this is a retry, append:
```
IMPORTANT — RETRY: Your previous response failed the following quality check:
<quality_failure object as JSON>

Address this issue specifically before producing your response.
```

---

## How to Spawn the Arbiter

Construct the Arbiter input JSON:
```json
{
  "trigger": "cycle_detected",
  "contested_sections": <contested_sections from state>,
  "unresolved_concerns": <unresolved_concerns>,
  "current_plan_path": "<current plan path being arbitrated>",
  "output_plan_path": "<SESSION_DIR_REL>/plan-arbiter.md",
  "round_history_summary": "<prose summary — see below>"
}
```

**Generate `round_history_summary`:** Read the `rounds` array from state. Write a natural-language prose summary (2–4 sentences per round) covering: what each agent changed, what each agent contested, and why the cycle formed. Focus on the contested sections. Example: "Round 1: Agent A made the rollback steps independent — reasoning that a failed DB migration needs handling separate from code. Agent B reverted to a single rollback script, citing simplicity. Round 2: Agent A re-introduced independent steps; Agent B reverted again." If Agent B was not spawned for the final round (mid-round cycle), state this explicitly.

Build the Arbiter prompt:

**System role:**
```
You are a neutral arbiter reviewing a deadlock between two plan reviewers. You will receive a history of contested sections (sections where the two reviewers have made alternating changes over multiple rounds), the current plan, and a summary of the round history.

Your job is:
1. Read the current plan at `current_plan_path` (relative to project root `<PROJECT_ROOT>`)
2. For each contested section, understand both reviewers' positions from the round history and make a recommendation: accept one position, propose a synthesis, or flag as unresolvable without additional information
3. For unresolvable items, state the specific question the human must answer
4. Write a resolved plan to `output_plan_path` (relative to project root) that incorporates your recommendations (only modify the contested sections — leave the rest unchanged)
5. Return a JSON response per the Arbiter Response Schema

You are not a plan reviewer. Do not raise new concerns. Do not add new content. Focus only on resolving the specific points of disagreement you were given.
```

**Task instructions:**
```
Your input JSON is:
<ARBITER_INPUT_JSON>

The Arbiter Response Schema is:
{
  "trigger": "cycle_detected",
  "disagreements": [
    {
      "section": "<section name>",
      "agent_a_position": "<summary of Agent A's position>",
      "agent_b_position": "<summary of Agent B's position>",
      "recommendation": "<accept_agent_a | accept_agent_b | synthesis>",
      "reasoning": "<why>"
    }
  ],
  "unresolvable": [
    {
      "section": "<section name>",
      "summary": "<what the disagreement is>",
      "action_needed": "<specific question for the human>"
    }
  ]
}

Write the resolved plan to the path specified in output_plan_path before producing your JSON response.

Your final message MUST be ONLY the JSON response object — no surrounding prose, no markdown code fences. Just the raw JSON.
```

Use the Agent tool to spawn the Arbiter. Capture the response as `arbiter_raw`.

**Validation:**
1. Check that `SESSION_DIR_REL/plan-arbiter.md` exists and is non-empty. If missing: proceed without a valid plan, set `arbiter_response = null`, and record the failure in the escalated state.
2. Parse `arbiter_raw` as JSON. If it fails: set `arbiter_response = null`.

Store parsed (or null) result as `arbiter_response`.

---

## Retry Procedure

A retry re-spawns the same agent with the same inputs PLUS a `quality_failure` field. Before the retry:

1. Increment V: `V = V + 1`
2. Assign a new `output_path` for the retry: `SESSION_DIR_REL/plan-vV.md`
3. If the original file was written correctly (i.e., the failure was JSON parse or quality check, not file missing), use the original `output_path` as `current_plan_path` for the retry — the agent does not need to rewrite it. If the file was missing, keep the original `current_plan_path`.
4. Build the retry input payload with `output_plan_path` set to the new retry path.
5. Add Part 4 to the agent prompt (quality failure context).
6. Spawn the agent. Capture the raw response. Run the same file check. Once the file check passes, re-extract the section list fresh from the retry's own output path (the new `output_path` assigned in step 2) — never reuse the section list computed for the original attempt, and never fall back to the input plan. Then run the JSON parse and quality check using this freshly-extracted section list.

If the retry succeeds, continue with the new response and new output path. If it fails, escalate.

---

## Cleanup Procedure

Triggered when invoked as `/review-plan --cleanup <session-id>` (with optional `--force`).

```
0. Validate session-id (already done in Step 1 argument parsing — no re-validation needed here,
   but confirm the value was validated before constructing any path).
   Confirm FORCE flag value (true or false) was parsed in Step 1.

1. Resolve repository root: use `$PROJECT_ROOT`, resolved once at the top of Step 1.
   All subsequent path constructions use this resolved root as a prefix.

2. Locate session directory: <repo-root>/plans/sessions/<session-id>/
   If the directory does not exist, report error and halt.

3. Read state.json. Extract:
   - plan_name
   - status
   - current_plan_path
   - arbiter_plan_path (if present)
   - escalation_reason (if present)
   - rounds array
   - version_counter

   Validate plan_name: it must not contain path separators (`/`, `\`), must not contain `..`,
   and must not be empty. If it fails validation, report "Invalid plan_name in state.json" and halt.
   (plan_name is used to construct output file paths; an adversarially crafted state.json
   could otherwise cause writes outside the documentation/ directory.)

   Path format: current_plan_path and arbiter_plan_path are repo-relative paths
   (e.g., `plans/sessions/<session-id>/plan-v3.md`). When constructing the copy source
   in Step 7, prepend <repo-root>/ to form the absolute path. Do not treat these values
   as absolute paths even if the state.json author wrote them that way — if either path
   begins with `/` or a Windows drive letter, report "Unexpected absolute path in state.json"
   and halt.

4. Status guard: if status == "running", report:
   "Session <session-id> appears to be in progress (status: running).
    Confirm cleanup with /review-plan --cleanup <session-id> --force"
   and halt UNLESS FORCE == true.

5. Determine the final plan file:
   - If status == "converged": use current_plan_path
   - If status == "escalated" and arbiter_plan_path exists: use arbiter_plan_path
   - Otherwise: use current_plan_path and note it was not a clean convergence

6. Ensure documentation directory exists:
   mkdir -p "<repo-root>/documentation/"

7. Copy the final plan:
   Target path: <repo-root>/documentation/<plan-name>-final.md
   Source path: <repo-root>/<final_plan_path>  (final_plan_path is repo-relative; see Step 3)
   If the target file already exists: overwrite it and note "Overwriting existing final plan for <plan-name>."
   cp "<repo-root>/<final_plan_path>" "<repo-root>/documentation/<plan-name>-final.md"

8. Verify the copy: confirm <repo-root>/documentation/<plan-name>-final.md exists and
   is non-empty. If verification fails (disk full, permissions error, source missing),
   report the error and halt WITHOUT proceeding to Step 9. Do not delete the session
   directory if the copy cannot be verified.
   Note: if Step 8 halts, the documentation/<plan-name>-final.md file may or may not
   exist depending on when the failure occurred. The session directory is preserved for
   manual recovery. No automatic cleanup of the partial output is attempted.

9. Write a review summary to <repo-root>/documentation/<plan-name>-review-summary.md:
   - Session ID, plan name, start date, final status
   - escalation_reason (from state.json; null for converged sessions)
   - Number of rounds completed, number of plan versions produced
   - Brief prose summary: for each round, what Agent A changed and what Agent B changed
     (derive from the rounds[].agent_a_response.changes and rounds[].agent_b_response.changes arrays;
     if these sub-fields are absent in a round entry, note "no changes recorded" for that agent
     rather than halting — a missing changes field is not a structural error)
   - Link to final plan: documentation/<plan-name>-final.md

   If summary write fails due to the rounds array being missing or not an array (structural
   failure in state.json), report the error and halt WITHOUT proceeding to Step 10. Do not
   delete the session directory if the summary cannot be written.
   Note: if Step 9 halts, documentation/<plan-name>-final.md already exists (Step 8
   verified it). The session directory is preserved. The human can write the summary
   manually and then re-run cleanup, or delete the session directory manually.

10. Delete the session directory:
    rm -rf "<repo-root>/plans/sessions/<session-id>/"
    If the delete fails (e.g., file locked on Windows), report the error explicitly:
    "Warning: session directory could not be deleted: <error>. Delete manually:
     <repo-root>/plans/sessions/<session-id>/"
    Then proceed to Step 11 regardless — the archive outputs in documentation/ are
    already written and the failure is non-fatal.

11. Report to human:
    "Session <session-id> archived.
     Final plan: documentation/<plan-name>-final.md
     Summary: documentation/<plan-name>-review-summary.md
     Session directory: <deleted | could not be deleted — see warning above>"
```

---

## Semantic Cycle Detection

Given the `contested_sections` dict from state and the current `round` number:

For each section in `contested_sections`, collect the set of round numbers in which any entry for that section appears (any agent). If any three consecutive round numbers `r`, `r+1`, `r+2` are all present in that set, a semantic cycle is detected.

Implement using inline Python:
```bash
PYTHON_BIN=$(bash "$PLUGIN_ROOT/scripts/find-python.sh") || { echo "ERROR: no working python3/python found in PATH. If Python is installed but this still fails, check Windows Settings > Apps > Advanced app settings > App execution aliases and disable the python.exe/python3.exe Microsoft Store entries, or put a real python.org install earlier on PATH." >&2; exit 1; }
SEMANTIC_CYCLE="$(CONTESTED_JSON='<contested_sections_json>' "$PYTHON_BIN" -c '
import json, os
contested = json.loads(os.environ["CONTESTED_JSON"])
cycle = False
for section, entries in contested.items():
    rounds_set = set(e.get("round", 0) for e in entries)
    for r in sorted(rounds_set):
        if r + 1 in rounds_set and r + 2 in rounds_set:
            cycle = True
            break
    if cycle:
        break
print("true" if cycle else "false")
')"
```

Return `true` or `false`.

---

## State Write Pattern

All state writes follow this pattern. Never do partial field writes via shell `sed` or similar. Always read the full file, modify in memory, and write back.

**Finding the Python binary:** On Windows, `command -v python` can find the Microsoft Store's app-execution-alias stub (a real file on PATH) and return its path even though running it does nothing useful — existence on PATH does not mean it works. Use:
```bash
PYTHON_BIN=$(bash "$PLUGIN_ROOT/scripts/find-python.sh") || { echo "ERROR: no working python3/python found in PATH. If Python is installed but this still fails, check Windows Settings > Apps > Advanced app settings > App execution aliases and disable the python.exe/python3.exe Microsoft Store entries, or put a real python.org install earlier on PATH." >&2; exit 1; }
```

**Standard state write (via Python temp file):**

**IMPORTANT:** Do NOT use inline `"$(...)"` substitution for Python state writes. The quoting required to pass JSON through shell variable expansion is fragile and will silently wipe the state file if Python fails. Always write the Python script to a temp file first, then execute it:

```bash
PYTHON_BIN=$(bash "$PLUGIN_ROOT/scripts/find-python.sh") || { echo "ERROR: no working python3/python found in PATH. If Python is installed but this still fails, check Windows Settings > Apps > Advanced app settings > App execution aliases and disable the python.exe/python3.exe Microsoft Store entries, or put a real python.org install earlier on PATH." >&2; exit 1; }
STATE_FILE_ABS="$PROJECT_ROOT/$STATE_FILE_REL"

cat > /tmp/update_state_NNN.py << 'PYEOF'
import json, sys

state_file = sys.argv[1]
with open(state_file) as f:
    s = json.load(f)

# ... apply updates to s using Python literals (no shell interpolation needed) ...

with open(state_file, 'w') as f:
    json.dump(s, f, indent=2)
print(f"Written: key_field={s['key_field']}")
PYEOF

"$PYTHON_BIN" /tmp/update_state_NNN.py "$STATE_FILE_ABS"
```

Use a unique suffix for the temp file name (e.g., `update_state_r1a.py`, `update_state_r1b.py`) to avoid conflicts between rounds. Pass all variable values as Python literals inside the script — avoid `os.environ` for large JSON payloads; embed them directly as Python dicts/strings.
```

For complex updates (round entries, nested arrays), pass JSON payloads via environment variables too — never embed raw JSON as shell string literals. Example pattern:

```bash
CURRENT_STATE_VAL="$(cat "$STATE_FILE_ABS")" \
AGENT_RESPONSE_VAL="$AGENT_A_RESPONSE_JSON" \
V_VAL="$V" \
ROUND_VAL="$ROUND" \
"$PYTHON_BIN" -c '
import json, os
s = json.loads(os.environ["CURRENT_STATE_VAL"])
resp = json.loads(os.environ["AGENT_RESPONSE_VAL"])
v = int(os.environ["V_VAL"])
rnd = int(os.environ["ROUND_VAL"])
# update s...
print(json.dumps(s, indent=2))
'
```

**Minimal patch (for pre-Arbiter status writes only):**
When writing only `status` and `current_plan_path` before spawning the Arbiter, use the same read-modify-write pattern but change only those two fields:
```python
s["status"] = "cycle_detected"
s["current_plan_path"] = output_path_a_or_b
```

**Post-Arbiter state write:**
Includes all standard fields plus:
```python
s["status"] = "escalated"
s["escalation_reason"] = "cycle_detected"
s["arbiter_plan_path"] = SESSION_DIR_REL + "/plan-arbiter.md"
s["arbiter_response"] = arbiter_response_parsed_or_none
```

**Terminal state writes (convergence, max rounds, size exceeded):**
Update only the `status` and `escalation_reason` fields (plus any final `current_plan_path`/`version_counter` if not already written).

---

## Agent Input Payload Construction

When computing the size estimate before an agent spawn, build the full JSON payload first, then measure it. This ensures the estimate matches what the agent will actually receive.

The payload for pre-spawn size check purposes is the same JSON object described in each spawn step. Build it as a Python dict and serialize with `json.dumps` to get the character count.

**Section list extraction** from a plan file returns the text content of `## ` headers with the prefix stripped. Example: `## Rollback Plan` → `"Rollback Plan"`. This list is used for the Specificity quality check (approvals must name a section from this list). Extraction always happens from the agent's own output file (`output_path_a`/`output_path_b`, or the retry's output path on a retry), and only after that file's existence has been confirmed — never before the agent has run, and never from the plan file the agent received as input.

---

## Invariants (Do Not Violate)

1. `state.json` is always read in full before any write. Partial writes via sed/grep are forbidden except for the two-field status patch.
2. Plan files are never modified in place. Each agent produces a new numbered file.
3. `plan-v0.md` is never modified.
4. Never spawn a new agent while a previous agent invocation is in progress.
5. Every agent invocation records its outcome in `state.json` before the next invocation.
6. V is a monotonically increasing global counter. Retries consume V values just like normal rounds.
7. The Arbiter is spawned at most once per session.
