# wasm-forth

A Forth-like environment for programming WebAssembly directly. The bootstrap
compiler owns its memory and heterogeneous `funcref` table and imports one thin
host module installer. It emits Wasm binary directly, without a runtime WAT
assembler or hidden data stack.

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
extension exports its function under its source name. Later modules import
earlier functions by name from `wasm-forth:user/<name>`, and calls across modules are
ordinary typed direct calls. Adapters implement that namespace with a JavaScript
object or an equivalent native runtime registry. The shared table is reserved
for compiler actions. Top-level expressions are ordinary target functions
exported under the reserved name `__repl`.

## Build and test

WABT's `wat2wasm` and Node.js are the core development dependencies.

```sh
make test
```

This assembles `compiler/compiler.wat`, drives synchronous module installation
on Node, WAMR, Wasmtime, Chromium, and Firefox, validates and
instantiates every generated extension, and checks execution and structured
failures. Rust, the npm development dependencies, and Playwright's Chromium and
Firefox installations are required for the complete default suite.

The native-only subset tests Node, WAMR, and Wasmtime:

```sh
make test-runtimes
```

Individual engines can be selected with `make test-node`, `make test-wamr`,
or `make test-wasmtime`. The native cases execute a typed cross-module call,
single- and multi-result top-level expressions, and a structured compilation
failure. The cross-module case submits two definitions and the expression that
calls them as three separate chunks in one persistent compiler session, then
invokes the generated `__repl` export. CI runs all three engines.

All five runtimes consume the same line-delimited conformance source at
`test/fixtures/repl.txt`; expected outcomes live beside it in
`test/fixtures/repl.expected.json`. Adding a chunk and its expected result there
extends the shared runtime matrix.

The native adapters can also be used as line-oriented development REPLs. Each
non-empty input line is submitted as one persistent source chunk:

```sh
make repl-wamr
make repl-wasmtime
```

The WAMR target builds the pinned WAMR 2.4.5 interpreter through CMake. Set
`WAMR_ROOT_DIR=/path/to/wasm-micro-runtime` to use an existing checkout;
otherwise CMake fetches it.

The browser workspace and Node tests share `browser/repl.mjs`, which implements
the host installer and the `OK`/`ERROR` lifecycle. The
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
remain installed until Reset Session is pressed. It uses the same synchronous
installer protocol as the Node tests and has no server-side runtime component.

## Embedding ABI

See [INTEGRATION.md](INTEGRATION.md) for the complete adapter state machine,
object ownership rules, a persistent REPL example, and JavaScript and native
runtime integration notes.

The compiler imports `wasm-forth:host.install(module_pointer, module_length) ->
status` and exports `memory`, `table`, `reset`, `alloc`, and `compile`.
`compile(source, source_length)` returns `(status, payload, payload_length)`:

| Status | Meaning |
| ---: | --- |
| `0` | `OK`: source consumed; payload and length are zero |
| `1` | `ERROR`: payload is a compiler-authored UTF-8 diagnostic |

The imported installer synchronously copies and instantiates each generated
module, resolving prior definitions from the `wasm-forth:user/` namespace:

```js
const instance = new WebAssembly.Instance(module, userDefinitions);
userDefinitions[`wasm-forth:user/${name}`] = {
  [name]: instance.exports[name],
};
return 0;
```

Top-level expressions use the same compiler and Wasm operand stack as function
bodies. For example, `1 2 add` emits and installs an ephemeral nullary function.
During installation the adapter recognizes `__repl`, invokes it, and presents
its results instead of registering it as a persistent word. The ephemeral
dictionary record is removed immediately.

The compiler stops scanning exactly after each `;`, so no later source is
processed until the host has installed that definition. There is no final
program module.

Error messages are generated inside the compiler module rather than reconstructed
from numeric codes by each adapter. When a source token caused the failure, the
diagnostic contains that exact source span, for example
`unknown name: \`missing\``. Adapters can render the payload directly.

The bootstrap table is compiler-only. The current implementation limits definitions to 240,
the semantic type stack and local context to 1024 entries each, and source to 1
MiB. Runtime definition calls still need to move onto the shared compiler-action
path described in `TODO.md`; dictionary entries are not architecturally
restricted to runtime functions.
