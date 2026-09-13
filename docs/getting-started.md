# Getting started

Installing the harness into a fresh project, end to end. Budget about 30 minutes, most of it
prerequisites and filling in your own project's `CLAUDE.md`.

## 0. Prerequisites

| Tool | Why | Check |
|---|---|---|
| **git** | worktrees are the isolation mechanism | `git --version` |
| **[beads](https://github.com/gastownhall/beads)** (`bd`) | the issue tracker the whole loop runs on | `bd version` |
| **jq** | **required, not optional** — the `PreToolUse` guards deny *every* `Bash` call without it | `jq --version` |
| **[uv](https://docs.astral.sh/uv/)** | owns the Python interpreter, `./.venv`, and `uv.lock`; the quality gates run through it | `uv --version` |
| **docker** | only for Mermaid diagram validation | `docker ps` |

> **jq is not a soft dependency.** The guard hooks are written to **deny** rather than fall through
> unchecked when they can't evaluate a command. That means a machine without jq denies every `Bash`
> call *including the one that would install jq*. Install it from a shell outside Claude Code.

## 1. Install the files

```bash
./install.sh /path/to/your/project --dry-run   # see exactly what would be written
./install.sh /path/to/your/project
```

The target does not need to be a git repository yet: the installer runs `git init -b main` if it
isn't one. `install.sh` never overwrites an existing file unless you pass `--force`. After copying
it runs `bd init` for you, non-interactively (see step 2), then builds `./.venv` (see step 3). If
the repo has no git remote and `gh` is logged in, it also creates a **private** GitHub repository
named after the target directory (no wiki, no issues — the tracker is beads) and adds it as `origin`;
pass `--skip-remote` to opt out, and any existing remote is left alone. With an `origin` in place it
publishes the tracker over it (see step 2).

If your repo's default branch isn't `main`, the installer says so and stops short of rewriting
anything — see [customizing.md](customizing.md#default-branch-name).

## 2. The tracker (done by `install.sh`)

`bd init` is interactive by default. The installer runs the opinionated non-interactive equivalent
so the tracker comes up the same way every time:

```bash
bd init --non-interactive --role maintainer --skip-agents --prefix <prefix>
```

- **`--skip-agents`** — bd would otherwise write its own `CLAUDE.md`, `.claude/settings.json`,
  `AGENTS.md`, `.codex/` and `.agents/` straight over the harness files.
- **`--prefix`** defaults to the target directory's basename; override with
  `./install.sh <repo> --prefix <p>`. The installer rejects a prefix containing `--` (the one id-shape
  rule, see [customizing.md](customizing.md#ticket-prefix)) and anything bd would silently rewrite.
- **Hooks are kept.** bd points `core.hooksPath` at `.beads/hooks/`; anything that was in
  `.git/hooks/` is bypassed from then on.
- **`import.auto: false`** is written into `.beads/config.yaml` and committed. This is the single
  most important configuration in the harness, and the reason the installer writes the file rather
  than calling `bd config set` (which stores the key in the Dolt database, where
  `harness-doctor.sh` cannot see it).

> **Why.** With auto-import on, the `post-checkout`/`post-merge` git hooks replay
> `.beads/issues.jsonl` back into Dolt after any pull or merge. A `git pull --rebase` following a
> `bd close` then replays a committed export from *before* the close and **silently reverts it**.
> The close looks successful, the ticket quietly reopens, and the pipeline re-dispatches work that
> was already done. This bit the source project three separate times before it was understood.

You will find two commits on your branch afterwards: bd's own `bd init: initialize beads issue
tracking`, and the installer's `chore: pin beads import.auto=false`. If `.beads/` already exists the
installer leaves the tracker entirely alone, and `--skip-bd-init` skips this step outright.

**Publishing is done for you too**, when the repo has an `origin` (created by the installer via
`gh`, or already there). `bd init` points the Dolt remote at it, and the installer runs
`scripts/bd-dolt-push.sh`, which puts the tracker on the wire as `refs/dolt/data`. Dolt refuses to
push to a git remote with no branches, so if `origin` was empty the installer pushes your branch
first; a remote that already has branches is not pushed to, since merging is your call. If there was
no `origin`, add one and run it yourself:

```bash
git push -u origin main          # only if the remote is empty
./scripts/bd-dolt-push.sh        # publishes over refs/dolt/data
```

## 3. The Python environment (done by `install.sh`)

The harness is a standard [uv](https://docs.astral.sh/uv/) project. The installer runs `uv sync`
for you, which finds (or downloads) a Python satisfying `requires-python`, resolves `uv.lock`,
creates `./.venv` at the repo root, and installs into it. `pyproject.toml` ships as a placeholder:
no runtime dependencies, and a `dev` dependency group holding the gate tools (`nox`, `pytest`,
`pytest-xdist`, `ruff`, `shellcheck-py`, `typer`). **No lock ships with the harness.** A resolution
is your project's artifact, not the harness's, so the installer writes `uv.lock` on your machine
and you commit it with your first commit; the `lock_currency` gate reads it from then on. If your
repo already had a `uv.lock`, the installer runs `uv sync --locked` instead and never moves it.
Rename the project and add your dependencies in step 5 with `uv add <pkg>`, which updates
`pyproject.toml` and `uv.lock` together.

The everyday commands, all through `uv`:

```bash
uv sync                          # (re)build ./.venv from uv.lock
uv run --frozen nox -t fix       # format + lint
uv run --frozen nox -s tests     # your test suite (everything except tests/harness/)
uv run --frozen nox -s harness_tests   # the harness's own gate tests under tests/harness/
uv add <pkg>                     # add a runtime dependency; updates pyproject.toml and uv.lock
uv lock --upgrade-package <pkg>  # move one pin; scripts/update-deps.sh does this gated, with a diff
```

Gates run `--frozen` on purpose: a plain `uv run` would silently rewrite a lock that no longer
matches `pyproject.toml`, and that staleness is what the `lock_currency` gate exists to report.
Optionally pin an interpreter with `uv python pin 3.12` (writes `.python-version`; uv honours it).

**No uv means the step is skipped, not failed.** The installer says so and the files are all in
place; [install uv](https://docs.astral.sh/uv/getting-started/installation/) and run `uv sync`
yourself.

A template `noxfile.py` ships with the harness, defining the handles the agent files invoke by
name — the `fix` **tag** (`nox -t fix`), the `tests` **session** (`nox -s tests`, your suite),
`harness_tests` (the harness's own suite under `tests/harness/`, reached on a gate through
`scripts/harness-tests-gate.sh` only when a branch touched a harness path), `lock_currency`, and
`shellcheck` (lints every `.sh` file through the venv's `shellcheck-py`). Replace the bodies with your real tooling but **keep the names**. The harness treats
them as opaque gate commands behind a 0/1/2 exit contract; see
[customizing.md](customizing.md#quality-gates).

## 4. Verify the install

```bash
./scripts/harness-doctor.sh
```

Then run the harness's own gate tests — they ship green, need no project code, and need no commit
yet (the scan-scope checks count untracked files too):

```bash
uv run --frozen nox -s harness_tests   # 988 passed
```

`nox -s tests` is *your* suite and passes empty on a fresh install (pytest's "no tests collected"
is a pass there, not a red gate). Put your tests under `tests/`; the harness's live under
`tests/harness/` and `nox -s tests` ignores that directory.

`harness-doctor.sh` checks prerequisites, guard scripts, agents and skills, hook wiring, the
auto-import invariant, gate-test presence, and `.gitignore` coverage. It is read-only — it reports, it never repairs. Fix every **FAIL** before
going further; **warn** lines are informational.

## 5. Fill in the placeholders

Four files ship as templates with `<angle bracket>` placeholders:

- **`CLAUDE.md`** — the "What this is" section, your commit attribution line, and the list of design
  docs. Everything else is harness contract you should leave alone until you've read
  [architecture.md](architecture.md).
- **`docs/conventions.md`** — delete the two example fiats and write your own. Keep the litmus in
  the preamble: if a rule earns a *why*, it belongs in a design doc, not here.
- **`docs/design.md`** — fill in the sections. It ships as a skeleton with the expected headings;
  `CLAUDE.md` points agents there first.
- **`pyproject.toml`** — the project name, your runtime dependencies (`uv add`), and a
  `[build-system]` once you have a package of your own to install. Keep the `dev` group's tools;
  `uv add` keeps `uv.lock` current as you go (step 3).

Also create `docs/decisions.md` (open questions) and `docs/configuration.md` (tunables), even if
they start nearly empty. The agents are instructed to route knowledge into them, and a missing file
is where a design fact goes to die in a ticket note instead.

## 6. File your first ticket

```bash
bd create --type=task \
  --title="<something small and real>" \
  --description="<what and why>" \
  --acceptance="<the observable condition that means done>"
bd dolt push
```

**Acceptance criteria are the contract** the semantic reviewer judges the finished branch against. A
ticket without them will get built to somebody's guess and then bounced for not meeting a standard
nobody wrote down.

## 7. Run the loop

```
/code <ticket-id>
```

That dispatches a `coding` producer into its own worktree, then a `code-reviewer` into a second one.
Watch what happens: the producer should push `land/<ticket-id>` and leave the ticket at
`ready-for-code-review`; the reviewer should push onto the same branch and swap it to
`ready-for-land`.

Then:

```
/land
```

which semantic-reviews the branch, merges it `--no-ff`, re-gates, pushes, and closes the ticket.

Once you trust it, run the loops:

```
/loop 5m /land       # on ONE machine only — the lock does not cross machines
/loop 30m /sweep
```

and use bare `/code` to fan out across the whole ready frontier.

## What to expect the first few times

- **The first `/code` run will surface a gap in your ticket.** That's the system working. Use
  `/challenge <id>` before building anything non-trivial.
- **Producers escalate rather than guess.** A ticket with `land-escalated` is waiting on you, not
  broken. `/sweep` surfaces the queue.
- **A `needs-rebase` kick-back is routine**, not an error — it means `/land` declined to spend a
  review on a branch that no longer merges. The next `/code` invocation picks it up automatically.
- **Watch the concurrency cap.** Each agent's gate runs your full test suite. Fan out too wide and
  you will exhaust the machine — the cap exists because that took a host down twice. Set
  `CODE_MAX_CONCURRENT_AGENTS` in `.claude/settings.local.json` if the derived value is wrong for
  your machine.

## A note on the epic gate

`/code` refuses to auto-select a ticket whose parent epic has never been through `/challenge`. The
unblock is to actually debate the epic (`/challenge <epic-id>` — cheap) or to hand-apply the
`epic-debated` label. There is deliberately no bypass flag: the gate exists because children of an
undebated epic got built and landed before anyone noticed the epic was never stress-tested.
