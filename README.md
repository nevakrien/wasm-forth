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
locals are compile-time words scoped to the current definition. `local name
i32` declares a zero-initialized Wasm local. `@name` emits `local.get`, `!name`
consumes a value and emits `local.set`, and `!@name` emits `local.tee`, storing
the top value while retaining it on the operand stack:

```forth
: twice ( i32 -- i32 )
  local x i32
  !x
  @x @x add
;
```

The bare local name is intentionally invalid so a missing operation prefix is
reported instead of silently reading or modifying a local.

Each completed definition produces one extension module immediately. The
extension imports `memory` and `table` from `wasm-forth`, installs its runtime
function in a compiler-assigned table slot with an active element segment, and
exports the function under its source name. Calls across modules use typed
`call_indirect` against the shared heterogeneous table.

## Build and test

WABT's `wat2wasm` and Node.js are the core development dependencies.

```sh
make test
```

This assembles `compiler/compiler.wat`, drives the instantiate-and-resume
protocol on Node, wasmi, Wasmtime, Chromium, and Firefox, validates and
instantiates every generated extension, and checks execution and structured
failures. Rust, the npm development dependencies, and Playwright's Chromium and
Firefox installations are required for the complete default suite.

The native-only subset tests Node, wasmi, and Wasmtime:

```sh
make test-runtimes
```

Individual engines can be selected with `make test-node`, `make test-wasmi`,
or `make test-wasmtime`. The native cases execute a typed cross-module call,
single- and multi-result top-level expressions, and a structured compilation
failure. The cross-module case submits two definitions and the expression that
calls them as three separate chunks in one persistent compiler session, then
invokes the slot returned by `RUN`. CI runs all three engines.

All five runtimes consume the same line-delimited conformance source at
`test/fixtures/repl.txt`; expected outcomes live beside it in
`test/fixtures/repl.expected.json`. Adding a chunk and its expected result there
extends the shared runtime matrix.

The native adapters can also be used as line-oriented development REPLs. Each
non-empty input line is submitted as one persistent source chunk:

```sh
make repl-wasmi
make repl-wasmtime
```

The browser workspace and Node tests share `browser/repl.mjs`, which implements
the source-chunk, `INSTALL`, instantiate, `resume`, and `RUN` lifecycle. The
browser test drives that workspace through the same three-chunk REPL flow
headlessly on Chromium and Firefox in CI.
After installing the development dependencies and browsers with `npm ci` and
`npx playwright install chromium firefox`, run either engine locally with:

```sh
make test-browser BROWSER=chromium
make test-browser BROWSER=firefox
```

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

See [INTEGRATION.md](INTEGRATION.md) for the complete adapter state machine,
object ownership rules, a persistent REPL example, and JavaScript and native
runtime integration notes.

The compiler exports `memory`, `table`, `reset`, `alloc`, `compile`, and
`resume`. `compile(source, source_length)` and `resume()` return
`(status, payload, payload_length)`:

| Status | Meaning |
| ---: | --- |
| `0` | `READY`: source consumed; payload and length are zero |
| `1` | `INSTALL`: payload is one extension module |
| `2` | `RUN`: payload is an ephemeral function's table slot; length is its result count |
| `3` | `ERROR`: payload is a compiler-authored UTF-8 diagnostic |

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

Error messages are generated inside the compiler module rather than reconstructed
from numeric codes by each adapter. When a source token caused the failure, the
diagnostic contains that exact source span, for example
`unknown name: \`missing\``. Adapters can render the payload directly.

The bootstrap currently reserves table slots 0-15 for compiler actions and
limits runtime definitions to 240, the semantic type stack and local context to
1024 entries each, and source to 1 MiB. Runtime definition calls still need to
move onto the shared compiler-action path described in `TODO.md`; dictionary
entries are not architecturally restricted to runtime functions.
