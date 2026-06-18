# Standing context: why this fork exists and what must stay true

You are resolving a daily rebase of a small patch stack onto the fast-moving
upstream `anomalyco/opencode:dev`. You are running headless in CI. Your job is to
land the rebase **without weakening the fork's purpose**, then make the gates pass.

## Why the fork exists
Upstream supports JSON-schema structured output on the *server/SDK* but has not
merged (a) two bugs that make it crash/unreliable, and (b) a CLI surface for it.
This fork carries that small set of patches on top of upstream so the `opencode`
CLI can be used in `--output-schema` mode today, while we still work to upstream
each patch. The structured-output subsystem upstream moves location often
(`message-v2.ts` → `session/legacy.ts` → `core/src/v1/session.ts`, and a parallel
v2 runtime is being built). Expect our patches to land where the code has moved.

## The invariants — these MUST remain true after you resolve
1. **OutputFormat encodes from plain objects.** In the v1 session schema,
   `OutputFormatText` and `OutputFormatJsonSchema` are `Schema.Struct` (NOT
   `Schema.Class`), so encoding a plain DB row through `SessionV1.WithParts`
   (the `GET /session/:id/message` route) does not crash. (Upstream issue #26929.)
2. **retryCount is respected.** The structured-output run loop reads
   `format.retryCount` (default 2). On a structured-output miss it persists a
   synthetic `<system-reminder>` user message and retries the step with
   `toolChoice: "required"` still in force, and the final `StructuredOutputError`
   reports the real attempt count. (Upstream issue #25430.)
3. **The synthetic `StructuredOutput` tool is exempt from permission filtering**
   so structured output works under restrictive agent permissions. (Issue #23473.)
4. **`opencode run --output-schema <file|inline-json>`** passes
   `format: { type: "json_schema", schema, retryCount? }` to the prompt and prints
   ONLY the resulting structured JSON to stdout (suppressing the pretty render),
   mapping `StructuredOutputError` to a non-zero exit. (Issue #9320.)

## Resolution rules
- **Keep both sides' intent.** Prefer upstream's new structure; re-apply our
  change on top of it. Never delete upstream functionality to favor our patch.
- **Follow relocations.** If upstream moved/renamed a symbol our patch touches
  (file, namespace e.g. `SessionLegacy`→`SessionV1`, or an idiom e.g. a removed
  `slog`/`log` helper → `Effect.logError`), re-apply our change at the new home in
  the current idiom. Match surrounding code.
- **Never drop an invariant to make a conflict disappear.** If the only way to
  resolve cleanly would violate invariants 1–4, STOP and fail — a human decides.
- **If upstream already implemented one of our fixes** (e.g. converted the schemas
  to `Struct` themselves, or added retry handling), our commit for that fix is now
  redundant: let it rebase to empty / drop it, and say so clearly in your summary.
- **Gates must pass** when you're done: `bun run typecheck` (turbo), `bun run lint`,
  and `packages/opencode` → `bun test test/session/`. Note: a package-local
  `bun run typecheck` inside `packages/opencode` reports many *pre-existing*
  test-harness `Layer` errors that are NOT yours — judge by the turbo typecheck.

## Output
End with a short summary: which files you touched, how you re-applied each affected
invariant, and whether any patch became redundant and was dropped.
