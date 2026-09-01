# claude-plan-review

A Claude Code plugin that hardens an implementation plan before you build from it. Two AI reviewers work over the plan in alternating rounds — one checking it is complete and self-consistent, the other hunting for what will break — until they both stop finding problems or a neutral arbiter settles a deadlock.

## Recommended workflow

1. **Plan normally.** Put Claude into planning mode and work through the task until you have a plan you would be willing to execute.
2. **Save the plan to a file** instead of running it. Anywhere works; a `plans/` folder in the project is a tidy home for it — say `plans/add-oauth-login.md`.
3. **Review the saved plan:**
   ```
   /claude-plan-review:review-plan plans/add-oauth-login.md add-oauth-login
   ```
   The general form is:
   ```
   /claude-plan-review:review-plan <plan-path> <plan-name>
   ```
   `<plan-path>` is an absolute or project-relative path to the plan; `<plan-name>` is a short label with no spaces, used to name the session and the archived output. The loop then runs unattended and reports back either **converged** or **escalated**, with a session id like `plan-review-2026-09-01-001`.
4. **Read the final plan**, resolve anything the run escalated, then archive and clean up:
   ```
   /claude-plan-review:review-plan --cleanup plan-review-2026-09-01-001
   ```
   `--cleanup <session-id>` copies the final plan to `documentation/<plan-name>-final.md`, writes a round-by-round summary beside it, and deletes the session's working files. Add `--force` if the session's state still says `running`.

## Install

From within a Claude CLI session:

```
/plugin marketplace add simonrumi/claude-plan-review
/plugin install claude-plan-review@claude-plan-review
```

**After installing or updating this plugin, restart Claude Code (or start a new session) before first use.** The plugin resolves your project directory via a `SessionStart` hook that persists it into the session's environment; that hook must run at least once, with the plugin already installed, before `/claude-plan-review:review-plan` can find your project root. Invoking the command in the same session you just installed or updated the plugin in will fail with a clear "restart Claude Code" error rather than silently using the wrong project.

## The plan it produces

The reviewers rewrite the plan into a fixed shape so that every step carries its own verification:

- **`## Context`** — optional, and the only non-phase section allowed. Why the change is being made.
- **`## Phase N: <name>`** — one or more. A single-step plan uses one phase, `## Phase 1: Implementation`.
- Each phase contains exactly three subsections:
  - **`### Build`** — what to implement. Any "files to modify" or "implementation steps" material from the original plan is folded in here.
  - **`### Code Review`** — what a reviewer should check once the build step is done.
  - **`### Test`** — how to prove the phase works.

## How it works

**TL;DR:** an orchestrator spawns two sub-agents with opposite briefs and lets them rewrite the plan turn by turn until neither finds anything left to fix; if they get stuck flipping the same section back and forth, a third agent breaks the tie.

The command is the **orchestrator**. It never edits the plan itself — each round it spawns agents, reads back their rewritten plan and a structured verdict, updates a running list of open concerns, and decides whether to continue.

| Agent | Brief |
|---|---|
| **Agent A** | Constructive. Is everything thought through? Does each step depend only on things built in an earlier step? Does any section contradict another? |
| **Agent B** | Adversarial. Assume the plan is built exactly as written and then fails — find the failure modes, security holes, brittle assumptions, and missing dependencies. |

Each round, Agent A rewrites the plan, then Agent B rewrites Agent A's version. Both must approve sections explicitly rather than silently, justify every change, and restate or formally accept any concern they raised in an earlier round. Quality checks reject a response that skips these. Both are also told to add content only when it would change an implementation decision — "when in doubt, leave it out" — so the plan does not grow a little more every round.

**The arbiter.** Sometimes the two agents disagree on one section and keep flipping it: A rewrites it, B reverts it, A rewrites it again. Left alone this runs until the round limit with nothing resolved. When the orchestrator sees a section rewritten three rounds running (or a plan version that exactly repeats an earlier one), it stops the loop and spawns the **arbiter** — a neutral third agent, used at most once per session. The arbiter looks only at the contested sections, reads the back-and-forth history, and for each one either picks a side, proposes a synthesis, or writes down the exact question a human needs to answer. It does not raise new concerns or add new content.

**How a run ends:**

- **Converged** — after at least two rounds, both agents report no changes and no open concerns. The last plan version is final.
- **Escalated** — a deadlock went to the arbiter, the round limit (8) was reached, or the plan grew too large to review safely. The orchestrator reports what is unresolved and hands back to you.

## Where files go

Everything is created under the project you run the command from, never the plugin's install directory:

- `plans/sessions/<session-id>/` — one working directory per run: `plan-v0.md` (your input, left untouched), `plan-v1.md`, `plan-v2.md`, … (each agent's rewrite), `plan-arbiter.md` if the arbiter ran, and `state.json`. All of this is removed by `--cleanup`.
- `documentation/` — where `--cleanup` leaves the final plan and its review summary.

## Known residual risk (Windows)

This plugin's `SessionStart` hook writes at most two lines to Claude Code's session environment file, guarded so repeated hook firings (on `/clear`, `/compact`, or session resume) never duplicate those lines. That guard covers this plugin's own contribution, but it cannot control other hooks or plugins sharing the same session. On Windows, an open upstream issue (anthropics/claude-code#78146) describes the Bash tool's environment-file handling accumulating duplicate content across many resume/clear/compact cycles in a single long session, in rare cases producing a malformed line that wedges the Bash tool for the rest of that session. If this happens, the documented recovery is the same as the upstream report's: start a brand-new conversation rather than resuming. This is a disclosed, accepted, upstream limitation — not something this plugin can fully eliminate on its own.

## License

MIT — see [LICENSE](./LICENSE).
