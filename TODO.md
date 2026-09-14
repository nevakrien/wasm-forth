# TODO

- Add optional multi-function generated modules. Keep one function per module
  as the default until runtime measurements justify batching. A batching mode
  must flush before executing a generated immediate, running generated code,
  an explicit `end-module`, or reaching a configured limit.
- Add typed forward declarations and recursive groups for mutually recursive
  functions. Linker names and signatures must be reserved before compiling any
  body in the group.
- Add explicit foreign-module imports with signature validation and a portable
  adapter path for registering foreign functions in the named linker registry.
- Add dictionary-backed typed constants. Constant compiler actions should emit
  values directly and should not consume runtime function-table slots.
- Add `variable`-style objects backed by a persistent shared-memory data arena.
  Their compiler actions must emit semantic pointer types containing memory
  identity and pointee type.
- Add string/data definitions using reserved shared-memory ranges and generated
  active data segments. Export immutable globals for addresses and lengths when
  external Wasm consumers need them.
- Complete the canonical dictionary compiler-action ABI. Bootstrap primitives
  now dispatch indirectly through dictionary metadata; runtime definitions
  should move to one shared typed call action, and non-function dictionary
  objects must be able to use distinct compiler actions without consuming
  runtime table slots.
