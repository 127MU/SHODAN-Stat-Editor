//! Stored row/hash tables. Offsets are file-relative integers, never live pointers.
use crate::dlbin::Block;
use std::{collections::BTreeMap, ops::Range};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Key {
    Id(u32),
    Hash(u64),
}
#[derive(Clone, Copy, Debug)]
pub enum Layout {
    Rows { stride: usize, id_offset: usize },
    Keyed { stride: usize, slack: usize },
}
pub struct Table {
    pub type_id: u32,
    pub rows: BTreeMap<Key, Range<usize>>,
    pub duplicate_keys: usize,
    pub tail: Range<usize>,
}
impl Table {
    pub fn field_offset(&self, key: Key, relative: usize, width: usize) -> Result<usize, String> {
        let row = self.rows.get(&key).ok_or("记录 ID 不存在")?;
        if relative.checked_add(width).is_none_or(|n| n > row.len()) {
            return Err("字段越过当前记录边界".into());
        }
        row.start
            .checked_add(relative)
            .ok_or_else(|| "字段偏移溢出".into())
    }
    pub fn read_number(
        &self,
        file: &[u8],
        key: Key,
        relative: usize,
        kind: crate::Kind,
    ) -> Result<f64, String> {
        let offset = self.field_offset(key, relative, 4)?;
        crate::read(file, offset, kind).map_err(str::to_string)
    }
}
fn u32_at(data: &[u8], at: usize) -> Result<u32, String> {
    let end = at.checked_add(4).ok_or("表偏移溢出")?;
    Ok(u32::from_le_bytes(
        data.get(at..end).ok_or("表字段越界")?.try_into().unwrap(),
    ))
}
fn u64_at(data: &[u8], at: usize) -> Result<u64, String> {
    let end = at.checked_add(8).ok_or("表偏移溢出")?;
    Ok(u64::from_le_bytes(
        data.get(at..end).ok_or("表字段越界")?.try_into().unwrap(),
    ))
}
fn rows(
    data: &[u8],
    base: usize,
    type_id: u32,
    stride: usize,
    id_offset: usize,
) -> Result<Table, String> {
    if stride < 4 || id_offset.checked_add(4).is_none_or(|n| n > stride) {
        return Err("行宽或 ID 偏移无效".into());
    }
    let count = u32_at(data, 8)? as usize;
    if u32_at(data, 12)? != 0 {
        return Err("行表保留字段非零".into());
    }
    let end = count
        .checked_mul(stride)
        .and_then(|n| n.checked_add(16))
        .ok_or("行数溢出")?;
    if end > data.len() {
        return Err("行表载荷不足".into());
    }
    let mut result = Table {
        type_id,
        rows: BTreeMap::new(),
        duplicate_keys: 0,
        tail: base + end..base + data.len(),
    };
    for index in 0..count {
        let offset = 16 + index * stride;
        let key = Key::Id(u32_at(data, offset + id_offset)?);
        if let std::collections::btree_map::Entry::Vacant(entry) = result.rows.entry(key) {
            entry.insert(base + offset..base + offset + stride);
        } else {
            result.duplicate_keys += 1;
        }
    }
    Ok(result)
}
fn keyed(
    data: &[u8],
    base: usize,
    type_id: u32,
    stride: usize,
    slack: usize,
) -> Result<Table, String> {
    if stride == 0 || slack > data.len() {
        return Err("哈希表行宽或填充无效".into());
    }
    let mut candidates = Vec::new();
    let mut twice = Vec::new();
    let mut live = 0;
    let mut top = 0;
    for offset in (0..data.len().saturating_sub(15)).step_by(16) {
        let slot = u32_at(data, offset + 8)? as usize;
        if u32_at(data, offset + 12)? != 0 {
            break;
        }
        let count = offset / 16 + 1;
        if u64_at(data, offset)? != 0 {
            live += 1;
            top = top.max(slot);
        }
        let Some(array) = data.len().checked_sub(count * 16 + slack) else {
            break;
        };
        if count <= 2 * live && array > 0 && array % stride == 0 {
            let records = array / stride;
            if records > top && records <= live + 2 {
                candidates.push(count);
                if count == 2 * live {
                    twice.push(count);
                }
            }
        }
    }
    let placed = |buckets: usize| -> Result<bool, String> {
        for k in 0..buckets {
            let key = u64_at(data, k * 16)?;
            if key == 0 {
                continue;
            }
            let mut at = (key % buckets as u64) as usize;
            while at != k {
                if u64_at(data, at * 16)? == 0 {
                    return Ok(false);
                }
                at = (at + 1) % buckets;
            }
        }
        Ok(true)
    };
    let mut fits = Vec::new();
    for n in candidates {
        if placed(n)? {
            fits.push(n);
        }
    }
    if fits.len() != 1 {
        fits = twice;
    }
    if fits.len() != 1 {
        return Err(format!(
            "哈希表存在 {} 个候选布局，无法唯一识别",
            fits.len()
        ));
    }
    let buckets = fits[0];
    let row_start = buckets * 16;
    let records = (data.len() - row_start - slack) / stride;
    let mut result = Table {
        type_id,
        rows: BTreeMap::new(),
        duplicate_keys: 0,
        tail: base + data.len() - slack..base + data.len(),
    };
    for k in 0..buckets {
        let key = u64_at(data, k * 16)?;
        if key == 0 {
            continue;
        }
        let slot = u32_at(data, k * 16 + 8)? as usize;
        if slot >= records {
            return Err("哈希表槽位超过记录数量".into());
        }
        let start = base + row_start + slot * stride;
        if let std::collections::btree_map::Entry::Vacant(entry) = result.rows.entry(Key::Hash(key))
        {
            entry.insert(start..start + stride);
        } else {
            result.duplicate_keys += 1;
        }
    }
    Ok(result)
}

/// Loadout's bounded-probe map does not use the general component-table
/// placement rule. Its keys may sit past empty buckets, within 16 slots of home.
fn loadout(data: &[u8], base: usize, type_id: u32) -> Result<Table, String> {
    let mut keys = Vec::new();
    let mut candidates = Vec::new();
    for at in (0..data.len().saturating_sub(15)).step_by(16) {
        let slot = u32_at(data, at + 8)? as usize;
        if u32_at(data, at + 12)? != 0 || slot > 100000 {
            break;
        }
        let hash = u64_at(data, at)?;
        if hash != 0 {
            keys.push((at / 16, hash, slot));
        }
        let buckets = at / 16 + 1;
        let records = (data.len() - buckets * 16) / 32;
        if buckets >= 64
            && buckets == 2 * keys.len()
            && records > 0
            && keys.iter().all(|(bucket, hash, slot)| {
                (*bucket + buckets - (*hash % buckets as u64) as usize) % buckets < 16
                    && *slot < records
            })
        {
            candidates.push(buckets);
        }
    }
    if candidates.len() != 1 {
        return Err("配装条目哈希表布局不唯一".into());
    }
    let buckets = candidates[0];
    let start = buckets * 16;
    let records = (data.len() - start) / 32;
    let mut result = Table {
        type_id,
        rows: BTreeMap::new(),
        duplicate_keys: 0,
        tail: base + start + records * 32..base + data.len(),
    };
    for at in (0..start).step_by(16) {
        let key = u64_at(data, at)?;
        if key == 0 {
            continue;
        }
        let slot = u32_at(data, at + 8)? as usize;
        let row = base + start + slot * 32;
        if result.rows.insert(Key::Hash(key), row..row + 32).is_some() {
            result.duplicate_keys += 1;
        }
    }
    Ok(result)
}
pub fn parse(file: &[u8], block: &Block, layout: Layout) -> Result<Table, String> {
    let data = file.get(block.payload.clone()).ok_or("表载荷越界")?;
    if block.type_id == 0x4F2CF417 {
        if !matches!(
            layout,
            Layout::Keyed {
                stride: 32,
                slack: 0
            }
        ) {
            return Err("配装条目布局不匹配".into());
        }
        return loadout(data, block.payload.start, block.type_id);
    }
    match layout {
        Layout::Rows { stride, id_offset } => {
            rows(data, block.payload.start, block.type_id, stride, id_offset)
        }
        Layout::Keyed { stride, slack } => {
            keyed(data, block.payload.start, block.type_id, stride, slack)
        }
    }
}

/// Layouts already supported by the 4.6.0 compatibility core. Additional layouts
/// are selected explicitly rather than guessed from a parameter's numeric value.
pub fn layouts(type_id: u32) -> Vec<Layout> {
    let rows = match type_id {
        0xAFDF0267 => Some(104),
        0xBD4042C2 => Some(272),
        0xE0A72CF0 => Some(76),
        0x2AEA2592 => Some(152),
        0xC5085606 => Some(112),
        0x30EB6399 => Some(400),
        0xC63E0B22 => Some(160),
        0x1E604234 => Some(88),
        _ => None,
    };
    if let Some(stride) = rows {
        return vec![Layout::Rows {
            stride,
            id_offset: match type_id {
                0x30EB6399 => 4,
                0x1E604234 => 8,
                _ => 0,
            },
        }];
    }
    let strides: &[usize] = match type_id {
        0x88E4DBB1 => &[1232, 1240],
        0x4F2CF417 => &[32], // loadout entity hash map
        0xFB8D88A3 => &[160],
        0x66081072 => &[136],
        0x45171B68 => &[616],
        0xF0721C2C => &[120],
        0x936A9C08 => &[552, 568],
        0x4C981CD9 => &[592],
        0x8E551126 => &[224],
        0xBBA9003F => &[192],
        0xB87BA9ED => &[80],
        0xB3915DE3 => &[22096],            // health
        0x14729B6A => &[44],               // sensor
        0xFF67A367 => &[24],               // detector
        0xDDB5C03F => &[12],               // hellpod payload
        0xEBA8F3D0 => &[4872],             // default customization
        0xAF16BCB5 | 0xF5CF9B8C => &[360], // throwable / explosive
        0xEAEB2B0D => &[3704],             // vehicle
        0x3845B1E0 => &[120],              // mounts
        0x5653EA91 => &[152],              // faction
        0xBA9B803D => &[12],               // behavior
        0x4AEAFC86 => &[424],              // seat collection
        0x5154DB66 => &[344],              // shield
        0xA98BB156 => &[568],              // hellpod rack
        0xEAC335A1 => &[216],              // charge
        0x54270608 => &[280],              // jump pack
        0x1F42878E => &[4],                // recharge
        0xA7813546 => &[632],              // warp pack
        0xC435BA85 => &[152],              // charges
        0x7A858691 => &[32],               // loadout package
        0x991D454E => &[80],               // reload
        0x84CE7EEE => &[36],               // windup
        0xA29A84D8 => &[752],              // mine thrower
        0x74FEF89A => &[44],               // minefield
        0x0697FED6 => &[32],               // mine spawner
        0xCDBC43D8 => &[192],              // bombardment
        0x556FF68B => &[152, 336],         // eagle layouts (field mapping is separate)
        0xBF3A6789 => &[272],              // seeking missile
        0x84957034 => &[124],              // guidance
        0x32528174 => &[64],               // designator
        0x40EF204C => &[852],              // avatar
        0x726A4F6B => &[64],               // drownable
        0x7EF5CC55 => &[104],              // hellpod
        0x5FEF63C4 => &[80],               // AI character
        0x5357A825 => &[232],              // equipment
        0xD0207221 => &[1084],             // hive mind
        0x8ADAB43B => &[144],              // inventory
        0xFCCA29DB => &[1104],             // pickup
        0x6062C233 => &[46600],            // status effects taken
        0x498CE7C7 => &[48],               // transport
        0xC677F538 => &[12],               // danger sensor
        0x595A2910 => &[28],               // scrambler
        0x333C9A62 => &[752],              // flight path
        0xD57D0101 => &[4836],             // hit reaction
        0xD2B93CD8 => &[168],              // squad transport
        0x2C0968D2 => &[64],               // targeting
        0xC8033E7F => &[16],               // hearing
        0x9D0EEFB5 => &[736],              // enemy AI
        0x8C5F8AB7 => &[20],               // jammer
        0x4437574D => &[136],              // unit
        0xD74E6E1A => &[96],               // spawn floor
        0x8A40FE2F => &[56],               // encyclopedia
        _ => &[],
    };
    if type_id == 0x9AF175A4 {
        return vec![Layout::Keyed {
            stride: 76,
            slack: 4,
        }];
    }
    if type_id == 0x1EBA7593 {
        return vec![
            Layout::Keyed {
                stride: 76,
                slack: 0,
            },
            Layout::Keyed {
                stride: 76,
                slack: 4,
            },
        ];
    }
    strides
        .iter()
        .map(|&stride| Layout::Keyed {
            stride,
            slack: if matches!(type_id, 0x8C5F8AB7 | 0xC677F538) {
                4
            } else {
                0
            },
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn row_identity_and_tail_do_not_depend_on_record_order() {
        let mut b = 16u64.to_le_bytes().to_vec();
        b.extend(2u32.to_le_bytes());
        b.extend([0; 4]);
        b.extend(9u32.to_le_bytes());
        b.extend(1f32.to_le_bytes());
        b.extend(3u32.to_le_bytes());
        b.extend(2f32.to_le_bytes());
        b.extend(b"tail");
        let t = rows(&b, 100, 7, 8, 0).unwrap();
        assert_eq!(t.rows[&Key::Id(3)], 124..132);
        assert_eq!(t.tail, 132..136);
        assert!(rows(&b[..20], 0, 7, 8, 0).is_err());
    }
    #[test]
    fn full_width_hashes_and_unindexed_record_are_preserved() {
        let mut b = Vec::new();
        let key = u64::MAX - 2;
        b.extend([0; 16]);
        b.extend(key.to_le_bytes());
        b.extend(0u32.to_le_bytes());
        b.extend([0; 4]);
        b.extend([17; 8]);
        let t = keyed(&b, 200, 7, 8, 0).unwrap();
        assert_eq!(t.rows[&Key::Hash(key)], 232..240);
    }
    #[test]
    fn rejects_ambiguous_or_malformed_inputs_without_panicking() {
        assert!(keyed(&[0; 64], 0, 7, 8, 0).is_err());
        assert!(rows(&[0; 15], 0, 7, 8, 0).is_err());
        assert!(rows(&[0; 16], 0, 7, 1, usize::MAX).is_err());
    }
    #[test]
    fn originals_follow_stable_ids_after_record_reordering() {
        let mut original = 16u64.to_le_bytes().to_vec();
        original.extend(2u32.to_le_bytes());
        original.extend([0; 4]);
        original.extend(9u32.to_le_bytes());
        original.extend(1f32.to_le_bytes());
        original.extend(3u32.to_le_bytes());
        original.extend(2f32.to_le_bytes());
        let mut changed = original[..16].to_vec();
        changed.extend(&original[24..32]);
        changed.extend(&original[16..24]);
        changed[20..24].copy_from_slice(&99f32.to_le_bytes());
        let a = rows(&original, 0, 7, 8, 0).unwrap();
        let b = rows(&changed, 0, 7, 8, 0).unwrap();
        assert_eq!(
            b.read_number(&changed, Key::Id(3), 4, crate::Kind::F32)
                .unwrap(),
            99.0
        );
        assert_eq!(
            a.read_number(&original, Key::Id(3), 4, crate::Kind::F32)
                .unwrap(),
            2.0
        );
        assert!(a.field_offset(Key::Id(3), 6, 4).is_err());
        assert!(a.field_offset(Key::Id(3), usize::MAX, 4).is_err());
    }
}
