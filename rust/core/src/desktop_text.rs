//! String archive records and editable names, model designations and descriptions.
use crate::{
    catalog::{Catalog, Owner},
    game_workspace::Game,
    residency_install::{Edits, CARRIER},
    workspace::Workspace,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;

pub(crate) const STRINGS: u64 = 0x0d972bab10b40fd3;
const ENGLISH: u32 = 0x03f97b57;
const CHINESE: u32 = 1497550071;
pub(crate) const STATE: &str = "text";

#[derive(Deserialize, Serialize)]
pub(crate) struct Binding {
    id: u32,
    upper: bool,
}
#[derive(Deserialize, Serialize)]
pub(crate) struct Bindings {
    lines: bool,
    #[serde(default)]
    name: Vec<Binding>,
    #[serde(default)]
    code: Vec<Binding>,
    #[serde(default)]
    desc: Vec<Binding>,
}
impl Bindings {
    fn field(&self, name: &str) -> &[Binding] {
        match name {
            "name" => &self.name,
            "code" => &self.code,
            "desc" => &self.desc,
            _ => &[],
        }
    }
}

fn u32at(data: &[u8], at: usize) -> Result<u32, String> {
    Ok(u32::from_le_bytes(
        data.get(at..at + 4)
            .ok_or("文字资源头截断")?
            .try_into()
            .unwrap(),
    ))
}
struct Strings<'a> {
    data: &'a [u8],
    rows: Vec<(u32, &'a str)>,
}
impl<'a> Strings<'a> {
    fn parse(data: &'a [u8]) -> Result<Self, String> {
        let count = u32at(data, 8)? as usize;
        if count > 1_000_000 || 16 + count * 8 > data.len() {
            return Err("文字资源索引越界".into());
        }
        let mut rows = Vec::with_capacity(count);
        for i in 0..count {
            let id = u32at(data, 16 + i * 4)?;
            let at = u32at(data, 16 + count * 4 + i * 4)? as usize;
            if at < 16 + count * 8 {
                return Err("文字资源偏移越界".into());
            }
            let remaining = data.get(at..).ok_or("文字资源偏移越界")?;
            let end = remaining
                .iter()
                .position(|&c| c == 0)
                .ok_or("文字资源未结束")?;
            let s = std::str::from_utf8(&remaining[..end]).map_err(|_| "文字资源编码无效")?;
            rows.push((id, s));
        }
        Ok(Self { data, rows })
    }
    fn rewrite(&self, edits: &BTreeMap<u32, String>) -> Result<Option<Vec<u8>>, String> {
        if !self.rows.iter().any(|(id, _)| edits.contains_key(id)) {
            return Ok(None);
        }
        let count = self.rows.len();
        let mut out = self.data[..16 + count * 4].to_vec();
        out.resize(16 + count * 8, 0);
        for (i, (id, old)) in self.rows.iter().enumerate() {
            let text = edits.get(id).map_or(*old, String::as_str);
            let at = u32::try_from(out.len()).map_err(|_| "文字资源大小溢出")?;
            let slot = 16 + count * 4 + i * 4;
            out[slot..slot + 4].copy_from_slice(&at.to_le_bytes());
            out.extend_from_slice(text.as_bytes());
            out.push(0);
        }
        Ok(Some(out))
    }
}

pub(crate) fn load_originals(game: &Game) -> Result<BTreeMap<u32, String>, String> {
    let mut cache = game.resources()?;
    let b = &mut cache.as_mut().unwrap().bundles;
    let mut english = BTreeMap::new();
    let mut chinese = BTreeMap::new();
    for (id, size) in b.entries(CARRIER, STRINGS)? {
        if size < 16 {
            continue;
        }
        let bytes = b.resource(CARRIER, (STRINGS, id))?;
        let language = u32at(&bytes, 12)?;
        let target = match language {
            ENGLISH => &mut english,
            CHINESE => &mut chinese,
            _ => continue,
        };
        for (id, text) in Strings::parse(&bytes)?.rows {
            target.insert(id, text.replace("\r\n", "|").replace('\n', "|"));
        }
    }
    english.extend(chinese);
    Ok(english)
}

pub(crate) fn validate(field: &str, text: &str) -> Result<(), String> {
    let limit = match field {
        "name" => 60,
        "code" => 20,
        "desc" => 400,
        _ => return Err("无效的文字字段".into()),
    };
    if text.len() > limit || text.chars().any(|c| c.is_control() || c == '#') {
        return Err(format!("文字不能包含控制字符或 #，且最多 {limit} 字节"));
    }
    Ok(())
}

pub(crate) fn edit(
    workspace: &mut Workspace,
    owner: &Owner,
    originals: &BTreeMap<u32, String>,
    field: &str,
    value: Option<&str>,
) -> Result<Value, String> {
    validate(field, value.unwrap_or_default())?;
    let Some(bindings) = &owner.text else {
        return Ok(json!({"available":false}));
    };
    let ids = bindings.field(field);
    let Some(first) = ids.first().and_then(|b| originals.get(&b.id)) else {
        return Ok(json!({"available":false}));
    };
    let original = if field == "desc" && bindings.lines {
        ids.iter()
            .filter_map(|b| originals.get(&b.id))
            .map(String::as_str)
            .collect::<Vec<_>>()
            .join("||")
    } else {
        first.clone()
    };
    if let Some(value) = value {
        let mut meta = workspace.metadata().clone();
        if !meta.is_object() {
            meta = json!({});
        }
        if value.is_empty() || value == original {
            if let Some(texts) = meta[STATE][&owner.id].as_object_mut() {
                texts.remove(field);
            }
        } else {
            meta[STATE][&owner.id][field] = json!(value);
        }
        workspace.set_batch(&[], Some(meta))?;
    }
    Ok(
        json!({"available":true,"value":workspace.metadata()[STATE][&owner.id][field].as_str().unwrap_or(&original),
        "original":original}),
    )
}

pub(crate) fn prepare(
    game: &Game,
    catalog: &Catalog,
    current: &Value,
    loaded: &Value,
) -> Result<Edits, String> {
    if current == loaded {
        return Ok(Edits::new());
    }
    let mut entries = BTreeMap::new();
    if let Some(owners) = current.as_object() {
        for (owner, fields) in owners {
            let owner = catalog.owner(owner)?.1;
            let bindings = owner
                .text
                .as_ref()
                .ok_or("预设文字字段无法在当前版本定位")?;
            for (field, value) in fields.as_object().ok_or("预设文字格式无效")? {
                let value = value.as_str().ok_or("预设文字不是有效字符串")?;
                validate(field, value)?;
                let ids = bindings.field(field);
                if ids.is_empty() {
                    return Err("预设文字字段无法在当前版本定位".into());
                }
                let value = value.replace('|', "\n");
                if field == "desc" && bindings.lines {
                    for (i, part) in value.splitn(ids.len(), "\n\n").enumerate() {
                        entries.insert(ids[i].id, part.to_owned());
                    }
                } else {
                    for binding in ids {
                        let text = if binding.upper {
                            value.to_ascii_uppercase()
                        } else {
                            value.clone()
                        };
                        if entries
                            .insert(binding.id, text.clone())
                            .is_some_and(|old| old != text)
                        {
                            return Err(format!(
                                "多个条目为同一文字 ID {} 提供了不同内容",
                                binding.id
                            ));
                        }
                    }
                }
            }
        }
    }
    let held = game.overrides(CARRIER)?;
    let mut edits = BTreeMap::new();
    let mut cache = game.resources()?;
    let bundles = &mut cache.as_mut().unwrap().bundles;
    for (id, size) in bundles.entries(CARRIER, STRINGS)? {
        if size < 16 {
            continue;
        }
        let key = (STRINGS, id);
        let original = bundles.resource(CARRIER, key)?;
        let strings = Strings::parse(&original)?;
        if let Some(replacement) = strings.rewrite(&entries)? {
            if held.get(&key) != Some(&replacement) {
                edits.insert(key, Some(replacement));
            }
        } else if held.contains_key(&key) {
            edits.insert(key, None);
        }
    }
    if edits.is_empty() {
        Ok(Edits::new())
    } else {
        Ok(BTreeMap::from([(CARRIER.into(), edits)]))
    }
}
