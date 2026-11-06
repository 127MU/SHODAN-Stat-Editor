//! Own only the patch slots whose complete contents match our ledger.
use crate::{
    bundles::Mode,
    dependencies::Identity,
    hash::sha256_hex,
    install::{self, Change},
    residency,
    resource_package::{Built, Package, MAGIC},
};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
};

pub(crate) const CARRIER: &str = "9ba626afa44a3aa3";
const SUFFIXES: [&str; 3] = ["", ".gpu_resources", ".stream"];

#[derive(Deserialize, Serialize)]
struct Slot {
    index: u32,
    hashes: [Option<String>; 3],
}

#[derive(Deserialize, Serialize)]
struct Group {
    signature: String,
    packages: BTreeSet<String>,
}

#[derive(Default, Deserialize, Serialize)]
struct Ledger {
    groups: BTreeMap<String, Group>,
    slots: BTreeMap<String, Slot>,
    vacant: BTreeMap<u32, Slot>,
    #[serde(default)]
    overrides: BTreeMap<String, BTreeSet<String>>,
}
pub(crate) type Overrides = BTreeMap<Identity, Vec<u8>>;
pub(crate) type Edits = BTreeMap<String, BTreeMap<Identity, Option<Vec<u8>>>>;

fn load(path: &Path) -> Result<(Option<Vec<u8>>, Ledger), String> {
    let bytes = install::read(path)?;
    let ledger: Ledger = match &bytes {
        Some(bytes) if bytes.len() <= 2 * 1024 * 1024 => {
            serde_json::from_slice(bytes).map_err(|_| "驻留安装记录格式无效")?
        }
        Some(_) => return Err("驻留安装记录过大".into()),
        None => Ledger::default(),
    };
    let mut indices = BTreeSet::new();
    if ledger
        .slots
        .iter()
        .any(|(name, slot)| !residency::package_name(name) || !indices.insert(slot.index))
        || ledger
            .vacant
            .iter()
            .any(|(i, slot)| *i != slot.index || !indices.insert(*i))
        || ledger
            .groups
            .values()
            .any(|group| group.packages.iter().any(|p| !ledger.slots.contains_key(p)))
        || ledger
            .overrides
            .keys()
            .any(|name| !ledger.slots.contains_key(name))
    {
        return Err("驻留安装记录的槽位或资源包无效".into());
    }
    Ok((bytes, ledger))
}

fn path(root: &Path, index: u32, suffix: &str) -> std::path::PathBuf {
    root.join(format!("{CARRIER}.patch_{index}{suffix}"))
}

fn contents(root: &Path, index: u32) -> Result<[Option<Vec<u8>>; 3], String> {
    let mut result = [None, None, None];
    for (target, suffix) in result.iter_mut().zip(SUFFIXES) {
        *target = install::read(&path(root, index, suffix))?;
    }
    Ok(result)
}

fn fingerprints(parts: &[Option<Vec<u8>>; 3]) -> [Option<String>; 3] {
    std::array::from_fn(|i| parts[i].as_deref().map(sha256_hex))
}

fn checked(root: &Path, slot: &Slot) -> Result<[Option<Vec<u8>>; 3], String> {
    let parts = contents(root, slot.index)?;
    if fingerprints(&parts) != slot.hashes {
        return Err(format!(
            "驻留补丁槽位 {} 已由其他工具更改或缺失",
            slot.index
        ));
    }
    Ok(parts)
}

pub(crate) fn audit(root: &Path, ledger: &Path) -> Result<Vec<String>, String> {
    use sha2::{Digest, Sha256};
    use std::io::{ErrorKind, Read};
    let (_, ledger) = load(ledger)?;
    let mut problems = Vec::new();
    let mut buf = [0; 64 * 1024];
    for slot in ledger.slots.values().chain(ledger.vacant.values()) {
        for (suffix, expected) in SUFFIXES.iter().zip(&slot.hashes) {
            let target = path(root, slot.index, suffix);
            let label = target.file_name().unwrap().to_string_lossy();
            match (std::fs::symlink_metadata(&target), expected) {
                (Err(e), _) if e.kind() != ErrorKind::NotFound => {
                    problems.push(format!("{label} 无法检查：{e}"))
                }
                (Err(_), Some(_)) => problems.push(format!("{label} 缺失")),
                (Ok(_), None) => problems.push(format!("{label} 出现未登记的伴生文件")),
                (Ok(meta), Some(expected)) if meta.is_file() => {
                    let result = (|| -> std::io::Result<String> {
                        let mut file = std::fs::File::open(&target)?;
                        let mut hash = Sha256::new();
                        loop {
                            let count = file.read(&mut buf)?;
                            if count == 0 {
                                break;
                            }
                            hash.update(&buf[..count]);
                        }
                        Ok(format!("{:x}", hash.finalize()))
                    })();
                    match result {
                        Ok(actual) if &actual != expected => {
                            problems.push(format!("{label} 内容已改变"))
                        }
                        Err(error) => problems.push(format!("{label} 无法读取：{error}")),
                        _ => {}
                    }
                }
                (Ok(_), Some(_)) => problems.push(format!("{label} 已被替换为非普通文件")),
                (Err(_), None) => {}
            }
        }
    }
    Ok(problems)
}

fn put(
    root: &Path,
    index: u32,
    before: [Option<Vec<u8>>; 3],
    after: [Option<Vec<u8>>; 3],
    changes: &mut Vec<Change>,
) -> Slot {
    let hashes = fingerprints(&after);
    // Commit companion files before making the TOC visible.
    for ((old, new), suffix) in before.into_iter().zip(after).zip(SUFFIXES).rev() {
        if old != new {
            changes.push(Change {
                path: path(root, index, suffix),
                before: old,
                after: new,
            });
        }
    }
    Slot { index, hashes }
}

fn empty_patch() -> Result<Vec<u8>, String> {
    let mut header = [0; 72];
    header[..4].copy_from_slice(&MAGIC.to_le_bytes());
    Ok(Package {
        header,
        types: vec![],
        entries: vec![],
    }
    .build(&[])?
    .toc)
}

pub(crate) fn installed(root: &Path, ledger: &Path, group: &str) -> Result<bool, String> {
    let (_, ledger) = load(ledger)?;
    let Some(group) = ledger.groups.get(group) else {
        return Ok(false);
    };
    let slots = residency::slots(root, CARRIER)?;
    for name in &group.packages {
        let slot = &ledger.slots[name];
        if slots.toc.range(..=slot.index).count() as u64 != u64::from(slot.index) + 1 {
            return Ok(false);
        }
        let entry = residency::Entry {
            host: CARRIER.into(),
            index: slot.index,
            name: name.clone(),
            mode: "full".into(),
            built: 0,
        };
        if residency::state(root, &entry)? == 0 {
            return Ok(false);
        }
    }
    Ok(true)
}

fn key_string((typ, id): Identity) -> String {
    format!("{typ:016x}:{id:016x}")
}

fn blob_key(blob: &crate::resource_package::Blob) -> Identity {
    (
        u64::from_le_bytes(blob.entry[8..16].try_into().unwrap()),
        u64::from_le_bytes(blob.entry[..8].try_into().unwrap()),
    )
}

pub(crate) fn migrate_legacy(
    root: &Path,
    path: &Path,
    profile: &Path,
    bundles: &mut crate::bundles::Bundles,
    known_override: impl Fn(&str, Identity) -> bool,
) -> Result<Vec<String>, String> {
    if path.exists() {
        return Ok(Vec::new());
    }
    let records = residency::read_ledger(&profile.join("residency.txt"))?;
    if records.is_empty() {
        return Ok(Vec::new());
    }
    let mut ledger = Ledger::default();
    let mut notes = Vec::new();
    let mut full = BTreeSet::new();
    let slots = residency::slots(root, CARRIER)?;
    for record in records.into_iter().filter(|r| r.host == CARRIER) {
        let mut validate = || -> Result<(Slot, BTreeSet<String>), String> {
            if record.mode == "light"
                || slots.toc.range(..=record.index).count() as u64 != u64::from(record.index) + 1
            {
                return Err("旧补丁是轻量模式或存在缺失槽位".into());
            }
            let parts = contents(root, record.index)?;
            let toc = parts[0].as_deref().ok_or("旧补丁主文件缺失")?;
            let actual = Package::parse(toc)?.blobs(
                toc,
                parts[1].as_deref().unwrap_or_default(),
                parts[2].as_deref().unwrap_or_default(),
            )?;
            if actual.is_empty() || (record.built != 0 && record.built as usize != actual.len()) {
                return Err("旧补丁的目录数量与记录不一致".into());
            }
            let mut overrides = Overrides::new();
            let mut seen = BTreeSet::new();
            for blob in &actual {
                let key = blob_key(blob);
                if !seen.insert(key) {
                    return Err("旧补丁有重复资源".into());
                }
                if record.mode == "res" || known_override(&record.name, key) {
                    let base = bundles.resource(&record.name, key)?;
                    if base != blob.toc {
                        if !known_override(&record.name, key) {
                            return Err("旧补丁包含未知的资源修改".into());
                        }
                        overrides.insert(key, blob.toc.clone());
                    }
                }
            }
            let mode = if record.mode == "full" {
                Mode::Full
            } else {
                Mode::Overrides
            };
            let wanted = bundles.build_patch(&record.name, mode, &overrides)?;
            let expected =
                Package::parse(&wanted.toc)?.blobs(&wanted.toc, &wanted.gpu, &wanted.stream)?;
            let hashes = |blobs: Vec<crate::resource_package::Blob>| {
                blobs
                    .into_iter()
                    .map(|blob| {
                        (
                            blob_key(&blob),
                            [
                                sha256_hex(&blob.toc),
                                sha256_hex(&blob.gpu),
                                sha256_hex(&blob.stream),
                            ],
                        )
                    })
                    .collect::<BTreeMap<_, _>>()
            };
            if hashes(actual) != hashes(expected) {
                return Err("旧补丁内容无法与当前原包和已知编辑匹配".into());
            }
            Ok((
                Slot {
                    index: record.index,
                    hashes: fingerprints(&parts),
                },
                overrides.keys().copied().map(key_string).collect(),
            ))
        };
        match validate() {
            Ok((slot, overrides)) => {
                if record.mode == "full" {
                    full.insert(record.name.clone());
                }
                if !overrides.is_empty() {
                    ledger.overrides.insert(record.name.clone(), overrides);
                }
                ledger.slots.insert(record.name, slot);
            }
            Err(why) => notes.push(format!("保留旧资源补丁槽 {} · {why}", record.index)),
        }
    }
    if let Some(groups) =
        crate::desktop_presets::read_text(&profile.join("residency_dependencies.txt"), 1024 * 1024)?
    {
        for line in groups.lines() {
            let mut cells = line.splitn(3, '\t');
            let (Some(owner), Some(signature), Some(packages)) =
                (cells.next(), cells.next(), cells.next())
            else {
                continue;
            };
            let packages: BTreeSet<_> = packages
                .split_ascii_whitespace()
                .map(str::to_ascii_lowercase)
                .collect();
            if owner.len() == 16
                && owner.bytes().all(|b| b.is_ascii_hexdigit())
                && signature.len() <= 4096
                && !packages.is_empty()
                && packages.is_subset(&full)
            {
                ledger.groups.insert(
                    owner.to_ascii_uppercase(),
                    Group {
                        signature: signature.into(),
                        packages,
                    },
                );
            }
        }
    }
    let used = group_packages(&ledger);
    // A package without a verified owner stays outside the managed ledger.
    ledger
        .slots
        .retain(|name, _| used.contains(name) || ledger.overrides.contains_key(name));
    let bytes = serde_json::to_vec(&ledger).map_err(|_| "无法记录旧版驻留槽位")?;
    install::save_atomic(path, &bytes)?;
    Ok(notes)
}

fn saved(root: &Path, ledger: &Ledger, name: &str) -> Result<Overrides, String> {
    let Some(keys) = ledger.overrides.get(name) else {
        return Ok(BTreeMap::new());
    };
    let slot = ledger.slots.get(name).ok_or("覆盖记录缺少对应补丁")?;
    let parts = checked(root, slot)?;
    let toc = parts[0].as_deref().ok_or("缺少覆盖补丁主文件")?;
    let blobs = Package::parse(toc)?.blobs(
        toc,
        parts[1].as_deref().unwrap_or_default(),
        parts[2].as_deref().unwrap_or_default(),
    )?;
    let mut found = BTreeMap::new();
    for blob in blobs {
        let id = u64::from_le_bytes(blob.entry[..8].try_into().unwrap());
        let typ = u64::from_le_bytes(blob.entry[8..16].try_into().unwrap());
        if keys.contains(&key_string((typ, id))) {
            found.insert((typ, id), blob.toc);
        }
    }
    if keys.len() != found.len() {
        return Err("已安装补丁缺少登记的覆盖资源".into());
    }
    Ok(found)
}

pub(crate) fn read_overrides(
    root: &Path,
    ledger_path: &Path,
    name: &str,
) -> Result<Overrides, String> {
    saved(root, &load(ledger_path)?.1, name)
}

pub(crate) fn prepare(
    root: &Path,
    ledger_path: &Path,
    group: &str,
    requested: Option<(&str, &[String])>,
    build: impl FnMut(&str, Mode, &Overrides, &Overrides) -> Result<Built, String>,
) -> Result<Vec<Change>, String> {
    if group.is_empty() || group.len() > 256 {
        return Err("驻留组合标识无效".into());
    }
    reconcile(
        root,
        ledger_path,
        Some((group, requested)),
        BTreeMap::new(),
        build,
    )
}

pub(crate) fn prepare_edits(
    root: &Path,
    ledger_path: &Path,
    edits: Edits,
    build: impl FnMut(&str, Mode, &Overrides, &Overrides) -> Result<Built, String>,
) -> Result<Vec<Change>, String> {
    reconcile(root, ledger_path, None, edits, build)
}

fn group_packages(ledger: &Ledger) -> BTreeSet<String> {
    ledger
        .groups
        .values()
        .flat_map(|g| g.packages.iter().cloned())
        .collect()
}

fn combine(by_package: &BTreeMap<String, Overrides>) -> Result<Overrides, String> {
    let mut shared = Overrides::new();
    for entries in by_package.values() {
        for (&key, bytes) in entries {
            if let Some(prior) = shared.insert(key, bytes.clone()) {
                if prior != *bytes {
                    return Err(format!("同一资源 {} 存在互相冲突的覆盖", key_string(key)));
                }
            }
        }
    }
    Ok(shared)
}

fn reconcile(
    root: &Path,
    ledger_path: &Path,
    group: Option<(&str, Option<(&str, &[String])>)>,
    mut edits: Edits,
    mut build: impl FnMut(&str, Mode, &Overrides, &Overrides) -> Result<Built, String>,
) -> Result<Vec<Change>, String> {
    let (before, mut ledger) = load(ledger_path)?;
    let slots = residency::slots(root, CARRIER)?;
    let mut next = match slots.used.last().copied() {
        Some(highest) if slots.toc.len() as u64 == u64::from(highest) + 1 => {
            highest.checked_add(1).ok_or("驻留补丁槽位已满")?
        }
        Some(_) => return Err("载体存在缺号或缺主文件的补丁，无法安全写入".into()),
        None => 0,
    };
    let mut changes = Vec::new();
    let old_full = group_packages(&ledger);
    match group {
        Some((group, Some((signature, names)))) => {
            if names.is_empty()
                || names.len() > 128
                || names
                    .iter()
                    .any(|n| !residency::package_name(n) || n == CARRIER)
            {
                return Err("资源驻留来源包无效或数量超限".into());
            }
            ledger.groups.insert(
                group.into(),
                Group {
                    signature: signature.into(),
                    packages: names.iter().cloned().collect(),
                },
            );
        }
        Some((group, None)) => {
            ledger.groups.remove(group);
        }
        None => {}
    }
    let new_full = group_packages(&ledger);
    let mut affected: BTreeSet<_> = old_full
        .symmetric_difference(&new_full)
        .cloned()
        .chain(edits.keys().cloned())
        .collect();
    let mut by_package: BTreeMap<_, _> = ledger
        .overrides
        .keys()
        .map(|name| saved(root, &ledger, name).map(|entries| (name.clone(), entries)))
        .collect::<Result<_, _>>()?;
    let before_shared = combine(&by_package)?;
    for (name, entries) in std::mem::take(&mut edits) {
        if !residency::package_name(&name) || name != name.to_ascii_lowercase() {
            return Err("来源资源包文件名无效".into());
        }
        let overrides = by_package.entry(name.clone()).or_default();
        for (key, bytes) in entries {
            if let Some(bytes) = bytes {
                overrides.insert(key, bytes);
            } else {
                overrides.remove(&key);
            }
        }
        if overrides.is_empty() {
            ledger.overrides.remove(&name);
        } else {
            ledger
                .overrides
                .insert(name, overrides.keys().copied().map(key_string).collect());
        }
    }
    let shared = combine(&by_package)?;
    let edited: BTreeSet<_> = before_shared
        .keys()
        .chain(shared.keys())
        .filter(|key| before_shared.get(key) != shared.get(key))
        .copied()
        .collect();
    if !edited.is_empty() {
        for name in new_full.intersection(&old_full) {
            if affected.contains(name) {
                continue;
            }
            let slot = &ledger.slots[name];
            let toc = install::read(&path(root, slot.index, ""))?.ok_or("驻留补丁主文件缺失")?;
            if Package::parse(&toc)?.entries.iter().any(|entry| {
                let id = u64::from_le_bytes(entry[..8].try_into().unwrap());
                let typ = u64::from_le_bytes(entry[8..16].try_into().unwrap());
                edited.contains(&(typ, id))
            }) {
                affected.insert(name.clone());
            }
        }
    }
    let empty = Overrides::new();
    for name in affected {
        let overrides = by_package.get(&name).unwrap_or(&empty);
        if !new_full.contains(&name) && overrides.is_empty() {
            continue;
        }
        let (index, before) = if let Some(slot) = ledger.slots.get(&name) {
            (slot.index, checked(root, slot)?)
        } else if let Some(index) = ledger.vacant.first_key_value().map(|(&i, _)| i) {
            let slot = ledger.vacant.remove(&index).unwrap();
            (index, checked(root, &slot)?)
        } else {
            let index = next;
            next = next.checked_add(1).ok_or("驻留补丁槽位已满")?;
            (index, [None, None, None])
        };
        let mode = if new_full.contains(&name) {
            Mode::Full
        } else {
            Mode::Overrides
        };
        let Built { toc, gpu, stream } = build(&name, mode, overrides, &shared)?;
        if Package::parse(&toc)?.entries.is_empty() {
            return Err(format!("来源包 {name} 没有可驻留资源"));
        }
        let after = [
            Some(toc),
            (!gpu.is_empty()).then_some(gpu),
            (!stream.is_empty()).then_some(stream),
        ];
        ledger
            .slots
            .insert(name, put(root, index, before, after, &mut changes));
    }
    let retained: BTreeSet<_> = new_full
        .into_iter()
        .chain(ledger.overrides.keys().cloned())
        .collect();
    let mut unused: Vec<_> = ledger
        .slots
        .keys()
        .filter(|name| !retained.contains(*name))
        .cloned()
        .collect();
    unused.sort_by_key(|name| std::cmp::Reverse(ledger.slots[name].index));
    for name in unused {
        let slot = ledger.slots.remove(&name).unwrap();
        let before = checked(root, &slot)?;
        let index = slot.index;
        if index.checked_add(1) == Some(next) {
            put(root, index, before, [None, None, None], &mut changes);
            next = index;
        } else {
            let vacant = put(
                root,
                index,
                before,
                [Some(empty_patch()?), None, None],
                &mut changes,
            );
            ledger.vacant.insert(index, vacant);
        }
    }
    while let Some(index) = next.checked_sub(1) {
        let Some(slot) = ledger.vacant.get(&index) else {
            break;
        };
        // A newly vacated slot already has a planned replacement in this transaction.
        if changes.iter().any(|c| c.path == path(root, index, "")) {
            break;
        }
        let before = checked(root, slot)?;
        ledger.vacant.remove(&index);
        put(root, index, before, [None, None, None], &mut changes);
        next = index;
    }
    let after = serde_json::to_vec(&ledger).map_err(|_| "无法保存驻留安装记录")?;
    changes.push(Change {
        path: ledger_path.to_path_buf(),
        before,
        after: Some(after),
    });
    Ok(changes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{bundles::Bundles, resource_package::Blob};
    use std::{
        fs,
        path::PathBuf,
        time::{SystemTime, UNIX_EPOCH},
    };

    struct Sandbox(PathBuf);
    impl Drop for Sandbox {
        fn drop(&mut self) {
            assert!(
                self.0.starts_with(std::env::temp_dir())
                    && self
                        .0
                        .file_name()
                        .unwrap()
                        .to_string_lossy()
                        .starts_with("shodan-residency-")
            );
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn resident_copies_follow_shared_edits_and_return_to_their_own_originals() {
        let sandbox = Sandbox(std::env::temp_dir().join(format!("shodan-residency-{}-{}",
            std::process::id(), SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos())));
        let root = &sandbox.0;
        fs::create_dir(root).unwrap();
        let ledger = root.join("ledger.json");
        let a = "1111111111111111";
        let b = "2222222222222222";
        let key = (12_u64, 34_u64);
        let mut header = [0; 72];
        header[..4].copy_from_slice(&MAGIC.to_le_bytes());
        let mut entry = [0; 80];
        entry[..8].copy_from_slice(&key.1.to_le_bytes());
        entry[8..16].copy_from_slice(&key.0.to_le_bytes());
        let package = Package {
            header,
            types: vec![],
            entries: vec![],
        };
        for (name, value) in [(a, 1), (b, 2)] {
            let built = package
                .build(&[Blob {
                    entry,
                    toc: vec![value],
                    gpu: vec![],
                    stream: vec![],
                }])
                .unwrap();
            fs::write(root.join(name), built.toc).unwrap();
        }
        fs::write(root.join(CARRIER), []).unwrap();
        let mut bundles = Bundles::open(root).unwrap();
        let mut build = |name: &str, mode, own: &Overrides, shared: &Overrides| {
            bundles.build_patch_shared(name, mode, own, shared)
        };
        let read = || {
            let raw = fs::read(path(root, 0, "")).unwrap();
            Package::parse(&raw).unwrap().blobs(&raw, &[], &[]).unwrap()[0]
                .toc
                .clone()
        };
        let names = vec![b.to_owned()];
        let changes = prepare(
            root,
            &ledger,
            "owner",
            Some(("signature", &names)),
            &mut build,
        )
        .unwrap();
        install::apply(changes, &root.join("tx1"), |_| {}).unwrap();
        assert_eq!(read(), [2]);
        let changes = prepare_edits(
            root,
            &ledger,
            BTreeMap::from([(a.into(), BTreeMap::from([(key, Some(vec![9]))]))]),
            &mut build,
        )
        .unwrap();
        install::apply(changes, &root.join("tx2"), |_| {}).unwrap();
        assert_eq!(read(), [9]);
        assert_eq!(read_overrides(root, &ledger, a).unwrap()[&key], [9]);
        assert!(read_overrides(root, &ledger, b).unwrap().is_empty());
        let changes = prepare_edits(
            root,
            &ledger,
            BTreeMap::from([(a.into(), BTreeMap::from([(key, None)]))]),
            &mut build,
        )
        .unwrap();
        install::apply(changes, &root.join("tx3"), |_| {}).unwrap();
        assert_eq!(read(), [2]);
        assert!(!path(root, 1, "").exists());
    }
}
