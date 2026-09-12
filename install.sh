#!/usr/bin/env bash
#
# Install the agent harness into a target git repository.
#
# Runs `git init -b main` if the target is not already a repository, copies
# template/ into it, never overwriting an existing file unless --force is given,
# then initialises the beads tracker non-interactively with the harness's
# opinions baked in (see "tracker" below). It does NOT create a venv or publish
# the tracker (`bd dolt push`) — those are walked through in docs/getting-started.md.
#
# Usage:
#   ./install.sh /path/to/repo [--dry-run] [--force] [--prefix <id-prefix>] [--skip-bd-init]
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
    --prefix)       want_prefix=1 ;;
    --prefix=*)     PREFIX="${arg#--prefix=}" ;;
    -h|--help)
      sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

[ -n "$TARGET" ] || { echo "install: usage: ./install.sh /path/to/repo [--dry-run] [--force] [--prefix <id-prefix>] [--skip-bd-init]" >&2; exit 1; }
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
  # Prune Python bytecode caches: running the template's own tests in place
  # leaves __pycache__/ behind, and stale .pyc files must never be installed.
  cd "$TEMPLATE" && find . \( -name __pycache__ -o -name '*.pyc' -o -name '*.pyo' \) -prune -o -type f -print \
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
if [ "$SKIP_BD" = 1 ]; then
  echo "  SKIP      bd init (--skip-bd-init)"
elif [ -e "$TARGET/.beads" ]; then
  echo "  SKIP      bd init (.beads/ exists — leaving the tracker alone; harness-doctor.sh checks import.auto)"
elif [ "$DRY_RUN" = 1 ]; then
  echo "  would run bd init --non-interactive --role maintainer --skip-agents --prefix $PREFIX"
  echo "  would set import.auto: false in .beads/config.yaml and commit it"
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
  echo "           grep -rl '\\bmain\\b' .claude scripts CLAUDE.md"
  echo "           # review each hit, then substitute deliberately"
  echo
  echo "         See docs/customizing.md ('Default branch name') in the harness export."
fi

cat <<'NEXT'

install: next steps (see docs/getting-started.md for the full walkthrough)

  1. Install prerequisites:      jq, python3, (docker for diagram validation)
  2. Publish the tracker:        bd dolt push        (needs a git origin)
  3. Build the venv:             ./scripts/python-init.sh
  4. Check the install:          ./scripts/harness-doctor.sh
  5. Fill in the placeholders:   CLAUDE.md, docs/conventions.md, docs/design.md
  6. File your first ticket, then run /code

NEXT
