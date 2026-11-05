//! Storage codecs and masked byte edits. No runtime pointers or UI range caps.
use std::collections::BTreeMap;

#[derive(Clone, Debug)]
pub enum Encoding {
    Bool,
    U8,
    U16,
    U32,
    I32,
    F32,
    /// A boolean stored in selected bits of an 8/16/32-bit little-endian word.
    Flag {
        width: usize,
        mask: u32,
    },
    /// One UI switch corresponds to two actual integer tokens (bolt cycle etc.).
    Switch {
        on: u32,
        off: u32,
    },
    /// Picker IDs map to complete 64-bit identities; never pass them through f64.
    Reference(BTreeMap<u64, u64>),
    /// Resolved from the current/original destruction template table by Workspace.
    Demolition,
    #[doc(hidden)]
    Tier(BTreeMap<u32, u32>),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Patch {
    pub at: usize,
    pub bytes: Vec<u8>,
    pub mask: Vec<u8>,
}
fn integer(value: f64, low: f64, high: f64) -> Result<(), String> {
    if !value.is_finite() || value.fract() != 0.0 || value < low || value > high {
        Err("数值超出字段整数存储范围".into())
    } else {
        Ok(())
    }
}
impl Encoding {
    pub fn width(&self) -> Result<usize, String> {
        Ok(match self {
            Self::Bool | Self::U8 => 1,
            Self::U16 => 2,
            Self::Reference(entries) => {
                if entries.keys().any(|id| *id > 9_007_199_254_740_991) {
                    return Err("资源选择 ID 超出 JSON 精确整数范围".into());
                }
                8
            }
            Self::Demolition | Self::Tier(_) => 12,
            Self::Flag { width, mask } => {
                if ![1, 2, 4].contains(width)
                    || *mask == 0
                    || (*width < 4 && (*mask as u64) >= 1u64 << (width * 8))
                    || !mask.is_power_of_two()
                {
                    return Err("开关字段的位掩码无效".into());
                }
                *width
            }
            Self::Switch { on, off } if on == off => return Err("开关的两个原始值相同".into()),
            _ => 4,
        })
    }
    pub fn read(&self, bytes: &[u8]) -> Result<f64, String> {
        if bytes.len() != self.width()? {
            return Err("字段长度不匹配".into());
        }
        let word = || u32::from_le_bytes(bytes[..4].try_into().unwrap());
        let value = match self {
            Self::Bool => {
                if bytes[0] > 1 {
                    return Err("当前值不是布尔开关".into());
                }
                bytes[0] as f64
            }
            Self::U8 => bytes[0] as f64,
            Self::U16 => u16::from_le_bytes(bytes.try_into().unwrap()) as f64,
            Self::U32 => word() as f64,
            Self::I32 => i32::from_le_bytes(bytes.try_into().unwrap()) as f64,
            Self::F32 => f32::from_le_bytes(bytes.try_into().unwrap()) as f64,
            Self::Flag { mask, .. } => {
                let mut raw = [0; 4];
                raw[..bytes.len()].copy_from_slice(bytes);
                f64::from((u32::from_le_bytes(raw) & mask) != 0)
            }
            Self::Switch { on, off } => {
                let v = word();
                if v == *on {
                    1.0
                } else if v == *off {
                    0.0
                } else {
                    return Err("当前值不是已识别的开关状态".into());
                }
            }
            Self::Reference(entries) => {
                let raw = u64::from_le_bytes(bytes.try_into().unwrap());
                let mut matches = entries.iter().filter(|(_, v)| **v == raw);
                let id = matches.next().ok_or("当前资源身份尚未登记")?.0;
                if matches.next().is_some() {
                    return Err("同一资源身份对应多个选择 ID".into());
                }
                *id as f64
            }
            Self::Demolition => return Err("拆毁等级需要当前文件的模板索引".into()),
            Self::Tier(tiers) => {
                let pointer = u64::from_le_bytes(bytes[..8].try_into().unwrap());
                if pointer != u64::MAX && pointer != 0 {
                    return Err("拆毁等级包含非存储态指针".into());
                }
                let id = u32::from_le_bytes(bytes[8..12].try_into().unwrap());
                *tiers.get(&id).ok_or("拆毁等级的模板编号不存在")? as f64
            }
        };
        if !value.is_finite() {
            return Err("字段包含非有限数值".into());
        }
        Ok(value)
    }
    pub fn encode(&self, at: usize, value: f64) -> Result<Patch, String> {
        let width = self.width()?;
        let mut mask = vec![255; width];
        let bytes = match self {
            Self::Bool => {
                integer(value, 0.0, 1.0)?;
                vec![value as u8]
            }
            Self::U8 => {
                integer(value, 0.0, u8::MAX as f64)?;
                vec![value as u8]
            }
            Self::U16 => {
                integer(value, 0.0, u16::MAX as f64)?;
                (value as u16).to_le_bytes().to_vec()
            }
            Self::U32 => {
                integer(value, 0.0, u32::MAX as f64)?;
                (value as u32).to_le_bytes().to_vec()
            }
            Self::I32 => {
                integer(value, i32::MIN as f64, i32::MAX as f64)?;
                (value as i32).to_le_bytes().to_vec()
            }
            Self::F32 => {
                let float = value as f32;
                if !value.is_finite() || !float.is_finite() {
                    return Err("数值超出 32 位浮点存储范围".into());
                }
                float.to_le_bytes().to_vec()
            }
            Self::Flag { mask: bits, .. } => {
                integer(value, 0.0, 1.0)?;
                mask = bits.to_le_bytes()[..width].to_vec();
                if value == 1.0 {
                    mask.clone()
                } else {
                    vec![0; width]
                }
            }
            Self::Switch { on, off } => {
                integer(value, 0.0, 1.0)?;
                (if value == 1.0 { *on } else { *off })
                    .to_le_bytes()
                    .to_vec()
            }
            Self::Reference(entries) => {
                integer(value, 0.0, 9_007_199_254_740_991.0)?;
                entries
                    .get(&(value as u64))
                    .ok_or("资源选择 ID 不存在")?
                    .to_le_bytes()
                    .to_vec()
            }
            Self::Demolition => return Err("拆毁等级需要当前文件的模板索引".into()),
            Self::Tier(tiers) => {
                let mut choices = tiers.iter().filter(|(_, v)| **v as f64 == value);
                let (id, _) = choices.next().ok_or("没有该拆毁阈值对应的模板")?;
                if choices.next().is_some() {
                    return Err("拆毁阈值对应多个模板".into());
                }
                [u64::MAX.to_le_bytes().as_slice(), &id.to_le_bytes()].concat()
            }
        };
        Ok(Patch { at, bytes, mask })
    }
}

/// Immutable source plus a byte overlay: adjacent bools and half-word flags do
/// not overwrite each other. A whole batch is planned before mutating state.
pub struct Document {
    snapshot: Vec<u8>,
    blocks: Vec<crate::dlbin::Block>,
    resource: bool,
    pending: BTreeMap<usize, u8>,
}
impl Document {
    pub fn new(snapshot: Vec<u8>) -> Result<Self, String> {
        let blocks = crate::dlbin::index(&snapshot).map_err(|e| e.to_string())?;
        Ok(Self {
            snapshot,
            blocks,
            resource: false,
            pending: BTreeMap::new(),
        })
    }
    /// An archive resource has its own separately checked directory entry. It
    /// is not an LDLD file and must never be given a fabricated block header.
    pub(crate) fn resource(snapshot: Vec<u8>) -> Result<Self, String> {
        if snapshot.is_empty() || snapshot.len() > 64 * 1024 * 1024 {
            return Err("独立资源大小无效".into());
        }
        Ok(Self {
            snapshot,
            blocks: Vec::new(),
            resource: true,
            pending: BTreeMap::new(),
        })
    }
    pub fn snapshot(&self) -> &[u8] {
        &self.snapshot
    }
    pub fn blocks(&self) -> &[crate::dlbin::Block] {
        &self.blocks
    }
    pub fn checkpoint(&self) -> BTreeMap<usize, u8> {
        self.pending.clone()
    }
    pub(crate) fn resume(&mut self, pending: BTreeMap<usize, u8>) {
        self.pending = pending;
    }
    pub fn pending_count(&self) -> usize {
        self.pending.len()
    }
    pub fn slice(&self, at: usize, width: usize) -> Result<Vec<u8>, String> {
        let inside_resource = self.resource
            && at
                .checked_add(width)
                .is_some_and(|end| end <= self.snapshot.len());
        if !inside_resource && !self.blocks.iter().any(|b| b.contains(at, width)) {
            return Err("字段越过数据块边界".into());
        }
        Ok((at..at + width)
            .map(|i| self.pending.get(&i).copied().unwrap_or(self.snapshot[i]))
            .collect())
    }
    pub fn value(&self, at: usize, encoding: &Encoding) -> Result<f64, String> {
        encoding.read(&self.slice(at, encoding.width()?)?)
    }
    pub fn apply(&mut self, patches: &[Patch]) -> Result<(), String> {
        let mut merged: BTreeMap<usize, (u8, u8)> = BTreeMap::new();
        for patch in patches {
            if patch.bytes.is_empty() || patch.bytes.len() != patch.mask.len() {
                return Err("待写入字段长度无效".into());
            }
            self.slice(patch.at, patch.bytes.len())?;
            for (i, (value, mask)) in patch.bytes.iter().zip(&patch.mask).enumerate() {
                let (bits, wanted) = merged.entry(patch.at + i).or_default();
                let overlap = *bits & *mask;
                if (*wanted ^ value) & overlap != 0 {
                    return Err("同一字段被指定互相冲突的数值".into());
                }
                *wanted = (*wanted & !*mask) | (*value & *mask);
                *bits |= *mask;
            }
        }
        for (at, (mask, value)) in merged {
            let old = self.pending.get(&at).copied().unwrap_or(self.snapshot[at]);
            let byte = (old & !mask) | (value & mask);
            if byte == self.snapshot[at] {
                self.pending.remove(&at);
            } else {
                self.pending.insert(at, byte);
            }
        }
        Ok(())
    }
    pub fn render(&self, current: &[u8]) -> Result<Vec<u8>, String> {
        if current != self.snapshot {
            return Err("打开后的磁盘数据已被修改，未导出".into());
        }
        let mut out = self.snapshot.clone();
        for (at, byte) in &self.pending {
            out[*at] = *byte;
        }
        Ok(out)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn data() -> Vec<u8> {
        [
            b"LDLD\x01\0\0\0".as_slice(),
            &1u32.to_le_bytes(),
            &32u32.to_le_bytes(),
            &[0; 8],
            &[0xa5; 32],
        ]
        .concat()
    }
    #[test]
    fn flags_merge_without_clobbering_neighbors_and_conflicts_are_atomic() {
        let input = data();
        let mut doc = Document::new(input.clone()).unwrap();
        let a = Encoding::Flag { width: 1, mask: 2 };
        let b = Encoding::Flag {
            width: 2,
            mask: 256,
        };
        doc.apply(&[a.encode(24, 1.0).unwrap(), b.encode(24, 0.0).unwrap()])
            .unwrap();
        let mut wanted = input.clone();
        wanted[24] = 0xa7;
        wanted[25] = 0xa4;
        assert_eq!(doc.render(&input).unwrap(), wanted);
        let before = doc.checkpoint();
        assert!(doc
            .apply(&[a.encode(24, 0.0).unwrap(), a.encode(24, 1.0).unwrap()])
            .is_err());
        assert_eq!(before, doc.checkpoint());
        assert!(doc
            .apply(&[
                a.encode(24, 0.0).unwrap(),
                Encoding::U32.encode(54, 1.0).unwrap()
            ])
            .is_err());
        assert_eq!(before, doc.checkpoint());
        assert!(doc.render(&wanted).is_err());
    }
    #[test]
    fn ranges_and_full_width_resource_id_are_preserved() {
        let cases = [
            (Encoding::U8, 255.0),
            (Encoding::U16, 65535.0),
            (Encoding::U32, 4294967295.0),
            (Encoding::I32, -2147483648.0),
            (Encoding::F32, -2.5),
            (
                Encoding::Switch {
                    on: 2719,
                    off: 2677,
                },
                1.0,
            ),
        ];
        for (encoding, value) in cases {
            let p = encoding.encode(0, value).unwrap();
            assert_eq!(encoding.read(&p.bytes).unwrap(), value);
        }
        assert!(Encoding::U8.encode(0, 256.0).is_err());
        assert!(Encoding::U32.encode(0, 1.1).is_err());
        assert!(Encoding::F32.encode(0, f64::INFINITY).is_err());
        assert!(Encoding::F32.encode(0, 1e100).is_err());
        assert!(Encoding::Flag {
            width: 2,
            mask: 65536
        }
        .width()
        .is_err());
        let encoding = Encoding::Reference(BTreeMap::from([(3, u64::MAX - 1)]));
        let patch = encoding.encode(24, 3.0).unwrap();
        assert_eq!(patch.bytes, (u64::MAX - 1).to_le_bytes());
        assert_eq!(encoding.read(&patch.bytes).unwrap(), 3.0);
    }
}
