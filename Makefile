WAT2WASM ?= wat2wasm
WEB_PORT ?= 8000
BROWSER ?= chromium

.PHONY: all test test-node test-runtimes test-wasmi test-wasmtime test-browser test-browser-all repl-wasmi repl-wasmtime web clean

all: build/compiler.wasm

build/compiler.wasm: compiler/compiler.wat
	mkdir -p build
	$(WAT2WASM) $< -o $@

test: test-runtimes test-browser-all

test-node: build/compiler.wasm
	node test/compiler.test.mjs

test-runtimes: test-node test-wasmi test-wasmtime

test-wasmi: build/compiler.wasm
	cargo build --locked --manifest-path test/runtimes/Cargo.toml --features wasmi --bin wasmi-repl
	node test/native-repl.test.mjs test/runtimes/target/debug/wasmi-repl wasmi

test-wasmtime: build/compiler.wasm
	cargo build --locked --manifest-path test/runtimes/Cargo.toml --features wasmtime --bin wasmtime-repl
	node test/native-repl.test.mjs test/runtimes/target/debug/wasmtime-repl wasmtime

repl-wasmi: build/compiler.wasm
	cargo run --locked --manifest-path test/runtimes/Cargo.toml --features wasmi --bin wasmi-repl

repl-wasmtime: build/compiler.wasm
	cargo run --locked --manifest-path test/runtimes/Cargo.toml --features wasmtime --bin wasmtime-repl

test-browser: build/compiler.wasm
	npx playwright test --project=$(BROWSER)

test-browser-all: build/compiler.wasm
	npx playwright test

web: build/compiler.wasm
	@url="http://127.0.0.1:$(WEB_PORT)/browser/"; \
	  python3 -m http.server "$(WEB_PORT)" --bind 127.0.0.1 & server=$$!; \
	  trap 'kill "$$server" 2>/dev/null || true; wait "$$server" 2>/dev/null || true' EXIT; \
	  trap 'exit 130' INT TERM; \
	  sleep 0.5; \
	  printf 'wasm-forth workspace: %s\nPress Ctrl+C to stop the server.\n' "$$url"; \
	  if command -v xdg-open >/dev/null 2>&1; then \
	    xdg-open "$$url" >/dev/null 2>&1 || true; \
	  elif command -v open >/dev/null 2>&1; then \
	    open "$$url" >/dev/null 2>&1 || true; \
	  fi; \
	  wait "$$server"

clean:
	rm -rf build
