//! Immutable disk snapshot, optional trusted originals, and atomic in-memory edits.
//! Original values are never inferred from a modified file's header or current values.
use crate::{
    dlbin::{self, Block},
    Kind,
};
use std::collections::BTreeMap;

pub struct Document {
    snapshot: Vec<u8>,
    originals: Option<Vec<u8>>,
    blocks: Vec<Block>,
    pending: BTreeMap<usize, [u8; 4]>,
}

impl Document {
    /// The caller must authenticate `originals` before supplying them here.
    pub fn new(snapshot: Vec<u8>, originals: Option<Vec<u8>>) -> Result<Self, String> {
        let blocks = dlbin::index(&snapshot).map_err(|e| e.to_string())?;
        if let Some(ref baseline) = originals {
            let original_blocks = dlbin::index(baseline).map_err(|e| e.to_string())?;
            if snapshot.len() != baseline.len()
                || original_blocks.len() != blocks.len()
                || blocks.iter().zip(&original_blocks).any(|(a, b)| {
                    a.header_offset != b.header_offset
                        || a.type_id != b.type_id
                        || a.payload != b.payload
                })
            {
                return Err("原版基准与当前数据布局不一致，无法按偏移映射原值".into());
            }
        }
        Ok(Self {
            snapshot,
            originals,
            blocks,
            pending: BTreeMap::new(),
        })
    }

    pub fn blocks(&self) -> &[Block] {
        &self.blocks
    }

    pub fn snapshot(&self) -> &[u8] {
        &self.snapshot
    }

    fn check_field(&self, offset: usize) -> Result<(), &'static str> {
        if !self.blocks.iter().any(|b| b.contains(offset, 4)) {
            return Err("参数不在数据块有效载荷内");
        }
        Ok(())
    }

    pub fn value(&self, offset: usize, kind: Kind) -> Result<f64, &'static str> {
        self.check_field(offset)?;
        match self.pending.get(&offset) {
            Some(bytes) => crate::read(bytes, 0, kind),
            None => crate::read(&self.snapshot, offset, kind),
        }
    }

    pub fn original(&self, offset: usize, kind: Kind) -> Result<Option<f64>, &'static str> {
        self.check_field(offset)?;
        self.originals
            .as_ref()
            .map(|bytes| crate::read(bytes, offset, kind))
            .transpose()
    }

    pub fn set(&mut self, offset: usize, kind: Kind, value: f64) -> Result<(), &'static str> {
        self.check_field(offset)?;
        let encoded = crate::plan(&self.snapshot, offset, kind, value)?;
        if self
            .pending
            .keys()
            .any(|&at| at != offset && at < offset + 4 && offset < at + 4)
        {
            return Err("参数写入范围重叠");
        }
        if self.snapshot[offset..offset + 4] == encoded.value {
            self.pending.remove(&offset);
        } else {
            self.pending.insert(offset, encoded.value);
        }
        Ok(())
    }

    pub fn restore(&mut self, offset: usize) -> Result<(), &'static str> {
        self.check_field(offset)?;
        let bytes = self.originals.as_ref().ok_or("没有可信原值，无法恢复")?;
        let value: [u8; 4] = bytes[offset..offset + 4].try_into().unwrap();
        if self
            .pending
            .keys()
            .any(|&at| at != offset && at < offset + 4 && offset < at + 4)
        {
            return Err("参数写入范围重叠");
        }
        if self.snapshot[offset..offset + 4] == value {
            self.pending.remove(&offset);
        } else {
            self.pending.insert(offset, value);
        }
        Ok(())
    }

    /// Stage a whole batch or retain the exact previous pending state.
    pub fn set_batch(&mut self, fields: &[(usize, Kind, f64)]) -> Result<(), &'static str> {
        let previous = self.pending.clone();
        let mut seen = Vec::new();
        for &(offset, kind, value) in fields {
            if seen
                .iter()
                .any(|&at| at < offset.saturating_add(4) && offset < at + 4)
            {
                self.pending = previous;
                return Err("批量修改包含重复或重叠字段");
            }
            if let Err(error) = self.set(offset, kind, value) {
                self.pending = previous;
                return Err(error);
            }
            seen.push(offset);
        }
        Ok(())
    }

    pub fn pending_count(&self) -> usize {
        self.pending.len()
    }

    /// Produces bytes only. Encryption, backups, and installation are separate stages.
    pub fn render(&self, current_disk: &[u8]) -> Result<Vec<u8>, &'static str> {
        if current_disk != self.snapshot {
            return Err("文件已被其他程序修改，请重新读取");
        }
        let edits: Vec<_> = self
            .pending
            .iter()
            .map(|(&offset, &value)| crate::Edit {
                offset,
                original: self.snapshot[offset..offset + 4].try_into().unwrap(),
                value,
            })
            .collect();
        crate::apply(&self.snapshot, &edits)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture(value: f32) -> Vec<u8> {
        let mut b = b"LDLD\x01\0\0\0".to_vec();
        b.extend(1u32.to_le_bytes());
        b.extend(8u32.to_le_bytes());
        b.extend([1, 0, 0, 0, 0, 0, 0, 0]);
        b.extend(value.to_le_bytes());
        b.extend([0; 4]);
        b
    }
    #[test]
    fn modified_snapshot_is_never_used_as_default() {
        let disk = fixture(99.0);
        let original = fixture(1.3);
        let mut d = Document::new(disk.clone(), Some(original.clone())).unwrap();
        assert_eq!(d.value(24, Kind::F32).unwrap(), 99.0);
        assert_eq!(d.original(24, Kind::F32).unwrap(), Some(1.3f32 as f64));
        d.restore(24).unwrap();
        assert_eq!(d.render(&disk).unwrap(), original);
        assert_eq!(disk, fixture(99.0));
    }
    #[test]
    fn unknown_original_cannot_restore_and_stale_disk_cannot_commit() {
        let disk = fixture(5.0);
        let mut d = Document::new(disk.clone(), None).unwrap();
        assert_eq!(d.original(24, Kind::F32).unwrap(), None);
        assert!(d.restore(24).is_err());
        d.set(24, Kind::F32, -2.5).unwrap();
        assert!(d.render(&fixture(6.0)).is_err());
        assert_eq!(
            crate::read(&d.render(&disk).unwrap(), 24, Kind::F32).unwrap(),
            -2.5
        );
    }
    #[test]
    fn validates_payload_overlap_and_original_layout() {
        let disk = fixture(1.0);
        let mut d = Document::new(disk.clone(), None).unwrap();
        assert!(d.set(12, Kind::U32, 1.0).is_err());
        d.set(24, Kind::U32, 1.0).unwrap();
        assert!(d.set(25, Kind::U32, 2.0).is_err());
        assert_eq!(d.pending_count(), 1);
        let mut wrong = disk.clone();
        wrong[8] = 2;
        assert!(Document::new(disk, Some(wrong)).is_err());
    }
    #[test]
    fn revert_to_disk_removes_pending_edit() {
        let disk = fixture(1.0);
        let mut d = Document::new(disk, None).unwrap();
        d.set(24, Kind::F32, 1000000.0).unwrap();
        assert_eq!(d.pending_count(), 1);
        d.set(24, Kind::F32, 1.0).unwrap();
        assert_eq!(d.pending_count(), 0);
    }
    #[test]
    fn failed_batch_preserves_preexisting_edits_exactly() {
        let disk = fixture(1.0);
        let mut d = Document::new(disk.clone(), None).unwrap();
        d.set(24, Kind::F32, 12.0).unwrap();
        let before = d.render(&disk).unwrap();
        for batch in [
            vec![(24, Kind::F32, 99.0), (28, Kind::F32, f64::NAN)],
            vec![(24, Kind::F32, 99.0), (24, Kind::F32, 100.0)],
            vec![(24, Kind::F32, 99.0), (25, Kind::F32, 100.0)],
        ] {
            assert!(d.set_batch(&batch).is_err());
            assert_eq!(d.render(&disk).unwrap(), before);
            assert_eq!(d.pending_count(), 1);
        }
        d.set_batch(&[(24, Kind::F32, 2.0), (28, Kind::U32, 3.0)])
            .unwrap();
        assert_eq!(d.pending_count(), 2);
    }
}
