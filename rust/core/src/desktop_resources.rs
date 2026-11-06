//! Resource sources for the current equipment, projectile and explosion selections.
use crate::{
    catalog::{Catalog, Mode, Owner},
    dependencies::Identity,
    references,
    tables::Key,
    workspace::Workspace,
};
use std::collections::BTreeSet;

const PACKAGE: u32 = 0x7A858691;
const PROJECTILE: u32 = 0xBD4042C2;
const EXPLOSION: u32 = 0x2AEA2592;
const PARTICLE: u64 = 0xA8193123526FAD64;

#[derive(Default)]
pub(crate) struct Plan {
    pub preferred: Vec<String>,
    pub resources: BTreeSet<Identity>,
    pub events: BTreeSet<u32>,
    pub scan: Vec<Vec<u8>>,
}

fn integer(bytes: &[u8], at: usize) -> Result<u32, String> {
    bytes
        .get(at..at + 4)
        .map(|s| u32::from_le_bytes(s.try_into().unwrap()))
        .ok_or_else(|| "资源引用行截断".into())
}
fn hash(bytes: &[u8], at: usize) -> Result<u64, String> {
    bytes
        .get(at..at + 8)
        .map(|s| u64::from_le_bytes(s.try_into().unwrap()))
        .ok_or_else(|| "资源引用行截断".into())
}
fn package(workspace: &Workspace, entity: u64) -> Result<Option<String>, String> {
    workspace
        .table_bytes(PACKAGE, Key::Hash(entity), false)?
        .map(|b| hash(b, 8))
        .transpose()
        .map(|p| p.filter(|&n| n != 0).map(|n| format!("{n:016x}")))
}
fn push_package(list: &mut Vec<String>, name: Option<String>) {
    if let Some(name) = name {
        if name != crate::residency_install::CARRIER && !list.contains(&name) {
            list.push(name);
        }
    }
}

fn shot_roots(workspace: &Workspace, entity: u64, original: bool) -> Result<BTreeSet<u32>, String> {
    let mut ids = BTreeSet::new();
    for (typ, offsets) in [
        (0x45171B68, [0, 576].as_slice()),
        (0x66081072, &[64, 68]),
        (0xEAC335A1, &[4, 28, 52]),
    ] {
        if let Some(b) = workspace.table_bytes(typ, Key::Hash(entity), original)? {
            for &at in offsets {
                let id = integer(b, at)?;
                if id != 0 {
                    ids.insert(id);
                }
            }
        }
    }
    Ok(ids)
}

pub(crate) fn plan(
    catalog: &Catalog,
    workspace: &Workspace,
    owner: &Owner,
    all: bool,
) -> Result<Plan, String> {
    let mut plan = Plan::default();
    let mut roots = BTreeSet::new();
    let entity = owner
        .native_key
        .as_deref()
        .and_then(|key| u64::from_str_radix(key, 16).ok());
    if owner.tab == "Records" && owner.id.len() == 16 {
        if let Ok(id) = u32::from_str_radix(&owner.id[2..], 16) {
            match &owner.id[..2] {
                "F1" => {
                    roots.insert((PROJECTILE, id));
                }
                "F2" => {
                    roots.insert((EXPLOSION, id));
                }
                _ => {}
            }
        }
    }
    for row in &owner.rows {
        let kind = row.choice.as_str().unwrap_or("");
        if kind == "package"
            && (row.id == "res_package" || owner.rows.iter().all(|r| r.id != "res_package"))
        {
            let value = catalog
                .row_value(owner, row, workspace, Mode::Current)?
                .unwrap_or(0.0) as u64;
            if value != 0 {
                let name = catalog
                    .registries
                    .get("package")
                    .into_iter()
                    .flatten()
                    .find(|c| c.id == value)
                    .ok_or_else(|| format!("无法识别资源包选项 #{value}"))?;
                if !crate::residency::package_name(&name.raw) {
                    return Err("资源包选项缺少有效的文件名".into());
                }
                push_package(&mut plan.preferred, Some(name.raw.to_ascii_lowercase()));
            }
        }
        let target = match kind {
            "explosion" => EXPLOSION,
            "shrapnel" => PROJECTILE,
            _ if row.choice == true => PROJECTILE,
            "mountitem" | "dogweapon" => {
                let value = catalog.row_value(owner, row, workspace, Mode::Current)?;
                let original = catalog.row_value(owner, row, workspace, Mode::Original)?;
                if let Some(value) = value.filter(|v| *v > 0.0 && (all || Some(*v) != original)) {
                    if let Some(id) = catalog
                        .registries
                        .get(kind)
                        .into_iter()
                        .flatten()
                        .find(|item| item.id as f64 == value)
                        .and_then(|item| u64::from_str_radix(&item.raw, 16).ok())
                    {
                        push_package(&mut plan.preferred, package(workspace, id)?);
                        roots.extend(
                            shot_roots(workspace, id, false)?
                                .into_iter()
                                .map(|s| (PROJECTILE, s)),
                        );
                        if kind == "dogweapon" {
                            if let Some(b) =
                                workspace.table_bytes(0xEBA8F3D0, Key::Hash(id), false)?
                            {
                                if let Ok(unit) = hash(b, 128) {
                                    if unit != 0 {
                                        plan.resources.insert((0x5F7203C8F280DAB8, unit));
                                    }
                                }
                            }
                        }
                    }
                }
                continue;
            }
            _ => continue,
        };
        let value = catalog.row_value(owner, row, workspace, Mode::Current)?;
        let original = catalog.row_value(owner, row, workspace, Mode::Original)?;
        if let Some(value) = value.filter(|v| *v > 0.0 && (all || Some(*v) != original)) {
            roots.insert((target, value as u32));
        }
    }
    if all {
        if let Some(entity) = entity {
            push_package(&mut plan.preferred, package(workspace, entity)?);
            roots.extend(
                shot_roots(workspace, entity, false)?
                    .into_iter()
                    .map(|id| (PROJECTILE, id)),
            );
        }
    }
    let mut pending: Vec<_> = roots.iter().copied().collect();
    let mut visited = BTreeSet::new();
    while let Some((typ, id)) = pending.pop() {
        if id == 0 || !visited.insert((typ, id)) {
            continue;
        }
        if visited.len() > 4096 {
            return Err("射弹依赖链超过数量限制".into());
        }
        let key = Key::Id(id);
        let bytes = workspace
            .table_bytes(typ, key, false)?
            .ok_or_else(|| format!("找不到资源引用记录 {typ:08X} #{id}"))?;
        plan.scan.push(bytes.to_vec());
        let mut add = |at, kind| -> Result<(), String> {
            let id = hash(bytes, at)?;
            if id != 0 {
                plan.resources.insert((kind, id));
            }
            Ok(())
        };
        if typ == PROJECTILE {
            for at in [72, 80, 96, 104, 112, 120] {
                add(at, PARTICLE)?;
            }
            add(128, 0xE0A48D0BE9A7453F)?;
            for at in [204, 208, 212, 216] {
                let event = integer(bytes, at)?;
                if event != 0 {
                    plan.events.insert(event);
                }
            }
            for at in [144, 156] {
                if let Some(next) = workspace.table_value(typ, key, at)? {
                    pending.push((EXPLOSION, next as u32));
                }
            }
        } else {
            add(56, PARTICLE)?;
            let count = integer(bytes, 48)? as usize;
            if count != 0 {
                let relative = usize::try_from(hash(bytes, 40)?).map_err(|_| "震屏资源偏移超限")?;
                if count > 4096 || relative == 0 {
                    return Err("震屏资源数组无效".into());
                }
                let shakes = workspace.table_payload_slice(typ, key, relative, count * 8)?;
                for id in shakes
                    .chunks_exact(8)
                    .map(|b| u64::from_le_bytes(b.try_into().unwrap()))
                {
                    if id != 0 {
                        plan.resources.insert((0xFCAAF813B4D3CC1E, id));
                    }
                }
                plan.scan.push(shakes.to_vec());
            }
            if workspace.table_value(typ, key, 80)?.unwrap_or(0.0) > 0.0 {
                if let Some(next) = workspace.table_value(typ, key, 84)? {
                    pending.push((PROJECTILE, next as u32));
                }
            }
        }
    }
    if !roots.is_empty() {
        let mut checked = BTreeSet::new();
        for donor in &catalog.owners {
            let Some(id) = donor
                .native_key
                .as_deref()
                .and_then(|key| u64::from_str_radix(key, 16).ok())
            else {
                continue;
            };
            if Some(id) == entity || !checked.insert(id) {
                continue;
            }
            for shot in shot_roots(workspace, id, true)? {
                let direct = roots.contains(&(PROJECTILE, shot));
                let mut blast = false;
                if let Some(b) = workspace.table_bytes(PROJECTILE, Key::Id(shot), true)? {
                    blast = [144, 156]
                        .into_iter()
                        .any(|at| integer(b, at).is_ok_and(|n| roots.contains(&(EXPLOSION, n))));
                }
                if direct || blast {
                    push_package(&mut plan.preferred, package(workspace, id)?);
                    break;
                }
            }
        }
    }
    if all {
        let graph = crate::catalog_refs::graph(catalog, workspace, owner)?;
        for node in graph["entries"].as_array().into_iter().flatten() {
            let kind = node["kind"].as_str().and_then(references::kind);
            if let Some((kind, id)) = kind.zip(node["id"].as_u64()) {
                if !visited.contains(&(kind, id as u32)) {
                    if let Some(b) = workspace.table_bytes(kind, Key::Id(id as u32), false)? {
                        plan.scan.push(b.to_vec());
                    }
                }
            }
        }
    }
    Ok(plan)
}
