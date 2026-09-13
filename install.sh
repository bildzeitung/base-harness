#!/usr/bin/env bash
#
# Install the agent harness into a target git repository.
#
# Runs `git init -b main` if the target is not already a repository, copies
# template/ into it, never overwriting an existing file unless --force is given,
# then initialises the beads tracker non-interactively with the harness's
# opinions baked in (see "tracker" below), then builds ./.venv through
# `uv sync` when uv is on PATH (see "python" below). If the repo has no git
# remote and `gh` is on PATH, it creates a private GitHub repository named
# after the target directory and adds it as origin (see "remote" below). With
# a tracker it just initialised and an origin to push to, it then publishes the
# tracker: pushes the branch if the remote is empty (Dolt refuses a remote with
# no branches), then runs scripts/bd-dolt-push.sh (see "publish" below).
#
# Usage:
#   ./install.sh /path/to/repo [--dry-run] [--force] [--prefix <id-prefix>] [--skip-bd-init] [--skip-remote]
#
# --prefix defaults to the target directory's basename. It must contain no
# double hyphen ("--"): /land's ref backstop splits on it (docs/customizing.md).
#
# Exit codes: 0 ok, 1 usage/precondition failure, 2 machine fault.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
TEMPLATE="$HERE/template"

TARGET=""
DRY_RUN=0
FORCE=0
SKIP_BD=0
SKIP_REMOTE=0
PREFIX=""
want_prefix=0
for arg in "$@"; do
  if [ "$want_prefix" = 1 ]; then
    PREFIX="$arg"; want_prefix=0; continue
  fi
  case "$arg" in
    --dry-run)      DRY_RUN=1 ;;
    --force)        FORCE=1 ;;
    --skip-bd-init) SKIP_BD=1 ;;
    --skip-remote)  SKIP_REMOTE=1 ;;
    --prefix)       want_prefix=1 ;;
    --prefix=*)     PREFIX="${arg#--prefix=}" ;;
    -h|--help)
      sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) echo "install: unknown option '$arg'" >&2; exit 1 ;;
    *)
      [ -n "$TARGET" ] && { echo "install: more than one target given" >&2; exit 1; }
      TARGET="$arg"
      ;;
  esac
done
[ "$want_prefix" = 1 ] && { echo "install: --prefix needs a value" >&2; exit 1; }

[ -n "$TARGET" ] || { echo "install: usage: ./install.sh /path/to/repo [--dry-run] [--force] [--prefix <id-prefix>] [--skip-bd-init] [--skip-remote]" >&2; exit 1; }
[ -d "$TEMPLATE" ] || { echo "install: template/ not found beside this script" >&2; exit 2; }
[ -d "$TARGET" ]   || { echo "install: '$TARGET' is not a directory" >&2; exit 1; }

# A git repo is a hard precondition: the whole harness is worktree-based. A target
# that is not one gets `git init -b main` — main because that is the branch name
# baked into the templates, so a repo created here needs no substitution. The
# `-b` fallback covers git older than 2.28.
GIT_INITED=0
if ! git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
  if [ "$DRY_RUN" = 1 ]; then
    GIT_INITED=dry
  else
    git -C "$TARGET" init -q -b main 2>/dev/null \
      || { git -C "$TARGET" init -q && git -C "$TARGET" symbolic-ref HEAD refs/heads/main; } \
      || { echo "install: git init failed in '$TARGET'" >&2; exit 2; }
    GIT_INITED=1
  fi
fi

# bd is checked up front, not after the copy: discovering it is missing once
# half the install has landed leaves the target in the state this script exists
# to avoid.
if [ "$SKIP_BD" != 1 ] && ! command -v bd >/dev/null 2>&1; then
  echo "install: 'bd' (beads) is not on PATH. Install it, or pass --skip-bd-init to install the files only." >&2
  exit 1
fi

# The prefix is the one id-shape input the harness cares about, and bd does not
# validate it: it accepts "a--b" silently, and rewrites characters it dislikes
# ("My.Proj" becomes "My_Proj") without failing. Validate here, strictly enough
# that bd will use the value verbatim, so what is written to config.yaml below
# is what the ids actually carry.
if [ "$SKIP_BD" != 1 ]; then
  [ -n "$PREFIX" ] || PREFIX="$(basename "$(cd "$TARGET" && pwd -P)")"
  case "$PREFIX" in
    *--*)
      echo "install: prefix '$PREFIX' contains '--', which /land's ref backstop splits on. Pass --prefix <something-else>." >&2
      exit 1 ;;
  esac
  if ! printf '%s' "$PREFIX" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]*$'; then
    echo "install: prefix '$PREFIX' is not [A-Za-z0-9][A-Za-z0-9_-]*; bd would rewrite it. Pass --prefix <letters-digits-_->." >&2
    exit 1
  fi
fi

DEFAULT_BRANCH="$(git -C "$TARGET" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")"
[ "$GIT_INITED" = dry ] && DEFAULT_BRANCH=main

echo "install: target      $TARGET"
case "$GIT_INITED" in
  1)   echo "install: git         initialised (was not a repository)" ;;
  dry) echo "install: git         would run 'git init -b main' (not a repository)" ;;
esac
echo "install: branch      ${DEFAULT_BRANCH:-<detached or unborn>}"
[ "$SKIP_BD" != 1 ] && echo "install: bd prefix   $PREFIX"
[ "$DRY_RUN" = 1 ] && echo "install: DRY RUN — nothing will be written"
echo

copied=0; skipped=0; overwritten=0
while IFS= read -r rel; do
  src="$TEMPLATE/$rel"
  dst="$TARGET/$rel"
  if [ -e "$dst" ] && [ "$FORCE" != 1 ]; then
    printf '  SKIP      %s (exists — use --force to overwrite)\n' "$rel"
    skipped=$((skipped + 1))
    continue
  fi
  if [ -e "$dst" ]; then
    printf '  OVERWRITE %s\n' "$rel"
    overwritten=$((overwritten + 1))
  else
    printf '  write     %s\n' "$rel"
    copied=$((copied + 1))
  fi
  if [ "$DRY_RUN" != 1 ]; then
    mkdir -p "$(dirname "$dst")" || exit 2
    cp -f "$src" "$dst" || exit 2
    # Preserve the executable bit rather than re-deriving it from the extension:
    # the source tree is the authority on what is meant to be runnable.
    [ -x "$src" ] && chmod +x "$dst"
  fi
done < <(
  # Prune tool state: running the template's own gates in place leaves
  # __pycache__/, .ruff_cache/, .pytest_cache/, .nox/, a venv and a uv.lock
  # behind, and none of it is template content -- a stale .pyc or another
  # machine's ruff cache must never be installed. The lock is excluded on
  # principle, not just hygiene: it is a project artifact, resolved on the
  # target by `uv sync` below and committed there.
  cd "$TEMPLATE" && find . \( -name __pycache__ -o -name '*.pyc' -o -name '*.pyo' \
      -o -name .ruff_cache -o -name .pytest_cache -o -name .mypy_cache -o -name .nox \
      -o -name venv -o -name .venv -o -name uv.lock \) -prune -o -type f -print \
    | sed 's#^\./##' | sort
)

echo
echo "install: $copied new, $overwritten overwritten, $skipped skipped"

# ---- tracker -------------------------------------------------------------------
#
# `bd init` is interactive by default; this is the opinionated non-interactive
# equivalent. The opinions, and why each one is not negotiable here:
#
#   --skip-agents   bd would otherwise write its own CLAUDE.md, .claude/settings.json,
#                   AGENTS.md, .codex/ and .agents/ — straight over the harness files
#                   copied above.
#   --role          "maintainer" (the non-interactive default). Contributor/team
#                   wizards are interactive-only.
#   hooks: kept     bd points core.hooksPath at .beads/hooks/. The harness assumes
#                   those hooks (CLAUDE.md "Workflow gotchas"). Anything that was in
#                   .git/hooks/ is bypassed from here on.
#   import.auto     FALSE, written to .beads/config.yaml. `bd config set` would put
#                   it in the Dolt database, where harness-doctor.sh (which reads the
#                   file) cannot see it. This is the harness's single hard invariant:
#                   with auto-import on, a pull replays a stale committed issues.jsonl
#                   into Dolt and silently reverts recent closes.
#
# bd init makes its own commit ("bd init: initialize beads issue tracking") on the
# current branch; the config.yaml edit is committed as a second one so the invariant
# is in history before the first ticket exists.
echo
echo "tracker"
BD_INITED=0
if [ "$SKIP_BD" = 1 ]; then
  echo "  SKIP      bd init (--skip-bd-init)"
elif [ -e "$TARGET/.beads" ]; then
  echo "  SKIP      bd init (.beads/ exists — leaving the tracker alone; harness-doctor.sh checks import.auto)"
elif [ "$DRY_RUN" = 1 ]; then
  echo "  would run bd init --non-interactive --role maintainer --skip-agents --prefix $PREFIX"
  echo "  would set import.auto: false in .beads/config.yaml and commit it"
  BD_INITED=dry
else
  bd_out="$(mktemp)" || exit 2
  if ! (cd "$TARGET" && BD_NON_INTERACTIVE=1 bd init --non-interactive --role maintainer --skip-agents --prefix "$PREFIX") >"$bd_out" 2>&1; then
    echo "install: bd init failed:" >&2
    sed 's/^/    /' "$bd_out" >&2
    rm -f "$bd_out"
    exit 2
  fi
  # Trust what bd reports over what was asked for; validation above should make
  # them identical, and a mismatch means an assumption about bd has broken.
  used="$(sed -n 's/^[[:space:]]*Issue prefix:[[:space:]]*//p' "$bd_out" | head -1)"
  rm -f "$bd_out"
  if [ -n "$used" ] && [ "$used" != "$PREFIX" ]; then
    echo "install: bd init used prefix '$used', not '$PREFIX' — refusing to guess which the ids carry" >&2
    exit 2
  fi
  printf '  ran       bd init --non-interactive --role maintainer --skip-agents --prefix %s\n' "$PREFIX"
  BD_INITED=1

  cfg="$TARGET/.beads/config.yaml"
  [ -f "$cfg" ] || { echo "install: bd init reported success but $cfg is missing" >&2; exit 2; }
  if grep -Eq '^(import|import\.auto|issue-prefix):' "$cfg"; then
    echo "install: $cfg already has an uncommented import/issue-prefix key; not appending over it" >&2
    exit 2
  fi
  cat >>"$cfg" <<CFG || exit 2

# ---- added by the harness installer ----
# Read by scripts/harness-doctor.sh; must match the prefix bd init was given.
issue-prefix: "$PREFIX"
# HARD INVARIANT (docs/architecture.md, "Tracker sync discipline"). With auto-import
# on, the post-checkout/post-merge hooks replay a stale committed issues.jsonl back
# into Dolt after any pull and silently revert recent closes. Never flip this.
import:
  auto: false
CFG
  echo "  wrote     .beads/config.yaml (issue-prefix, import.auto: false)"
  if git -C "$TARGET" add .beads/config.yaml && git -C "$TARGET" commit -q -m "chore: pin beads import.auto=false" >/dev/null 2>&1; then
    echo "  committed .beads/config.yaml"
  else
    echo "  NOTE      could not commit .beads/config.yaml (no git identity?) — commit it by hand before the first ticket"
  fi
fi

# ---- python --------------------------------------------------------------------
#
# `uv sync` runs here rather than being left to the walkthrough: every fresh
# install needs it and it was the step most often skipped. uv owns the whole
# Python side -- it finds (or downloads) an interpreter satisfying
# pyproject.toml's requires-python, creates ./.venv, resolves uv.lock and
# installs it -- so there is no interpreter to probe for and no venv to
# hand-build. The harness ships no lock: a resolution belongs to the project,
# so a target without one gets a plain `uv sync`, which writes uv.lock for
# the project to commit, and tests/harness/ is runnable the moment this returns. A
# target that already has a lock gets `uv sync --locked`, which never moves
# it. Skipped, not failed, when uv is not on PATH: nothing here can fix that,
# and every file is already in place for a hand run later.
echo
echo "python"
VENV_SKIPPED=0
LOCK_WRITTEN=0
lock_present=0
[ -e "$TARGET/uv.lock" ] && lock_present=1
sync_args=""
[ "$lock_present" = 1 ] && sync_args="--locked"
if ! command -v uv >/dev/null 2>&1; then
  echo "  SKIP      uv sync (uv not on PATH)"
  VENV_SKIPPED=1
elif [ -e "$TARGET/.venv" ]; then
  echo "  SKIP      uv sync (.venv/ exists)"
elif [ "$DRY_RUN" = 1 ]; then
  echo "  would run uv sync${sync_args:+ $sync_args} ($(uv --version 2>/dev/null))"
else
  out="$(mktemp)" || exit 2
  # shellcheck disable=SC2086  # $sync_args is at most one flag, deliberately unquoted
  if (cd "$TARGET" && uv sync $sync_args) >"$out" 2>&1; then
    rm -f "$out"
    echo "  ran       uv sync${sync_args:+ $sync_args} ($(uv --version 2>/dev/null))"
    echo "  built     .venv/"
    if [ "$lock_present" = 0 ]; then
      echo "  wrote     uv.lock"
      LOCK_WRITTEN=1
    fi
  else
    echo "install: uv sync failed; last 30 lines:" >&2
    tail -30 "$out" | sed 's/^/    /' >&2
    rm -f "$out"
    echo "install: files and tracker are in place. Fix the cause, then run 'uv sync' by hand." >&2
    exit 2
  fi
fi

# ---- remote --------------------------------------------------------------------
#
# `bd dolt push`, the one step left to the walkthrough, needs a git origin. A
# fresh `git init` has none, so when `gh` is on PATH and the repo has no remote
# at all, create a private GitHub repository named after the target directory
# (basename only, never the path) and wire it up as origin. Private, no wiki,
# no issues: the tracker is beads, not GitHub Issues, and a public repo is a
# decision to make on purpose. Any existing remote, whatever its name, means
# the user has already decided where this repo lives. Runs last so a failure
# here leaves the files, tracker and .venv in place.
echo
echo "remote"
REMOTE_CREATED=0
REPO_NAME="$(basename "$(cd "$TARGET" && pwd -P)")"
if [ "$SKIP_REMOTE" = 1 ]; then
  echo "  SKIP      gh repo create (--skip-remote)"
elif [ "$GIT_INITED" != dry ] && [ -n "$(git -C "$TARGET" remote 2>/dev/null)" ]; then
  echo "  SKIP      gh repo create (remote exists: $(git -C "$TARGET" remote | paste -sd' ' -))"
elif ! command -v gh >/dev/null 2>&1; then
  echo "  SKIP      gh repo create (gh not on PATH)"
elif ! gh auth status >/dev/null 2>&1; then
  echo "  SKIP      gh repo create (gh is not logged in -- 'gh auth login', then create the remote by hand)"
elif [ "$DRY_RUN" = 1 ]; then
  echo "  would run gh repo create $REPO_NAME --source=. --remote=origin --private --disable-wiki --disable-issues"
else
  gh_out="$(mktemp)" || exit 2
  if (cd "$TARGET" && gh repo create "$REPO_NAME" --source=. --remote=origin --private --disable-wiki --disable-issues) >"$gh_out" 2>&1; then
    rm -f "$gh_out"
    echo "  ran       gh repo create $REPO_NAME --source=. --remote=origin --private --disable-wiki --disable-issues"
    echo "  origin    $(git -C "$TARGET" remote get-url origin 2>/dev/null)"
    REMOTE_CREATED=1
  else
    echo "install: gh repo create failed:" >&2
    sed 's/^/    /' "$gh_out" >&2
    rm -f "$gh_out"
    echo "install: files, tracker and .venv are in place. Create the remote by hand (or fix the cause and re-run; every other step is skipped once done)." >&2
    exit 2
  fi
fi

# ---- publish -------------------------------------------------------------------
#
# The tracker's wire is refs/dolt/data on the git origin, and `bd init` above
# already pointed the Dolt remote at it. Only a tracker THIS run initialised is
# pushed: an existing .beads/ was left alone above, and publishing it is the
# same decision. Dolt refuses to push to a git remote with no branches at all
# ("initialize the repository with an initial branch/commit first"), so an
# empty remote -- the just-created GitHub repo, or any fresh bare repo -- gets
# the branch pushed first. A remote that already has branches is left as it
# is: pushing the branch there is a merge decision, not setup. The push goes
# through scripts/bd-dolt-push.sh, the harness's guarded chokepoint, not bare
# `bd dolt push`.
echo
echo "publish"
TRACKER_PUSHED=0
BRANCH_PUSHED=0
# Is there an origin -- or, on a dry run, would the remote step above have made one?
origin_present=0
[ "$GIT_INITED" != dry ] && git -C "$TARGET" remote get-url origin >/dev/null 2>&1 && origin_present=1
if [ "$origin_present" = 0 ] && [ "$DRY_RUN" = 1 ] && [ "$SKIP_REMOTE" != 1 ] && command -v gh >/dev/null 2>&1; then
  if [ "$GIT_INITED" = dry ] || [ -z "$(git -C "$TARGET" remote 2>/dev/null)" ]; then
    origin_present=dry
  fi
fi
if [ "$BD_INITED" = 0 ]; then
  echo "  SKIP      bd dolt push (tracker not initialised by this run)"
elif [ "$origin_present" = 0 ]; then
  echo "  SKIP      bd dolt push (no origin remote; run ./scripts/bd-dolt-push.sh once there is one)"
elif [ "$DRY_RUN" = 1 ]; then
  echo "  would push the branch to origin if the remote has no branches yet"
  echo "  would run ./scripts/bd-dolt-push.sh"
else
  branch="$(git -C "$TARGET" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")"
  heads="$(git -C "$TARGET" ls-remote --heads origin 2>&1)" || {
    echo "install: cannot reach origin to publish the tracker:" >&2
    printf '%s\n' "$heads" | sed 's/^/    /' >&2
    echo "install: everything else is in place. Fix the remote, then run ./scripts/bd-dolt-push.sh by hand." >&2
    exit 2
  }
  if [ -z "$heads" ]; then
    if [ -z "$branch" ]; then
      echo "install: origin is empty and HEAD is not on a branch; cannot push. Push a branch, then run ./scripts/bd-dolt-push.sh by hand." >&2
      exit 2
    fi
    if git -C "$TARGET" push -q -u origin "$branch" >/dev/null 2>&1; then
      echo "  pushed    $branch -> origin (remote was empty; Dolt needs a branch there)"
      BRANCH_PUSHED=1
    else
      echo "install: git push -u origin $branch failed; cannot publish the tracker to an empty remote." >&2
      echo "install: everything else is in place. Push the branch, then run ./scripts/bd-dolt-push.sh by hand." >&2
      exit 2
    fi
  fi
  push_out="$(mktemp)" || exit 2
  if (cd "$TARGET" && ./scripts/bd-dolt-push.sh) >"$push_out" 2>&1; then
    rm -f "$push_out"
    echo "  ran       ./scripts/bd-dolt-push.sh (refs/dolt/data is on origin)"
    TRACKER_PUSHED=1
  else
    echo "install: scripts/bd-dolt-push.sh failed:" >&2
    sed 's/^/    /' "$push_out" >&2
    rm -f "$push_out"
    echo "install: everything else is in place. Fix the cause, then run ./scripts/bd-dolt-push.sh by hand." >&2
    exit 2
  fi
fi

if [ "$DRY_RUN" = 1 ]; then
  echo
  echo "install: dry run complete — re-run without --dry-run to apply"
  exit 0
fi

# The default branch is baked into the templates as `main`. Say so plainly rather
# than rewriting the files: a silent sed across skills and guard scripts is exactly
# the kind of unreviewed bulk edit this harness exists to prevent.
if [ -n "$DEFAULT_BRANCH" ] && [ "$DEFAULT_BRANCH" != "main" ]; then
  echo
  echo "install: NOTE — this repo's default branch is '$DEFAULT_BRANCH', but the harness"
  echo "         templates say 'main'. Before running anything, replace it:"
  echo
  echo "           cd $TARGET"
  printf '%s\n' "           grep -rl '\\bmain\\b' .claude scripts CLAUDE.md"
  echo "           # review each hit, then substitute deliberately"
  echo
  echo "         See docs/customizing.md ('Default branch name') in the harness export."
fi

if [ "$VENV_SKIPPED" = 1 ]; then
  echo
  echo "install: NOTE — uv is not on PATH, so ./.venv was not built. Install uv"
  echo "         (https://docs.astral.sh/uv/getting-started/installation/) and run"
  echo "         'uv sync' in $TARGET before step 3 below."
fi

if [ "$LOCK_WRITTEN" = 1 ]; then
  echo
  echo "install: uv.lock was resolved on this machine -- it is your project's, not the"
  echo "         harness's. Commit it with your first commit; the lock_currency gate reads it."
fi

if [ "$REMOTE_CREATED" = 1 ] && [ "$BRANCH_PUSHED" = 0 ]; then
  echo
  echo "install: origin is a new, empty GitHub repository -- push the branch:"
  echo "           git -C $TARGET push -u origin ${DEFAULT_BRANCH:-main}"
fi

echo
echo "install: next steps (see docs/getting-started.md for the full walkthrough)"
echo
echo "  1. Install prerequisites:      jq, uv, (docker for diagram validation)"
if [ "$TRACKER_PUSHED" = 1 ]; then
  echo "  2. Publish the tracker:        done (refs/dolt/data is on origin)"
else
  echo "  2. Publish the tracker:        ./scripts/bd-dolt-push.sh   (needs a git origin with a branch)"
fi
cat <<'NEXT'
  3. Check the install:          ./scripts/harness-doctor.sh && uv run --frozen nox -s harness_tests
  4. Fill in the placeholders:   CLAUDE.md, pyproject.toml, docs/conventions.md, docs/design.md
  5. File your first ticket, then run /code

NEXT
