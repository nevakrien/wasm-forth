import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const compilerBytes = await readFile(new URL("../build/compiler.wasm", import.meta.url));
const { instance: compiler } = await WebAssembly.instantiate(compilerBytes);
const { memory, table, reset, alloc, compile, resume } = compiler.exports;
const encoder = new TextEncoder();

function decodeError(bytes) {
  assert.equal(bytes.length, 28);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  assert.equal(new TextDecoder().decode(bytes.subarray(0, 4)), "WFCE");
  return {
    version: view.getUint32(4, true),
    code: view.getUint32(8, true),
    offset: view.getUint32(12, true),
    span: view.getUint32(16, true),
    expected: view.getUint32(20, true),
    actual: view.getUint32(24, true),
  };
}

async function compileSource(text) {
  reset();
  const source = encoder.encode(text);
  const pointer = alloc(source.length);
  assert.notEqual(pointer, 0);
  new Uint8Array(memory.buffer, pointer, source.length).set(source);
  const instances = [];
  const modules = [];
  let response = compile(pointer, source.length);
  while (response[0] === 1) {
    const bytes = new Uint8Array(memory.buffer, response[1], response[2]).slice();
    assert.equal(WebAssembly.validate(bytes), true);
    modules.push(bytes);
    const { instance } = await WebAssembly.instantiate(bytes, {
      "wasm-forth": { memory, table },
    });
    instances.push(instance);
    response = resume();
  }
  const [status, payload, length] = response;
  const bytes = length
    ? new Uint8Array(memory.buffer, payload, length).slice()
    : new Uint8Array();
  return { status, payload, length, bytes, instances, modules };
}

async function compileIncrement(text) {
  const source = encoder.encode(text);
  const pointer = alloc(source.length);
  assert.notEqual(pointer, 0);
  new Uint8Array(memory.buffer, pointer, source.length).set(source);
  const instances = [];
  let response = compile(pointer, source.length);
  while (response[0] === 1) {
    const bytes = new Uint8Array(memory.buffer, response[1], response[2]).slice();
    const { instance } = await WebAssembly.instantiate(bytes, {
      "wasm-forth": { memory, table },
    });
    instances.push(instance);
    response = resume();
  }
  return { status: response[0], instances };
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
    ": add ( i32 i32 -- i32 ) i32.add ; : pair ( i32 i32 -- i32 i32 ) 0 i32.add ;",
  );
  assert.equal(result.status, 0);
  assert.equal(result.instances[0].exports.add(20, 22), 42);
  assert.deepEqual(result.instances[1].exports.pair(4, 5), [4, 5]);
}

{
  const result = await compileSource(": limits ( -- i32 i32 ) -2147483648 2147483647 ;");
  assert.equal(result.status, 0);
  assert.deepEqual(result.instances[0].exports.limits(), [-2147483648, 2147483647]);
}

{
  const result = await compileSource(": recurse ( i32 -- i32 ) recurse ;");
  assert.equal(result.status, 0, "a definition must see its reserved slot and type");
  assert.equal(result.modules.length, 1);
}

const failures = [
  [": bad ( -- i32 ) 1 i32.add ;", 5],
  [": bad ( -- i32 i32 ) 1 ;", 13],
  [": bad ( -- i32 ) ;", 6],
  [": bad ( -- i32 ) 2147483648 ;", 8],
  [": outer ( -- i32 ) : inner ( -- i32 ) 1 ; ;", 3],
  [": bad ( -- i32 ) missing ;", 4],
  ["export missing", 7],
  [": unfinished ( -- i32 ) 1", 2],
  [": bad ( f32 -- i32 ) 1 ;", 12],
];

for (const [source, code] of failures) {
  const result = await compileSource(source);
  assert.equal(result.status, 256 + code, source);
  assert.equal(decodeError(result.bytes).code, code, source);
}

{
  reset();
  const forty = await compileIncrement(": forty ( -- i32 ) 40 ;");
  const answer = await compileIncrement(": answer ( -- i32 ) forty 2 i32.add ;");
  assert.equal(forty.status, 0);
  assert.equal(answer.status, 0);
  assert.equal(answer.instances[0].exports.answer(), 42);

  const failed = await compileIncrement(": retry ( -- i32 ) missing ;");
  const retried = await compileIncrement(": retry ( -- i32 ) answer ;");
  assert.equal(failed.status, 260);
  assert.equal(retried.status, 0, "a failed incremental definition must be rolled back");
  assert.equal(retried.instances[0].exports.retry(), 42);
}

console.log("compiler tests passed");
