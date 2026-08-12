# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd prime` for full workflow context.

> **Architecture in one line:** Issues live in a local Dolt database (`.beads/dolt/`); cross-machine
> sync uses `bd dolt push/pull` (a git-compatible protocol), stored under `refs/dolt/data` on your
> git remote — separate from `refs/heads/*` where your code lives. `.beads/issues.jsonl` is a
> passive export, not the wire protocol.

## Quick reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>           # Complete work
bd dolt push            # Push tracker data to the remote
```

## Rules

- Use `bd` for ALL task tracking — no markdown TODO lists.
- Use `bd remember` for persistent knowledge — no ad-hoc memory files.
- **`import.auto: false` is a hard invariant.** Sync only via `bd dolt push`/`bd dolt pull`; never
  `bd import` the JSONL export as a substitute (it only upserts and silently misses deletions).
- Never commit `.beads/issues.jsonl` from an agent.

## Non-interactive shell commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.
`cp`, `mv`, and `rm` may be aliased to `-i` on some systems, causing an agent to hang indefinitely
waiting for y/n input.

```bash
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

Others that may prompt: `scp`/`ssh` (use `-o BatchMode=yes`), `apt-get` (`-y`), `brew`
(`HOMEBREW_NO_AUTO_UPDATE=1`).

## Git policy

Do not commit, push, or sync unless the active workflow explicitly calls for it. In this repo the
pipeline is explicit about who writes what:

- **Producers** (`coding`, `code-reviewer`) commit and push only to their own `land/<id>` branch.
- **`/land`** is the single owner of every write to the default branch.
- Everything else reports changed files, validation, and suggested next commands, and waits.

See [`CLAUDE.md`](CLAUDE.md) for the full contract.
