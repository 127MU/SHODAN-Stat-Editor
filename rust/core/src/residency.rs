//! Legacy-compatible residency records and read-only slot planning.
//! A ledger alone is never proof that a patch can be loaded.
use std::{collections::BTreeSet, fs, io::Read, path::Path};
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub host: String,
    pub index: u32,
    pub name: String,
    pub mode: String,
    pub built: u32,
}
pub fn package_name(name: &str) -> bool {
    name.len() == 16 && name.bytes().all(|c| c.is_ascii_hexdigit())
}
pub fn parse(text: &str) -> Result<Vec<Entry>, String> {
    if text.len() > 1024 * 1024 {
        return Err("驻留记录过大".into());
    }
    let mut entries = Vec::new();
    let mut slots = BTreeSet::new();
    let mut sources = BTreeSet::new();
    for line in text.lines().filter(|l| !l.trim().is_empty()) {
        let parts: Vec<_> = line.split_whitespace().collect();
        if !(4..=5).contains(&parts.len())
            || !package_name(parts[0])
            || !package_name(parts[2])
            || !["full", "light", "res"].contains(&parts[3])
        {
            return Err("驻留记录格式无效，未更改记录".into());
        }
        let entry = Entry {
            host: parts[0].to_ascii_lowercase(),
            index: parts[1].parse().map_err(|_| "驻留槽位无效")?,
            name: parts[2].to_ascii_lowercase(),
            mode: parts[3].into(),
            built: parts
                .get(4)
                .unwrap_or(&"0")
                .parse()
                .map_err(|_| "驻留资源数无效")?,
        };
        if !slots.insert((entry.host.clone(), entry.index))
            || !sources.insert((entry.host.clone(), entry.name.clone()))
        {
            return Err("驻留记录有重复槽位或来源".into());
        }
        entries.push(entry);
    }
    entries.sort_by(|a, b| (&a.host, a.index).cmp(&(&b.host, b.index)));
    Ok(entries)
}
pub fn encode(entries: &[Entry]) -> Result<String, String> {
    let text = entries
        .iter()
        .map(|e| format!("{} {} {} {} {}\n", e.host, e.index, e.name, e.mode, e.built))
        .collect::<String>();
    let sorted = parse(&text)?;
    Ok(sorted
        .iter()
        .map(|e| format!("{} {} {} {} {}\n", e.host, e.index, e.name, e.mode, e.built))
        .collect())
}
fn metadata(path: &Path) -> Result<Option<fs::Metadata>, String> {
    match fs::symlink_metadata(path) {
        Ok(m) if m.is_file() && !m.file_type().is_symlink() => Ok(Some(m)),
        Ok(_) => Err("补丁路径不是普通文件".into()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err("补丁文件不可访问，不能当作不存在处理".into()),
    }
}
pub fn read_ledger(path: &Path) -> Result<Vec<Entry>, String> {
    let Some(meta) = metadata(path)? else {
        return Ok(Vec::new());
    };
    if meta.len() > 1024 * 1024 {
        return Err("驻留记录过大".into());
    }
    parse(&fs::read_to_string(path).map_err(|_| "无法读取驻留记录")?)
}
pub struct Slots {
    pub used: BTreeSet<u32>,
    pub toc: BTreeSet<u32>,
}
pub fn slots(root: &Path, host: &str) -> Result<Slots, String> {
    if !package_name(host) {
        return Err("宿主资源包名称无效".into());
    }
    if metadata(&root.join("bundles.nxa"))?.is_none() && metadata(&root.join(host))?.is_none() {
        return Err("游戏资源索引不存在".into());
    }
    let prefix = format!("{}.patch_", host.to_ascii_lowercase());
    let mut result = Slots {
        used: BTreeSet::new(),
        toc: BTreeSet::new(),
    };
    for item in fs::read_dir(root).map_err(|_| "无法枚举补丁目录")? {
        let item = item.map_err(|_| "无法读取补丁目录项")?;
        let file = item.file_name().to_string_lossy().to_ascii_lowercase();
        let Some(suffix) = file.strip_prefix(&prefix) else {
            continue;
        };
        let (number, side) = suffix.split_once('.').unwrap_or((suffix, ""));
        if !["", "stream", "gpu_resources"].contains(&side)
            || number.is_empty()
            || !number.bytes().all(|b| b.is_ascii_digit())
        {
            continue;
        }
        let index: u32 = number.parse().map_err(|_| "补丁槽位超出范围")?;
        // Reject alternate spellings: Windows treats case as equal; patch_01 is
        // not safe evidence for the loader's required patch_1.
        if number != index.to_string() {
            return Err("补丁槽位名称不是规范编号".into());
        }
        metadata(&item.path())?;
        result.used.insert(index);
        if side.is_empty() {
            result.toc.insert(index);
        }
    }
    Ok(result)
}
pub struct Plan {
    pub index: u32,
    pub reuse: bool,
}
pub fn plan(root: &Path, entries: &[Entry], host: &str, name: &str) -> Result<Plan, String> {
    if !package_name(name) {
        return Err("来源资源包名称无效".into());
    }
    // Validate caller-supplied ledgers too; duplicate ownership cannot be guessed.
    parse(&encode(entries)?)?;
    let host = host.to_ascii_lowercase();
    let name = name.to_ascii_lowercase();
    let slots = slots(root, &host)?;
    if let Some(e) = entries
        .iter()
        .find(|e| e.host.eq_ignore_ascii_case(&host) && e.name.eq_ignore_ascii_case(&name))
    {
        if slots.used.contains(&e.index) {
            if slots.toc.range(..=e.index).count() as u64 != u64::from(e.index) + 1 {
                return Err("补丁序号不连续或主文件缺失，驻留补丁不会被加载".into());
            }
            return Ok(Plan {
                index: e.index,
                reuse: true,
            });
        }
    }
    if let Some(highest) = slots.used.last().copied() {
        if slots.toc.len() as u64 != u64::from(highest) + 1 {
            return Err("补丁序号不连续或仅有伴生文件，不能分配新槽位".into());
        }
        return Ok(Plan {
            index: highest.checked_add(1).ok_or("补丁槽位已耗尽")?,
            reuse: false,
        });
    }
    Ok(Plan {
        index: 0,
        reuse: false,
    })
}
pub fn state(root: &Path, entry: &Entry) -> Result<u8, String> {
    if !package_name(&entry.host) {
        return Err("宿主资源包名称无效".into());
    }
    let slots = slots(root, &entry.host)?;
    if slots.toc.range(..=entry.index).count() as u64 != u64::from(entry.index) + 1 {
        return Ok(0);
    }
    let base = root.join(format!("{}.patch_{}", entry.host, entry.index));
    let mut file = fs::File::open(&base).map_err(|_| "无法读取驻留补丁")?;
    let toc_len = file.metadata().map_err(|_| "无法读取补丁长度")?.len();
    let mut head = [0; 72];
    file.read_exact(&mut head).map_err(|_| "驻留补丁头截断")?;
    let types = u32::from_le_bytes(head[4..8].try_into().unwrap()) as usize;
    let count = u32::from_le_bytes(head[8..12].try_into().unwrap()) as usize;
    if types > 4096 || count > 100000 {
        return Err("驻留补丁目录数量异常".into());
    }
    let mut bytes = head.to_vec();
    bytes.resize(72 + types * 32 + count * 80, 0);
    file.read_exact(&mut bytes[72..])
        .map_err(|_| "驻留补丁目录截断")?;
    let package = crate::resource_package::Package::parse(&bytes)?;
    let length = |suffix: &str| -> Result<u64, String> {
        Ok(
            metadata(&root.join(format!("{}.patch_{}{suffix}", entry.host, entry.index)))?
                .map_or(0, |m| m.len()),
        )
    };
    let gpu = length(".gpu_resources")?;
    let stream = length(".stream")?;
    for e in &package.entries {
        for (off, n, size) in [(16, 56, toc_len), (24, 60, stream), (32, 64, gpu)] {
            let n = u32::from_le_bytes(e[n..n + 4].try_into().unwrap()) as u64;
            let at = u64::from_le_bytes(e[off..off + 8].try_into().unwrap());
            if n > 0 && at.checked_add(n).is_none_or(|end| end > size) {
                return Ok(0);
            }
        }
    }
    Ok(match entry.mode.as_str() {
        "full" => 1,
        "light" => 2,
        "res" => 0,
        _ => return Err("驻留模式无效".into()),
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    const HOST: &str = "9ba626afa44a3aa3";
    fn dir() -> std::path::PathBuf {
        let p = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../dist/build-temp-r19")
            .join(format!(
                "slots-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
        fs::create_dir_all(&p).unwrap();
        fs::write(p.join("bundles.nxa"), []).unwrap();
        p
    }
    #[test]
    fn ledger_roundtrip_rejects_duplicate_and_path_injection() {
        let e = parse(&format!("{HOST} 248 0123456789ABCDEF full 43\n")).unwrap();
        assert_eq!(parse(&encode(&e).unwrap()).unwrap(), e);
        assert!(parse(&format!("{0} 0 {0} full 1\n{0} 0 {0} full 1", HOST)).is_err());
        assert!(parse("../bad 0 deadbeef full 1").is_err());
    }
    #[test]
    fn slots_above_248_are_preserved_and_holes_are_not_reused() {
        let p = dir();
        for i in 0..=250 {
            fs::write(p.join(format!("{HOST}.patch_{i}")), []).unwrap();
        }
        assert_eq!(plan(&p, &[], HOST, HOST).unwrap().index, 251);
        fs::remove_file(p.join(format!("{HOST}.patch_120"))).unwrap();
        assert!(plan(&p, &[], HOST, HOST).is_err());
        fs::remove_dir_all(p).unwrap();
    }
    #[test]
    fn orphan_sidecar_does_not_count_as_loadable_patch() {
        let p = dir();
        fs::write(p.join(format!("{HOST}.patch_0.stream")), []).unwrap();
        let e = Entry {
            host: HOST.into(),
            index: 0,
            name: HOST.into(),
            mode: "full".into(),
            built: 0,
        };
        assert!(plan(&p, &[e.clone()], HOST, HOST).is_err());
        assert_eq!(state(&p, &e).unwrap(), 0);
        fs::remove_dir_all(p).unwrap();
    }
    #[test]
    fn ledger_does_not_hide_missing_or_truncated_streams() {
        use crate::resource_package::{Blob, Package, MAGIC};
        let p = dir();
        let mut header = [0; 72];
        header[..4].copy_from_slice(&MAGIC.to_le_bytes());
        let mut entry = [0; 80];
        entry[..8].copy_from_slice(&1u64.to_le_bytes());
        entry[8..16].copy_from_slice(&2u64.to_le_bytes());
        let built = Package {
            header,
            types: vec![],
            entries: vec![],
        }
        .build(&[Blob {
            entry,
            toc: vec![1; 8],
            gpu: vec![],
            stream: vec![2; 4],
        }])
        .unwrap();
        fs::write(p.join(format!("{HOST}.patch_0")), built.toc).unwrap();
        let e = Entry {
            host: HOST.into(),
            index: 0,
            name: HOST.into(),
            mode: "full".into(),
            built: 1,
        };
        assert_eq!(state(&p, &e).unwrap(), 0);
        let side = p.join(format!("{HOST}.patch_0.stream"));
        fs::write(&side, &built.stream).unwrap();
        assert_eq!(state(&p, &e).unwrap(), 1);
        fs::write(&side, [2]).unwrap();
        assert_eq!(state(&p, &e).unwrap(), 0);
        fs::remove_dir_all(p).unwrap();
    }
}
