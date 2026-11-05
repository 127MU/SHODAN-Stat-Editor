//! Per-armor passive assignment, including new combined records. Both outputs
//! are prepared together; no filesystem write or implicit installation occurs.
use crate::{
    arrays::{Kit, ARMOR_KIT},
    dlbin,
    passive::{self, Passive},
};
use std::collections::{BTreeMap, BTreeSet};

pub fn invoke(p: &serde_json::Value, export: bool) -> Result<serde_json::Value, String> {
    let text = |key: &str| p[key].as_str().ok_or_else(|| format!("缺少路径：{key}"));
    let mut total = 0;
    let passive = crate::workspace_api::bounded_read(
        std::path::Path::new(text("passive_path")?),
        &mut total,
    )?;
    let armor =
        crate::workspace_api::bounded_read(std::path::Path::new(text("armor_path")?), &mut total)?;
    let object = p["assignments"].as_object().ok_or("缺少护甲分配清单")?;
    let mut lists = BTreeMap::new();
    for (key, value) in object {
        let id = key.parse::<u32>().map_err(|_| "护甲文字 ID 无效")?;
        if id.to_string() != *key {
            return Err("护甲文字 ID 必须是规范十进制整数".into());
        }
        let list = value
            .as_array()
            .ok_or("被动列表无效")?
            .iter()
            .map(|v| u32::try_from(v.as_u64().ok_or("被动 ID 无效")?).map_err(|_| "被动 ID 越界"))
            .collect::<Result<Vec<_>, _>>()?;
        lists.insert(id, list);
    }
    let mut lines = BTreeMap::new();
    if let Some(object) = p.get("description_lines") {
        for (key, value) in object.as_object().ok_or("描述行数清单无效")? {
            let id = key.parse::<u32>().map_err(|_| "描述被动 ID 无效")?;
            if id.to_string() != *key {
                return Err("描述被动 ID 必须是规范十进制整数".into());
            }
            lines.insert(
                id,
                usize::try_from(value.as_u64().ok_or("描述行数无效")?)
                    .map_err(|_| "描述行数越界")?,
            );
        }
    }
    let report = prepare(&passive, &armor, &lists, &lines)?;
    let files = BTreeMap::from([
        (
            "generated_customization_passive_bonuses.dl_bin".into(),
            report.passives,
        ),
        (
            "generated_customization_armor_sets.dl_bin".into(),
            report.armors,
        ),
    ]);
    let mut out = serde_json::json!({"assigned":report.assigned,"added":report.added,"dropped":report.dropped,"hidden":report.hidden,"mapping":report.mapping,"installed":false});
    if export {
        out["export"] =
            crate::workspace_api::export_prepared(&files, std::path::Path::new(text("output")?))?;
    }
    Ok(out)
}

pub struct Report {
    pub passives: Vec<u8>,
    pub armors: Vec<u8>,
    pub assigned: usize,
    pub added: usize,
    pub dropped: Vec<u32>,
    pub hidden: Vec<u32>,
    pub mapping: BTreeMap<u32, u32>,
}
fn word(b: &[u8], at: usize) -> Result<u32, String> {
    Ok(u32::from_le_bytes(
        b.get(at..at.checked_add(4).ok_or("护甲偏移溢出")?)
            .ok_or("护甲字段越界")?
            .try_into()
            .unwrap(),
    ))
}
fn key(b: &[u8]) -> u32 {
    u32::from_le_bytes(b[..4].try_into().unwrap())
}
fn combine(parts: &[&Passive], id: u32, dropped: &mut Vec<u32>, hidden: &mut Vec<u32>) -> Passive {
    let mut out = parts[0].clone();
    out.id = id;
    out.modifiers.clear();
    out.stats.clear();
    let mut have = BTreeSet::new();
    for source in parts {
        for row in &source.modifiers {
            if have.insert(key(row)) {
                out.modifiers.push(*row);
            } else {
                dropped.push(key(row));
            }
        }
        // Weapon-stat modifiers are applied sequentially, not deduplicated.
        out.stats.extend_from_slice(&source.stats);
    }
    let mut shown = BTreeSet::new();
    for round in 0..3 {
        for source in parts {
            if let Some(row) = source
                .modifiers
                .iter()
                .filter(|r| r[12..16] != [0; 4])
                .nth(round)
            {
                if shown.len() < 3 {
                    shown.insert(key(row));
                }
            }
        }
    }
    for row in &mut out.modifiers {
        if row[12..16] != [0; 4] && !shown.contains(&key(row)) {
            hidden.push(key(row));
            row[12..16].fill(0);
        }
    }
    out
}
pub fn prepare(
    passive_file: &[u8],
    armor_file: &[u8],
    lists: &BTreeMap<u32, Vec<u32>>,
    one_line: &BTreeMap<u32, usize>,
) -> Result<Report, String> {
    if lists.len() > 16384 {
        return Err("护甲分配数量过多".into());
    }
    let blocks = dlbin::index(passive_file).map_err(|e| e.to_string())?;
    let kits = dlbin::index(armor_file).map_err(|e| e.to_string())?;
    let mut catalog = passive::catalog(passive_file)?;
    let mut passives = passive_file.to_vec();
    for (&id, &lines) in one_line {
        if lines > 3 {
            return Err("护甲描述最多保留三条".into());
        }
        let p = catalog.get_mut(&id).ok_or("需要调整描述的被动不存在")?;
        let block = blocks
            .iter()
            .find(|b| {
                b.type_id == passive::TYPE && word(passive_file, b.payload.start).ok() == Some(id)
            })
            .ok_or("被动数据块不存在")?;
        let mut shown = 0;
        for (i, row) in p.modifiers.iter_mut().enumerate() {
            if row[12..16] != [0; 4] {
                if shown >= lines {
                    row[12..16].fill(0);
                    passives[block.payload.start + 56 + i * 16 + 12
                        ..block.payload.start + 56 + i * 16 + 16]
                        .fill(0);
                }
                shown += 1;
            }
        }
    }
    let mut available = BTreeSet::new();
    for block in &kits {
        if block.type_id == ARMOR_KIT {
            let kit = Kit::parse(&armor_file[block.payload.clone()])?;
            if kit.kind == 0 {
                available.insert(kit.name);
            }
        }
    }
    let mut next = catalog
        .keys()
        .max()
        .copied()
        .unwrap_or(0)
        .checked_add(1)
        .ok_or("护甲被动 ID 已用尽")?
        .max(60);
    let mut mapping = BTreeMap::new();
    let mut allocated = BTreeMap::new();
    let mut additions = Vec::new();
    let mut dropped = Vec::new();
    let mut hidden = Vec::new();
    for (&armor, list) in lists {
        if !available.contains(&armor) {
            return Err(format!("当前数据没有该护甲条目：{armor}"));
        }
        if list.len() > 128 || list.iter().any(|id| !catalog.contains_key(id)) {
            return Err("被动列表包含不存在的记录或数量过多".into());
        }
        let id = if list.len() < 2 {
            list.first().copied().unwrap_or(0)
        } else if let Some(id) = allocated.get(list) {
            *id
        } else {
            if next == crate::armor_profiles::EVERY {
                next = next.checked_add(1).ok_or("护甲被动 ID 已用尽")?;
            }
            let id = next;
            next = next.checked_add(1).ok_or("护甲被动 ID 已用尽")?;
            let parts = list.iter().map(|id| &catalog[id]).collect::<Vec<_>>();
            let merged = combine(&parts, id, &mut dropped, &mut hidden);
            let payload = merged.encode()?;
            let source = blocks
                .iter()
                .find(|b| {
                    b.type_id == passive::TYPE
                        && word(passive_file, b.payload.start).ok() == list.first().copied()
                })
                .ok_or("组合来源块不存在")?;
            let mut head = passive_file[source.header_offset..source.payload.start].to_vec();
            head[12..16].copy_from_slice(
                &u32::try_from(payload.len())
                    .map_err(|_| "被动数据块过大")?
                    .to_le_bytes(),
            );
            head.extend(payload);
            additions.push(head);
            allocated.insert(list.clone(), id);
            id
        };
        mapping.insert(armor, id);
    }
    let mut armors = armor_file.to_vec();
    let mut assigned = 0;
    for block in &kits {
        if block.type_id == ARMOR_KIT {
            let kit = Kit::parse(&armor_file[block.payload.clone()])?;
            if kit.kind == 0 {
                if let Some(id) = mapping.get(&kit.name) {
                    armors[block.payload.start + 28..block.payload.start + 32]
                        .copy_from_slice(&id.to_le_bytes());
                    assigned += 1;
                }
            }
        }
    }
    if !additions.is_empty() {
        if blocks.first().is_none_or(|b| b.header_offset != 4)
            || word(passive_file, 0)? as usize != blocks.len()
            || blocks
                .last()
                .is_none_or(|b| b.payload.end != passive_file.len())
        {
            return Err("护甲被动文件计数或尾部布局不匹配".into());
        }
        passives[..4].copy_from_slice(
            &u32::try_from(blocks.len() + additions.len())
                .map_err(|_| "护甲块数量溢出")?
                .to_le_bytes(),
        );
        for addition in &additions {
            passives.extend(addition);
        }
    }
    // Reparse both complete outputs before exposing either half.
    passive::catalog(&passives)?;
    dlbin::index(&armors).map_err(|e| e.to_string())?;
    Ok(Report {
        passives,
        armors,
        assigned,
        added: additions.len(),
        dropped,
        hidden,
        mapping,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn row(id: u32) -> [u8; 16] {
        let mut r = [0; 16];
        r[..4].copy_from_slice(&id.to_le_bytes());
        r[12..16].copy_from_slice(&(id + 100).to_le_bytes());
        r
    }
    #[test]
    fn first_modifier_wins_and_descriptions_take_turns_without_losing_stats() {
        let a = Passive {
            id: 1,
            header: vec![0; 56],
            modifiers: vec![row(1), row(2), row(3), row(4)],
            stats: vec![[0; 12]],
        };
        let mut b = a.clone();
        b.modifiers = vec![row(5), row(1)];
        let mut dropped = Vec::new();
        let mut hidden = Vec::new();
        let p = combine(&[&a, &b], 60, &mut dropped, &mut hidden);
        assert_eq!(p.modifiers.len(), 5);
        assert_eq!(p.stats.len(), 2);
        assert_eq!(dropped, vec![1]);
        assert_eq!(
            p.modifiers
                .iter()
                .filter(|r| r[12..16] != [0; 4])
                .map(|r| key(r))
                .collect::<Vec<_>>(),
            vec![1, 2, 5]
        );
        assert_eq!(hidden, vec![3, 4]);
    }
}
