#!/usr/bin/env bash
# Rebase the fork branch onto a newer upstream stable tag, regenerate the
# generated API schema artifact, run checks, and tag the result as
# <branch>-<upstream-tag>. Fork-only tooling; upstream never runs this.
set -euo pipefail

SCHEMA_PATH="docs/next/api/herdr-api.schema.json"
SCHEMA_TEST="generated_protocol_schema_artifact_is_current"
DEFAULT_CHECK_RECIPES="ci docs-contract-test"

usage() {
  cat <<'USAGE'
usage: scripts/fork/sync-upstream.sh [options] [<upstream-tag>]

Rebase the current fork branch onto <upstream-tag> (default: the newest v*
tag on the upstream remote), regenerate the API schema artifact, run checks,
and create an annotated <branch>-<upstream-tag> tag.

options:
  --branch <name>     fork branch that must be checked out (default: current branch)
  --continue          resume after resolving rebase conflicts by hand
  --check <recipes>   just recipes to run, space separated (default: "ci docs-contract-test")
  --skip-check        run no just recipes
  --no-tag            do not create the fork tag
  --push              push the branch (--force-with-lease) and the fork tag to origin
  --dry-run           print the plan and exit before changing anything
  -h, --help          show this help

Conflict handling: a conflict limited to the generated schema artifact is
resolved automatically (upstream copy, then regeneration). Any other conflict
stops the script; resolve it, `git add` the files, and rerun with --continue.
USAGE
}

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

BRANCH=""
CONTINUE=false
CHECK_RECIPES="$DEFAULT_CHECK_RECIPES"
CREATE_TAG=true
PUSH=false
DRY_RUN=false
NEW_TAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) [[ $# -ge 2 ]] || die "--branch needs a value"; BRANCH="$2"; shift 2 ;;
    --continue) CONTINUE=true; shift ;;
    --check) [[ $# -ge 2 ]] || die "--check needs a value"; CHECK_RECIPES="$2"; shift 2 ;;
    --skip-check) CHECK_RECIPES=""; shift ;;
    --no-tag) CREATE_TAG=false; shift ;;
    --push) PUSH=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) [[ -z "$NEW_TAG" ]] || die "unexpected argument: $1"; NEW_TAG="$1"; shift ;;
  esac
done

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
STATE_FILE="$(git rev-parse --git-dir)/herdr-fork-sync.state"

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required${2:-}"
}

check_toolchain() {
  local hint=" (run: mise trust && mise install)"
  require_tool git
  require_tool cargo
  require_tool just "$hint"
  require_tool zig "$hint"
  cargo nextest --version >/dev/null 2>&1 || die "cargo-nextest is required$hint"
  local required actual
  required="$(grep -oE 'requires Zig [0-9]+\.[0-9]+\.[0-9]+' crates/ghostty-vt/build.rs | head -1 | awk '{print $3}' || true)"
  if [[ -n "$required" ]]; then
    actual="$(zig version)"
    [[ "$actual" == "$required" ]] || die "zig $required is required by crates/ghostty-vt, found $actual"
  fi
}

rebase_in_progress() {
  local git_dir
  git_dir="$(git rev-parse --git-dir)"
  [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]]
}

conflicted_files() {
  git diff --name-only --diff-filter=U
}

regenerate_schema() {
  log "regenerating $SCHEMA_PATH"
  HERDR_UPDATE_API_SCHEMA=1 just test-one "$SCHEMA_TEST"
}

save_state() {
  printf 'NEW_TAG=%q\nOLD_BASE=%q\nBRANCH=%q\n' "$NEW_TAG" "$OLD_BASE" "$BRANCH" > "$STATE_FILE"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "no sync in progress (missing $STATE_FILE)"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

stop_for_manual_resolution() {
  save_state
  {
    echo "conflicts need manual resolution:"
    printf '  %s\n' "$@"
    echo
    echo "During a rebase, --ours is the upstream side and --theirs is the fork commit."
    echo "Leave $SCHEMA_PATH alone; the script regenerates it. Then run:"
    echo "  git add <resolved files>"
    echo "  scripts/fork/sync-upstream.sh --continue"
  } >&2
  exit 2
}

# Walks the rebase until it finishes. Schema-only conflicts take the upstream
# copy because the file is generated; everything else stops for a human.
drive_rebase() {
  local conflicts
  while rebase_in_progress; do
    conflicts="$(conflicted_files)"
    if [[ "$conflicts" == "$SCHEMA_PATH" ]]; then
      log "schema conflict: taking the upstream copy, regeneration follows"
      git checkout --ours -- "$SCHEMA_PATH"
      git add -- "$SCHEMA_PATH"
    elif [[ -n "$conflicts" ]]; then
      # shellcheck disable=SC2086
      stop_for_manual_resolution $conflicts
    fi
    if git diff --cached --name-only | grep -qxF "$SCHEMA_PATH"; then
      regenerate_schema
      git add -- "$SCHEMA_PATH"
    fi
    if ! GIT_EDITOR=true git rebase --continue; then
      [[ -n "$(conflicted_files)" ]] || die "git rebase --continue failed without conflicts; inspect git status"
    fi
  done
}

# After the rebase, a clean three-way merge can still leave the artifact stale.
# Fold a fresh copy into the newest fork commit that owns the file.
finalize_schema() {
  regenerate_schema
  if git diff --quiet -- "$SCHEMA_PATH"; then
    log "schema artifact is current"
    return
  fi
  local owner
  owner="$(git log -1 --format=%H "$NEW_TAG..HEAD" -- "$SCHEMA_PATH" || true)"
  [[ -n "$owner" ]] || owner="$(git rev-parse HEAD)"
  log "folding regenerated schema into $(git log -1 --format='%h %s' "$owner")"
  git commit --quiet --fixup="$owner" -- "$SCHEMA_PATH"
  GIT_SEQUENCE_EDITOR=true GIT_EDITOR=true git rebase -i --autosquash "$NEW_TAG"
}

run_checks() {
  if [[ -z "$CHECK_RECIPES" ]]; then
    log "skipping checks"
    return
  fi
  local recipe
  for recipe in $CHECK_RECIPES; do
    log "just $recipe"
    just "$recipe"
  done
}

create_fork_tag() {
  FORK_TAG="${BRANCH}-${NEW_TAG}"
  if git rev-parse -q --verify "refs/tags/$FORK_TAG" >/dev/null; then
    die "tag $FORK_TAG already exists; delete it first to recreate it"
  fi
  local message
  message="$(mktemp)"
  {
    echo "$FORK_TAG"
    echo
    echo "Base: $NEW_TAG"
    echo "Branch: $BRANCH"
    echo "Fork-Commits:"
    git log --reverse --format='- %h %s' "$NEW_TAG..HEAD"
  } > "$message"
  git tag -a -F "$message" "$FORK_TAG"
  rm -f "$message"
  log "created tag $FORK_TAG"
}

if $CONTINUE; then
  rebase_in_progress || die "no rebase in progress; nothing to continue"
  load_state
  head_name="$(cat "$(git rev-parse --git-dir)/rebase-merge/head-name" 2>/dev/null || true)"
  [[ "$head_name" == "refs/heads/$BRANCH" ]] || die "the rebase in progress is not for $BRANCH"
  check_toolchain
  drive_rebase
else
  ! rebase_in_progress || die "a rebase is already in progress; finish it or rerun with --continue"
  [[ -z "$(git status --porcelain)" ]] || die "working tree is not clean"
  current="$(git symbolic-ref --short -q HEAD || true)"
  [[ -n "$current" ]] || die "HEAD is detached; check out the fork branch first"
  BRANCH="${BRANCH:-$current}"
  [[ "$BRANCH" == "$current" ]] || die "check out $BRANCH first (current branch: $current)"
  git remote get-url upstream >/dev/null 2>&1 || die "remote 'upstream' is missing"

  log "fetching upstream tags"
  git fetch --prune --tags upstream

  OLD_BASE="$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$BRANCH")"
  if [[ -z "$NEW_TAG" ]]; then
    NEW_TAG="$(git tag --list 'v[0-9]*' --sort=-v:refname | head -1)"
  fi
  git rev-parse -q --verify "refs/tags/$NEW_TAG^{commit}" >/dev/null || die "unknown upstream tag: $NEW_TAG"

  log "branch $BRANCH is based on $OLD_BASE; target is $NEW_TAG"
  log "fork commits:"
  git log --reverse --format='    %h %s' "$OLD_BASE..$BRANCH"
  if $DRY_RUN; then
    if [[ "$OLD_BASE" == "$NEW_TAG" ]]; then
      log "dry run: already based on $NEW_TAG; would only regenerate, check, and tag"
    else
      log "dry run: would run git rebase --onto $NEW_TAG $OLD_BASE $BRANCH"
    fi
    exit 0
  fi

  check_toolchain
  if [[ "$OLD_BASE" == "$NEW_TAG" ]]; then
    log "already based on $NEW_TAG; skipping rebase"
  else
    save_state
    if ! git -c rerere.enabled=true rebase --onto "$NEW_TAG" "$OLD_BASE" "$BRANCH"; then
      drive_rebase
    fi
  fi
fi

rm -f "$STATE_FILE"
finalize_schema
run_checks

FORK_TAG=""
if $CREATE_TAG; then
  create_fork_tag
fi

if $PUSH; then
  log "pushing $BRANCH and ${FORK_TAG:-no tag} to origin"
  git push --force-with-lease origin "$BRANCH"
  [[ -z "$FORK_TAG" ]] || git push origin "refs/tags/$FORK_TAG"
fi

log "done: $BRANCH is $(git rev-parse --short HEAD) on $NEW_TAG"
previous_fork_tag="${BRANCH}-${OLD_BASE}"
if [[ "$OLD_BASE" != "$NEW_TAG" ]] && git rev-parse -q --verify "refs/tags/$previous_fork_tag" >/dev/null; then
  echo "review the patch drift with:"
  echo "  git range-diff $OLD_BASE..$previous_fork_tag $NEW_TAG..$BRANCH"
fi
if ! $PUSH; then
  echo "publish with:"
  echo "  git push --force-with-lease origin $BRANCH"
  [[ -z "$FORK_TAG" ]] || echo "  git push origin refs/tags/$FORK_TAG"
fi
