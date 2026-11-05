//! Multi-file native workspace with stable record identities and joint history.
//! Pending values and trusted originals are separate; a current modded file is
//! never promoted to a baseline. Preparing output does not install anything.
use crate::{
    baseline::Baseline,
    binary::{Document, Encoding, Patch},
    dlbin,
    tables::{self, Key},
};
use std::{collections::BTreeMap, fs, ops::Range, path::PathBuf};

#[derive(Clone, Debug)]
pub struct Location {
    pub file: String,
    pub typ: u32,
    pub record: Record,
    pub relative: usize,
}
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Record {
    Table(Key),
    Delta(crate::arrays::DeltaKey),
    Kit {
        identity: [u32; 3],
        size: usize,
    },
    Resource {
        typ: u64,
        id: u64,
    },
    StatusModifier {
        status: u32,
        stat: u32,
        ordinal: u32,
    },
    Destruction {
        entity: u64,
        level: u8,
        direct: bool,
    },
}
impl From<Key> for Record {
    fn from(key: Key) -> Self {
        Self::Table(key)
    }
}
#[derive(Clone)]
struct Index {
    rows: BTreeMap<(u32, Record), Vec<Range<usize>>>,
    deltas: Vec<(usize, crate::arrays::Deltas)>,
    destruction: Option<crate::destruction::Index>,
    pub problems: Vec<String>,
}
impl Index {
    fn build(bytes: &[u8]) -> Result<Self, String> {
        let blocks = dlbin::index(bytes).map_err(|e| e.to_string())?;
        let mut out = Self {
            rows: BTreeMap::new(),
            deltas: Vec::new(),
            destruction: crate::destruction::Index::parse(bytes, &blocks)?,
            problems: Vec::new(),
        };
        for block in blocks {
            if block.type_id == crate::arrays::DELTAS {
                let parsed = crate::arrays::Deltas::parse(&bytes[block.payload.clone()])?;
                out.deltas.push((block.payload.start, parsed));
                continue;
            }
            if block.type_id == crate::arrays::ARMOR_KIT {
                let kit = crate::arrays::Kit::parse(&bytes[block.payload.clone()])?;
                out.rows
                    .entry((
                        block.type_id,
                        Record::Kit {
                            identity: kit.identity,
                            size: block.payload.len(),
                        },
                    ))
                    .or_default()
                    .push(block.payload);
                continue;
            }
            if block.type_id == crate::passive::TYPE {
                let passive = crate::passive::Passive::parse(&bytes[block.payload.clone()])?;
                out.rows
                    .entry((block.type_id, Key::Id(passive.id).into()))
                    .or_default()
                    .push(block.payload);
                continue;
            }
            let layouts = tables::layouts(block.type_id);
            if layouts.is_empty() {
                continue;
            }
            let candidates = layouts
                .into_iter()
                .filter_map(|layout| tables::parse(bytes, &block, layout).ok())
                .collect::<Vec<_>>();
            if candidates.len() != 1 || candidates[0].duplicate_keys != 0 {
                out.problems.push(format!(
                    "数据块 {:08X} 的布局或记录身份不唯一",
                    block.type_id
                ));
                continue;
            }
            for (key, row) in &candidates[0].rows {
                out.rows
                    .entry((block.type_id, (*key).into()))
                    .or_default()
                    .push(row.clone());
                if block.type_id == 0xC63E0B22 {
                    let Key::Id(status) = *key else {
                        return Err("状态效果记录身份无效".into());
                    };
                    let count = u32::from_le_bytes(
                        bytes[row.start + 120..row.start + 124].try_into().unwrap(),
                    ) as usize;
                    if count > 4096 {
                        return Err("状态修饰项数量过多".into());
                    }
                    if count == 0 {
                        continue;
                    }
                    let relative = usize::try_from(u64::from_le_bytes(
                        bytes[row.start + 112..row.start + 120].try_into().unwrap(),
                    ))
                    .map_err(|_| "状态修饰项偏移溢出")?;
                    let at = block
                        .payload
                        .start
                        .checked_add(relative)
                        .ok_or("状态修饰项偏移溢出")?;
                    let end = count
                        .checked_mul(8)
                        .and_then(|n| at.checked_add(n))
                        .ok_or("状态修饰项长度溢出")?;
                    if at < candidates[0].tail.start || end > block.payload.end {
                        return Err("状态修饰项越过尾部数据区".into());
                    }
                    let mut ordinals: BTreeMap<u32, u32> = BTreeMap::new();
                    for at in (at..end).step_by(8) {
                        let stat = u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap());
                        let ordinal = ordinals.entry(stat).or_default();
                        out.rows
                            .entry((
                                block.type_id,
                                Record::StatusModifier {
                                    status,
                                    stat,
                                    ordinal: *ordinal,
                                },
                            ))
                            .or_default()
                            .push(at..at + 8);
                        *ordinal += 1;
                    }
                }
            }
        }
        Ok(out)
    }
    fn offset(&self, location: &Location, width: usize) -> Result<Option<usize>, String> {
        if let Record::Destruction {
            entity,
            level,
            direct,
        } = &location.record
        {
            if location.typ != crate::destruction::SETTINGS
                || location.relative.checked_add(width).is_none_or(|n| n > 12)
            {
                return Err("拆毁参数类型或长度不匹配".into());
            }
            return self
                .destruction
                .as_ref()
                .ok_or("当前文件没有拆毁实体索引")?
                .offset(*entity, *level, *direct)
                .map(|v| v.map(|at| at + location.relative));
        }
        if let Record::Delta(key) = &location.record {
            if location.typ != crate::arrays::DELTAS {
                return Err("增量记录类型不匹配".into());
            }
            let mut resolved = None;
            for (base, deltas) in &self.deltas {
                if let Some(at) = deltas.resolve(key, location.relative, width)? {
                    if resolved.is_some() {
                        return Err("增量记录出现在多个数据块".into());
                    }
                    resolved = Some(base + at);
                }
            }
            return Ok(resolved);
        }
        let Some(rows) = self.rows.get(&(location.typ, location.record.clone())) else {
            return Ok(None);
        };
        if rows.len() != 1 {
            return Err("同一记录身份出现在多个数据块，无法安全定位".into());
        }
        let row = &rows[0];
        if location
            .relative
            .checked_add(width)
            .is_none_or(|end| end > row.len())
        {
            return Err("参数越过记录边界".into());
        }
        Ok(Some(row.start + location.relative))
    }
    fn codec(&self, encoding: &Encoding) -> Result<Encoding, String> {
        if matches!(encoding, Encoding::Demolition) {
            return Ok(Encoding::Tier(
                self.destruction
                    .as_ref()
                    .ok_or("当前文件没有拆毁模板")?
                    .tiers
                    .clone(),
            ));
        }
        Ok(encoding.clone())
    }
}
pub struct File {
    pub path: PathBuf,
    document: Document,
    index: Index,
    original: Option<(Vec<u8>, Index)>,
}
impl File {
    pub fn new(
        path: PathBuf,
        current: Vec<u8>,
        original: Option<Baseline>,
    ) -> Result<Self, String> {
        let index = Index::build(&current)?;
        let original = original
            .map(|b| Index::build(b.bytes()).map(|i| (b.into_bytes(), i)))
            .transpose()?;
        Ok(Self {
            path,
            index,
            document: Document::new(current)?,
            original,
        })
    }
    /// The caller authenticates archive originals against a compiled manifest;
    /// unknown data remains editable but cannot provide reset/default values.
    pub(crate) fn resource(
        path: PathBuf,
        current: Vec<u8>,
        record: Record,
        original: Option<Vec<u8>>,
    ) -> Result<Self, String> {
        if !matches!(record, Record::Resource { .. }) {
            return Err("独立资源身份类型无效".into());
        }
        let make = |len| Index {
            rows: BTreeMap::from([((0x5F7203C8, record.clone()), vec![0..len])]),
            deltas: Vec::new(),
            destruction: None,
            problems: Vec::new(),
        };
        let index = make(current.len());
        let original = original.map(|b| {
            let i = make(b.len());
            (b, i)
        });
        Ok(Self {
            path,
            document: Document::resource(current)?,
            index,
            original,
        })
    }
}
#[derive(Clone, PartialEq)]
pub struct Checkpoint {
    files: BTreeMap<String, BTreeMap<usize, u8>>,
    metadata: serde_json::Value,
}
#[derive(Default)]
pub struct Workspace {
    files: BTreeMap<String, File>,
    metadata: serde_json::Value,
    undo: Vec<Checkpoint>,
    redo: Vec<Checkpoint>,
}
pub struct Value {
    pub current: f64,
    pub original: Option<f64>,
    pub loaded: f64,
}
impl Workspace {
    pub(crate) fn contains(&self, name: &str) -> bool {
        self.files.keys().any(|key| key.eq_ignore_ascii_case(name))
    }
    pub(crate) fn has_path(&self, path: &std::path::Path) -> bool {
        self.files.values().any(|file| {
            file.path
                .to_string_lossy()
                .eq_ignore_ascii_case(&path.to_string_lossy())
        })
    }
    pub fn add(&mut self, name: String, file: File) -> Result<(), String> {
        if name.is_empty()
            || name.contains(['/', '\\', ':', '\0'])
            || name == "."
            || name == ".."
            || self.files.keys().any(|key| key.eq_ignore_ascii_case(&name))
        {
            return Err("数据文件名无效或重复".into());
        }
        if self.files.values().any(|existing| {
            existing
                .path
                .to_string_lossy()
                .eq_ignore_ascii_case(&file.path.to_string_lossy())
        }) {
            return Err("工作区的源文件路径重复".into());
        }
        if !self.undo.is_empty() || !self.redo.is_empty() || self.pending_count() != 0 {
            return Err("已有修改时不能变更工作区文件集合".into());
        }
        self.files.insert(name, file);
        Ok(())
    }
    pub fn checkpoint(&self) -> Checkpoint {
        Checkpoint {
            files: self
                .files
                .iter()
                .map(|(name, file)| (name.clone(), file.document.checkpoint()))
                .collect(),
            metadata: self.metadata.clone(),
        }
    }
    fn resume(&mut self, snapshot: Checkpoint) {
        for (name, pending) in snapshot.files {
            self.files
                .get_mut(&name)
                .expect("fixed workspace files")
                .document
                .resume(pending);
        }
        self.metadata = snapshot.metadata;
    }
    pub fn metadata(&self) -> &serde_json::Value {
        &self.metadata
    }
    pub fn pending_count(&self) -> usize {
        self.files
            .values()
            .map(|f| f.document.pending_count())
            .sum()
    }
    pub fn history(&self) -> (usize, usize) {
        (self.undo.len(), self.redo.len())
    }
    pub fn undo(&mut self) -> bool {
        if let Some(before) = self.undo.pop() {
            self.redo.push(self.checkpoint());
            self.resume(before);
            true
        } else {
            false
        }
    }
    pub fn redo(&mut self) -> bool {
        if let Some(after) = self.redo.pop() {
            self.undo.push(self.checkpoint());
            self.resume(after);
            true
        } else {
            false
        }
    }
    fn edit(&mut self, change: impl FnOnce(&mut Self) -> Result<(), String>) -> Result<(), String> {
        let before = self.checkpoint();
        if let Err(error) = change(self) {
            self.resume(before);
            return Err(error);
        }
        if self.checkpoint() != before {
            if self.undo.len() == 100 {
                self.undo.remove(0);
            }
            self.undo.push(before);
            self.redo.clear();
        }
        Ok(())
    }
    pub fn value(&self, location: &Location, encoding: &Encoding) -> Result<Value, String> {
        let file = self
            .files
            .get(&location.file)
            .ok_or("工作区没有该数据文件")?;
        let width = encoding.width()?;
        let at = file
            .index
            .offset(location, width)?
            .ok_or("当前数据中没有该记录")?;
        let current_codec = file.index.codec(encoding)?;
        let loaded = current_codec.read(&file.document.snapshot()[at..at + width])?;
        let current = file.document.value(at, &current_codec)?;
        let original = if let Some((baseline, index)) = &file.original {
            index
                .offset(location, width)?
                .map(|offset| {
                    index
                        .codec(encoding)?
                        .read(&baseline[offset..offset + width])
                })
                .transpose()?
        } else {
            None
        };
        Ok(Value {
            current,
            original,
            loaded,
        })
    }
    pub fn demolition_choice(
        &self,
        location: &Location,
        target: f64,
    ) -> Result<(u32, u32), String> {
        if !target.is_finite() {
            return Err("拆毁阈值必须是有限数值".into());
        }
        let file = self.files.get(&location.file).ok_or("拆毁数据文件未打开")?;
        let tiers = &file.index.destruction.as_ref().ok_or("缺少拆毁模板")?.tiers;
        let now = self.value(location, &Encoding::Demolition)?.current;
        let mut best: Option<(u32, u32)> = None;
        for &id in &[1, 2, 3, 4, 5, 6, 9] {
            if let Some(&threshold) = tiers.get(&id) {
                if (threshold as f64 - target).abs() < 0.5 {
                    return Ok((threshold, id));
                }
                if target > now
                    && threshold as f64 >= target
                    && best.is_none_or(|(old, _)| threshold < old)
                    || target < now
                        && threshold as f64 <= target
                        && best.is_none_or(|(old, _)| threshold > old)
                {
                    best = Some((threshold, id));
                }
            }
        }
        best.ok_or_else(|| "该方向没有可用的拆毁模板".into())
    }
    pub fn set_batch(
        &mut self,
        values: &[(Location, Encoding, f64)],
        metadata: Option<serde_json::Value>,
    ) -> Result<(), String> {
        let mut changes: BTreeMap<String, Vec<Patch>> = BTreeMap::new();
        for (location, encoding, value) in values {
            let file = self
                .files
                .get(&location.file)
                .ok_or("工作区没有该数据文件")?;
            let at = file
                .index
                .offset(location, encoding.width()?)?
                .ok_or("当前数据中没有该记录")?;
            changes
                .entry(location.file.clone())
                .or_default()
                .push(file.index.codec(encoding)?.encode(at, *value)?);
        }
        self.edit(move |workspace| {
            for (name, patches) in changes {
                workspace
                    .files
                    .get_mut(&name)
                    .unwrap()
                    .document
                    .apply(&patches)?;
            }
            if let Some(metadata) = metadata {
                workspace.metadata = metadata;
            }
            Ok(())
        })
    }
    pub fn restore(&mut self, location: Location, encoding: Encoding) -> Result<(), String> {
        let value = self
            .value(&location, &encoding)?
            .original
            .ok_or("没有可信原始值，不能恢复")?;
        self.set_batch(&[(location, encoding, value)], None)
    }
    pub fn problems(&self) -> Vec<String> {
        self.files
            .iter()
            .flat_map(|(name, file)| {
                file.index
                    .problems
                    .iter()
                    .map(move |why| format!("{name}: {why}"))
            })
            .collect()
    }
    pub fn snapshots(&self) -> impl Iterator<Item = (&str, &[u8])> {
        self.files
            .iter()
            .map(|(name, file)| (name.as_str(), file.document.snapshot()))
    }
    /// Read and validate every source before returning any prepared plaintext.
    pub fn render_all(&self) -> Result<BTreeMap<String, Vec<u8>>, String> {
        self.files
            .iter()
            .map(|(name, file)| {
                let disk =
                    fs::read(&file.path).map_err(|_| format!("无法核对 {name} 的磁盘数据"))?;
                file.document
                    .render(&disk)
                    .map(|bytes| (name.clone(), bytes))
            })
            .collect()
    }
    pub fn rendered(&self, name: &str) -> Result<Vec<u8>, String> {
        let file = self.files.get(name).ok_or("工作区没有该数据文件")?;
        file.document.render(file.document.snapshot())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn bytes(id: u32, value: u32) -> Vec<u8> {
        let mut b = b"LDLD\x01\0\0\0".to_vec();
        b.extend(0xE0A72CF0u32.to_le_bytes());
        b.extend(92u32.to_le_bytes());
        b.extend([0; 8]);
        b.extend(16u64.to_le_bytes());
        b.extend(1u32.to_le_bytes());
        b.extend([0; 4]);
        b.extend(id.to_le_bytes());
        b.extend(value.to_le_bytes());
        b.extend([0; 68]);
        b
    }
    fn loc(file: &str, id: u32) -> Location {
        Location {
            file: file.into(),
            typ: 0xE0A72CF0,
            record: Key::Id(id).into(),
            relative: 4,
        }
    }
    #[test]
    fn multi_file_edits_roll_back_as_one_action_and_keep_redo_on_failure() {
        let mut w = Workspace::default();
        w.add(
            "a".into(),
            File::new("a".into(), bytes(1, 50), None).unwrap(),
        )
        .unwrap();
        w.add(
            "b".into(),
            File::new("b".into(), bytes(2, 70), None).unwrap(),
        )
        .unwrap();
        w.set_batch(
            &[
                (loc("a", 1), Encoding::U32, 100.0),
                (loc("b", 2), Encoding::U32, 200.0),
            ],
            Some(serde_json::json!({"scope":"armor"})),
        )
        .unwrap();
        assert_eq!(
            w.value(&loc("a", 1), &Encoding::U32).unwrap().original,
            None
        );
        assert_eq!(w.value(&loc("a", 1), &Encoding::U32).unwrap().loaded, 50.0);
        assert_eq!(w.history(), (1, 0));
        assert!(w.undo());
        assert_eq!(w.pending_count(), 0);
        assert!(w.metadata().is_null());
        assert!(w
            .set_batch(
                &[
                    (loc("a", 1), Encoding::U32, 9.0),
                    (loc("b", 99), Encoding::U32, 2.0)
                ],
                None
            )
            .is_err());
        assert_eq!(w.history(), (0, 1));
        assert!(w.redo());
        assert_eq!(
            w.value(&loc("b", 2), &Encoding::U32).unwrap().current,
            200.0
        );
        let before = w.checkpoint();
        assert!(w
            .set_batch(
                &[
                    (loc("a", 1), Encoding::U32, 9.0),
                    (loc("b", 2), Encoding::U32, 3.0),
                    (loc("b", 2), Encoding::U32, 4.0)
                ],
                None
            )
            .is_err());
        assert!(w.checkpoint() == before);
    }
    #[test]
    fn missing_default_and_duplicate_record_never_guess() {
        let mut w = Workspace::default();
        let one = bytes(1, 50);
        let duplicated = [one.clone(), one].concat();
        w.add("a".into(), File::new("a".into(), duplicated, None).unwrap())
            .unwrap();
        assert!(w.value(&loc("a", 1), &Encoding::U32).is_err());
        assert!(w.restore(loc("a", 1), Encoding::U32).is_err());
        assert_eq!(w.pending_count(), 0);
    }
}
