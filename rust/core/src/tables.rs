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

pub fn parse(file: &[u8], block: &Block, layout: Layout) -> Result<Table, String> {
    let data = file.get(block.payload.clone()).ok_or("表载荷越界")?;
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
        _ => None,
    };
    if let Some(stride) = rows {
        return vec![Layout::Rows {
            stride,
            id_offset: 0,
        }];
    }
    let strides: &[usize] = match type_id {
        0x88E4DBB1 => &[1232, 1240],
        0xFB8D88A3 => &[160],
        0x66081072 => &[136],
        0x45171B68 => &[616],
        0xF0721C2C => &[120],
        0x936A9C08 => &[552, 568],
        0x4C981CD9 => &[592],
        0x8E551126 => &[224],
        0xBBA9003F => &[192],
        0xB87BA9ED => &[80],
        _ => &[],
    };
    strides
        .iter()
        .map(|&stride| Layout::Keyed { stride, slack: 0 })
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
