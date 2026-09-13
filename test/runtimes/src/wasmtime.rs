use std::{
    fs,
    io::{self, BufRead, IsTerminal, Write},
    path::PathBuf,
};

use anyhow::{Context, Result, ensure};
use wasmtime::{Engine, Linker, Memory, Module, Ref, Store, Table, TypedFunc};

const READY: i32 = 0;
const INSTALL: i32 = 1;
const RUN: i32 = 2;

struct Compiler {
    engine: Engine,
    store: Store<()>,
    memory: Memory,
    table: Table,
    reset: TypedFunc<(), ()>,
    alloc: TypedFunc<i32, i32>,
    compile: TypedFunc<(i32, i32), (i32, i32, i32)>,
    resume: TypedFunc<(), (i32, i32, i32)>,
}

impl Compiler {
    fn load() -> Result<Self> {
        let bytes = fs::read(compiler_path()).context("read build/compiler.wasm")?;
        let engine = Engine::default();
        let module = Module::new(&engine, bytes).context("compile compiler module")?;
        let mut store = Store::new(&engine, ());
        let instance = Linker::new(&engine).instantiate(&mut store, &module)?;
        let memory = instance
            .get_memory(&mut store, "memory")
            .context("missing memory export")?;
        let table = instance
            .get_table(&mut store, "table")
            .context("missing table export")?;
        let reset = instance.get_typed_func(&mut store, "reset")?;
        let alloc = instance.get_typed_func(&mut store, "alloc")?;
        let compile = instance.get_typed_func(&mut store, "compile")?;
        let resume = instance.get_typed_func(&mut store, "resume")?;
        Ok(Self {
            engine,
            store,
            memory,
            table,
            reset,
            alloc,
            compile,
            resume,
        })
    }

    fn reset(&mut self) -> Result<()> {
        self.reset.call(&mut self.store, ())?;
        Ok(())
    }

    fn compile_chunk(&mut self, source: &str) -> Result<(i32, i32, i32)> {
        let pointer = self.alloc.call(&mut self.store, source.len() as i32)?;
        ensure!(pointer != 0, "source allocation failed");
        self.memory
            .write(&mut self.store, pointer as usize, source.as_bytes())?;

        let mut response = self
            .compile
            .call(&mut self.store, (pointer, source.len() as i32))?;
        while response.0 == INSTALL {
            let mut bytes = vec![0; response.2 as usize];
            self.memory
                .read(&self.store, response.1 as usize, &mut bytes)?;
            let module = Module::new(&self.engine, bytes).context("compile extension module")?;
            let mut linker = Linker::new(&self.engine);
            linker.define(&mut self.store, "wasm-forth", "memory", self.memory)?;
            linker.define(&mut self.store, "wasm-forth", "table", self.table)?;
            linker.instantiate(&mut self.store, &module)?;
            response = self.resume.call(&mut self.store, ())?;
        }
        Ok(response)
    }

    fn call_slot(&mut self, slot: i32, result_count: i32) -> Result<Vec<i32>> {
        let reference = self
            .table
            .get(&mut self.store, slot as u64)
            .context("table slot is out of bounds")?;
        let Ref::Func(Some(function)) = reference else {
            anyhow::bail!("table slot is not a function");
        };
        let mut results = vec![wasmtime::Val::I32(0); result_count as usize];
        function.call(&mut self.store, &[], &mut results)?;
        results
            .into_iter()
            .map(|value| value.i32().context("REPL result is not i32"))
            .collect()
    }

    fn error_code(&mut self, response: (i32, i32, i32)) -> Result<u32> {
        ensure!(response.2 >= 12, "compiler returned a truncated error");
        let mut bytes = [0; 4];
        self.memory
            .read(&self.store, response.1 as usize + 8, &mut bytes)?;
        Ok(u32::from_le_bytes(bytes))
    }
}

fn compiler_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../build/compiler.wasm")
}

fn main() -> Result<()> {
    let mut compiler = Compiler::load()?;
    compiler.reset()?;
    let stdin = io::stdin();
    let interactive = stdin.is_terminal();
    let mut input = stdin.lock();
    if interactive {
        eprintln!("Wasmtime wasm-forth REPL; each line is one source chunk");
    }
    loop {
        if interactive {
            eprint!("wasmtime> ");
            io::stderr().flush()?;
        }
        let mut source = String::new();
        if input.read_line(&mut source)? == 0 {
            break;
        }
        if source.trim().is_empty() {
            continue;
        }
        let response = compiler.compile_chunk(&source)?;
        match response.0 {
            READY => println!("READY"),
            RUN => {
                let values = compiler.call_slot(response.1, response.2)?;
                print!("RUN");
                for value in values {
                    print!(" {value}");
                }
                println!();
            }
            status if status >= 256 => println!("ERROR {}", compiler.error_code(response)?),
            status => anyhow::bail!("unexpected compiler status {status}"),
        }
    }
    Ok(())
}
