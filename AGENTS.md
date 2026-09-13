# AGENTS.md

## Project goal

`wasm-forth` is a dynamic Forth-like programming environment for **programming WebAssembly directly**.

It is not a Forth VM implemented on top of Wasm.

The runtime operand stack is the real Wasm operand stack. Generated programs should be ordinary Wasm binaries that can be loaded by normal Wasm runtimes.

The project should assume as little as possible about the host.

---

## Committed bootstrap architecture

The first compiler is written directly in WebAssembly. Its checked-in source is WAT, assembled to a Wasm module as a development build step. WAT is only the textual representation of the bootstrap module; the compiler itself emits Wasm binary directly and never invokes a WAT assembler at runtime.

Do not implement the core compiler in C, Rust, or another language whose toolchain introduces an ABI, shadow stack, `__stack_pointer`, runtime support functions, or other conventions not required by this project. The bootstrap module uses ordinary Wasm functions, parameters, locals, globals, tables, and linear memory deliberately and visibly.

The core compiler module has no imports. It defines and exports its own linear memory and grows it as needed. It must not depend on files, environment variables, a clock, threads, stdout, WASI, or a host allocator. Native command-line tools and browser glue are thin adapters around the same Wasm module.

The compiler has these concrete components:

```text
source bytes
    -> tokenizer
    -> dictionary lookup / compile-time evaluator
    -> immediate words mutate Compiler
    -> buffered Wasm binary emitter
    -> module bytes or structured error
```

`Compiler` owns at least:

```text
dictionary                 names -> primitive, immediate, or target definition
module                     interned types, functions, memories, globals, exports
current function           locals, instruction bytes, control frames
type stack                 semantic types of live Wasm operand values
compile-time values        values used while executing immediates
source location            byte offset and token span
error                      code, location, expected data, actual data
specialization caches      generated helpers keyed by concrete Wasm types
```

Emit Wasm binary directly. Do not make WAT or an external assembler part of `compile`. Keep a structured module builder, but do not build a general instruction AST: each function buffers encoded instructions, and the module writer adds section and body sizes when finalizing. Assign or intern type and function indices at declaration time so ordinary emission does not require patching instruction streams.

Compiler state is represented explicitly in the bootstrap module's linear memory. The compile-time evaluator may use a private value stack there to execute immediate definitions. This is compiler state, not a Forth runtime stack and not something emitted programs carry. Initially, built-in immediates are Wasm functions dispatched through a table. Generated immediate bodies are installed through the dynamic module lifecycle below and then invoked indirectly by the compiler. The evaluator and primitive compiler API must remain small enough to replace with wasm-forth definitions incrementally.

### Dynamic module lifecycle

The compiler is a persistent compile/run environment; there is no final program
module. It owns and exports the linear memory and a heterogeneous `funcref`
table. Generated modules import those objects, and active element segments add
their runtime functions to compiler-assigned table slots. A thin host adapter
only services an instantiate-and-resume protocol when compilation yields a new
module.

Initially, each completed definition is emitted as one module and instantiated
before compilation continues. This makes newly generated immediates callable
immediately and gives failures a small transactional boundary. Multi-function
module batching is a later optional optimization, not part of the initial
linking semantics.

Runtime words may have arbitrary explicit Wasm signatures. The shared table is
heterogeneous, and generated cross-module calls use `call_indirect` with the
specific expected signature. Compiler-callable immediates use a separate,
canonical compiler ABI because the persistent compiler must know how to invoke
them.

Every dictionary word names a compiler action invoked indirectly. The compiler
action for an ordinary runtime function reads that function's explicit
signature and table slot from dictionary metadata, checks the semantic type
stack, and emits its typed indirect call. It is a shared compiler action; do
not generate one compiler function for every ordinary runtime definition.

Dictionary words are not limited to functions. Constants, variables, globals,
strings, and other named compiler objects also have associated compiler
actions using the canonical immediate ABI. A plain constant action emits its
typed constant value. A variable action emits a typed pointer carrying its
memory identity and pointee type. More specialized objects may execute custom
immediate behavior rather than being reduced to a function call.

Persistent runtime data must not share an allocator lifetime with temporary
source and compiler-output buffers. Generated modules may initialize reserved
regions of the shared memory with active data segments. Objects such as strings
may additionally be represented by exported immutable globals and dictionary
metadata so later modules can emit their address and length with the correct
semantic types.

Function signatures are explicit. Assign function indices and table slots at
declaration time so self-recursion works, and permit declarations to reserve
the signatures and slots needed for mutual recursion.

The initial embedding ABI is intentionally Wasm-native:

```text
export memory
export reset() -> ()
export alloc(byte_count: i32) -> pointer: i32
export compile(source: i32, source_length: i32)
    -> (status: i32, payload: i32, payload_length: i32)
export resume()
    -> (status: i32, payload: i32, payload_length: i32)
```

The host calls `reset`, allocates and writes the source bytes, then calls
`compile`. A ready status means the source was consumed. An install status means
the payload is a generated extension module; the host instantiates it with the
compiler's exported memory and table and calls `resume`. On failure, the
payload is a serialized structured error. Returned pointers remain valid until
the next `reset`. The first page contains bootstrap state and zero is reserved
as an allocation-failure sentinel. This is not a C ABI: there is no implicit
stack pointer, stack frame layout, allocator contract, or null-terminated
string convention.

An interactive top-level expression is emitted as an ephemeral nullary
extension function. After its install/resume cycle, a run status returns that
function's table slot and result count so the host can invoke it and present the
result. Its dictionary record is then discarded and its slot may be reused.
This status is necessary because the import-free compiler cannot instantiate or
invoke the extension itself, while the REPL must not emulate the Wasm operand
stack in host code.

This architecture is the default. Change it only in response to a concrete limitation demonstrated by an implementation or test, and record the reason here.

### Initial vertical slice

Implement one end-to-end path before broad feature work:

1. Tokenize names, integer literals, `:`, `;`, and `export`.
2. Compile `i32.const`, `i32.add`, calls, and one exported nullary function returning `i32`.
3. Maintain and test the type stack while instructions are emitted.
4. Return module bytes through the exported Wasm ABI and instantiate them in at least one native runtime and one browser.
5. Add `drop`, `dup`, and `swap`, including helper specialization and invalid-stack tests.
6. Add structured control flow before adding linear memory, GC, SIMD, or C ABI features.

The first accepted source program is:

```forth
: answer 40 2 i32.add ;
export answer
```

In this slice, a bare integer literal emits `i32.const`; definitions use
explicit signatures; and a name referring to a linked target definition emits
a typed indirect call. Reject integer overflow, unknown names, nested
definitions, an empty `;`, and signature/type-stack mismatches as structured
compile errors rather than guessing.

The initial slice may emit only the four MVP numeric value types while enabling multi-value function results. This is staging, not an MVP-only design: semantic types, binary type encodings, and specialization keys must be extensible to typed references, pointers, and `v128` without changing the execution model.

Do not begin with a WAT parser, optimizer, package system, C ABI layer, self-hosting effort, or broad standard library. Those are later layers and must not obscure the compiler/immediate boundary.

---

## The execution model is fundamentally dynamic

The compiler is itself an executing environment.

Forth immediates are the core compilation mechanism.

An immediate word can execute while another word is being compiled and may:

```text
inspect the compile-time type stack
inspect compiler/module state
inspect constants and definitions
create locals
create functions
reuse previously generated functions
emit Wasm instructions
change compiler state
report an error
```

Do not think of immediates merely as callbacks into a conventional compiler.

They **are the compiler logic**.

The compile-time environment should be expressive enough that substantial language features can be implemented as ordinary wasm-forth code rather than hard-coded into the compiler.

---

## Type checking

The compiler maintains a type stack describing the values that generated code currently leaves on the real Wasm operand stack.

Immediate words manipulate this stack directly.

For example, `i32.add` can conceptually do:

```text
require top == i32
pop

require top == i32
pop

emit i32.add

push i32
```

If the types do not match, the immediate returns an error.

There is no separate generic/type-checking pass. Instruction immediates check and update the type stack as they emit. Function finalization verifies that the resulting stack matches the declared results, and module validation remains a mandatory backstop in tests.

---

## Generics come naturally from immediates

Generic operations should normally be implemented by inspecting the type stack at compile time.

For example, `swap` observes:

```text
(... A B)
```

and specializes:

```text
(... A B -- ... B A)
```

for those concrete types.

`swap` is implemented as a call to a generated, module-local helper with the canonical Wasm signature `(A, B) -> (B, A)`. The helper body is exactly:

```wat
(func (param $a A) (param $b B) (result B A)
  local.get $b
  local.get $a)
```

The parameters already are locals, so this needs no temporary. Cache one helper per canonical lowered Wasm signature and reuse it throughout the module. Semantic types which have the same valid Wasm signature, such as two non-null pointer types both lowered to `i32`, may share the helper; the calling immediate still updates the semantic type stack from `A B` to `B A`.

Use the same specialized-helper strategy for stack permutations which Wasm cannot express as a simple instruction sequence. Keep helpers internal, tiny, and deterministically named so disassembly is readable and engines can inline them. There is no nonstandard "force inline" mechanism.

Use direct emission when Wasm already has the right operation: `drop` emits `drop`. `dup` uses a cached `(A) -> (A, A)` helper whose body is `local.get 0; local.get 0`. Using a parameter rather than a scratch local also works for non-defaultable reference types, whose locals cannot be zero-initialized. Do not introduce scratch locals solely for stack permutation words.

The important idea is:

> generic words are compile-time programs specializing themselves from the types they observe.

Do not build a second template/generics system when immediates already provide the required mechanism.

---

## Stay close to Wasm

The runtime stack is the Wasm operand stack.

Do not introduce a hidden Forth data stack.

Do not add traditional operations such as `pick` or `roll` merely for compatibility when they require inventing another runtime model.

Use normal Wasm facilities:

```text
locals
globals
functions
blocks
GC objects
linear memories
tables
```

Generated Wasm should remain easy to inspect and understand.

---

## Types

Support modern Wasm types and design around modern Wasm rather than MVP-only Wasm.

Important types/features include:

```text
i32
i64
f32
f64

GC/reference types
structs
arrays
typed references

multiple memories

multi-value

v128 / SIMD
```

GC should be treated as an important normal part of the language.

SIMD may initially be an optional module, but `v128` must fit naturally into the type system.

### Typed pointers

Linear-memory pointers are semantic types.

For example:

```text
i32
ptr<memory 0, i32>
ptr<memory 3, i32>
(ref $foo)
```

are distinct.

A wasm32 pointer may lower to an `i32`, but that does not make it an integer.

A pointer carries its memory identity.

Therefore:

```text
ptr<memory 3, i32> @
```

must automatically emit a load from memory 3.

The programmer should not repeat information already known by the type system.

---

## Errors

Compilation errors should be returned as data.

Do not assume stdout or a terminal.

For example:

```text
expected: (... i32 i32)
found:    (... i32 i64)
```

The caller may display the error however it wants.

---

## wasm-only tooling

The project should remain as self-contained in Wasm as practical.

Compiler, assembler, validator, disassembler, and related tooling should ultimately be usable as Wasm modules.

Do not design around calling native host tooling at runtime.

A useful interface is approximately:

```text
compile(source)      -> wasm bytes | error
assemble(wat)        -> wasm bytes | error
disassemble(wasm)    -> text | error
validate(wasm)       -> ok | error
```

These functions may live in separate Wasm modules.

The core compiler must not be produced by compiling C, Rust, or another high-level implementation to Wasm. Existing third-party libraries compiled to Wasm may be evaluated for separate assembler, disassembler, or validator modules, but they must remain isolated from the compiler and must not impose their ABI on generated programs.

Investigate existing assembler/disassembler libraries before writing those separate tools from scratch.

The important constraint is that the resulting tool remains a Wasm module rather than requiring a particular native host.

---

## C ABI

C interoperability is a supported goal, but the C ABI is never required by the core language or imposed on ordinary generated modules.

Projects which need to exchange functions or data with C opt into a separate C ABI module.

The lowest-level interface should permit direct use of the conventional `__stack_pointer` global. Do not introduce a separate compiler pass merely to manage C stack frames.

Higher-level conveniences may be implemented as wasm-forth immediates or ordinary definitions on top of it, for example:

```text
stack.mark
stack.alloc size alignment
stack.restore
```

When size or alignment is known at compile time, immediates should emit the obvious constant arithmetic directly. A sufficiently optimizing runtime can fold consecutive static stack adjustments; do not add a frame-coalescing optimization until measurements justify it.

C-compatible type definitions may expose compile-time `sizeof` and `alignof` information so an allocation immediate can generate correctly aligned stack-pointer arithmetic automatically.

This layer may additionally provide:

```text
calling Clang-produced Wasm
C-compatible structs and buffers
C ABI argument/result lowering
```

It should be possible to implement this module in wasm-forth itself using ordinary Wasm globals, memories, functions, and immediates.

The compiler module itself does not expose a C ABI and must not acquire `__stack_pointer`, C stack frames, libc dependencies, or compiler runtime helpers in order to support this layer.

---

## Development tools

For development and debugging, use external tools freely.

Prefer:

```text
wasm-tools
    parse
    print
    validate
    objdump

WABT
    wat2wasm
    wasm2wat
    wasm-validate

Clang/LLVM
    for C ABI fixtures and experiments
```

External developer tools are fine.

The restriction is on the **produced system**, not on the tools used while building it.

---

## Runtime testing

Test generated Wasm on several unrelated runtimes.

Important targets:

```text
iwasm / WAMR
Wasmtime
Chromium WebAssembly
Firefox WebAssembly
```

Do not treat one runtime as the specification.

Maintain a tiny browser test page.

The browser should be able to load the wasm-forth compiler/tooling Wasm, compile some source, obtain another Wasm binary, and instantiate that binary directly.

That is an important end-to-end test of the architecture.

---

## Testing style

Prefer tiny tests.

Test:

```text
immediate execution
type-stack behavior
generic specialization
generated helper functions
compiler-generated locals
GC structs and arrays
typed pointers
multiple memories
v128/SIMD
control flow
invalid type combinations
C interoperability
assembly/disassembly round trips
```

When something fails:

```text
validate the generated Wasm
disassemble it
inspect the type stack
reduce the test
try another runtime
```

Do not hide compiler bugs behind runtime-specific workarounds.

---

## Measure of success

The project is succeeding when:

* simple source produces simple Wasm;
* immediates can implement substantial compiler behavior themselves;
* generic words specialize naturally from the compile-time type stack;
* GC, multiple memories, and SIMD feel like native language features;
* the same output runs across multiple serious Wasm runtimes;
* a browser can run the compiler and then instantiate its generated output;
* C interoperability can be added without changing the core execution model;
* compiler, assembler, and disassembler functionality can themselves live inside Wasm;
* inspecting emitted Wasm remains a useful way to understand the program.

The project should feel like a dynamic programming interface to the actual WebAssembly machine, not a second VM layered on top of it.
