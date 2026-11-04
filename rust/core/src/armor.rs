//! Named armor numeric edits and AVP1 snapshots. Current data never supplies defaults.
use crate::{baseline::Baseline, document::Document, passive, Kind};
use std::collections::BTreeMap;
pub struct Row {
    pub key: String,
    pub label: String,
    pub passive: u32,
    pub offsets: Vec<usize>,
    pub original: Option<f32>,
}
pub struct Armor {
    document: Document,
    pub rows: BTreeMap<String, Row>,
}
pub fn catalog() -> serde_json::Value {
    serde_json::from_str(include_str!("../data/armor-catalog.json"))
        .expect("embedded armor catalog")
}
fn numbers(bytes: &[u8]) -> Result<BTreeMap<String, (u32, f32, usize)>, String> {
    let mut out = BTreeMap::new();
    let mut seen = std::collections::BTreeSet::new();
    for block in crate::dlbin::index(bytes).map_err(|e| e.to_string())? {
        if block.type_id != passive::TYPE {
            continue;
        }
        let p = passive::Passive::parse(&bytes[block.payload.clone()])?;
        if !seen.insert(p.id) {
            return Err("护甲被动 ID 重复".into());
        }
        let mut occurrences = BTreeMap::new();
        let mods = p
            .modifiers
            .iter()
            .enumerate()
            .map(|(i, r)| (16, r.as_slice(), 56 + i * 16));
        let stats = p
            .stats
            .iter()
            .enumerate()
            .map(|(i, r)| (12, r.as_slice(), 56 + p.modifiers.len() * 16 + i * 12));
        for (width, row, relative) in mods.chain(stats) {
            let effect = u32::from_le_bytes(row[..4].try_into().unwrap());
            let op = if width == 16 {
                u32::from_le_bytes(row[4..8].try_into().unwrap())
            } else {
                0
            };
            let identity = format!("{width}:{effect}:{op}");
            let ordinal = occurrences.entry(identity.clone()).or_insert(0);
            *ordinal += 1;
            let key = format!("{}:{identity}:{}", p.id, *ordinal);
            let value = f32::from_le_bytes(row[8..12].try_into().unwrap());
            if !value.is_finite() {
                return Err("护甲参数包含非有限数值".into());
            }
            out.insert(key, (p.id, value, block.payload.start + relative + 8));
        }
    }
    Ok(out)
}
impl Armor {
    pub fn new(current: Vec<u8>, baseline: Baseline) -> Result<Self, String> {
        let originals = numbers(baseline.bytes())?;
        let values = numbers(&current)?;
        let data = catalog();
        let mut rows: BTreeMap<String, Row> = BTreeMap::new();
        let mut groups: BTreeMap<(u32, String), String> = BTreeMap::new();
        for (key, (pid, _, offset)) in values {
            let parts: Vec<_> = key.split(':').collect();
            if parts[4] != "1" {
                continue;
            }
            let width = parts[1].parse::<u32>().map_err(|_| "护甲键无效")?;
            let effect = parts[2].parse::<u32>().map_err(|_| "护甲键无效")?;
            let op = parts[3].parse::<u32>().map_err(|_| "护甲键无效")?;
            let passive = data["list"]
                .as_array()
                .unwrap()
                .iter()
                .find(|p| p["id"].as_u64() == Some(pid as u64));
            let descriptor = passive
                .and_then(|p| p["effects"].as_array())
                .and_then(|effects| {
                    effects.iter().find(|e| {
                        e["a"].as_u64() == Some(effect as u64)
                            && e["b"].as_u64() == Some(op as u64)
                            && ((e["kind"] == "stat" && width == 12)
                                || (e["kind"] == "row" && width == 16))
                    })
                });
            let Some(e) = descriptor else {
                continue;
            };
            let label = e["label"].as_str().unwrap_or("");
            if label.contains("不明") || label.contains("标记") {
                continue;
            }
            let original = originals.get(&key).map(|r| r.1);
            let mut row = Row {
                key: key.clone(),
                label: label.into(),
                passive: pid,
                offsets: vec![offset],
                original,
            };
            if let Some(group) = e["group"].as_str() {
                let group = (pid, group.to_string());
                if let Some(existing) = groups.get(&group).cloned() {
                    let mut previous = rows.remove(&existing).ok_or("护甲分组无效")?;
                    if e["canonical"] == true {
                        row.offsets.extend(previous.offsets);
                        rows.insert(key.clone(), row);
                        groups.insert(group, key);
                    } else {
                        previous.offsets.push(offset);
                        rows.insert(existing, previous);
                    }
                    continue;
                }
                groups.insert(group, key.clone());
            }
            rows.insert(key, row);
        }
        Ok(Self {
            document: Document::new(current, None)?,
            rows,
        })
    }
    pub fn value(&self, key: &str) -> Result<f64, String> {
        let row = self.rows.get(key).ok_or("当前版本没有该护甲参数")?;
        self.document
            .value(row.offsets[0], Kind::F32)
            .map_err(str::to_string)
    }
    pub fn set(&mut self, key: &str, value: f64) -> Result<(), String> {
        let row = self.rows.get(key).ok_or("当前版本没有该护甲参数")?;
        let plan: Vec<_> = row
            .offsets
            .iter()
            .map(|at| (*at, Kind::F32, value))
            .collect();
        self.document.set_batch(&plan).map_err(str::to_string)
    }
    pub fn capture(&self) -> Result<String, String> {
        let mut out = "AVP1\n".to_string();
        for (key, row) in &self.rows {
            let original = row.original.ok_or("护甲参数缺少可信原值")?;
            out.push_str(&format!("{key} {original} {}\n", self.value(key)?));
        }
        Ok(out)
    }
    pub fn apply_snapshot(&mut self, text: &str) -> Result<(), String> {
        if text.len() > 1024 * 1024 || !text.starts_with("AVP1\n") {
            return Err("护甲预设格式无效".into());
        }
        let mut wanted = BTreeMap::new();
        for line in text[5..].lines().filter(|l| !l.is_empty()) {
            let p: Vec<_> = line.split_whitespace().collect();
            if p.len() != 3 {
                return Err("护甲预设行格式无效".into());
            }
            let row = self.rows.get(p[0]).ok_or("护甲预设含失效参数")?;
            let base = p[1].parse::<f64>().map_err(|_| "护甲基准无效")?;
            if !base.is_finite() || Some(base as f32) != row.original {
                return Err("护甲预设基准与当前版本不一致".into());
            }
            let value = p[2].parse::<f64>().map_err(|_| "护甲数值无效")?;
            if wanted.insert(p[0], value).is_some() {
                return Err("护甲预设含重复参数".into());
            }
        }
        let mut plan = Vec::new();
        for (key, row) in &self.rows {
            let value = match wanted.get(key.as_str()) {
                Some(v) => *v,
                None => row.original.ok_or("缺少可信护甲基准")? as f64,
            };
            for at in &row.offsets {
                plan.push((*at, Kind::F32, value));
            }
        }
        self.document.set_batch(&plan).map_err(str::to_string)
    }
    pub fn render(&self, disk: &[u8]) -> Result<Vec<u8>, String> {
        self.document.render(disk).map_err(str::to_string)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn editor() -> Armor {
        let bytes = include_bytes!("../data/armor-baseline.bin").to_vec();
        let baseline = Baseline::shipped(
            "generated_customization_passive_bonuses.dl_plain",
            bytes.clone(),
        )
        .unwrap();
        Armor::new(bytes, baseline).unwrap()
    }
    #[test]
    fn armor_snapshot_restores_numeric_values_and_missing_entries_use_trusted_defaults() {
        let mut a = editor();
        assert!(!a.rows.is_empty());
        let key = a.rows.keys().next().unwrap().clone();
        let original = a.value(&key).unwrap();
        let snapshot = a.capture().unwrap();
        a.set(&key, 99.0).unwrap();
        a.apply_snapshot(&snapshot).unwrap();
        assert_eq!(a.value(&key).unwrap(), original);
        a.set(&key, 99.0).unwrap();
        a.apply_snapshot("AVP1\n").unwrap();
        assert_eq!(a.value(&key).unwrap(), original);
        assert!(a.apply_snapshot(&format!("AVP1\n{key} NaN 4\n")).is_err());
        assert!(a
            .apply_snapshot(&(snapshot + "999:16:1:1:1 1 2\n"))
            .is_err());
        assert_eq!(a.value(&key).unwrap(), original);
    }
}
