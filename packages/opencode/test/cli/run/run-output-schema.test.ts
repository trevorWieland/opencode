// Subprocess integration tests for `opencode run --output-schema`.
// These exercise the structured-output CLI wiring end-to-end against a
// TestLLMServer: the model is scripted to call (or never call) the
// `StructuredOutput` tool, and we assert the CLI's stdout/stderr/exit-code
// contract. See `test/lib/cli-process.ts` for the harness.
import { describe, expect } from "bun:test"
import { Effect } from "effect"
import path from "node:path"
import { cliIt } from "../../lib/cli-process"

const ANSWER_SCHEMA = JSON.stringify({
  type: "object",
  properties: { answer: { type: "number" } },
  required: ["answer"],
})

describe("opencode run --output-schema (subprocess)", () => {
  // Happy path: the model calls StructuredOutput; stdout is ONLY the compact
  // JSON result (no banner, no agent line), and the process exits 0.
  cliIt.concurrent(
    "inline schema: emits compact JSON to stdout and exits 0",
    ({ llm, opencode }) =>
      Effect.gen(function* () {
        yield* llm.tool("StructuredOutput", { answer: 4 })
        const result = yield* opencode.run("what is 2+2", { outputSchema: ANSWER_SCHEMA })
        opencode.expectExit(result, 0)

        expect(JSON.parse(result.stdout.trim())).toEqual({ answer: 4 })
        // stdout must be cleanly pipeable: exactly the JSON, no banner/agent line.
        const lines = result.stdout.split("\n").filter((l) => l.trim().length > 0)
        expect(lines).toEqual([JSON.stringify({ answer: 4 })])
        expect(result.stdout).not.toContain("·")
      }),
    60_000,
  )

  // Schema sourced from a file path (not inline JSON).
  cliIt.concurrent(
    "schema from a file path: same result",
    ({ llm, opencode, home }) =>
      Effect.gen(function* () {
        const schemaPath = path.join(home, "schema.json")
        yield* Effect.promise(() => Bun.write(schemaPath, ANSWER_SCHEMA))
        yield* llm.tool("StructuredOutput", { answer: 7 })
        const result = yield* opencode.run("what is 3+4", { outputSchema: schemaPath })
        opencode.expectExit(result, 0)
        expect(JSON.parse(result.stdout.trim())).toEqual({ answer: 7 })
      }),
    60_000,
  )

  // Failure: the model never calls the tool and retries are exhausted (0).
  // Exit nonzero, stdout empty (no partial JSON), stderr mentions the failure.
  cliIt.concurrent(
    "structured-output failure: nonzero exit, empty stdout, stderr message",
    ({ llm, opencode }) =>
      Effect.gen(function* () {
        // No StructuredOutput tool call — the model just emits plain text.
        // With 0 retries this forces a StructuredOutputError on the message.
        yield* llm.text("I refuse to use the tool")
        yield* llm.text("still refusing")
        const result = yield* opencode.run("answer", {
          outputSchema: ANSWER_SCHEMA,
          outputSchemaRetries: 0,
          timeoutMs: 30_000,
        })
        expect(result.exitCode).not.toBe(0)
        expect(result.stdout.trim()).toBe("")
        expect(result.stderr.toLowerCase()).toContain("structured output")
      }),
    60_000,
  )

  // --output-schema composes with --format json: it must NOT error. The
  // structured result rides the event stream; stdout stays line-delimited JSON.
  cliIt.concurrent(
    "--output-schema with --format json does not error",
    ({ llm, opencode }) =>
      Effect.gen(function* () {
        yield* llm.tool("StructuredOutput", { answer: 9 })
        const result = yield* opencode.run("compose", { outputSchema: ANSWER_SCHEMA, format: "json" })
        opencode.expectExit(result, 0)
        const events = opencode.parseJsonEvents(result.stdout)
        expect(events.length).toBeGreaterThan(0)
      }),
    60_000,
  )

  // Conflict: --output-schema + --interactive is rejected before any prompt.
  cliIt.concurrent(
    "--output-schema with --interactive is rejected",
    ({ opencode }) =>
      Effect.gen(function* () {
        const result = yield* opencode.run("hi", {
          outputSchema: ANSWER_SCHEMA,
          extraArgs: ["--interactive"],
          timeoutMs: 15_000,
        })
        expect(result.exitCode).not.toBe(0)
        expect(result.stderr.toLowerCase()).toContain("--output-schema")
      }),
    30_000,
  )

  // Conflict: --output-schema + --command is rejected.
  cliIt.concurrent(
    "--output-schema with --command is rejected",
    ({ opencode }) =>
      Effect.gen(function* () {
        const result = yield* opencode.run("args", {
          outputSchema: ANSWER_SCHEMA,
          command: "somecmd",
          timeoutMs: 15_000,
        })
        expect(result.exitCode).not.toBe(0)
        expect(result.stderr.toLowerCase()).toContain("--output-schema")
      }),
    30_000,
  )

  // Invalid schema JSON is rejected with a clear message.
  cliIt.concurrent(
    "invalid --output-schema JSON is rejected",
    ({ opencode }) =>
      Effect.gen(function* () {
        const result = yield* opencode.run("hi", {
          outputSchema: "{ not valid json",
          timeoutMs: 15_000,
        })
        expect(result.exitCode).not.toBe(0)
        expect(result.stderr.toLowerCase()).toContain("invalid json")
      }),
    30_000,
  )

  // A schema file that parses but is not a plain object is rejected. (Inline
  // values only count when they start with `{`, so a non-object schema can
  // only arrive via a file path.)
  cliIt.concurrent(
    "non-object schema file is rejected",
    ({ opencode, home }) =>
      Effect.gen(function* () {
        const schemaPath = path.join(home, "array-schema.json")
        yield* Effect.promise(() => Bun.write(schemaPath, "[1, 2, 3]"))
        const result = yield* opencode.run("hi", {
          outputSchema: schemaPath,
          timeoutMs: 15_000,
        })
        expect(result.exitCode).not.toBe(0)
        expect(result.stderr).toContain("--output-schema must be a JSON object")
      }),
    30_000,
  )
})
