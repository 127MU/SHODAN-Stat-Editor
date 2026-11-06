//! Current-value reference graph with separate namespaces and bounded traversal.
use crate::{
    session::Session,
    tables::{self, Key, Table},
    Kind,
};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
pub struct Data<'a> {
    files: Vec<&'a Session>,
    tables: BTreeMap<u32, Vec<(usize, Table)>>,
}

#[cfg(test)]
mod tests {
    use super::*;
    fn block(typ: u32, stride: usize, id: u32, refs: &[(usize, u32)]) -> Vec<u8> {
        let mut b = b"LDLD\x01\0\0\0".to_vec();
        b.extend(typ.to_le_bytes());
        b.extend(((16 + stride) as u32).to_le_bytes());
        b.extend([0; 8]);
        b.extend([0; 8]);
        b.extend(1u32.to_le_bytes());
        b.extend([0; 4]);
        let mut row = vec![0; stride];
        row[..4].copy_from_slice(&id.to_le_bytes());
        for (at, value) in refs {
            row[*at..*at + 4].copy_from_slice(&value.to_le_bytes());
        }
        b.extend(row);
        b
    }
    #[test]
    fn cross_file_cycles_missing_and_current_edits_are_preserved() {
        let mut a = Session::new(block(0xBD4042C2, 272, 1, &[(60, 2), (144, 99)]), None).unwrap();
        let b = Session::new(
            [
                block(0xE0A72CF0, 76, 2, &[(44, 3)]),
                block(0xC63E0B22, 160, 3, &[(44, 2)]),
            ]
            .concat(),
            None,
        )
        .unwrap();
        let roots = vec![("shot".into(), 1, "当前记录".into())];
        let graph = Data::new(vec![&a, &b]).unwrap().graph(&roots).unwrap();
        let entries = graph["entries"].as_array().unwrap();
        assert!(entries.iter().any(|v| v["repeated"] == true));
        assert!(entries
            .iter()
            .any(|v| v["key"] == "blast:99" && v["missing"] == true));
        a.index_table(
            0,
            tables::Layout::Rows {
                stride: 272,
                id_offset: 0,
            },
        )
        .unwrap();
        a.set(
            crate::session::Field {
                block: 0,
                record: Key::Id(1),
                relative: 60,
                kind: Kind::U32,
            },
            0.0,
        )
        .unwrap();
        let graph = Data::new(vec![&a, &b]).unwrap().graph(&roots).unwrap();
        assert!(!graph["entries"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v["kind"] == "damage"));
    }
}
pub(crate) fn kind(name: &str) -> Option<u32> {
    Some(match name {
        "shot" => 0xBD4042C2,
        "blast" => 0x2AEA2592,
        "damage" => 0xE0A72CF0,
        "status" => 0xC63E0B22,
        "arc" => 0xAFDF0267,
        "beam" => 0xC5085606,
        _ => return None,
    })
}
impl<'a> Data<'a> {
    pub fn new(files: Vec<&'a Session>) -> Result<Self, String> {
        let mut result = Self {
            files,
            tables: BTreeMap::new(),
        };
        for (file, session) in result.files.iter().enumerate() {
            for block in crate::dlbin::index(session.snapshot()).map_err(|e| e.to_string())? {
                let layouts = tables::layouts(block.type_id);
                if layouts.is_empty() {
                    continue;
                }
                let mut parsed = layouts
                    .into_iter()
                    .filter_map(|layout| tables::parse(session.snapshot(), &block, layout).ok())
                    .collect::<Vec<_>>();
                if parsed.len() != 1 {
                    return Err(format!("引用表 {:08X} 布局无法唯一识别", block.type_id));
                }
                let table = parsed.remove(0);
                if table.duplicate_keys != 0 {
                    return Err("引用表含重复记录 ID".into());
                }
                result
                    .tables
                    .entry(block.type_id)
                    .or_default()
                    .push((file, table));
            }
        }
        Ok(result)
    }
    fn number(
        &self,
        typ: u32,
        key: Key,
        relative: usize,
        kind: Kind,
    ) -> Result<Option<f64>, String> {
        let matches = self
            .tables
            .get(&typ)
            .into_iter()
            .flatten()
            .filter(|(_, t)| t.rows.contains_key(&key))
            .collect::<Vec<_>>();
        if matches.len() > 1 {
            return Err("跨数据文件存在重复引用身份".into());
        }
        let Some((file, table)) = matches.first() else {
            return Ok(None);
        };
        self.files[*file]
            .number_at(table.field_offset(key, relative, 4)?, kind)
            .map(Some)
    }
    pub fn roots(&self, entity: u64) -> Result<Vec<(String, u32, String)>, String> {
        roots(false, |typ, offset| {
            self.number(typ, Key::Hash(entity), offset, Kind::U32)
        })
    }
    pub fn graph(&self, roots: &[(String, u32, String)]) -> Result<Value, String> {
        graph(roots, |typ, id, offset| {
            self.number(typ, Key::Id(id), offset, Kind::U32)
        })
    }
}

pub(crate) fn roots(
    bound_fire_modes: bool,
    number: impl Fn(u32, usize) -> Result<Option<f64>, String>,
) -> Result<Vec<(String, u32, String)>, String> {
    let mut roots = Vec::new();
    for (typ, offset, target, label) in [
        (0x45171B68, 0, "shot", "主射击模式"),
        (0x45171B68, 576, "shot", "第二射击模式"),
        (0x66081072, 64, "shot", "主弹种"),
        (0x66081072, 68, "shot", "备选弹种"),
        (0xEAC335A1, 4, "shot", "蓄力阶段 1"),
        (0xEAC335A1, 28, "shot", "蓄力阶段 2"),
        (0xEAC335A1, 52, "shot", "蓄力阶段 3"),
        (0xF0721C2C, 0, "beam", "激光类型"),
        (0xB87BA9ED, 0, "arc", "电弧类型"),
        (0x8E551126, 200, "damage", "喷流伤害"),
        (0x8E551126, 196, "shot", "喷流射弹"),
        (0xBBA9003F, 12, "damage", "近战伤害"),
    ] {
        if bound_fire_modes && matches!(typ, 0x45171B68 | 0x66081072) {
            continue;
        }
        if let Some(id) = number(typ, offset)? {
            if id > 0.0 {
                roots.push((target.into(), id as u32, label.into()));
            }
        }
    }
    Ok(roots)
}

pub(crate) fn graph(
    roots: &[(String, u32, String)],
    number: impl Fn(u32, u32, usize) -> Result<Option<f64>, String>,
) -> Result<Value, String> {
    let mut out = Vec::new();
    let mut expanded = BTreeSet::new();
    let mut edges = BTreeSet::new();
    let mut limited = false;
    let mut pending = roots
        .iter()
        .rev()
        .map(|(kind, id, via)| (kind.clone(), *id, via.clone(), String::new(), 0))
        .collect::<Vec<_>>();
    while let Some((name, id, via, parent, depth)) = pending.pop() {
        if id == 0 {
            continue;
        }
        let typ = kind(&name).ok_or("未知引用命名空间")?;
        let key = format!("{name}:{id}");
        if !edges.insert((parent.clone(), key.clone(), via.clone())) {
            continue;
        }
        if out.len() >= 512 || depth > 24 {
            limited = true;
            continue;
        }
        let exists = number(typ, id, 0)?.is_some();
        let repeated = expanded.contains(&key);
        out.push(json!({"key":key,"kind":name,"id":id,"parent":parent,"via":via,"depth":depth,"missing":!exists,"repeated":repeated}));
        if !exists || !expanded.insert(key.clone()) {
            continue;
        }
        let specs: Vec<(&str, usize, String)> = match name.as_str() {
            "shot" => vec![
                ("damage", 60, "直接命中伤害".into()),
                ("blast", 144, "命中爆炸".into()),
                ("blast", 156, "到期爆炸".into()),
            ],
            "blast" => {
                let mut s = vec![("damage", 4, "爆炸伤害".into())];
                if number(typ, id, 80)?.unwrap_or(0.0) > 0.0 {
                    s.push(("shot", 84, "破片射弹".into()));
                }
                s.push(("arc", 120, "爆炸电弧".into()));
                s
            }
            "damage" => (0..4)
                .map(|slot| ("status", 44 + slot * 8, format!("状态槽 {}", slot + 1)))
                .collect(),
            "status" => vec![("damage", 44, "每跳伤害".into())],
            "arc" => vec![("damage", 36, "电弧伤害".into())],
            "beam" => vec![("damage", 12, "激光伤害".into())],
            _ => vec![],
        };
        for (target, offset, label) in specs.into_iter().rev() {
            if let Some(value) = number(typ, id, offset)? {
                if value > 0.0 {
                    pending.push((target.into(), value as u32, label, key.clone(), depth + 1));
                }
            }
        }
    }
    Ok(json!({"entries":out,"limited":limited,"read_only":true}))
}
