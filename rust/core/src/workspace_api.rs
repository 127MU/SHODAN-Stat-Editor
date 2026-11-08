//! JSON boundary for the shared multi-file Rust workspace.
use crate::{
    binary::Encoding,
    tables::Key,
    workspace::{File, Location, Record, Workspace},
};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    io::Write,
    path::{Path, PathBuf},
};
fn text<'a>(p: &'a Value, key: &str) -> Result<&'a str, String> {
    p[key].as_str().ok_or_else(|| format!("缺少文本：{key}"))
}
fn unsigned(p: &Value, key: &str) -> Result<usize, String> {
    usize::try_from(p[key].as_u64().ok_or_else(|| format!("缺少整数：{key}"))?)
        .map_err(|_| "整数超出范围".into())
}
fn word(p: &Value, key: &str) -> Result<u32, String> {
    u32::try_from(unsigned(p, key)?).map_err(|_| "整数超出 32 位范围".into())
}
fn hex(text: &str) -> Result<u64, String> {
    let digits = text.strip_prefix("0x").unwrap_or(text);
    if digits.is_empty() || digits.len() > 16 || !digits.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("资源哈希无效".into());
    }
    u64::from_str_radix(digits, 16).map_err(|_| "资源哈希无效".into())
}
pub fn encoding(p: &Value) -> Result<Encoding, String> {
    let kind = p
        .as_str()
        .or_else(|| p["kind"].as_str())
        .ok_or("缺少字段存储类型")?;
    let codec = match kind {
        "u8" => Encoding::U8,
        "u16" => Encoding::U16,
        "u32" => Encoding::U32,
        "i32" => Encoding::I32,
        "f32" => Encoding::F32,
        "bool" => Encoding::Bool,
        "demolition" => Encoding::Demolition,
        "flag" => Encoding::Flag {
            width: unsigned(p, "width")?,
            mask: word(p, "mask")?,
        },
        "switch" => Encoding::Switch {
            on: word(p, "on")?,
            off: word(p, "off")?,
        },
        "reference" => {
            let mut entries = BTreeMap::new();
            let mut seen = BTreeSet::new();
            let object = p["entries"].as_object().ok_or("缺少资源身份清单")?;
            if object.len() > 100000 {
                return Err("资源身份清单过大".into());
            }
            for (key, value) in object {
                let id = key.parse::<u64>().map_err(|_| "资源选择 ID 无效")?;
                if id.to_string() != *key {
                    return Err("资源选择 ID 必须是规范十进制整数".into());
                }
                let raw = hex(value.as_str().ok_or("完整资源身份必须使用十六进制文本")?)?;
                if !seen.insert(raw) {
                    return Err("资源身份清单存在重复资源".into());
                }
                entries.insert(id, raw);
            }
            Encoding::Reference(entries)
        }
        _ => return Err("不支持的字段存储类型".into()),
    };
    codec.width()?;
    Ok(codec)
}
pub fn location(p: &Value) -> Result<Location, String> {
    let raw = text(p, "record")?;
    let record = if let Some(id) = raw.strip_prefix("id:") {
        Key::Id(id.parse().map_err(|_| "记录 ID 无效")?).into()
    } else if let Some(hash) = raw.strip_prefix("hash:") {
        Key::Hash(hex(hash)?).into()
    } else if let Some(key) = raw.strip_prefix("delta:") {
        let parts = key.split(':').collect::<Vec<_>>();
        if parts.len() != 3 {
            return Err("增量记录身份无效".into());
        }
        Record::Delta(crate::arrays::DeltaKey {
            resource: hex(parts[0])?,
            component: parts[1].parse().map_err(|_| "增量组件编号无效")?,
            field: parts[2].parse().map_err(|_| "增量字段编号无效")?,
        })
    } else if let Some(key) = raw.strip_prefix("kit:") {
        let parts = key.split(':').collect::<Vec<_>>();
        if parts.len() != 4 {
            return Err("护甲条目身份无效".into());
        }
        let mut identity = [0; 3];
        for i in 0..3 {
            identity[i] = u32::try_from(hex(parts[i])?).map_err(|_| "护甲条目身份无效")?;
        }
        Record::Kit {
            identity,
            size: parts[3].parse().map_err(|_| "护甲条目长度无效")?,
        }
    } else if let Some(key) = raw.strip_prefix("resource:") {
        let (typ, id) = key.split_once(':').ok_or("独立资源身份无效")?;
        Record::Resource {
            typ: hex(typ)?,
            id: hex(id)?,
        }
    } else if let Some(key) = raw.strip_prefix("stat:") {
        let parts = key.split(':').collect::<Vec<_>>();
        if parts.len() != 3 {
            return Err("状态修饰项身份无效".into());
        }
        Record::StatusModifier {
            status: parts[0].parse().map_err(|_| "状态 ID 无效")?,
            stat: parts[1].parse().map_err(|_| "修饰项 ID 无效")?,
            ordinal: parts[2].parse().map_err(|_| "修饰项序号无效")?,
        }
    } else if let Some(key) = raw.strip_prefix("demolition:") {
        let parts = key.split(':').collect::<Vec<_>>();
        if parts.len() != 3 || !matches!(parts[2], "0" | "1") {
            return Err("拆毁条目身份无效".into());
        }
        Record::Destruction {
            entity: hex(parts[0])?,
            level: parts[1].parse().map_err(|_| "拆毁等级无效")?,
            direct: parts[2] == "1",
        }
    } else {
        return Err("记录身份无效".into());
    };
    Ok(Location {
        file: text(p, "file")?.into(),
        typ: u32::try_from(hex(text(p, "type")?)?).map_err(|_| "类型 ID 无效")?,
        record,
        relative: unsigned(p, "relative")?,
    })
}
pub(crate) fn bounded_read(path: &Path, total: &mut u64) -> Result<Vec<u8>, String> {
    let size = fs::metadata(path)
        .map_err(|_| "数据文件不存在或无法读取")?
        .len();
    *total = total.checked_add(size).ok_or("数据文件总量溢出")?;
    if size > 256 * 1024 * 1024 || *total > 512 * 1024 * 1024 {
        return Err("工作区数据总量过大".into());
    }
    let bytes = fs::read(path).map_err(|_| "数据文件无法读取")?;
    if bytes.len() as u64 != size {
        return Err("读取时数据文件发生变化".into());
    }
    Ok(bytes)
}
pub fn open(p: &Value) -> Result<Workspace, String> {
    let files = p["files"].as_array().ok_or("缺少工作区文件清单")?;
    if files.is_empty() || files.len() > 64 {
        return Err("工作区文件数量无效".into());
    }
    let mut workspace = Workspace::default();
    let mut paths = BTreeSet::new();
    let mut total = 0;
    for input in files {
        let path = fs::canonicalize(text(input, "path")?).map_err(|_| "数据文件路径无法解析")?;
        let identity = path.to_string_lossy().to_string();
        #[cfg(windows)]
        let identity = identity.to_lowercase();
        if !paths.insert(identity) {
            return Err("同一个文件被重复添加到工作区".into());
        }
        let current = bounded_read(&path, &mut total)?;
        let baseline = if input["embedded_armor"] == true {
            if text(input, "name")? != crate::desktop_armor::PASSIVE {
                return Err("嵌入原值只能用于护甲被动表".into());
            }
            Some(crate::baseline::Baseline::shipped(
                "generated_customization_passive_bonuses.dl_plain",
                crate::desktop_armor::BASELINE.to_vec(),
            )?)
        } else if input["baseline_path"].is_null() {
            None
        } else {
            let bytes = bounded_read(Path::new(text(input, "baseline_path")?), &mut total)?;
            Some(crate::baseline::Baseline::shipped(
                text(input, "baseline_name")?,
                bytes,
            )?)
        };
        let file = match input.get("sealed") {
            None | Some(Value::Bool(false)) => File::new(path, current, baseline),
            Some(Value::Bool(true)) => File::sealed(path, current, baseline),
            Some(_) => return Err("密封输入选项必须为布尔值".into()),
        };
        let name = text(input, "name")?;
        match file {
            Ok(file) => workspace.add(name.into(), file)?,
            Err(error) if p["isolate_invalid_files"] == true => workspace.block_resource(
                name.into(),
                format!("{name} 无法解析：{error}；该文件未载入、未修改，请运行自动修复"),
            ),
            Err(error) => return Err(format!("{name}：{error}")),
        }
    }
    Ok(workspace)
}
fn changes(p: &Value) -> Result<Vec<(Location, Encoding, f64)>, String> {
    let values = p["values"].as_array().ok_or("缺少修改清单")?;
    if values.len() > 150000 {
        return Err("一次修改的参数数量过大".into());
    }
    values
        .iter()
        .map(|v| {
            let number = v["value"].as_f64().ok_or("参数数值无效")?;
            Ok((
                location(&v["field"])?,
                encoding(&v["field"]["encoding"])?,
                number,
            ))
        })
        .collect()
}
fn export(workspace: &Workspace, output: &Path) -> Result<Value, String> {
    let prepared = workspace.render_all()?;
    export_prepared(&prepared, output)
}
pub(crate) fn export_prepared(
    prepared: &BTreeMap<String, Vec<u8>>,
    output: &Path,
) -> Result<Value, String> {
    export_files(prepared, output, "dl_plain")
}

fn export_files(
    prepared: &BTreeMap<String, Vec<u8>>,
    output: &Path,
    format: &str,
) -> Result<Value, String> {
    let mut names = BTreeSet::new();
    let filename = |name: &str| {
        let stem = name.strip_suffix(".dl_bin").unwrap_or(name);
        format!("{stem}.{format}")
    };
    for name in prepared.keys() {
        if name.is_empty() || name.contains(['/', '\\', ':', '\0']) || name == "." || name == ".." {
            return Err("导出文件名无效".into());
        }
        if !names.insert(filename(name).to_lowercase()) {
            return Err("导出文件名重复".into());
        }
    }
    fs::create_dir(output).map_err(|_| "无法创建全新的导出目录；不会覆盖已有目录")?;
    let mut owned: Vec<PathBuf> = Vec::new();
    let result = (|| {
        let mut reports = Vec::new();
        for (name, bytes) in prepared {
            let filename = filename(name);
            let path = output.join(&filename);
            let mut file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&path)
                .map_err(|_| "无法创建工作区导出文件")?;
            owned.push(path.clone());
            file.write_all(bytes)
                .and_then(|_| file.sync_all())
                .map_err(|_| "工作区导出未完整写入")?;
            if fs::read(&path).map_err(|_| "无法回读工作区导出")? != *bytes {
                return Err("工作区导出回读不一致".into());
            }
            reports.push(json!({"name":filename,"bytes":bytes.len(),"sha256":crate::hash::sha256_hex(bytes)}));
        }
        Ok(json!({"files":reports,"format":format,"installed":false}))
    })();
    if result.is_err() {
        for path in owned {
            let _ = fs::remove_file(path);
        }
        let _ = fs::remove_dir(output);
    }
    result
}
pub fn invoke(workspace: &mut Workspace, method: &str, p: &Value) -> Result<Value, String> {
    match method {
        "workspace-read-batch" => {
            let fields = p["fields"].as_array().ok_or("缺少参数清单")?;
            if fields.len() > 150000 {
                return Err("读取参数数量过大".into());
            }
            let mut values = Vec::with_capacity(fields.len());
            for field in fields {
                let value = workspace.value(&location(field)?, &encoding(&field["encoding"])?)?;
                values.push(
                    json!({"value":value.current,"original":value.original,"loaded":value.loaded}),
                );
            }
            Ok(json!(values))
        }
        "workspace-get" => {
            let field = location(p)?;
            let codec = encoding(&p["encoding"])?;
            let value = workspace.value(&field, &codec)?;
            Ok(json!({"value":value.current,"original":value.original,"loaded":value.loaded}))
        }
        "workspace-apply" => {
            let metadata = p.get("metadata").cloned();
            if let Some(data) = &metadata {
                if data.to_string().len() > 1024 * 1024 {
                    return Err("工作区状态过大".into());
                }
            }
            workspace.set_batch(&changes(p)?, metadata)?;
            Ok(json!({"pending_bytes":workspace.pending_count()}))
        }
        "workspace-restore" => {
            workspace.restore(location(p)?, encoding(&p["encoding"])?)?;
            Ok(json!(true))
        }
        "workspace-undo" => Ok(json!(workspace.undo())),
        "workspace-redo" => Ok(json!(workspace.redo())),
        "workspace-history" => {
            let (undo, redo) = workspace.history();
            Ok(json!({"undo":undo,"redo":redo}))
        }
        "workspace-preview" => Ok(
            json!({"pending_bytes":workspace.pending_count(),"metadata":workspace.metadata(),"problems":workspace.problems(),"installed":false}),
        ),
        "workspace-export-copy" => export(workspace, Path::new(text(p, "output")?)),
        "workspace-export-sealed-copy" => {
            let output = Path::new(text(p, "output")?);
            let floats = p
                .get("float_fields")
                .map(|fields| {
                    let fields = fields.as_array().ok_or("允许微调的参数清单格式无效")?;
                    if fields.len() > 64 {
                        return Err("允许微调的参数数量过多".into());
                    }
                    fields
                        .iter()
                        .map(|field| {
                            if field["encoding"] != "f32" {
                                return Err("只可明确允许微调浮点参数".into());
                            }
                            location(field)
                        })
                        .collect::<Result<Vec<_>, String>>()
                })
                .transpose()?
                .unwrap_or_default();
            let prepared = workspace.prepare_sealed(&floats)?;
            if prepared.is_empty() {
                return Ok(json!({"files":[],"format":"dl_bin","installed":false}));
            }
            let mut reports = Vec::new();
            let files = prepared
                .into_iter()
                .map(|(name, file)| {
                    if let Some((offset, before, after)) = file.correction.adjusted_float {
                        reports.push(
                            json!({"file":name,"offset":offset,"before":before,"after":after}),
                        );
                    }
                    (name, file.ciphertext)
                })
                .collect();
            let mut report = export_files(&files, output, "dl_bin")?;
            report["adjusted_floats"] = json!(reports);
            Ok(report)
        }
        _ => Err("未提供该工作区接口".into()),
    }
}
