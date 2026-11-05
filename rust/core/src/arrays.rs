//! Checked payload-relative arrays used by attachment deltas and armor kits.
//! Stored pointers are offsets, never process addresses. Identities are retained
//! so an edit can be rebound after another editor reorders the arrays.
use std::{collections::BTreeMap, ops::Range};

pub const DELTAS: u32 = 0x683E604F;
pub const ARMOR_KIT: u32 = 0xD9A55AA0;

fn word(data: &[u8], at: usize) -> Result<u32, String> {
    Ok(u32::from_le_bytes(
        data.get(at..at.checked_add(4).ok_or("数组偏移溢出")?)
            .ok_or("数组字段越界")?
            .try_into()
            .unwrap(),
    ))
}
fn wide(data: &[u8], at: usize) -> Result<u64, String> {
    Ok(u64::from_le_bytes(
        data.get(at..at.checked_add(8).ok_or("数组偏移溢出")?)
            .ok_or("数组字段越界")?
            .try_into()
            .unwrap(),
    ))
}
fn area(
    data: &[u8],
    at: usize,
    count: usize,
    stride: usize,
    minimum: usize,
) -> Result<Range<usize>, String> {
    let end = count
        .checked_mul(stride)
        .and_then(|size| at.checked_add(size))
        .ok_or("数组大小溢出")?;
    if at < minimum || end > data.len() {
        return Err("数组载荷越界".into());
    }
    Ok(at..end)
}
fn array(
    data: &[u8],
    header: usize,
    stride: usize,
    minimum: usize,
) -> Result<Range<usize>, String> {
    if word(data, header + 12)? != 0 {
        return Err("数组保留字段非零".into());
    }
    let count = word(data, header + 8)? as usize;
    let at = usize::try_from(wide(data, header)?).map_err(|_| "数组偏移超过地址范围")?;
    if count == 0 && at == 0 {
        return Ok(0..0);
    }
    area(data, at, count, stride, minimum)
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct DeltaKey {
    pub resource: u64,
    pub component: u32,
    pub field: u32,
}
#[derive(Clone, Debug)]
pub struct Deltas {
    /// A field may occur repeatedly; the final delta is the one the game uses.
    pub values: BTreeMap<DeltaKey, Vec<Range<usize>>>,
    pub arrays: [Range<usize>; 5],
}
impl Deltas {
    pub fn parse(data: &[u8]) -> Result<Self, String> {
        let strides = [16, 8, 12, 12, 1];
        let mut arrays: [Range<usize>; 5] = std::array::from_fn(|_| 0..0);
        for i in 0..5 {
            arrays[i] = array(data, i * 16, strides[i], 80)?;
        }
        for a in 0..5 {
            for b in a + 1..5 {
                if !arrays[a].is_empty()
                    && !arrays[b].is_empty()
                    && arrays[a].start < arrays[b].end
                    && arrays[b].start < arrays[a].end
                {
                    return Err("增量数据数组相互重叠".into());
                }
            }
        }
        let slots = arrays[1].len() / 8;
        let components = arrays[2].len() / 12;
        let deltas = arrays[3].len() / 12;
        let mut resources = BTreeMap::new();
        for at in arrays[0].clone().step_by(16) {
            let resource = wide(data, at)?;
            if word(data, at + 12)? != 0 {
                return Err("增量索引保留字段非零".into());
            }
            if resource == 0 {
                continue;
            }
            let slot = word(data, at + 8)? as usize;
            if slot >= slots || resources.insert(resource, slot).is_some() {
                return Err("增量资源身份重复或槽位越界".into());
            }
        }
        let mut values: BTreeMap<DeltaKey, Vec<Range<usize>>> = BTreeMap::new();
        for (resource, slot) in resources {
            let at = arrays[1].start + slot * 8;
            let count = word(data, at)? as usize;
            let first = word(data, at + 4)? as usize;
            let range = first..first.checked_add(count).ok_or("增量组件数量溢出")?;
            if range.end > components {
                return Err("增量组件索引越界".into());
            }
            for index in range {
                let at = arrays[2].start + index * 12;
                let component = word(data, at)?;
                let first = word(data, at + 4)? as usize;
                let count = word(data, at + 8)? as usize;
                let range = first..first.checked_add(count).ok_or("增量字段数量溢出")?;
                if range.end > deltas {
                    return Err("增量字段索引越界".into());
                }
                for index in range {
                    let at = arrays[3].start + index * 12;
                    let field = word(data, at)?;
                    let size = word(data, at + 4)? as usize;
                    let offset = word(data, at + 8)? as usize;
                    if size == 0
                        || offset
                            .checked_add(size)
                            .is_none_or(|end| end > arrays[4].len())
                    {
                        return Err("增量数值越过数据区".into());
                    }
                    values
                        .entry(DeltaKey {
                            resource,
                            component,
                            field,
                        })
                        .or_default()
                        .push(arrays[4].start + offset..arrays[4].start + offset + size);
                }
            }
        }
        Ok(Self { values, arrays })
    }
    pub fn resolve(
        &self,
        key: &DeltaKey,
        relative: usize,
        width: usize,
    ) -> Result<Option<usize>, String> {
        let Some(values) = self.values.get(key) else {
            return Ok(None);
        };
        let value = values.last().ok_or("增量字段没有数据")?;
        if relative
            .checked_add(width)
            .is_none_or(|end| end > value.len())
        {
            return Err("参数越过增量字段边界".into());
        }
        Ok(Some(value.start + relative))
    }
}

#[derive(Clone, Debug)]
pub struct Piece {
    pub record: Range<usize>,
    pub slot: u32,
    pub subtype: u32,
    pub weight: u32,
}
#[derive(Clone, Debug)]
pub struct Kit {
    pub identity: [u32; 3],
    pub name: u32,
    pub caps: u32,
    pub description: u32,
    pub kind: u32,
    pub passive: u32,
    pub pieces: Vec<Piece>,
}
impl Kit {
    pub fn parse(data: &[u8]) -> Result<Self, String> {
        if data.len() < 64 {
            return Err("护甲配置头不完整".into());
        }
        let mut out = Self {
            identity: [word(data, 0)?, word(data, 4)?, word(data, 16)?],
            name: word(data, 16)?,
            caps: word(data, 12)?,
            description: word(data, 20)?,
            kind: word(data, 40)?,
            passive: word(data, 28)?,
            pieces: Vec::new(),
        };
        let count = word(data, 56)? as usize;
        if count > 8 {
            return Err("护甲体型数量无效".into());
        }
        if out.kind != 0 || count == 0 {
            return Ok(out);
        }
        let bodies = array(data, 48, 24, 64)?;
        for body in bodies.step_by(24) {
            if word(data, body + 16)? > 64 {
                return Err("护甲部件数量无效".into());
            }
            for at in array(data, body + 8, 112, 64)?.step_by(112) {
                let weight = word(data, at + 16)?;
                if weight > 2 {
                    return Err("护甲重量类别无效".into());
                }
                out.pieces.push(Piece {
                    record: at..at + 112,
                    slot: word(data, at + 8)?,
                    subtype: word(data, at + 12)?,
                    weight,
                });
            }
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn put(b: &mut [u8], at: usize, n: u32) {
        b[at..at + 4].copy_from_slice(&n.to_le_bytes());
    }
    #[test]
    fn delta_identity_follows_arrays_and_final_override() {
        let mut b = vec![0; 160];
        for (i, at, count) in [
            (0, 80, 1),
            (1, 96, 1),
            (2, 104, 1),
            (3, 116, 2),
            (4, 140, 20),
        ] {
            put(&mut b, i * 16, at);
            put(&mut b, i * 16 + 8, count);
        }
        b[80..88].copy_from_slice(&0xF123456789ABCDEFu64.to_le_bytes());
        put(&mut b, 96, 1);
        put(&mut b, 104, 7);
        put(&mut b, 112, 2);
        for (at, off) in [(116, 0), (128, 4)] {
            put(&mut b, at, 64);
            put(&mut b, at + 4, 4);
            put(&mut b, at + 8, off);
        }
        let key = DeltaKey {
            resource: 0xF123456789ABCDEF,
            component: 7,
            field: 64,
        };
        let d = Deltas::parse(&b).unwrap();
        assert_eq!(d.values[&key].len(), 2);
        assert_eq!(d.resolve(&key, 0, 4).unwrap(), Some(144));
        assert!(d.resolve(&key, 1, 4).is_err());
        put(&mut b, 136, u32::MAX);
        assert!(Deltas::parse(&b).is_err());
    }
    #[test]
    fn kit_rejects_invalid_nested_arrays() {
        let mut b = vec![0; 200];
        put(&mut b, 48, 64);
        put(&mut b, 56, 1);
        put(&mut b, 72, 88);
        put(&mut b, 80, 1);
        put(&mut b, 96, 2);
        let k = Kit::parse(&b).unwrap();
        assert_eq!(k.pieces[0].slot, 2);
        assert_eq!(k.pieces[0].record, 88..200);
        put(&mut b, 104, 3);
        assert!(Kit::parse(&b).is_err());
        put(&mut b, 104, 0);
        b.pop();
        assert!(Kit::parse(&b).is_err());
    }
}
