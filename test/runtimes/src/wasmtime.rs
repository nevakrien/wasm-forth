use std::{
    collections::HashMap,
    fs,
    io::{self, BufRead, IsTerminal, Write},
    ops::Range,
    path::PathBuf,
};

use anyhow::{Context, Result, ensure};
use ariadne::{Color, Config, Label, Report, ReportKind, Source};
use wasmtime::{Caller, Engine, Extern, Linker, Memory, Module, Store, TypedFunc};

const READY: i32 = 0;
const ERROR: i32 = 1;

#[derive(Default)]
struct HostState {
    user_definitions: HashMap<String, Extern>,
    execution: Option<Vec<i32>>,
    install_error: Option<String>,
}

struct Compiler {
    store: Store<HostState>,
    memory: Memory,
    reset: TypedFunc<(), ()>,
    alloc: TypedFunc<i32, i32>,
    compile: TypedFunc<(i32, i32), (i32, i32, i32, i32, i32)>,
}

impl Compiler {
    fn load() -> Result<Self> {
        let bytes = fs::read(compiler_path()).context("read build/compiler.wasm")?;
        let engine = Engine::default();
        let module = Module::new(&engine, bytes).context("compile compiler module")?;
        let mut store = Store::new(&engine, HostState::default());
        let mut linker = Linker::new(&engine);
        let host_engine = engine.clone();
        linker.func_wrap(
            "wasm-forth:host",
            "install",
            move |mut caller: Caller<'_, HostState>, pointer: i32, length: i32| {
                let result = install_extension(&host_engine, &mut caller, pointer, length);
                match result {
                    Ok(()) => 0,
                    Err(error) => {
                        caller.data_mut().install_error = Some(format!("{error:#}"));
                        1
                    }
                }
            },
        )?;
        let instance = linker.instantiate(&mut store, &module)?;
        let memory = instance
            .get_memory(&mut store, "memory")
            .context("missing memory export")?;
        let reset = instance.get_typed_func(&mut store, "reset")?;
        let alloc = instance.get_typed_func(&mut store, "alloc")?;
        let compile = instance.get_typed_func(&mut store, "compile")?;
        Ok(Self {
            store,
            memory,
            reset,
            alloc,
            compile,
        })
    }

    fn reset(&mut self) -> Result<()> {
        self.store.data_mut().user_definitions.clear();
        self.store.data_mut().execution = None;
        self.reset.call(&mut self.store, ())?;
        Ok(())
    }

    fn compile_chunk(&mut self, source: &str) -> Result<(i32, i32, i32, i32, i32)> {
        let pointer = self.alloc.call(&mut self.store, source.len() as i32)?;
        ensure!(pointer != 0, "source allocation failed");
        self.memory
            .write(&mut self.store, pointer as usize, source.as_bytes())?;

        self.store.data_mut().execution = None;
        self.store.data_mut().install_error = None;
        let response = self
            .compile
            .call(&mut self.store, (pointer, source.len() as i32))?;
        if let Some(error) = self.store.data_mut().install_error.take() {
            anyhow::bail!("install extension module: {error}");
        }
        Ok(response)
    }

    fn error_message(&mut self, response: (i32, i32, i32, i32, i32)) -> Result<String> {
        let mut bytes = vec![0; response.2 as usize];
        self.memory
            .read(&self.store, response.1 as usize, &mut bytes)?;
        String::from_utf8(bytes).context("compiler error is not UTF-8")
    }
}

fn install_extension(
    engine: &Engine,
    caller: &mut Caller<'_, HostState>,
    pointer: i32,
    length: i32,
) -> Result<()> {
    ensure!(pointer >= 0 && length >= 0, "invalid extension byte range");
    let memory = caller
        .get_export("memory")
        .and_then(Extern::into_memory)
        .context("missing compiler memory")?;
    let mut bytes = vec![0; length as usize];
    memory.read(&*caller, pointer as usize, &mut bytes)?;
    let module = Module::new(engine, bytes).context("compile extension module")?;
    let mut linker = Linker::new(engine);
    let definitions = caller.data().user_definitions.clone();
    for (name, value) in definitions {
        linker.define(
            &mut *caller,
            &format!("wasm-forth:user/{name}"),
            &name,
            value,
        )?;
    }
    let instance = linker.instantiate(&mut *caller, &module)?;
    for export in module.exports() {
        let name = export.name().to_owned();
        let value = instance
            .get_export(&mut *caller, &name)
            .context("missing declared extension export")?;
        if name == "__repl" {
            let function = value
                .into_func()
                .context("__repl export is not a function")?;
            let result_count = function.ty(&*caller).results().len();
            let mut results = vec![wasmtime::Val::I32(0); result_count];
            function.call(&mut *caller, &[], &mut results)?;
            caller.data_mut().execution = Some(
                results
                    .into_iter()
                    .map(|value| value.i32().context("REPL result is not i32"))
                    .collect::<Result<_>>()?,
            );
        } else {
            caller.data_mut().user_definitions.insert(name, value);
        }
    }
    Ok(())
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
            READY => {
                if let Some(values) = compiler.store.data_mut().execution.take() {
                    print!("RUN");
                    for value in values {
                        print!(" {value}");
                    }
                    println!();
                } else {
                    println!("READY");
                }
            }
            ERROR => {
                let (off, sp) = (response.3 as usize, response.4 as usize);
                let message = compiler.error_message(response)?;
                if sp > 0 {
                    let src = source.trim_end();
                    ensure!(
                        off + sp <= src.len()
                            && src.is_char_boundary(off)
                            && src.is_char_boundary(off + sp),
                        "compiler returned an invalid UTF-8 byte span"
                    );
                    let start = src[..off].chars().count();
                    let end = start + src[off..off + sp].chars().count();
                    let span: Range<usize> = start..end;
                    Report::build(ReportKind::Error, (), start)
                        .with_config(Config::default().with_color(interactive))
                        .with_label(Label::new(span).with_color(Color::Red))
                        .with_message(&message)
                        .finish()
                        .write(Source::from(src), io::stderr())
                        .unwrap();
                }
                println!("ERROR {message}");
            }
            status => anyhow::bail!("unexpected compiler status {status}"),
        }
    }
    Ok(())
}
