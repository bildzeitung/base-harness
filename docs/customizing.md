# Customizing

What to change per project, what to leave alone, and where the load-bearing bits are.

## Change these

### Default branch name

The templates say **`main`** throughout — in the skills' prose, in the guard scripts' branch
literals, and in `scripts/default-branch-write-guard.sh`'s comparison.

`install.sh` detects a different default branch and tells you, but deliberately does **not** rewrite
anything: a silent bulk `sed` across skills and guard scripts is exactly the kind of unreviewed edit
this harness exists to prevent. Do it yourself:

```bash
grep -rln '\bmain\b' .claude scripts CLAUDE.md docs
```

The occurrences that actually **matter** (everything else is prose):

| File | What to change |
|---|---|
| `scripts/default-branch-write-guard.sh` | the `[ "$branch" = "main" ]` comparison |
| `scripts/worktree-gc-classify.sh` | the `git merge-base --is-ancestor "$sha" main` arms |
| `scripts/assert-main-checkout.sh` | branch references in its checks |
| `scripts/land-lock.sh`, `scripts/land-merge-one.sh`, `scripts/merge-precheck.sh` | branch literals |
| `.claude/skills/land/SKILL.md` | `git checkout -f main`, `git reset --hard origin/main`, `git push origin main`, `git branch --merged main` |
| `.claude/agents/*.md` | `git fetch origin land/<id> main`, `git merge origin/main` |

Re-run `./scripts/harness-doctor.sh` afterwards, and do a real `/code` → `/land` cycle on a throwaway
ticket before trusting it.

### Ticket prefix

**Nothing in the harness hardcodes a ticket prefix.** Every id is handled as an opaque `<id>`
placeholder, and branches are derived as `land/<id>`. Your `bd init` prefix — whatever it is — needs
no substitution anywhere in `.claude/` or `scripts/`.

There is exactly **one** id-shape assumption, and it is load-bearing:

> **An id must not contain a double hyphen (`--`).**

Reviewers and rebase pickups check a branch out locally as `land/<id>--<their-worktree-dir>`, and
`/land`'s bare-ref backstop maps that back to the remote `land/<id>` with `${BR%%--*}`. A prefix
containing `--` truncates the comparison, which makes the "remote still exists — keep" arm
unreachable and turns the backstop into a ref shredder: it would force-delete an in-flight ticket's
ref, and its unpushed commits with it, the moment that worktree goes away.

`harness-doctor.sh` checks this against `issue-prefix` in `.beads/config.yaml` and fails if it finds
a double hyphen. Any ordinary prefix (`acme`, `web`, `k8s`, `proj2`) is fine.

The gate tests use `proj-…` ids as **fixture data** — they fabricate their own repos and tracker
stubs, so they neither read nor constrain your real prefix. (Proof: the suite passes in a repo where
`bd init` has never been run.)

### Quality gates

Gates are opaque commands behind the **0 / 1 / 2 exit contract**
([architecture.md](architecture.md#gate-exit-codes-0--1--2)). Exit 2 is the part people drop and the
part that matters: **any gate you add must distinguish "found a problem" from "could not answer."**

The three invocations to substitute, all appearing in `.claude/agents/coding.md`,
`.claude/agents/code-reviewer.md`, and `.claude/skills/land/SKILL.md`:

```bash
./venv/bin/nox -t fix             # format + lint, fixing in place
./venv/bin/nox -s tests           # the test suite
./venv/bin/nox -s lock_currency   # dependency-lock currency (optional; keep it LAST in /land's && chain)
```

Two rules travel with whatever you substitute:

- **Explicit paths, never activation.** The isolation guard refuses a sourced command, so
  `. ./venv/bin/activate && nox` fails where `./venv/bin/nox` works.
- **`lock_currency` stays last in `/land`'s `&&` chain.** An `&&` chain reports its last-run
  command's status, so anything after it masks an exit 2.

### Concurrency cap

`scripts/code-concurrency-cap.sh` derives how many agents `/code` may run at once from available
memory and the test suite's worker count. Override it per machine, without editing any tracked file,
in `.claude/settings.local.json` (gitignored):

```json
{ "env": { "CODE_MAX_CONCURRENT_AGENTS": "6" } }
```

The derivation reads your test suite's worker count from `HARNESS_TEST_WORKERS`, falling back to
the default it greps out of your `noxfile.py` (it looks for `os.environ.get("HARNESS_TEST_WORKERS")
or "<n>"`). If your noxfile spells that differently, either match the spelling or set
`HARNESS_TEST_WORKERS` explicitly — otherwise the cap is derived from a guessed worker count.
`HARNESS_CAP_MEMINFO` and `HARNESS_CAP_NPROC` are test seams, not tuning knobs.

The default derivation is tuned for a suite that runs parallel test workers, each holding a
meaningful memory footprint. If your suite is cheap, raise it; if each run loads a large model or
container, lower it. **This is a throughput heuristic, not a worst-case memory bound** — don't
"tighten" it into one.

### Models

Set per-agent in each agent file's frontmatter:

| Agent | Ships as | Why |
|---|---|---|
| `coding` | cheaper tier | builds the simplest green thing; the expensive judgment is downstream |
| `code-reviewer` | strongest tier | its own reasoning **is** the correctness review; nothing backs it up |
| `land-review` | strongest tier | the last semantic gate before the default branch |

`/land` itself is a skill, not a subagent — it has no model of its own and inherits the session's.
Run it from a strong-model session.

### Commit attribution

The commit trailer is named in `CLAUDE.md` and referenced by both producer agents. Set it once.

### Labels

The label names are the queue. If you rename one, rename it in **all** of: the agent that sets it,
the skill that consumes it, `/sweep`'s exclude-label list in §2b, and any `--exclude-label` query.
There is no central registry — a rename that misses one site silently strands work at that stage.

The set: `ready-for-code-review`, `ready-for-land`, `needs-rebase`, `land-escalated`, `human`,
`epic-debated`, `epic-ready-to-audit`, `epic-audited`, `epic-audit-gap`, `sweep-digest`.

## Leave these alone

Each of these exists because the corresponding English instruction was violated in practice. Change
them only after reading [architecture.md](architecture.md).

- **The two isolation guards, and the requirement to run them before touching anything.** Worktree
  isolation has been observed failing in two distinct ways, and both are undetectable by branch name.
- **The foreground-only gate rule.** A subagent with no live background children is stopped by the
  harness, so a notification for a backgrounded gate can never arrive. The build stalls forever and
  the work is silently dropped.
- **The clean-tree assertions.** Gates run against the working tree, not `HEAD`. "The tree that
  gated green must be the tree that gets committed and pushed" is the whole invariant.
- **The single-lander lock, and running `/loop /land` on one machine only.** The lock does not cross
  machines.
- **Merge, never rebase, on a `needs-rebase` pickup.** A merge appends; a rebase rewrites commits
  already pushed and would need a force-push. Nothing in this harness force-pushes, which is why no
  step of the loop needs a human to authorize one.
- **The `import.auto: false` invariant.** See [getting-started.md](getting-started.md#2-initialise-the-tracker).
- **`.gitignore`'s `venv/` and `.nox/` entries.** `/land`'s worktree GC reclaims a worktree only
  when it reads clean, and a finished worktree reads clean *only* because build junk is ignored.
  Un-ignore one and the sweep silently reclaims nothing, forever, with no alarm.
- **The `land_head` exact-match vs. `review_head` ancestor-check asymmetry.** Same predicate,
  deliberately different questions. Harmonizing it either misses real drift or falsely flags every
  amend-and-re-gate re-entry.
- **`--limit 0` on every tracker list query.** The tracker emits no truncation signal — a capped read
  is indistinguishable from a short queue.
- **`/land` reporting incidental discoveries rather than filing them.** "Search the tracker before
  filing" looks like the obvious improvement and was rejected: it codifies the improvised filing path
  instead of removing it, and it binds only an agent already consulting the filing guidance — which
  an agent improvising a filing path, by construction, is not.
- **The no-cross-block-shell-state rule.** Each fenced block in a skill is a separate tool
  invocation. This rule was learned by shipping the bug.

## Adding a new skill or agent

- **Agents that write need `isolation: worktree` in their own frontmatter**, not at the dispatch call
  site. The requirement travels with the *role*, so it holds however the agent is dispatched.
- **Any agent that writes must run both guards** before its first `Edit`/`Write`, and re-run the
  isolation guard before its first `git commit`.
- **Persist across blocks via files, not variables.** Use `scripts/land-state-load.sh` for the load
  side — it has exactly two policies (missing-fatal/empty-OK, and both-fatal), so a new call site
  picks one by argument rather than hand-rolling another `cat` spelling.
- **Assert that state loaded.** A loop that iterates zero times and exits 0 is indistinguishable
  from a clean pass with nothing to do.
- **If a new label can mark a ticket mid-pipeline, add it to `/sweep` §2b's exclude list** — or the
  stranded-work report will list live in-flight work every pass.

## Known rough edges in this export

- **Script header comments still narrate incidents from the source project** in a generic form
  ("an earlier fix", "OBSERVED"). The narration is accurate about the failure mode and useful when
  you're deciding whether you may change a predicate; it just no longer cites ticket ids. The
  executable code is unmodified apart from the branch-name and project-name substitutions.
- **You can drop the gate tests that cover skills you don't use** — the modules are independent and
  `tests/README.md` tiers them. What you should not drop are the markdown scanners: they are the only
  check on the bash *inside* the skills, which no linter reaches.
- **The gate tests ship and pass, but they are pins.** `tests/` carries 42 test modules (1063 tests) that
  enforce the mechanisms above. Several assert on **exact strings** in the skill markdown, so a
  legitimate edit to a skill will fail one — deliberately: that failure is the review prompt. See
  `tests/README.md`.
- **`scripts/docs_index_*.py`, `check_links.py`, and `check_docstring_refs.py`** are included as
  generically useful tooling but are not wired into any skill. They assume a `docs/` tree; read each
  script's header before adopting it.
- **`.claude/statusline.sh`** renders tracker queue state in the status line. It is ported but only
  lightly reviewed; delete the `statusLine` key from `.claude/settings.json` if you don't want it.
