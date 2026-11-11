//! Recompute `resource_sources` fingerprints for a game build.
//!
//! The catalog records, for every standalone resource the editor can patch, its
//! byte length, SHA-256 and owning package. A game update that rebuilds the
//! bundles changes those fingerprints even when the numeric tables are intact,
//! and the startup check then rejects the whole workspace. This tool rescans
//! the installed bundles and prints an updated map:
//!
//!   rescan-resources <game-root> <catalog.json> <output.json>
//!
//! It only reads the game directory.
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use shodan_core::bundles::Bundles;
use std::collections::BTreeMap;
use std::{env, fs, process::ExitCode};

fn u64at(bytes: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(bytes[at..at + 8].try_into().unwrap())
}

fn u32at(bytes: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap())
}

fn sha256(data: &[u8]) -> String {
    let digest = Sha256::digest(data);
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

fn run() -> Result<(), String> {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.len() != 3 {
        return Err("用法：rescan-resources <游戏目录> <catalog.json> <输出 JSON>".into());
    }
    let root = std::path::PathBuf::from(&args[0]);
    let catalog: Value = serde_json::from_slice(
        &fs::read(&args[1]).map_err(|_| "无法读取参数目录".to_string())?,
    )
    .map_err(|_| "参数目录不是有效 JSON".to_string())?;
    let sources = catalog["resource_sources"]
        .as_object()
        .ok_or("参数目录缺少 resource_sources")?;
    let mut bundles = Bundles::open(&root)?;

    // (type, id) -> (package, toc offset, toc length)
    let mut index: BTreeMap<(u64, u64), (String, u64, u32)> = BTreeMap::new();
    let names: Vec<String> = bundles.packages.keys().cloned().collect();
    for name in &names {
        let package = match bundles.package(name) {
            Ok(package) => package,
            Err(error) => {
                eprintln!("skip {name}: {error}");
                continue;
            }
        };
        for entry in &package.entries {
            let id = u64at(entry, 0);
            let typ = u64at(entry, 8);
            index
                .entry((typ, id))
                .or_insert_with(|| (name.clone(), u64at(entry, 16), u32at(entry, 56)));
        }
    }
    eprintln!("packages={} resources={}", names.len(), index.len());

    let mut out = Map::new();
    let mut missing = Vec::new();
    for name in sources.keys() {
        let (id_hex, typ_hex) = name.split_once('.').ok_or("资源名称格式无效")?;
        let id = u64::from_str_radix(id_hex, 16).map_err(|_| "资源 ID 无效")?;
        let typ = u64::from_str_radix(typ_hex, 16).map_err(|_| "资源类型无效")?;
        let Some((package, offset, size)) = index.get(&(typ, id)).cloned() else {
            missing.push(name.clone());
            continue;
        };
        let data = bundles
            .read(&package, offset, size as usize)
            .map_err(|error| format!("{name}: {error}"))?;
        out.insert(
            name.clone(),
            json!({"bytes": data.len(), "sha256": sha256(&data), "package": package}),
        );
    }
    let report = json!({"resource_sources": out, "missing": missing});
    fs::write(&args[2], serde_json::to_vec_pretty(&report).map_err(|_| "无法编码结果")?)
        .map_err(|_| "无法写入结果文件")?;
    eprintln!(
        "written {} resources, missing {}",
        report["resource_sources"].as_object().unwrap().len(),
        missing.len()
    );
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}
