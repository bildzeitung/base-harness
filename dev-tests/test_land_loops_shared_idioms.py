"""Pins the shared idioms of scripts/land-merge-batch.sh and scripts/land-replay.sh
byte-for-byte equal between the two files.

`/land`'s Section 3 has two merge loops with the same shape -- the first-pass
batch merge (land-merge-batch.sh) and the isolation-replay loop
(land-replay.sh) -- kept as two separate scripts rather than unified into one:
the two loops' verdict sets genuinely differ (LANDED/CONFLICT/HELD/SKIPPED
vs. SURVIVOR/CONFLICT/HELD/CULPRIT/MORE), and only the replay loop gates
per-branch, so a shared loop body would need its own conditional gating mode
threaded through the most destructive code path in the repo.

What was never enforced is that the two loops' remaining SHARED idioms --
copied by hand between the scripts -- stay identical. This test closes that
gap mechanically: it pins the two idioms both scripts' headers call out
explicitly as traps learned the hard way --

  * the `grep -qxF "$id" "$ACCEPTED"` / `grc=$?` / `case "$grc" in` ...
    stale-membership re-check, pinned as its 0/1/else partition header plus
    the else arm's machine-fault diagnostic (the arms' ACTIONS legitimately
    differ: the batch prints SKIPPED where the replay `continue`s).
  * the `if CMD; then rc=0; else rc=$?; fi` merge-dispatch idiom (NOT the
    negated `if ! CMD; then rc=$?; fi` form, which would silently read a
    machine-fault exit 2 as a clean merge).

as exact substrings that must appear, byte-for-byte, in BOTH scripts. An edit
to either idiom in one file that is not mirrored in the other now fails this
test instead of only being caught by someone reading both files side by side.
"""

from __future__ import annotations

import pytest
from conftest import REPO_ROOT

BATCH_SCRIPT = REPO_ROOT / "scripts" / "land-merge-batch.sh"
REPLAY_SCRIPT = REPO_ROOT / "scripts" / "land-replay.sh"

# The stale-membership re-check's partition header. The 1) and *) arms' ACTIONS
# differ by design between the two loops, so the header is pinned here and the
# else arm's diagnostic separately below -- together they keep the 0/1/else
# partition itself from being collapsed in either script.
GREP_RECHECK_HEADER = (
    '  grep -qxF "$id" "$ACCEPTED"\n  grc=$?\n  case "$grc" in\n    0) ;;\n'
)

# The else arm's first diagnostic line: a grep that fails for any reason other
# than "absent" (the file vanished, an I/O error) must be a machine fault,
# never read as "already dropped" -- which would silently skip every remaining
# id while leaving them in the accepted file.
GREP_RECHECK_FAULT_LINE = (
    '      echo "GATE COULD NOT RUN: grep failed (exit $grc) '
    "re-checking '$id' in '$ACCEPTED'\" >&2\n"
)

# The merge-dispatch idiom: `if CMD; then rc=0; else rc=$?; fi`, never the
# negated form. Fully identical in both scripts, documented in each file's
# header as the reason this exact shape matters.
MERGE_DISPATCH_IDIOM = (
    '  if CONFLICTS=$("$TOP/scripts/land-merge-one.sh" "$id" "$MSG_DIR" "$OWN_TOKEN"); then\n'
    "    rc=0\n"
    "  else\n"
    "    rc=$?\n"
    "  fi\n"
)


# name -> (pinned text, why this exact shape matters). The "why" is what the
# failure message carries, so whoever trips this test learns what the drift
# would have cost rather than just which bytes moved.
PINNED_IDIOMS = {
    "stale-membership re-check": (
        GREP_RECHECK_HEADER,
        (
            "the 0/1/else partition that keeps a grep failure from being read as "
            "'already dropped' and silently skipping the rest of the loop"
        ),
    ),
    "stale-membership fault arm": (
        GREP_RECHECK_FAULT_LINE,
        (
            "the else arm's machine-fault diagnostic -- deleting it from either "
            "script silently demotes a grep I/O failure to 'already dropped'"
        ),
    ),
    "merge-dispatch": (
        MERGE_DISPATCH_IDIOM,
        (
            "`if CMD; then rc=0; else rc=$?; fi` -- never the negated form, which "
            "would silently read land-merge-one.sh's machine-fault exit 2 as a clean merge"
        ),
    ),
}


@pytest.mark.parametrize("script", [BATCH_SCRIPT, REPLAY_SCRIPT], ids=lambda p: p.name)
@pytest.mark.parametrize("name", sorted(PINNED_IDIOMS))
def test_idiom_pinned_in_both_scripts(name: str, script) -> None:
    idiom, why = PINNED_IDIOMS[name]
    assert idiom in script.read_text(), (
        f"{script.name}'s {name} idiom drifted from the pinned copy: {why}. "
        "The two loops are deliberately NOT unified, so this test is the only "
        "thing keeping their hand-copied idioms in sync -- if the drift was "
        "intentional, mirror it in the other script and update the pin here "
        "deliberately."
    )
