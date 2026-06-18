#!/usr/bin/env bash
#
# configure-opencode-glm.sh — authenticate the (stable, globally-installed)
# opencode the agent layer uses against Z.AI's GLM, the OFFICIAL way: write the
# `zai-coding-plan` provider credential into opencode's auth.json, exactly as
# `opencode auth login` -> Z.AI would. The provider definition (baseURL, model
# list) comes from the models.dev registry automatically — no custom provider
# block needed. Use model string: zai-coding-plan/glm-5.2
#
# SECURITY: the key is taken from $ZAI_API_KEY (a GitHub secret) at runtime and
# written only to the ephemeral runner's auth.json (chmod 600). It is never
# committed, never echoed.
#
set -euo pipefail

: "${ZAI_API_KEY:?ZAI_API_KEY must be set in the environment (GitHub secret); never hardcode it}"
PROVIDER="${ZAI_PROVIDER_ID:-zai-coding-plan}"
AUTH_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
AUTH="$AUTH_DIR/auth.json"
mkdir -p "$AUTH_DIR"

# Merge into any existing auth.json rather than clobbering other providers.
python3 - "$AUTH" "$PROVIDER" <<'PY'
import json, os, sys
path, provider = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except Exception:
        data = {}
data[provider] = {"type": "api", "key": os.environ["ZAI_API_KEY"]}
json.dump(data, open(path, "w"), indent=2)
os.chmod(path, 0o600)
PY

echo "[glm] wrote '${PROVIDER}' credential to ${AUTH} (model: ${AGENT_MODEL:-zai-coding-plan/glm-5.2})"
echo "[glm] key sourced from \$ZAI_API_KEY; provider definition resolved from models.dev"
