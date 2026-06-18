#!/usr/bin/env bash
#
# notify.sh — ntfy push. INTERVENTION ONLY.
# Call this ONLY when Trevor must personally do something (the deterministic layer
# AND the agent both failed, or git state is unexpected). Never for success, never
# as an event log. Silence is the normal outcome.
#
set -uo pipefail

TITLE="${1:?usage: notify.sh <title> <message>}"
MSG="${2:?usage: notify.sh <title> <message>}"
: "${NTFY_URL:?NTFY_URL must be set to the full topic URL, e.g. https://ntfy.sh/<topic>}"

if curl -fsS \
    -H "Title: ${TITLE}" \
    -H "Priority: high" \
    -H "Tags: warning,opencode-fork" \
    -d "${MSG}" \
    "${NTFY_URL}" >/dev/null; then
  echo "[ntfy] intervention ping sent: ${TITLE}"
else
  # If even ntfy fails we must not swallow it — surface loudly in the CI log.
  echo "::error::[ntfy] FAILED to deliver intervention ping. Check NTFY_URL secret." >&2
  exit 1
fi
