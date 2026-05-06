# Constitution: HoehnPhotosOrganizer

> Living document. Operator-edits override; agent-proposed edits go via
> handoff to operator (don't silent-commit). Workers re-read on every
> `/clear`. This is the north star when no task is dispatched.

## Mission

*To be refined by the kickoff audit task. Until then: extend the
existing repo at `/Users/connorhoehn/Projects/HoehnPhotosOrganizer` consistent with its README, planning
docs, and recent commit history.*

## Scope

**This project IS:**
- A working codebase at `/Users/connorhoehn/Projects/HoehnPhotosOrganizer` with its own existing
  conventions, tests, and architectural choices.
- A leaf application by default — assume no other agent pins to its
  source unless the kickoff audit finds otherwise.

**This project IS NOT:**
- A place to invent shared abstractions belonging in a sibling
  library — file a task for the appropriate library agent if needed.
- A staging ground for speculative features without a documented
  pull signal in `.planning/` or recent commits.

## Hard rules — non-negotiable, in addition to worker-template.md

1. **NEVER run cloud apply.** Includes (non-exhaustive):
   - `cdk deploy` / `cdk destroy` / `cdk bootstrap`
   - `aws ... create / update / delete / put / sync` (read-only
     `describe / list / get` is fine for diagnostics)
   - `terraform apply` / `terraform destroy`
   - `kubectl apply` / `kubectl delete` / `helm install` / `helm upgrade`
   - `gcloud ... deploy` / `az ... create`
   - `npm run deploy` / `npm run destroy` / equivalent shell scripts.
   You may *write* IaC, *run synth/plan*, *run unit tests*. You may NOT
   execute apply.
2. **NEVER alter production data** even via "dev" tooling.
3. **No new secrets in code or commits.** Existing secret-management
   patterns may be extended; new credentials go in env or SSM.
4. The "no AWS deploys" hard rule already in worker-template.md
   applies fully — these are amplifications.

## Current phase

**Unknown — to be determined by the kickoff audit task.**

The audit reads `.planning/STATE.md`, `.planning/ROADMAP.md`,
`.planning/MILESTONES.md`, any `*-HANDOFF.md` docs, and recent git
log. It then proposes a real `## Current phase` + `## Phase
north-star` via handoff to orchestrator.

Until the audit lands: idle when the dispatched queue is empty.
Don't self-generate against this placeholder.

## Self-driven backlog (placeholder — to be populated by kickoff audit)

The audit task will populate this section.

## User-facing framing

Default personas (kickoff audit may refine):
- **End-user**: people using the product. What they see, what works,
  what stops breaking.
- **Operator (you, on-call)**: what they can debug, intervene on,
  observe.

Frame `User impact:` summaries in the right persona for the change.
Internal refactors with no user-visible change should say so
explicitly — don't fabricate impact.

## Good-enhancement criteria

A self-driven task is worth claiming if it satisfies AT LEAST ONE of:
- Closes a `.planning/` follow-up older than 2 weeks.
- Removes a documented techdebt item.
- Adds tests for a code path with thin coverage.
- Hardens a recently-shipped feature.
- Improves operator visibility (logs, metrics, dev CLI ergonomics).

A self-driven task is **NOT** worth claiming if it:
- Adds an exported symbol with no consumer.
- Refactors a green code path with no measured benefit.
- Touches IaC without a corresponding user-facing reason.
- Spends >200 LOC across implementation. Larger ⇒ raise a blocker
  for operator scope review.

## Daily cap

**Default: up to 30 self-driven tasks per UTC day per agent session.**
Override file: `$AGENT_HUB_ROOT/.budget-HoehnPhotosOrganizer` (integer)
supersedes the default when present. Read every `/clear`.

Anthropic weekly limit handled separately via `.cooldown_until`.

## Constitution review cadence

After every 5 self-driven `task.done` events, re-read this file +
the last 5 done summaries. Propose edits via handoff to orchestrator —
never silent-commit constitution changes.

## Cross-repo contracts

To be determined by the kickoff audit. Default assumption: this is a
leaf application; producers it depends on are external (npm packages,
cloud SDKs). All cross-project dependencies must follow the project
linkage rules in `worker-template.md` — git-published artifacts only,
no filesystem coupling, no auto-correlation across languages.

## Kill-switch

If `$AGENT_HUB_ROOT/.no_self_driven` exists, do NOT enter the
self-generation step. Only execute dispatched work. Idle when the
dispatched queue is empty.
