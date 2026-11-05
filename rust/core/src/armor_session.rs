//! One native armor session: values, composition choices and bounded joint history.
//! Exports create copies only; this session never installs game files.
use crate::{armor::Armor, armor_profiles::Profiles, baseline::Baseline};
use serde_json::{json, Value};
use std::{fs, io::Write, path::PathBuf};

pub struct Session {
    armor: Armor,
    path: PathBuf,
    profiles: Profiles,
    history: Vec<ArmorEdit>,
    future: Vec<ArmorEdit>,
}
#[derive(Clone, PartialEq, Eq)]
struct ArmorEdit {
    values: std::collections::BTreeMap<usize, [u8; 4]>,
    profiles: crate::armor_profiles::Profiles,
}
fn text<'a>(value: &'a Value, key: &str) -> Result<&'a str, String> {
    value[key]
        .as_str()
        .ok_or_else(|| format!("缺少文本：{key}"))
}
fn number(value: &Value, key: &str) -> Result<u64, String> {
    value[key]
        .as_u64()
        .ok_or_else(|| format!("缺少有效整数：{key}"))
}
fn armor_profiles_json(
    profiles: &crate::armor_profiles::Profiles,
    available: &std::collections::BTreeSet<u32>,
) -> Result<Value, String> {
    let (groups, sources) = profiles.counts();
    Ok(json!({"groups":profiles.groups.iter().map(|(id,g)|{
        // Always an object: dense numeric keys must never become arrays.
        let enabled:serde_json::Map<String,Value>=g.profile.enabled.iter().map(|id|(id.to_string(),json!(true))).collect();
        json!({"id":id,"own":g.profile.own,"configured":g.configured,
          "policy":if g.profile.policy==crate::passive::Policy::Strongest{"strongest"}else{"stack"},"enabled":enabled})
    }).collect::<Vec<_>>(),"configured_groups":groups,"selected_sources":sources,
      "available":available,"text":profiles.encode(available)?}))
}
fn export_new(path: &str, bytes: &[u8]) -> Result<(), String> {
    let mut out = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|_| "无法创建新的导出文件")?;
    out.write_all(bytes)
        .and_then(|_| out.sync_all())
        .map_err(|_| "导出失败，文件可能不完整".into())
}
impl Session {
    pub fn open(path: PathBuf, baseline_path: &str) -> Result<Self, String> {
        let current = fs::read(&path).map_err(|_| "无法读取护甲数据")?;
        let original = fs::read(baseline_path).map_err(|_| "无法读取护甲原值")?;
        let baseline =
            Baseline::shipped("generated_customization_passive_bonuses.dl_plain", original)?;
        Ok(Self {
            armor: Armor::new(current, baseline)?,
            path,
            profiles: Default::default(),
            history: Vec::new(),
            future: Vec::new(),
        })
    }
    pub fn row_count(&self) -> usize {
        self.armor.rows.len()
    }
    fn checkpoint(&self) -> ArmorEdit {
        ArmorEdit {
            values: self.armor.checkpoint(),
            profiles: self.profiles.clone(),
        }
    }
    pub fn invoke(&mut self, method: &str, p: &Value) -> Result<Value, String> {
        let watched = matches!(
            method,
            "armor-set"
                | "armor-apply-snapshot"
                | "armor-profiles-load"
                | "armor-profiles-update"
                | "armor-profiles-remove"
                | "armor-profiles-clear"
                | "armor-state-apply"
        );
        let checkpoint = watched.then(|| self.checkpoint());
        let result = self.invoke_inner(method, p);
        if result.is_ok() {
            if let Some(before) = checkpoint {
                if self.checkpoint() != before {
                    if self.history.len() == 100 {
                        self.history.remove(0);
                    }
                    self.history.push(before);
                    self.future.clear();
                }
            }
        }
        result
    }
    fn invoke_inner(&mut self, method: &str, p: &Value) -> Result<Value, String> {
        let armor = &mut self.armor;
        let path = &self.path;
        return match method {
            "armor-history" => Ok(json!({"undo":self.history.len(),"redo":self.future.len()})),
            "armor-undo" | "armor-redo" => {
                let saved = if method == "armor-undo" {
                    self.history.pop()
                } else {
                    self.future.pop()
                };
                if let Some(saved) = saved {
                    let current = ArmorEdit {
                        values: armor.checkpoint(),
                        profiles: self.profiles.clone(),
                    };
                    armor.resume(saved.values);
                    self.profiles = saved.profiles;
                    if method == "armor-undo" {
                        self.future.push(current);
                    } else {
                        self.history.push(current);
                    }
                    Ok(json!(true))
                } else {
                    Ok(json!(false))
                }
            }
            "armor-profiles-get" => armor_profiles_json(&self.profiles, &armor.available),
            "armor-profiles-load" => {
                let parsed =
                    crate::armor_profiles::Profiles::parse(text(p, "text")?, &armor.available)?;
                let mut result = armor_profiles_json(&parsed.profiles, &armor.available)?;
                result["ignored_numeric"] = json!(parsed.ignored_numeric);
                result["warnings"] = json!(parsed.warnings);
                self.profiles = parsed.profiles;
                Ok(result)
            }
            "armor-profiles-update" => {
                let id = u32::try_from(number(p, "id")?).map_err(|_| "护甲组 ID 无效")?;
                let own = p["own"].as_bool().ok_or("保留原生被动必须是开关值")?;
                let policy = match text(p, "policy")? {
                    "stack" => crate::passive::Policy::Stack,
                    "strongest" => crate::passive::Policy::Strongest,
                    _ => return Err("同类效果处理方式无效".into()),
                };
                let mut enabled = Vec::new();
                for (key, value) in p["enabled"]
                    .as_object()
                    .ok_or("被动选择必须是 ID 到开关值的对象")?
                {
                    let source = key.parse::<u32>().map_err(|_| "来源被动 ID 无效")?;
                    if source.to_string() != *key || !armor.available.contains(&source) {
                        return Err("来源被动不存在或 ID 无效".into());
                    }
                    if value.as_bool().ok_or("被动选择必须是开关值")? {
                        enabled.push(source);
                    }
                }
                enabled.sort_unstable();
                let mut updated = self.profiles.clone();
                updated.groups.insert(
                    id,
                    crate::armor_profiles::Group {
                        profile: crate::passive::Profile {
                            own,
                            policy,
                            enabled,
                        },
                        configured: true,
                    },
                );
                let result = armor_profiles_json(&updated, &armor.available)?;
                self.profiles = updated;
                Ok(result)
            }
            "armor-profiles-remove" => {
                let id = u32::try_from(number(p, "id")?).map_err(|_| "护甲组 ID 无效")?;
                self.profiles.groups.remove(&id);
                armor_profiles_json(&self.profiles, &armor.available)
            }
            "armor-profiles-clear" => {
                self.profiles = Default::default();
                armor_profiles_json(&self.profiles, &armor.available)
            }
            "armor-profiles-export-copy" => {
                let config = self.profiles.encode(&armor.available)?;
                export_new(text(p, "path")?, config.as_bytes())?;
                Ok(json!({"bytes":config.len(),"installed":false}))
            }
            "armor-state-capture" => {
                let numeric = armor.capture()?;
                let profiles = self.profiles.encode(&armor.available)?;
                let state = json!({"format":"SHODAN-ARMOR-STATE","version":1,"numeric":numeric,"profiles":profiles});
                let encoded = serde_json::to_string(&state).map_err(|_| "护甲预设编码失败")?;
                Ok(json!(encoded))
            }
            "armor-state-apply" => {
                let input = text(p, "text")?;
                if input.len() > 2 * 1024 * 1024 {
                    return Err("护甲预设过大".into());
                }
                let state: Value = serde_json::from_str(input).map_err(|_| "护甲预设格式无效")?;
                if state["format"] != "SHODAN-ARMOR-STATE" || state["version"] != 1 {
                    return Err("护甲预设版本不支持".into());
                }
                if state.as_object().is_none_or(|v| {
                    v.keys().any(|key| {
                        !["format", "version", "numeric", "profiles"].contains(&key.as_str())
                    })
                }) {
                    return Err("护甲预设包含未知字段".into());
                }
                let parsed = crate::armor_profiles::Profiles::parse(
                    text(&state, "profiles")?,
                    &armor.available,
                )?;
                // Imported snapshots must not silently discard IDs from a
                // different game version. Parse before atomic numeric apply.
                if !parsed.warnings.is_empty() || parsed.ignored_numeric != 0 {
                    return Err("护甲预设包含无法识别的组合配置".into());
                }
                armor.apply_snapshot(text(&state, "numeric")?)?;
                self.profiles = parsed.profiles;
                Ok(json!(true))
            }
            "armor-compose-preview" | "armor-compose-export-copy" => {
                let current = fs::read(path).map_err(|_| "无法核对护甲磁盘数据")?;
                let edited = armor.render(&current)?;
                let selected = self
                    .profiles
                    .selection(&Default::default(), &armor.available)?;
                let report = crate::passive::rebuild(&edited, &selected)?;
                if method == "armor-compose-export-copy" {
                    export_new(text(p, "path")?, &report.bytes)?;
                }
                let (groups, sources) = self.profiles.counts();
                Ok(
                    json!({"bytes":report.bytes.len(),"applied_groups":report.groups,"applied_sources":report.sources,
                      "configured_groups":groups,"selected_sources":sources,"format":"dl_plain","installed":false}),
                )
            }
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
}
