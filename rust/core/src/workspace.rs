//! Multi-file native workspace with stable record identities and joint history.
//! Pending values and trusted originals are separate; a current modded file is
//! never promoted to a baseline. Preparing output does not install anything.
use crate::{
    baseline::Baseline,
    binary::{Document, Encoding, Patch},
    dlbin,
    tables::{self, Key},
};
use std::{borrow::Cow, collections::BTreeMap, fs, ops::Range, path::PathBuf};

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
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
    fn codec<'a>(&self, encoding: &'a Encoding) -> Result<Cow<'a, Encoding>, String> {
        if matches!(encoding, Encoding::Demolition) {
            return Ok(Cow::Owned(Encoding::Tier(
                self.destruction
                    .as_ref()
                    .ok_or("当前文件没有拆毁模板")?
                    .tiers
                    .clone(),
            )));
        }
        Ok(Cow::Borrowed(encoding))
    }
}
pub struct File {
    pub path: PathBuf,
    sealed_source: Option<(usize, String)>,
    document: Document,
    index: Index,
    original: Option<(Vec<u8>, Index)>,
    codebook: Option<crate::stratagem_code::Codebook>,
    original_codebook: Option<crate::stratagem_code::Codebook>,
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
        let has_codes = path.file_name().and_then(|s| s.to_str()).is_some_and(|s| {
            s == crate::stratagem_code::FILE || s == "generated_stratagem_settings.dl_plain"
        });
        let codebook = has_codes
            .then(|| crate::stratagem_code::Codebook::parse(&current))
            .transpose()?;
        let original_codebook = if has_codes {
            original
                .as_ref()
                .map(|(bytes, _)| crate::stratagem_code::Codebook::parse(bytes))
                .transpose()?
        } else {
            None
        };
        Ok(Self {
            path,
            sealed_source: None,
            index,
            document: Document::new(current)?,
            original,
            codebook,
            original_codebook,
        })
    }
    pub(crate) fn sealed(
        path: PathBuf,
        cipher: Vec<u8>,
        original: Option<Baseline>,
    ) -> Result<Self, String> {
        let plain = crate::sealed::open_data(&cipher).map_err(|e| e.to_string())?;
        let source = (cipher.len(), crate::hash::sha256_hex(&cipher));
        let mut file = Self::new(path, plain, original)?;
        file.sealed_source = Some(source);
        Ok(file)
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
            sealed_source: None,
            document: Document::resource(current)?,
            index,
            original,
            codebook: None,
            original_codebook: None,
        })
    }
    fn disk_bytes(&self) -> Result<Vec<u8>, String> {
        let size = self
            .sealed_source
            .as_ref()
            .map_or(self.document.snapshot().len(), |(size, _)| *size);
        if fs::metadata(&self.path)
            .map_err(|_| "无法核对磁盘数据")?
            .len()
            != size as u64
        {
            return Err("打开后的磁盘数据已被修改，未导出".into());
        }
        let bytes = fs::read(&self.path).map_err(|_| "无法核对磁盘数据")?;
        if let Some((_, expected)) = &self.sealed_source {
            if crate::hash::sha256_hex(&bytes) != *expected {
                return Err("打开后的密封数据已被修改，未导出".into());
            }
        } else if bytes != self.document.snapshot() {
            return Err("打开后的磁盘数据已被修改，未导出".into());
        }
        Ok(bytes)
    }
    fn checked_render(&self) -> Result<Vec<u8>, String> {
        self.disk_bytes()?;
        self.document.render(self.document.snapshot())
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
    blocked_files: BTreeMap<String, String>,
    suspended_draft: BTreeMap<String, DraftFile>,
    suspended_source: Option<Vec<u8>>,
    draft_problems: Vec<String>,
    installed_from: BTreeMap<String, Option<(Vec<u8>, Index)>>,
    metadata: serde_json::Value,
    undo: Vec<Checkpoint>,
    redo: Vec<Checkpoint>,
    draft: Option<(PathBuf, Option<Vec<u8>>)>,
    loaded_metadata: serde_json::Value,
}
#[derive(serde::Deserialize, serde::Serialize)]
struct Draft {
    version: u32,
    metadata: serde_json::Value,
    files: BTreeMap<String, DraftFile>,
}
#[derive(Clone, serde::Deserialize, serde::Serialize)]
struct DraftFile {
    source: String,
    bytes: BTreeMap<usize, u8>,
}
pub(crate) struct RestoredFile {
    pub bytes: Vec<u8>,
    pub source: String,
}
pub struct Value {
    pub current: f64,
    pub original: Option<f64>,
    pub loaded: f64,
}
impl Workspace {
    pub(crate) fn block_resource(&mut self, name: String, error: String) {
        self.blocked_files.insert(name, error);
    }
    pub(crate) fn resource_conflicts(&self) -> impl Iterator<Item = &String> {
        self.blocked_files.values()
    }
    pub(crate) fn draft_conflicts(&self) -> impl Iterator<Item = &String> {
        self.draft_problems.iter()
    }
    pub(crate) fn disk_checks(&self) -> Vec<(&str, Result<&str, String>)> {
        self.files
            .iter()
            .filter(|(_, file)| file.sealed_source.is_some())
            .map(|(name, file)| {
                let status = file.disk_bytes().map(|_| {
                    if self.installed_from.contains_key(name) {
                        "编辑器已安装"
                    } else if let Some((original, _)) = &file.original {
                        if file.document.snapshot() == original {
                            "与可信原值一致"
                        } else {
                            "打开时与可信原值不同"
                        }
                    } else {
                        "与打开时一致，缺少独立原值"
                    }
                });
                (name.as_str(), status)
            })
            .collect()
    }
    pub(crate) fn remember_install_source(
        &mut self,
        name: &str,
        original: Vec<u8>,
    ) -> Result<(), String> {
        let file = self.files.get(name).ok_or("已安装文件缺少工作区记录")?;
        let source = if file
            .original
            .as_ref()
            .is_some_and(|(bytes, _)| bytes == &original)
        {
            None
        } else {
            let index = Index::build(&original)?;
            Some((original, index))
        };
        self.installed_from.insert(name.to_string(), source);
        Ok(())
    }
    pub(crate) fn field_edited(
        &self,
        location: &Location,
        encoding: &Encoding,
    ) -> Result<bool, String> {
        let values = self.value(location, encoding)?;
        if values.current != values.loaded {
            return Ok(true);
        }
        if matches!(location.record, Record::Resource { .. }) {
            return Ok(values
                .original
                .is_some_and(|before| before != values.current));
        }
        match self.installed_from.get(&location.file) {
            Some(Some((bytes, index))) => {
                let width = encoding.width()?;
                let Some(at) = index.offset(location, width)? else {
                    return Ok(false);
                };
                Ok(index.codec(encoding)?.read(&bytes[at..at + width])? != values.current)
            }
            Some(None) => Ok(values
                .original
                .is_some_and(|before| before != values.current)),
            None => Ok(false),
        }
    }
    pub(crate) fn contains(&self, name: &str) -> bool {
        self.files.keys().any(|key| key.eq_ignore_ascii_case(name))
    }
    pub(crate) fn table_ids(&self, typ: u32) -> Result<Vec<u32>, String> {
        let mut ids = std::collections::BTreeSet::new();
        for file in self.files.values() {
            for ((kind, record), rows) in file.index.rows.range((typ, Key::Id(0).into())..) {
                if *kind != typ {
                    break;
                }
                if let Record::Table(Key::Id(id)) = record {
                    if rows.len() != 1 || !ids.insert(*id) {
                        return Err("数据表存在重复记录编号".into());
                    }
                }
            }
        }
        Ok(ids.into_iter().collect())
    }
    pub(crate) fn table_value(
        &self,
        typ: u32,
        key: Key,
        relative: usize,
    ) -> Result<Option<f64>, String> {
        let location = Location {
            file: String::new(),
            typ,
            record: key.into(),
            relative,
        };
        let mut result = None;
        for file in self.files.values() {
            if let Some(at) = file.index.offset(&location, 4)? {
                if result.is_some() {
                    return Err("跨数据文件存在重复引用身份".into());
                }
                result = Some(file.document.value(at, &Encoding::U32)?);
            }
        }
        Ok(result)
    }
    pub(crate) fn table_location(
        &self,
        typ: u32,
        id: u32,
        relative: usize,
    ) -> Result<Location, String> {
        let record = Record::from(Key::Id(id));
        let mut result = None;
        for (name, file) in &self.files {
            if file.index.rows.contains_key(&(typ, record.clone())) {
                if result.is_some() {
                    return Err("跨数据文件存在重复引用身份".into());
                }
                result = Some(Location {
                    file: name.clone(),
                    typ,
                    record: record.clone(),
                    relative,
                });
            }
        }
        result.ok_or_else(|| "当前数据中没有该记录".into())
    }
    pub(crate) fn table_locations(
        &self,
        typ: u32,
        relative: impl Fn(usize) -> usize,
    ) -> Result<Vec<Location>, String> {
        let mut list = Vec::new();
        for (name, file) in &self.files {
            for ((kind, record), ranges) in &file.index.rows {
                if *kind != typ {
                    continue;
                }
                if ranges.len() != 1 {
                    return Err("参数表身份重复".into());
                }
                list.push(Location {
                    file: name.clone(),
                    typ,
                    record: record.clone(),
                    relative: relative(ranges[0].len()),
                });
            }
        }
        Ok(list)
    }
    pub(crate) fn table_bytes(
        &self,
        typ: u32,
        key: Key,
        original: bool,
    ) -> Result<Option<&[u8]>, String> {
        let mut result = None;
        let record: Record = key.into();
        for file in self.files.values() {
            let (bytes, index) = if original {
                let Some((bytes, index)) = &file.original else {
                    continue;
                };
                (bytes.as_slice(), index)
            } else {
                (file.document.snapshot(), &file.index)
            };
            if let Some(rows) = index.rows.get(&(typ, record.clone())) {
                if rows.len() != 1 || result.is_some() {
                    return Err("数据表存在重复引用身份".into());
                }
                result = bytes.get(rows[0].clone());
            }
        }
        Ok(result)
    }
    pub(crate) fn table_payload_slice(
        &self,
        typ: u32,
        key: Key,
        relative: usize,
        size: usize,
    ) -> Result<&[u8], String> {
        let record: Record = key.into();
        let mut result = None;
        for file in self.files.values() {
            if let Some(rows) = file.index.rows.get(&(typ, record.clone())) {
                if rows.len() != 1 || result.is_some() {
                    return Err("数据表存在重复引用身份".into());
                }
                let block = file
                    .document
                    .blocks()
                    .iter()
                    .find(|b| b.type_id == typ && b.payload.contains(&rows[0].start))
                    .ok_or("找不到资源数组所属数据块")?;
                let at = block
                    .payload
                    .start
                    .checked_add(relative)
                    .ok_or("资源数组偏移溢出")?;
                if !block.contains(at, size) {
                    return Err("资源数组越界".into());
                }
                result = Some(&file.document.snapshot()[at..at + size]);
            }
        }
        result.ok_or_else(|| "找不到资源数组".into())
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
    pub(crate) fn loaded_metadata(&self) -> &serde_json::Value {
        &self.loaded_metadata
    }
    pub(crate) fn set_loaded_metadata(&mut self, value: serde_json::Value) -> Result<(), String> {
        if !(value.is_object() || value.is_null()) {
            return Err("已安装编辑器配置无效".into());
        }
        self.loaded_metadata = value.clone();
        self.metadata = value;
        Ok(())
    }
    pub fn pending_count(&self) -> usize {
        self.files
            .values()
            .map(|f| f.document.pending_count())
            .sum()
    }
    pub(crate) fn file_has_pending(&self, name: &str) -> bool {
        self.files
            .get(name)
            .is_some_and(|file| file.document.pending_count() > 0)
    }
    pub fn history(&self) -> (usize, usize) {
        (self.undo.len(), self.redo.len())
    }
    fn fingerprint(&self, name: &str) -> String {
        let file = &self.files[name];
        file.sealed_source.as_ref().map_or_else(
            || crate::hash::sha256_hex(file.document.snapshot()),
            |(_, hash)| hash.clone(),
        )
    }
    pub(crate) fn configure_draft(&mut self, path: PathBuf) -> Result<(), String> {
        let disk = crate::install::read(&path)?;
        if let Some(bytes) = &disk {
            if bytes.len() > 8 * 1024 * 1024 {
                return Err("编辑草稿过大".into());
            }
            let draft: Draft = serde_json::from_slice(bytes).map_err(|_| "编辑草稿无效")?;
            if draft.version != 1 || !(draft.metadata.is_null() || draft.metadata.is_object()) {
                return Err("编辑草稿版本无效".into());
            }
            let mut snapshot = self.checkpoint();
            for (name, pending) in draft.files {
                if self.blocked_files.contains_key(&name) {
                    self.suspended_draft.insert(name, pending);
                    continue;
                }
                // A draft records byte offsets into the data it was captured
                // from, so it can only be replayed onto that exact source. When
                // the game or another tool changed the file, replaying it would
                // silently corrupt unrelated records. The draft stays on disk
                // and is reported instead of aborting startup: otherwise the
                // editor can never open again to recover or discard it.
                let mut conflict = None;
                if let Some(file) = self.files.get(&name) {
                    if pending.source != self.fingerprint(&name) {
                        conflict = Some(format!(
                            "{name} 已由其他工具或游戏更新改变，草稿已保留但未应用；该文件的编辑以当前游戏数据为准"
                        ));
                    } else if pending
                        .bytes
                        .keys()
                        .any(|&offset| file.document.slice(offset, 1).is_err())
                    {
                        conflict = Some(format!(
                            "{name} 的草稿位置超出当前数据范围，草稿已保留但未应用；该文件的编辑以当前游戏数据为准"
                        ));
                    }
                } else {
                    conflict = Some(format!("{name} 不在当前数据文件集合中，草稿已保留但未应用"));
                }
                match conflict {
                    Some(conflict) => {
                        self.suspended_draft.insert(name, pending);
                        self.draft_problems.push(conflict);
                    }
                    None => {
                        snapshot.files.insert(name, pending.bytes);
                    }
                }
            }
            snapshot.metadata = draft.metadata;
            self.resume(snapshot);
            if !self.suspended_draft.is_empty() {
                self.suspended_source = Some(bytes.clone());
            }
        }
        self.draft = Some((path, disk));
        if !self.suspended_draft.is_empty() {
            let suspended = std::mem::take(&mut self.suspended_draft);
            match self.persist(&self.checkpoint()) {
                Ok(()) => {
                    self.suspended_source = None;
                    self.draft_problems.push(
                        "冲突草稿已完整转存为同目录的 draft-recovery 恢复副本，当前游戏数据可继续编辑。"
                            .into(),
                    );
                }
                Err(error) => {
                    self.suspended_draft = suspended;
                    self.draft_problems
                        .push(format!("旧草稿仍保留在原文件，恢复副本尚未保存：{error}"));
                }
            }
        }
        Ok(())
    }
    pub(crate) fn valid_draft(bytes: &[u8]) -> bool {
        serde_json::from_slice::<Draft>(bytes).is_ok_and(|draft| {
            draft.version == 1 && (draft.metadata.is_null() || draft.metadata.is_object())
        })
    }
    pub(crate) fn draft_recovery(&self) -> Result<Option<crate::install::Change>, String> {
        let Some(bytes) = &self.suspended_source else {
            return Ok(None);
        };
        let Some((path, _)) = &self.draft else {
            return Ok(None);
        };
        let path = path.with_file_name(format!(
            "draft-recovery-{}.json",
            crate::hash::sha256_hex(bytes)
        ));
        match crate::install::read(&path)? {
            Some(saved) if saved == *bytes => Ok(None),
            Some(_) => Err("旧草稿恢复副本与原内容不一致，未覆盖".into()),
            None => Ok(Some(crate::install::Change {
                path,
                before: None,
                after: Some(bytes.clone()),
            })),
        }
    }
    fn persist(&mut self, next: &Checkpoint) -> Result<(), String> {
        let Some((path, disk)) = &self.draft else {
            return Ok(());
        };
        let mut files = self.suspended_draft.clone();
        for (name, bytes) in &next.files {
            if !bytes.is_empty() {
                files.insert(
                    name.clone(),
                    DraftFile {
                        source: self.fingerprint(name),
                        bytes: bytes.clone(),
                    },
                );
            }
        }
        let encoded = serde_json::to_vec(&Draft {
            version: 1,
            metadata: next.metadata.clone(),
            files,
        })
        .map_err(|_| "无法编码编辑草稿")?;
        if encoded.len() > 8 * 1024 * 1024 {
            return Err("编辑草稿过大".into());
        }
        let folder = path.parent().ok_or("草稿目录无效")?;
        fs::create_dir_all(folder).map_err(|_| "无法创建草稿目录")?;
        let _lock = crate::install::lock_transaction(folder)?;
        if crate::install::read(path)? != *disk {
            return Err("其他编辑器实例已更改草稿，请重新打开".into());
        }
        if let Some(recovery) = self.draft_recovery()? {
            crate::install::save_atomic(&recovery.path, recovery.after.as_ref().unwrap())?;
        }
        crate::install::save_atomic(path, &encoded)?;
        self.draft.as_mut().unwrap().1 = Some(encoded);
        Ok(())
    }
    pub(crate) fn finish_draft(&self) -> Option<crate::install::Change> {
        let (path, disk) = self.draft.as_ref()?;
        disk.as_ref()?;
        Some(crate::install::Change {
            path: path.clone(),
            before: disk.clone(),
            after: None,
        })
    }
    pub(crate) fn draft_metadata_change(
        &self,
        key: &str,
        replacement: &serde_json::Value,
    ) -> Result<Option<crate::install::Change>, String> {
        let Some((path, Some(disk))) = &self.draft else {
            return Ok(None);
        };
        let mut draft: Draft = serde_json::from_slice(disk).map_err(|_| "编辑草稿无效")?;
        if draft.metadata.is_null() {
            draft.metadata = serde_json::json!({});
        }
        if replacement.is_null() {
            draft
                .metadata
                .as_object_mut()
                .ok_or("编辑草稿配置无效")?
                .remove(key);
        } else {
            draft.metadata[key] = replacement.clone();
        }
        let bytes = serde_json::to_vec(&draft).map_err(|_| "无法编码修复后的草稿")?;
        Ok(Some(crate::install::Change {
            path: path.clone(),
            before: Some(disk.clone()),
            after: Some(bytes),
        }))
    }
    pub(crate) fn migrate_draft(
        &mut self,
        build: impl FnOnce(&mut Self) -> Result<Vec<String>, String>,
    ) -> Result<Vec<String>, String> {
        let Some(draft) = self.draft.take() else {
            return Ok(Vec::new());
        };
        let before = self.checkpoint();
        let result = build(self);
        self.draft = Some(draft);
        let result = result.and_then(|warnings| {
            self.persist(&self.checkpoint())?;
            Ok(warnings)
        });
        if result.is_err() {
            self.resume(before);
        }
        self.undo.clear();
        self.redo.clear();
        result
    }
    pub(crate) fn restored_draft(
        &self,
        catalog: &crate::catalog::Catalog,
        restored: &BTreeMap<String, RestoredFile>,
        mut metadata: serde_json::Value,
    ) -> Result<Option<crate::install::Change>, String> {
        let Some((path, disk)) = &self.draft else {
            return Ok(None);
        };
        let words = crate::extra_stratagem::clear_words(self)?;
        let mut locations = BTreeMap::<&str, BTreeMap<&Location, usize>>::new();
        for binding in catalog.bindings.iter().flatten() {
            let width = binding.encoding.width()?;
            for location in &binding.locations {
                if restored.contains_key(&location.file) {
                    let fields = locations.entry(&location.file).or_default();
                    let stored = fields.entry(location).or_default();
                    *stored = (*stored).max(width);
                }
            }
        }
        // Drafts set aside on open (their source changed outside the editor)
        // stay in the file: dropping them here would discard edits the user was
        // told were kept for recovery.
        let mut files = self.suspended_draft.clone();
        for (name, file) in &self.files {
            let pending = file.document.checkpoint();
            let Some(after) = restored.get(name) else {
                if !pending.is_empty() {
                    files.insert(
                        name.clone(),
                        DraftFile {
                            source: self.fingerprint(name),
                            bytes: pending,
                        },
                    );
                }
                continue;
            };
            let resource = matches!(
                file.index.rows.keys().next(),
                Some((_, Record::Resource { .. }))
            );
            let target = if resource {
                file.index.clone()
            } else {
                Index::build(&after.bytes)?
            };
            let mut current = file.document.render(file.document.snapshot())?;
            for (location, value) in words.iter().filter(|(location, _)| location.file == *name) {
                let at = file.index.offset(location, 4)?.ok_or("派生战备记录缺失")?;
                current[at..at + 4].copy_from_slice(&value.to_le_bytes());
            }
            let mut staged = BTreeMap::new();
            let mut moved = std::collections::BTreeSet::new();
            let copy = |from: usize,
                        to: usize,
                        width: usize,
                        staged: &mut BTreeMap<usize, u8>,
                        moved: &mut std::collections::BTreeSet<usize>|
             -> Result<(), String> {
                let bytes = current.get(from..from + width).ok_or("原草稿字段越界")?;
                let original = after
                    .bytes
                    .get(to..to + width)
                    .ok_or("恢复后的草稿字段越界")?;
                for (i, (&wanted, &old)) in bytes.iter().zip(original).enumerate() {
                    if pending.contains_key(&(from + i)) {
                        moved.insert(from + i);
                    }
                    if wanted != old {
                        staged.insert(to + i, wanted);
                    }
                }
                Ok(())
            };
            if resource && after.bytes.len() == current.len() {
                copy(0, 0, current.len(), &mut staged, &mut moved)?;
            } else if let Some(fields) = locations.get(name.as_str()) {
                for (location, &width) in fields {
                    let (Some(from), Some(to)) = (
                        file.index.offset(location, width)?,
                        target.offset(location, width)?,
                    ) else {
                        continue;
                    };
                    let derived_armor = (name == crate::desktop_armor::PASSIVE
                        || name == crate::desktop_armor::KITS && location.relative == 28)
                        && !metadata["armor"].is_null();
                    if !derived_armor || pending.range(from..from + width).next().is_some() {
                        copy(from, to, width, &mut staged, &mut moved)?;
                    }
                }
            }
            if moved.len() != pending.len() {
                return Err(format!(
                    "{name} 的未写入参数无法安全映射到恢复后的数据。请先保存为预设。"
                ));
            }
            if name == crate::stratagem_code::FILE {
                let book = crate::stratagem_code::Codebook::parse(&after.bytes)?;
                for field in &catalog.fields {
                    let Some(typ) = field.stratagem_code else {
                        continue;
                    };
                    if !metadata["virtual"][&field.key].is_null() {
                        continue;
                    }
                    if let (Some(current), Some(original)) = (
                        self.codebook(false).and_then(|book| book.get(typ)),
                        book.get(typ),
                    ) {
                        if current != original {
                            metadata["virtual"][&field.key] = serde_json::json!(current);
                        }
                    }
                }
            }
            if !staged.is_empty() {
                files.insert(
                    name.clone(),
                    DraftFile {
                        source: after.source.clone(),
                        bytes: staged,
                    },
                );
            }
        }
        if let Some(object) = metadata.as_object_mut() {
            object.remove(crate::extra_stratagem::GENERATED);
        }
        if disk.is_none() && files.is_empty() && metadata.is_null() {
            return Ok(None);
        }
        let after = serde_json::to_vec(&Draft {
            version: 1,
            metadata,
            files,
        })
        .map_err(|_| "无法保存恢复后的编辑草稿")?;
        if after.len() > 8 * 1024 * 1024 {
            return Err("恢复后的草稿过大，请先保存为预设".into());
        }
        Ok(Some(crate::install::Change {
            path: path.clone(),
            before: disk.clone(),
            after: Some(after),
        }))
    }
    pub fn undo(&mut self) -> bool {
        self.replay(false).unwrap_or(false)
    }
    pub fn redo(&mut self) -> bool {
        self.replay(true).unwrap_or(false)
    }
    pub(crate) fn replay(&mut self, redo: bool) -> Result<bool, String> {
        let stack = if redo { &self.redo } else { &self.undo };
        let Some(next) = stack.last().cloned() else {
            return Ok(false);
        };
        self.persist(&next)?;
        let current = self.checkpoint();
        if redo {
            self.redo.pop();
            self.undo.push(current);
        } else {
            self.undo.pop();
            self.redo.push(current);
        }
        self.resume(next);
        Ok(true)
    }
    fn edit(&mut self, change: impl FnOnce(&mut Self) -> Result<(), String>) -> Result<(), String> {
        let before = self.checkpoint();
        if let Err(error) = change(self) {
            self.resume(before);
            return Err(error);
        }
        let next = self.checkpoint();
        if next != before {
            if let Err(err) = self.persist(&next) {
                self.resume(before);
                return Err(err);
            }
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
    fn encode_batch(
        &self,
        values: &[(Location, Encoding, f64)],
    ) -> Result<BTreeMap<String, Vec<Patch>>, String> {
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
        Ok(changes)
    }
    pub(crate) fn validate_batch(
        &self,
        values: &[(Location, Encoding, f64)],
    ) -> Result<(), String> {
        for (name, patches) in self.encode_batch(values)? {
            self.files[&name].document.validate(&patches)?;
        }
        Ok(())
    }
    pub fn set_batch(
        &mut self,
        values: &[(Location, Encoding, f64)],
        metadata: Option<serde_json::Value>,
    ) -> Result<(), String> {
        let changes = self.encode_batch(values)?;
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
        let mut problems = self.blocking_problems();
        problems.extend(self.draft_problems.iter().cloned());
        problems
    }
    pub(crate) fn blocking_problems(&self) -> Vec<String> {
        let mut problems = self.data_problems();
        problems.extend(self.blocked_files.values().cloned());
        problems
    }
    pub(crate) fn data_problems(&self) -> Vec<String> {
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
    pub(crate) fn snapshot(&self, name: &str) -> Result<&[u8], String> {
        self.files
            .get(name)
            .map(|file| file.document.snapshot())
            .ok_or_else(|| format!("未载入 {name}"))
    }
    pub(crate) fn original_snapshot(&self, name: &str) -> Option<&[u8]> {
        self.files
            .get(name)?
            .original
            .as_ref()
            .map(|(bytes, _)| bytes.as_slice())
    }
    /// Read and validate every source before returning any prepared plaintext.
    pub fn render_all(&self) -> Result<BTreeMap<String, Vec<u8>>, String> {
        self.files
            .iter()
            .map(|(name, file)| {
                file.checked_render()
                    .map(|bytes| (name.clone(), bytes))
                    .map_err(|error| format!("{name}：{error}"))
            })
            .collect()
    }
    pub(crate) fn prepare_sealed(
        &self,
        allowed_floats: &[Location],
    ) -> Result<BTreeMap<String, crate::export::Prepared>, String> {
        self.prepare_game_changes(
            allowed_floats,
            &BTreeMap::new(),
            &BTreeMap::new(),
            &BTreeMap::new(),
        )
    }
    pub(crate) fn prepare_game_changes(
        &self,
        allowed_floats: &[Location],
        codes: &BTreeMap<u32, u32>,
        rebuilt_files: &BTreeMap<String, Vec<u8>>,
        words: &BTreeMap<Location, u32>,
    ) -> Result<BTreeMap<String, crate::export::Prepared>, String> {
        let mut offsets = BTreeMap::<&str, Vec<usize>>::new();
        for location in allowed_floats {
            let file = self
                .files
                .get(&location.file)
                .ok_or("找不到允许微调的数值文件")?;
            if file.sealed_source.is_none() || file.document.pending_count() == 0 {
                return Err("只允许微调已修改的密封数据文件".into());
            }
            let offset = file
                .index
                .offset(location, 4)?
                .ok_or("找不到允许微调的数值记录")?;
            let positions = offsets.entry(&location.file).or_default();
            if !positions.contains(&offset) {
                positions.push(offset);
            }
        }
        let mut files = BTreeMap::new();
        for (name, file) in &self.files {
            let planned = words.iter().filter(|(location, _)| location.file == *name);
            let has_words = planned.clone().next().is_some();
            let rebuild_codes = name == crate::stratagem_code::FILE && !codes.is_empty();
            let rebuilt = rebuilt_files.get(name);
            if file.document.pending_count() == 0
                && !rebuild_codes
                && rebuilt.is_none()
                && !has_words
            {
                continue;
            }
            if file.sealed_source.is_none() {
                if matches!(
                    file.index.rows.keys().next(),
                    Some((_, Record::Resource { .. }))
                ) {
                    continue;
                }
                return Err(format!("{name} 需要独立明文或资源事务"));
            }
            let mut edited = file
                .checked_render()
                .map_err(|error| format!("{name}：{error}"))?;
            for (location, value) in planned {
                let at = file
                    .index
                    .offset(location, 4)?
                    .ok_or("无法定位派生战备参数")?;
                edited[at..at + 4].copy_from_slice(&value.to_le_bytes());
            }
            if &edited == file.document.snapshot() && rebuilt.is_none() && !rebuild_codes {
                continue;
            }
            let options = crate::correction::Options {
                float_offsets: offsets.get(name.as_str()).map(Vec::as_slice).unwrap_or(&[]),
                ..Default::default()
            };
            for location in allowed_floats
                .iter()
                .filter(|loc| loc.file == *name && loc.typ == 0xBD4042C2 && loc.relative == 32)
            {
                let at = file.index.offset(location, 4)?.ok_or("初速校验字段缺失")?;
                if edited[at..at + 4] == file.document.snapshot()[at..at + 4] {
                    let value = f32::from_le_bytes(edited[at..at + 4].try_into().unwrap());
                    if !value.is_finite() || value <= 0.0 {
                        return Err("初速校验字段不适用".into());
                    }
                    let next = f32::from_bits(value.to_bits() + 1);
                    if !next.is_finite() {
                        return Err("初速校验字段超出范围".into());
                    }
                    edited[at..at + 4].copy_from_slice(&next.to_le_bytes());
                }
            }
            let prepared = if let Some(rebuilt) = rebuilt {
                if !options.float_offsets.is_empty() {
                    return Err("重建后的文件不能沿用原浮点字段位置".into());
                }
                if rebuilt == file.document.snapshot() {
                    continue;
                }
                crate::export::prepare_rebuilt(file.document.snapshot(), rebuilt, &options, |_| {})
            } else if rebuild_codes {
                if !options.float_offsets.is_empty() {
                    return Err("战备指令重建不能同时微调此文件的浮点字段".into());
                }
                let book = crate::stratagem_code::Codebook::parse(&edited)?;
                let rebuilt = book.rebuild(&edited, codes)?;
                crate::export::prepare_rebuilt(file.document.snapshot(), &rebuilt, &options, |_| {})
            } else {
                crate::export::prepare(file.document.snapshot(), &edited, &options, |_| {})
            }
            .map_err(|error| format!("{name}：{error}"))?;
            files.insert(name.clone(), prepared);
        }
        Ok(files)
    }
    pub fn rendered(&self, name: &str) -> Result<Vec<u8>, String> {
        let file = self.files.get(name).ok_or("工作区没有该数据文件")?;
        file.document.render(file.document.snapshot())
    }
    pub(crate) fn rebase_passive_changes(
        &self,
        name: &str,
        mut base: Vec<u8>,
    ) -> Result<Vec<u8>, String> {
        let file = self.files.get(name).ok_or("缺少护甲被动数据")?;
        let pending = file.document.checkpoint();
        if pending.is_empty() {
            return Ok(base);
        }
        let clean = Index::build(&base)?;
        let mut applied = 0;
        for ((typ, record), ranges) in &file.index.rows {
            if *typ != crate::passive::TYPE || ranges.len() != 1 {
                continue;
            }
            let range = &ranges[0];
            for (&at, &value) in pending.range(range.clone()) {
                let key = (*typ, record.clone());
                let target = clean
                    .rows
                    .get(&key)
                    .filter(|rows| rows.len() == 1)
                    .map(|rows| &rows[0])
                    .ok_or("草稿引用了组合生成的护甲被动")?;
                if target.len() != range.len() {
                    return Err("护甲被动结构变化，无法保留组合内的直接数值修改".into());
                }
                base[target.start + at - range.start] = value;
                applied += 1;
            }
        }
        if applied != pending.len() {
            return Err("无法定位所有待写入的护甲被动字段".into());
        }
        Ok(base)
    }
    pub(crate) fn changed_resources(&self) -> Vec<&str> {
        self.files
            .iter()
            .filter_map(|(name, file)| {
                (file.document.pending_count() != 0
                    && matches!(
                        file.index.rows.keys().next(),
                        Some((_, Record::Resource { .. }))
                    ))
                .then_some(name.as_str())
            })
            .collect()
    }
    pub(crate) fn checked_cipher(&self, name: &str) -> Result<Vec<u8>, String> {
        let file = self.files.get(name).ok_or("工作区没有该数据文件")?;
        if file.sealed_source.is_none() {
            return Err("数据源不是密封游戏文件".into());
        }
        file.disk_bytes()
    }
    pub(crate) fn codebook(&self, original: bool) -> Option<&crate::stratagem_code::Codebook> {
        let file = self.files.get(crate::stratagem_code::FILE)?;
        if original {
            file.original_codebook.as_ref()
        } else {
            file.codebook.as_ref()
        }
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
    fn draft_dir(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("shodan-workspace-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }
    fn draft_with(source: &str, name: &str) -> (PathBuf, Vec<u8>, BTreeMap<usize, u8>) {
        let path = draft_dir(name).join("draft.json");
        let mut edited = Workspace::default();
        edited
            .add(
                "a".into(),
                File::new("a".into(), bytes(1, 50), None).unwrap(),
            )
            .unwrap();
        edited
            .set_batch(&[(loc("a", 1), Encoding::U32, 100.0)], None)
            .unwrap();
        let pending = edited.checkpoint().files["a"].clone();
        assert!(!pending.is_empty());
        let encoded = serde_json::to_vec(&Draft {
            version: 1,
            metadata: serde_json::Value::Null,
            files: BTreeMap::from([(
                "a".to_string(),
                DraftFile {
                    source: source.into(),
                    bytes: pending.clone(),
                },
            )]),
        })
        .unwrap();
        fs::write(&path, &encoded).unwrap();
        (path, encoded, pending)
    }
    fn reopen_with_draft(path: &std::path::Path) -> Workspace {
        let mut w = Workspace::default();
        w.add(
            "a".into(),
            File::new("a".into(), bytes(1, 50), None).unwrap(),
        )
        .unwrap();
        w.configure_draft(path.to_path_buf())
            .expect("草稿冲突不能中断启动");
        w
    }
    #[test]
    fn conflicting_draft_is_kept_aside_instead_of_blocking_startup() {
        let (path, encoded, _) = draft_with("stale-source", "draft-conflict");
        let w = reopen_with_draft(&path);
        assert_eq!(w.pending_count(), 0);
        assert_eq!(w.value(&loc("a", 1), &Encoding::U32).unwrap().current, 50.0);
        assert!(w.suspended_draft.is_empty());
        assert!(w.blocking_problems().is_empty());
        assert!(w
            .problems()
            .iter()
            .any(|problem| problem.contains("已由其他工具或游戏更新改变")));
        let recovery = path.with_file_name(format!(
            "draft-recovery-{}.json",
            crate::hash::sha256_hex(&encoded)
        ));
        assert_eq!(
            fs::read(&recovery).unwrap(),
            encoded,
            "恢复副本必须逐字节一致"
        );
        let active: Draft = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert!(active.files.is_empty());
        let mut reopened = reopen_with_draft(&path);
        assert!(reopened.problems().is_empty());
        reopened
            .set_batch(&[(loc("a", 1), Encoding::U32, 125.0)], None)
            .unwrap();
        let edited = reopen_with_draft(&path);
        assert_eq!(
            edited.value(&loc("a", 1), &Encoding::U32).unwrap().current,
            125.0
        );
        assert_eq!(fs::read(&recovery).unwrap(), encoded);
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }
    #[test]
    fn matching_draft_still_restores_pending_values() {
        let mut reference = Workspace::default();
        reference
            .add(
                "a".into(),
                File::new("a".into(), bytes(1, 50), None).unwrap(),
            )
            .unwrap();
        let fingerprint = reference.fingerprint("a");
        let (path, _, pending) = draft_with(&fingerprint, "draft-match");
        let w = reopen_with_draft(&path);
        assert_eq!(w.pending_count(), pending.len());
        assert_eq!(
            w.value(&loc("a", 1), &Encoding::U32).unwrap().current,
            100.0
        );
        assert!(w.problems().is_empty());
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn invalid_draft_locations_are_archived_once_and_do_not_block_fresh_edits() {
        for missing in [false, true] {
            let (path, _, _) = draft_with(
                "temporary",
                if missing {
                    "draft-missing"
                } else {
                    "draft-range"
                },
            );
            let mut reference = Workspace::default();
            reference
                .add(
                    "a".into(),
                    File::new("a".into(), bytes(1, 50), None).unwrap(),
                )
                .unwrap();
            let draft = Draft {
                version: 1,
                metadata: serde_json::Value::Null,
                files: BTreeMap::from([(
                    if missing { "absent".into() } else { "a".into() },
                    DraftFile {
                        source: reference.fingerprint("a"),
                        bytes: BTreeMap::from([(usize::MAX, 1)]),
                    },
                )]),
            };
            let encoded = serde_json::to_vec(&draft).unwrap();
            fs::write(&path, &encoded).unwrap();
            let w = reopen_with_draft(&path);
            assert!(w.blocking_problems().is_empty());
            assert!(!w.problems().is_empty());
            assert_eq!(w.pending_count(), 0);
            assert!(reopen_with_draft(&path).problems().is_empty());
            let recovery = path.with_file_name(format!(
                "draft-recovery-{}.json",
                crate::hash::sha256_hex(&encoded)
            ));
            assert_eq!(fs::read(recovery).unwrap(), encoded);
            let _ = fs::remove_dir_all(path.parent().unwrap());
        }
    }

    #[test]
    fn failed_draft_archival_preserves_source_and_allows_read_only_startup() {
        let (path, encoded, _) = draft_with("stale-source", "draft-recovery-conflict");
        let recovery = path.with_file_name(format!(
            "draft-recovery-{}.json",
            crate::hash::sha256_hex(&encoded)
        ));
        fs::write(&recovery, b"other contents").unwrap();
        let mut w = reopen_with_draft(&path);
        assert_eq!(w.pending_count(), 0);
        assert!(w.problems().iter().any(|p| p.contains("恢复副本尚未保存")));
        assert_eq!(fs::read(&path).unwrap(), encoded);
        assert!(w
            .set_batch(&[(loc("a", 1), Encoding::U32, 125.0)], None)
            .is_err());
        assert_eq!(w.pending_count(), 0);
        assert_eq!(fs::read(&path).unwrap(), encoded);
        assert_eq!(fs::read(&recovery).unwrap(), b"other contents");
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }
}
