---
name: land
description: Drain the ready-for-land queue — the SINGLE owner of every write to the default branch. Per pass: cheap-precheck each ready-for-land branch (drift + does it still merge — a conflict is kicked back needs-rebase, no review spent); semantic-review the survivors (via the land-review agent) → accept | bounce | escalate; batch-merge the accepted set --no-ff, re-gate once, isolate the culprit on red; then push, bd close the landed tickets, flag any epic whose last child this pass closed with epic-ready-to-audit, publish tracker state, and GC the merged land/<id> branches and local builder worktrees. Bounces open a new linked ticket carrying the findings; escalations leave the branch for a human and land nothing. Run self-paced as /loop 5m /land on ONE machine; a local lockfile guard skips a tick that would overlap a still-running land. Producers (/code) never land their own work — this skill does.
---

# land

I am the **lander** — the single, sole owner of every write to the default branch. Producers build
reviewed, green branches, push them to `origin/land/<id>`, and mark their ticket `ready-for-land`;
they **never** merge, close, or push. I am the other half of that contract: **nothing reaches the
default branch except through me.**

I run on the **primary checkout, on the default branch** — I am the *one* agent allowed to. Producers
are the inverse. I never touch a producer's worktree. I am typically invoked self-paced as
**`/loop 5m /land`** so I drain the queue while you work, with no daemon to manage.

**Run me from a strong-model session.** I am a skill, not a subagent — I have no model of my own and
inherit the session's. My semantic review and combined re-gate are exactly where that judgment earns
its keep.

## The merge decision belongs to the agent that didn't write the code

My **first task per branch is a semantic review I do not perform myself** — I dispatch the
[`land-review`](../../agents/land-review.md) agent. The independence is the point: the producer
already ran the *technical* review on its own branch with gates green; I add the *semantic* gate —
*should this land?* — from the outside. I do not re-run the technical review and I assume the branch
is green until my re-gate says otherwise.

## Governing rule: no fenced block may depend on shell state from another

**I run each fenced `bash` block below as its own, separate Bash tool invocation. Nothing carries
over** — not variables, not arrays, not function definitions, not `trap`s, not `set -e`/`pipefail`,
not background jobs. Anything one block needs from an earlier one is either **re-derived** (cheap,
deterministic — e.g. `$(git rev-parse --git-dir)`) or **persisted to a file** under `$STATE_DIR`
(`.git/land-state/`, which survives `git reset --hard` because that only touches the index and
working tree). Logic shared by two call sites lives in `scripts/`, never in a bash function defined
in one block and called from another.

This is not a style preference — it is a defect this skill has already shipped. One section
populated a `declare -A MSG` associative array that a later section's merge loop read back; by the
time that loop ran, `MSG` was empty, and `git merge -m ''` failed with **completely empty stdout and
stderr**. Every such failure is silent by default, and this is the one skill that writes the default
branch — so **any block that loads state must also assert it loaded** and abort loudly if it did not.
A loop that iterates zero times and exits 0 is indistinguishable from a clean pass with nothing to do.

---

## 0. Single-lander lock — acquire FIRST, every tick

Being the **single** lander is what serializes landing, guaranteed by **(a)** a local "skip if
already running" lockfile and **(b)** the convention that the loop runs on **one machine**.

**This lock is real state that must span the whole pass, across every fenced block** — exactly the
shape the governing rule warns cannot survive a `trap` or a `$$`. Managed inline it was **inert**:
the release fired the instant its own block's shell exited, and the stale-lock reclaim judged
liveness from a PID that is *always* already dead by the time a later block reads it. Both halves
live in `scripts/land-lock.sh`, which replaces them with a wall-clock staleness token.

**The token is a heartbeat, not a one-shot stamp.** Section 2a re-stamps it once per ticket, and
`scripts/land-merge-one.sh` re-stamps on every call, so a long pass never has its *own* lock
reclaimed mid-merge. Two boundary call sites cover the stretches that *grow* with queue size (before
Section 1a, and at the top of Section 4). The single combined re-gate still runs unheartbeated —
that one does not grow with queue size.

**The lock is released explicitly at exactly two sites:** the empty-queue exit in Section 1 and the
end of a full pass in Section 4. **Every other way a pass stops leaves the lock held until it ages
out** (default 1800s). That is correct: a TTL that asks nothing of any exit site cannot be silently
broken by a future "stop the pass" that forgets to release. Adding a release per exit site was
deliberately rejected on that basis.

**A pass in which every branch was bounced, escalated, held, or kicked back is NOT one of those exit
sites.** Section 3's empty-accepted guard distinguishes **missing** (3a never ran — a real silent
failure, aborted loudly) from **empty** (every branch legitimately left the set). The empty case
flows straight through to Section 4, which already handles an empty landed set by construction.

```bash
STATE_DIR="$(git rev-parse --git-dir)/land-state"    # re-derive — fresh Bash invocation
mkdir -p "$STATE_DIR"
# On a non-zero acquire, this skip line goes to STDERR and points AT the diagnostic
# land-lock.sh already printed there — whose wording distinguishes a transient "another
# /land is still running" from a permanent MACHINE FAULT (flock missing, an unwritable lock
# dir), the distinction a reader of the loop's output needs. Deliberately NOT `2>&1` into
# $ACQUIRE_OUT: the script's token contract is its STDOUT, and on the SUCCESS path that
# variable feeds the token parse below.
#
# stderr is ALSO captured to a scratch file so the failure branch can inspect it for the
# script's own escalation marker without a second `acquire` call (which would double-count
# its consecutive-fault counter). Both files live under ${TMPDIR:-/tmp}, deliberately NOT
# under $STATE_DIR: an unwritable git dir IS the headline fault being escalated, and a
# redirect into the git dir fails BEFORE `acquire` runs at all.
ACQUIRE_ERR_FILE="${TMPDIR:-/tmp}/land-lock-acquire-stderr"
ACQUIRE_OUT="$(scripts/land-lock.sh acquire 2>"$ACQUIRE_ERR_FILE")" || {
  ACQUIRE_ERR="$(cat "$ACQUIRE_ERR_FILE" 2>/dev/null || true)"
  echo "$ACQUIRE_ERR" >&2
  echo "land: could not acquire the lock this tick — skipping. Read land-lock.sh's own" \
    "diagnostic immediately above: a MACHINE FAULT there is PERMANENT on this machine and" \
    "blocks landing until a human fixes it — not an overrunning tick." >&2
  # land-lock.sh only DETECTS a persistent fault and marks it with a distinctly-prefixed
  # stderr line — it stays tracker-free by design. THIS is the one place that reaches a
  # human: open a `human`-labeled ticket, which /sweep already surfaces. Keyed by a fixed
  # title and FILED ONCE per fault episode: a fault that persists for days is thousands of
  # ticks. The ticket EXISTING is the signal; closing it re-arms filing.
  if grep -q 'land-lock: ESCALATE' "$ACQUIRE_ERR_FILE" 2>/dev/null; then
    # `--limit 0`, and NO `--status open` — bd list already excludes closed issues, while
    # pinning `open` would miss this very ticket once a human moves it to in_progress and
    # then duplicate it every tick. The title goes through jq's `env.` builtin rather than
    # `--arg` so a `$name` binding inside the jq program can't trip the cross-block scanner.
    export ESCALATION_TITLE="land-lock: persistent MACHINE FAULT is blocking /land on this machine"
    EXISTING_ESCALATION="$(bd list --label human --limit 0 --json \
      | jq -r '(. // [])[] | select(.title == env.ESCALATION_TITLE) | .id' | head -1)"
    if [ -z "$EXISTING_ESCALATION" ]; then
      bd create --type=decision --label=human --title="$ESCALATION_TITLE" \
        --description="scripts/land-lock.sh acquire has hit a persistent MACHINE FAULT under
/loop 5m /land on this machine, past its escalation threshold. This is not a routine
overrunning pass; it will not self-heal, and every tick keeps skipping until a human fixes
the underlying cause named below.

Filed ONCE per fault episode, not refreshed per tick — the live diagnostic is in the loop's
own output. Do NOT run \`scripts/land-lock.sh acquire\` by hand to check: on a machine that
has since been fixed it would take the lock out from under the loop. Close this ticket once
the machine is fixed; a recurrence opens a fresh one.

Diagnostic at the time of filing:
$ACQUIRE_ERR"
      bd dolt push
    fi
  fi
  exit 0
}
echo "$ACQUIRE_OUT"
# Persist THIS pass's own acquire token to disk for every later heartbeat/release call site
# — a file, not a variable, because no shell state survives between blocks. It lives OUTSIDE
# $STATE_DIR because Section 1's per-pass scratch wipe would otherwise delete it before any
# consumer read it: this is lock state, not per-pass scratch.
# Loud-fail if the pattern doesn't match rather than silently persisting an empty token.
printf '%s\n' "$ACQUIRE_OUT" \
  | grep -oE 'token [0-9a-f]+' | cut -d' ' -f2 > "$(git rev-parse --git-dir)/land-lock-token"
[ -s "$(git rev-parse --git-dir)/land-lock-token" ] || {
  echo "land: could not parse this pass's own token out of: $ACQUIRE_OUT" >&2
  # RELEASE BEFORE BAILING. We hold the lock as of two lines ago, and this is the only exit
  # path in the whole skill that aborts while holding it — without this, a parse bug wedges
  # landing for the FULL staleness window. The explicit blind sentinel is on purpose: we
  # could not parse our own token, and nothing else can have taken the lock in the
  # microseconds since `acquire` succeeded.
  scripts/land-lock.sh release --land-lock-blind   # land-lock-blind-ok: the one sanctioned opt-out, see above
  exit 1
}
```

**Convention:** run the loop on **one machine only** — the local lock does not cross machines.

---

## 1. Setup the pass — tracker-authoritative, fetch origin

**Refuse to start unless I am actually in the primary checkout — asserted once, up front, as a
precondition of the whole block rather than as a `-C` bolted onto individual commands.**
`--show-toplevel` resolves relative to **cwd**, so `-C "$(git rev-parse --show-toplevel)"` is a no-op
wherever it matters: in the primary checkout it restates the cwd you're already in, and in a worktree
it resolves to *that worktree's* root. It reads as a safety guard and is not one.
`--git-common-dir` is what actually distinguishes the two: every worktree shares one common `.git`
directory, and only the **primary checkout's toplevel** is that directory's parent.

**The guard is the FIRST LINE OF THE SAME fenced block as the commands it protects — never its own
block, and this is the whole point.** Every fenced block is a separate Bash invocation, so a guard in
its own block can only `exit` *that* shell — whether the destructive block then runs is left to my
judgment reading prose. Sharing one block makes `||` do the work instead: `git reset --hard` is
**unreachable** unless the assertion passed, enforced by the shell, with no agent decision in between.

```bash
scripts/assert-main-checkout.sh || exit 1   # STOP — everything below assumes this passed
bd dolt pull            # the tracker DB is authoritative; pull the latest claim/label/close state
git checkout -f main    # I land ON the default branch, in the primary checkout (just asserted)
  # `-f` so this cannot FAIL — not to clean anything; the reset below does that by itself.
git fetch origin        # I need origin/main and every origin/land/<id> fresh
STATE_DIR="$(git rev-parse --git-dir)/land-state"
rm -rf "$STATE_DIR"     # per-pass scratch the reset below cannot clear — see below
git log --oneline origin/main..main   # expected EMPTY; non-empty = residue, printed before it goes
  # Residue here is BY CONSTRUCTION merge commits (a pass that died between Section 3's merges
  # and Section 4's push), so this print must be faithful — the reset below destroys them.
git reset --hard origin/main   # pass-start reset, NOT `pull --rebase` — see below
```

On a non-zero exit the pass stops there — the script's stderr names cwd, the primary checkout, and
why (exit 1 = wrong directory; exit 2 = a machine fault rather than a location verdict). Every
command after it runs unqualified, because the assertion is what guarantees cwd already *is* the
primary checkout, which a cwd-derived `-C` never could.

**Why a hard reset, not `pull --rebase`.** I am the only **agent** that writes the default branch, so
at pass start local should already be bit-for-bit `origin`. The only legitimate difference is a
**previous** pass that died between Section 3's merges and Section 4's push — an exit-2 gate stop, or
an ungraceful crash. Those merges were never gated green on their own and never reached origin:
**residue, not work.**

**This line is the *only* place residue is cleared — every exit site below points here rather than
restoring the branch itself.** That generality costs timing (residue survives until the *next* pass
starts) but it buys self-healing from a bare crash or kill, which a per-exit-site restore cannot: a
killed pass runs no exit-site code at all.

Two things the reset does **not** do that `pull --rebase` did, both deliberate: it does not replay
local-only commits forward, and it does **not** refuse on a dirty tree or index. The second cuts both
ways — a staged passive tracker export aborts `pull --rebase` outright while `reset --hard` absorbs
it, but the same permissiveness lets the reset destroy genuinely uncommitted work, which no reflog
recovers. Hence the `git log` line above, printed while the residue still exists. Discarded *commits*
stay in `git reflog`; discarded *uncommitted* work does not. **Do not "simplify" this back to
`pull --rebase`.**

**The `checkout -f` is load-bearing, and not for cleanup** — `reset --hard` clears an unmerged index
by itself. It is load-bearing because `reset --hard` moves whatever ref HEAD is on: were HEAD ever
detached, it would leave the branch untouched. `-f` is there purely so the checkout cannot *fail* — a
pass killed mid-merge leaves an unmerged index, and a bare `checkout` then fails rc=1 *even when
already on the right branch*, stopping the pass at its second command in exactly the crash case this
reset exists to heal.

**The same block wipes `$STATE_DIR`.** It is per-pass scratch the reset cannot clear, and a leftover
from a crashed prior pass is the same *residue* category as a leftover merge commit. The line only
ever **removes** — each writer still `mkdir -p`s the subdirectory it needs — so Section 1 never has
to enumerate a subdirectory a later section invents. Its position *inside* the block is load-bearing:
no block here runs under `set -e`, so the **last** command's status is the only machine-readable
signal the block gives, and `rm -rf` reports success even on a path that does not exist. Keep
`git reset --hard` last.

**This reset is load-bearing for a downstream consumer.** `scripts/recycled-worktree-guard.sh` resets
recycled agent worktrees onto `origin/main`, on the premise that `/land` only ever advances that ref
with already-gated content — a property of this skill's *step order*, not of any lock. Every launch
worktree branches from `origin/main` too, so a reorder's blast radius is every fresh agent worktree.
Section 4's push must stay after Section 3's re-gate.

Then read the queue — every ticket carrying **`ready-for-land`** (it stays `in_progress`; the label,
not the status, is the queue):

```bash
bd list --label ready-for-land --status in_progress --limit 0 --json
```

**`--limit 0` is load-bearing.** A truncated read wouldn't lose a branch outright, but it would
silently under-report and under-land a large backlog, every pass.

If the queue is empty, release the lock and stop:

```bash
MY_TOKEN="$(cat "$(git rev-parse --git-dir)/land-lock-token" 2>/dev/null || true)"
[ -n "$MY_TOKEN" ] || echo "land: WARNING -- no own-token available; land-lock ownership check is DISABLED for this call \
  -- land-lock.sh REFUSES a blind release outright, so the lock stays held until the" \
  "staleness window reclaims it" >&2
scripts/land-lock.sh release "$MY_TOKEN"
exit 0
```

Otherwise heartbeat once here, so Section 1a's `O(n²)` work below is isolated as the sole contributor
to this stretch rather than 1a plus Section 1's networked calls combined. Failure is logged but never
stops the pass:

```bash
MY_TOKEN="$(cat "$(git rev-parse --git-dir)/land-lock-token" 2>/dev/null || true)"
[ -n "$MY_TOKEN" ] || echo "land: WARNING -- no own-token available; land-lock ownership check is DISABLED for this call \
  -- so this heartbeat simply does not fire (|| true below)" >&2
scripts/land-lock.sh heartbeat "$MY_TOKEN" || true
```

---

## 1a. Compute the stacked-branch graph — once per pass, from git, never from the tracker

A producer sometimes must build one `land/<id>` branch **on top of** another still-unlanded
`land/<base>` — merging it in — because its ticket only makes sense once the base's code exists.
Nothing about a stacked branch's *content* announces this; I detect it purely from **git history**. A
producer records a `builds_on` field as a breadcrumb, but that is redundancy and intent only — I
never trust it as the mechanism.

**Detection — shared history off the default branch, NOT tip-ancestry.** Two land branches cut
independently have nothing but the default branch in common. So the relation to test is: **does any
of their merge-bases lie off it?** If one does, the pair shares non-trunk history — and that shared
commit is a base's tip *at the moment a dependent merged it*.

**Shared history is necessary, not sufficient — the direction test decides.** An off-base merge-base
means one of two things, and only the first is a stack:

- **A stack** — one merged the other. The direction test finds the shared commit on the base's
  first-parent spine but not the dependent's, and emits the edge.
- **Siblings** — *two dependents that each merged the same third base* also share that base's
  commits. Here the shared commit is off *both* spines, the direction test matches neither ordering,
  and **no edge is emitted — which is the correct answer.** Each sibling is still correctly detected
  as stacked on the *base* by its own pair.

```bash
git for-each-ref --format='%(refname:short)' 'refs/remotes/origin/land/*'
# for every ORDERED pair (X, Y) among the listed refs:
# ENUMERATE ALL merge-bases — a pair can have more than one — and keep only the off-branch
# ones. A base that later takes a needs-rebase pickup AFTER a dependent merged it acquires a
# SECOND merge-base: the dependent's own cut point, which IS an ancestor of the default
# branch. Single-result `git merge-base` picks one ARBITRARILY, and when it returns the
# on-branch one the pair reads as unrelated and the stack goes undetected.
OFF_BASE=""
for mb in $(git merge-base --all "origin/land/<X>" "origin/land/<Y>"); do
  git merge-base --is-ancestor "$mb" origin/main || OFF_BASE="$OFF_BASE $mb"
done
[ -z "$OFF_BASE" ] && continue   # every merge-base is on the default branch → unrelated
# DIRECTION: the BASE is the one whose own first-parent spine contains an off-branch MB — the
# dependent reached that commit through a merge (second parent), so it is not on its spine.
for mb in $OFF_BASE; do
  git rev-list --first-parent origin/main..origin/land/<X> | grep -qx "$mb" \
    && ! git rev-list --first-parent origin/main..origin/land/<Y> | grep -qx "$mb" \
    && echo "<Y> is stacked on <X>" && break
done
```

**Do NOT reduce this to `git merge-base --is-ancestor origin/land/<X> origin/land/<Y>`.** That tests
the base's **tip**, and a base's tip *moves after a dependent merges it* — its reviewer pushes fixes,
a pickup merges the default branch in. Both leave the dependent holding the base's *older* commits,
so the base's current tip is no longer an ancestor and **the whole stack goes invisible**, silently.
That is not a corner case; it is the *normal* flow, because a producer stacks on a base precisely
while that base is still unlanded and therefore still moving. Immunity comes from `--all` plus the
off-base filter, not from using a merge-base per se.

Build this **once**, as an in-memory map for the rest of the pass — never persisted, never trusted
from a prior pass. Two shapes get used:

- **Full relation** (every base of Y, direct *or* transitive) — used by Bounce and the escalation
  resolution paths to ask "does deleting X strand a live descendant?" A transitively-stacked branch
  inherits X's content just as much as a direct one.
- **Direct edges only** (X is Y's *nearest* base) — needed by 2c to pick the one base `land-review`
  diffs a stacked branch against. Handing it a *transitive* base would make the diff carry the
  intermediate branch's work as if it were this branch's. Section 3a uses the same view to order the
  merge set.

**Known gaps — documented, not claimed airtight.**

1. **Force-push.** The merge-base test survives any *append* but not a **rewrite**. If a base's
   history were force-pushed after a dependent merged it, the shared commit is gone and the pair
   reads as unrelated. Nothing in this architecture force-pushes a land branch, so this is a defense
   against a future change, not a live trigger. **If a `land/<id>` branch is ever force-pushed, the
   stacked graph for that pass is not trustworthy.**
2. **Branched-from-base, not merged-base.** The direction test assumes the dependent *merged* the
   base. A producer that instead **branches directly off `land/<base>`** puts the shared commit on
   *both* first-parent spines, so the direction test matches neither half and emits no edge.
   Detection still flags the pair as related; only the *direction* is lost. This is a **live**
   trigger — producers have deviated from the sanctioned flow.

Note gap 2 is not distinguishable from a sibling pair by signature alone — both show up as "related
but no edge." That is why it stays a documented gap rather than something to warn on: a warning keyed
on that signature would fire on every perfectly normal sibling pair. If a stack is suspected but no
edge appears, check by hand whether the dependent's first-parent spine reaches the default branch at
all, or dead-ends in the base.

---

## 2. Vet each branch — cheap prechecks first, then the semantic review

Steps 2a and 2b are **cheap gates I run before spending a strong model on the semantic review** — a
branch that has drifted or no longer merges cleanly is disqualified on mechanics alone.

### 2a. Re-validate that the tracker and git haven't drifted

The landing context is **minimal by design** — `land_head` + a one-line `land_summary`, read via
`bd show <id> --json` (the branch name is *derived*, never stored). The SHA exists only to **detect
drift**: a push onto the branch *after* the ticket was marked ready.

**First action of every iteration: heartbeat the lock.** This is the call site that keeps the
staleness token measuring idle time rather than the pass's total duration — it fires once per ticket,
right before that ticket's review dispatch, so the gap the TTL must outlast is one dispatch, not the
sum across the queue.

```bash
MY_TOKEN="$(cat "$(git rev-parse --git-dir)/land-lock-token" 2>/dev/null || true)"
[ -n "$MY_TOKEN" ] || echo "land: WARNING -- no own-token available; land-lock ownership check is DISABLED for this call \
  -- so this iteration simply does not heartbeat (|| true below)" >&2
scripts/land-lock.sh heartbeat "$MY_TOKEN" || true
BD_JSON="$(bd show <id> --json)"
LAND_HEAD="$(jq -r '.[0].metadata.land_head // empty' <<<"$BD_JSON")"
# Shape-check BEFORE comparing to anything. Exit 1 = malformed/missing metadata; exit 2 = this
# call is broken. `|| exit $?` is load-bearing: there is no `set -e` here, so without it the
# block would run the drift comparison on a value the check just rejected — the exact thing
# the check exists to prevent — while preserving the 1-vs-2 distinction.
scripts/validate-sha40.sh land_head "$LAND_HEAD" || exit $?
git ls-remote origin "refs/heads/land/<id>"   # branch must still exist on origin...
# ...and origin/land/<id>'s tip SHA must equal $LAND_HEAD
```

**Why the shape check, before the comparison.** A metadata write has no schema — a truncated or
hand-retyped value (one hex digit short) writes just as cleanly as a real one, and a malformed value
never equals a real branch tip, so without this check it reads as ordinary drift and the branch is
thrown back on that basis — which for this section means a **bounce**, superseding the ticket and
dropping the branch: a self-inflicted rebuild of work that was already correct.

**Deliberate asymmetry — do not "harmonize" it.** This check is **exact-match**, not the
ancestor-check the technical reviewer uses for `review_head`. Same predicate, different questions:
`/land` lands **without** re-reviewing, so a forward push of never-reviewed commits genuinely is
drift here; the reviewer reviews the whole branch regardless, so a forward push is harmless there.

A **missing branch** or a **SHA mismatch** is drift — treat it exactly like a review **bounce**. A
**malformed `land_head`** is a **distinct** outcome — neither drift nor a real mismatch, since there
is no well-formed value to compare — and it is an **escalate**, never a bounce and never an in-pass
repair. Concretely: **keep the branch**, land nothing from it, label `land-escalated`, and say
explicitly "malformed `land_head` metadata, not drift" plus what the human owes: re-derive the value
mechanically (`git rev-parse` / `git ls-remote`, never retyped), re-write the field, and re-enter at
`ready-for-land`.

**Why escalate rather than bounce or repair.** A corrupt hand-off record means **no drift evidence
exists at all** — whether the branch is nonetheless the reviewed one is a *human* judgement. Bouncing
would supersede the ticket and **delete** the branch whose field the remedy asks a human to re-write.
Repairing in-pass is worse: `land_head` records **what the reviewer saw**, so re-deriving it yields
the *current* tip and the comparison becomes tip == tip — vacuously true. That doesn't fix the drift
check, it deletes it while leaving it green.

### 2b. Cheap conflict precheck — does it still merge?

A branch that forked long ago is **not** stale-in-a-way-that-matters as long as it still merges
clean: `--no-ff` integrates non-linear history fine, and Section 3's combined re-gate re-runs the
tests on the *merged* result. What *does* disqualify a branch is a **textual conflict** — and
discovering that only at merge time means I've already paid for a full semantic review on contents
the rebase will change.

```bash
# $STATE_DIR is wiped once per pass in Section 1; re-derived here, fresh invocation.
STATE_DIR="$(git rev-parse --git-dir)/land-state"
CONFLICTS_DIR="$STATE_DIR/conflicts"
mkdir -p "$CONFLICTS_DIR"

# A command substitution inside an `if` condition is exempt from `set -e` — unlike a bare
# `VAR=$(cmd)` assignment, which would abort the shell before `rc=$?` is ever reached.
if CONFLICTS=$(scripts/merge-precheck.sh origin/main "origin/land/<id>"); then
  rc=0
else
  rc=$?
fi

# $CONFLICTS does NOT survive to the kick-back block below — that is a SEPARATE Bash
# invocation. Persist it now, at the only point this block actually holds it.
#
# An `if`, NOT `[ "$rc" = 1 ] && printf ...`. As this block's LAST command that AND-list makes
# the whole invocation exit 1 whenever rc is 0 — so the COMMON clean path would report failure
# and a real conflict would report success, INVERTING the only signal this block gives.
# Testing `= 1` and not `!= 0` is also load-bearing: a machine fault (rc=2) leaves $CONFLICTS
# empty and must NOT leave a file behind for a later kick-back to read as a conflict record.
if [ "$rc" = 1 ]; then
  printf '%s\n' "$CONFLICTS" > "$CONFLICTS_DIR/<id>"
fi
```

- **`rc=0`** → clean; proceed to 2c.
- **`rc=1`** → textual conflict. `$CONFLICTS` holds exactly the conflicting paths, one per line. →
  needs-rebase kick-back: skip the semantic review, leave the merge set. **Do that kick-back now, for
  this branch, while still in Section 2** — 3a computes the accepted set from outcomes that include
  "kicked back", so a branch reaching 3a un-kicked-back is out of order on its own terms.
- **`rc=2`** → **MACHINE FAULT, not a branch conflict** (old git, an unreadable ref, or the tool
  failing). I do **not** kick this branch back — a machine fault blaming an innocent branch is
  exactly the defect this precheck's extraction closed. **Stop the pass** and surface the script's
  own stderr verbatim as a human decision.

A conflict is **neither a bounce nor an escalate** — the branch's *content* may be perfectly fine, it
simply can't replay onto where the default branch now is.

### 2c. Run the semantic gate

**Dispatch `subagent_type: "land-review"` via the Agent tool — no `isolation` argument at the call
site.** Its own agent definition carries `isolation: worktree`, so the requirement travels with the
*role*: any dispatch lands isolated whether or not the call site remembers to ask.

That matters here more than anywhere. I run on the default branch, in the primary checkout — **the
same working tree Section 3 merges into.** A non-isolated review dispatch runs *in that tree*, and
nothing stops a reviewer from leaving files staged or modified there. Observed: three non-isolated
dispatches all ran in the primary checkout; one left a full branch diff staged, and the next branch's
merge aborted with "would be overwritten by merge" — with `git ls-files -u` empty, so it hit neither
the retry path nor the real-conflict path, and silently read as an unretried conflict.

Pass the ticket ID and its branch. **If 1a's direct-edge map found this ticket stacked on exactly one
live base**, also pass that base — land-review diffs against it instead of the default branch. If it
found *no* live base, or (rare) more than one direct base, hand it nothing extra — but in the
multi-base case, note in the dispatch which other live land branches this one contains, so
land-review doesn't misread their content as scope creep.

- **accept** → add the ticket to the **merge set**.
- **bounce** → handle per [Bounce](#bounce--clear-failure): new ticket carrying the findings,
  supersede the original, **drop the branch** — unless that would strand a live descendant, in which
  case it escalates instead.
- **escalate** → land **nothing** for it, **keep the branch**, label it, surface the question.

Collect verdicts for the whole queue before merging — I want the full accepted set so I can
**batch**-merge.

---

## 3. Batch-merge the accepted set, re-gate once, isolate on red

Two branches each green *in isolation* can break when **combined** (a clean git merge with broken
behaviour). So I merge the whole accepted set, then re-gate **once**.

**Every re-gate in this section runs in the FOREGROUND, in the same turn, and its result is read from
its own real exit status, never from a downstream command's.** No `run_in_background`, no `Monitor`,
no ending a turn on a pending gate. And **never pipe a gate through `tail`/`head`/`grep` and read the
pipeline's exit status as the gate's own**: a pipeline's status is its **last** element's, so a
killed or hung gate can surface as "completed, exit 0" while its own output ends mid-run. **Observed:**
`nox -s tests 2>&1 | tail -30` exceeded the timeout, was backgrounded, hung, and was killed — and the
harness reported "completed (exit code 0)" because that 0 was `tail`'s, even though the captured
output ended in `Session tests failed`. If output must be trimmed, capture the real status first
(`set -o pipefail`, `${PIPESTATUS[0]}`, or `cmd > file; status=$?; tail -30 file`).

**This is specifically the lander's problem.** A producer that misreads its own gate hands a bad
branch to the *next* gate in the chain. I am the **last** gate: nothing re-checks what I certify. A
misread green here pushes unverified content straight out, which is the one thing `/land` exists to
prevent.

**A gate that was killed or never completed is neither green nor a content red.** It must not land
anything and must not bounce anything either — nothing failed on its *content*, the run simply never
finished. Stop, re-run cleanly with the real exit status captured, then decide.

### 3a. Order the accepted set — base before dependent; hold an orphaned dependent

An unordered merge set is unsafe for a stacked branch: merging a dependent *before* its base drags
the base's unreviewed content in under the wrong ticket's name, and a dependent whose base never made
it into this pass's accepted set must not land at all this pass.

Using 1a's **direct edges**, restricted to the accepted set:

- **The base is also accepted** → the dependent must merge *after* it. A plain topological sort
  (Kahn's algorithm) handles any depth of stacking from these direct edges alone.
- **The base is not accepted** → **hold** the dependent: pull it out of this pass's merge set
  entirely (it does not merge, conflict-isolate, or bounce this pass), and leave a note:

  ```bash
  bd update <id> --append-notes "HELD (/land, stacked-branch ordering): land/<id> is stacked on
  land/<B>, which is not landing this pass (<B>'s outcome: <bounced|escalated|needs-rebase|not yet
  ready-for-land>). Re-evaluated automatically once <B> lands or its outcome resolves — no action
  needed unless <B> itself needs a human decision."
  ```

  It stays `ready-for-land` and simply re-enters the semantic review next pass, by which point either
  the base has landed (so its own diff now naturally excludes the base's content) or the hold note
  explains why it's still waiting.

**The invariant that outlives this step: a base that leaves the merge set takes its dependents with
it.** Ordering up-front is not sufficient, because a base can still drop *out* later in Section 3 —
by a real merge conflict (kicked back) or by turning the gate red during isolation (bounced). In both
cases the loop would carry on to a dependent still in the set, merge it, and land the departed base's
just-rejected content under the *dependent's* ticket name. So whenever a branch leaves the merge set
**for any reason**, **drop every dependent of it too** (the *full* relation, so transitive dependents
go as well), with the same HELD note.

**Pre-compute every merge message before the first merge — no tracker call inside the merge loop, and
persisted to a FILE, never a bash variable.** The summary comes from `metadata.land_summary` or the
title.

> **On what dirties the tree — stated honestly, because a wrong causal story about a destructive path
> is worse than an admitted gap.** Measured repeatedly: a bare tracker *read* and a real tracker
> *write* each leave `git status --porcelain` **empty**. Tracker writes go to Dolt; the tracked
> `.beads/issues.jsonl` is regenerated and staged by the **pre-commit hook at commit time**. So the
> per-iteration read hoisted out of the loop is **not** what re-dirties the tree.
>
> **What has NOT been established is the positive cause.** `bd dolt pull` is *suspected*, but that is
> a defensive assumption, not a measurement, and a direct attempt to reproduce it did not stage
> anything. Do not upgrade that hedge into a settled fact.
>
> **The restore below stays regardless, and its justification does not depend on knowing the cause.**
> The staged-export failure is real and observed; the export is **by invariant never work**; so
> restoring it unconditionally is free and correct whatever the trigger turns out to be — precisely
> the right move *because* the trigger is unestablished.

```bash
STATE_DIR="$(git rev-parse --git-dir)/land-state"    # under .git/ — survives a later `git reset
MSG_DIR="$STATE_DIR/msg"                             # --hard` (that only resets index+worktree)
CONFLICTS_DIR="$STATE_DIR/conflicts"
mkdir -p "$MSG_DIR" "$CONFLICTS_DIR"   # $STATE_DIR is wiped once per pass, in Section 1

# Capture the accepted set to a file HERE, at the one moment I actually hold it. Every later
# block RE-READS this file instead of having the ids restated by hand: ids are opaque
# identifiers, and the derive-identifiers fiat rules out hand-transcribing them — doubly so
# here, where the ORDER is load-bearing and a silent slip merges a dependent before its base.
printf '%s\n' $ACCEPTED > "$STATE_DIR/accepted"
: > "$STATE_DIR/landed"    # appended to by the merge loops below; Section 4 reads it back

for id in $(cat "$STATE_DIR/accepted"); do
  SUMMARY=$(bd show "$id" --json | jq -r '.[0].metadata.land_summary // .[0].title')
  printf '%s' "Merge land/$id: $SUMMARY ($id)" > "$MSG_DIR/$id"
done
```

**Re-derive `STATE_DIR`/`MSG_DIR` at the top of every later block that needs them.** Deriving
`$(git rev-parse --git-dir)` fresh is cheap and deterministic, not "state assumed to survive"; what
persists across blocks is the **files** on disk, never the shell variables naming their location.

The accepted set genuinely cannot be *re-derived* after the fact — it encodes per-branch judgment
that is not queryable from git or the tracker — but **"cannot be re-derived" is not "cannot be
persisted"**: the block above captures it at the one moment I do hold it. The landed set is better
still: the merge loops **append** to it as each branch actually merges, so it is derived from what
happened rather than recalled.

**Every block below that loads one of these files asserts that it LOADED.** All cross-block loads go
through `scripts/land-state-load.sh`, whose two policies (default = missing fatal / empty OK;
`--require-nonempty` = both fatal) are the *only* two — a new load site picks one by argument rather
than hand-rolling a fifth `cat` spelling. What the assertion separates is not "empty" from "a real
merge", but its two **causes**: a file that was never written (3a never ran — the silent failure,
aborted loudly) from a file written empty (every branch legitimately left the set — allowed through).
**Do not re-add an emptiness test to the first-pass merge loop** — that conflates the two again.

Before merging anything, unstage the passive export — unconditionally. A staged export means its
index blob differs from `HEAD` while the worktree matches the index, so `git diff` reads **clean** in
that state and the drift is invisible right up until `git merge --no-ff` refuses with "Your local
changes would be overwritten by merge." A bare `git checkout --` does **not** fix this: it only
overwrites the worktree, leaving the staged index entry, so a naive retry loops.

```bash
git restore --staged --worktree .beads/issues.jsonl 2>/dev/null || true
```

**A failed `git merge` is not automatically a textual conflict.** Classify on the actual failure:
`would be overwritten by merge` in stderr *with* an **empty** `git ls-files -u` is the passive-export
trap, not a conflict — restore and retry the same merge once. Only a genuinely unmerged index
(`git ls-files -u` non-empty) is a real textual conflict.

That retry-and-classify logic is `scripts/land-merge-one.sh`, not an inline bash function. The
function used to be defined in one fenced block and called again from the isolation-replay loop below
— but that loop only runs after a reset and a re-gate, each its own separate invocation, so the
function had already vanished. A script exists on disk identically for both call sites. It reads its
message from the `MSG_DIR` files, communicates a real conflict's paths back over **stdout**, and
carries the same 0/1/2 contract (0 = merged, 1 = real conflict, 2 = machine fault). It also asserts
its own primary-checkout identity internally, so this block needs no separate guard.

```bash
STATE_DIR="$(git rev-parse --git-dir)/land-state"   # re-derive — fresh Bash invocation; nothing
MSG_DIR="$STATE_DIR/msg"                            # from 3a persists except the FILES it wrote
CONFLICTS_DIR="$STATE_DIR/conflicts"
MY_TOKEN="$(cat "$(git rev-parse --git-dir)/land-lock-token" 2>/dev/null || true)"
[ -n "$MY_TOKEN" ] || echo "land: WARNING -- no own-token available; land-lock ownership check is DISABLED for this call " >&2

# Load 3a's accepted set, and REFUSE if the FILE never got written: that is 3a's precompute
# not having run at all. An EMPTY file is a different, legitimate outcome and is NOT refused —
# the loop iterates zero times, the re-gate after it is SKIPPED, and the pass falls through to
# Section 4 exactly as a real merge would.
ACCEPTED=$(scripts/land-state-load.sh "$STATE_DIR/accepted" -- \
  "3a's precompute did not run. Landing nothing.") || exit 1

for id in $ACCEPTED; do
  # A command substitution inside an `if` condition is exempt from `set -e`, and `$?` in the
  # `else` arm is the SCRIPT's real exit status. Do NOT rewrite as `if ! CMD; then rc=$?`:
  # there `$?` is the *negation's* status, always 0 in that arm — so a machine-fault 2 would
  # read as a clean merge and the pass would carry on as though the branch had landed.
  if CONFLICTS=$(scripts/land-merge-one.sh "$id" "$MSG_DIR" "$MY_TOKEN"); then
    rc=0
  else
    rc=$?
  fi
  case "$rc" in
    0) echo "$id" >> "$STATE_DIR/landed" ;;   # merged cleanly — record it and keep going
    2)
      # MACHINE FAULT — never read as a conflict or a bounce. Stop the pass and surface the
      # script's own stderr as a human decision.
      exit 1
      ;;
    *)
      # rc=1: real textual conflict with a branch already merged this pass — both passed 2b
      # against origin but conflict with *each other*. Kick-back, NOT a land. It never reaches
      # the `0)` arm, so it is never appended to landed and Section 4 cannot close or GC it.
      printf '%s\n' "$CONFLICTS" > "$CONFLICTS_DIR/$id"
      #
      # 3a INVARIANT: this branch just LEFT the merge set — drop it AND its dependents (1a's
      # full relation, transitively) and leave each the HELD note. WRITE THAT REDUCTION TO
      # THE FILE, not just this shell's variable: the isolation-replay loop re-reads the FILE
      # and would otherwise re-merge a branch this pass already kicked back, or merge a
      # dependent whose base is no longer landing. For each dropped id:
      #   grep -vxF "$dropped" "$STATE_DIR/accepted" > "$STATE_DIR/accepted.tmp" || true
      #   mv "$STATE_DIR/accepted.tmp" "$STATE_DIR/accepted"
      # (`|| true` because grep exits 1 when it filters out the last remaining line, and an
      # empty accepted set is a legitimate outcome here.)
      continue
      ;;
  esac
done
```

Re-gate the combined result. A **docs-only** merge set has no code gate — skip it, and run the
diagram validator only if a merged diff touched a diagram.

**If the loop merged NOTHING — the landed file is empty, the all-bounced / all-kicked-back pass —
skip this re-gate entirely and go straight to Section 4.** The branch is byte-identical to the origin
ref Section 1 fetched, whose content is by construction already gated, so there is nothing this pass
introduced to certify. This is a cost decision, not a correctness nicety: without it, every
all-bounced tick pays a full test run to re-certify content already carried, and any red it found
could only be pre-existing breakage this pass neither caused nor could attribute.

```bash
./venv/bin/nox -t fix && ./venv/bin/nox -s tests && ./venv/bin/nox -s lock_currency
```

`lock_currency` catches a stale dependency lock here — locally, before public CI does. A branch that
bumped a dependency without regenerating the lock (or whose merge with another accepted branch
changed the resolved graph) fails it with **exit 1**, treated identically to a red test run.

**Exit 2 from any of these is NOT a red gate — it is a machine fault, and isolating on it bounces an
innocent branch.** On exit 2 I do **not** isolate, bounce, or land: I stop the pass and surface the
message verbatim. `lock_currency` is **last** in the `&&` chain for exactly this reason — an `&&`
chain reports its last-run command's status, so anything after it would mask the 2. Keep it there.

**Neither exit-2 stop restores the local branch** — deliberately; that is Section 1's job.

- **Green** → proceed to Section 4.
- **Red** → **isolate.** The combined merge is bad but I don't know which branch. Reset back to
  origin and replay the accepted set **one at a time** (in 3a's order), re-gating after each; keep
  every branch that stays green, and **bounce** the first that turns the gate red, then continue with
  the rest — **but if the branch I bounce is a base, its dependents leave the set with it**: don't
  replay them, hold them. Replaying a dependent whose base just failed merges the failing content
  back in under a different ticket's name. (The bounce's own descendant check fires here too.)

  This is a fresh invocation, so it needs its **own** primary-checkout guard as its first line —
  Section 1's cannot reach it. Keep this block's destructive commands below it **in this same fence**:
  the two `git reset --hard HEAD~1` calls are protected only by sharing it. Splitting this block is
  what would silently un-guard the resets.

  ```bash
  scripts/assert-main-checkout.sh || exit 1   # STOP — everything below assumes this passed
  git reset --hard origin/main
  STATE_DIR="$(git rev-parse --git-dir)/land-state"   # re-derive; 3a's files under $STATE_DIR
  MSG_DIR="$STATE_DIR/msg"                            # are untouched by the reset
  CONFLICTS_DIR="$STATE_DIR/conflicts"
  MY_TOKEN="$(cat "$(git rev-parse --git-dir)/land-lock-token" 2>/dev/null || true)"
  [ -n "$MY_TOKEN" ] || echo "land: WARNING -- no own-token available; land-lock ownership check is DISABLED for this call " >&2
  # DELIBERATELY ASYMMETRIC with the first-pass loop, which lets an EMPTY accepted set through:
  # here an empty one is still refused. This block only runs on a RED combined re-gate, and a
  # nothing-merged pass skips that re-gate entirely, so an empty set should be unreachable —
  # which is exactly why it stays fatal rather than being relaxed for symmetry. If it ever does
  # arrive, the tree is byte-identical to origin, so the red is attributable to no branch in
  # this pass: nothing to isolate, nothing to bounce, and a loud stop is the only honest
  # outcome. The two blocks answer different questions.
  ACCEPTED=$(scripts/land-state-load.sh "$STATE_DIR/accepted" --require-nonempty -- \
    "isolation-replay path — nothing to attribute this red to. Landing nothing.") || exit 1
  : > "$STATE_DIR/landed"    # the reset discarded every merge the first-pass loop recorded —
                             # start the replay's record from empty so Section 4 closes only
                             # what THIS loop actually keeps merged

  # BASELINE before attributing anything. THE RULE, stated generally so a gate added here later
  # inherits it: NO gate this loop attributes is a pure function of the tree, so baseline EVERY
  # one of them on the bare origin ref before entering the attribution loop. Otherwise the loop
  # blames — and deletes — whichever innocent branch happened to be merged first. This block is
  # on the red path only, so a green pass never pays for it.
  #
  # The test suite used to be exempt, on the premise that it "asks a question about the tree
  # alone". That premise licensed a real incident: an ambient environment variable in the
  # LANDING SESSION's own shell — not set anywhere in this repo — reddened several tests on a
  # bare, unmodified origin ref with NOTHING merged. Trusting it would have bounced the first
  # branch in the set: closing its ticket, opening a rebuild ticket with a FABRICATED "turned
  # the gate red" finding, and deleting the reviewed branch — for a variable this repo does not
  # set. The lock gate fails the same test for its own reason: it asks whether the committed
  # lock is a fixed point of the tree PLUS this machine's ambient tooling PLUS today's index,
  # so it too can be red with no branch involved at all.
  ./venv/bin/nox -s tests
  #   exit 0 → attributable from here on for THIS gate. Continue.
  #   nonzero → red before any branch merged; not attributable to anything in the set. Stop the
  #            pass, land nothing, surface as a human decision — and check the landing shell's
  #            own environment first.
  ./venv/bin/nox -s lock_currency
  #   exit 0 → attributable from here on. Continue.
  #   exit 1 → the branch's own lock is stale before any merge. Not attributable: stop, land
  #            nothing, surface as a human decision.
  #   exit 2 → machine fault: stop the pass, land nothing, surface it verbatim.

  # $ACCEPTED was loaded from the file above — already reduced by any kick-back the first-pass
  # loop wrote back, so the replay never re-merges one.
  for id in $ACCEPTED; do
    # Identical idiom and shape to the first-pass loop — see its comment for why
    # `if ! CMD; then rc=$?` is wrong here. Keep the two loops the same shape.
    if CONFLICTS=$(scripts/land-merge-one.sh "$id" "$MSG_DIR" "$MY_TOKEN"); then
      rc=0
    else
      rc=$?
    fi
    case "$rc" in
      0) : ;;   # merged — now gate it below before recording it as a survivor
      2) exit 1 ;;   # MACHINE FAULT — never a branch verdict. Stop; do not bounce or land.
      *)
        # rc=1: real textual conflict against an earlier survivor merged this pass. Kick-back,
        # not a bounce — its content wasn't judged bad, it just needs to replay.
        printf '%s\n' "$CONFLICTS" > "$CONFLICTS_DIR/$id"
        continue
        ;;
    esac
    if ! ./venv/bin/nox -t fix || ! ./venv/bin/nox -s tests; then
      git reset --hard HEAD~1   # back the culprit out
      # → bounce <id>; it does NOT land this pass
      continue
    fi
    ./venv/bin/nox -s lock_currency
    case $? in
      0) echo "$id" >> "$STATE_DIR/landed" ;;   # survivor — keep it merged and record it
      2) break ;;                    # machine fault mid-loop, NOT this branch: stop the pass,
                                     # land nothing. Never bounce on a 2.
      *) git reset --hard HEAD~1 ;;  # back the culprit out → bounce <id>
    esac
  done
  ```

  **Every "stop the pass" exit above leaves the local branch exactly as it sits.** I restore none of
  them; that is Section 1's job.

  Read `$?` from the gate itself. The pipeline rule applies with extra force here: never pipe these
  into `tail`/`grep` and read the *pipeline's* status, which would silently flatten a 2.

---

## 4. Land the survivors

Only now — combined and green — do I write the world. **Order matters:** push first, then close, then
publish tracker state, then GC branches and local worktrees.

**Do not hoist this push above Section 3's re-gate.**

First, check whether the re-gate's formatter actually changed anything:

```bash
git status --short
```

- **Empty** → nothing to commit; skip.
- **Non-empty** → stage **only** the explicitly-named reformatted source paths. Never `-A` (it once
  swept in an unrelated pre-existing untracked directory under a misleading `style:` message), and
  never rely on a pathspec exclude to keep the passive export out — the tracker's own pre-commit hook
  re-exports and re-stages it on *every* commit regardless of what was `git add`-ed, so the commit
  must skip hooks too.

  **This commit names no ref or path at all — the one git write in this section that doesn't.** Every
  other one below is ref- or path-addressed and therefore cwd-independent. This one commits to
  whatever branch cwd's `HEAD` happens to be on, and run from the wrong directory that is not a loud
  failure: it silently commits the reformat to that directory's branch, and the push below then
  pushes without it — green all the way through. So this fence needs its own guard:

  ```bash
  scripts/assert-main-checkout.sh || exit 1   # STOP — this commit is not ref-addressed at all
  git add <path> <path> ...                     # explicit reformatted source paths only
  git commit --no-verify -q -m "style: formatter on merged main"   # --no-verify: skip the
                                                # pre-commit hook so it can't re-stage the export
  git show --stat HEAD                          # confirm only the intended paths rode along
  ```

```bash
git push origin main
git status                 # MUST show up to date with origin

# Heartbeat here so every per-ticket close, the networked publish, every branch delete, and the
# worktree-GC sweep below sit strictly BETWEEN this call and the pass-end release. That stretch
# is the ordinary GREEN path, it grows with the number of tickets landed, and it runs during the
# exact window the default branch is being written.
MY_TOKEN="$(cat "$(git rev-parse --git-dir)/land-lock-token" 2>/dev/null || true)"
[ -n "$MY_TOKEN" ] || echo "land: WARNING -- no own-token available; land-lock ownership check is DISABLED for this call \
  -- so this heartbeat simply does not fire (|| true below)" >&2
scripts/land-lock.sh heartbeat "$MY_TOKEN" || true

# The ids that actually stayed merged — read back from the file Section 3's loops appended to,
# never restated by hand. On the Green path that is the accepted set minus any mid-loop
# kick-backs; on the Red path the replay loop truncated the file and re-recorded only what it
# kept, so bounced culprits and held dependents are already excluded. An EMPTY file is
# legitimate and correctly closes nothing; a MISSING one means Section 3 never ran.
STATE_DIR="$(git rev-parse --git-dir)/land-state"
LANDED=$(scripts/land-state-load.sh "$STATE_DIR/landed" -- \
  "Section 3 never ran (or never reached its end-of-loop write). Nothing to close.") || exit 1
for id in $LANDED; do
  bd close "$id" --reason "Landed via /land (merge <sha>)"
  bd update "$id" --remove-label ready-for-land
    # Tidy the queue label off the now-closed ticket — symmetric with the kick-back, escalate,
    # and bounce exits, which have always done this. Keep it AFTER the close: a crash between
    # the two leaves only a benign stale label, whereas stripping FIRST would strand an open,
    # label-less ticket outside the queue for good — the label, not the status, is the queue.
done

# Closing the last child of an epic completes it — flag it for the closing-side review. I only
# NOTICE completion here; the review itself is /epic-audit. epic-completion-check.sh walks to
# the parent epic and decides whether it is now fully child-complete and not already flagged.
# It is extracted, not inlined, so it carries its own fixture-backed tests: the inline jq this
# replaced was DEAD CODE for months (it read `bd show`'s `.dependents`, populated only with the
# opt-in --include-dependents flag, so the array was always absent and a false-positive guard
# silently ate every pass) and no gate would ever catch a markdown-embedded jq snippet
# regressing. The script is read-only; this loop is the one place that writes the label.
for id in $LANDED; do
  RESULT=$(scripts/epic-completion-check.sh "$id")
  [ -z "$RESULT" ] && continue
  PARENT=$(printf '%s' "$RESULT" | awk '{print $2}')
  bd label add "$PARENT" epic-ready-to-audit   # /epic-audit picks it up
done

scripts/bd-dolt-push.sh   # publish closes, epic flags, and any bounce tickets

for id in $LANDED; do
  git push origin --delete "land/$id"   # GC the merged remote branch — a bare ref delete, not a
                                        # worktree/uncommitted-work risk, so this stays per-ticket
done
```

### Local worktree + branch GC

**This end-of-pass backstop sweep is the ONLY local worktree/branch reclaim.** There used to be a
per-ticket loop here that read a recorded worktree path off each landed ticket and ran
`git worktree remove --force` unconditionally — no lock check, no dirty check. It is **deleted**.
Discovering worktrees live from `git worktree list --porcelain` beats trusting per-ticket metadata
that can drift, and the sweep catches every just-landed builder worktree on the same pass (this
pass's merge is what makes each one's HEAD an ancestor).

**What that costs**, because "the backstop subsumes it" is true of the CANDIDATE set but not the
RECLAIMED set: the backstop gates on locked + clean + ancestry, none of which the old loop had, so it
reclaims strictly **less**. A landed builder worktree that is dirty, locked, or carries commits that
never reached origin is now **kept** where the old loop force-removed it — the dirty case being a
permanent leak until a human clears it. That is deliberate: **leak a directory rather than destroy
uncommitted work.**

**One unenforced coupling keeps this sweep reclaiming anything at all**, and if it breaks the sweep
silently reclaims *nothing*: **`.gitignore`.** A finished worktree is full of untracked build junk
(`venv/`, `.nox/`, `__pycache__/`); it reads clean ONLY because those are ignored. Un-ignore one and
every worktree reads dirty. If you touch `.gitignore`, re-check that this sweep still reclaims.

**Where the predicates live:** every predicate below — both ancestry arms, the dirty-tree guard and
its exclude list, the dir-only age floor — lives in `scripts/worktree-gc-classify.sh`, extracted so
it is shellcheck'd and unit-tested rather than unreachable in a markdown fence. This block holds the
**sweep-level contract**; the script's header holds the per-arm detail.

**The contract.** ANY worktree under `.claude/worktrees/` that is **unlocked**, **clean**, and
**either** has not diverged from the default branch **or** — for a branch-attached worktree — has not
diverged from its own branch's origin counterpart, is reclaimable, whoever made it. The second arm
exists because an **escalated** ticket's reviewer worktree never merges by definition, so a
trunk-only test could never reclaim it; content pushed to `origin/land/<id>` is captured just as
safely.

A worktree freshly branched off the default branch is trivially "merged" by **zero divergence** — that
proxy alone reads TRUE for a live, uncommitted build the instant its worktree is created. So the
sweep also tests the ACTUAL invariant directly: `git -C "$WT" status --porcelain`. **A dirty tree is
never reclaimed, regardless of lock state, ancestry, or who made the worktree.** That guard is what
protects the worktree classes holding no lock: an interactive session, a human's hand-made worktree,
an exited agent's leftover scratch. There are exactly two lock sources and neither covers those:

1. The **harness** locks every `isolation: worktree` launch worktree for the lifetime of the agent
   standing in it, released on exit. So a LIVE reviewer/pickup worktree is `locked` and the sweep
   skips it outright.
2. The **producer** also locks its build worktree explicitly, because it unlocks again at its first
   commit — earlier than the harness would.

The guard distinguishes "clean" (proceed) from "could not tell" (skip): `status --porcelain` prints
nothing both when the tree is clean *and* when the command itself errors. An unguarded zero-divergence
read was once a real hazard — it destroyed two builds' uncommitted work outright before the dirty
guard existed.

**Accepted residual:** a CLEAN worktree at zero divergence that raises no lock — a human's hand-made
worktree, or an exited agent's clean leftovers — is still reclaimable. Nothing is destroyed (the tree
is clean); the directory just vanishes out from under whoever is standing in it. The trade is
intentional: the failure direction is now "remove an empty checkout," never "destroy uncommitted
work."

```bash
# FIELD ORDER IS LOAD-BEARING — DO NOT REORDER ($BR must stay LAST). Tab is IFS *whitespace*,
# so `read` collapses adjacent tabs and does NOT preserve an empty MIDDLE field. `branch` is
# the one field that can be empty (a DETACHED worktree — explicitly supported). With `branch`
# in the middle, a detached worktree's line shifts every later field left: $BR swallows the
# locked flag and $LOCKED reads EMPTY, so a LOCKED, LIVE agent's worktree sails past the gate
# into the `--force` below — precisely the "rip a worktree out from under a running agent" harm
# the gate exists to prevent. Keeping `branch` last makes its empty case a TRAILING delimiter,
# which `read` discards harmlessly.
RECLAIMED=0; RECLAIMED_DIR_ONLY=0; SKIP_LOCKED=0; SKIP_NOTMERGED=0; SKIP_DIRTY=0; FAILED=0
STALE_LOCKS_FOUND=0
# Minimum age of a NOT-MERGED builder worktree's last commit before its DIRECTORY (never its
# branch ref) becomes eligible for the dir-only reclaim.
MIN_AGE_SECONDS="${LAND_WORKTREE_DIRONLY_MIN_AGE_SECONDS:-21600}"
while IFS=$'\t' read -r WT SHA LOCKED BR; do
  if [ "$LOCKED" = "1" ]; then
    # The lock recorded here is PER-SESSION, not per-agent — measured: several worktrees can
    # share ONE lock-owner pid (the parent session process), so a DEAD session leaves every
    # worktree it ever locked stuck at this check forever. worktree-lock-stale.sh proves the
    # recorded pid is either not running at all, or has been REUSED by an unrelated later
    # process (matching the recorded start-time token) — a plain PID-liveness probe cannot
    # safely make this call. A lock it cannot positively prove dead is left alone (fail closed).
    LOCK_REASON=$(git worktree list --porcelain | awk -v want="$WT" '
      /^worktree / { path=$2; reason="" }
      /^locked/    { reason=substr($0,8) }
      /^$/         { if (path==want) { print reason; exit }; path="" }
    ')
    if scripts/worktree-lock-stale.sh "$LOCK_REASON"; then
      STALE_LOCKS_FOUND=$((STALE_LOCKS_FOUND + 1))
      # `git worktree remove` refuses a still-locked worktree even with --force — that flag
      # overrides "has modifications," never "is locked". Proving the SESSION is dead is not
      # the same as clearing git's own on-disk lock, so unlock it now and reflect that in
      # $LOCKED so classify judges this candidate as unlocked.
      git worktree unlock "$WT" 2>/dev/null || true
      LOCKED=0
    fi
  fi
  # The classifier is the single source of truth for the bucket. It takes no action; the case
  # below performs the two destructive calls it only ever recommends — reading `git worktree
  # remove`'s own exit status, not merely the fact that we attempted it, so the summary can
  # never report "reclaimed N" when every remove FAILED.
  BUCKET=$(scripts/worktree-gc-classify.sh "$WT" "$SHA" "$LOCKED" "$BR" "$MIN_AGE_SECONDS")
  case "$BUCKET" in
    keep-locked)    SKIP_LOCKED=$((SKIP_LOCKED + 1)) ;;
    keep-notmerged) SKIP_NOTMERGED=$((SKIP_NOTMERGED + 1)) ;;
    keep-dirty)     SKIP_DIRTY=$((SKIP_DIRTY + 1)) ;;
    dir-only)
      if git worktree remove --force "$WT"; then
        RECLAIMED_DIR_ONLY=$((RECLAIMED_DIR_ONLY + 1))   # ref intentionally KEPT
      else
        FAILED=$((FAILED + 1))
      fi
      ;;
    full-reclaim)
      if git worktree remove --force "$WT"; then
        [ -n "$BR" ] && git branch -D "$BR" 2>/dev/null || true
        RECLAIMED=$((RECLAIMED + 1))
      else
        FAILED=$((FAILED + 1))
      fi
      ;;
    *)
      # Defensive net against a future classify bug printing something outside its documented
      # bucket set. Fails CLOSED rather than silently falling through either reclaim arm.
      echo "worktree GC: unexpected classify output '$BUCKET' for $WT — treating as failed" >&2
      FAILED=$((FAILED + 1))
      ;;
  esac
done < <(git worktree list --porcelain | awk '
  /^worktree / { path=$2; head=""; branch=""; locked=0 }
  /^HEAD / { head=$2 }
  /^branch refs\/heads\// { branch=substr($0,19) }
  /^locked/ { locked=1 }
  /^$/ { if (path!="" && path ~ /\/\.claude\/worktrees\//) print path"\t"head"\t"locked"\t"branch; path="" }
')
git worktree prune          # drop any now-stale worktree admin entries
# Always emit one line. "reclaimed 0 of 0" (nothing to do) reads differently from "reclaimed 0
# of N" (everything was skipped — worth investigating), and the reason breakdown makes a
# regression that silently zeroes out GC visible instead of indistinguishable from idle.
TOTAL=$((RECLAIMED + RECLAIMED_DIR_ONLY + SKIP_LOCKED + SKIP_NOTMERGED + SKIP_DIRTY + FAILED))
echo "worktree GC: reclaimed $((RECLAIMED + RECLAIMED_DIR_ONLY)) of $TOTAL candidate(s) (full=$RECLAIMED, dir-only=$RECLAIMED_DIR_ONLY, stale-locks-cleared=$STALE_LOCKS_FOUND; skipped: locked=$SKIP_LOCKED, not-merged=$SKIP_NOTMERGED, dirty=$SKIP_DIRTY; failed=$FAILED)"
```

**One loop covers BOTH branch-attached and DETACHED worktrees.** This replaced two separate sweeps —
one keyed on branch *name*, one on HEAD *sha* — that tested the literally identical predicate ("this
worktree's tip is already captured elsewhere") by two routes. The SHA form is strictly more general,
so a new worktree-**branch**-naming convention cannot leak past this loop. That name-independence is
**scoped to worktrees** and does NOT extend to the bare-ref backstops below, which must enumerate by
name because `refs/heads/*` is shared with human branches.

The one deliberate exception: the **dir-only** arm does key on the builder branch name, because what
it tests — "no agent will ever want this exact checkout again, and its ref will survive to hold the
commits" — has no metadata-free signal other than the branch shape.

```bash
# Second backstop: dangling local land/<id> refs with no worktree attached at all (so the sweep
# above never considered them) and no remote counterpart left. "Remote gone" is sufficient
# signal on its own: an in-flight ticket's origin/land/<id> always exists, so a missing remote
# means this local ref is already stale. No extra locked/merged check is needed — `git branch
# -D` itself refuses harmlessly if the branch is still checked out somewhere.
#
# List origin's land refs ONCE and only sweep if that listing SUCCEEDED: an unreachable origin
# makes ls-remote exit non-zero, and reading that as "every remote land branch is gone" would
# force-delete every local land ref on a transient network blip. An empty-but-successful
# listing correctly means every local land ref is stale.
#
# STRIP THE WORKTREE SUFFIX BEFORE COMPARING. Reviewers and pickups check the branch out under
# `land/<id>--<their-own-worktree-dir>`, which can NEVER byte-match origin's `land/<id>`.
# Comparing raw would make the "remote still exists — keep" arm dead code for every ref this
# sweep sees, silently demoting the backstop to "delete every land/* ref not currently checked
# out" and force-deleting an in-flight ticket's ref — unpushed commits with it — the moment its
# worktree goes away. `${BR%%--*}` maps the local name back to the remote one and leaves a bare
# name untouched. Safe because an id never contains `--`.
if REMOTE_LAND=$(git ls-remote --heads origin 'land/*' 2>/dev/null); then
  REMOTE_LAND=$(printf '%s\n' "$REMOTE_LAND" | sed 's#^.*refs/heads/##')
  # Report only deletions that ACTUALLY happened, reading `git branch -D`'s own exit status
  # rather than announcing one "before the fact" behind `|| true`. OBSERVED: this backstop once
  # printed "deleting stale local ref …" while the ref still existed afterward — the delete had
  # been refused (still checked out in a locked worktree) and `|| true` swallowed it silently.
  # Process substitution, not a pipe, so these counters survive past the loop.
  B2_DELETED=0; B2_FAILED=0
  while read -r BR; do
    printf '%s\n' "$REMOTE_LAND" | grep -qxF "${BR%%--*}" && continue   # remote exists — keep
    if git branch -D "$BR" 2>/dev/null; then
      B2_DELETED=$((B2_DELETED + 1))
    else
      B2_FAILED=$((B2_FAILED + 1))
    fi
  done < <(git for-each-ref --format='%(refname:short)' 'refs/heads/land/*')
  echo "bare-ref backstop2 (land/*): deleted $B2_DELETED stale local ref(s) (failed=$B2_FAILED)"
fi

# Third backstop: dangling local worktree-agent-* refs with no worktree attached — the same bug
# as backstop 2 but the OTHER namespace, invisible to both nets above, accumulating without
# bound (17 confirmed orphans on one machine). This namespace needs a DIFFERENT guard: a
# builder branch is never pushed to origin, so "remote gone" is meaningless here and would
# delete a LIVE, still-building branch. The correct guard is the same PREDICATE the worktree
# sweep applies — captured elsewhere — reached by a branch-NAME lookup, because a bare ref has
# no worktree and therefore no HEAD line to test; plus not currently checked out anywhere.
MERGED=$(git branch --merged main --format='%(refname:short)')
CHECKED_OUT=$(git worktree list --porcelain | awk '/^branch refs\/heads\//{print substr($0,19)}')
B3_DELETED=0; B3_FAILED=0
while read -r BR; do
  printf '%s\n' "$CHECKED_OUT" | grep -qxF "$BR" && continue   # still checked out — keep
  printf '%s\n' "$MERGED" | grep -qxF "$BR" || continue        # not merged — keep (in-flight)
  if git branch -D "$BR" 2>/dev/null; then
    B3_DELETED=$((B3_DELETED + 1))
  else
    B3_FAILED=$((B3_FAILED + 1))
  fi
done < <(git for-each-ref --format='%(refname:short)' 'refs/heads/worktree-agent-*')
echo "bare-ref backstop3 (worktree-agent-*): deleted $B3_DELETED stale local ref(s) (failed=$B3_FAILED)"

MY_TOKEN="$(cat "$(git rev-parse --git-dir)/land-lock-token" 2>/dev/null || true)"
[ -n "$MY_TOKEN" ] || echo "land: WARNING -- no own-token available; land-lock ownership check is DISABLED for this call \
  -- land-lock.sh REFUSES a blind release, so the lock stays held until it ages out" >&2
scripts/land-lock.sh release "$MY_TOKEN"   # the pass is fully done
```

`bd close` unblocks dependents — that is *why* the lander closes and the producer never does: a
closed ticket frees the next layer of `bd ready`. Closing is mine because the merge decision is mine.

The worktree GC is **best-effort and machine-local**. Builds can happen on several machines, and a
worktree on another machine simply isn't in this machine's list — that machine's own lander reclaims
it. **On a bounce or escalate the builder's worktree never satisfies either ancestry arm**, so its
**branch ref** is what survives, not its directory: once its last commit ages past the floor and its
tree is clean, the dir-only arm reclaims the directory and keeps the ref, so every commit stays
reachable but the checkout doesn't persist indefinitely. A **dirty** builder worktree is never
touched, in any bucket.

---

## Needs rebase — kick back

A **needs-rebase** is the outcome of the 2b precheck or a Section-3 textual conflict: the branch
**can't merge**, but its content was never judged bad — I never ran the semantic review on it. It is
a **third outcome, distinct from bounce and escalate**: not a rebuild (nothing is wrong with the
work), not a human decision (there's nothing to decide). So I keep everything and hand it straight
back to the producer.

**This block is its own separate Bash invocation from whichever producer detected the conflict** —
none of that block's shell state survives. Read the conflicting paths back from the file, and
refuse — loudly — rather than kick back with a blank paths section:

```bash
STATE_DIR="$(git rev-parse --git-dir)/land-state"   # re-derive — the FILE is what survived
CONFLICTS=$(scripts/land-state-load.sh "$STATE_DIR/conflicts/<id>" --require-nonempty -- \
  "the producer site did not persist the conflicting paths. Refusing to kick back with a" \
  "blank paths section.") || exit 1

bd update <id> --remove-label ready-for-land --add-label needs-rebase \
  --append-notes "NEEDS REBASE (/land): origin/land/<id> no longer merges cleanly onto
main @ $(git rev-parse --short origin/main).
Conflicting paths:
$CONFLICTS
/code's step-0 pickup merges current main into land/<id>, re-gates, commits, and pushes the
result itself (an ordinary, non-force push), then swaps needs-rebase back to ready-for-land."
scripts/bd-dolt-push.sh
# The branch is KEPT. The build worktree is KEPT. No supersede, no new ticket, no close.
```

The ticket stays `in_progress`; the `needs-rebase` label is now its state. **`/code` picks this up
automatically** on its next invocation — no human nudge needed unless the merge itself conflicts and
the two sides genuinely disagree.

## Bounce — clear failure

A **bounce** is a confident "this branch should not land as-is" (an unmet acceptance criterion,
silent scope creep, a violated invariant, a wrong approach — or drift from 2a). The original ticket
is **superseded** by a fresh ticket carrying the findings, so a producer can rebuild from a clean
brief.

**Before doing anything else: check for live descendants.** A bounce **deletes** the branch, and a
prior pass did that with no idea another live branch had already merged it in. Deleting does not
delete its commits from the dependent: the dependent went on carrying the rejected content —
including the very defect the bounce was rejecting — on a foundation that no longer existed and would
never land. So **read the descendants straight out of 1a's map** (the *full* relation). Do **not**
re-derive it with an ad-hoc `--contains` probe against the tip — that is the tip test 1a exists to
avoid.

- **No descendants** → proceed with the bounce below.
- **A live descendant found** → do **not** silently drop the branch. Escalate instead:

  ```bash
  bd update <id> --remove-label ready-for-land --add-label land-escalated \
    --append-notes "ESCALATION (/land bounce): land-review bounced this branch (findings below),
  but land/<dep> is a LIVE branch that already merged land/<id>'s commits — deleting land/<id> now
  would silently strand land/<dep>, which would carry the very defect this bounce is rejecting.
  Needs a human decision: FOLD (supersede both into one combined rebuild ticket), SEQUENCE
  (rebuild <id> alone; <dep> stays parked until the rebuild lands, then rebases onto it), or DROP
  (neither is wanted — close both).

  LAND-REVIEW FINDINGS: <verbatim>"
  scripts/bd-dolt-push.sh
  # BOTH branches are KEPT until the human resolves it.
  ```

  The dependent itself is left exactly as it is — this escalation doesn't touch it.

**The ordinary bounce.** Derive the blocks-dependent set **with its exit status tested**, THEN create
the rebuild ticket, THEN mark the original superseded:

```bash
# Derive blocks-dependents FIRST, before anything else changes state. Capture the output so the
# exit status is testable — a bare `for DEP in $(...)` discards it. If OTHER tickets depend on
# <id> via a `blocks` edge, the supersede below CLOSES <id> — so the tracker treats that blocker
# as satisfied and those dependents unblock PREMATURELY, while the real work still sits unbuilt
# in the rebuild. Re-pointing each dependent onto the rebuild is what prevents that.
#
# Extracted to a script, unlike the inline jq this replaced: that snippet was correct but
# ungated, and a dropped re-point here fails silently UNSAFE. But a derivation regression isn't
# the only way this goes wrong: a RUNTIME failure (tracker missing, DB locked, an unresolvable
# id) makes the script exit non-zero, which no gate on its internals can catch — only the caller
# reading its exit status can. That is what this `if !` does.
if ! DEPS=$(scripts/blocks-dependents.sh <id>); then
  bd update <id> --add-label land-escalated --remove-label ready-for-land \
    --append-notes "ESCALATION (bounce): scripts/blocks-dependents.sh <id> failed at runtime while
deriving blocks-dependents ahead of a supersede. Bounce does not proceed blind — superseding
without a reliable dependent list risks re-pointing nothing while blocks-dependents silently
unblock against an unbuilt rebuild. No rebuild ticket was created; land/<id> is kept. Retry once
the underlying failure clears."
  scripts/bd-dolt-push.sh
  # STOP with a STATEMENT, not a comment. A bare `# STOP` is INERT: control would fall through
  # the `fi` straight into the create/supersede/delete below, superseding the ticket anyway —
  # the exact "proceed blind" outcome this guard exists to prevent.
  exit 1
fi

NEW=$(bd create --type=<same-type-as-original> \
  --title="<original title> (rebuild after land bounce)" \
  --description="Rebuild of <id>, bounced by /land semantic review.

REBUILD BRIEF (from land-review):
<the findings + what the rebuild must satisfy that the bounced branch did not>" \
  --json | jq -r '.id')

# Preserve epic parentage BEFORE superseding — otherwise supersede closes the child and the epic
# loses it, reading falsely "complete" while the real work sits in an unlinked ticket.
# Re-parenting keeps completion accounting honest: the superseded child closes, but NEW is an
# open child, so the epic stays incomplete until the rebuild lands.
PARENT=$(bd show <id> --json | jq -r '.[0].parent // empty')
[ -n "$PARENT" ] && bd dep add "$NEW" "$PARENT" --type=parent-child

# Re-point the non-parent dependents derived above (captured before $NEW existed).
for DEP in $DEPS; do
  bd dep add "$DEP" "$NEW"   # DEP now depends on the rebuild, not the superseded original
done

bd supersede <id> --with "$NEW"   # links and AUTO-CLOSES <id> as superseded
bd update <id> --remove-label ready-for-land   # tidy the queue label off the now-closed original

git push origin --delete "land/<id>"    # drop the rejected branch
scripts/bd-dolt-push.sh
```

`bd supersede` **closes** the original — superseded means *replaced*, and the new ticket is the live
work. It is the one case where the landing side closes an `in_progress` producer ticket; a normal
accept closes via Section 4, and an escalate never closes.

### Branch disposition on a bounce — drop (default) vs. keep-for-lift

- **DROP (default)** — the finding is about the branch's *own* content: an unmet criterion, a wrong
  approach, a violated invariant, scope creep. Nothing there survives review unchanged.
- **KEEP-FOR-LIFT** — reserved for the *fold* resolution of a strand escalation: the **dependent's**
  branch (not the bounced base's) is kept when its content is judged independently sound, and the
  combined rebuild ticket says explicitly **"lift verbatim from `land/<dep>` @ `<sha>`"** rather than
  re-describing the same design from scratch. The **base's** branch is still dropped.

**A kept branch is not GC'd for free — say so in the rebuild ticket.** Section 4 deletes only the
branches in the landed set, and a kept branch belongs to a ticket that was *superseded*, not landed:
it will never appear there, so nothing deletes it automatically. The rebuild ticket must carry the
disposal instruction alongside the lift pointers — **"lift verbatim from `land/<dep>` @ `<sha>`;
delete `land/<dep>` once this ticket lands."** Until then it stays visible to 1a, which is correct: a
kept branch really does still contain its base's commits.

## Escalate — genuine decision

An **escalate** is a real question only a human can answer. I land **nothing** for it, **keep its
branch**, mark it, and surface the question — **without blocking the rest of the batch**:

```bash
bd update <id> --add-label land-escalated --remove-label ready-for-land \
  --append-notes "ESCALATION (/land semantic review): <the decision needed, with options>"
scripts/bd-dolt-push.sh
# origin/land/<id> is KEPT until the human resolves it.
```

A `land-escalated` branch is never touched by an automated sweep — only the human-driven resolutions
below remove the label and let the branch go.

## Resolving a `land-escalated` branch

`land-escalated` is **not terminal** — a human resolves it, and every resolution **removes the
label**, so the queue can reach empty. Resolution is a human action taken outside a pass; `/land`
only ever *sets* the label. There are exactly four exits.

### (a) Land as-is — materialize the decision first, then re-enter the queue

If the human decides the branch **should** land, the branch itself needs no change. What changes is
the *ticket*: swapping the label back with nothing else touched is **not a complete transition**,
because the next pass re-dispatches the review, which hits the *same* ambiguity and escalates again —
an infinite loop.

So the swap is valid only once the human has **written the decision into the ticket**. The review
stays authoritative on re-review; there is deliberately **no "human-blessed" bypass label**.

```bash
bd update <id> --acceptance="<revised, unambiguous acceptance criteria>"
  # land-review reads acceptance_criteria as the contract — this is the field that must change.
  # The BRANCH is untouched.
# If resolving this required a COMMIT to land/<id> — which it does whenever the decision belongs
# in docs/ rather than a tracker field — refresh land_head, or Section 2a reads the commit you
# just made as DRIFT and prescribes a bounce next pass. This exit is the exposed one because it
# re-enters with no reviewer in between; exits (b) and (d) route through a reviewer, which
# refreshes land_head itself.
# --set-metadata (upsert), NOT --metadata (a whole-blob replace that drops the other keys).
bd update <id> --set-metadata land_head="$(git rev-parse origin/land/<id>)"   # omit if nothing committed
bd update <id> --remove-label land-escalated --add-label ready-for-land
scripts/bd-dolt-push.sh
```

### (b) Rebuild — supersede into a fresh ticket, drop the branch

Resolve it exactly like a bounce: new ticket carrying the decision, supersede, drop the branch (same
epic re-parent and dependent re-point care applies).

**Before dropping the branch, run the same descendant check as Bounce** — an escalated branch can
have picked up a live stacked dependent while it sat waiting, and a *stale* graph from the pass that
escalated it is no use here, so recompute 1a's relation against the live refs. If it finds a live
descendant, apply the fold/sequence/drop framing instead of proceeding blind.

```bash
NEW=$(bd create --type=<same-type-as-original> \
  --title="<original title> (rebuild after land-escalated)" \
  --description="Rebuild of <id>. Human resolution of the escalated decision:
<the decision + what the rebuild must satisfy that the escalated branch did not>" \
  --json | jq -r '.id')
# re-parent onto the same epic / re-point blocking dependents — see Bounce for why.
bd supersede <id> --with "$NEW"
bd update <id> --remove-label land-escalated
git push origin --delete "land/<id>"
scripts/bd-dolt-push.sh
```

### (c) Drop — close with reason, GC the branch

**Same descendant check before deleting** — a dropped branch's commits are just as live inside a
dependent as a bounced branch's would be. A live descendant means dropping also strands that
dependent's foundation: surface that as part of this same decision rather than deleting silently.

```bash
bd close <id> --reason "<why this is dropped>"
bd update <id> --remove-label land-escalated
git push origin --delete "land/<id>"
scripts/bd-dolt-push.sh
```

### (d) Amend and re-gate — fix the already-landed defect, keep the branch and ticket

Two triggers:

**Trigger 1 — `/land`'s combined re-gate.** Applies when the escalation was raised by the combined
re-gate, not by the semantic review or a producer gate, and all of:

- the semantic review **accepted** this branch (the escalation happened *after* review);
- the merge precheck was clean;
- the re-gate failure is traceable to code **already on the default branch**, not to anything this
  branch introduces — the branch would have gated green before whatever landed the defect, and gates
  red now only because it is the first thing to exercise the defective landed code.

Under those conditions neither other exit fits: "land as-is" is for a branch that needs no change,
and this one does; "rebuild" discards a branch already judged sound, which is the wrong instrument
for a defect that isn't the branch's fault.

**Trigger 2 — a semantic-review escalation whose resolution requires a scoped on-branch edit.**
Trigger 1's three conditions attach to it only. This trigger's sole condition is that the human
decides the fix requires editing the branch, rather than landing as-is, rebuilding, or dropping.

Either way the human amends the branch and sends it back **one gate earlier than a normal "land
as-is"**, at `ready-for-code-review`: the amendment is new, ungated content the original accept never
saw, so it needs its own technical review before a semantic re-review is worth spending.

**Write the added scope into the acceptance criteria, not only into a note** — the re-entered branch
still has to clear `ready-for-land`, where the next pass re-runs the semantic review, which reads
acceptance criteria as the contract. An amendment recorded only in notes reads to that re-review as
scope creep on a branch it already accepted.

```bash
bd update <id> --acceptance="<original criteria + what the amendment must satisfy>"
bd update <id> --remove-label land-escalated --add-label ready-for-code-review \
  --append-notes "RESOLVED (human, amend-and-re-gate): <the landed defect + the fix>"
scripts/bd-dolt-push.sh
# The human may amend the branch before the swap, or leave it to the code-reviewer that /code's
# stranded-review sweep dispatches. Either way it re-gates and re-pushes.
```

### Re-entry per escalating source — re-enter at the gate that escalated

Whichever gate could not resolve the ambiguity is the gate that re-runs once it is resolved — the
same gate, against the now-unambiguous ticket, never a later gate taking the resolution on faith.

| escalated by | exit | re-entry label |
|---|---|---|
| `/land` semantic review, resolution needs **no** branch edit | (a) | `ready-for-land` |
| `/land` semantic review, resolution needs **a** branch edit | (d) | `ready-for-code-review` |
| `code-reviewer` technical review | (a) | `ready-for-code-review` |
| `coding` rebase-pickup conflict | (a) | `needs-rebase` |
| `coding` build-time clarification | (a) | `ready-for-code-review` |
| `/land` combined re-gate (defect already landed) | (d) | `ready-for-code-review` |
| `/land` §2a malformed `land_head` metadata | (a) | `ready-for-land` |

The two semantic-review rows are an explicit **no branch edit / a branch edit** pair so they cannot
both match one escalation. The discriminator is **not** the escalation but a property of the human's
*resolution* — whether it requires editing the branch. Every row follows the same shape: write the
decision into the ticket first, then swap the label and publish.

**Re-entering at `ready-for-code-review` MUST also (re)write `metadata.review_head` as part of the
same resolution.** This hand-edit happens outside any `/code` run, and nothing else on this path
forces the field to exist — `/code`'s stranded-review sweep will not dispatch a reviewer until a
non-empty `review_head` can be established (deliberately: it will not guess a head to review), so
omitting this step used to strand the ticket forever, `in_progress` and invisible to everything but a
repeated "needs a human" line. That sweep now derives the field itself as a **backstop**, not a
substitute. Validate before writing — an `ls-remote` that resolves nothing prints nothing, and an
unguarded write would put an *empty* value on the ticket, re-creating the state this exists to
prevent:

```bash
SHA="$(git ls-remote origin "refs/heads/land/<id>" | cut -f1)"
scripts/validate-sha40.sh review_head "$SHA" && bd update <id> --set-metadata review_head="$SHA"
```

**The build-time case is the deliberately arguable one.** A build-time escalation means the producer
stopped mid-build, so its branch is green-but-possibly **incomplete** and never reached
`ready-for-code-review` on its own. Re-entering it there hands the reviewer a branch that may not
implement the whole ticket. That trade-off is accepted — routing every trivially-answerable build
question through a full rebuild would over-charge a question the branch may already answer correctly
— under three conditions:

1. The human writes the resolved answer into the ticket **before** flipping the label.
2. The reviewer is not obliged to pass a half-built branch: **escalate** is its standing non-pass
   outcome, so a build-time re-entry asserts only that the *ambiguity* is resolved, not that the
   branch is *finished*. The semantic review's **bounce** verdict is the backstop if it slips past.
3. Re-entry means "the decision is made, re-run the pipeline from technical review" — **not** "this
   branch is done."

---

## Tracker-sync discipline (non-negotiable)

I am the system's heaviest tracker writer, and the repo runs **`import.auto: false`**: **Dolt is
authoritative; `.beads/issues.jsonl` is an export-only passive artifact, never a sync wire.**

- **Pull at the start, push after writes.** `bd dolt pull` opens the pass;
  `scripts/bd-dolt-push.sh` (retry-on-reject: backoff + re-pull between attempts, since a concurrent
  producer's write can transiently reject or lock-contend) follows *every* batch of writes.
- **Never commit the JSONL export, never `bd import` it.** Import only upserts and silently misses
  deletions. `import.auto: false` already stops the post-merge hook from re-importing a stale export
  and reverting a close; do not re-enable that path.
- **Never let the passive export block or enter a merge.** Unstage it right before the merge loop,
  every pass, on the assumption it may be staged even when `git diff` says otherwise.
- **Order so a close can't be reverted by a stale export.** Push, then close, then publish — the
  authoritative close lives in Dolt and is pushed immediately.

---

## What I never do

- **Land work I can't verify.** Drift, a textual conflict, a red re-gate, or a bounce verdict all stop
  a branch from landing this pass.
- **Rebase a producer's branch myself, or review a branch that won't merge.** A branch failing 2b is
  kicked back for the *producer* to merge in its own worktree.
- **Land on a bounce or escalate, or skip the semantic review.** The review is the *first* task per
  branch; only an accept enters the merge set.
- **Run two landers at once**, or run the loop on more than one machine.
- **Commit the passive export, or `bd import` it** in place of `bd dolt pull`.
- **Touch a producer's worktree, or record a design decision in a tracker note** instead of `docs/`.
- **Delete a branch without first checking for a live descendant.**
- **Merge a stacked dependent before its base, or land a dependent whose base isn't in this pass's
  accepted set.**
- **Trust `builds_on` metadata as the mechanism for detecting a stacked branch.** It's a breadcrumb;
  always derive from git containment.
- **File a ticket for an incidental discovery** — something I notice about `/land`'s own mechanics
  mid-pass, not a per-branch verdict. I **report** it instead, and the human reading that report
  decides whether it becomes a ticket. This is scoped narrowly and does not touch the two sanctioned
  create paths (the bounce rebuild ticket, and exit (b)) — both are per-branch verdicts, my actual
  job.

  *Why not-filing loses nothing:* every pass **executes** this skill's own code, so every pass gets
  the same opportunity to notice the same flaw — the observation recurs on its own, without a ticket
  to carry it between passes. Proven in practice: three independent passes noticed one dead check and
  each re-derived it from scratch, filing three duplicates. Not filing removes the dupe generator.

  *Rejected alternative — "search the tracker before filing":* it codifies the improvised filing path
  instead of removing it, and it aims at a step that never happened — every one of those three
  filings created the ticket **first** and searched afterwards or not at all. A search-first caveat
  only binds an agent already consulting this file's filing guidance, and an agent improvising a
  filing path this file does not sanction is, by construction, not that agent.

  **Not filing is not the same as leaving work for the human** — see below.

## Stop and report

When the pass ends I release the lock and report: how many branches I reviewed; which **landed**
(with the merge SHA, in merge order); which I **kicked back** (they never reached the semantic
review); which I **bounced** (and the superseding ticket IDs); which I **escalated** (and the decision
each owes a human); which I **held** as an orphaned stacked dependent and what base it's waiting on;
any **epic** I flagged for audit; anything that **drifted**; and any **incidental discovery**, named
here rather than filed. On any genuine ambiguity in the landing mechanics themselves — not a
per-branch verdict — I stop and surface it rather than guess.

### If the whole remedy is a one-line doc change, report the patch — not the gap

Naming a one-line fix as a "discovery" and stopping there hands the human a research task: re-find
the surface, re-derive the wording, decide whether it earns a ticket. For a remedy that small the
ticket costs more than the fix. So whenever I can state the remedy in a line or two, I report it as a
patch the human can apply directly, with all three of:

- **The exact replacement text**, written out in full — the words to paste, never a description of
  what they should say.
- **Where it goes** — file path plus the line number I actually **derived this pass** (`grep -n` at
  report time, never recalled or estimated) *and* the anchor line **quoted verbatim**, so the
  location survives the number going stale.
- **What it changes**, in one sentence, so the human can accept or reject without opening the file.

**I still do not apply it.** I run on the default branch in the primary checkout, and a doc edit typed
here reaches it with no branch, no technical review, no semantic review and no re-gate — bypassing
every gate this skill exists to be. The patch text is a **hand-off**.

**The escape hatch, stated so it isn't quietly stretched.** This applies only when the remedy is
purely *how to word it*. The moment the fix needs a judgment call about *what to say*, it is no
longer a one-line patch and goes back to being an ordinary reported discovery. Length is the symptom,
not the test: a two-line change that encodes a decision is a discovery; a five-line change that only
transcribes an already-settled one is still a patch.
