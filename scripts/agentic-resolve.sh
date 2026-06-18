#!/usr/bin/env bash
#
# agentic-resolve.sh — the ONCE-PER-DAY agentic layer. Runs only when the
# deterministic sync (sync-upstream.sh) returned 10 (unresolved conflicts) or
# 20 (clean rebase but gates failed). It drives `opencode` (powered by the GLM
# key) to (1) finish any in-progress rebase by resolving conflicts, then (2) make
# the gates pass — all under the standing context in prompts/resolve-conflict.md.
#
# Operates on whatever branch sync-upstream.sh left checked out (sync/attempt-*).
# On success advances `personal` and exits 0 (caller publishes). On failure exits
# 1 (caller sends the single ntfy intervention ping).
#
set -uo pipefail

MODEL="${AGENT_MODEL:?AGENT_MODEL must be set (e.g. the GLM model id)}"
PROMPT_FILE="${PROMPT_FILE:-prompts/resolve-conflict.md}"
PERSONAL="${PERSONAL:-personal}"
MAX_ROUNDS="${MAX_ROUNDS:-6}"
OPENCODE_TIMEOUT="${OPENCODE_TIMEOUT:-900}"  # cap a single agent call; GLM can lag

[ -f "$PROMPT_FILE" ] || { echo "missing $PROMPT_FILE" >&2; exit 1; }
ctx() { cat "$PROMPT_FILE"; }
markers() { grep -rlE '^(<<<<<<<|=======|>>>>>>>)' --include='*.ts' --include='*.tsx' . 2>/dev/null; }
# One bounded agent call. A hung/slow model fails the round instead of the job.
oc() { timeout "$OPENCODE_TIMEOUT" opencode run --model "$MODEL" "$1"; }

# --- Phase 1: drive the in-progress rebase to completion ---------------------
round=0
while [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; do
  round=$((round + 1))
  [ "$round" -gt "$MAX_ROUNDS" ] && { echo "agent: exceeded $MAX_ROUNDS rebase rounds" >&2; exit 1; }

  conflicts="$(git diff --name-only --diff-filter=U)"
  if [ -z "$conflicts" ]; then
    git -c core.editor=true rebase --continue >/dev/null 2>&1 || { echo "agent: rebase --continue failed" >&2; exit 1; }
    continue
  fi

  echo "agent: resolving conflicts (round $round): $conflicts"
  task="$(ctx)

## Current task: resolve a rebase conflict
You are mid-rebase, replaying our patch onto upstream. These files have conflict
markers — edit each to remove EVERY <<<<<<< / ======= / >>>>>>> marker, keeping
both upstream's intent and our invariants:

${conflicts}

Do not run git. Just leave each file in its correct final state."
  oc "$task" || { echo "agent: opencode invocation failed/timed out" >&2; exit 1; }

  if [ -n "$(markers)" ]; then
    echo "agent: conflict markers still present after resolution attempt" >&2
    exit 1
  fi
  git add -A
  git -c core.editor=true rebase --continue >/dev/null 2>&1 || { echo "agent: rebase --continue failed post-resolve" >&2; exit 1; }
done

# --- Phase 2: make the gates pass --------------------------------------------
gate() {
  bun run typecheck >/dev/null 2>&1 \
    && bun run lint >/dev/null 2>&1 \
    && ( cd packages/opencode && bun test test/session/ ) >/dev/null 2>&1
}

round=0
until gate; do
  round=$((round + 1))
  [ "$round" -gt "$MAX_ROUNDS" ] && { echo "agent: gates still failing after $MAX_ROUNDS rounds" >&2; exit 1; }
  echo "agent: repairing failing gates (round $round)"
  task="$(ctx)

## Current task: repair failing gates
The rebase landed but the gates fail (turbo typecheck, lint, or packages/opencode
session tests). Investigate and fix the code so ALL gates pass, without weakening
any invariant or deleting upstream functionality. Make the minimal correct change."
  oc "$task" || { echo "agent: opencode invocation failed/timed out" >&2; exit 1; }
  git add -A
  git commit -m "fix: agentic post-rebase repair (round $round)" >/dev/null 2>&1 || true
done

git branch -f "$PERSONAL" HEAD
echo "agent: resolved and gates green; $PERSONAL -> $(git rev-parse --short HEAD)"
exit 0
