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
    let session;
    const { instance } = await WebAssembly.instantiate(bytes, {
      "wasm-forth:host": {
        install(pointer, length) {
          return session.install(pointer, length);
        },
      },
    });
    session = new ReplSession(instance);
    return session;
  }

  reset() {
    this.userDefinitions = Object.create(null);
    this.execution = null;
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
          resultCount: Array.isArray(value) ? value.length : 1,
          value,
        };
      } else {
        for (const [name, value] of Object.entries(instance.exports)) {
          this.userDefinitions[`wasm-forth:user/${name}`] = { [name]: value };
        }
      }
      this.installations.push({ bytes, module, instance });
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

    const payloadBytes = response[0] === ERROR && response[2]
      ? new Uint8Array(memory.buffer, response[1], response[2]).slice()
      : new Uint8Array();
    let spanOffset = 0;
    let spanLength = 0;
    if (response[0] === ERROR && response[2]) {
      const spanView = new DataView(memory.buffer);
      spanOffset = spanView.getUint32(256, true);
      spanLength = spanView.getUint32(260, true);
    }
    return { response, installations: this.installations, execution: this.execution, payloadBytes, spanOffset, spanLength };
  }
}
