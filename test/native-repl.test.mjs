import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";

const [binary, runtime] = process.argv.slice(2);
assert.ok(binary, "native REPL binary path is required");
assert.ok(runtime, "runtime name is required");

const source = await readFile(new URL("./fixtures/repl.txt", import.meta.url), "utf8");
const expected = JSON.parse(
  await readFile(new URL("./fixtures/repl.expected.json", import.meta.url), "utf8"),
);
const result = spawnSync(binary, [], { input: source, encoding: "utf8" });

assert.equal(result.status, 0, result.stderr);
assert.deepEqual(
  result.stdout.trim().split("\n"),
  expected.map(({ status, values = [], code }) =>
    [status, ...values, ...(code === undefined ? [] : [code])].join(" "),
  ),
);
console.log(`${runtime} REPL tests passed`);
