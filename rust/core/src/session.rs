//! Native editing session shared by future UI adapters; no compatibility calls.
use crate::{
    baseline::Baseline,
    document::Document,
    tables::{self, Key, Layout, Table},
    Kind,
};
use std::collections::BTreeMap;

#[derive(Clone, Copy)]
pub struct Field {
    pub block: usize,
    pub record: Key,
    pub relative: usize,
    pub kind: Kind,
}
pub struct FieldValue {
    pub current: f64,
    pub original: Option<f64>,
}
pub struct Session {
    document: Document,
    baseline: Option<Baseline>,
    tables: BTreeMap<usize, (Layout, Table)>,
}
impl Session {
    pub fn new(snapshot: Vec<u8>, baseline: Option<Baseline>) -> Result<Self, String> {
        Ok(Self {
            document: Document::new(snapshot, None)?,
            baseline,
            tables: BTreeMap::new(),
        })
    }
    /// Index an explicit schema once. Refuse duplicate IDs rather than editing an arbitrary row.
    pub fn index_table(&mut self, block: usize, layout: Layout) -> Result<(), String> {
        let header = self.document.blocks().get(block).ok_or("数据块不存在")?;
        let table = tables::parse(self.document.snapshot(), header, layout)?;
        if table.duplicate_keys != 0 {
            return Err("表内存在重复记录 ID，不能安全编辑".into());
        }
        self.tables.insert(block, (layout, table));
        Ok(())
    }
    fn offset(&self, field: Field) -> Result<usize, String> {
        self.tables
            .get(&field.block)
            .ok_or("数据表尚未完成索引")?
            .1
            .field_offset(field.record, field.relative, 4)
    }
    pub fn value(&self, field: Field) -> Result<FieldValue, String> {
        let offset = self.offset(field)?;
        let original = if let Some(baseline) = &self.baseline {
            let (layout, table) = &self.tables[&field.block];
            baseline.original(table, *layout, field.record, field.relative, field.kind)?
        } else {
            None
        };
        Ok(FieldValue {
            current: self
                .document
                .value(offset, field.kind)
                .map_err(str::to_string)?,
            original,
        })
    }
    pub fn set(&mut self, field: Field, value: f64) -> Result<(), String> {
        let offset = self.offset(field)?;
        self.document
            .set(offset, field.kind, value)
            .map_err(str::to_string)
    }
    pub fn restore(&mut self, field: Field) -> Result<(), String> {
        let original = self
            .value(field)?
            .original
            .ok_or("没有可信原值，无法恢复")?;
        self.set(field, original)
    }
    pub fn pending_count(&self) -> usize {
        self.document.pending_count()
    }

    pub fn snapshot(&self) -> &[u8] {
        self.document.snapshot()
    }
    pub fn render(&self, current_disk: &[u8]) -> Result<Vec<u8>, String> {
        self.document.render(current_disk).map_err(str::to_string)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture(duplicate: bool) -> Vec<u8> {
        let mut bytes = b"LDLD\x01\0\0\0".to_vec();
        bytes.extend(1u32.to_le_bytes());
        bytes.extend(32u32.to_le_bytes());
        bytes.extend([0; 8]);
        bytes.extend([0; 8]);
        bytes.extend(2u32.to_le_bytes());
        bytes.extend([0; 4]);
        for (key, value) in [(5u32, 1.3f32), (if duplicate { 5 } else { 9 }, -2.5)] {
            bytes.extend(key.to_le_bytes());
            bytes.extend(value.to_le_bytes());
        }
        bytes
    }
    #[test]
    fn typed_session_edits_only_selected_record_and_detects_stale_disk() {
        let disk = fixture(false);
        let mut session = Session::new(disk.clone(), None).unwrap();
        let field = Field {
            block: 0,
            record: Key::Id(9),
            relative: 4,
            kind: Kind::F32,
        };
        assert!(session.set(field, 42.0).is_err());
        session
            .index_table(
                0,
                Layout::Rows {
                    stride: 8,
                    id_offset: 0,
                },
            )
            .unwrap();
        assert_eq!(session.value(field).unwrap().current, -2.5);
        assert_eq!(session.value(field).unwrap().original, None);
        assert!(session.restore(field).is_err());
        session.set(field, 1_000_000.0).unwrap();
        let edited = session.render(&disk).unwrap();
        assert_eq!(&disk[..52], &edited[..52]);
        assert_eq!(crate::read(&edited, 52, Kind::F32).unwrap(), 1_000_000.0);
        assert!(session.render(&edited).is_err());
        assert!(session
            .set(
                Field {
                    relative: 7,
                    ..field
                },
                1.0
            )
            .is_err());
        assert!(session.set(field, f64::NAN).is_err());
        session.set(field, -2.5).unwrap();
        assert_eq!(session.pending_count(), 0);
    }
    #[test]
    fn duplicate_record_ids_cannot_be_indexed_for_editing() {
        let mut session = Session::new(fixture(true), None).unwrap();
        assert!(session
            .index_table(
                0,
                Layout::Rows {
                    stride: 8,
                    id_offset: 0
                }
            )
            .is_err());
    }
}
