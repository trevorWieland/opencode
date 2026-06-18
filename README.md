# opencode fork — automation branch

This orphan branch holds **only** the daily-sync automation for the fork. It shares
no history with the code and is never rebased onto upstream. It is the fork's
default branch so GitHub's scheduled workflow runs from here.

## What it does (daily)
1. Fast-forward the pristine `dev` mirror from `anomalyco/opencode:dev`.
2. Rebase our patch stack (`patches/*`) onto fresh `dev` — **deterministically first**
   (`git rerere` replay + `--update-refs`), no AI.
3. If that lands clean and the gates pass → build + publish, silently.
4. If it conflicts or gates fail → run the GLM agent **once**, bundling the day's drift,
   under the invariants in `prompts/resolve-conflict.md`.
5. If the agent also fails → **ntfy** (the only notification; intervention required).

Success and self-healed days are silent. The job is fork-internal: it never pushes
the PR-bound `patches/*` branches and cannot reach upstream.

## Branch model (in the fork)
- `automation` — this branch (infra only; default branch).
- `dev` — pristine mirror of upstream dev (fast-forward only).
- `patches/*` — human-curated, PR-bound patch commits (source of truth for content).
- `personal` — disposable daily output = dev + stack; the binary is built from it.

## Files
- `scripts/sync-upstream.sh` — deterministic rebase + gates; exit 0/10/20/30.
- `scripts/agentic-resolve.sh` — once-daily GLM agent (resolve conflicts, fix gates).
- `scripts/configure-opencode-glm.sh` — auth the official `zai-coding-plan` provider.
- `scripts/build-and-release.sh` — `bun run build --single` → rolling `fork-latest` release.
- `scripts/notify.sh` — ntfy, intervention only.
- `prompts/resolve-conflict.md` — agent's standing context + the 4 invariants.
- `schemas/invariant-review.json` — structured-output schema for the publish-gate
  review (dogfoods the fork's `--output-schema` feature; activates once a `fork-latest`
  binary exists).
- `.github/workflows/sync.yml` — orchestration.

## Required fork settings (not stored here)
- Secret `ZAI_API_KEY` — Z.AI GLM key (used only at runtime; never committed).
- Secret `NTFY_URL` — full ntfy topic URL, e.g. `https://ntfy.sh/<topic>`.
- Variable `AGENT_MODEL` — optional; defaults to `zai-coding-plan/glm-5.2`.

## Consuming the build
The daily job publishes the compiled binary to the rolling `fork-latest` GitHub
Release. Download it (`gh release download fork-latest`) or point a small updater at it.
