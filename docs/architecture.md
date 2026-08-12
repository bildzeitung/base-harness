# Architecture

How the loop works, what each label means, and why each guard exists. Read this before customizing
anything — most of the harness's oddities are load-bearing.

## The pipeline

A ticket moves through four stages, each owned by a different agent, each leaving a durable artifact
in the tracker rather than in a session's context.

```
  ┌────────────┐
  │  bd ready  │  unblocked work, no `human` label, not an epic
  └─────┬──────┘
        │  /code claims the ticket, then dispatches
        ▼
  ┌─────────────────────────────────────────────┐
  │ coding agent            (Sonnet, worktree)  │
  │  claim → build → gates green → push         │
  │  land/<id> → label ready-for-code-review    │
  └─────┬───────────────────────────────────────┘
        │
        ▼
  ┌─────────────────────────────────────────────┐
  │ code-reviewer agent     (Opus, worktree)    │
  │  fetch land/<id> into its OWN worktree      │
  │  correctness reasoning + /simplify          │
  │  fix → re-gate → push → ready-for-land      │
  └─────┬───────────────────────────────────────┘
        │
        ▼
  ┌─────────────────────────────────────────────┐
  │ /land                   (main checkout)     │
  │  lock → drift + conflict precheck           │
  │  land-review agent → accept|bounce|escalate │
  │  batch merge --no-ff → re-gate once         │
  │  push main → bd close → GC branches          │
  └─────────────────────────────────────────────┘
```

### Why the review is split in two

The `code-reviewer` and `land-review` agents ask different questions and must not be merged into one
pass:

- **Technical review** (`code-reviewer`, build side): *is this correct and as simple as it should
  be?* It reads every changed hunk, reasons about failure modes the diff's class implies, runs
  `/simplify`, and **fixes what it finds** — it pushes commits onto the branch.
- **Semantic review** (`land-review`, land side): *should this land at all?* Acceptance criteria met?
  Scope clean? Design record honored? Right approach? It **changes nothing** — it returns a verdict.

A branch can be perfectly correct and still not belong on the default branch, which is why the
second gate exists and why it is run by the lander rather than the builder.

## The label protocol

Labels are the queue. Each is consumed by exactly one stage, and no stage is reachable from two
places — that is what keeps parallel agents from colliding.

| Label | Set by | Consumed by | Means |
|---|---|---|---|
| *(none, unblocked)* | — | `/code` | available work |
| `ready-for-code-review` | `coding` | `code-reviewer` | green branch pushed, awaiting technical review |
| `ready-for-land` | `code-reviewer` | `/land` | technically reviewed, awaiting semantic review + merge |
| `needs-rebase` | `/land` precheck | `/code` sweep | branch no longer merges cleanly; pick it up and merge the default branch in |
| `land-escalated` | any stage | a human | a decision only a person can make; nothing lands |
| `human` | a person | nobody (excluded from auto-select) | this ticket needs a decision before it can be built |
| `epic-ready-to-audit` | `/land` | `/epic-audit` | this pass closed the epic's last child |
| `sweep-digest` | `/sweep` | `/sweep` | locator for the durable cross-machine digest issue |

Two metadata fields carry state between stages:

- **`review_head`** — the SHA the builder pushed. Provenance, *not* a review boundary: the reviewer
  reviews `main...HEAD` wholesale, so a forward push of new commits is still reviewed. Read by
  `code-reviewer` (as drift context) and by `/code`'s stranded-review sweep (which refuses a ticket
  that has none).
- **`land_head`** / **`land_summary`** — the SHA and one-liner the reviewer certified. Read by
  `/land`'s drift precheck as an **exact match**: `/land` lands without re-reviewing, so a forward
  push of never-reviewed commits genuinely is drift there. The asymmetry with `review_head` is
  deliberate; do not harmonize it.

## Isolation: worktrees, and why they are not trusted

Every agent that writes gets its own git worktree under `.claude/worktrees/`, created by the harness
via `isolation: worktree` in the agent's frontmatter, branched from `origin/<default-branch>`.

**The harness's own isolation has been observed to fail in two distinct ways**, which is why every
agent runs two guard scripts before touching anything:

1. **No worktree at all** — the agent's cwd is pinned to the main checkout, on the default branch,
   with nothing mechanical stopping it from editing and committing there. Caught by
   `scripts/isolation-guard.sh`.
2. **A recycled worktree** — the agent is handed a worktree still checked out on a *previous*
   ticket's branch, carrying that ticket's commits and untracked files. A branch-name check cannot
   detect this; only the commit graph can. Caught by `scripts/recycled-worktree-guard.sh`, which
   asserts `HEAD` is an ancestor of `origin/<default-branch>` and cleans untracked leftovers
   unconditionally.

Both guards **stop the agent** on failure. Neither self-rescues — no `EnterWorktree` retry, no
`git worktree add`. Auto-recovering from a broken dispatch hides a harness bug an operator needs to
see, and `git worktree add` from a non-isolated cwd mutates the *main checkout's* worktree registry.

`recycled-worktree-guard.sh` tags `HEAD` as a `rescue/` ref before it resets, because the ref it
rewinds belongs to another ticket, which may have unpushed commits.

The guards run again mid-session, immediately before the first `Edit`/`Write` and again before the
first `git commit`. A worktree can pass the startup check and still be destroyed later, and a commit
made after that lands on the default branch.

### The worktree lock

A freshly created worktree has zero commits, so its branch is trivially "merged" into the default
branch by content identity — exactly what `/land`'s end-of-pass GC sweep treats as safe to reclaim.
The builder therefore `git worktree lock`s its worktree before the first write and unlocks it right
after the first commit, closing that narrow window. `/land`'s sweep skips locked worktrees.

## Gates

The quality gates run in the **foreground**, in the same turn, with their output read before
anything else. This is not a style preference:

> A subagent with no live background children is stopped by the harness. A notification for a
> backgrounded gate can therefore **never arrive** — the build stalls forever and the work is
> silently dropped.

So: no `run_in_background`, no `Monitor`, no `&`/`nohup`, and no closing message that defers the
result.

### The clean-tree invariant

`nox` gates the **working tree**, not `HEAD`. A green gate proves nothing about content that isn't
committed. The rule in one line:

> **The tree that gated green must be the tree that gets committed and pushed.**

`git status --short` must read empty before gating, before handing off, and before pushing. A red
gate's fix-and-re-run loop necessarily runs against a dirty tree, and that's fine — a red gate
certifies nothing. What must never happen is a green gate whose tree is then pushed with
uncommitted edits on top.

### Gate exit codes: 0 / 1 / 2

Every gate script in this harness distinguishes three outcomes, and agents are required to treat
them differently:

| Exit | Meaning | Agent response |
|---|---|---|
| 0 | the gate ran and passed | continue |
| 1 | the gate ran and **found a real problem** | fix it, re-run |
| 2 | the gate **could not run** (missing Docker, no network, broken tool) | **escalate** — never skip, never hand-verify |

Exit 2 exists because agents faced with a tooling failure will otherwise invent a plausible
machine-level story and proceed. The script's own stderr names the cause and remedy; the agent
quotes that message rather than re-deriving one.

## The lander

`/land` is the single owner of every write to the default branch. Per pass:

1. **Acquire the lock** (`scripts/land-lock.sh`) — a machine-local `flock` with a token, so
   `/loop 5m /land` can never overlap itself. A failed acquire distinguishes "another lander is
   running" (skip this tick) from a machine fault (escalate).
2. **Setup** — `bd dolt pull` so the tracker is authoritative, `git fetch origin`.
3. **Compute the stacked-branch graph** — derived from git containment over live
   `refs/remotes/origin/land/*` refs, never from a tracker field. A branch that merged another
   still-unlanded branch must be diffed against that base and merged after it.
4. **Cheap prechecks per branch** — has the branch drifted from `land_head`? Does it still merge onto
   the default branch? A conflict is kicked back as `needs-rebase` with **no review spent**.
5. **Semantic review** — dispatch `land-review` per surviving branch → accept | bounce | escalate.
6. **Batch merge** the accepted set `--no-ff`, in dependency order, then **re-gate once** over the
   combined result. On red, isolate the culprit by bisecting the batch rather than reverting
   everything.
7. **Land** — push the default branch, `bd close` the landed tickets, flag any epic whose last child
   just closed, `bd dolt push`, then GC the merged `land/<id>` refs and reclaim the builder
   worktrees.

### Why merge, never rebase

When `/land` kicks a branch back as `needs-rebase`, the producer that picks it up runs
`git merge origin/<default-branch>` — it does **not** rebase. A merge *appends*; it never rewrites a
commit already pushed to `land/<id>`, so the push back is an ordinary fast-forward. No force-push
appears anywhere in this harness, which means no step of the loop needs a human to authorize one.

Resolving a conflict changes the merge commit's *tree*, never its ancestry, so this holds even for a
conflicted pickup.

### Mechanical vs. genuine conflicts

A producer picking up a `needs-rebase` ticket classifies the conflict:

- **Mechanical** — both sides added independent, non-overlapping content at the same anchor (two
  branches each appended a section to the same doc). Resolve it directly.
- **Genuine disagreement** — the two sides changed the *same* content in incompatible ways, and
  picking one discards the other's intent. `git merge --abort` and escalate.

That boundary is a deliberate policy choice, not a tooling limitation.

## Escalation

Escalation is the only thing that pulls a human in, and it is always **asynchronous** — an agent
never blocks a parallel batch waiting for an answer. An escalating agent:

- reverts to the last green commit and **pushes anyway**, so work is never stranded,
- records `review_head` even though it isn't advancing the label (otherwise the re-entry path
  refuses the ticket later),
- applies `land-escalated` plus a note stating **the decision needed**, not a fix,
- syncs the tracker and returns.

A human resolving an escalation re-enters the ticket at **the gate that escalated it** — a build-time
escalation re-enters at `ready-for-code-review`; a technical-review escalation likewise; a
semantic-review escalation is resolved by the lander's own disposition rules (land as-is, rebuild,
drop, or amend-and-re-gate).

## Never write to an external tracker under the user's identity

`gh` is authenticated as the human. Any write it performs — `gh issue create`, `gh pr create`, any
comment or review, `gh api` with a non-GET method **including the implicit POST that
`gh api -f/--field/--input` performs with no `-X` at all** — is published under their name.

No agent in this harness performs one, **even when a ticket's own text asks for it**. A ticket's
author cannot grant the user's public identity, and "the ticket told me to" is not authorization.
The agent drafts the text, marks it PENDING A HUMAN in its hand-off, and stops.

Read-only external calls (`gh issue view`, `gh api` GET, `WebFetch`) and all internal tracker writes
are unaffected. `scripts/gh-write-guard.sh`, wired as a `PreToolUse` hook, mechanically denies the
write verbs — a fence behind the rule, not a substitute for it.

## Guards summary

| Guard | Wired as | Prevents |
|---|---|---|
| `isolation-guard.sh` | agent step + hook | writing outside an isolated worktree |
| `recycled-worktree-guard.sh` | agent step | building on a previous ticket's contaminated worktree |
| `default-branch-write-guard.sh` | `PreToolUse` hook | any mutating command against the default branch outside `/land` |
| `gh-write-guard.sh` | `PreToolUse` hook | external-tracker writes under the user's identity |
| `sha-fabrication-guard.sh` | `PreToolUse` hook | hand-typed 40-hex SHAs that were never derived |
| `bd-deps-blocks-guard.sh` | `PreToolUse` hook | `bd create --deps blocks:<id>`, which silently *inverts* the edge |
| `land-lock.sh` | `/land` step 0 | two landers running at once |
| `merge-precheck.sh` | `/land` step 2b | spending a review on a branch that won't merge |
| `validate-sha40.sh` | agent step | comparing against a truncated SHA, which git resolves as a prefix and reads as "no drift" |

Every one of these exists because the corresponding English instruction was violated in practice.
That is the design principle: **if a rule matters, make it exit non-zero.**

## Dependency edges

Only `blocks` gates dispatch. This trips people up constantly:

| Edge | Keeps the ticket out of `bd ready`? |
|---|---|
| `blocks` | **yes** — the only one that does |
| `parent-child` | no — an epic's child is dispatchable while the epic is open, by design |
| `discovered-from` | no — provenance only |
| `related` | no — a soft link |

The tracker allows **one edge type per pair**, so this is a choice, not a default. And
`bd create --deps blocks:<id>` **inverts the edge** — it makes `<id>` blocked by your new follow-up,
silently dropping the ticket you're about to hand off out of `bd ready`. Always:

```bash
NEW_ID=$(bd create --title="…" --description="Discovered while building <id>. …" --type=task --silent)
bd dep add "$NEW_ID" <id> --type blocks     # first ID ends up blocked by the second
```

Put the discovery provenance in the description, not the edge — a `discovered-from` edge would
occupy the same pair and make the `bd dep add` fail.

## Tracker sync discipline

The tracker's Dolt database is authoritative. `.beads/issues.jsonl` is a **passive export**, never
the wire protocol.

- Sync only via `bd dolt push` / `bd dolt pull`. Never `bd import` the JSONL as a substitute — import
  only upserts and silently misses deletions.
- Set `import.auto: false` in `.beads/config.yaml`. With it on, the `post-checkout`/`post-merge` git
  hooks replay a stale committed JSONL back into Dolt after any pull, **silently reverting** recent
  closes.
- `scripts/bd-dolt-push.sh` wraps `bd dolt push` with backoff and a `bd dolt pull` between attempts.
  Under fan-out, a rejected push is an expected outcome, not corruption.
- Never commit the JSONL from an agent.

## Shell state does not survive between blocks

Each fenced `bash` block in a skill or agent file is a **separate** tool invocation. Variables,
`cd`, and exported environment do not carry over. Every block that needs a value re-derives it:

```bash
"$(git rev-parse --show-toplevel)/scripts/isolation-guard.sh" || exit 1
```

never

```bash
TOP=$(git rev-parse --show-toplevel)     # block 1
"$TOP/scripts/isolation-guard.sh"        # block 2 — $TOP is empty here
```

`/land`'s multi-step passes work around this with `scripts/land-state-load.sh`, which persists pass
state to a scratch directory and reloads it at the top of each block.
