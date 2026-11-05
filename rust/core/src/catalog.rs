//! Declarative, compressed parameter catalog. Runtime logic is Rust; catalog
//! data contains no Lua functions, process addresses or physical default values.
use crate::{
    binary::Encoding,
    workspace::{Location, Workspace},
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    io::Read,
};

#[derive(Deserialize)]
struct Source {
    format: String,
    version: u32,
    owners: Vec<Owner>,
    fields: Vec<Field>,
    #[serde(default)]
    registries: BTreeMap<String, Vec<Choice>>,
    #[serde(default)]
    resource_sources: BTreeMap<String, ResourceSource>,
}
#[derive(Deserialize, Serialize, Clone)]
pub struct Choice {
    pub id: u64,
    #[serde(default)]
    pub raw: String,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub note: String,
}
#[derive(Deserialize, Clone)]
pub struct ResourceSource {
    pub bytes: usize,
    pub sha256: String,
}
#[derive(Deserialize, Serialize)]
pub struct Owner {
    pub id: String,
    pub name: String,
    pub english: String,
    pub tab: String,
    #[serde(default)]
    pub note: String,
    #[serde(default)]
    pub groups: Value,
    pub rows: Vec<Row>,
}
#[derive(Deserialize, Serialize)]
pub struct Part {
    pub field: usize,
    pub id: String,
}
#[derive(Deserialize, Serialize)]
#[serde(tag = "op", rename_all = "lowercase")]
pub enum Expression {
    Field {
        field: usize,
    },
    Subtract {
        left: Box<Expression>,
        right: Box<Expression>,
    },
}
#[derive(Deserialize, Serialize)]
pub struct Row {
    pub key: String,
    pub id: String,
    pub label: String,
    pub section: String,
    pub storage: String,
    pub parts: Vec<Part>,
    #[serde(default)]
    pub help: Vec<String>,
    #[serde(default)]
    pub note: String,
    #[serde(default)]
    pub choice: Value,
    #[serde(default)]
    pub lead: bool,
    #[serde(default)]
    pub show_first: bool,
    #[serde(default)]
    pub mult: bool,
    #[serde(default)]
    pub inverse: bool,
    #[serde(default)]
    pub never: bool,
    pub scale: Option<f64>,
    pub zero: Option<f64>,
    pub rate_plus: Option<f64>,
    pub span: Option<Expression>,
    pub drain: Option<String>,
    #[serde(default)]
    pub suppression: bool,
    #[serde(default)]
    pub code: bool,
    pub unresolved: Option<String>,
}
#[derive(Deserialize)]
pub struct ResourceBinding {
    pub identity: String,
    pub relative: usize,
}
#[derive(Deserialize)]
pub struct Field {
    pub key: String,
    pub storage: String,
    pub bindings: Vec<Value>,
    pub encoding: Option<Value>,
    pub resource: Option<ResourceBinding>,
    pub virtual_default: Option<f64>,
    #[serde(default)]
    pub allowed: Vec<u64>,
    pub unset: Option<f64>,
    pub auto_drop: Option<usize>,
    pub death: Option<usize>,
    pub unresolved: Option<String>,
}
pub struct Binding {
    pub locations: Vec<Location>,
    pub encoding: Encoding,
}
pub struct Catalog {
    pub owners: Vec<Owner>,
    pub fields: Vec<Field>,
    pub bindings: Vec<Option<Binding>>,
    pub registries: BTreeMap<String, Vec<Choice>>,
    pub resources: BTreeMap<String, ResourceSource>,
    by_owner: BTreeMap<String, usize>,
    pub users: Vec<BTreeSet<usize>>,
}
#[derive(Clone, Copy)]
pub enum Mode {
    Current,
    Loaded,
    Original,
}
impl Catalog {
    pub fn from_gzip(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() > 16 * 1024 * 1024 {
            return Err("参数目录压缩文件过大".into());
        }
        let mut decoder = flate2::read::GzDecoder::new(bytes);
        let mut raw = Vec::new();
        decoder
            .by_ref()
            .take(64 * 1024 * 1024 + 1)
            .read_to_end(&mut raw)
            .map_err(|_| "参数目录压缩数据无效")?;
        if raw.len() > 64 * 1024 * 1024 {
            return Err("参数目录解压后过大".into());
        }
        let data: Source =
            serde_json::from_slice(&raw).map_err(|e| format!("参数目录格式无效：{e}"))?;
        if data.format != "SHODAN-NATIVE-DESCRIPTORS" || data.version != 1 {
            return Err("参数目录版本不支持".into());
        }
        if data.owners.len() > 10000 || data.fields.len() > 200000 {
            return Err("参数目录数量过大".into());
        }
        let mut by_owner = BTreeMap::new();
        let mut users = vec![BTreeSet::new(); data.fields.len()];
        for (index, owner) in data.owners.iter().enumerate() {
            if owner.id.len() != 16
                || !owner.id.bytes().all(|b| b.is_ascii_hexdigit())
                || by_owner
                    .insert(owner.id.to_ascii_uppercase(), index)
                    .is_some()
            {
                return Err("参数目录装备身份无效或重复".into());
            }
            let mut row_ids = BTreeSet::new();
            for row in &owner.rows {
                if !row_ids.insert(&row.key) {
                    return Err("同一装备参数标识重复".into());
                }
                for part in &row.parts {
                    users
                        .get_mut(part.field)
                        .ok_or("参数引用索引越界")?
                        .insert(index);
                }
                if let Some(span) = &row.span {
                    validate_expression(span, data.fields.len(), 0)?;
                }
            }
        }
        let mut bindings = Vec::with_capacity(data.fields.len());
        for field in &data.fields {
            for index in [field.auto_drop, field.death].into_iter().flatten() {
                if index >= data.fields.len() {
                    return Err("联动参数索引越界".into());
                }
            }
            if let Some(v) = field.virtual_default {
                if !v.is_finite() {
                    return Err("虚拟参数默认值无效".into());
                }
            }
            if field.storage == "virtual" {
                bindings.push(None);
                continue;
            }
            let mut codec = field.encoding.clone();
            let mut locations = field
                .bindings
                .iter()
                .map(crate::workspace_api::location)
                .collect::<Result<Vec<_>, _>>()?;
            if let Some(resource) = &field.resource {
                let (id, typ) = resource
                    .identity
                    .split_once('.')
                    .ok_or("资源参数身份无效")?;
                locations.push(crate::workspace_api::location(&json!({"file":resource.identity,"type":"5F7203C8","record":format!("resource:{typ}:{id}"),"relative":resource.relative}))?);
                codec = Some(json!(field.storage));
            }
            let Some(mut codec) = codec else {
                bindings.push(None);
                continue;
            };
            if let Some(registry) = codec["registry"].as_str() {
                let entries = data
                    .registries
                    .get(registry)
                    .ok_or("资源参数目录缺少选择列表")?;
                codec = json!({"kind":"reference","entries":entries.iter().filter(|c|c.raw.len()==16 && c.raw.bytes().all(|b|b.is_ascii_hexdigit())).map(|c|(c.id.to_string(),json!(c.raw))).collect::<serde_json::Map<_,_>>()});
            }
            if locations.is_empty() {
                bindings.push(None);
                continue;
            }
            bindings.push(Some(Binding {
                locations,
                encoding: crate::workspace_api::encoding(&codec)?,
            }));
        }
        Ok(Self {
            owners: data.owners,
            fields: data.fields,
            registries: data.registries,
            resources: data.resource_sources,
            by_owner,
            bindings,
            users,
        })
    }
    pub fn owner(&self, id: &str) -> Result<(usize, &Owner), String> {
        let i = *self
            .by_owner
            .get(&id.to_ascii_uppercase())
            .ok_or("找不到装备条目")?;
        Ok((i, &self.owners[i]))
    }
    pub fn field_value(
        &self,
        index: usize,
        workspace: &Workspace,
        mode: Mode,
    ) -> Result<Option<f64>, String> {
        let field = self.fields.get(index).ok_or("参数索引越界")?;
        if field.storage == "virtual" {
            return Ok(if matches!(mode, Mode::Current) {
                workspace.metadata()["virtual"][&field.key]
                    .as_f64()
                    .or(field.virtual_default)
            } else {
                field.virtual_default
            });
        }
        let binding = self.bindings[index]
            .as_ref()
            .ok_or("该参数的原生绑定尚未完成")?;
        let mut result = None;
        for location in &binding.locations {
            let value = workspace.value(location, &binding.encoding)?;
            let value = match mode {
                Mode::Current => Some(value.current),
                Mode::Loaded => Some(value.loaded),
                Mode::Original => value.original,
            };
            let Some(mut value) = value else {
                return Ok(None);
            };
            if value == f32::MAX as f64 {
                if let Some(unset) = field.unset {
                    value = unset;
                }
            }
            if result.is_some_and(|previous| previous != value) {
                return Err("共享参数的多个记录当前不一致".into());
            }
            result = Some(value);
        }
        Ok(result)
    }
    fn expression(&self, e: &Expression, w: &Workspace, m: Mode) -> Result<Option<f64>, String> {
        match e {
            Expression::Field { field } => self.field_value(*field, w, m),
            Expression::Subtract { left, right } => Ok(self
                .expression(left, w, m)?
                .zip(self.expression(right, w, m)?)
                .map(|(a, b)| a - b)),
        }
    }
    pub fn row_value(
        &self,
        owner: &Owner,
        row: &Row,
        w: &Workspace,
        m: Mode,
    ) -> Result<Option<f64>, String> {
        if let Some(why) = &row.unresolved {
            return Err(format!("参数规则尚未完成迁移：{why}"));
        }
        let Some(first) = row.parts.first() else {
            return Ok(None);
        };
        let first_value = self.field_value(first.field, w, m)?;
        if row.choice == "holster" {
            return Ok(first_value.map(|v| if v == 0xCCF501C7u32 as f64 { 1.0 } else { 0.0 }));
        }
        if row.choice == "pod_twin" {
            let node =
                self.field_value(row.parts.get(2).ok_or("双侧投放节点字段缺失")?.field, w, m)?;
            let count =
                self.field_value(row.parts.get(16).ok_or("双侧投放数量字段缺失")?.field, w, m)?;
            return Ok(node.zip(count).map(|(n, c)| {
                if n == 0x7FE13CFFu32 as f64 && c >= 2.0 {
                    2.0
                } else {
                    1.0
                }
            }));
        }
        let mut scale = row.scale.unwrap_or(1.0);
        if let Some(drain) = &row.drain {
            let r = owner
                .rows
                .iter()
                .find(|r| r.id == *drain)
                .ok_or("流失速率参数不存在")?;
            if let Some(rate) =
                self.field_value(r.parts.first().ok_or("流失速率没有字段")?.field, w, m)?
            {
                if rate > 0.0 {
                    scale = 1.0 / rate;
                }
            }
        }
        if row.show_first {
            return Ok(first_value);
        }
        if row.choice != Value::Null && row.choice != Value::Bool(false) || row.lead {
            return Ok(first_value.map(|v| v * scale));
        }
        if let Some(span) = &row.span {
            if row.never && first_value == Some(0.0) {
                return Ok(Some(0.0));
            }
            return Ok(self
                .expression(span, w, m)?
                .zip(first_value)
                .and_then(|(s, r)| {
                    let rate = r + row.rate_plus.unwrap_or(0.0);
                    (rate > 0.0).then_some(s / rate)
                }));
        }
        let mut sum = 0.0;
        for part in &row.parts {
            let Some(v) = self.field_value(part.field, w, m)? else {
                return Ok(None);
            };
            sum += v;
        }
        if sum == 0.0 && row.zero.is_some() {
            return Ok(row.zero);
        }
        let value = sum / row.parts.len() as f64 * scale;
        if !value.is_finite() {
            return Err("组合参数计算结果超出有限数值范围".into());
        }
        Ok(Some(value + 0.0))
    }
    pub fn info(&self) -> Value {
        json!({"runtime":"rust-native","owners":self.owners.len(),"rows":self.owners.iter().map(|o|o.rows.len()).sum::<usize>(),"fields":self.fields.len(),"bound_fields":self.bindings.iter().filter(|b|b.is_some()).count(),"virtual_fields":self.fields.iter().filter(|f|f.storage=="virtual").count(),"physical_defaults_embedded":false})
    }
    pub fn items(&self, tab: Option<&str>, query: &str) -> Value {
        let q = query.trim().to_lowercase();
        json!(self.owners.iter().filter(|o|tab.is_none_or(|tab|tab==o.tab) && (q.is_empty() || o.name.to_lowercase().contains(&q) || o.english.to_lowercase().contains(&q) || o.id.to_ascii_lowercase().contains(&q))).map(|o|json!({"id":o.id,"name":o.name,"english":o.english,"tab":o.tab,"note":o.note,"groups":o.groups})).collect::<Vec<_>>())
    }
    pub fn read_rows(&self, id: &str, w: &Workspace) -> Result<Value, String> {
        let (_, owner) = self.owner(id)?;
        Ok(json!(owner.rows.iter().map(|r|{
            let current=self.row_value(owner,r,w,Mode::Current);let original=self.row_value(owner,r,w,Mode::Original);let loaded=self.row_value(owner,r,w,Mode::Loaded);
            json!({"id":r.key,"parameter":r.id,"label":r.label,"section":r.section,"help":r.help,"note":r.note,"choice":r.choice,"storage":r.storage,
                "value":current.as_ref().ok().copied().flatten(),"original":original.as_ref().ok().copied().flatten(),"loaded":loaded.as_ref().ok().copied().flatten(),"error":current.err(),"original_error":original.err()})
        }).collect::<Vec<_>>()))
    }
    pub fn read_fields(&self, indices: &Value, w: &Workspace) -> Result<Value, String> {
        let indices = indices.as_array().ok_or("缺少参数索引清单")?;
        if indices.len() > 150000 {
            return Err("参数索引清单过大".into());
        }
        let mut out = Vec::with_capacity(indices.len());
        for index in indices {
            let index = usize::try_from(index.as_u64().ok_or("参数索引无效")?)
                .map_err(|_| "参数索引越界")?;
            let value = self.field_value(index, w, Mode::Current);
            let original = self.field_value(index, w, Mode::Original);
            let loaded = self.field_value(index, w, Mode::Loaded);
            out.push(json!({"index":index,"value":value.as_ref().ok().copied().flatten(),"original":original.as_ref().ok().copied().flatten(),"loaded":loaded.as_ref().ok().copied().flatten(),"error":value.err(),"original_error":original.err()}));
        }
        Ok(json!(out))
    }
    pub fn row_values(&self, ids: &Value, w: &Workspace) -> Result<Value, String> {
        let ids = ids.as_array().ok_or("缺少装备身份清单")?;
        if ids.len() > 10000 {
            return Err("装备清单过大".into());
        }
        let mut out = Vec::new();
        for id in ids {
            let (_, owner) = self.owner(id.as_str().ok_or("装备身份无效")?)?;
            let rows = owner
                .rows
                .iter()
                .map(|row| {
                    let value = self.row_value(owner, row, w, Mode::Current);
                    json!({"value":value.as_ref().ok().copied().flatten(),"error":value.err()})
                })
                .collect::<Vec<_>>();
            out.push(json!({"owner":owner.id,"rows":rows}));
        }
        Ok(json!(out))
    }
    pub fn open_resources(&self, w: &mut Workspace, inputs: &Value) -> Result<usize, String> {
        let files = inputs.as_array().ok_or("缺少独立资源清单")?;
        if files.len() > 256 {
            return Err("独立资源数量过多".into());
        }
        // Prepare and authenticate the complete batch before adding any file.
        let mut prepared = Vec::new();
        let mut names = BTreeSet::new();
        let mut paths = BTreeSet::new();
        let mut total = 0;
        for input in files {
            let name = input["identity"]
                .as_str()
                .ok_or("缺少独立资源身份")?
                .to_ascii_uppercase();
            if !names.insert(name.clone()) || w.contains(&name) {
                return Err("独立资源重复".into());
            }
            let expected = self.resources.get(&name).ok_or("参数目录没有该独立资源")?;
            let path = std::fs::canonicalize(input["path"].as_str().ok_or("缺少独立资源路径")?)
                .map_err(|_| "独立资源路径无法解析")?;
            let current = crate::workspace_api::bounded_read(&path, &mut total)?;
            if current.len() != expected.bytes {
                return Err("独立资源布局大小与参数目录不匹配".into());
            }
            if w.has_path(&path) || !paths.insert(path.to_string_lossy().to_ascii_lowercase()) {
                return Err("独立资源的源文件路径重复".into());
            }
            let baseline = if let Some(p) = input["baseline_path"].as_str() {
                let bytes =
                    crate::workspace_api::bounded_read(std::path::Path::new(p), &mut total)?;
                if bytes.len() != expected.bytes
                    || crate::hash::sha256_hex(&bytes) != expected.sha256
                {
                    return Err("独立资源原值指纹不匹配".into());
                }
                Some(bytes)
            } else {
                None
            };
            let (id, typ) = name.split_once('.').ok_or("独立资源身份无效")?;
            let record = crate::workspace::Record::Resource {
                typ: u64::from_str_radix(typ, 16).map_err(|_| "独立资源类型无效")?,
                id: u64::from_str_radix(id, 16).map_err(|_| "独立资源名称无效")?,
            };
            prepared.push((
                name,
                crate::workspace::File::resource(path, current, record, baseline)?,
            ));
        }
        if w.history() != (0, 0) || w.pending_count() != 0 {
            return Err("已有修改时不能变更工作区资源集合".into());
        }
        let count = prepared.len();
        for (name, file) in prepared {
            w.add(name, file)?;
        }
        Ok(count)
    }
}
fn validate_expression(e: &Expression, count: usize, depth: usize) -> Result<(), String> {
    if depth > 16 {
        return Err("参数表达式嵌套过深".into());
    }
    match e {
        Expression::Field { field } => {
            if *field < count {
                Ok(())
            } else {
                Err("参数表达式索引越界".into())
            }
        }
        Expression::Subtract { left, right } => {
            validate_expression(left, count, depth + 1)?;
            validate_expression(right, count, depth + 1)
        }
    }
}
