# Runtime adapter integration

wasm-forth is a persistent compile-and-run environment. A runtime adapter does
more than instantiate `compiler.wasm`: it repeatedly installs extension modules
produced by the compiler and resumes compilation after every installation.

The reference JavaScript adapter is `browser/repl.mjs`. It is shared by the
Node tests and the browser workspace. Native examples for wasmi and Wasmtime
are in `test/runtimes/src/`.

## Objects and ownership

Instantiate `build/compiler.wasm` once per REPL session. It exports the objects
and functions needed by the adapter:

```text
memory
table
reset() -> ()
alloc(byte_count: i32) -> pointer: i32
compile(source: i32, source_length: i32) -> (status, payload, payload_length)
resume() -> (status, payload, payload_length)
```

The compiler owns `memory` and `table`. Every generated extension imports those
exact objects under the module name `wasm-forth`:

```text
wasm-forth.memory
wasm-forth.table
```

For native runtimes, the compiler and all extensions must use the same engine,
store, or equivalent runtime context. Creating a fresh store for an extension
does not preserve object identity and will not implement the REPL lifecycle.

Call `reset` once when creating or explicitly resetting a session. Do not call
it before each source chunk: dictionary entries, table slots, and generated
definitions intentionally persist between submissions.

## How definitions reach later modules

WebAssembly has no ambient namespace shared by independently instantiated
modules. Every cross-module object must either be represented by an imported
shared object or explicitly supplied as an import by the adapter.

### Functions

Generated runtime functions are not imported directly by later modules. When a
definition begins, the compiler reserves a stable slot in its heterogeneous
`funcref` table and records that slot and the function signature in dictionary
metadata. The extension that defines the function contains an active element
segment which writes the function into that slot during instantiation.

Later child modules import the same table. A call to an earlier word is emitted
as a typed `call_indirect` using its recorded slot and signature:

```text
definition extension --active element--> shared table[slot]
later extension       --call_indirect---> shared table[slot]
```

The adapter therefore does not build a new function import object for every
child. Its responsibility is to pass the exact compiler-owned table to every
extension and to finish instantiating each extension before calling `resume`.
This ordering makes the new function visible to the next source chunk.

Host-defined runtime functions are not supported by the current embedding ABI.
Supporting one requires both a table slot containing the host function and a
compiler dictionary record containing its semantic signature and compiler
action. Merely placing a function in the table is insufficient because source
lookup and type checking would not know about it.

### Constants, variables, and data

These objects should not all be modeled as Wasm globals:

| Object | Cross-module representation |
| --- | --- |
| Compile-time constant | Dictionary metadata; emit the typed constant into each use site. |
| Mutable variable | Address in persistent shared memory plus semantic pointer metadata. |
| String or static data | Reserved persistent shared-memory range, initialized by a data segment. |
| Runtime function | Stable slot in the shared `funcref` table. |
| True Wasm global | Exported global handle explicitly registered and supplied by the adapter. |

Constants need no runtime linkage. Variables and data are visible to children
because every extension receives the same memory; the dictionary action emits
their address and preserves memory identity and pointee type. Persistent data
must use an allocator lifetime separate from temporary source and compiler
output buffers.

### True Wasm globals

Source-level runtime globals and generated global sections are not implemented
in the current vertical slice. Today, generated extensions import only
`wasm-forth.memory` and `wasm-forth.table`; the compiler's internal mutable
globals are private and are not available to children.

When true cross-module Wasm globals are added, they require an explicit adapter
registry because Wasm globals cannot be stored in a `funcref` table. The linking
contract should be:

1. The compiler assigns each persistent global an internal ID and Wasm type.
2. Its defining extension exports the global under a deterministic internal
   name derived from that ID.
3. After instantiation, the adapter registers the exported `WebAssembly.Global`
   or native-runtime global handle under that ID.
4. A later extension that uses the global declares an import for that ID with
   the exact type and mutability.
5. The adapter resolves that import from its registry before instantiation.
6. Reset clears the registry together with compiler dictionary state.

This is deliberately different from function linkage. Functions use one
shared table so children need no per-function imports. True globals need
per-global imports and host-held handles. Until the compiler emits those
imports and stable internal export names, an adapter must not claim that runtime
globals are linked.

## Adapter state machine

For each source chunk:

1. Encode the chunk as UTF-8.
2. Call `alloc(byte_length)` and copy the bytes into compiler memory.
3. Call `compile(pointer, byte_length)`.
4. While the returned status is `INSTALL`, copy the module bytes out of compiler
   memory, instantiate them with the compiler's memory and table, then call
   `resume`.
5. Handle the final `READY`, `RUN`, or error response.

The response statuses are:

| Status | Name | Adapter action |
| ---: | --- | --- |
| `0` | `READY` | The chunk is complete. Wait for another chunk. |
| `1` | `INSTALL` | Instantiate the module payload, then call `resume`. |
| `2` | `RUN` | Call the nullary function at table slot `payload`. |
| `>= 256` | Error | Copy and decode the structured error payload. |

An adapter loop is equivalent to:

```text
submit(source):
    pointer = compiler.alloc(source.byte_length)
    compiler.memory[pointer..] = source
    response = compiler.compile(pointer, source.byte_length)

    while response.status == INSTALL:
        bytes = copy compiler.memory[response.payload..response.payload_length]
        extension = instantiate bytes with:
            "wasm-forth"."memory" = compiler.memory
            "wasm-forth"."table"  = compiler.table
        response = compiler.resume()

    if response.status == RUN:
        function = compiler.table[response.payload]
        value = function()
        return value

    if response.status >= 256:
        error = copy compiler.memory[response.payload..response.payload_length]
        return decode(error)

    return READY
```

Copy an `INSTALL` or error payload before the next compiler call. Returned
pointers refer to compiler-owned memory and are only guaranteed to remain valid
until the next `reset`; compilation and extension instantiation can also grow
memory, invalidating cached host views such as JavaScript `Uint8Array` objects.

Do not invoke extension exports as a substitute for handling `RUN`. A top-level
expression is emitted as an ephemeral nullary function, and its table slot is
the interface returned to the host.

## Persistent REPL example

These are three separate calls to the adapter, not one concatenated source
string:

```forth
: forty ( -- i32 ) 40 ;
```

```forth
: answer ( -- i32 ) forty 2 i32.add ;
```

```forth
answer
```

The first submission installs `forty` and finishes with `READY`. The second
installs `answer`, whose generated body calls `forty` through the shared table,
and finishes with `READY`. The third installs an ephemeral expression function
and finishes with `RUN`; calling the returned table slot produces `42`.

## JavaScript reference adapter

`ReplSession` accepts an instantiated compiler and implements the complete
lifecycle:

```js
import { ReplSession } from "./browser/repl.mjs";

const bytes = await fetch("./build/compiler.wasm").then((response) => response.arrayBuffer());
const { instance: compiler } = await WebAssembly.instantiate(bytes);
const repl = new ReplSession(compiler);

repl.reset();
await repl.submit(": forty ( -- i32 ) 40 ;");
await repl.submit(": answer ( -- i32 ) forty 2 i32.add ;");
const result = await repl.submit("answer");
console.assert(result.response[0] === 2);
console.assert(result.execution.value === 42);
```

Each installation is also returned in `result.installations`, including its
copied bytes, compiled module, and instance. On `RUN`, `result.execution`
contains the table slot, result count, and invoked value. On a compiler error,
`result.payloadBytes` contains a stable copy of the structured error record.

## Native adapters

The wasmi and Wasmtime adapters follow the same state machine with runtime-
specific APIs. They are also usable line-oriented REPL binaries: each non-empty
stdin line is one source chunk, and each output line is `READY`, `RUN` followed
by its i32 results, or `ERROR` followed by the structured error code.

```sh
make repl-wasmi
make repl-wasmtime
```

For example, enter these as three separate lines:

```text
: forty ( -- i32 ) 40 ;
: answer ( -- i32 ) forty 2 i32.add ;
answer
```

The adapters' important integration steps are:

1. Keep one store alive for the whole session.
2. Resolve typed compiler exports, including the three-value results of
   `compile` and `resume`.
3. Copy each extension payload into host-owned bytes.
4. Define the compiler's existing memory and table in the extension linker.
5. Instantiate and start the extension before calling `resume`.
6. Resolve a `RUN` result from the shared table and invoke it with its expected
   signature.

The adapters are development examples; the compiler and generated programs do
not acquire a Rust ABI or runtime dependency from them. Their automated test
spawns the same binaries and feeds source chunks through stdin rather than
testing a separate in-process harness.

Run every adapter with:

```sh
make test
```

The cross-runtime conformance session is `test/fixtures/repl.txt`. Every
non-empty line is one source chunk, and Node, wasmi, Wasmtime, Chromium, and
Firefox all consume that exact file. `test/fixtures/repl.expected.json` contains
the ordered outcomes. Extend those two files to add a behavior to the shared
runtime matrix; runtime-specific tests may still cover additional details.
