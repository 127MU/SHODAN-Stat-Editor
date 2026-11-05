//! Line-delimited JSON transport for the Rust-only editing engine.
//! No Lua fallback, installation or implicit game-directory writes.
use crate::{
    baseline::Baseline,
    session::{Field, Session},
    tables::{Key, Layout},
    Kind,
};
use serde_json::{json, Value};
use std::{
    fs,
    io::{BufRead, Write},
    path::PathBuf,
};

#[derive(Default)]
pub struct Api {
    active: Option<(Session, PathBuf)>,
    parameters: crate::parameters::Parameters,
    armor: Option<crate::armor_session::Session>,
    workspace: Option<crate::workspace::Workspace>,
    catalog: Option<crate::catalog::Catalog>,
    update_job: Option<std::thread::JoinHandle<Result<Value, String>>>,
    resolver: Option<(
        PathBuf,
        u64,
        std::time::SystemTime,
        crate::resource_resolver::Resolver,
    )>,
}
fn identity(v: &Value) -> Result<crate::dependencies::Identity, String> {
    let hex =
        |key| u64::from_str_radix(text(v, key)?, 16).map_err(|_| format!("无效资源身份：{key}"));
    Ok((hex("type")?, hex("id")?))
}
fn identities(
    v: &Value,
) -> Result<std::collections::BTreeSet<crate::dependencies::Identity>, String> {
    v.as_array()
        .ok_or("资源清单无效")?
        .iter()
        .map(identity)
        .collect()
}
fn identity_json((typ, id): crate::dependencies::Identity) -> Value {
    json!({"type":format!("{typ:016x}"),"id":format!("{id:016x}")})
}
fn number(v: &Value, key: &str) -> Result<usize, String> {
    usize::try_from(
        v[key]
            .as_u64()
            .ok_or_else(|| format!("缺少有效整数：{key}"))?,
    )
    .map_err(|_| "整数超出平台范围".into())
}
fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str, String> {
    v[key].as_str().ok_or_else(|| format!("缺少文本：{key}"))
}
fn record(v: &Value) -> Result<Key, String> {
    let record = text(v, "record")?;
    let record = if let Some(id) = record.strip_prefix("id:") {
        Key::Id(id.parse().map_err(|_| "记录 ID 无效")?)
    } else if let Some(hash) = record.strip_prefix("hash:") {
        Key::Hash(u64::from_str_radix(hash, 16).map_err(|_| "记录哈希无效")?)
    } else {
        return Err("记录必须使用 id: 或 hash: 前缀".into());
    };
    Ok(record)
}
fn field(v: &Value) -> Result<Field, String> {
    let record = record(v)?;
    let kind = match text(v, "kind")? {
        "f32" => Kind::F32,
        "u32" => Kind::U32,
        "i32" => Kind::I32,
        _ => return Err("不支持的字段类型".into()),
    };
    Ok(Field {
        block: number(v, "block")?,
        record,
        relative: number(v, "relative")?,
        kind,
    })
}
impl Api {
    pub fn invoke(&mut self, request: &Value) -> Result<Value, String> {
        let method = text(request, "method")?;
        let p = &request["params"];
        if method == "catalog-load" {
            let path = std::path::Path::new(text(p, "path")?);
            if fs::metadata(path)
                .map_err(|_| "无法读取原生参数目录")?
                .len()
                > 16 * 1024 * 1024
            {
                return Err("参数目录压缩文件过大".into());
            }
            let bytes = fs::read(path).map_err(|_| "无法读取原生参数目录")?;
            let catalog = crate::catalog::Catalog::from_gzip(&bytes)?;
            let info = catalog.info();
            self.catalog = Some(catalog);
            return Ok(info);
        }
        if method.starts_with("catalog-") {
            let catalog = self.catalog.as_ref().ok_or("请先载入原生参数目录")?;
            return match method {
                "catalog-info" => Ok(catalog.info()),
                "catalog-set" | "catalog-restore" | "catalog-edit-preview" => {
                    let workspace = self.workspace.as_mut().ok_or("请先打开原生工作区")?;
                    let value = if method == "catalog-restore" {
                        None
                    } else {
                        Some(p["value"].as_f64().ok_or("缺少有效参数数值")?)
                    };
                    let plan = crate::catalog_edit::prepare(
                        catalog,
                        workspace,
                        text(p, "owner")?,
                        text(p, "key")?,
                        value,
                    )?;
                    if method != "catalog-edit-preview" {
                        workspace.set_batch(&plan.values, Some(plan.metadata))?;
                    }
                    Ok(
                        json!({"changes":plan.changes,"applied":method!="catalog-edit-preview","installed":false}),
                    )
                }
                "catalog-items" => {
                    Ok(catalog.items(p["tab"].as_str(), p["query"].as_str().unwrap_or("")))
                }
                "catalog-describe" => Ok(json!(catalog.owner(text(p, "owner")?)?.1)),
                "catalog-read-rows" => catalog.read_rows(
                    text(p, "owner")?,
                    self.workspace.as_ref().ok_or("请先打开原生工作区")?,
                ),
                "catalog-read-fields" => catalog.read_fields(
                    &p["indices"],
                    self.workspace.as_ref().ok_or("请先打开原生工作区")?,
                ),
                "catalog-row-values" => catalog.row_values(
                    &p["owners"],
                    self.workspace.as_ref().ok_or("请先打开原生工作区")?,
                ),
                "catalog-open-resources" => Ok(json!(catalog.open_resources(
                    self.workspace.as_mut().ok_or("请先打开原生工作区")?,
                    &p["files"]
                )?)),
                _ => Err("未提供该原生目录接口".into()),
            };
        }
        if method == "armor-assign-preview" || method == "armor-assign-export-copy" {
            return crate::armor_assign::invoke(p, method == "armor-assign-export-copy");
        }
        if method == "workspace-open" {
            let workspace = crate::workspace_api::open(p)?;
            let problems = workspace.problems();
            self.workspace = Some(workspace);
            return Ok(json!({"problems":problems}));
        }
        if method == "workspace-close" {
            self.workspace = None;
            return Ok(json!(true));
        }
        if method.starts_with("workspace-") {
            return crate::workspace_api::invoke(
                self.workspace.as_mut().ok_or("请先打开原生工作区")?,
                method,
                p,
            );
        }
        if method == "update-open-link" {
            crate::update::open_link(text(p, "url")?)?;
            return Ok(json!(true));
        }
        if method == "update-parse" {
            return crate::update::parse(text(p, "json")?, text(p, "current")?);
        }
        if method == "update-start" {
            if self
                .update_job
                .as_ref()
                .is_some_and(|job| !job.is_finished())
            {
                return Ok(json!({"pending":true}));
            }
            let current = text(p, "current")?.to_string();
            self.update_job = Some(std::thread::spawn(move || crate::update::check(&current)));
            return Ok(json!({"pending":true}));
        }
        if method == "update-poll" {
            if self
                .update_job
                .as_ref()
                .is_some_and(|job| !job.is_finished())
            {
                return Ok(json!({"pending":true}));
            }
            let Some(job) = self.update_job.take() else {
                return Ok(json!({"pending":false,"idle":true}));
            };
            return job
                .join()
                .map_err(|_| "更新检查异常退出".to_string())?
                .map(|offer| json!({"pending":false,"offer":offer}));
        }
        if method == "residency-plan" {
            let root = std::path::Path::new(text(p, "root")?);
            let ledger = crate::residency::read_ledger(std::path::Path::new(text(p, "ledger")?))?;
            let plan = crate::residency::plan(root, &ledger, text(p, "host")?, text(p, "name")?)?;
            let entry = ledger.iter().find(|e| {
                e.host.eq_ignore_ascii_case(text(p, "host").unwrap_or(""))
                    && e.name.eq_ignore_ascii_case(text(p, "name").unwrap_or(""))
            });
            let state = entry
                .map(|e| crate::residency::state(root, e))
                .transpose()?;
            return Ok(
                json!({"slot":plan.index,"reuse":plan.reuse,"state":state.unwrap_or(0),"read_only":true}),
            );
        }
        if method == "dependency-closure" {
            let roots = identities(&p["roots"])?;
            let mut edges = std::collections::BTreeMap::new();
            for edge in p["edges"].as_array().ok_or("依赖边清单无效")? {
                if edges
                    .insert(
                        identity(&edge["resource"])?,
                        identities(&edge["dependencies"])?,
                    )
                    .is_some()
                {
                    return Err("依赖节点重复".into());
                }
            }
            let (all, missing) = crate::dependencies::closure(&roots, &edges, 4096)?;
            return Ok(
                json!({"resources":all.into_iter().map(identity_json).collect::<Vec<_>>(),"unknown":missing.into_iter().map(identity_json).collect::<Vec<_>>(),"read_only":true}),
            );
        }
        if method == "resource-scan" || method == "resources-resolve" {
            let root = fs::canonicalize(text(p, "root")?).map_err(|_| "资源目录不可读")?;
            let meta = fs::metadata(root.join("bundles.nxa")).map_err(|_| "资源索引不可读")?;
            let stamp = meta.modified().map_err(|_| "无法核对资源索引时间")?;
            if !self
                .resolver
                .as_ref()
                .is_some_and(|(r, len, time, _)| *r == root && *len == meta.len() && *time == stamp)
            {
                let resolver =
                    crate::resource_resolver::Resolver::new(crate::bundles::Bundles::open(&root)?);
                self.resolver = Some((root, meta.len(), stamp, resolver));
            }
            let resolver = &mut self.resolver.as_mut().unwrap().3;
            let progress = |done, total| {
                if done % 32 == 0 {
                    eprintln!(
                        "@shodan-progress {}",
                        json!({"stage":"核对资源与音效来源","done":done,"total":total})
                    );
                }
            };
            if method == "resource-scan" {
                let mut blobs = Vec::new();
                let mut total = 0usize;
                for input in p["blobs"].as_array().ok_or("缺少资源引用数据")? {
                    let hex = input.as_str().ok_or("资源引用数据格式无效")?;
                    total = total.checked_add(hex.len()).ok_or("资源引用数据过大")?;
                    if total > 32 * 1024 * 1024
                        || hex.len() % 2 != 0
                        || !hex.bytes().all(|c| c.is_ascii_hexdigit())
                    {
                        return Err("资源引用数据过大或十六进制无效".into());
                    }
                    blobs.push(
                        (0..hex.len())
                            .step_by(2)
                            .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
                            .collect(),
                    );
                }
                let found = resolver.scan(&blobs, progress)?;
                return Ok(
                    json!({"candidates":found.into_iter().map(identity_json).collect::<Vec<_>>(),"read_only":true,"note":"按完整资源哈希查找的候选引用，需要结合实际字段核对"}),
                );
            }
            let preferred = p["preferred"]
                .as_array()
                .ok_or("首选资源包清单无效")?
                .iter()
                .map(|v| {
                    v.as_str()
                        .map(|s| s.to_ascii_lowercase())
                        .ok_or("资源包名称无效")
                })
                .collect::<Result<Vec<_>, _>>()?;
            let resources = identities(&p["resources"])?;
            let events = p["events"]
                .as_array()
                .ok_or("音效事件清单无效")?
                .iter()
                .map(|v| {
                    v.as_u64()
                        .and_then(|n| u32::try_from(n).ok())
                        .filter(|n| *n != 0)
                        .ok_or("音效事件 ID 无效")
                })
                .collect::<Result<std::collections::BTreeSet<_>, _>>()?;
            let (resolved, providers, warnings) =
                resolver.resolve(&preferred, &resources, &events, progress)?;
            let mut details = Vec::new();
            for key in &resources {
                details.push(json!({"resource":identity_json(*key),"providers":resolved.packages.iter().filter(|n|providers[*n].resources.contains(key)).collect::<Vec<_>>(),"missing":resolved.missing_resources.contains(key)}));
            }
            for event in &events {
                details.push(json!({"event":event,"providers":resolved.packages.iter().filter(|n|providers[*n].events.contains(event)).collect::<Vec<_>>(),"missing":resolved.missing_events.contains(event)}));
            }
            return Ok(
                json!({"packages":resolved.packages,"details":details,"missing_resources":resolved.missing_resources.into_iter().map(identity_json).collect::<Vec<_>>(),"missing_events":resolved.missing_events,"warnings":warnings,"read_only":true,"audio_binding":"Wwise 事件目录身份匹配，不代表全部声音播放链已验证"}),
            );
        }
        if method == "bundle-inspect"
            || method == "bundle-package-inspect"
            || method == "bundle-patch-preview"
        {
            let mut bundles =
                crate::bundles::Bundles::open(std::path::Path::new(text(p, "root")?))?;
            if method == "bundle-inspect" {
                return Ok(
                    json!({"count":bundles.packages.len(),"names":bundles.packages.keys().take(100).collect::<Vec<_>>()}),
                );
            }
            if method == "bundle-patch-preview" {
                let mode = match text(p, "mode")? {
                    "light" => crate::bundles::Mode::Light,
                    "full" => crate::bundles::Mode::Full,
                    "res" => crate::bundles::Mode::Overrides,
                    _ => return Err("驻留模式无效".into()),
                };
                let mut overrides = std::collections::BTreeMap::new();
                if let Some(entries) = p.get("overrides") {
                    for entry in entries.as_array().ok_or("覆盖清单无效")? {
                        let id = u64::from_str_radix(text(entry, "id")?, 16)
                            .map_err(|_| "资源 ID 无效")?;
                        let typ = u64::from_str_radix(text(entry, "type")?, 16)
                            .map_err(|_| "资源类型无效")?;
                        let hex = text(entry, "hex")?;
                        if hex.len() % 2 != 0 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
                            return Err("资源覆盖内容不是有效十六进制".into());
                        }
                        let bytes = (0..hex.len())
                            .step_by(2)
                            .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
                            .collect();
                        if overrides.insert((typ, id), bytes).is_some() {
                            return Err("资源覆盖身份重复".into());
                        }
                    }
                }
                let built = bundles.build_patch(text(p, "name")?, mode, &overrides)?;
                let report = |bytes: &[u8]| json!({"bytes":bytes.len(),"sha256":crate::hash::sha256_hex(bytes)});
                return Ok(
                    json!({"toc":report(&built.toc),"gpu":report(&built.gpu),"stream":report(&built.stream),"installed":false}),
                );
            }
            let package = bundles.package(text(p, "name")?)?;
            return Ok(
                json!({"entries":package.entries.len(),"types":package.types.len(),"read_only":true}),
            );
        }
        if method == "package-inspect" || method == "package-rebuild-copy" {
            let input = fs::read(text(p, "path")?).map_err(|_| "无法读取资源包")?;
            let package = crate::resource_package::Package::parse(&input)?;
            if method == "package-inspect" {
                return Ok(
                    json!({"types":package.types.len(),"entries":package.entries.iter().map(|e|json!({
                "id":format!("{:016X}",u64::from_le_bytes(e[..8].try_into().unwrap())),"type":format!("{:016X}",u64::from_le_bytes(e[8..16].try_into().unwrap()))})).collect::<Vec<_>>()}),
                );
            }
            let side = |key| -> Result<Vec<u8>, String> {
                if p[key].is_null() {
                    Ok(Vec::new())
                } else {
                    fs::read(text(p, key)?).map_err(|_| "无法读取资源伴生文件".into())
                }
            };
            let blobs = package.blobs(&input, &side("gpu_path")?, &side("stream_path")?)?;
            let built = package.build(&blobs)?;
            let out = PathBuf::from(text(p, "output")?);
            // All three files are one export transaction; no game directory is inferred.
            let parent = out.parent().ok_or("导出目录无效")?;
            let backup = parent.join(format!(
                "shodan-export-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_err(|_| "系统时间无效")?
                    .as_nanos()
            ));
            let gpu = PathBuf::from(format!("{}.gpu_resources", out.display()));
            let stream = PathBuf::from(format!("{}.stream", out.display()));
            if out.exists() || gpu.exists() || stream.exists() {
                return Err("导出文件已存在，不会覆盖".into());
            }
            crate::install::apply(
                vec![
                    crate::install::Change {
                        path: out,
                        before: None,
                        after: Some(built.toc),
                    },
                    crate::install::Change {
                        path: gpu,
                        before: None,
                        after: Some(built.gpu),
                    },
                    crate::install::Change {
                        path: stream,
                        before: None,
                        after: Some(built.stream),
                    },
                ],
                &backup,
                |_| {},
            )?;
            return Ok(json!({"resources":blobs.len(),"installed":false}));
        }
        if method == "reference-files" {
            let paths = p["paths"].as_array().ok_or("缺少引用数据文件")?;
            if paths.len() > 64 {
                return Err("引用数据文件过多".into());
            }
            let sessions = paths
                .iter()
                .map(|v| {
                    let bytes = fs::read(v.as_str().ok_or("文件路径无效")?)
                        .map_err(|_| "引用数据无法读取")?;
                    Session::new(bytes, None)
                })
                .collect::<Result<Vec<_>, String>>()?;
            let data = crate::references::Data::new(sessions.iter().collect())?;
            let roots = p["roots"]
                .as_array()
                .ok_or("缺少引用根节点")?
                .iter()
                .map(|root| {
                    Ok((
                        text(root, "kind")?.to_string(),
                        u32::try_from(number(root, "id")?).map_err(|_| "引用 ID 超出范围")?,
                        root["via"].as_str().unwrap_or("当前记录").to_string(),
                    ))
                })
                .collect::<Result<Vec<_>, String>>()?;
            return data.graph(&roots);
        }
        if method == "diagnostic-scrub" {
            return Ok(crate::diagnostics::Privacy::local().scrub(&p["data"]));
        }
        if method == "armor-open" {
            let session = crate::armor_session::Session::open(
                PathBuf::from(text(p, "path")?),
                text(p, "baseline_path")?,
            )?;
            let count = session.row_count();
            self.armor = Some(session);
            return Ok(json!({"rows":count}));
        }
        if method.starts_with("armor-") {
            return self
                .armor
                .as_mut()
                .ok_or("请先打开护甲数据")?
                .invoke(method, p);
        }
        if method == "schema" {
            let type_id =
                u32::from_str_radix(text(p, "type")?, 16).map_err(|_| "数据块类型无效")?;
            let fields = crate::schema::parameters(type_id);
            if fields.is_empty() {
                return Err("该类型的原生参数描述尚未迁移".into());
            }
            return Ok(json!(fields
                .iter()
                .map(|f| json!({"id":f.id,"label":f.label,"relative":f.relative,
                "kind":match f.kind {Kind::F32=>"f32",Kind::U32=>"u32",Kind::I32=>"i32"}}))
                .collect::<Vec<_>>()));
        }
        if method == "info" {
            return Ok(
                json!({"runtime":"rust-native","version":env!("CARGO_PKG_VERSION"),"lua":false,"installation":false}),
            );
        }
        if method == "close" {
            self.active = None;
            self.armor = None;
            self.workspace = None;
            self.parameters = Default::default();
            return Ok(json!(true));
        }
        if method == "preset-inspect" {
            let preset = crate::preset::Preset::decode(text(p, "text")?)?;
            return Ok(
                json!({"kind":preset.kind,"name":preset.name,"weapon":preset.weapon,
                "editor":preset.editor,"armor":preset.armor,"values":preset.values.iter().map(|v|
                    json!({"owner":v.owner,"parameter":v.parameter,"value":v.value})).collect::<Vec<_>>(),
                "normalized":preset.encode()?}),
            );
        }
        if method == "open" {
            let path = PathBuf::from(text(p, "path")?);
            let bytes = fs::read(&path).map_err(|_| "无法读取数据文件")?;
            let baseline = if p["baseline_path"].is_null() {
                None
            } else {
                let filename = text(p, "baseline_name")?;
                let bytes = fs::read(text(p, "baseline_path")?).map_err(|_| "无法读取原值文件")?;
                Some(Baseline::shipped(filename, bytes)?)
            };
            let blocks = crate::dlbin::index(&bytes).map_err(|e| e.to_string())?;
            let report = json!({"blocks":blocks.iter().enumerate().map(|(index,b)|json!({"index":index,"type":format!("{:08X}",b.type_id),"bytes":b.payload.len()})).collect::<Vec<_>>()});
            let session = Session::new(bytes, baseline)?;
            self.active = Some((session, path));
            self.parameters = Default::default();
            return Ok(report);
        }
        let (session, path) = self.active.as_mut().ok_or("请先打开数据文件")?;
        match method {
            "references" => {
                let data = crate::references::Data::new(vec![session])?;
                let roots = if let Some(entity) = p["entity"].as_str() {
                    data.roots(u64::from_str_radix(entity, 16).map_err(|_| "实体哈希无效")?)?
                } else {
                    p["roots"]
                        .as_array()
                        .ok_or("缺少引用根节点")?
                        .iter()
                        .map(|root| {
                            Ok((
                                text(root, "kind")?.to_string(),
                                u32::try_from(number(root, "id")?)
                                    .map_err(|_| "引用 ID 超出范围")?,
                                "当前数据记录".into(),
                            ))
                        })
                        .collect::<Result<Vec<_>, String>>()?
                };
                data.graph(&roots)
            }
            "bind-parameter" => {
                let parts = p["fields"].as_array().ok_or("缺少参数字段")?;
                let fields = parts
                    .iter()
                    .map(|part| {
                        session.named_field(
                            number(part, "block")?,
                            record(part)?,
                            text(part, "parameter")?,
                        )
                    })
                    .collect::<Result<Vec<_>, String>>()?;
                self.parameters
                    .bind(session, text(p, "owner")?, text(p, "parameter")?, fields)?;
                Ok(json!(true))
            }
            "preset-compare" | "preset-apply-values" => {
                let preset = crate::preset::Preset::decode(text(p, "text")?)?;
                let allow_missing = match p.get("allow_missing") {
                    None => false,
                    Some(v) => v.as_bool().ok_or("跳过缺失参数选项必须为布尔值")?,
                };
                let plan = if method == "preset-compare" {
                    self.parameters.plan(session, &preset, allow_missing)?
                } else {
                    self.parameters.apply(session, &preset, allow_missing)?
                };
                Ok(
                    json!({"changes":plan.changes.iter().map(|(owner,parameter,before,after)|json!({"owner":owner,"parameter":parameter,"before":before,"after":after})).collect::<Vec<_>>(),
                    "warnings":plan.warnings,"pending":session.pending_count(),"applied":method=="preset-apply-values"}),
                )
            }
            "history" => {
                let (undo, redo) = session.history();
                Ok(json!({"undo":undo,"redo":redo}))
            }
            "undo" => Ok(json!({"changed":session.undo(),"pending":session.pending_count()})),
            "redo" => Ok(json!({"changed":session.redo(),"pending":session.pending_count()})),
            "index" => {
                let layout = match text(p, "layout")? {
                    "rows" => Layout::Rows {
                        stride: number(p, "stride")?,
                        id_offset: number(p, "id_offset")?,
                    },
                    "keyed" => Layout::Keyed {
                        stride: number(p, "stride")?,
                        slack: number(p, "slack")?,
                    },
                    _ => return Err("未知表布局".into()),
                };
                session.index_table(number(p, "block")?, layout)?;
                Ok(json!(true))
            }
            "get" => {
                let value = session.value(field(p)?)?;
                Ok(json!({"value":value.current,"original":value.original}))
            }
            "set" => {
                session.set(field(p)?, p["value"].as_f64().ok_or("数值无效")?)?;
                Ok(json!({"pending":session.pending_count()}))
            }
            "apply-batch" => {
                let edits = p["fields"].as_array().ok_or("缺少批量字段列表")?;
                if edits.len() > 100000 {
                    return Err("批量字段过多".into());
                }
                let edits = edits
                    .iter()
                    .map(|entry| Ok((field(entry)?, entry["value"].as_f64().ok_or("数值无效")?)))
                    .collect::<Result<Vec<_>, String>>()?;
                session.apply_batch(&edits)?;
                Ok(json!({"pending":session.pending_count(),"accepted":edits.len()}))
            }
            "restore" => {
                session.restore(field(p)?)?;
                Ok(json!({"pending":session.pending_count()}))
            }
            "preview" => Ok(json!({"pending":session.pending_count(),"installed":false})),
            "export-copy" => {
                // Re-read before export: external tools must not be overwritten by stale edits.
                let current = fs::read(path).map_err(|_| "无法重新读取磁盘快照")?;
                let edited = session.render(&current)?;
                let mut output = fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(text(p, "path")?)
                    .map_err(|_| "无法创建新文件，不会覆盖已有文件")?;
                output
                    .write_all(&edited)
                    .and_then(|_| output.sync_all())
                    .map_err(|_| "导出写入失败")?;
                Ok(
                    json!({"bytes":edited.len(),"sha256":crate::hash::sha256_hex(&edited),"installed":false,"sealed":false}),
                )
            }
            _ => Err(format!("未提供原生接口：{method}")),
        }
    }
}
fn request_line(
    input: &mut impl BufRead,
    limit: usize,
) -> Result<Option<Result<Vec<u8>, String>>, String> {
    let mut line = Vec::new();
    let mut too_large = false;
    loop {
        let buffer = input.fill_buf().map_err(|_| "请求读取失败")?;
        if buffer.is_empty() {
            return if line.is_empty() && !too_large {
                Ok(None)
            } else {
                Ok(Some(if too_large {
                    Err("请求过大".into())
                } else {
                    Ok(line)
                }))
            };
        }
        let newline = buffer.iter().position(|b| *b == b'\n');
        let consumed = newline.map_or(buffer.len(), |at| at + 1);
        if !too_large {
            if line.len().saturating_add(consumed) > limit {
                too_large = true;
                line.clear();
            } else {
                line.extend_from_slice(&buffer[..consumed]);
            }
        }
        input.consume(consumed);
        if newline.is_some() {
            return Ok(Some(if too_large {
                Err("请求过大".into())
            } else {
                Ok(line)
            }));
        }
    }
}
pub fn serve(mut input: impl BufRead, mut output: impl Write) -> Result<(), String> {
    let api = std::sync::Arc::new(std::sync::Mutex::new(Api::default()));
    let mut mcp: Option<crate::mcp::Server> = None;
    // Permit an 8 MiB preset even if JSON escapes every byte. Bound allocation
    // while reading, and drain oversized requests so the next call remains usable.
    while let Some(line) = request_line(&mut input, 50 * 1024 * 1024)? {
        let parsed = line.and_then(|line| {
            serde_json::from_slice::<Value>(&line).map_err(|_| "请求 JSON 无效".to_string())
        });
        let id = parsed
            .as_ref()
            .ok()
            .and_then(|r| r.get("id"))
            .cloned()
            .unwrap_or(Value::Null);
        let result = parsed.and_then(|r| match r["method"].as_str() {
            Some("mcp-start") => {
                if mcp.is_none() {
                    mcp = Some(crate::mcp::Server::start(api.clone())?);
                }
                Ok(json!({"enabled":true,"config":mcp.as_ref().unwrap().config()}))
            }
            Some("mcp-stop") => {
                mcp = None;
                Ok(json!({"enabled":false}))
            }
            Some("mcp-status") => Ok(json!({"enabled":mcp.is_some()})),
            Some("mcp-config") => mcp
                .as_ref()
                .map(|s| s.config())
                .ok_or("MCP 尚未开启".into()),
            _ => api
                .lock()
                .map_err(|_| "原生会话不可用".to_string())?
                .invoke(&r),
        });
        let response = match result {
            Ok(value) => json!({"id":id,"ok":true,"result":value}),
            Err(e) => json!({"id":id,"ok":false,"error":e}),
        };
        writeln!(output, "{response}")
            .and_then(|_| output.flush())
            .map_err(|_| "响应写入失败")?;
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn oversized_lines_are_drained_and_following_requests_remain_readable() {
        let mut input = std::io::BufReader::with_capacity(3, &b"123456789\n{}\n"[..]);
        assert!(request_line(&mut input, 5).unwrap().unwrap().is_err());
        assert_eq!(
            request_line(&mut input, 5).unwrap().unwrap().unwrap(),
            b"{}\n"
        );
        assert!(request_line(&mut input, 5).unwrap().is_none());
    }
    #[test]
    fn transport_preserves_ids_and_recovers_after_bad_requests() {
        let input=b"bad\n{\"id\":7,\"method\":\"get\",\"params\":{}}\n{\"id\":\"hello\",\"method\":\"info\"}\n";
        let mut output = Vec::new();
        serve(&input[..], &mut output).unwrap();
        let replies: Vec<Value> = String::from_utf8(output)
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        assert_eq!(replies[0]["ok"], false);
        assert_eq!(replies[1]["id"], 7);
        assert_eq!(replies[2]["id"], "hello");
        assert_eq!(replies[2]["result"]["lua"], false);
    }
}
