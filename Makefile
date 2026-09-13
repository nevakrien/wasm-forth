WAT2WASM ?= wat2wasm
WEB_PORT ?= 8000

.PHONY: all test web clean

all: build/compiler.wasm

build/compiler.wasm: compiler/compiler.wat
	mkdir -p build
	$(WAT2WASM) $< -o $@

test: build/compiler.wasm
	node test/compiler.test.mjs

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
