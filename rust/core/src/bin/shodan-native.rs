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
    if command == "prepare-copy" {
        let snapshot = args.next().ok_or("缺少修改前的明文快照")?;
        let edited = args.next().ok_or("缺少修改后的明文数据")?;
        let output = args.next().ok_or("缺少新导出文件路径")?;
        let mut floats = Vec::new();
        for arg in args {
            let text = arg.to_str().ok_or("浮点字段偏移无效")?;
            let offset = if let Some(hex) = text.strip_prefix("0x") {
                usize::from_str_radix(hex, 16)
            } else {
                text.parse()
            }
            .map_err(|_| "浮点字段偏移无效")?;
            floats.push(offset);
        }
        let snapshot = fs::read(snapshot).map_err(|e| format!("无法读取快照：{e}"))?;
        let edited = fs::read(edited).map_err(|e| format!("无法读取编辑数据：{e}"))?;
        let prepared = shodan_core::export::prepare(
            &snapshot,
            &edited,
            &shodan_core::correction::Options {
                float_offsets: &floats,
                ..Default::default()
            },
            |count| eprintln!("准备校验：{count} 个候选"),
        )
        .map_err(|e| e.to_string())?;
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(output)
            .map_err(|e| format!("无法创建新导出文件（不会覆盖）：{e}"))?;
        file.write_all(&prepared.ciphertext)
            .and_then(|_| file.sync_all())
            .map_err(|e| format!("无法写入导出文件：{e}"))?;
        println!(
            "{}",
            json!({"runtime":"rust-native","installed":false,"target_hash":format!("{:016x}",prepared.target_hash),
            "plaintext_sha256":prepared.plaintext_sha256,"header":prepared.correction.header,
            "salts_tested":prepared.correction.salts_tested,
            "adjusted_float":prepared.correction.adjusted_float.map(|(offset,before,after)|json!({"offset":offset,"before":before,"after":after}))})
        );
        return Ok(());
    }
    if ![
        "inspect",
        "inspect-sealed",
        "seal-copy",
        "unseal-copy",
        "tables",
    ]
    .contains(&command)
    {
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
    if command == "tables" {
        let mut tables = Vec::new();
        let mut problems = Vec::new();
        for block in &blocks {
            let layouts = shodan_core::tables::layouts(block.type_id);
            if layouts.is_empty() {
                continue;
            }
            let mut candidates = Vec::new();
            for layout in layouts {
                if let Ok(table) = shodan_core::tables::parse(&bytes, block, layout) {
                    candidates.push((layout, table));
                }
            }
            if candidates.len() != 1 {
                problems.push(
                    json!({"type":format!("{:08X}",block.type_id),"offset":block.header_offset,
                    "message":format!("识别到 {} 个候选布局",candidates.len())}),
                );
                continue;
            }
            let (layout, table) = candidates.remove(0);
            tables.push(
                json!({"type":format!("{:08X}",table.type_id),"offset":block.header_offset,
                "layout":format!("{layout:?}"),"duplicates":table.duplicate_keys,
                "rows":table.rows.iter().map(|(key,range)|json!({
                    "key":match key {shodan_core::tables::Key::Id(id)=>format!("id:{id}"),
                        shodan_core::tables::Key::Hash(hash)=>format!("hash:{hash:016X}")},
                    "offset":range.start,"bytes":range.len()})).collect::<Vec<_>>()}),
            );
        }
        println!(
            "{}",
            json!({"runtime":"rust-native","read_only":true,"tables":tables,"problems":problems})
        );
        return Ok(());
    }
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
