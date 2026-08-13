#!/usr/bin/env bash
#
# /land's isolation replay: on a RED combined re-gate, replay the accepted set
# one branch at a time, re-gating after each, to attribute the red to a branch.
#
# RESUMABLE BY DESIGN. Per branch this runs three gate sessions, plus two
# baseline runs before the loop -- `2 + 3N` full gate invocations. A single Bash
# tool call is capped at 600s and the harness forbids backgrounding a gate, so a
# straight-through loop hits that ceiling at a modest queue size, mid-loop. The
# consequence is not merely a failed pass: nothing gets attributed, so nothing is
# bounced, the next pass rebuilds the same accepted set and reds again. It
# re-loops. This script therefore works to a DEADLINE, persists its position, and
# asks to be re-invoked (exit 3).
#
# The deadline default lives HERE, not at the call site, so a skill edit cannot
# silently raise it past the tool cap.
#
# IT CLASSIFIES; THE CALLER ACTS. On a culprit it backs the branch out and
# reports it -- it does NOT bounce. Bouncing needs a live-descendant check, a
# supersede, and a rebuild ticket carrying land-review's findings: judgment plus
# tracker writes, which stay with the agent. It also does not drop a culprit's
# dependents, because the caller may escalate instead of bouncing (a bounce that
# would strand a live descendant is an escalation), and only the caller knows
# which. On a plain merge CONFLICT it does drop dependents, because that outcome
# is mechanical and has no judgment in it.
#
# Usage:
#   scripts/land-replay.sh --accepted <f> --landed <f> --msg-dir <d>
#                          --conflicts-dir <d> --state <f>
#                          [--graph <f>] [--own-token <t>]
#                          [--base-ref <ref>] [--deadline-seconds <n>]
#
# Output (stdout), one record per line, tab-separated:
#   SURVIVOR <id>     merged and gated green; kept, and appended to <landed>
#   CONFLICT <id>     textual conflict against an earlier survivor; kicked back
#   HELD     <id>     dropped because its base conflicted; owes a HELD note
#   CULPRIT  <id>     turned the gate red; backed out. Caller bounces or escalates
#   MORE     <n>      deadline reached with <n> branches left; re-invoke to resume
#
# Exit codes:
#   0  finished -- every remaining branch merged green
#   1  a CULPRIT was found and backed out; caller must act, then re-invoke
#   2  machine fault, or a baseline red (not attributable to any branch): stop
#      the pass, land nothing further
#   3  deadline reached, progress persisted; re-invoke to continue
set -u

TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || TOP=""
[ -n "$TOP" ] || { echo "GATE COULD NOT RUN: not inside a git repository" >&2; exit 2; }

ACCEPTED=""; LANDED=""; MSG_DIR=""; CONFLICTS_DIR=""; STATE=""; GRAPH=""; OWN_TOKEN=""
BASE_REF="origin/main"
#: Default deadline. Deliberately well under the 600s tool cap: the check below
#: refuses to START a gate it predicts would cross this, and that prediction is
#: an estimate, so the margin absorbs a slower-than-average run.
DEADLINE=480
while [ "$#" -gt 0 ]; do
  case "$1" in
    --accepted)         shift; ACCEPTED="${1:-}" ;;
    --landed)           shift; LANDED="${1:-}" ;;
    --msg-dir)          shift; MSG_DIR="${1:-}" ;;
    --conflicts-dir)    shift; CONFLICTS_DIR="${1:-}" ;;
    --state)            shift; STATE="${1:-}" ;;
    --graph)            shift; GRAPH="${1:-}" ;;
    --own-token)        shift; OWN_TOKEN="${1:-}" ;;
    --base-ref)         shift; BASE_REF="${1:-}" ;;
    --deadline-seconds) shift; DEADLINE="${1:-}" ;;
    *) echo "GATE COULD NOT RUN: unknown argument '$1'" >&2; exit 2 ;;
  esac
  [ "$#" -gt 0 ] || { echo "GATE COULD NOT RUN: trailing option needs a value" >&2; exit 2; }
  shift
done
for req in ACCEPTED LANDED MSG_DIR CONFLICTS_DIR STATE; do
  eval "v=\$$req"
  [ -n "$v" ] || { echo "GATE COULD NOT RUN: --$(echo "$req" | tr 'A-Z_' 'a-z-') is required" >&2; exit 2; }
done
case "$DEADLINE" in ''|*[!0-9]*) echo "GATE COULD NOT RUN: --deadline-seconds must be an integer" >&2; exit 2 ;; esac
# Clamp rather than trust: a caller that passes 900 would reintroduce exactly the
# ceiling this script exists to stay under.
[ "$DEADLINE" -gt 570 ] && DEADLINE=570
[ "$DEADLINE" -lt 30 ] && DEADLINE=30

[ -f "$ACCEPTED" ] || { echo "GATE COULD NOT RUN: accepted file '$ACCEPTED' does not exist" >&2; exit 2; }
[ -d "$MSG_DIR" ]  || { echo "GATE COULD NOT RUN: msg dir '$MSG_DIR' does not exist" >&2; exit 2; }
mkdir -p "$CONFLICTS_DIR" || exit 2

START="$(date +%s)"

# --- state -----------------------------------------------------------------
# Plain key=value lines under $STATE_DIR. `done` records ids this run has
# finished with (survivor, conflicted, or backed-out culprit) so a resume never
# re-merges them; `est` carries the measured gate duration forward so the very
# first deadline check after a resume is informed rather than guessed.
state_get() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" | tail -1; }
state_set() {
  local k="$1" v="$2" tmp="$STATE.tmp"
  { [ -f "$STATE" ] && grep -v "^$k=" "$STATE"; printf '%s=%s\n' "$k" "$v"; } > "$tmp" 2>/dev/null
  mv "$tmp" "$STATE"
}
DONE_FILE="$STATE.done"
is_done()   { [ -f "$DONE_FILE" ] && grep -qxF "$1" "$DONE_FILE"; }
mark_done() { printf '%s\n' "$1" >> "$DONE_FILE"; }

EST="$(state_get est)"; [ -n "$EST" ] || EST=120

# --- gates -----------------------------------------------------------------
# LAND_GATE_CMD exists so a test can substitute a stub; unset, the real sessions
# run. Either way the status is read DIRECTLY -- never through a pipe, whose exit
# status is its last element's, so a killed gate would surface as exit 0.
GATE_CMD="${LAND_GATE_CMD:-}"
run_gate() {
  if [ -n "$GATE_CMD" ]; then "$GATE_CMD" "$1"; return $?; fi
  case "$1" in
    fix)   "$TOP/venv/bin/nox" -t fix ;;
    tests) "$TOP/venv/bin/nox" -s tests ;;
    lock)  "$TOP/venv/bin/nox" -s lock_currency ;;
    *)     return 2 ;;
  esac
}

# --- first invocation: reset, baseline ------------------------------------
if [ "$(state_get baselined)" != "1" ]; then
  "$TOP/scripts/assert-main-checkout.sh" || exit 2
  git reset --hard "$BASE_REF" >/dev/null || {
    echo "GATE COULD NOT RUN: could not reset to '$BASE_REF'" >&2; exit 2; }
  : > "$LANDED"          # the reset discarded every merge the first pass recorded
  : > "$DONE_FILE"

  # BASELINE EVERY GATE BEFORE ATTRIBUTING ANYTHING. No gate here is a pure
  # function of the tree, so a red one may have nothing to do with the accepted
  # set -- and this loop DELETES what it blames. An ambient environment variable
  # in the landing shell, set nowhere in the repo, once reddened the suite on a
  # bare ref with nothing merged; trusting it would have closed an innocent
  # ticket and deleted a reviewed branch.
  b0="$(date +%s)"
  run_gate tests; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "GATE COULD NOT RUN: the suite is red on bare $BASE_REF, before any branch merged." >&2
    echo "Not attributable to anything in the accepted set. Land nothing; surface as a human" >&2
    echo "decision, and check the landing shell's own environment first." >&2
    exit 2
  fi
  # One real measurement beats a guess for every deadline check that follows.
  EST=$(( $(date +%s) - b0 )); [ "$EST" -lt 5 ] && EST=5
  state_set est "$EST"

  run_gate lock; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "GATE COULD NOT RUN: lock_currency is red on bare $BASE_REF (exit $rc), before any" >&2
    echo "branch merged -- not attributable to the accepted set. Land nothing." >&2
    exit 2
  fi
  state_set baselined 1
fi

# --- the replay loop -------------------------------------------------------
remaining_count() {
  local n=0 id
  while read -r id; do
    [ -n "$id" ] || continue
    is_done "$id" || n=$((n + 1))
  done < "$ACCEPTED"
  printf '%s' "$n"
}

for id in $(cat "$ACCEPTED"); do
  [ -n "$id" ] || continue
  is_done "$id" && continue
  # Membership is re-checked every iteration: an earlier conflict may have taken
  # this branch out of the set, and merging it anyway lands a departed base's
  # content under this ticket's name.
  grep -qxF "$id" "$ACCEPTED" || continue

  # Deadline: never START work whose gates are predicted to cross it. Three gate
  # sessions per branch, so budget 3 * EST.
  now="$(date +%s)"
  if [ $(( now - START + (3 * EST) )) -gt "$DEADLINE" ]; then
    left="$(remaining_count)"
    printf 'MORE\t%s\n' "$left"
    exit 3
  fi

  if CONFLICTS=$("$TOP/scripts/land-merge-one.sh" "$id" "$MSG_DIR" "$OWN_TOKEN"); then
    rc=0
  else
    rc=$?
  fi
  case "$rc" in
    0) : ;;
    1)
      # Conflicts with an earlier survivor. Its content was never judged bad, so
      # this is a kick-back, not a bounce -- and it leaves the merge set, so it
      # takes its dependents with it. Mechanical, no judgment: done here.
      printf '%s\n' "$CONFLICTS" > "$CONFLICTS_DIR/$id"
      printf 'CONFLICT\t%s\n' "$id"
      mark_done "$id"
      dropargs="$id --accepted $ACCEPTED"
      [ -n "$GRAPH" ] && dropargs="$dropargs --graph $GRAPH"
      # shellcheck disable=SC2086
      "$TOP/scripts/drop-from-accepted.sh" $dropargs \
        | awk -F'\t' '$1 == "HELD" { print "HELD\t" $2 }' || {
          echo "GATE COULD NOT RUN: drop-from-accepted.sh failed for '$id'" >&2; exit 2; }
      continue
      ;;
    *)
      printf 'FAULT\t%s\n' "$id"
      echo "GATE COULD NOT RUN: land-merge-one.sh machine fault on '$id' -- never a branch verdict" >&2
      exit 2
      ;;
  esac

  g0="$(date +%s)"
  run_gate fix;   fix_rc=$?
  run_gate tests; tests_rc=$?
  EST=$(( $(date +%s) - g0 )); [ "$EST" -lt 5 ] && EST=5
  state_set est "$EST"

  if [ "$fix_rc" -ne 0 ] || [ "$tests_rc" -ne 0 ]; then
    git reset --hard HEAD~1 >/dev/null || exit 2   # back the culprit out
    mark_done "$id"
    printf 'CULPRIT\t%s\n' "$id"
    exit 1
  fi

  run_gate lock; rc=$?
  case "$rc" in
    0)
      printf '%s\n' "$id" >> "$LANDED"
      printf 'SURVIVOR\t%s\n' "$id"
      mark_done "$id"
      ;;
    2)
      # A machine fault mid-loop is NOT this branch's verdict. Stop; never bounce.
      echo "GATE COULD NOT RUN: lock_currency machine fault on '$id' -- stopping, landing nothing further" >&2
      exit 2
      ;;
    *)
      git reset --hard HEAD~1 >/dev/null || exit 2
      mark_done "$id"
      printf 'CULPRIT\t%s\n' "$id"
      exit 1
      ;;
  esac
done

exit 0
