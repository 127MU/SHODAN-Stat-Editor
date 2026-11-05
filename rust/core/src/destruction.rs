//! Stored destruction settings, linked by entity identity rather than temporary
//! relocated pointers. Encoding always leaves the stored pointer unresolved.
use crate::dlbin;
use std::collections::{BTreeMap, BTreeSet};
pub const SETTINGS: u32 = 0xD6A11545;
pub const MAP: u32 = 0x49795156;
pub const TIERS: u32 = 0xFB45E243;
#[derive(Clone)]
pub struct Index {
    pub entities: BTreeMap<u64, usize>,
    pub settings: Vec<dlbin::Block>,
    pub tiers: BTreeMap<u32, u32>,
}
fn word(b: &[u8], at: usize) -> Result<u32, String> {
    Ok(u32::from_le_bytes(
        b.get(at..at.checked_add(4).ok_or("拆毁字段偏移溢出")?)
            .ok_or("拆毁字段越界")?
            .try_into()
            .unwrap(),
    ))
}
fn wide(b: &[u8], at: usize) -> Result<u64, String> {
    Ok(u64::from_le_bytes(
        b.get(at..at.checked_add(8).ok_or("拆毁字段偏移溢出")?)
            .ok_or("拆毁字段越界")?
            .try_into()
            .unwrap(),
    ))
}
fn array(b: &[u8]) -> Result<usize, String> {
    let n = word(b, 8)? as usize;
    if wide(b, 0)? != 16
        || word(b, 12)? != 0
        || n.checked_mul(16)
            .and_then(|v| v.checked_add(16))
            .is_none_or(|end| end > b.len())
    {
        return Err("拆毁数组布局无效".into());
    }
    Ok(n)
}
impl Index {
    pub fn parse(bytes: &[u8], blocks: &[dlbin::Block]) -> Result<Option<Self>, String> {
        let settings = blocks
            .iter()
            .filter(|b| b.type_id == SETTINGS)
            .cloned()
            .collect::<Vec<_>>();
        if settings.is_empty() {
            return Ok(None);
        }
        if settings.iter().any(|b| b.payload.len() < 144) {
            return Err("拆毁等级数据不足".into());
        }
        let mut entities = BTreeMap::new();
        let mut found_map = false;
        let mut tiers = None;
        for block in blocks {
            let b = &bytes[block.payload.clone()];
            if block.type_id == MAP {
                if found_map {
                    return Err("拆毁实体映射表重复".into());
                }
                found_map = true;
                for i in 0..array(b)? {
                    let at = 16 + i * 16;
                    let entity = wide(b, at)?;
                    if entity != 0 {
                        let slot =
                            usize::try_from(wide(b, at + 8)?).map_err(|_| "拆毁条目序号越界")?;
                        if slot >= settings.len() || entities.insert(entity, slot).is_some() {
                            return Err("拆毁实体身份重复或序号越界".into());
                        }
                    }
                }
            } else if block.type_id == TIERS {
                let n = match array(b) {
                    Ok(n) if (10..=64).contains(&n) => n,
                    _ => continue,
                };
                if !(0..n).all(|i| word(b, 16 + i * 16).ok() == Some(i as u32)) {
                    continue;
                }
                let mut values = BTreeMap::new();
                for i in 0..n {
                    values.insert(i as u32, word(b, 20 + i * 16)?);
                }
                if tiers.replace(values).is_some() {
                    return Err("拆毁模板身份不唯一".into());
                }
            }
        }
        if entities.len() != settings.len()
            || entities.values().copied().collect::<BTreeSet<_>>().len() != settings.len()
        {
            return Err("拆毁条目数量与实体映射不一致".into());
        }
        Ok(Some(Self {
            settings,
            entities,
            tiers: tiers.ok_or("没有识别到拆毁模板表")?,
        }))
    }
    pub fn offset(&self, entity: u64, level: u8, direct: bool) -> Result<Option<usize>, String> {
        if level > 2 {
            return Err("拆毁等级越界".into());
        }
        Ok(self.entities.get(&entity).map(|slot| {
            self.settings[*slot].payload.start + level as usize * 48 + if direct { 32 } else { 16 }
        }))
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_missing_entity_map_instead_of_using_physical_order() {
        let mut bytes = b"LDLD\x01\0\0\0".to_vec();
        bytes.extend(SETTINGS.to_le_bytes());
        bytes.extend(144u32.to_le_bytes());
        bytes.extend([0; 8]);
        bytes.extend([0; 144]);
        let blocks = dlbin::index(&bytes).unwrap();
        assert!(Index::parse(&bytes, &blocks).is_err());
    }
}
