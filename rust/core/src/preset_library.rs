//! Named, portable multi-owner preset bundles. Stable owner IDs travel with data.
use crate::{
    catalog::Catalog, catalog_preset, desktop_presets, game_workspace, hash, install,
    preset::Preset, workspace::Workspace,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{collections::BTreeMap, fs};
const HEADER: &str = "SHODAN-SHARE 1\n";
#[derive(Clone, Deserialize, Serialize)]
struct Bundle {
    name: String,
    presets: Vec<String>,
}
#[derive(Deserialize, Serialize)]
struct Document {
    format: String,
    version: u32,
    groups: Vec<Bundle>,
}
fn encode(groups: Vec<Bundle>) -> Result<String, String> {
    let doc = Document {
        format: "SHODAN-PRESET-LIBRARY".into(),
        version: 1,
        groups,
    };
    Ok(format!(
        "{HEADER}{}\n",
        serde_json::to_string_pretty(&doc).map_err(|_| "无法导出预设")?
    ))
}
fn parse(text: &str, catalog: &Catalog) -> Result<Vec<Bundle>, String> {
    if text.len() > 8 * 1024 * 1024 {
        return Err("预设文本超过 8 MB".into());
    }
    let text = text.trim_start_matches('\u{feff}').trim();
    let groups = if text.starts_with("SHODAN-PRESET 1") || text.starts_with("SSEO-") {
        let p = if text.starts_with("SSEO-") {
            crate::preset_code::decode(catalog, text)?.0
        } else {
            Preset::decode(text)?
        };
        vec![Bundle {
            name: p.name.clone(),
            presets: vec![p.encode()?],
        }]
    } else {
        let body = text
            .strip_prefix("SHODAN-SHARE 1\r\n")
            .or_else(|| text.strip_prefix(HEADER))
            .unwrap_or(text);
        let doc: Document =
            serde_json::from_str(body).map_err(|_| "不是支持的预设 TXT、JSON 或分享码")?;
        if doc.format != "SHODAN-PRESET-LIBRARY" || doc.version != 1 {
            return Err("预设文件版本不受支持".into());
        }
        doc.groups
    };
    if groups.is_empty() || groups.len() > 500 {
        return Err("预设数量必须为 1–500".into());
    }
    let mut total = 0;
    for group in &groups {
        if group.name.trim().is_empty()
            || group.name.len() > 384
            || group.name.chars().any(char::is_control)
            || group.presets.is_empty()
        {
            return Err("预设名称或内容无效".into());
        }
        total += group.presets.len();
        if total > 2500 {
            return Err("预设包含过多条目".into());
        }
        for raw in &group.presets {
            Preset::decode(raw)?;
        }
    }
    Ok(groups)
}
fn id(bundle: &Bundle) -> String {
    hash::sha256_hex(serde_json::to_string(bundle).unwrap().as_bytes())
}
fn stored() -> Result<BTreeMap<String, Bundle>, String> {
    let path = game_workspace::profile().join("preset-library.json");
    match fs::read(&path) {
        Ok(bytes) if bytes.len() <= 32 * 1024 * 1024 => {
            serde_json::from_slice(&bytes).map_err(|_| "预设库损坏，已保留原文件".into())
        }
        Ok(_) => Err("预设库超过 32 MB".into()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(BTreeMap::new()),
        Err(_) => Err("无法读取预设库".into()),
    }
}
fn save(store: &BTreeMap<String, Bundle>) -> Result<(), String> {
    let profile = game_workspace::profile();
    fs::create_dir_all(&profile).map_err(|_| "无法创建预设目录")?;
    let _lock = install::lock_transaction(&profile)?;
    let bytes = serde_json::to_vec(store).map_err(|_| "预设保存失败")?;
    if bytes.len() > 32 * 1024 * 1024 {
        return Err("预设库超过 32 MB".into());
    }
    install::save_atomic(&profile.join("preset-library.json"), &bytes)
}
fn all() -> Result<BTreeMap<String, Bundle>, String> {
    let mut result = stored()?;
    for (key, raw) in desktop_presets::saved_presets()? {
        let p = Preset::decode(&raw)?;
        result.insert(
            format!("legacy:{key}"),
            Bundle {
                name: p.name,
                presets: vec![raw],
            },
        );
    }
    Ok(result)
}
fn summary(bundle: &Bundle, catalog: &Catalog) -> Result<Value, String> {
    let mut targets = BTreeMap::new();
    let mut count = 0;
    for raw in &bundle.presets {
        let p = Preset::decode(raw)?;
        count += p.values.len();
        let owners = p
            .weapon
            .iter()
            .chain(p.values.iter().map(|v| &v.owner))
            .chain(p.texts.keys());
        for owner in owners {
            let owner = catalog.owner(owner)?.1;
            targets.insert(owner.id.clone(), owner.name.clone());
        }
    }
    Ok(
        json!({"name":bundle.name,"count":count,"targets":targets.values().collect::<Vec<_>>(),"owners":targets.keys().collect::<Vec<_>>()}),
    )
}
// Merge only metadata differences. Two distinct incoming values on the same
// virtual/shared field are rejected before changing the workspace.
fn merge(base: &Value, incoming: &Value, output: &mut Value) -> Result<(), String> {
    if incoming == base {
        return Ok(());
    }
    if let Some(object) = incoming.as_object() {
        if !output.is_object() {
            if output != base {
                return Err("预设包含冲突的共享配置".into());
            }
            *output = json!({});
        }
        for (key, value) in object {
            merge(&base[key], value, &mut output[key])?;
        }
        if let Some(old) = base.as_object() {
            for key in old.keys().filter(|key| !object.contains_key(*key)) {
                if output[key] != base[key] && !output[key].is_null() {
                    return Err("预设包含冲突的共享配置".into());
                }
                output.as_object_mut().unwrap().remove(key);
            }
        }
        Ok(())
    } else if output == base || output == incoming {
        *output = incoming.clone();
        Ok(())
    } else {
        Err("预设包含冲突的共享配置".into())
    }
}
fn review(
    groups: &[Bundle],
    catalog: &Catalog,
    workspace: &mut Workspace,
    apply: bool,
) -> Result<Value, String> {
    let base = workspace.metadata().clone();
    let mut metadata = base.clone();
    let mut values = Vec::new();
    let mut entries = Vec::new();
    let mut warnings = Vec::new();
    let mut summaries = Vec::new();
    for group in groups {
        summaries.push(summary(group, catalog)?);
        for raw in &group.presets {
            let p = Preset::decode(raw)?;
            let (plan, notes) = catalog_preset::prepare(catalog, workspace, &p, false, false)?;
            merge(&base, &plan.metadata, &mut metadata)?;
            values.extend(plan.values);
            warnings.extend(notes);
            entries.extend(plan.changes.as_array().into_iter().flatten().map(|change|
                json!({"equipment":group.name,"parameter":change["field"],"before":change["before"],"after":change["after"]})));
        }
    }
    workspace.validate_batch(&values)?;
    warnings.extend(crate::extra_stratagem::validate(
        catalog, workspace, &values,
    )?);
    warnings.extend(catalog.code_overrides(workspace, &metadata)?.1);
    if apply {
        workspace.set_batch(&values, Some(metadata))?;
    }
    Ok(
        json!({"entries":entries,"groups":summaries,"warnings":warnings,"problems":[],"applied":apply}),
    )
}
pub(crate) fn invoke(
    catalog: &Catalog,
    workspace: &mut Workspace,
    method: &str,
    args: &[Value],
) -> Result<Value, String> {
    let arg = |i| args.get(i).unwrap_or(&Value::Null);
    let text = || arg(0).as_str().ok_or("缺少预设文本或标识");
    let mut store = stored()?;
    match method {
        "library_join" => {
            let inputs = arg(0).as_array().ok_or("缺少预设文件文本")?;
            let mut groups = Vec::new();
            let mut bytes = 0;
            for input in inputs {
                let input = input.as_str().ok_or("预设文本无效")?;
                bytes += input.len();
                if bytes > 8 * 1024 * 1024 {
                    return Err("预设文本合计超过 8 MB".into());
                }
                groups.extend(parse(input, catalog)?);
            }
            let text = encode(groups)?;
            parse(&text, catalog)?;
            Ok(json!(text))
        }
        "library_list" => {
            let mut list = Vec::new();
            for (key, bundle) in all()? {
                let mut row = summary(&bundle, catalog)?;
                row["id"] = json!(key);
                list.push(row);
            }
            Ok(json!(list))
        }
        "library_export" => {
            let entries = all()?;
            let groups = if arg(0).is_null() {
                entries.into_values().collect()
            } else {
                vec![entries.get(text()?).ok_or("找不到预设")?.clone()]
            };
            Ok(json!(encode(groups)?))
        }
        "library_capture" => {
            let name = text()?.trim();
            if name.is_empty() || name.len() > 384 || name.chars().any(char::is_control) {
                return Err("请输入有效的预设名称".into());
            }
            let mut presets = Vec::new();
            if let Some(ids) = arg(1).as_array() {
                if ids.is_empty() || ids.len() > 2000 {
                    return Err("请至少选择一个条目".into());
                }
                let mut seen = std::collections::BTreeSet::new();
                for requested in ids {
                    let owner = catalog.owner(requested.as_str().ok_or("条目标识无效")?)?.1;
                    if !seen.insert(owner.id.clone()) {
                        continue;
                    }
                    presets.push(catalog_preset::export_for_share(
                        catalog,
                        workspace,
                        desktop_presets::preset(owner.name.clone(), owner.enemy, Some(&owner.id)),
                    )?);
                }
            } else {
                for enemy in [false, true] {
                    let mut p = Preset::decode(&catalog_preset::export_for_share(
                        catalog,
                        workspace,
                        desktop_presets::preset(name.into(), enemy, None),
                    )?)?;
                    if !enemy {
                        p.armor = Some(crate::desktop_armor::capture(workspace)?);
                    }
                    if !p.values.is_empty() || !p.texts.is_empty() || p.armor.is_some() {
                        presets.push(p.encode()?);
                    }
                }
            }
            let bundle = Bundle {
                name: name.into(),
                presets,
            };
            review(std::slice::from_ref(&bundle), catalog, workspace, false)?;
            let key = id(&bundle);
            store.insert(key.clone(), bundle.clone());
            save(&store)?;
            Ok(json!({"id":key,"text":encode(vec![bundle])?,"message":"预设已保存到预设库"}))
        }
        "library_preview" | "library_import" | "library_load" => {
            let entries = all()?;
            let groups = if let Some(bundle) = entries.get(text()?) {
                vec![bundle.clone()]
            } else {
                parse(text()?, catalog)?
            };
            let mut result = if method == "library_load" {
                review(&groups, catalog, workspace, true)?
            } else {
                let mut entries = Vec::new();
                let mut summaries = Vec::new();
                let mut warnings = Vec::new();
                for group in &groups {
                    let r = review(std::slice::from_ref(group), catalog, workspace, false)?;
                    entries.extend(r["entries"].as_array().unwrap().clone());
                    summaries.extend(r["groups"].as_array().unwrap().clone());
                    warnings.extend(r["warnings"].as_array().unwrap().clone());
                }
                json!({"entries":entries,"groups":summaries,"warnings":warnings,"problems":[],"applied":false})
            };
            if method == "library_import" {
                let mut selected = String::new();
                for bundle in &groups {
                    selected = id(bundle);
                    store.insert(selected.clone(), bundle.clone());
                }
                save(&store)?;
                result["selected"] = json!(selected);
                result["message"] =
                    json!(format!("已导入 {} 组预设，保留原自定义名称", groups.len()));
            }
            Ok(result)
        }
        "library_rename" => {
            let key = text()?;
            let name = arg(1).as_str().ok_or("请输入预设名称")?.trim();
            if name.is_empty() || name.len() > 384 || name.chars().any(char::is_control) {
                return Err("请输入有效的预设名称".into());
            }
            store
                .get_mut(key)
                .ok_or("该预设是旧版槽位预设，请在原页面重命名")?
                .name = name.into();
            save(&store)?;
            Ok(json!("预设名称已保存"))
        }
        "library_delete" => {
            let key = text()?;
            if key.starts_with("legacy:") {
                return Err("旧版槽位预设请在原装备预设或全局预设中删除".into());
            }
            store.remove(key).ok_or("找不到预设")?;
            save(&store)?;
            Ok(json!("预设已删除"))
        }
        _ => Err("不支持的预设库操作".into()),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn metadata_merge_preserves_unrelated_values_and_rejects_conflicts() {
        let base = json!({"virtual":{"one":1},"other":5});
        let mut output = base.clone();
        merge(&base, &json!({"virtual":{"one":2},"other":5}), &mut output).unwrap();
        merge(
            &base,
            &json!({"virtual":{"one":1,"two":3},"other":5}),
            &mut output,
        )
        .unwrap();
        assert_eq!(output, json!({"virtual":{"one":2,"two":3},"other":5}));
        assert!(merge(&base, &json!({"virtual":{"one":4},"other":5}), &mut output).is_err());
    }
}
