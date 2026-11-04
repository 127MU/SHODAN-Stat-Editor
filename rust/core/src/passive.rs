//! Armor passive composition from current stored rows, without retuning values.
use std::collections::{BTreeMap, BTreeSet};
pub const TYPE: u32 = 0x63CE0FEB;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Policy {
    Stack,
    Strongest,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Profile {
    pub own: bool,
    pub enabled: Vec<u32>,
    pub policy: Policy,
}
impl Default for Profile {
    fn default() -> Self {
        Self {
            own: true,
            enabled: Vec::new(),
            policy: Policy::Stack,
        }
    }
}
#[derive(Clone)]
pub struct Passive {
    pub id: u32,
    pub header: Vec<u8>,
    pub modifiers: Vec<[u8; 16]>,
    pub stats: Vec<[u8; 12]>,
}
fn u32at(bytes: &[u8], at: usize) -> Result<u32, String> {
    Ok(u32::from_le_bytes(
        bytes
            .get(at..at + 4)
            .ok_or("护甲数据越界")?
            .try_into()
            .unwrap(),
    ))
}
fn array<const N: usize>(
    bytes: &[u8],
    pointer: usize,
    count: usize,
) -> Result<Vec<[u8; N]>, String> {
    let n = u32at(bytes, count)? as usize;
    if n == 0 {
        return Ok(Vec::new());
    }
    let offset = u64::from_le_bytes(
        bytes
            .get(pointer..pointer + 8)
            .ok_or("护甲数组指针越界")?
            .try_into()
            .unwrap(),
    );
    let offset = usize::try_from(offset).map_err(|_| "护甲数组偏移溢出")?;
    let end = n
        .checked_mul(N)
        .and_then(|v| offset.checked_add(v))
        .ok_or("护甲数组长度溢出")?;
    if offset < 56 {
        return Err("护甲数组覆盖固定头部".into());
    }
    let rows = bytes.get(offset..end).ok_or("护甲数组越界")?;
    Ok(rows
        .chunks_exact(N)
        .map(|r| r.try_into().unwrap())
        .collect())
}
impl Passive {
    pub fn parse(bytes: &[u8]) -> Result<Self, String> {
        let header = bytes.get(..56).ok_or("护甲被动头部不完整")?.to_vec();
        let modifiers = array(bytes, 16, 24)?;
        let stats = array(bytes, 32, 40)?;
        let expected_stats = 56usize
            .checked_add(modifiers.len().checked_mul(16).ok_or("护甲长度溢出")?)
            .ok_or("护甲长度溢出")?;
        let expected_end = expected_stats
            .checked_add(stats.len().checked_mul(12).ok_or("护甲长度溢出")?)
            .ok_or("护甲长度溢出")?;
        let pointer = |at| u64::from_le_bytes(bytes[at..at + 8].try_into().unwrap());
        if expected_end != bytes.len()
            || (!modifiers.is_empty() && pointer(16) != 56)
            || (!stats.is_empty() && pointer(32) != expected_stats as u64)
        {
            return Err("护甲数组布局不匹配，拒绝丢弃未识别数据".into());
        }
        Ok(Self {
            id: u32at(bytes, 0)?,
            header,
            modifiers,
            stats,
        })
    }
    pub fn encode(&self) -> Result<Vec<u8>, String> {
        let mut out = self.header.clone();
        if out.len() != 56 {
            return Err("护甲被动头部无效".into());
        }
        out[..4].copy_from_slice(&self.id.to_le_bytes());
        let modifiers = u32::try_from(self.modifiers.len()).map_err(|_| "护甲修饰项过多")?;
        let stats = u32::try_from(self.stats.len()).map_err(|_| "武器属性项过多")?;
        let stat_offset = 56u64 + modifiers as u64 * 16;
        out[16..24].copy_from_slice(&(if modifiers == 0 { u64::MAX } else { 56 }).to_le_bytes());
        out[24..28].copy_from_slice(&modifiers.to_le_bytes());
        out[32..40]
            .copy_from_slice(&(if stats == 0 { u64::MAX } else { stat_offset }).to_le_bytes());
        out[40..44].copy_from_slice(&stats.to_le_bytes());
        for row in &self.modifiers {
            out.extend(row);
        }
        for row in &self.stats {
            out.extend(row);
        }
        Ok(out)
    }
}
fn strength(typ: u32, value: f32) -> f64 {
    if typ == 2 {
        if value <= 0.0 {
            f64::INFINITY
        } else {
            (value as f64).ln().abs()
        }
    } else {
        value.abs() as f64
    }
}
fn combine<const N: usize>(rows: Vec<[u8; N]>, policy: Policy) -> Result<Vec<[u8; N]>, String> {
    let mut index = BTreeMap::new();
    let mut values: BTreeMap<u32, Vec<f32>> = BTreeMap::new();
    let mut out: Vec<[u8; N]> = Vec::new();
    for row in rows {
        let key = u32at(&row, 0)?;
        let value = f32::from_le_bytes(row[8..12].try_into().unwrap());
        if !value.is_finite() {
            return Err("护甲修饰项数值无效".into());
        }
        // The compatibility engine deduplicates identical numeric values
        // before comparing strength, even when their operation types differ.
        let previous_values = values.entry(key).or_default();
        if previous_values.contains(&value) {
            continue;
        }
        previous_values.push(value);
        let typ = if N == 16 { u32at(&row, 4)? } else { 2 };
        if let Some(&at) = index.get(&key) {
            if policy == Policy::Strongest {
                let previous: &[u8; N] = &out[at];
                let previous_type = if N == 16 { u32at(previous, 4)? } else { 2 };
                let old = f32::from_le_bytes(previous[8..12].try_into().unwrap());
                if strength(typ, value) > strength(previous_type, old) {
                    out[at] = row;
                }
            }
        } else {
            index.insert(key, out.len());
            out.push(row);
        }
    }
    Ok(out)
}
pub fn compose(
    catalog: &BTreeMap<u32, Passive>,
    target: u32,
    profile: &Profile,
) -> Result<Passive, String> {
    let own = catalog.get(&target).ok_or("目标护甲被动不存在")?;
    let mut result = own.clone();
    let mut mods = Vec::new();
    let mut stats = Vec::new();
    if profile.own {
        mods.extend(own.modifiers.iter().copied());
        stats.extend(own.stats.iter().copied());
    }
    let mut seen = BTreeSet::new();
    for id in &profile.enabled {
        if !seen.insert(*id) || (*id == target && profile.own) {
            continue;
        }
        let source = catalog
            .get(id)
            .ok_or_else(|| format!("叠加来源被动不存在：{id}"))?;
        mods.extend(source.modifiers.iter().copied());
        stats.extend(source.stats.iter().copied());
    }
    result.modifiers = combine(mods, profile.policy)?;
    result.stats = combine(stats, profile.policy)?;
    let mut shown = 0;
    for row in &mut result.modifiers {
        if row[12..16] != [0; 4] {
            shown += 1;
            if shown > 3 {
                row[12..16].fill(0);
            }
        }
    }
    Ok(result)
}
pub struct Report {
    pub bytes: Vec<u8>,
    pub groups: usize,
    pub sources: usize,
}
pub fn catalog(file: &[u8]) -> Result<BTreeMap<u32, Passive>, String> {
    let mut out = BTreeMap::new();
    for block in crate::dlbin::index(file).map_err(|e| e.to_string())? {
        if block.type_id != TYPE {
            continue;
        }
        let p = Passive::parse(&file[block.payload])?;
        if p.id == crate::armor_profiles::EVERY || out.insert(p.id, p).is_some() {
            return Err("护甲被动 ID 无效或重复".into());
        }
    }
    if out.is_empty() {
        return Err("护甲数据中没有被动记录".into());
    }
    Ok(out)
}
pub fn rebuild(file: &[u8], profiles: &BTreeMap<u32, Profile>) -> Result<Report, String> {
    let blocks = crate::dlbin::index(file).map_err(|e| e.to_string())?;
    let catalog = catalog(file)?;
    let mut out = Vec::new();
    let mut cursor = 0;
    let mut groups = 0;
    let mut sources = 0;
    for id in profiles.keys() {
        if !catalog.contains_key(id) {
            return Err(format!("目标被动不存在：{id}"));
        }
    }
    for block in &blocks {
        if block.type_id != TYPE {
            continue;
        }
        let id = u32at(&file[block.payload.clone()], 0)?;
        let Some(profile) = profiles.get(&id) else {
            continue;
        };
        if profile.own && profile.enabled.iter().all(|source| *source == id) {
            continue;
        }
        let merged = compose(&catalog, id, profile)?;
        let payload = merged.encode()?;
        out.extend(&file[cursor..block.header_offset]);
        let mut head = file[block.header_offset..block.payload.start].to_vec();
        head[12..16].copy_from_slice(
            &u32::try_from(payload.len())
                .map_err(|_| "护甲块过大")?
                .to_le_bytes(),
        );
        out.extend(head);
        out.extend(payload);
        cursor = block.payload.end;
        groups += 1;
        sources += profile
            .enabled
            .iter()
            .copied()
            .filter(|v| *v != id || !profile.own)
            .collect::<BTreeSet<_>>()
            .len();
    }
    out.extend(&file[cursor..]);
    crate::dlbin::index(&out).map_err(|e| e.to_string())?;
    Ok(Report {
        bytes: out,
        groups,
        sources,
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    fn row(key: u32, value: f32) -> [u8; 16] {
        let mut r = [0; 16];
        r[..4].copy_from_slice(&key.to_le_bytes());
        r[4..8].copy_from_slice(&2u32.to_le_bytes());
        r[8..12].copy_from_slice(&value.to_le_bytes());
        r[12] = 1;
        r
    }
    fn passive(id: u32, mods: Vec<[u8; 16]>) -> Passive {
        Passive {
            id,
            header: vec![0; 56],
            modifiers: mods,
            stats: vec![],
        }
    }
    fn block(p: &Passive) -> Vec<u8> {
        let data = p.encode().unwrap();
        let mut b = b"LDLD\x01\0\0\0".to_vec();
        b.extend(TYPE.to_le_bytes());
        b.extend((data.len() as u32).to_le_bytes());
        b.extend([0; 8]);
        b.extend(data);
        b
    }
    #[test]
    fn clear_profiles_is_noop_and_rebuild_preserves_unrelated_bytes() {
        let a = passive(1, vec![row(10, 1.3)]);
        let b = passive(2, vec![row(11, 2.0)]);
        let file = [block(&a), vec![5, 4, 3, 2], block(&b)].concat();
        assert_eq!(rebuild(&file, &BTreeMap::new()).unwrap().bytes, file);
        let profiles = BTreeMap::from([(
            1,
            Profile {
                enabled: vec![2],
                ..Default::default()
            },
        )]);
        let r = rebuild(&file, &profiles).unwrap();
        assert_eq!(r.groups, 1);
        assert_eq!(r.sources, 1);
        let blocks = crate::dlbin::index(&r.bytes).unwrap();
        let merged = Passive::parse(&r.bytes[blocks[0].payload.clone()]).unwrap();
        assert_eq!(merged.modifiers.len(), 2);
        assert_eq!(
            &r.bytes[blocks[1].header_offset - 4..blocks[1].header_offset],
            &[5, 4, 3, 2]
        );
        assert_eq!(&r.bytes[blocks[1].header_offset..], block(&b));
    }
    #[test]
    fn strongest_and_description_cap_keep_effects() {
        let catalog = BTreeMap::from([
            (1, passive(1, vec![row(10, 1.3)])),
            (
                2,
                passive(
                    2,
                    vec![row(10, 2.0), row(11, 3.0), row(12, 4.0), row(13, 5.0)],
                ),
            ),
        ]);
        let p = compose(
            &catalog,
            1,
            &Profile {
                enabled: vec![2],
                policy: Policy::Strongest,
                own: true,
            },
        )
        .unwrap();
        assert_eq!(p.modifiers.len(), 4);
        assert_eq!(p.modifiers[0], row(10, 2.0));
        assert_eq!(p.modifiers[3][12..16], [0; 4]);
        assert!(compose(
            &catalog,
            1,
            &Profile {
                enabled: vec![99],
                ..Default::default()
            }
        )
        .is_err());
        let empty = compose(
            &catalog,
            1,
            &Profile {
                own: false,
                ..Default::default()
            },
        )
        .unwrap();
        assert!(empty.modifiers.is_empty());
    }
    #[test]
    fn strongest_deduplicates_equal_values_before_comparing_operation_types() {
        let ratio = row(10, 2.0);
        let mut amount = ratio;
        amount[4..8].copy_from_slice(&1u32.to_le_bytes());
        let catalog = BTreeMap::from([
            (1, passive(1, vec![ratio])),
            (2, passive(2, vec![amount, row(10, 3.0)])),
        ]);
        let result = compose(
            &catalog,
            1,
            &Profile {
                own: true,
                enabled: vec![2],
                policy: Policy::Strongest,
            },
        )
        .unwrap();
        assert_eq!(result.modifiers, vec![row(10, 3.0)]);
        let result = compose(
            &catalog,
            1,
            &Profile {
                own: true,
                enabled: vec![2],
                policy: Policy::Stack,
            },
        )
        .unwrap();
        assert_eq!(result.modifiers, vec![ratio]);
    }
}
