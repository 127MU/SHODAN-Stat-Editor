//! Standalone Rust codec and read-only LDLD inspection.
//! Does not load the compatibility host, DLLs, or Lua source files.
use serde_json::json;
use std::{env, fs, io::Write, process::ExitCode};

fn run() -> Result<(), String> {
    let mut args = env::args_os().skip(1);
    let command = args
        .next()
        .ok_or("缺少操作：inspect / inspect-sealed / seal-copy / unseal-copy")?;
    let command = command.to_str().ok_or("无效的操作名称")?;
    if !["inspect", "inspect-sealed", "seal-copy", "unseal-copy"].contains(&command) {
        return Err("未知操作：inspect / inspect-sealed / seal-copy / unseal-copy".into());
    }
    let path = args.next().ok_or("缺少数据文件路径")?;
    let output = if command.ends_with("-copy") {
        Some(args.next().ok_or("缺少新导出文件路径")?)
    } else {
        None
    };
    if args.next().is_some() {
        return Err("参数过多".into());
    }
    let input = fs::read(&path).map_err(|e| format!("无法读取数据文件：{e}"))?;
    let bytes = if ["inspect-sealed", "unseal-copy"].contains(&command) {
        shodan_core::sealed::open_data(&input).map_err(|e| e.to_string())?
    } else {
        input
    };
    let blocks = shodan_core::dlbin::index(&bytes).map_err(|e| e.to_string())?;
    if let Some(output) = output {
        let exported = if command == "seal-copy" {
            shodan_core::sealed::seal(&bytes).map_err(|e| e.to_string())?
        } else {
            bytes.clone()
        };
        // Export only: no replacement of existing files, backups or game installation.
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(output)
            .map_err(|e| format!("无法创建新导出文件（不会覆盖现有文件）：{e}"))?;
        file.write_all(&exported)
            .and_then(|_| file.sync_all())
            .map_err(|e| format!("无法写入导出文件：{e}"))?;
    }
    println!(
        "{}",
        json!({"runtime":"rust-native","read_only":!command.ends_with("-copy"),"bytes":bytes.len(),
        "sha256":shodan_core::hash::sha256_hex(&bytes),"murmur64":format!("{:016x}",shodan_core::hash::murmur64(&bytes)),
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
