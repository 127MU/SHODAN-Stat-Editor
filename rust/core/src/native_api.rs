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
    armor: Option<(crate::armor::Armor, PathBuf)>,
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
        if method == "diagnostic-scrub" {
            return Ok(crate::diagnostics::Privacy::local().scrub(&p["data"]));
        }
        if method == "armor-open" {
            let path = PathBuf::from(text(p, "path")?);
            let current = fs::read(&path).map_err(|_| "无法读取护甲数据")?;
            let original = fs::read(text(p, "baseline_path")?).map_err(|_| "无法读取护甲原值")?;
            let baseline =
                Baseline::shipped("generated_customization_passive_bonuses.dl_plain", original)?;
            let armor = crate::armor::Armor::new(current, baseline)?;
            let count = armor.rows.len();
            self.armor = Some((armor, path));
            return Ok(json!({"rows":count}));
        }
        if method.starts_with("armor-") {
            let (armor, path) = self.armor.as_mut().ok_or("请先打开护甲数据")?;
            return match method {
                "armor-rows" => Ok(json!(armor
                    .rows
                    .values()
                    .map(
                        |r| Ok(json!({"key":r.key,"label":r.label,"passive":r.passive,
                    "value":armor.value(&r.key)?,"original":r.original}))
                    )
                    .collect::<Result<Vec<_>, String>>()?)),
                "armor-set" => {
                    armor.set(text(p, "key")?, p["value"].as_f64().ok_or("护甲数值无效")?)?;
                    Ok(json!(true))
                }
                "armor-capture" => Ok(json!(armor.capture()?)),
                "armor-apply-snapshot" => {
                    armor.apply_snapshot(text(p, "text")?)?;
                    Ok(json!(true))
                }
                "armor-export-copy" => {
                    let current = fs::read(path).map_err(|_| "无法核对护甲磁盘数据")?;
                    let bytes = armor.render(&current)?;
                    let mut out = fs::OpenOptions::new()
                        .write(true)
                        .create_new(true)
                        .open(text(p, "path")?)
                        .map_err(|_| "无法创建新护甲导出文件")?;
                    out.write_all(&bytes)
                        .and_then(|_| out.sync_all())
                        .map_err(|_| "护甲导出失败")?;
                    Ok(json!({"bytes":bytes.len(),"installed":false}))
                }
                _ => Err("未提供该护甲接口".into()),
            };
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
                json!({"runtime":"rust-native","version":"4.6.0","lua":false,"installation":false}),
            );
        }
        if method == "close" {
            self.active = None;
            self.armor = None;
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
pub fn serve(input: impl BufRead, mut output: impl Write) -> Result<(), String> {
    let mut api = Api::default();
    for line in input.lines() {
        let line = line.map_err(|_| "请求读取失败")?;
        let parsed = if line.len() > 1_048_576 {
            Err("请求过大".to_string())
        } else {
            serde_json::from_str::<Value>(&line).map_err(|_| "请求 JSON 无效".to_string())
        };
        let id = parsed
            .as_ref()
            .ok()
            .and_then(|r| r.get("id"))
            .cloned()
            .unwrap_or(Value::Null);
        let result = parsed.and_then(|r| api.invoke(&r));
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
