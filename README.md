# claude-plan-review

A Claude Code plugin that orchestrates a dual-AI plan review loop: two sub-agents (Agent A and Agent B) alternately review and improve a plan document, applying six quality checks each round and detecting both hash-based and semantic oscillation, until they converge (both report no changes and no open concerns) or escalate to a neutral Arbiter and a human decision.

## Usage

```
/claude-plan-review:review-plan <plan-path> <plan-name>
/claude-plan-review:review-plan --cleanup <session-id> [--force]
```

`<plan-path>` is an absolute or project-relative path to the input plan file; `<plan-name>` is a short, space-free label used for session and output naming. The `--cleanup` variant archives a finished session's final plan and a review summary into `documentation/`, and removes the session's working directory under `plans/sessions/`.

The plugin expects (and will create) `plans/sessions/` and `documentation/` under whatever project it is invoked from — not under the plugin's own install directory.

## Install

From within a Claude CLI session:

```
/plugin marketplace add simonrumi/claude-plan-review
/plugin install claude-plan-review@claude-plan-review
```

**After installing or updating this plugin, restart Claude Code (or start a new session) before first use.** The plugin resolves your project directory via a `SessionStart` hook that persists it into the session's environment; that hook must run at least once, with the plugin already installed, before `/claude-plan-review:review-plan` can find your project root. Invoking the command in the same session you just installed or updated the plugin in will fail with a clear "restart Claude Code" error rather than silently using the wrong project.

## Known residual risk (Windows)

This plugin's `SessionStart` hook writes at most two lines to Claude Code's session environment file, guarded so repeated hook firings (on `/clear`, `/compact`, or session resume) never duplicate those lines. That guard covers this plugin's own contribution, but it cannot control other hooks or plugins sharing the same session. On Windows, an open upstream issue (anthropics/claude-code#78146) describes the Bash tool's environment-file handling accumulating duplicate content across many resume/clear/compact cycles in a single long session, in rare cases producing a malformed line that wedges the Bash tool for the rest of that session. If this happens, the documented recovery is the same as the upstream report's: start a brand-new conversation rather than resuming. This is a disclosed, accepted, upstream limitation — not something this plugin can fully eliminate on its own.

## License

MIT — see [LICENSE](./LICENSE).
