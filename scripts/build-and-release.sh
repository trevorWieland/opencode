#!/usr/bin/env bash
#
# build-and-release.sh — compile the fork's `personal` build into a single native
# binary and publish it to a rolling GitHub Release on the fork. Called only after
# a successful sync (deterministic or agent). Requires GH_TOKEN (GITHUB_TOKEN in CI).
#
set -euo pipefail

TAG="${RELEASE_TAG:-fork-latest}"
ASSET="${ASSET_NAME:-opencode-linux-x64}"
# Pin the release to THIS fork. `gh` resolves a fork's default repo to its parent
# (anomalyco/opencode), so every gh call must target the fork explicitly — both to
# work and as a hard guard against ever touching upstream.
REPO="${GH_REPO:-${GITHUB_REPOSITORY:-trevorWieland/opencode}}"
case "$REPO" in
  */opencode) ;;
  *) echo "[release] refusing: unexpected repo '$REPO'" >&2; exit 1 ;;
esac
case "$REPO" in
  anomalyco/*) echo "[release] refusing to release to upstream '$REPO'" >&2; exit 1 ;;
esac
echo "[release] target repo: $REPO"

echo "[release] building single native binary"
( cd packages/opencode && bun run build --single )

BIN="$(ls packages/opencode/dist/*/bin/opencode 2>/dev/null | head -1 || true)"
[ -n "$BIN" ] || { echo "[release] no binary produced under packages/opencode/dist/*/bin/" >&2; exit 1; }
TARBALL="$(ls packages/opencode/dist/*.tar.gz 2>/dev/null | head -1 || true)"

cp "$BIN" "./$ASSET"
UPSTREAM_SHA="$(git rev-parse --short "${MIRROR:-dev}")"
PERSONAL_SHA="$(git rev-parse --short "${PERSONAL:-personal}")"

# Rolling release: create once, then clobber assets each day.
if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release create "$TAG" --repo "$REPO" \
    --title "opencode fork — rolling build" \
    --notes "Auto-built from \`personal\` = upstream dev + structured-output patch stack." \
    --prerelease
fi

gh release upload "$TAG" "./$ASSET" --repo "$REPO" --clobber
[ -n "$TARBALL" ] && gh release upload "$TAG" "$TARBALL" --repo "$REPO" --clobber || true

gh release edit "$TAG" --repo "$REPO" --notes "Auto-built $(date -u +%Y-%m-%dT%H:%MZ)
- personal: ${PERSONAL_SHA}
- upstream dev: ${UPSTREAM_SHA}"

echo "[release] published $ASSET to '$TAG' on $REPO (personal ${PERSONAL_SHA} on upstream ${UPSTREAM_SHA})"
