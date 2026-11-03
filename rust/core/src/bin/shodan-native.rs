//! First standalone Rust entry point: read-only LDLD inspection.
//! Does not load the compatibility host, DLLs, or Lua source files.
use serde_json::json;
use std::{env, fs, process::ExitCode};

fn run() -> Result<(), String> {
    let mut args = env::args_os().skip(1);
    if args.next().as_deref() != Some(std::ffi::OsStr::new("inspect")) {
        return Err("用法：shodan-native inspect <解密后的 .dl_plain 文件>".into());
    }
    let path = args.next().ok_or("缺少数据文件路径")?;
    if args.next().is_some() {
        return Err("参数过多".into());
    }
    let bytes = fs::read(&path).map_err(|e| format!("无法读取数据文件：{e}"))?;
    let blocks = shodan_core::dlbin::index(&bytes).map_err(|e| e.to_string())?;
    println!(
        "{}",
        json!({"runtime":"rust-native","read_only":true,"bytes":bytes.len(),
        "blocks":blocks.iter().map(|b|json!({"offset":b.header_offset,"type":format!("{:08X}",b.type_id),
            "payload_offset":b.payload.start,"payload_bytes":b.payload.len(),
            "original_header":b.has_original_header()})).collect::<Vec<_>>() })
    );
    Ok(())
}
fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}
