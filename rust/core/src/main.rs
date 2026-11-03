#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use serde_json::{json, Value};
use std::{
    ffi::{c_void, CStr, CString},
    io::{self, BufRead, Write},
    path::PathBuf,
};
#[link(name = "kernel32")]
unsafe extern "system" {
    fn LoadLibraryW(p: *const u16) -> *mut c_void;
    fn GetProcAddress(h: *mut c_void, p: *const i8) -> *mut c_void;
}
type State = *mut c_void;
struct Lua {
    state: State,
    load: unsafe extern "C" fn(State, *const i8) -> i32,
    call: unsafe extern "C" fn(State, i32, i32, i32) -> i32,
    text: unsafe extern "C" fn(State, i32, *mut usize) -> *const i8,
    top: unsafe extern "C" fn(State, i32),
    close: unsafe extern "C" fn(State),
}
impl Drop for Lua {
    fn drop(&mut self) {
        unsafe { (self.close)(self.state) }
    }
}
impl Lua {
    unsafe fn new(root: &PathBuf) -> Result<Self, String> {
        let path: Vec<u16> = root
            .join("lua51.dll")
            .to_string_lossy()
            .encode_utf16()
            .chain(Some(0))
            .collect();
        let lib = LoadLibraryW(path.as_ptr());
        if lib.is_null() {
            return Err("无法加载 lua51.dll".into());
        }
        macro_rules! symbol {
            ($name:literal,$ty:ty) => {{
                let ptr = GetProcAddress(lib, concat!($name, "\0").as_ptr() as _);
                if ptr.is_null() {
                    return Err(format!("缺少接口 {}", $name));
                }
                std::mem::transmute::<*mut c_void, $ty>(ptr)
            }};
        }
        let new = symbol!("luaL_newstate", unsafe extern "C" fn() -> State);
        let state = new();
        if state.is_null() {
            return Err("无法创建数据引擎".into());
        }
        let open = symbol!("luaL_openlibs", unsafe extern "C" fn(State));
        open(state);
        Ok(Self {
            state,
            load: symbol!(
                "luaL_loadstring",
                unsafe extern "C" fn(State, *const i8) -> i32
            ),
            call: symbol!(
                "lua_pcall",
                unsafe extern "C" fn(State, i32, i32, i32) -> i32
            ),
            text: symbol!(
                "lua_tolstring",
                unsafe extern "C" fn(State, i32, *mut usize) -> *const i8
            ),
            top: symbol!("lua_settop", unsafe extern "C" fn(State, i32)),
            close: symbol!("lua_close", unsafe extern "C" fn(State)),
        })
    }
    fn eval(&mut self, code: &str) -> Result<String, String> {
        unsafe {
            let code = CString::new(code).map_err(|_| "请求包含空字节")?;
            let status = (self.load)(self.state, code.as_ptr());
            let status = if status == 0 {
                (self.call)(self.state, 0, 1, 0)
            } else {
                status
            };
            let ptr = (self.text)(self.state, -1, std::ptr::null_mut());
            let result = if ptr.is_null() {
                String::new()
            } else {
                CStr::from_ptr(ptr).to_string_lossy().into_owned()
            };
            (self.top)(self.state, 0);
            if status == 0 {
                Ok(result)
            } else {
                Err(result)
            }
        }
    }
}
fn literal(v: &Value) -> String {
    match v {
        Value::Null => "nil".into(),
        Value::Bool(x) => x.to_string(),
        Value::Number(x) => x.to_string(),
        Value::String(s) => {
            let mut out = String::from("\"");
            for b in s.bytes() {
                out.push_str(&format!("\\{:03}", b))
            }
            out.push('"');
            out
        }
        Value::Array(a) => format!(
            "{{{}}}",
            a.iter().map(literal).collect::<Vec<_>>().join(",")
        ),
        Value::Object(o) => format!(
            "{{{}}}",
            o.iter()
                .map(|(k, v)| format!("[{}]={}", literal(&json!(k)), literal(v)))
                .collect::<Vec<_>>()
                .join(",")
        ),
    }
}
fn run() -> Result<(), String> {
    let root = std::env::args().nth(1).map(PathBuf::from).unwrap_or(
        std::env::current_exe()
            .map_err(|e| e.to_string())?
            .parent()
            .unwrap()
            .to_owned(),
    );
    std::env::set_current_dir(&root).map_err(|e| e.to_string())?;
    let mut lua = unsafe { Lua::new(&root)? };
    lua.eval(include_str!("bridge.lua"))?;
    let mut out = io::stdout().lock();
    let mut output_ok = true;
    for line in io::stdin().lock().lines() {
        let line = line.map_err(|e| e.to_string())?;
        let req: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(e) => {
                writeln!(out, "{}", json!({"error":e.to_string()})).map_err(|e| e.to_string())?;
                continue;
            }
        };
        let id = req["id"].clone();
        let method = req["method"].as_str().unwrap_or("");
        if method == "shutdown" {
            lua.eval("API.flush();return ''")?;
            break;
        }
        let args = req.get("args").cloned().unwrap_or(json!([]));
        let code = format!(
            "return invoke({}, {})",
            literal(&json!(method)),
            literal(&args)
        );
        let response = match lua
            .eval(&code)
            .and_then(|s| serde_json::from_str::<Value>(&s).map_err(|e| e.to_string()))
        {
            Ok(data) => json!({"id":id,"data":data}),
            Err(error) => json!({"id":id,"error":error}),
        };
        if output_ok {
            output_ok = writeln!(out, "{response}")
                .and_then(|_| out.flush())
                .is_ok();
        }
    }
    lua.eval("API.flush();return ''")?;
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1)
    }
}
