#!/usr/bin/env bash
#
# Install the agent harness into a target git repository.
#
# Copies template/ into the target, never overwriting an existing file unless
# --force is given. Deliberately does NOT run `bd init`, create a venv, or touch
# git state — those are the steps a human should run and see, and they are
# walked through in docs/getting-started.md.
#
# Usage:
#   ./install.sh /path/to/repo [--dry-run] [--force]
#
# Exit codes: 0 ok, 1 usage/precondition failure, 2 machine fault.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
TEMPLATE="$HERE/template"

TARGET=""
DRY_RUN=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    -h|--help)
      sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) echo "install: unknown option '$arg'" >&2; exit 1 ;;
    *)
      [ -n "$TARGET" ] && { echo "install: more than one target given" >&2; exit 1; }
      TARGET="$arg"
      ;;
  esac
done

[ -n "$TARGET" ] || { echo "install: usage: ./install.sh /path/to/repo [--dry-run] [--force]" >&2; exit 1; }
[ -d "$TEMPLATE" ] || { echo "install: template/ not found beside this script" >&2; exit 2; }
[ -d "$TARGET" ]   || { echo "install: '$TARGET' is not a directory" >&2; exit 1; }

# A git repo is a hard precondition: the whole harness is worktree-based, and a
# half-installed harness in a non-repo is worse than no install at all.
git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "install: '$TARGET' is not a git repository. Run 'git init' there first." >&2
  exit 1
}

DEFAULT_BRANCH="$(git -C "$TARGET" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")"

echo "install: target      $TARGET"
echo "install: branch      ${DEFAULT_BRANCH:-<detached or unborn>}"
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
done < <(cd "$TEMPLATE" && find . -type f | sed 's#^\./##' | sort)

echo
echo "install: $copied new, $overwritten overwritten, $skipped skipped"

if [ "$DRY_RUN" = 1 ]; then
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
  echo "           grep -rl '\\bmain\\b' .claude scripts CLAUDE.md AGENTS.md"
  echo "           # review each hit, then substitute deliberately"
  echo
  echo "         See docs/customizing.md ('Default branch name') in the harness export."
fi

cat <<'NEXT'

install: next steps (see docs/getting-started.md for the full walkthrough)

  1. Install prerequisites:      bd, jq, python3, (docker for diagram validation)
  2. Initialise the tracker:     bd init && bd dolt push
  3. Turn off JSONL auto-import: set `import.auto: false` in .beads/config.yaml, and commit it
  4. Build the venv:             ./scripts/python-init.sh
  5. Check the install:          ./scripts/harness-doctor.sh
  6. Fill in the placeholders:   CLAUDE.md, docs/conventions.md, docs/design.md
  7. File your first ticket, then run /code

NEXT
