import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { ReplSession } from "../browser/repl.mjs";

const compilerBytes = await readFile(new URL("../build/compiler.wasm", import.meta.url));
const { instance: compiler } = await WebAssembly.instantiate(compilerBytes);
const { table } = compiler.exports;
const repl = new ReplSession(compiler);
const replSource = await readFile(new URL("./fixtures/repl.txt", import.meta.url), "utf8");
const replExpected = JSON.parse(
  await readFile(new URL("./fixtures/repl.expected.json", import.meta.url), "utf8"),
);

const decoder = new TextDecoder("utf-8", { fatal: true });

function decodeError(bytes) {
  return decoder.decode(bytes);
}

function replChunks(text) {
  return text.split(/\r?\n/).filter((line) => line.trim());
}

async function compileSource(text) {
  repl.reset();
  return compileIncrement(text);
}

async function compileIncrement(text) {
  const result = await repl.submit(text);
  for (const { bytes } of result.installations) {
    assert.equal(WebAssembly.validate(bytes), true);
  }
  return {
    status: result.response[0],
    payload: result.response[1],
    length: result.response[2],
    bytes: result.payloadBytes,
    spanOffset: result.spanOffset,
    spanLength: result.spanLength,
    instances: result.installations.map(({ instance }) => instance),
    modules: result.installations.map(({ bytes }) => bytes),
    execution: result.execution,
  };
}

{
  const result = await compileSource(": answer ( -- i32 ) 40 2 i32.add ; export answer");
  assert.equal(result.status, 0);
  assert.equal(result.payload, 0);
  assert.equal(result.length, 0);
  assert.equal(result.modules.length, 1);
  assert.equal(result.instances[0].exports.answer(), 42);
}

{
  const result = await compileSource(
    ": forty ( -- i32 ) 40 ; : answer ( -- i32 ) forty 2 i32.add ; export answer",
  );
  assert.equal(result.status, 0);
  assert.equal(result.modules.length, 2, "one module must be emitted per semicolon");
  assert.equal(result.instances[0].exports.forty(), 40);
  assert.equal(result.instances[1].exports.answer(), 42);
}

{
  const result = await compileSource(
    ": binary-add ( i32 i32 -- i32 ) i32.add ; : pair ( i32 i32 -- i32 i32 ) 0 i32.add ;",
  );
  assert.equal(result.status, 0);
  assert.equal(result.instances[0].exports["binary-add"](20, 22), 42);
  assert.deepEqual(result.instances[1].exports.pair(4, 5), [4, 5]);
}

{
  const result = await compileSource(
    ": sum ( i32 i32 -- i32 ) add ; " +
    ": twice ( i32 -- i32 ) local x i32 !x @x @x add ; " +
    ": replace ( i32 i32 -- i32 ) local replacement i32 local value i32 !replacement !value @replacement !value @value ; " +
    ": zero-local ( -- i32 ) local x i32 @x ; " +
    ": tee-local ( i32 -- i32 i32 ) local x i32 !@x @x ;",
  );
  assert.equal(result.status, 0);
  assert.equal(result.instances[0].exports.sum(20, 22), 42);
  assert.equal(result.instances[1].exports.twice(21), 42);
  assert.equal(result.instances[2].exports.replace(10, 42), 42);
  assert.equal(result.instances[3].exports["zero-local"](), 0);
  assert.deepEqual(result.instances[4].exports["tee-local"](42), [42, 42]);
  assert.equal(typeof table.get(0), "function", "generated modules must not overwrite compiler actions");
  assert.equal(typeof table.get(16), "function", "runtime definitions start after reserved action slots");
}

{
  const result = await compileSource(": limits ( -- i32 i32 ) -2147483648 2147483647 ;");
  assert.equal(result.status, 0);
  assert.deepEqual(result.instances[0].exports.limits(), [-2147483648, 2147483647]);
}

{
  const result = await compileSource("1 2 add");
  assert.equal(result.status, 2);
  assert.equal(result.length, 1);
  assert.equal(result.execution.value, 3);
  assert.equal(table.get(result.payload)(), 3);
}

{
  const result = await compileSource(": sum ( i32 i32 -- i32 ) add ; 20 22 sum");
  assert.equal(result.status, 2);
  assert.equal(result.instances.length, 2);
  assert.equal(result.execution.value, 42);
  assert.equal(table.get(result.payload)(), 42);
}

{
  repl.reset();
  const chunks = replChunks(replSource);
  assert.equal(chunks.length, replExpected.length);
  for (const [index, source] of chunks.entries()) {
    const result = await compileIncrement(source);
    const expected = replExpected[index];
    if (expected.status === "READY") {
      assert.equal(result.status, 0, source);
    } else if (expected.status === "RUN") {
      assert.equal(result.status, 2, source);
      const values = Array.isArray(result.execution.value)
        ? result.execution.value
        : [result.execution.value];
      assert.deepEqual(values, expected.values, source);
    } else {
      assert.equal(result.status, 3, source);
      assert.equal(decodeError(result.bytes), expected.message, source);
    }
  }
}

{
  const result = await compileSource(": recurse ( i32 -- i32 ) recurse ;");
  assert.equal(result.status, 0, "a definition must see its reserved slot and type");
  assert.equal(result.modules.length, 1);
}

const failures = [
  [": bad ( -- i32 ) 1 i32.add ;", "type stack underflow: `i32.add`", "i32.add"],
  [": bad ( -- i32 i32 ) 1 ;", "definition result does not match signature: `;`", ";"],
  [": bad ( -- i32 ) ;", "empty definition: `;`", ";"],
  [": bad ( -- i32 ) 2147483648 ;", "integer literal out of i32 range: `2147483648`", "2147483648"],
  [": outer ( -- i32 ) : inner ( -- i32 ) 1 ; ;", "nested definition: `:`", ":"],
  [": bad ( -- i32 ) missing ;", "unknown name: `missing`", "missing"],
  [": bad ( -- i32 ) míssing ;", "unknown name: `míssing`", "míssing"],
  ["export missing", "unknown export: `missing`", "missing"],
  [": unfinished ( -- i32 ) 1", "unexpected token or end of input", ""],
  [": bad ( f32 -- i32 ) 1 ;", "unsupported signature type: `f32`", "f32"],
  [": bad ( -- i32 ) local x f32 ;", "unsupported signature type: `f32`", "f32"],
  [": bad ( -- i32 ) local x i32 !x @x ;", "type stack underflow: `!x`", "!x"],
  [": bad ( i32 -- i32 ) local x i32 local x i32 @x ;", "duplicate or reserved local name: `x`", "x"],
  [": bad ( i32 -- i32 ) !missing ;", "unknown local name: `!missing`", "!missing"],
  [": bad ( i32 -- i32 ) @missing ;", "unknown local name: `@missing`", "@missing"],
  [": bad ( i32 -- i32 ) local x i32 x ;", "local name requires @, !, or !@: `x`", "x"],
  [": add ( i32 i32 -- i32 ) i32.add ;", "duplicate definition: `add`", "add"],
  [": first ( i32 -- i32 ) local x i32 !x @x ; : second ( -- i32 ) @x ;", "unknown local name: `@x`", "@x"],
];

const encoder = new TextEncoder();

for (const [source, message, expectedToken] of failures) {
  const result = await compileSource(source);
  assert.equal(result.status, 3, source);
  assert.equal(decodeError(result.bytes), message, source);
  if (expectedToken) {
    const sourceBytes = encoder.encode(source);
    const token = decoder.decode(
      sourceBytes.slice(result.spanOffset, result.spanOffset + result.spanLength),
    );
    assert.equal(token, expectedToken, `span should cover "${expectedToken}" in: ${source}`);
  }
}

{
  repl.reset();
  const forty = await compileIncrement(": forty ( -- i32 ) 40 ;");
  const answer = await compileIncrement(": answer ( -- i32 ) forty 2 i32.add ;");
  assert.equal(forty.status, 0);
  assert.equal(answer.status, 0);
  assert.equal(answer.instances[0].exports.answer(), 42);

  const failed = await compileIncrement(": retry ( -- i32 ) missing ;");
  const retried = await compileIncrement(": retry ( -- i32 ) answer ;");
  assert.equal(failed.status, 3);
  assert.equal(decodeError(failed.bytes), "unknown name: `missing`");
  assert.equal(retried.status, 0, "a failed incremental definition must be rolled back");
  assert.equal(retried.instances[0].exports.retry(), 42);
}

console.log("compiler tests passed");
