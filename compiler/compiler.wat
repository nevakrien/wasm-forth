(module
  (type $compiler-action (func (param i32) (result i32 i32 i32)))
  ;; Page zero is compiler state. Host/source/output allocations start at page 1.
  (memory (export "memory") 2)
  (table (export "table") 256 funcref)

  (global $heap (mut i32) (i32.const 65536))
  (global $source-base (mut i32) (i32.const 0))
  (global $scan (mut i32) (i32.const 0))
  (global $source-end (mut i32) (i32.const 0))
  (global $token-ptr (mut i32) (i32.const 0))
  (global $token-len (mut i32) (i32.const 0))
  (global $defs (mut i32) (i32.const 0))
  (global $in-def (mut i32) (i32.const 0))
  (global $current (mut i32) (i32.const 0))
  (global $depth (mut i32) (i32.const 0))
  (global $body-start (mut i32) (i32.const 0))
  (global $body-cursor (mut i32) (i32.const 0))
  (global $body-items (mut i32) (i32.const 0))
  (global $locals (mut i32) (i32.const 0))
  (global $action-data (mut i32) (i32.const 0))
  (global $repl-def (mut i32) (i32.const 0))
  (global $pending-run (mut i32) (i32.const 0))
  (global $out (mut i32) (i32.const 0))

  ;; Definition record (24 bytes): name pointer, name length, table slot,
  ;; i32 parameter count, i32 result count, complete flag.
  (data (i32.const 32) ":")
  (data (i32.const 34) ";")
  (data (i32.const 36) "export")
  (data (i32.const 43) "i32.add")
  (data (i32.const 51) "(")
  (data (i32.const 53) ")")
  (data (i32.const 55) "--")
  (data (i32.const 58) "i32")
  (data (i32.const 62) "add")
  (data (i32.const 66) "local")
  (data (i32.const 82) "__repl")

  ;; Compiler-authored diagnostics use fixed-width slots below temporary memory.
  (data (i32.const 32896) "unexpected token or end of input")
  (data (i32.const 32960) "nested definition")
  (data (i32.const 33024) "unknown name")
  (data (i32.const 33088) "type stack underflow")
  (data (i32.const 33152) "empty definition")
  (data (i32.const 33216) "unknown export")
  (data (i32.const 33280) "integer literal out of i32 range")
  (data (i32.const 33344) "duplicate definition")
  (data (i32.const 33408) "compiler limit exceeded")
  (data (i32.const 33472) "invalid compiler input or allocation failure")
  (data (i32.const 33536) "unsupported signature type")
  (data (i32.const 33600) "definition result does not match signature")
  (data (i32.const 33664) "duplicate or reserved local name")
  (data (i32.const 33728) "unknown local name")
  (data (i32.const 33792) "local name requires @, !, or !@")
  (data (i32.const 33824) "unknown compiler error")

  (func $reset (export "reset")
    (global.set $heap (i32.const 65536))
    (global.set $source-base (i32.const 0))
    (global.set $scan (i32.const 0))
    (global.set $source-end (i32.const 0))
    (global.set $defs (i32.const 0))
    (global.set $in-def (i32.const 0))
    (global.set $depth (i32.const 0))
    (global.set $locals (i32.const 0))
    (global.set $repl-def (i32.const 0))
    (global.set $pending-run (i32.const 0))
    ;; Primitive dictionary record: name pointer, name length, action table slot.
    (i32.store (i32.const 512) (i32.const 43))
    (i32.store (i32.const 516) (i32.const 7))
    (i32.store (i32.const 520) (i32.const 0))
    (i32.store (i32.const 524) (i32.const 62))
    (i32.store (i32.const 528) (i32.const 3))
    (i32.store (i32.const 532) (i32.const 0))
    (i32.store (i32.const 536) (i32.const 66))
    (i32.store (i32.const 540) (i32.const 5))
    (i32.store (i32.const 544) (i32.const 1)))

  (func $alloc (export "alloc") (param $size i32) (result i32)
    (local $start i32) (local $end i32) (local $pages i32)
    (local.set $start (global.get $heap))
    (local.set $end (i32.add (local.get $start) (local.get $size)))
    (if (i32.or
          (i32.lt_u (local.get $end) (local.get $start))
          (i32.gt_u (local.get $end) (i32.const 2147483647)))
      (then (return (i32.const 0))))
    (local.set $pages
      (i32.shr_u (i32.add (local.get $end) (i32.const 65535)) (i32.const 16)))
    (if (i32.gt_u (local.get $pages) (memory.size))
      (then
        (if (i32.eq
              (memory.grow (i32.sub (local.get $pages) (memory.size)))
              (i32.const -1))
          (then (return (i32.const 0))))))
    (global.set $heap (local.get $end))
    (local.get $start))

  (func $token-eq (param $literal i32) (param $length i32) (result i32)
    (local $i i32)
    (if (i32.ne (global.get $token-len) (local.get $length))
      (then (return (i32.const 0))))
    (loop $compare
      (if (i32.lt_u (local.get $i) (local.get $length))
        (then
          (if (i32.ne
                (i32.load8_u (i32.add (global.get $token-ptr) (local.get $i)))
                (i32.load8_u (i32.add (local.get $literal) (local.get $i))))
            (then (return (i32.const 0))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $compare))))
    (i32.const 1))

  (func $next-token (result i32)
    (local $start i32)
    (loop $skip
      (if (i32.lt_u (global.get $scan) (global.get $source-end))
        (then
          (if (i32.le_u (i32.load8_u (global.get $scan)) (i32.const 32))
            (then
              (global.set $scan (i32.add (global.get $scan) (i32.const 1)))
              (br $skip))))))
    (if (i32.ge_u (global.get $scan) (global.get $source-end))
      (then
        (global.set $token-len (i32.const 0))
        (return (i32.const 0))))
    (local.set $start (global.get $scan))
    (loop $word
      (if (i32.lt_u (global.get $scan) (global.get $source-end))
        (then
          (if (i32.gt_u (i32.load8_u (global.get $scan)) (i32.const 32))
            (then
              (global.set $scan (i32.add (global.get $scan) (i32.const 1)))
              (br $word))))))
    (global.set $token-ptr (local.get $start))
    (global.set $token-len (i32.sub (global.get $scan) (local.get $start)))
    (i32.const 1))

  ;; Returns classification (0 not integer, 1 valid, 2 overflow) and value.
  (func $parse-int (result i32 i32)
    (local $i i32) (local $negative i32) (local $byte i32)
    (local $value i64) (local $limit i64)
    (if (i32.eqz (global.get $token-len))
      (then (return (i32.const 0) (i32.const 0))))
    (if (i32.eq (i32.load8_u (global.get $token-ptr)) (i32.const 45))
      (then
        (local.set $negative (i32.const 1))
        (local.set $i (i32.const 1))
        (if (i32.eq (global.get $token-len) (i32.const 1))
          (then (return (i32.const 0) (i32.const 0))))))
    (local.set $limit
      (select (i64.const 2147483648) (i64.const 2147483647) (local.get $negative)))
    (block $done
      (loop $digits
        (br_if $done (i32.ge_u (local.get $i) (global.get $token-len)))
        (local.set $byte (i32.load8_u (i32.add (global.get $token-ptr) (local.get $i))))
        (if (i32.or (i32.lt_u (local.get $byte) (i32.const 48))
                    (i32.gt_u (local.get $byte) (i32.const 57)))
          (then (return (i32.const 0) (i32.const 0))))
        (local.set $value
          (i64.add (i64.mul (local.get $value) (i64.const 10))
                   (i64.extend_i32_u (i32.sub (local.get $byte) (i32.const 48)))))
        (if (i64.gt_u (local.get $value) (local.get $limit))
          (then (return (i32.const 2) (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $digits)))
    (if (local.get $negative)
      (then (return (i32.const 1)
                    (i32.wrap_i64 (i64.sub (i64.const 0) (local.get $value))))))
    (i32.const 1)
    (i32.wrap_i64 (local.get $value)))

  (func $record (param $index i32) (result i32)
    (i32.add (i32.const 1024) (i32.mul (local.get $index) (i32.const 24))))

  (func $primitive-record (param $index i32) (result i32)
    (i32.add (i32.const 512) (i32.mul (local.get $index) (i32.const 12))))

  ;; Local records live only while compiling one definition: name pointer,
  ;; name length, Wasm local index, and lowered value type.
  (func $local-record (param $index i32) (result i32)
    (i32.add (i32.const 16384) (i32.mul (local.get $index) (i32.const 16))))

  (func $token-matches-record (param $record i32) (result i32)
    (local $i i32)
    (if (i32.ne (i32.load offset=4 (local.get $record)) (global.get $token-len))
      (then (return (i32.const 0))))
    (loop $chars
      (if (i32.lt_u (local.get $i) (global.get $token-len))
        (then
          (if (i32.ne
                (i32.load8_u (i32.add (i32.load (local.get $record)) (local.get $i)))
                (i32.load8_u (i32.add (global.get $token-ptr) (local.get $i))))
            (then (return (i32.const 0))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $chars))))
    (i32.const 1))

  (func $find-primitive (result i32)
    (local $i i32) (local $r i32)
    (loop $each
      (if (i32.lt_u (local.get $i) (i32.const 3))
        (then
          (local.set $r (call $primitive-record (local.get $i)))
          (if (call $token-matches-record (local.get $r))
            (then (return (i32.load offset=8 (local.get $r)))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $each))))
    (i32.const -1))

  (func $find-local (result i32)
    (local $i i32) (local $r i32)
    (loop $each
      (if (i32.lt_u (local.get $i) (global.get $locals))
        (then
          (local.set $r (call $local-record (local.get $i)))
          (if (call $token-matches-record (local.get $r))
            (then (return (local.get $i))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $each))))
    (i32.const -1))

  (func $find-local-op (param $mode i32) (result i32)
    (local $i i32) (local $r i32) (local $j i32) (local $prefix-length i32)
    (local.set $prefix-length
      (select (i32.const 2) (i32.const 1) (i32.eq (local.get $mode) (i32.const 2))))
    (if (i32.le_u (global.get $token-len) (local.get $prefix-length))
      (then (return (i32.const -1))))
    (if (i32.eqz (local.get $mode))
      (then
        (if (i32.ne (i32.load8_u (global.get $token-ptr)) (i32.const 64))
          (then (return (i32.const -1)))))
      (else
        (if (i32.ne (i32.load8_u (global.get $token-ptr)) (i32.const 33))
          (then (return (i32.const -1))))))
    (if (i32.eq (local.get $mode) (i32.const 2))
      (then
        (if (i32.ne
              (i32.load8_u offset=1 (global.get $token-ptr))
              (i32.const 64))
          (then (return (i32.const -1))))))
    (loop $each
      (if (i32.lt_u (local.get $i) (global.get $locals))
        (then
          (local.set $r (call $local-record (local.get $i)))
          (if (i32.eq
                (global.get $token-len)
                (i32.add
                  (i32.load offset=4 (local.get $r))
                  (local.get $prefix-length)))
            (then
              (local.set $j (i32.const 0))
              (block $different
                (loop $chars
                  (br_if $different
                    (i32.and
                      (i32.lt_u (local.get $j) (i32.load offset=4 (local.get $r)))
                      (i32.ne
                        (i32.load8_u
                          (i32.add (global.get $token-ptr)
                            (i32.add (local.get $j) (local.get $prefix-length))))
                        (i32.load8_u
                          (i32.add (i32.load (local.get $r)) (local.get $j))))))
                  (if (i32.lt_u (local.get $j) (i32.load offset=4 (local.get $r)))
                    (then
                      (local.set $j (i32.add (local.get $j) (i32.const 1)))
                      (br $chars))))
                (return (local.get $i)))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $each))))
    (i32.const -1))

  (func $find-def (result i32)
    (local $i i32) (local $r i32) (local $j i32)
    (block $none
      (loop $each
        (br_if $none (i32.ge_u (local.get $i) (global.get $defs)))
        (local.set $r (call $record (local.get $i)))
        (if (i32.eq (i32.load offset=4 (local.get $r)) (global.get $token-len))
          (then
            (local.set $j (i32.const 0))
            (block $different
              (loop $chars
                (br_if $different
                  (i32.and
                    (i32.lt_u (local.get $j) (global.get $token-len))
                    (i32.ne
                      (i32.load8_u (i32.add (i32.load (local.get $r)) (local.get $j)))
                      (i32.load8_u (i32.add (global.get $token-ptr) (local.get $j))))))
                (if (i32.lt_u (local.get $j) (global.get $token-len))
                  (then
                    (local.set $j (i32.add (local.get $j) (i32.const 1)))
                    (br $chars))))
              (return (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $each)))
    (i32.const -1))

  (func $emit-byte (param $byte i32)
    (i32.store8 (global.get $body-cursor) (local.get $byte))
    (global.set $body-cursor (i32.add (global.get $body-cursor) (i32.const 1))))

  (func $emit-uleb (param $value i32)
    (local $byte i32)
    (loop $more
      (local.set $byte (i32.and (local.get $value) (i32.const 127)))
      (local.set $value (i32.shr_u (local.get $value) (i32.const 7)))
      (if (local.get $value)
        (then (local.set $byte (i32.or (local.get $byte) (i32.const 128)))))
      (call $emit-byte (local.get $byte))
      (br_if $more (local.get $value))))

  (func $emit-sleb (param $value i32)
    (local $byte i32) (local $done i32)
    (loop $more
      (local.set $byte (i32.and (local.get $value) (i32.const 127)))
      (local.set $value (i32.shr_s (local.get $value) (i32.const 7)))
      (local.set $done
        (i32.or
          (i32.and (i32.eqz (local.get $value))
                   (i32.eqz (i32.and (local.get $byte) (i32.const 64))))
          (i32.and (i32.eq (local.get $value) (i32.const -1))
                   (i32.ne (i32.and (local.get $byte) (i32.const 64)) (i32.const 0)))))
      (if (i32.eqz (local.get $done))
        (then (local.set $byte (i32.or (local.get $byte) (i32.const 128)))))
      (call $emit-byte (local.get $byte))
      (br_if $more (i32.eqz (local.get $done)))))

  ;; Compiler actions return (error code, expected, actual). A zero code means
  ;; that the action emitted successfully and token processing can continue.
  (func $compile-add (type $compiler-action) (param $offset i32)
    (result i32 i32 i32)
    (if (i32.lt_u (global.get $depth) (i32.const 2))
      (then (return (i32.const 5) (i32.const 2) (global.get $depth))))
    (global.set $depth (i32.sub (global.get $depth) (i32.const 1)))
    (call $emit-byte (i32.const 106))
    (global.set $body-items (i32.add (global.get $body-items) (i32.const 1)))
    (i32.const 0) (i32.const 0) (i32.const 0))

  (func $declare-local (type $compiler-action) (param $offset i32)
    (result i32 i32 i32)
    (local $found i32) (local $r i32) (local $definition i32)
    (local $name i32) (local $name-length i32)
    (if (i32.eqz (call $next-token))
      (then (return (i32.const 2) (i32.const 1) (i32.const 0))))
    (local.set $name (global.get $token-ptr))
    (local.set $name-length (global.get $token-len))
    (if (i32.or
          (i32.eq (i32.load8_u (local.get $name)) (i32.const 33))
          (i32.eq (i32.load8_u (local.get $name)) (i32.const 64)))
      (then (return (i32.const 14) (i32.const 0) (i32.const 0))))
    (local.set $found (call $find-local))
    (if (i32.ne (local.get $found) (i32.const -1))
      (then (return (i32.const 14) (i32.const 0) (local.get $found))))
    ;; Primitive names are reserved; runtime definition names may be shadowed.
    (if (i32.ne (call $find-primitive) (i32.const -1))
      (then (return (i32.const 14) (i32.const 0) (i32.const 0))))
    (if (i32.eqz (call $next-token))
      (then (return (i32.const 2) (i32.const 127) (i32.const 0))))
    (if (i32.eqz (call $token-eq (i32.const 58) (i32.const 3)))
      (then (return (i32.const 12) (i32.const 127) (i32.const 0))))
    (if (i32.ge_u (global.get $locals) (i32.const 1024))
      (then (return (i32.const 10) (i32.const 1024) (global.get $locals))))
    (local.set $r (call $local-record (global.get $locals)))
    (i32.store (local.get $r) (local.get $name))
    (i32.store offset=4 (local.get $r) (local.get $name-length))
    (local.set $definition (call $record (global.get $current)))
    (i32.store offset=8 (local.get $r)
      (i32.add (i32.load offset=12 (local.get $definition)) (global.get $locals)))
    (i32.store offset=12 (local.get $r) (i32.const 127))
    (global.set $locals (i32.add (global.get $locals) (i32.const 1)))
    (global.set $body-items (i32.add (global.get $body-items) (i32.const 1)))
    (i32.const 0) (i32.const 0) (i32.const 0))

  (func $compile-local-get (type $compiler-action) (param $offset i32)
    (result i32 i32 i32)
    (if (i32.ge_u (global.get $depth) (i32.const 1024))
      (then (return (i32.const 10) (i32.const 1024) (global.get $depth))))
    (call $emit-byte (i32.const 32))
    (call $emit-uleb (i32.load offset=8 (global.get $action-data)))
    (global.set $depth (i32.add (global.get $depth) (i32.const 1)))
    (global.set $body-items (i32.add (global.get $body-items) (i32.const 1)))
    (i32.const 0) (i32.const 0) (i32.const 0))

  (func $compile-local-set (type $compiler-action) (param $offset i32)
    (result i32 i32 i32)
    (if (i32.eqz (global.get $depth))
      (then (return (i32.const 5) (i32.const 1) (i32.const 0))))
    (call $emit-byte (i32.const 33))
    (call $emit-uleb (i32.load offset=8 (global.get $action-data)))
    (global.set $depth (i32.sub (global.get $depth) (i32.const 1)))
    (global.set $body-items (i32.add (global.get $body-items) (i32.const 1)))
    (i32.const 0) (i32.const 0) (i32.const 0))

  (func $compile-local-tee (type $compiler-action) (param $offset i32)
    (result i32 i32 i32)
    (if (i32.eqz (global.get $depth))
      (then (return (i32.const 5) (i32.const 1) (i32.const 0))))
    (call $emit-byte (i32.const 34))
    (call $emit-uleb (i32.load offset=8 (global.get $action-data)))
    ;; local.tee consumes and reproduces the same typed operand.
    (global.set $body-items (i32.add (global.get $body-items) (i32.const 1)))
    (i32.const 0) (i32.const 0) (i32.const 0))

  (func $uleb-size (param $value i32) (result i32)
    (local $size i32)
    (loop $more
      (local.set $size (i32.add (local.get $size) (i32.const 1)))
      (local.set $value (i32.shr_u (local.get $value) (i32.const 7)))
      (br_if $more (local.get $value)))
    (local.get $size))

  (func $sleb-size (param $value i32) (result i32)
    (local $size i32) (local $byte i32) (local $done i32)
    (loop $more
      (local.set $byte (i32.and (local.get $value) (i32.const 127)))
      (local.set $value (i32.shr_s (local.get $value) (i32.const 7)))
      (local.set $size (i32.add (local.get $size) (i32.const 1)))
      (local.set $done
        (i32.or
          (i32.and (i32.eqz (local.get $value))
                   (i32.eqz (i32.and (local.get $byte) (i32.const 64))))
          (i32.and (i32.eq (local.get $value) (i32.const -1))
                   (i32.ne (i32.and (local.get $byte) (i32.const 64)) (i32.const 0)))))
      (br_if $more (i32.eqz (local.get $done))))
    (local.get $size))

  (func $out-byte (param $byte i32)
    (i32.store8 (global.get $out) (local.get $byte))
    (global.set $out (i32.add (global.get $out) (i32.const 1))))

  (func $out-uleb (param $value i32)
    (local $byte i32)
    (loop $more
      (local.set $byte (i32.and (local.get $value) (i32.const 127)))
      (local.set $value (i32.shr_u (local.get $value) (i32.const 7)))
      (if (local.get $value)
        (then (local.set $byte (i32.or (local.get $byte) (i32.const 128)))))
      (call $out-byte (local.get $byte))
      (br_if $more (local.get $value))))

  (func $out-sleb (param $value i32)
    (local $byte i32) (local $done i32)
    (loop $more
      (local.set $byte (i32.and (local.get $value) (i32.const 127)))
      (local.set $value (i32.shr_s (local.get $value) (i32.const 7)))
      (local.set $done
        (i32.or
          (i32.and (i32.eqz (local.get $value))
                   (i32.eqz (i32.and (local.get $byte) (i32.const 64))))
          (i32.and (i32.eq (local.get $value) (i32.const -1))
                   (i32.ne (i32.and (local.get $byte) (i32.const 64)) (i32.const 0)))))
      (if (i32.eqz (local.get $done))
        (then (local.set $byte (i32.or (local.get $byte) (i32.const 128)))))
      (call $out-byte (local.get $byte))
      (br_if $more (i32.eqz (local.get $done)))))

  (func $copy-out (param $from i32) (param $length i32)
    (memory.copy (global.get $out) (local.get $from) (local.get $length))
    (global.set $out (i32.add (global.get $out) (local.get $length))))

  (func $error-text (param $code i32) (result i32 i32)
    (if (i32.eq (local.get $code) (i32.const 2))
      (then (return (i32.const 32896) (i32.const 32))))
    (if (i32.eq (local.get $code) (i32.const 3))
      (then (return (i32.const 32960) (i32.const 17))))
    (if (i32.eq (local.get $code) (i32.const 4))
      (then (return (i32.const 33024) (i32.const 12))))
    (if (i32.eq (local.get $code) (i32.const 5))
      (then (return (i32.const 33088) (i32.const 20))))
    (if (i32.eq (local.get $code) (i32.const 6))
      (then (return (i32.const 33152) (i32.const 16))))
    (if (i32.eq (local.get $code) (i32.const 7))
      (then (return (i32.const 33216) (i32.const 14))))
    (if (i32.eq (local.get $code) (i32.const 8))
      (then (return (i32.const 33280) (i32.const 32))))
    (if (i32.eq (local.get $code) (i32.const 9))
      (then (return (i32.const 33344) (i32.const 20))))
    (if (i32.eq (local.get $code) (i32.const 10))
      (then (return (i32.const 33408) (i32.const 23))))
    (if (i32.eq (local.get $code) (i32.const 11))
      (then (return (i32.const 33472) (i32.const 44))))
    (if (i32.eq (local.get $code) (i32.const 12))
      (then (return (i32.const 33536) (i32.const 26))))
    (if (i32.eq (local.get $code) (i32.const 13))
      (then (return (i32.const 33600) (i32.const 42))))
    (if (i32.eq (local.get $code) (i32.const 14))
      (then (return (i32.const 33664) (i32.const 32))))
    (if (i32.eq (local.get $code) (i32.const 15))
      (then (return (i32.const 33728) (i32.const 18))))
    (if (i32.eq (local.get $code) (i32.const 16))
      (then (return (i32.const 33792) (i32.const 31))))
    (i32.const 33824) (i32.const 22))

  ;; Offset and span stay internal and are used only to copy the failing token.
  (func $fail (param $code i32) (param $offset i32) (param $span i32)
               (param $expected i32) (param $actual i32) (result i32 i32 i32)
    (local $text i32) (local $text-length i32) (local $payload i32)
    ;; A failed definition must not poison a persistent compile session.
    (if (global.get $in-def)
      (then
        (global.set $defs (global.get $current))
        (global.set $in-def (i32.const 0))))
    ;; Expose the failing span so adapters can render source highlights.
    (i32.store (i32.const 256) (local.get $offset))
    (i32.store (i32.const 260) (local.get $span))
    (call $error-text (local.get $code))
    (local.set $text-length)
    (local.set $text)
    (local.set $payload
      (call $alloc
        (i32.add (local.get $text-length)
          (select (i32.const 4) (i32.const 0) (local.get $span)))))
    (if (i32.eqz (local.get $payload))
      (then (return (i32.const 3) (i32.const 33472) (i32.const 44))))
    (global.set $out (local.get $payload))
    (call $copy-out (local.get $text) (local.get $text-length))
    (if (local.get $span)
      (then
        (call $out-byte (i32.const 58))
        (call $out-byte (i32.const 32))
        (call $out-byte (i32.const 96))
        (call $copy-out
          (i32.add (global.get $source-base) (local.get $offset))
          (local.get $span))
        (call $out-byte (i32.const 96))))
    (i32.const 3)
    (local.get $payload)
    (i32.sub (global.get $out) (local.get $payload)))

  ;; Emit the current definition as an extension importing the persistent
  ;; compiler memory/table and installing its function into its reserved slot.
  (func $finish-module (result i32 i32 i32)
    (local $r i32) (local $i i32) (local $d i32) (local $payload i32)
    (local $type-size i32) (local $import-size i32) (local $function-size i32)
    (local $export-size i32) (local $element-size i32) (local $code-size i32)
    (local $body-size i32) (local $local-size i32) (local $capacity i32)
    (local.set $r (call $record (global.get $current)))

    ;; One type per known runtime definition keeps declaration-time type indices
    ;; stable for typed call_indirect, including self-calls.
    (local.set $type-size (call $uleb-size (global.get $defs)))
    (loop $size-types
      (if (i32.lt_u (local.get $i) (global.get $defs))
        (then
          (local.set $d (call $record (local.get $i)))
          (local.set $type-size
            (i32.add (local.get $type-size)
              (i32.add (i32.const 1)
                (i32.add
                  (i32.add (call $uleb-size (i32.load offset=12 (local.get $d)))
                           (i32.load offset=12 (local.get $d)))
                  (i32.add (call $uleb-size (i32.load offset=16 (local.get $d)))
                           (i32.load offset=16 (local.get $d)))))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $size-types))))
    ;; vec(2), module/name strings and import descriptors.
    (local.set $import-size (i32.const 44))
    (local.set $function-size
      (i32.add (i32.const 1) (call $uleb-size (global.get $current))))
    (local.set $export-size
      (i32.add (i32.const 3)
        (i32.add (call $uleb-size (i32.load offset=4 (local.get $r)))
                 (i32.load offset=4 (local.get $r)))))
    ;; vec(1), flags, i32.const slot/end, function vec.
    (local.set $element-size
      (i32.add (i32.const 6) (call $sleb-size (i32.load offset=8 (local.get $r)))))
    (local.set $local-size (i32.const 1))
    (if (global.get $locals)
      (then
        (local.set $local-size
          (i32.add (i32.const 2) (call $uleb-size (global.get $locals))))))
    (local.set $body-size
      (i32.add (local.get $local-size)
        (i32.add (i32.sub (global.get $body-cursor) (global.get $body-start))
                 (i32.const 1))))
    (local.set $code-size
      (i32.add (i32.const 1)
        (i32.add (call $uleb-size (local.get $body-size)) (local.get $body-size))))
    (local.set $capacity
      (i32.add (i32.const 8)
        (i32.add
          (i32.add (i32.const 1) (i32.add (call $uleb-size (local.get $type-size)) (local.get $type-size)))
          (i32.add
            (i32.add (i32.const 1) (i32.add (call $uleb-size (local.get $import-size)) (local.get $import-size)))
            (i32.add
              (i32.add (i32.const 1) (i32.add (call $uleb-size (local.get $function-size)) (local.get $function-size)))
              (i32.add
                (i32.add (i32.const 1) (i32.add (call $uleb-size (local.get $export-size)) (local.get $export-size)))
                (i32.add
                  (i32.add (i32.const 1) (i32.add (call $uleb-size (local.get $element-size)) (local.get $element-size)))
                  (i32.add (i32.const 1) (i32.add (call $uleb-size (local.get $code-size)) (local.get $code-size))))))))))
    (local.set $payload (call $alloc (local.get $capacity)))
    (if (i32.eqz (local.get $payload))
      (then (return (call $fail (i32.const 11) (i32.const 0) (i32.const 0)
                                (i32.const 0) (i32.const 0)))))
    (global.set $out (local.get $payload))
    (call $out-byte (i32.const 0)) (call $out-byte (i32.const 97))
    (call $out-byte (i32.const 115)) (call $out-byte (i32.const 109))
    (call $out-byte (i32.const 1)) (call $out-byte (i32.const 0))
    (call $out-byte (i32.const 0)) (call $out-byte (i32.const 0))

    ;; Type section.
    (call $out-byte (i32.const 1)) (call $out-uleb (local.get $type-size))
    (call $out-uleb (global.get $defs))
    (local.set $i (i32.const 0))
    (loop $write-types
      (if (i32.lt_u (local.get $i) (global.get $defs))
        (then
          (local.set $d (call $record (local.get $i)))
          (call $out-byte (i32.const 96))
          (call $out-uleb (i32.load offset=12 (local.get $d)))
          (local.set $body-size (i32.const 0))
          (loop $params
            (if (i32.lt_u (local.get $body-size) (i32.load offset=12 (local.get $d)))
              (then (call $out-byte (i32.const 127))
                    (local.set $body-size (i32.add (local.get $body-size) (i32.const 1)))
                    (br $params))))
          (call $out-uleb (i32.load offset=16 (local.get $d)))
          (local.set $body-size (i32.const 0))
          (loop $results
            (if (i32.lt_u (local.get $body-size) (i32.load offset=16 (local.get $d)))
              (then (call $out-byte (i32.const 127))
                    (local.set $body-size (i32.add (local.get $body-size) (i32.const 1)))
                    (br $results))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $write-types))))

    ;; Imports: (memory 2) and (table 256 funcref), both from wasm-forth.
    (call $out-byte (i32.const 2)) (call $out-uleb (local.get $import-size))
    (call $out-byte (i32.const 2))
    (call $out-byte (i32.const 10))
    (call $copy-out (i32.const 64) (i32.const 0))
    ;; Write literals bytewise to keep the bootstrap's own data small and clear.
    (call $out-byte (i32.const 119)) (call $out-byte (i32.const 97))
    (call $out-byte (i32.const 115)) (call $out-byte (i32.const 109))
    (call $out-byte (i32.const 45)) (call $out-byte (i32.const 102))
    (call $out-byte (i32.const 111)) (call $out-byte (i32.const 114))
    (call $out-byte (i32.const 116)) (call $out-byte (i32.const 104))
    (call $out-byte (i32.const 6))
    (call $out-byte (i32.const 109)) (call $out-byte (i32.const 101))
    (call $out-byte (i32.const 109)) (call $out-byte (i32.const 111))
    (call $out-byte (i32.const 114)) (call $out-byte (i32.const 121))
    (call $out-byte (i32.const 2)) (call $out-byte (i32.const 0)) (call $out-byte (i32.const 2))
    (call $out-byte (i32.const 10))
    (call $out-byte (i32.const 119)) (call $out-byte (i32.const 97))
    (call $out-byte (i32.const 115)) (call $out-byte (i32.const 109))
    (call $out-byte (i32.const 45)) (call $out-byte (i32.const 102))
    (call $out-byte (i32.const 111)) (call $out-byte (i32.const 114))
    (call $out-byte (i32.const 116)) (call $out-byte (i32.const 104))
    (call $out-byte (i32.const 5))
    (call $out-byte (i32.const 116)) (call $out-byte (i32.const 97))
    (call $out-byte (i32.const 98)) (call $out-byte (i32.const 108))
    (call $out-byte (i32.const 101))
    (call $out-byte (i32.const 1)) (call $out-byte (i32.const 112))
    (call $out-byte (i32.const 0)) (call $out-uleb (i32.const 256))

    ;; Function and export sections.
    (call $out-byte (i32.const 3)) (call $out-uleb (local.get $function-size))
    (call $out-byte (i32.const 1)) (call $out-uleb (global.get $current))
    (call $out-byte (i32.const 7)) (call $out-uleb (local.get $export-size))
    (call $out-byte (i32.const 1))
    (call $out-uleb (i32.load offset=4 (local.get $r)))
    (call $copy-out (i32.load (local.get $r)) (i32.load offset=4 (local.get $r)))
    (call $out-byte (i32.const 0)) (call $out-byte (i32.const 0))

    ;; Active element segment installs function index zero at the reserved slot.
    (call $out-byte (i32.const 9)) (call $out-uleb (local.get $element-size))
    (call $out-byte (i32.const 1)) (call $out-byte (i32.const 0))
    (call $out-byte (i32.const 65))
    (call $out-sleb (i32.load offset=8 (local.get $r)))
    (call $out-byte (i32.const 11))
    (call $out-byte (i32.const 1)) (call $out-byte (i32.const 0))

    ;; Code: one compact i32 local group, buffered instructions, end.
    (local.set $body-size
      (i32.add (local.get $local-size)
        (i32.add (i32.sub (global.get $body-cursor) (global.get $body-start))
                 (i32.const 1))))
    (call $out-byte (i32.const 10)) (call $out-uleb (local.get $code-size))
    (call $out-byte (i32.const 1)) (call $out-uleb (local.get $body-size))
    (if (global.get $locals)
      (then
        (call $out-byte (i32.const 1))
        (call $out-uleb (global.get $locals))
        (call $out-byte (i32.const 127)))
      (else (call $out-byte (i32.const 0))))
    (call $copy-out (global.get $body-start)
      (i32.sub (global.get $body-cursor) (global.get $body-start)))
    (call $out-byte (i32.const 11))
    (i32.const 1)
    (local.get $payload)
    (local.get $capacity))

  (func $run (result i32 i32 i32)
    (local $r i32) (local $found i32) (local $offset i32)
    (local $classification i32) (local $number i32) (local $i i32)
    (local $expected i32) (local $actual i32)
    (local $params i32) (local $results i32)
    (block $ready
      (loop $tokens
        (br_if $ready (i32.eqz (call $next-token)))
        (local.set $offset (i32.sub (global.get $token-ptr) (global.get $source-base)))
        (if (i32.eqz (global.get $in-def))
          (then
            (if (call $token-eq (i32.const 32) (i32.const 1))
              (then
                (if (i32.ge_u (global.get $defs) (i32.const 240))
                  (then (return (call $fail (i32.const 10) (local.get $offset)
                                            (global.get $token-len) (i32.const 240)
                                            (global.get $defs)))))
                (if (i32.eqz (call $next-token))
                  (then (return (call $fail (i32.const 2)
                                            (i32.sub (global.get $source-end) (global.get $source-base))
                                            (i32.const 0) (i32.const 1) (i32.const 0)))))
                (local.set $offset (i32.sub (global.get $token-ptr) (global.get $source-base)))
                (local.set $found (call $find-def))
                (if (i32.ne (local.get $found) (i32.const -1))
                  (then (return (call $fail (i32.const 9) (local.get $offset)
                                            (global.get $token-len) (i32.const 0)
                                            (local.get $found)))))
                (local.set $found (call $find-primitive))
                (if (i32.ne (local.get $found) (i32.const -1))
                  (then (return (call $fail (i32.const 9) (local.get $offset)
                                            (global.get $token-len) (i32.const 0)
                                            (local.get $found)))))
                (global.set $current (global.get $defs))
                (local.set $r (call $record (global.get $current)))
                (i32.store (local.get $r) (global.get $token-ptr))
                (i32.store offset=4 (local.get $r) (global.get $token-len))
                (i32.store offset=8 (local.get $r)
                  (i32.add (global.get $current) (i32.const 16)))
                ;; Reserve the dictionary entry and slot before parsing the body.
                (global.set $defs (i32.add (global.get $defs) (i32.const 1)))
                (if (i32.eqz (call $next-token))
                  (then (return (call $fail (i32.const 2)
                                            (i32.sub (global.get $source-end) (global.get $source-base))
                                            (i32.const 0) (i32.const 7) (i32.const 0)))))
                (if (i32.eqz (call $token-eq (i32.const 51) (i32.const 1)))
                  (then (return (call $fail (i32.const 2)
                                            (i32.sub (global.get $token-ptr) (global.get $source-base))
                                            (global.get $token-len) (i32.const 7) (i32.const 0)))))
                ;; Parameter list up to --.
                (block $params-done
                  (loop $params-loop
                    (if (i32.eqz (call $next-token))
                      (then (return (call $fail (i32.const 2)
                                                (i32.sub (global.get $source-end) (global.get $source-base))
                                                (i32.const 0) (i32.const 8) (i32.const 0)))))
                    (br_if $params-done (call $token-eq (i32.const 55) (i32.const 2)))
                    (if (i32.eqz (call $token-eq (i32.const 58) (i32.const 3)))
                      (then (return (call $fail (i32.const 12)
                                                (i32.sub (global.get $token-ptr) (global.get $source-base))
                                                (global.get $token-len) (i32.const 127) (i32.const 0)))))
                    (local.set $params (i32.add (local.get $params) (i32.const 1)))
                    (if (i32.gt_u (local.get $params) (i32.const 1024))
                      (then (return (call $fail (i32.const 10) (local.get $offset)
                                                (global.get $token-len) (i32.const 1024)
                                                (local.get $params)))))
                    (br $params-loop)))
                ;; Result list up to ).
                (block $results-done
                  (loop $results-loop
                    (if (i32.eqz (call $next-token))
                      (then (return (call $fail (i32.const 2)
                                                (i32.sub (global.get $source-end) (global.get $source-base))
                                                (i32.const 0) (i32.const 9) (i32.const 0)))))
                    (br_if $results-done (call $token-eq (i32.const 53) (i32.const 1)))
                    (if (i32.eqz (call $token-eq (i32.const 58) (i32.const 3)))
                      (then (return (call $fail (i32.const 12)
                                                (i32.sub (global.get $token-ptr) (global.get $source-base))
                                                (global.get $token-len) (i32.const 127) (i32.const 0)))))
                    (local.set $results (i32.add (local.get $results) (i32.const 1)))
                    (if (i32.gt_u (local.get $results) (i32.const 1024))
                      (then (return (call $fail (i32.const 10) (local.get $offset)
                                                (global.get $token-len) (i32.const 1024)
                                                (local.get $results)))))
                    (br $results-loop)))
                (i32.store offset=12 (local.get $r) (local.get $params))
                (i32.store offset=16 (local.get $r) (local.get $results))
                (global.set $body-start
                  (call $alloc
                    (i32.add
                      (i32.mul
                        (i32.sub (global.get $source-end) (global.get $scan))
                        (i32.const 2))
                      (i32.const 32))))
                (if (i32.eqz (global.get $body-start))
                  (then (return (call $fail (i32.const 11) (local.get $offset)
                                            (i32.const 0) (i32.const 0) (i32.const 0)))))
                (global.set $body-cursor (global.get $body-start))
                (global.set $depth (local.get $params))
                (global.set $body-items (i32.const 0))
                (global.set $locals (i32.const 0))
                (global.set $repl-def (i32.const 0))
                ;; Make declared parameters available on the real operand stack.
                (local.set $i (i32.const 0))
                (loop $param-gets
                  (if (i32.lt_u (local.get $i) (local.get $params))
                    (then
                      (call $emit-byte (i32.const 32))
                      (call $emit-uleb (local.get $i))
                      (local.set $i (i32.add (local.get $i) (i32.const 1)))
                      (br $param-gets))))
                (global.set $in-def (i32.const 1))
                (br $tokens)))
            (if (call $token-eq (i32.const 36) (i32.const 6))
              (then
                (if (i32.eqz (call $next-token))
                  (then (return (call $fail (i32.const 2)
                                            (i32.sub (global.get $source-end) (global.get $source-base))
                                            (i32.const 0) (i32.const 1) (i32.const 0)))))
                (local.set $found (call $find-def))
                (if (i32.eq (local.get $found) (i32.const -1))
                  (then (return (call $fail (i32.const 7)
                                            (i32.sub (global.get $token-ptr) (global.get $source-base))
                                            (global.get $token-len) (i32.const 3) (i32.const 0)))))
                (br $tokens)))
            ;; Any other top-level token starts an ephemeral nullary function.
            ;; Rewind so the ordinary definition-body compiler handles it.
            (if (i32.ge_u (global.get $defs) (i32.const 240))
              (then (return (call $fail (i32.const 10) (local.get $offset)
                                        (global.get $token-len) (i32.const 240)
                                        (global.get $defs)))))
            (global.set $current (global.get $defs))
            (local.set $r (call $record (global.get $current)))
            (i32.store (local.get $r) (i32.const 82))
            (i32.store offset=4 (local.get $r) (i32.const 6))
            (i32.store offset=8 (local.get $r)
              (i32.add (global.get $current) (i32.const 16)))
            (i32.store offset=12 (local.get $r) (i32.const 0))
            (i32.store offset=16 (local.get $r) (i32.const 0))
            (global.set $defs (i32.add (global.get $defs) (i32.const 1)))
            (global.set $body-start
              (call $alloc
                (i32.add
                  (i32.mul
                    (i32.sub (global.get $source-end) (global.get $token-ptr))
                    (i32.const 2))
                  (i32.const 32))))
            (if (i32.eqz (global.get $body-start))
              (then (return (call $fail (i32.const 11) (local.get $offset)
                                        (i32.const 0) (i32.const 0) (i32.const 0)))))
            (global.set $body-cursor (global.get $body-start))
            (global.set $depth (i32.const 0))
            (global.set $body-items (i32.const 0))
            (global.set $locals (i32.const 0))
            (global.set $repl-def (i32.const 1))
            (global.set $in-def (i32.const 1))
            (global.set $scan (global.get $token-ptr))
            (br $tokens)))

        ;; Definition body.
        (if (call $token-eq (i32.const 32) (i32.const 1))
          (then (return (call $fail (i32.const 3) (local.get $offset)
                                    (global.get $token-len) (i32.const 2) (i32.const 1)))))
        (if (call $token-eq (i32.const 34) (i32.const 1))
          (then
            (local.set $r (call $record (global.get $current)))
            (if (i32.eqz (global.get $body-items))
              (then (return (call $fail (i32.const 6) (local.get $offset)
                                        (global.get $token-len) (i32.const 5) (i32.const 0)))))
            (if (i32.ne (global.get $depth) (i32.load offset=16 (local.get $r)))
              (then (return (call $fail (i32.const 13) (local.get $offset)
                                        (global.get $token-len)
                                        (i32.load offset=16 (local.get $r))
                                        (global.get $depth)))))
            (i32.store offset=20 (local.get $r) (i32.const 1))
            (global.set $in-def (i32.const 0))
            (return (call $finish-module))))
        (local.set $found (call $find-primitive))
        (if (i32.ne (local.get $found) (i32.const -1))
          (then
            (local.get $offset)
            (local.get $found)
            (call_indirect (type $compiler-action))
            (local.set $actual)
            (local.set $expected)
            (local.set $classification)
            (if (local.get $classification)
              (then (return (call $fail (local.get $classification)
                                        (select
                                          (i32.sub (global.get $source-end) (global.get $source-base))
                                          (i32.sub (global.get $token-ptr) (global.get $source-base))
                                          (i32.eqz (global.get $token-len)))
                                        (global.get $token-len) (local.get $expected)
                                        (local.get $actual)))))
            (br $tokens)))
        (local.set $found (call $find-local-op (i32.const 0)))
        (if (i32.ne (local.get $found) (i32.const -1))
          (then
            (local.set $r (call $local-record (local.get $found)))
            (global.set $action-data (local.get $r))
            (local.get $offset)
            (i32.const 2)
            (call_indirect (type $compiler-action))
            (local.set $actual)
            (local.set $expected)
            (local.set $classification)
            (if (local.get $classification)
              (then (return (call $fail (local.get $classification)
                                        (select
                                          (i32.sub (global.get $source-end) (global.get $source-base))
                                          (i32.sub (global.get $token-ptr) (global.get $source-base))
                                          (i32.eqz (global.get $token-len)))
                                        (global.get $token-len) (local.get $expected)
                                        (local.get $actual)))))
            (br $tokens)))
        (local.set $found (call $find-local-op (i32.const 2)))
        (if (i32.ne (local.get $found) (i32.const -1))
          (then
            (local.set $r (call $local-record (local.get $found)))
            (global.set $action-data (local.get $r))
            (local.get $offset)
            (i32.const 4)
            (call_indirect (type $compiler-action))
            (local.set $actual)
            (local.set $expected)
            (local.set $classification)
            (if (local.get $classification)
              (then (return (call $fail (local.get $classification)
                                        (select
                                          (i32.sub (global.get $source-end) (global.get $source-base))
                                          (i32.sub (global.get $token-ptr) (global.get $source-base))
                                          (i32.eqz (global.get $token-len)))
                                        (global.get $token-len) (local.get $expected)
                                        (local.get $actual)))))
            (br $tokens)))
        (local.set $found (call $find-local-op (i32.const 1)))
        (if (i32.ne (local.get $found) (i32.const -1))
          (then
            (local.set $r (call $local-record (local.get $found)))
            (global.set $action-data (local.get $r))
            (local.get $offset)
            (i32.const 3)
            (call_indirect (type $compiler-action))
            (local.set $actual)
            (local.set $expected)
            (local.set $classification)
            (if (local.get $classification)
              (then (return (call $fail (local.get $classification)
                                        (select
                                          (i32.sub (global.get $source-end) (global.get $source-base))
                                          (i32.sub (global.get $token-ptr) (global.get $source-base))
                                          (i32.eqz (global.get $token-len)))
                                        (global.get $token-len) (local.get $expected)
                                        (local.get $actual)))))
            (br $tokens)))
        (local.set $found (call $find-local))
        (if (i32.ne (local.get $found) (i32.const -1))
          (then (return (call $fail (i32.const 16) (local.get $offset)
                                    (global.get $token-len) (i32.const 3) (i32.const 0)))))
        (call $parse-int)
        (local.set $number)
        (local.set $classification)
        (if (i32.eq (local.get $classification) (i32.const 2))
          (then (return (call $fail (i32.const 8) (local.get $offset)
                                    (global.get $token-len) (i32.const 6) (i32.const 0)))))
        (if (i32.eq (local.get $classification) (i32.const 1))
          (then
            (if (i32.ge_u (global.get $depth) (i32.const 1024))
              (then (return (call $fail (i32.const 10) (local.get $offset)
                                        (global.get $token-len) (i32.const 1024)
                                        (global.get $depth)))))
            (call $emit-byte (i32.const 65))
            (call $emit-sleb (local.get $number))
            (global.set $depth (i32.add (global.get $depth) (i32.const 1)))
            (global.set $body-items (i32.add (global.get $body-items) (i32.const 1)))
            (br $tokens)))
        (local.set $found (call $find-def))
        (if (i32.ne (local.get $found) (i32.const -1))
          (then
            (local.set $r (call $record (local.get $found)))
            (if (i32.lt_u (global.get $depth) (i32.load offset=12 (local.get $r)))
              (then (return (call $fail (i32.const 5) (local.get $offset)
                                        (global.get $token-len)
                                        (i32.load offset=12 (local.get $r))
                                        (global.get $depth)))))
            (global.set $depth
              (i32.add
                (i32.sub (global.get $depth) (i32.load offset=12 (local.get $r)))
                (i32.load offset=16 (local.get $r))))
            (if (i32.gt_u (global.get $depth) (i32.const 1024))
              (then (return (call $fail (i32.const 10) (local.get $offset)
                                        (global.get $token-len) (i32.const 1024)
                                        (global.get $depth)))))
            (if (i32.eq (local.get $found) (global.get $current))
              (then
                ;; The current extension owns function index zero.
                (call $emit-byte (i32.const 16))
                (call $emit-byte (i32.const 0)))
              (else
                (call $emit-byte (i32.const 65))
                (call $emit-sleb (i32.load offset=8 (local.get $r)))
                (call $emit-byte (i32.const 17))
                (call $emit-uleb (local.get $found))
                (call $emit-byte (i32.const 0))))
            (global.set $body-items (i32.add (global.get $body-items) (i32.const 1)))
            (br $tokens)))
        (if (i32.and
              (i32.ne (global.get $token-len) (i32.const 0))
              (i32.or
                (i32.eq (i32.load8_u (global.get $token-ptr)) (i32.const 33))
                (i32.eq (i32.load8_u (global.get $token-ptr)) (i32.const 64))))
          (then (return (call $fail (i32.const 15) (local.get $offset)
                                    (global.get $token-len) (i32.const 1) (i32.const 0)))))
        (return (call $fail (i32.const 4) (local.get $offset)
                            (global.get $token-len) (i32.const 4) (i32.const 0)))))
    (if (global.get $in-def)
      (then
        (if (global.get $repl-def)
          (then
            (local.set $r (call $record (global.get $current)))
            (if (i32.eqz (global.get $body-items))
              (then (return (call $fail (i32.const 6)
                                        (i32.sub (global.get $source-end) (global.get $source-base))
                                        (i32.const 0) (i32.const 1) (i32.const 0)))))
            (i32.store offset=16 (local.get $r) (global.get $depth))
            (i32.store offset=20 (local.get $r) (i32.const 1))
            (global.set $in-def (i32.const 0))
            (global.set $pending-run (i32.const 1))
            (return (call $finish-module))))
        (return (call $fail (i32.const 2)
                           (i32.sub (global.get $source-end) (global.get $source-base))
                           (i32.const 0) (i32.const 2) (i32.const 0)))))
    (if (global.get $pending-run)
      (then
        (global.set $pending-run (i32.const 0))
        (global.set $defs (global.get $current))
        (return
          (i32.const 2)
          (i32.add (global.get $current) (i32.const 16))
          (global.get $depth))))
    (i32.const 0) (i32.const 0) (i32.const 0))

  (func $compile (export "compile") (param $source i32) (param $length i32)
    (result i32 i32 i32)
    (if (i32.or
          (i32.eqz (local.get $source))
          (i32.or
            (i32.gt_u (local.get $length) (i32.const 1048576))
            (i32.or
              (i32.lt_u (i32.add (local.get $source) (local.get $length)) (local.get $source))
              (i32.gt_u (i32.add (local.get $source) (local.get $length))
                        (i32.shl (memory.size) (i32.const 16))))))
      (then (return (call $fail (i32.const 11) (i32.const 0) (i32.const 0)
                                (i32.const 0) (i32.const 0)))))
    (global.set $source-base (local.get $source))
    (global.set $scan (local.get $source))
    (global.set $source-end (i32.add (local.get $source) (local.get $length)))
    (global.set $in-def (i32.const 0))
    (call $run))

  (func (export "resume") (result i32 i32 i32)
    (call $run))

  ;; Compiler actions and generated runtime functions intentionally share one
  ;; heterogeneous table. Runtime definitions start at slot 16.
  (elem (i32.const 0) $compile-add $declare-local $compile-local-get
        $compile-local-set $compile-local-tee)
)
