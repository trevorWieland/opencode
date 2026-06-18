#!/usr/bin/env bash
#
# sync-upstream.sh — deterministic daily rebase of the fork's patch stack onto
# upstream dev. This is the "git resolution" layer: it tries hard to land the
# rebase WITHOUT any AI, using git rerere (replays previously-recorded conflict
# resolutions) + --update-refs (rebases the whole stack in one pass).
#
# It is FORK-INTERNAL ONLY. It never pushes the PR-bound patches/* branches and
# never touches the upstream remote. Its product is the disposable `personal`
# branch (what the binary is built from).
#
# Contract — the caller (CI) branches on the exit code:
#   0   clean (or rerere-resolved) rebase AND gates green -> caller publishes
#   10  rebase has unresolved conflicts          -> caller runs the agent
#   20  rebase clean but gates (typecheck/test) failed -> caller runs the agent
#   30  upstream rewrote dev history (non-ff) / unexpected git state -> caller escalates (ntfy)
#
# On 10/20 the half-done state is left on `sync/attempt-<date>` for the agent or
# a human to pick up; `personal` is NOT moved, so the last good build is retained.
#
set -uo pipefail

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/anomalyco/opencode.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-dev}"
MIRROR="${MIRROR:-dev}"                       # pristine local mirror of upstream
STACK_TOP="${STACK_TOP:-patches/output-schema-cli}"  # tip of the patch stack
PERSONAL="${PERSONAL:-personal}"              # disposable build branch
RERERE_DIR="${RERERE_DIR:-}"                  # optional persisted rerere cache path
ATTEMPT="sync/attempt-${SYNC_DATE:-manual}"

log() { printf '\033[36m[sync]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[sync] %s\033[0m\n' "$*" >&2; exit "${2:-1}"; }

# --- deterministic conflict reuse -------------------------------------------
git config rerere.enabled true
git config rerere.autoupdate true
# A persisted cache (committed on the automation branch / restored from CI cache)
# lets resolutions survive across runs and be reused when rebasing the PR branch.
if [ -n "$RERERE_DIR" ] && [ -d "$RERERE_DIR" ]; then
  mkdir -p .git/rr-cache
  cp -a "$RERERE_DIR/." .git/rr-cache/ 2>/dev/null || true
  log "loaded rerere cache from $RERERE_DIR"
fi

# --- fetch upstream ----------------------------------------------------------
git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1 || git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
log "fetching $UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
git fetch --quiet "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH" || die "fetch failed" 30

# --- fast-forward the pristine mirror ---------------------------------------
# A non-ff here means upstream rewrote dev history — never auto-resolve that.
git show-ref --verify --quiet "refs/heads/$MIRROR" || git branch "$MIRROR" "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
git checkout --quiet "$MIRROR"
if ! git merge --ff-only --quiet "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"; then
  die "upstream/$UPSTREAM_BRANCH is not a fast-forward of local $MIRROR (history rewrite?)" 30
fi
UPSTREAM_SHA="$(git rev-parse --short "$MIRROR")"
log "mirror $MIRROR at $UPSTREAM_SHA"

# --- rebase the whole stack onto fresh dev ----------------------------------
git checkout --quiet -B "$ATTEMPT" "$STACK_TOP"
log "rebasing stack ($STACK_TOP) onto $MIRROR with rerere + --update-refs"
if git rebase --update-refs --rerere-autoupdate "$MIRROR"; then
  REBASE_OK=1
else
  # rerere.autoupdate may have staged resolutions mid-stop; try to continue while
  # there are no remaining unmerged paths, so fully-recorded conflicts self-heal.
  while [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; do
    if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
      REBASE_OK=0; break
    fi
    git -c core.editor=true rebase --continue >/dev/null 2>&1 || { REBASE_OK=0; break; }
    REBASE_OK=1
  done
fi

# persist any newly-recorded resolutions back out for reuse
if [ -n "$RERERE_DIR" ] && [ -d .git/rr-cache ]; then
  mkdir -p "$RERERE_DIR"; cp -a .git/rr-cache/. "$RERERE_DIR/" 2>/dev/null || true
fi

if [ "${REBASE_OK:-0}" != "1" ]; then
  log "unresolved conflicts in: $(git diff --name-only --diff-filter=U | tr '\n' ' ')"
  # leave the conflicted state in place on $ATTEMPT for the agent to resume
  exit 10
fi
log "rebase clean -> $ATTEMPT at $(git rev-parse --short HEAD)"

# --- gates (CI-equivalent scope, NOT the test-polluted package typecheck) ----
run_gates() {
  log "gate: typecheck (turbo)"; bun run typecheck >/dev/null 2>&1 || return 1
  log "gate: lint";              bun run lint      >/dev/null 2>&1 || return 1
  log "gate: session tests";     ( cd packages/opencode && bun test test/session/ ) >/dev/null 2>&1 || return 1
  return 0
}
if [ "${SKIP_GATES:-0}" = "1" ]; then
  log "SKIP_GATES=1 -> skipping typecheck/lint/test gates"
elif ! run_gates; then
  log "gates failed on a clean rebase (upstream behaviour change, not a conflict)"
  exit 20
fi

# --- success: advance personal (caller publishes) ----------------------------
git branch -f "$PERSONAL" "$ATTEMPT"
git branch -D "$ATTEMPT" 2>/dev/null || true
log "OK: $PERSONAL -> $(git rev-parse --short "$PERSONAL") (on upstream $UPSTREAM_SHA)"
exit 0
