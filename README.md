# Agent harness

A working multi-agent development loop for Claude Code: agents build tickets in isolated git
worktrees, a *different* agent reviews them, and a single lander owns every write to the default
branch. It is designed to run unattended for hours and to fail loudly rather than silently.

This is an export of a harness that has been driving a real project for months. It carries the
mechanisms — the guards, the label protocol, the lock discipline — without that project's history.

## The loop in one picture

```
bd ready ──▶ /code ──▶ coding agent ──▶ code-reviewer agent ──▶ /land ──▶ main
             (fan-out)   builds in a      technical review in    semantic review,
                         worktree,        its OWN worktree,      batch merge,
                         pushes           re-gates, pushes       re-gate, close
                         land/<id>        land/<id>              tickets
                             │                    │                   │
                    ready-for-code-review   ready-for-land        (closed)
```

Three side loops keep it honest:

| Skill | Runs | Does |
|---|---|---|
| `/challenge` | before building | stress-tests a plan or ticket tree; finds the ambiguity before it becomes a rebuild |
| `/epic-audit` | after an epic's children close | asks whether the delivered set actually completed the epic |
| `/sweep` | on a timer | surfaces work that has stopped waiting on a human and nothing else consumes |

## The three ideas worth stealing

**1. The reviewer is never the author.** Three separate agents touch a change: one builds it, a
second reviews it technically (correctness + simplification), a third judges semantically whether it
*should* land. Each is dispatched fresh, with its own worktree and its own context. An agent
attached to its own work is the worst judge of whether it belongs on the default branch.

**2. Exactly one writer for the default branch.** Producers never merge. `/land` is the sole owner of
every write to `main`, holds a machine-local lock while it runs, and can be run on a timer without
overlapping itself. Everything else pushes a `land/<id>` branch and stops.

**3. Guards are scripts, not sentences, and the scripts are themselves tested.** "Don't edit files on the default branch" is an instruction
an agent will violate under load. `scripts/isolation-guard.sh` is a command that exits 1. Every rule
in this harness that matters is a `PreToolUse` hook or a script an agent must run and check, because
prose is advice and an exit code is a fence. `tests/harness/` then gates the guards — including
scanners that read the skills' *markdown*, since the bash an agent executes out of a `SKILL.md` is
reachable by no linter. Those tests test the harness, never your project, so they run on a gate
only when a branch touched a harness path (`scripts/harness-tests-gate.sh`); your own suite under
`tests/` runs every time.

## What's here

```
docs/
  getting-started.md    install it into a fresh project, step by step
  architecture.md       the pipeline, the label protocol, the invariants, why each guard exists
  customizing.md        what to change per project — gates, branch name, commit trailer, models
template/               the files that get copied into your project
  CLAUDE.md             project instructions every agent reads (imported into subagents too)
  .claude/agents/       coding, code-reviewer, land-review
  .claude/skills/       code, land, challenge, epic-audit, sweep, release
  .claude/settings.json hooks, permissions, worktree config
  scripts/              the guards, gates, and lock machinery
  tests/harness/        988 tests that gate the harness's own mechanisms — they pass on a fresh install;
                        tests/ itself is yours (nox -s tests ignores tests/harness/)
  noxfile.py            the gate sessions the agents invoke (nox -t fix / -s tests / -s harness_tests / -s lock_currency / -s shellcheck)
  pyproject.toml        placeholder uv project: no runtime deps, a dev group with the gate tools — rename and fill in
                        (no uv.lock ships: the installer resolves one on your machine, and you commit it)
  docs/conventions.md   your project's style fiats (starts nearly empty — fill it in)
install.sh              copies template/ into a target repo, with a dry-run mode
dev-tests/              tests of the harness's own internals (suite DRY-ness, cross-file drift, the
                        doctor, unwired tooling) — run here while developing the harness, never shipped
```

## Prerequisites

- **Claude Code** with subagent and worktree isolation support
- **[beads](https://github.com/gastownhall/beads)** (`bd`) — the issue tracker the whole loop is
  built on, backed by a local Dolt database and synced over `refs/dolt/data` on your git remote
- **jq** — required, not optional; the `PreToolUse` guards deny every `Bash` call without it
- **[uv](https://docs.astral.sh/uv/)** — owns the Python interpreter, `./.venv`, and `uv.lock`; the
  quality gates run as `uv run --frozen nox ...`
- **Docker** — only if you want the Mermaid diagram validation gate

## Quick start

```bash
./install.sh /path/to/your/project --dry-run   # see what would be written
./install.sh /path/to/your/project
cd /path/to/your/project
./scripts/harness-doctor.sh
uv run --frozen nox -s harness_tests   # 988 passed
```

`install.sh` also runs `bd init` for you, non-interactively and with the harness's opinions
(`--skip-agents`, `import.auto: false`) baked in, then builds `./.venv` with `uv sync` (uv finds or
downloads a Python that satisfies `requires-python`, and writes the `uv.lock` you commit), creates a private GitHub `origin` via `gh`
when the repo has none, and
publishes the tracker over it. Then read
[`docs/getting-started.md`](docs/getting-started.md), which walks through the parts it does not do:
`bd dolt push`, the first ticket, and the first `/code` run.
