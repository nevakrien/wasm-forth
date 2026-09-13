const INSTALL = 1;
const RUN = 2;

export class ReplSession {
  constructor(compiler) {
    this.compiler = compiler;
    this.encoder = new TextEncoder();
  }

  reset() {
    this.compiler.exports.reset();
  }

  async submit(text) {
    const source = this.encoder.encode(text);
    const { memory, table, alloc, compile, resume } = this.compiler.exports;
    const pointer = alloc(source.length);
    if (!pointer && source.length) throw new Error("compiler could not allocate the source buffer");
    new Uint8Array(memory.buffer, pointer, source.length).set(source);

    const installations = [];
    let response = compile(pointer, source.length);
    while (response[0] === INSTALL) {
      const bytes = new Uint8Array(memory.buffer, response[1], response[2]).slice();
      const module = await WebAssembly.compile(bytes);
      const instance = await WebAssembly.instantiate(module, {
        "wasm-forth": { memory, table },
      });
      installations.push({ bytes, module, instance });
      response = resume();
    }

    let execution = null;
    if (response[0] === RUN) {
      const callable = table.get(response[1]);
      if (typeof callable !== "function") {
        throw new Error(`RUN table slot ${response[1]} is not callable`);
      }
      execution = {
        slot: response[1],
        resultCount: response[2],
        value: callable(),
      };
    }

    const payloadBytes = response[0] >= 256 && response[2]
      ? new Uint8Array(memory.buffer, response[1], response[2]).slice()
      : new Uint8Array();
    return { response, installations, execution, payloadBytes };
  }
}
