const ERROR = 1;

export class ReplSession {
  constructor(compiler) {
    this.compiler = compiler;
    this.encoder = new TextEncoder();
    this.userDefinitions = Object.create(null);
    this.installations = [];
    this.execution = null;
    this.installError = null;
  }

  static async instantiate(bytes) {
    const bridge = { session: null };
    const { instance } = await WebAssembly.instantiate(bytes, {
      "wasm-forth:host": {
        install(pointer, length) {
          return bridge.session ? bridge.session.install(pointer, length) : 1;
        },
      },
    });
    bridge.session = new ReplSession(instance);
    return bridge.session;
  }

  reset() {
    this.userDefinitions = Object.create(null);
    this.installations = [];
    this.execution = null;
    this.installError = null;
    this.compiler.exports.reset();
  }

  install(pointer, length) {
    try {
      const { memory } = this.compiler.exports;
      const bytes = new Uint8Array(memory.buffer, pointer, length).slice();
      const module = new WebAssembly.Module(bytes);
      const instance = new WebAssembly.Instance(module, this.userDefinitions);
      if (typeof instance.exports.__repl === "function") {
        const value = instance.exports.__repl();
        this.execution = {
          resultCount: value === undefined ? 0 : Array.isArray(value) ? value.length : 1,
          value,
        };
      } else {
        for (const [name, value] of Object.entries(instance.exports)) {
          this.userDefinitions[`wasm-forth:user/${name}`] = { [name]: value };
        }
      }
      this.installations.push({
        bytes,
        module,
        instance,
        exportNames: Object.keys(instance.exports),
      });
      return 0;
    } catch (error) {
      this.installError = error;
      return 1;
    }
  }

  async submit(text) {
    const source = this.encoder.encode(text);
    const { memory, alloc, compile } = this.compiler.exports;
    const pointer = alloc(source.length);
    if (!pointer && source.length) throw new Error("compiler could not allocate the source buffer");
    new Uint8Array(memory.buffer, pointer, source.length).set(source);

    this.installations = [];
    this.execution = null;
    this.installError = null;
    const response = compile(pointer, source.length);
    if (this.installError) throw this.installError;
    if (!Array.isArray(response) || response.length !== 5) {
      throw new Error("compiler returned a malformed response");
    }
    const [status, payload, payloadLength, spanOffset, spanLength] = response;
    if (status !== 0 && status !== ERROR) {
      throw new Error(`compiler returned unknown status ${status}`);
    }

    const payloadBytes = status === ERROR && payloadLength
      ? new Uint8Array(memory.buffer, payload, payloadLength).slice()
      : new Uint8Array();
    return {
      status,
      payload,
      payloadLength,
      installations: this.installations,
      execution: this.execution,
      payloadBytes,
      spanOffset,
      spanLength,
    };
  }
}
