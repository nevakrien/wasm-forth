# wasm-forth

A Forth-like environment for programming WebAssembly directly. The bootstrap
compiler is an import-free WebAssembly module which owns its memory and
heterogeneous `funcref` table. It emits Wasm binary directly, without a runtime
WAT assembler or hidden data stack.

The current vertical slice accepts explicitly typed i32 definitions, signed
i32 literals, `i32.add`, typed calls to earlier definitions, and direct
module-local self-calls:

```forth
: forty ( -- i32 ) 40 ;
: answer ( -- i32 ) forty 2 i32.add ;
export answer
```

Parameters and results are explicit, with arbitrary i32 counts:

```forth
: sum ( i32 i32 -- i32 ) add ;
```

`i32.add` and its `add` alias are dictionary-backed compiler actions. Named
locals are compile-time words scoped to the current definition. `local name`
consumes the top value into a new Wasm local, the bare name emits `local.get`,
and `local.set name` consumes a value to update it:

```forth
: twice ( i32 -- i32 )
  local x
  x x add
;
```

Each completed definition produces one extension module immediately. The
extension imports `memory` and `table` from `wasm-forth`, installs its runtime
function in a compiler-assigned table slot with an active element segment, and
exports the function under its source name. Calls across modules use typed
`call_indirect` against the shared heterogeneous table.

## Build and test

WABT's `wat2wasm` and Node.js are the current development dependencies.

```sh
make test
```

This assembles `compiler/compiler.wat`, drives the instantiate-and-resume
protocol from Node, validates and instantiates every generated extension, and
checks execution and structured failures.

To build the compiler, start a local server, and open the browser workspace:

```sh
make web
```

The server runs until Ctrl+C. Set a different port with, for example,
`make web WEB_PORT=9000`. If a browser cannot be opened automatically, visit
the URL printed by the command. The workspace is a persistent session: submit
one definition, submit later definitions that call it, and invoke a word by
entering its i32 arguments followed by its name, such as `20 22 sum`. Definitions
remain installed until Reset Session is pressed. It uses the same
instantiate-and-resume protocol as the Node tests and has no server-side runtime
component.

## Embedding ABI

The compiler exports `memory`, `table`, `reset`, `alloc`, `compile`, and
`resume`. `compile(source, source_length)` and `resume()` return
`(status, payload, payload_length)`:

| Status | Meaning |
| ---: | --- |
| `0` | `READY`: source consumed; payload and length are zero |
| `1` | `INSTALL`: payload is one extension module |
| `2` | `RUN`: payload is an ephemeral function's table slot; length is its result count |
| `>= 256` | compilation error; payload is a 28-byte `WFCE` record |

On `INSTALL`, instantiate the bytes with the compiler-owned objects and then
call `resume`:

```js
const { instance } = await WebAssembly.instantiate(bytes, {
  "wasm-forth": { memory: compiler.memory, table: compiler.table },
});
response = compiler.resume();
```

Top-level expressions use the same compiler and Wasm operand stack as function
bodies. For example, `1 2 add` emits and installs an ephemeral nullary function.
After installation, `resume` returns `RUN`; the host calls
`table.get(payload)()` and presents its result. The ephemeral dictionary record
is removed immediately, and its table slot is reused by the next expression.

The compiler stops scanning exactly after each `;`, so no later source is
processed until the host has installed that definition. There is no final
program module.

The little-endian error record is:

| Offset | Field |
| ---: | --- |
| 0 | ASCII `WFCE` |
| 4 | format version (`1`) |
| 8 | error code (status minus 256) |
| 12 | source byte offset |
| 16 | token byte length |
| 20 | expected tag or count |
| 24 | actual tag or count |

Current error codes are: `2` unexpected end/token, `3` nested definition, `4`
unknown name, `5` type-stack underflow, `6` empty definition, `7` unknown
export, `8` integer overflow, `9` duplicate definition, `10` compiler limit,
`11` invalid input/allocation failure, `12` unsupported/invalid signature type,
`13` final signature mismatch, `14` duplicate/reserved local name, and `15`
unknown local name.

The bootstrap currently reserves table slots 0-15 for compiler actions and
limits runtime definitions to 240, the semantic type stack and local context to
1024 entries each, and source to 1 MiB. Runtime definition calls still need to
move onto the shared compiler-action path described in `TODO.md`; dictionary
entries are not architecturally restricted to runtime functions.
