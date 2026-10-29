use std::{
    cell::{Cell, RefCell},
    collections::HashMap,
    ffi::c_void,
    ptr::NonNull,
    rc::Rc,
};

use rquickjs::{
    Array, ArrayBuffer, BigInt, Ctx, Exception, Function, Object, Persistent, Value,
    function::{Func, Opt, Rest},
    qjs,
};
use serde_json::{Value as Json, json};
use wasmi::{
    CompilationMode, Config, Engine, Error, Extern, ExternType, F32, F64, FuncType, Instance,
    Memory, Module, Nullable, Ref, Store, StoreLimits, StoreLimitsBuilder, Val, ValType,
};

const MEMORY: usize = 1 << 30;

struct Data {
    limits: StoreLimits,
    memory: Option<Memory>,
}

struct Slot {
    store: Store<Data>,
    instance: Option<Instance>,
}

type Shared = Rc<RefCell<Slot>>;

struct Cached {
    buffer: Persistent<Value<'static>>,
    pointer: usize,
    length: usize,
}

struct State {
    engine: Engine,
    modules: HashMap<u64, Module>,
    instances: HashMap<u64, Shared>,
    callbacks: HashMap<u64, Vec<Persistent<Function<'static>>>>,
    buffers: HashMap<(u64, String), Cached>,
    defaults: HashMap<u64, String>,
    next: u64,
}

impl State {
    fn new() -> Self {
        let mut config = Config::default();
        config.compilation_mode(CompilationMode::Lazy);
        Self {
            engine: Engine::new(&config),
            modules: HashMap::new(),
            instances: HashMap::new(),
            callbacks: HashMap::new(),
            buffers: HashMap::new(),
            defaults: HashMap::new(),
            next: 0,
        }
    }

    fn id(&mut self) -> u64 {
        self.next += 1;
        self.next
    }
}

thread_local! {
    static STATE: RefCell<State> = RefCell::new(State::new());
    static CONTEXT: Cell<Option<NonNull<qjs::JSContext>>> = const { Cell::new(None) };
    static THROWN: RefCell<Option<Persistent<Value<'static>>>> = const { RefCell::new(None) };
    static ACTIVE: Cell<Option<(u64, *mut u8, usize)>> = const { Cell::new(None) };
}

pub fn clear() {
    THROWN.with_borrow_mut(Option::take);
    STATE.with_borrow_mut(|state| {
        state.buffers.clear();
        state.defaults.clear();
        state.callbacks.clear();
        state.instances.clear();
        state.modules.clear();
    });
}

fn code(ty: &ValType) -> char {
    match ty {
        ValType::I32 => 'i',
        ValType::I64 => 'I',
        ValType::F32 => 'f',
        ValType::F64 => 'F',
        ValType::V128 => 'v',
        _ => 'r',
    }
}

fn types(codes: &str) -> Vec<ValType> {
    codes
        .chars()
        .map(|code| match code {
            'I' => ValType::I64,
            'f' => ValType::F32,
            'F' => ValType::F64,
            _ => ValType::I32,
        })
        .collect()
}

fn describe(ty: &ExternType) -> (&'static str, String, String) {
    match ty {
        ExternType::Func(func) => (
            "func",
            func.params().iter().map(code).collect(),
            func.results().iter().map(code).collect(),
        ),
        ExternType::Memory(_) => ("memory", String::new(), String::new()),
        ExternType::Table(_) => ("table", String::new(), String::new()),
        ExternType::Global(global) => {
            ("global", code(&global.content()).to_string(), String::new())
        }
    }
}

fn to_js<'js>(ctx: &Ctx<'js>, value: &Val) -> rquickjs::Result<Value<'js>> {
    Ok(match value {
        Val::I32(value) => Value::new_int(ctx.clone(), *value),
        Val::I64(value) => BigInt::from_i64(ctx.clone(), *value)?.into_value(),
        Val::F32(value) => Value::new_float(ctx.clone(), f64::from(f32::from(*value))),
        Val::F64(value) => Value::new_float(ctx.clone(), f64::from(*value)),
        _ => {
            return Err(Exception::throw_type(
                ctx,
                "only i32, i64, f32 and f64 values cross the WebAssembly boundary",
            ));
        }
    })
}

fn from_js<'js>(ctx: &Ctx<'js>, ty: &ValType, value: Value<'js>) -> rquickjs::Result<Val> {
    Ok(match ty {
        ValType::I32 => Val::I32(value.get::<f64>().map(|number| number as i64 as i32)?),
        ValType::I64 => Val::I64(value.get::<BigInt>()?.to_i64()?),
        ValType::F32 => Val::F32(F32::from(value.get::<f64>()? as f32)),
        ValType::F64 => Val::F64(F64::from(value.get::<f64>()?)),
        _ => {
            return Err(Exception::throw_type(
                ctx,
                "only i32, i64, f32 and f64 values cross the WebAssembly boundary",
            ));
        }
    })
}

fn zero(ty: &ValType) -> Val {
    match ty {
        ValType::I64 => Val::I64(0),
        ValType::F32 => Val::F32(F32::from(0.0)),
        ValType::F64 => Val::F64(F64::from(0.0)),
        ValType::FuncRef => Val::FuncRef(Nullable::Null),
        _ => Val::I32(0),
    }
}

unsafe extern "C" fn release(
    _runtime: *mut qjs::JSRuntime,
    opaque: *mut c_void,
    _pointer: *mut c_void,
    size: qjs::size_t,
) -> *mut c_void {
    if size == 0 && !opaque.is_null() {
        drop(unsafe { Rc::from_raw(opaque as *const RefCell<Slot>) });
    }
    std::ptr::null_mut()
}

fn detach<'js>(ctx: &Ctx<'js>, cached: Cached) {
    if let Ok(buffer) = cached.buffer.restore(ctx) {
        unsafe { qjs::JS_DetachArrayBuffer(ctx.as_raw().as_ptr(), buffer.as_raw()) };
    }
}

fn refresh<'js>(ctx: &Ctx<'js>, instance: u64, pointer: *mut u8, length: usize) {
    let stale: Vec<Cached> = STATE.with_borrow_mut(|state| {
        let keys: Vec<(u64, String)> = state
            .buffers
            .iter()
            .filter(|((id, _), cached)| {
                *id == instance && (cached.pointer != pointer as usize || cached.length != length)
            })
            .map(|(key, _)| key.clone())
            .collect();
        keys.iter()
            .filter_map(|key| state.buffers.remove(key))
            .collect()
    });
    for cached in stale {
        detach(ctx, cached);
    }
}

fn callback(
    instance: u64,
    index: usize,
    params: &[Val],
    outputs: &mut [Val],
    results: &[ValType],
) -> Result<(), Error> {
    let Some(raw) = CONTEXT.get() else {
        return Err(Error::new(
            "WebAssembly called the host outside of JavaScript",
        ));
    };
    let ctx = unsafe { Ctx::from_raw(raw) };
    if let Some((_, pointer, length)) = ACTIVE.get() {
        refresh(&ctx, instance, pointer, length);
    }
    let saved = STATE.with_borrow(|state| {
        state
            .callbacks
            .get(&instance)
            .and_then(|list| list.get(index))
            .cloned()
    });
    let Some(saved) = saved else {
        return Err(Error::new("the WebAssembly import is gone"));
    };
    let fail = |ctx: &Ctx<'_>, error: rquickjs::Error| {
        let thrown = match error {
            rquickjs::Error::Exception => ctx.catch(),
            other => Exception::from_message(ctx.clone(), &other.to_string())
                .map(Exception::into_value)
                .unwrap_or_else(|_| Value::new_undefined(ctx.clone())),
        };
        THROWN.set(Some(Persistent::save(ctx, thrown)));
        Error::new("host")
    };
    let function = saved.restore(&ctx).map_err(|error| fail(&ctx, error))?;
    let arguments = params
        .iter()
        .map(|value| to_js(&ctx, value))
        .collect::<rquickjs::Result<Vec<_>>>()
        .map_err(|error| fail(&ctx, error))?;
    let returned: Value = function
        .call((Rest(arguments),))
        .map_err(|error| fail(&ctx, error))?;
    let values: Array = returned.get().map_err(|error| fail(&ctx, error))?;
    for (index, (output, ty)) in outputs.iter_mut().zip(results).enumerate() {
        let value: Value = values.get(index).map_err(|error| fail(&ctx, error))?;
        *output = from_js(&ctx, ty, value).map_err(|error| fail(&ctx, error))?;
    }
    Ok(())
}

fn host(store: &mut Store<Data>, ty: FuncType, instance: u64, index: usize) -> wasmi::Func {
    let results: Vec<ValType> = ty.results().to_vec();
    wasmi::Func::new(store, ty, move |caller, params, outputs| {
        let memory = caller
            .data()
            .memory
            .or_else(|| match caller.get_export("memory") {
                Some(Extern::Memory(memory)) => Some(memory),
                _ => None,
            })
            .map(|memory| (memory.data_ptr(&caller), memory.data_size(&caller)));
        let previous = ACTIVE.replace(memory.map(|(pointer, length)| (instance, pointer, length)));
        let result = callback(instance, index, params, outputs, &results);
        ACTIVE.set(previous);
        result
    })
}

fn slot<'js>(ctx: &Ctx<'js>, id: u64) -> rquickjs::Result<Shared> {
    STATE
        .with_borrow(|state| state.instances.get(&id).cloned())
        .ok_or_else(|| Exception::throw_reference(ctx, "the WebAssembly instance is gone"))
}

fn busy<'js>(ctx: &Ctx<'js>) -> rquickjs::Error {
    Exception::throw_type(
        ctx,
        "this WebAssembly instance is running: an import cannot call back into it, grow its memory or change its tables",
    )
}

fn outcome<'js>(ctx: &Ctx<'js>, message: Option<String>) -> rquickjs::Result<Value<'js>> {
    if let Some(thrown) = THROWN.with_borrow_mut(Option::take) {
        return Err(ctx.throw(thrown.restore(ctx)?));
    }
    let object = Object::new(ctx.clone())?;
    object.set("trap", message.unwrap_or_else(|| "unreachable".to_owned()))?;
    Ok(object.into_value())
}

fn run<'js>(
    ctx: &Ctx<'js>,
    slot: &mut Slot,
    func: wasmi::Func,
    inputs: &[Val],
    outputs: &mut [Val],
) -> Option<String> {
    let previous = CONTEXT.replace(Some(ctx.as_raw()));
    let failure = func
        .call(&mut slot.store, inputs, outputs)
        .err()
        .map(|error| error.to_string());
    CONTEXT.set(previous);
    failure
}

fn memory_of(slot: &Slot, name: &str) -> Option<Memory> {
    let instance = slot.instance?;
    if name.is_empty() {
        return slot.store.data().memory;
    }
    instance.get_memory(&slot.store, name)
}

pub fn install<'js>(ctx: &Ctx<'js>) -> rquickjs::Result<()> {
    let wasm = Object::new(ctx.clone())?;
    wasm.set(
        "compile",
        Func::from(
            |ctx: Ctx<'js>,
             buffer: ArrayBuffer<'js>,
             offset: Opt<usize>,
             length: Opt<usize>|
             -> rquickjs::Result<String> {
                let bytes = super::view(&ctx, &buffer, offset, length)?;
                let compiled = STATE.with_borrow(|state| Module::new(&state.engine, bytes));
                let module = match compiled {
                    Ok(module) => module,
                    Err(error) => return Ok(json!({"error": error.to_string()}).to_string()),
                };
                let imports: Vec<Json> = module
                    .imports()
                    .map(|import| {
                        let (kind, params, results) = describe(import.ty());
                        json!([import.module(), import.name(), kind, params, results])
                    })
                    .collect();
                let exports: Vec<Json> = module
                    .exports()
                    .map(|export| {
                        let (kind, params, results) = describe(export.ty());
                        json!([export.name(), kind, params, results])
                    })
                    .collect();
                let id = STATE.with_borrow_mut(|state| {
                    let id = state.id();
                    state.modules.insert(id, module);
                    id
                });
                Ok(json!({"id": id, "imports": imports, "exports": exports}).to_string())
            },
        ),
    )?;
    wasm.set(
        "instantiate",
        Func::from(
            |ctx: Ctx<'js>, module: f64, functions: Array<'js>| -> rquickjs::Result<Value<'js>> {
                let (engine, module, id) = STATE.with_borrow_mut(|state| {
                    let id = state.id();
                    (
                        state.engine.clone(),
                        state.modules.get(&(module as u64)).cloned(),
                        id,
                    )
                });
                let module = module.ok_or_else(|| {
                    Exception::throw_reference(&ctx, "the WebAssembly module is gone")
                })?;
                let limits = StoreLimitsBuilder::new()
                    .memory_size(MEMORY)
                    .instances(1)
                    .build();
                let mut store = Store::new(
                    &engine,
                    Data {
                        limits,
                        memory: None,
                    },
                );
                store.limiter(|data| &mut data.limits);
                let link = |message: String| -> rquickjs::Result<Value<'js>> {
                    let object = Object::new(ctx.clone())?;
                    object.set("link", message)?;
                    Ok(object.into_value())
                };
                let mut saved = Vec::new();
                let mut externs = Vec::new();
                for (index, import) in module.imports().enumerate() {
                    let ExternType::Func(ty) = import.ty() else {
                        return link(format!(
                            "{}.{} imports a {}, and this host links only functions",
                            import.module(),
                            import.name(),
                            describe(import.ty()).0
                        ));
                    };
                    let Ok(function) = functions.get::<Function>(index) else {
                        return link(format!(
                            "{}.{} is not a function",
                            import.module(),
                            import.name()
                        ));
                    };
                    saved.push(Persistent::save(&ctx, function));
                    externs.push(Extern::Func(host(&mut store, ty.clone(), id, index)));
                }
                STATE.with_borrow_mut(|state| state.callbacks.insert(id, saved));
                let slot: Shared = Rc::new(RefCell::new(Slot {
                    store,
                    instance: None,
                }));
                STATE.with_borrow_mut(|state| state.instances.insert(id, Rc::clone(&slot)));
                let created = {
                    let mut borrowed = slot.borrow_mut();
                    let previous = CONTEXT.replace(Some(ctx.as_raw()));
                    let created = Instance::new(&mut borrowed.store, &module, &externs);
                    CONTEXT.set(previous);
                    created
                };
                match created {
                    Ok(instance) => {
                        let mut borrowed = slot.borrow_mut();
                        let found = instance
                            .get_memory(&borrowed.store, "memory")
                            .map(|memory| ("memory".to_owned(), memory))
                            .or_else(|| {
                                instance.exports(&borrowed.store).find_map(|export| {
                                    let name = export.name().to_owned();
                                    export.into_memory().map(|memory| (name, memory))
                                })
                            });
                        if let Some((name, _)) = &found {
                            STATE.with_borrow_mut(|state| state.defaults.insert(id, name.clone()));
                        }
                        borrowed.store.data_mut().memory = found.map(|(_, memory)| memory);
                        borrowed.instance = Some(instance);
                        let object = Object::new(ctx.clone())?;
                        object.set("id", id as f64)?;
                        Ok(object.into_value())
                    }
                    Err(error) => {
                        STATE.with_borrow_mut(|state| {
                            state.instances.remove(&id);
                            state.callbacks.remove(&id);
                        });
                        if THROWN.with_borrow(Option::is_some) || error.as_trap_code().is_some() {
                            return outcome(&ctx, Some(error.to_string()));
                        }
                        link(error.to_string())
                    }
                }
            },
        ),
    )?;
    wasm.set(
        "call",
        Func::from(
            |ctx: Ctx<'js>,
             id: f64,
             name: String,
             arguments: Array<'js>|
             -> rquickjs::Result<Value<'js>> {
                let id = id as u64;
                let shared = slot(&ctx, id)?;
                let Ok(mut borrowed) = shared.try_borrow_mut() else {
                    return Err(busy(&ctx));
                };
                let instance = borrowed.instance.ok_or_else(|| busy(&ctx))?;
                let func = instance.get_func(&borrowed.store, &name).ok_or_else(|| {
                    Exception::throw_type(&ctx, &format!("no exported function named {name}"))
                })?;
                let ty = func.ty(&borrowed.store);
                let mut inputs = Vec::with_capacity(ty.params().len());
                for (index, param) in ty.params().iter().enumerate() {
                    inputs.push(from_js(&ctx, param, arguments.get(index)?)?);
                }
                let mut outputs: Vec<Val> = ty.results().iter().map(zero).collect();
                let failure = run(&ctx, &mut borrowed, func, &inputs, &mut outputs);
                if let Some(memory) = borrowed.store.data().memory {
                    let (pointer, length) = (
                        memory.data_ptr(&borrowed.store),
                        memory.data_size(&borrowed.store),
                    );
                    drop(borrowed);
                    refresh(&ctx, id, pointer, length);
                } else {
                    drop(borrowed);
                }
                if failure.is_some() {
                    return outcome(&ctx, failure);
                }
                match outputs.len() {
                    0 => Ok(Value::new_undefined(ctx.clone())),
                    1 => to_js(&ctx, &outputs[0]),
                    _ => {
                        let array = Array::new(ctx.clone())?;
                        for (index, output) in outputs.iter().enumerate() {
                            array.set(index, to_js(&ctx, output)?)?;
                        }
                        Ok(array.into_value())
                    }
                }
            },
        ),
    )?;
    wasm.set(
        "memory",
        Func::from(
            |ctx: Ctx<'js>, id: f64, name: String| -> rquickjs::Result<Value<'js>> {
                let id = id as u64;
                let shared = slot(&ctx, id)?;
                let default = STATE.with_borrow(|state| {
                    state.defaults.get(&id).is_some_and(|known| *known == name)
                });
                let active = ACTIVE
                    .get()
                    .filter(|(instance, _, _)| *instance == id && (name.is_empty() || default));
                let (pointer, length) = match active {
                    Some((_, pointer, length)) => (pointer, length),
                    None => {
                        let Ok(borrowed) = shared.try_borrow() else {
                            return Err(busy(&ctx));
                        };
                        let memory = memory_of(&borrowed, &name).ok_or_else(|| {
                            Exception::throw_type(&ctx, "the module exports no such memory")
                        })?;
                        (
                            memory.data_ptr(&borrowed.store),
                            memory.data_size(&borrowed.store),
                        )
                    }
                };
                refresh(&ctx, id, pointer, length);
                let key = (id, name);
                if let Some(buffer) = STATE.with_borrow(|state| {
                    state.buffers.get(&key).map(|cached| cached.buffer.clone())
                }) {
                    return buffer.restore(&ctx);
                }
                let opaque = Rc::into_raw(Rc::clone(&shared)) as *mut c_void;
                let raw = unsafe {
                    qjs::JS_NewArrayBuffer(
                        ctx.as_raw().as_ptr(),
                        pointer,
                        length as qjs::size_t,
                        0,
                        Some(release),
                        opaque,
                        false,
                    )
                };
                let buffer = unsafe { Value::from_raw(ctx.clone(), raw) };
                if buffer.is_exception() {
                    drop(unsafe { Rc::from_raw(opaque as *const RefCell<Slot>) });
                    return Err(rquickjs::Error::Exception);
                }
                let cached = Cached {
                    buffer: Persistent::save(&ctx, buffer.clone()),
                    pointer: pointer as usize,
                    length,
                };
                STATE.with_borrow_mut(|state| state.buffers.insert(key, cached));
                Ok(buffer)
            },
        ),
    )?;
    wasm.set(
        "grow",
        Func::from(
            |ctx: Ctx<'js>, id: f64, name: String, pages: f64| -> rquickjs::Result<f64> {
                let id = id as u64;
                let shared = slot(&ctx, id)?;
                let Ok(mut borrowed) = shared.try_borrow_mut() else {
                    return Err(busy(&ctx));
                };
                let memory = memory_of(&borrowed, &name).ok_or_else(|| {
                    Exception::throw_type(&ctx, "the module exports no such memory")
                })?;
                let grown = memory.grow(&mut borrowed.store, pages.max(0.0) as u64);
                let (pointer, length) = (
                    memory.data_ptr(&borrowed.store),
                    memory.data_size(&borrowed.store),
                );
                drop(borrowed);
                refresh(&ctx, id, pointer, length);
                Ok(grown.map_or(-1.0, |old| old as f64))
            },
        ),
    )?;
    wasm.set(
        "global",
        Func::from(
            |ctx: Ctx<'js>,
             id: f64,
             name: String,
             value: Opt<Value<'js>>|
             -> rquickjs::Result<Value<'js>> {
                let shared = slot(&ctx, id as u64)?;
                let Ok(mut borrowed) = shared.try_borrow_mut() else {
                    return Err(busy(&ctx));
                };
                let instance = borrowed.instance.ok_or_else(|| busy(&ctx))?;
                let global = instance.get_global(&borrowed.store, &name).ok_or_else(|| {
                    Exception::throw_type(&ctx, &format!("no exported global named {name}"))
                })?;
                if let Some(value) = value.0 {
                    let ty = global.ty(&borrowed.store).content();
                    global
                        .set(&mut borrowed.store, from_js(&ctx, &ty, value)?)
                        .map_err(|error| Exception::throw_type(&ctx, &error.to_string()))?;
                }
                to_js(&ctx, &global.get(&borrowed.store))
            },
        ),
    )?;
    wasm.set(
        "tableSize",
        Func::from(
            |ctx: Ctx<'js>, id: f64, name: String| -> rquickjs::Result<f64> {
                let shared = slot(&ctx, id as u64)?;
                let Ok(borrowed) = shared.try_borrow() else {
                    return Err(busy(&ctx));
                };
                let instance = borrowed.instance.ok_or_else(|| busy(&ctx))?;
                let table = instance.get_table(&borrowed.store, &name).ok_or_else(|| {
                    Exception::throw_type(&ctx, &format!("no exported table named {name}"))
                })?;
                Ok(table.size(&borrowed.store) as f64)
            },
        ),
    )?;
    wasm.set(
        "tableSet",
        Func::from(
            |ctx: Ctx<'js>,
             id: f64,
             name: String,
             index: f64,
             function: Function<'js>,
             target: Object<'js>|
             -> rquickjs::Result<()> {
                let source: f64 = target.get("instance")?;
                let export: String = target.get("name")?;
                let params: String = target.get("params")?;
                let results: String = target.get("results")?;
                let id = id as u64;
                let shared = slot(&ctx, id)?;
                let Ok(mut borrowed) = shared.try_borrow_mut() else {
                    return Err(busy(&ctx));
                };
                let instance = borrowed.instance.ok_or_else(|| busy(&ctx))?;
                let table = instance.get_table(&borrowed.store, &name).ok_or_else(|| {
                    Exception::throw_type(&ctx, &format!("no exported table named {name}"))
                })?;
                let func = if source as u64 == id {
                    instance.get_func(&borrowed.store, &export).ok_or_else(|| {
                        Exception::throw_type(&ctx, &format!("no exported function named {export}"))
                    })?
                } else {
                    let position = STATE.with_borrow_mut(|state| {
                        let list = state.callbacks.entry(id).or_default();
                        list.push(Persistent::save(&ctx, function));
                        list.len() - 1
                    });
                    let ty = FuncType::new(types(&params), types(&results));
                    host(&mut borrowed.store, ty, id, position)
                };
                table
                    .set(
                        &mut borrowed.store,
                        index.max(0.0) as u64,
                        Ref::Func(Nullable::Val(func)),
                    )
                    .map_err(|error| Exception::throw_range(&ctx, &error.to_string()))
            },
        ),
    )?;
    wasm.set(
        "release",
        Func::from(|kind: String, id: f64| {
            let id = id as u64;
            let stale: Vec<Cached> = STATE.with_borrow_mut(|state| {
                if kind == "module" {
                    state.modules.remove(&id);
                    return Vec::new();
                }
                state.instances.remove(&id);
                state.callbacks.remove(&id);
                state.defaults.remove(&id);
                let keys: Vec<(u64, String)> = state
                    .buffers
                    .keys()
                    .filter(|key| key.0 == id)
                    .cloned()
                    .collect();
                keys.iter()
                    .filter_map(|key| state.buffers.remove(key))
                    .collect()
            });
            drop(stale);
        }),
    )?;
    ctx.globals().set("__wasm", wasm)
}
