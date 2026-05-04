# ADR-003: Secrets in IaC — PreToolUse Hook vs. CLAUDE.md Prompt

**Date:** 2026-05-04  
**Status:** Accepted  
**Deciders:** Platform Team

---

## Context

When Claude Code generates or edits Terraform files, it may produce outputs containing plaintext credential values — particularly during scaffolding, when it defaults to placeholder literals like `password = "changeme"` or `api_key = "YOUR_KEY_HERE"`. These literals, if committed, create security incidents even if they appear "fake."

Two enforcement mechanisms are available in Claude Code:

- **PreToolUse hook** — a shell command that runs before every file write/edit. Can inspect the content and return exit code 2 to unconditionally block the operation.
- **CLAUDE.md prompt guidance** — a natural-language instruction that shapes Claude's behavior probabilistically.

---

## Decision

**Use both, for different reasons:**

1. **PreToolUse hook** (`/.claude/settings.json`) — blocks any literal credential pattern in `.tf` or `.tfvars` files unconditionally. This is the hard stop.

2. **CLAUDE.md prompt** — instructs Claude to prefer `var.*` references and `data.aws_secretsmanager_secret_version` for any credential. This shapes the output *before* the hook fires, reducing friction.

---

## Rationale

### Why the hook, not just the prompt?

| Property | Hook | Prompt |
|---|---|---|
| Enforcement | Deterministic | Probabilistic |
| Can be bypassed by model | No | Yes (model may "forget" or reason around it) |
| Applies to non-Claude edits | Yes (any tool write) | No |
| Latency | ~50ms | 0ms (baked into generation) |
| Right tool for "always wrong" cases | Yes | No |

Plaintext secrets in IaC are **always wrong**. There is no legitimate exception where writing `password = "hunter2"` into a `.tf` file is correct behavior. When the correct answer is binary and universal, a deterministic block is the right enforcement mechanism. A prompt relies on the model's judgment; a hook does not.

### Why keep the prompt too?

The hook fires *after* Claude has already generated the content. A prompt in `CLAUDE.md` shifts the generation upstream — Claude writes `var.db_password` instead of `password = "..."` in the first place. This eliminates the block-and-retry loop for the common case, making the workflow faster without reducing safety.

The prompt also covers edge cases the hook regex might miss (environment variable files, shell scripts) and serves as documentation for human developers reading `CLAUDE.md`.

---

## Hook Implementation

File: `.claude/settings.json`

The hook uses a regex pattern to detect common secret literal patterns:
```
(password|secret|token|api_key|private_key)\s*=\s*"[^$\{][^"]{3,}"
```

This pattern:
- Matches: `password = "mypassword"`, `api_key = "sk-abc123"`
- Does not match: `password = var.db_password`, `secret = "${local.secret}"` (Terraform interpolation)
- Applies only to `.tf` and `.tfvars` files

Exit code 2 blocks the tool call with a message directing Claude to use `var.*` references.

---

## Prompt Implementation

`CLAUDE.md` (project-level):
> **Secrets Rule:** NEVER write literal credential values in `.tf` files or any config committed to git. Use `var.` references for all secrets. In AWS, source from `data.aws_secretsmanager_secret_version`.

Each workload `CLAUDE.md` repeats the rule for its context.

---

## Consequences

- Claude Code IaC generation is slightly slower on first attempt if it produces a literal — hook fires, Claude retries with `var.` reference
- Human developers editing `.tf` files directly are also protected by the hook (any write tool, not just Claude)
- Hook does not cover Python or YAML config files — those rely on `.gitignore` and `detect-secrets` in CI (out of scope for this ADR)
