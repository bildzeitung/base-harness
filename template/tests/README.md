# Harness gate tests

These are the tests that keep the harness's own mechanisms honest. They are **not** application
tests — they have zero dependency on any project code, so they run in a fresh repo unchanged.

```bash
./venv/bin/pytest tests -q
```

## What they gate

| Kind | Examples | Why it can't be prose |
|---|---|---|
| **Guard-script behaviour** | `test_isolation_guard`, `test_recycled_worktree_guard`, `test_land_lock`, `test_merge_precheck`, `test_worktree_gc_classify` | fixture-backed runs against real git repos — the destructive paths are exactly where a regression is unrecoverable |
| **Skill-markdown scanners** | `test_skill_bash_state` (no cross-block shell state), `test_bd_list_limit_gate` (`--limit 0` on every tracker query), `test_land_skill_guard_coverage` (every mutating fence is guarded) | the skills' bash is *executed* by an agent but lives in markdown, where no linter reaches |
| **Hook wiring** | `test_gh_write_guard`, `test_bd_deps_guard` | the hooks are JSON strings in `settings.json`; nothing else type-checks them |
| **Cross-file invariants** | `test_validate_sha40_call_sites`, `test_no_hand_derived_skill_md_path`, `test_sweep_pipeline_label_roster_gate` | they pin that two files agree — the exact thing that drifts silently |

## They are pins, and pins go stale on purpose

Several assert on **exact strings** in the skill markdown. That is deliberate: a reworded gate is a
gate you no longer have. When you legitimately change a skill, the corresponding test fails and you
update it **deliberately** — that failure is the review prompt, not noise.

Three carry allowlists (`test_bd_list_limit_gate`'s prose-skip entries,
`test_land_skill_guard_coverage`'s mutating-command exemptions). Each demands its entries still
match something live, so an exemption that stops applying fails rather than silently exempting
nothing.

## Shared helpers

- `conftest.py` — the markdown fence parser and corpus locators. The fence rules live here and
  nowhere else; several gates key on them.
- `_fence_parsing.py` — the fence-marker primitives.
- `_gitrepo.py` — real-git-repo fixtures.
- `_hookharness.py` — locates and runs a `PreToolUse` hook out of `settings.json`. It finds a hook by
  **script name** (e.g. `gh-write-guard.sh`), so renaming a guard script is a deliberate, failing
  change rather than a silent miss.
