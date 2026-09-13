# Dev-only harness tests

Tests of the harness's **own internals** — they run here, in the export checkout, while developing
the harness. They are never installed into a project, because nothing a served project does can
change their verdict:

| Module | Gates | Why it stays here |
|---|---|---|
| `test_no_hand_derived_skill_md_path` | no test module re-derives a `SKILL.md`/agent path outside the shipped conftest | suite DRY-ness — protects the suite as it grows, not the harness a project runs |
| `test_land_loops_shared_idioms` | the two merge loops' hand-copied idioms stay byte-identical | drift between two frozen harness scripts |
| `test_beads_passive_exports` | every consumer reads the canonical passive-export list | cross-file drift among frozen harness files |
| `test_sweep_pipeline_label_roster_gate` | the pipeline-label roster agrees across five skills | cross-skill drift |
| `test_harness_doctor` | `scripts/harness-doctor.sh` itself | a project *runs* the doctor; it does not need to test it |
| `test_check_links` | `scripts/check_links.py` | tooling not wired into any skill (see docs/customizing.md) |

Everything a project *can* affect — the guard scripts on its machine, the skill markdown it is
told to edit — ships in `template/tests/harness/`.

## Running

The modules import the shipped suite's helpers; `conftest.py` here puts `template/tests/harness`
on the path and re-exports the shipped conftest, so `REPO_ROOT` is `template/`.

```bash
cd template
CLAUDE_PROJECT_DIR=$PWD uv run --frozen pytest ../dev-tests -q      # this directory
CLAUDE_PROJECT_DIR=$PWD uv run --frozen nox -s harness_tests        # the shipped suite, in place
```

`CLAUDE_PROJECT_DIR` is needed only when running inside the export checkout: the hook-wiring
tests resolve the project dir the way Claude Code sets it, and the export root is not `template/`.
