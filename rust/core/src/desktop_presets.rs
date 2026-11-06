//! Portable numeric and armor presets, with import from existing profile files.
use crate::{
    catalog::Catalog,
    catalog_preset, game_workspace, install,
    preset::{Preset, Value as Parameter},
    workspace::Workspace,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{collections::BTreeMap, fs, path::Path};

const FULL: u8 = 50;

#[derive(Default, Deserialize, Serialize)]
struct Store {
    entries: BTreeMap<String, String>,
}

fn key(enemy: bool, weapon: Option<&str>, slot: u8) -> String {
    if let Some(id) = weapon {
        format!("weapon:{}:{slot}", id.to_ascii_uppercase())
    } else {
        format!("{}:{slot}", if enemy { "enemy" } else { "equipment" })
    }
}

fn slot(v: &Value, maximum: u8) -> Result<u8, String> {
    v.as_u64()
        .and_then(|v| u8::try_from(v).ok())
        .filter(|v| (1..=maximum).contains(v))
        .ok_or_else(|| "预设编号无效".into())
}

fn name(v: &Value) -> Result<String, String> {
    let value = v.as_str().ok_or("缺少预设名称")?.trim();
    if value.is_empty() || value.len() > 96 || value.chars().any(char::is_control) {
        return Err("预设名称无效".into());
    }
    Ok(value.into())
}

pub(crate) fn preset(name: String, enemy: bool, weapon: Option<&str>) -> Preset {
    Preset {
        kind: if weapon.is_some() { "weapon" } else { "full" }.into(),
        editor: weapon
            .is_none()
            .then(|| if enemy { "enemy" } else { "equipment" }.into()),
        name,
        weapon: weapon.map(str::to_ascii_uppercase),
        armor: None,
        description: None,
        texts: Default::default(),
        values: Vec::new(),
    }
}

pub(crate) fn read_text(path: &Path, max: u64) -> Result<Option<String>, String> {
    match fs::metadata(path) {
        Ok(m) if m.is_file() && m.len() <= max => fs::read_to_string(path)
            .map(Some)
            .map_err(|_| "无法读取预设文件".into()),
        Ok(_) => Err("预设文件过大或格式无效".into()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err("无法访问预设文件".into()),
    }
}

fn hex_decode(text: &str) -> Option<String> {
    if text.len() % 2 != 0 || !text.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let bytes = (0..text.len())
        .step_by(2)
        .map(|n| u8::from_str_radix(&text[n..n + 2], 16).ok())
        .collect::<Option<Vec<_>>>()?;
    String::from_utf8(bytes).ok()
}

pub(crate) fn legacy_body(input: &str, mut preset: Preset) -> Result<Preset, String> {
    for line in input.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(name) = line.strip_prefix("name ") {
            preset.name = name.trim().into();
        } else if let Some(desc) = line.strip_prefix("desc ") {
            preset.description = Some(desc.into());
        } else if let Some(armor) = line.strip_prefix("armor ") {
            preset.armor = Some(hex_decode(armor.trim()).ok_or("旧护甲预设编码无效")?);
        } else if let Some(rename) = line.strip_prefix("rename ") {
            let mut parts = rename.splitn(3, ' ');
            let owner = parts.next().ok_or("旧文字缺少条目")?;
            let field = parts.next().ok_or("旧文字缺少字段")?;
            let value = parts.next().ok_or("旧文字缺少内容")?;
            crate::desktop_text::validate(field, value)?;
            preset
                .texts
                .entry(owner.to_ascii_uppercase())
                .or_default()
                .insert(field.into(), value.into());
        } else {
            let mut parts = line.split_whitespace();
            let (Some(owner), Some(parameter), Some(value)) =
                (parts.next(), parts.next(), parts.next())
            else {
                return Err("旧预设参数格式无效".into());
            };
            let value = crate::desktop::number(&json!(value))?;
            preset.values.push(Parameter {
                owner: owner.to_ascii_uppercase(),
                parameter: parameter.into(),
                value,
            });
        }
    }
    Ok(preset)
}

pub(crate) fn migrate_profile(
    catalog: &Catalog,
    workspace: &mut Workspace,
    root: &Path,
) -> Result<Vec<String>, String> {
    let config = read_text(&root.join("config.txt"), 8 * 1024 * 1024)?;
    if config.is_none()
        && !root.join("armory.ini").is_file()
        && !root.join("armory-values.txt").is_file()
    {
        return Ok(Vec::new());
    }
    let config = config.unwrap_or_default();
    workspace.migrate_draft(|workspace| {
        let mut presets = BTreeMap::<String, Preset>::new();
        let mut warnings = Vec::new();
        for line in config.lines() {
            let line = line
                .split('#')
                .next()
                .unwrap_or("")
                .trim()
                .trim_start_matches('\u{feff}');
            if line.is_empty() {
                continue;
            }
            let item = line.strip_prefix("rename ").unwrap_or(line);
            let mut parts = item.splitn(3, char::is_whitespace);
            let (Some(owner), Some(field), Some(raw)) = (parts.next(), parts.next(), parts.next())
            else {
                continue;
            };
            if owner.len() != 16 || !owner.bytes().all(|b| b.is_ascii_hexdigit()) {
                continue;
            }
            let Ok((_, owner)) = catalog.owner(owner) else {
                warnings.push(format!("已跳过当前版本没有的旧条目 {owner}"));
                continue;
            };
            let entry = presets
                .entry(owner.id.clone())
                .or_insert_with(|| preset("旧版配置".into(), owner.enemy, Some(&owner.id)));
            let raw = raw.trim();
            if line.starts_with("rename ") {
                let value = raw.replace("{H}", "#");
                if crate::desktop_text::validate(field, &value).is_ok() {
                    entry
                        .texts
                        .entry(owner.id.clone())
                        .or_default()
                        .insert(field.into(), value);
                } else {
                    warnings.push(format!("已跳过 {} 的无效旧文字字段", owner.name));
                }
            } else if let Ok(value) = raw.parse::<f64>() {
                if value.is_finite() {
                    entry.values.retain(|p| p.parameter != field);
                    entry.values.push(Parameter {
                        owner: owner.id.clone(),
                        parameter: field.into(),
                        value,
                    });
                }
            }
        }
        for (owner, preset) in presets {
            match crate::catalog_preset::prepare(catalog, workspace, &preset, true, false) {
                Ok((plan, notes)) => {
                    let mut extra =
                        crate::extra_stratagem::validate(catalog, workspace, &plan.values)?;
                    warnings.extend(notes);
                    warnings.append(&mut extra);
                    workspace.set_batch(&plan.values, Some(plan.metadata))?;
                }
                Err(error) => warnings.push(format!(
                    "未导入 {} 的旧参数 · {error}",
                    catalog.owner(&owner)?.1.name
                )),
            }
        }
        let mut metadata = workspace.metadata().clone();
        match crate::desktop_armor::legacy(workspace, root, &config, &mut metadata) {
            Ok(notes) => warnings.extend(notes),
            Err(error) => warnings.push(format!("未导入旧护甲配置 · {error}")),
        }
        metadata["legacy_imported"] = serde_json::json!(true);
        workspace.set_batch(&[], Some(metadata))?;
        warnings.sort();
        warnings.dedup();
        Ok(warnings)
    })
}

impl Store {
    fn load(profile: &Path) -> Result<Self, String> {
        if let Some(raw) = read_text(&profile.join("native-presets.json"), 32 * 1024 * 1024)? {
            return serde_json::from_str(&raw).map_err(|_| "预设索引格式无效".into());
        }
        let mut store = Self::default();
        for enemy in [false, true] {
            for slot in 1..=FULL {
                let filename = format!("{}preset_{slot:02}.txt", if enemy { "enemy_" } else { "" });
                if let Some(input) = read_text(&profile.join(filename), 8 * 1024 * 1024)? {
                    if !input.lines().any(|l| l.trim() == "cleared") {
                        if let Ok(value) =
                            legacy_body(&input, preset(format!("预设 {slot}"), enemy, None))
                                .and_then(|p| p.encode())
                        {
                            store.entries.insert(key(enemy, None, slot), value);
                        }
                    }
                }
            }
        }
        let mut weapons: BTreeMap<(String, u8), Preset> = BTreeMap::new();
        if let Some(input) = read_text(&profile.join("weapon_presets.txt"), 8 * 1024 * 1024)? {
            for line in input.lines() {
                let mut parts = line.split_whitespace();
                let (Some(owner), Some(n), Some(parameter)) =
                    (parts.next(), parts.next(), parts.next())
                else {
                    continue;
                };
                let Ok(n) = n.parse::<u8>() else {
                    continue;
                };
                if !(1..=5).contains(&n) || owner.len() != 16 {
                    continue;
                }
                let p = weapons
                    .entry((owner.to_ascii_uppercase(), n))
                    .or_insert_with(|| preset(format!("预设 {n}"), false, Some(owner)));
                if let Some(value) = parts
                    .next()
                    .and_then(|v| crate::desktop::number(&json!(v)).ok())
                {
                    p.values.push(Parameter {
                        owner: owner.to_ascii_uppercase(),
                        parameter: parameter.into(),
                        value,
                    });
                }
            }
        }
        if let Some(input) = read_text(&profile.join("preset_names.txt"), 1024 * 1024)? {
            for line in input.lines() {
                let mut parts = line.split_whitespace();
                if let (Some(owner), Some(n), Some(value)) =
                    (parts.next(), parts.next(), parts.next())
                {
                    if let (Ok(n), Some(value)) = (n.parse::<u8>(), hex_decode(value)) {
                        if let Some(p) = weapons.get_mut(&(owner.to_ascii_uppercase(), n)) {
                            p.name = value;
                        }
                    }
                }
            }
        }
        for ((owner, n), value) in weapons {
            if let Ok(value) = value.encode() {
                store.entries.insert(key(false, Some(&owner), n), value);
            }
        }
        Ok(store)
    }

    fn save(&self, profile: &Path) -> Result<(), String> {
        let bytes = serde_json::to_vec(self).map_err(|_| "预设保存失败")?;
        if bytes.len() > 32 * 1024 * 1024 {
            return Err("已保存的预设过多".into());
        }
        install::save_atomic(&profile.join("native-presets.json"), &bytes)
    }
}

fn review(
    catalog: &Catalog,
    workspace: &mut Workspace,
    text: &str,
    apply: bool,
) -> Result<Value, String> {
    let preset = Preset::decode(text)?;
    let (plan, mut warnings) = catalog_preset::prepare(catalog, workspace, &preset, true, true)?;
    warnings.extend(crate::extra_stratagem::validate(
        catalog,
        workspace,
        &plan.values,
    )?);
    warnings.extend(catalog.code_overrides(workspace, &plan.metadata)?.1);
    if apply {
        workspace.set_batch(&plan.values, Some(plan.metadata))?;
    }
    let entries:Vec<_>=plan.changes.as_array().into_iter().flatten()
        .map(|v|json!({"equipment":preset.name,"parameter":v["field"],"before":v["before"],"after":v["after"]}))
        .collect();
    Ok(json!({"entries":entries,"warnings":warnings,"problems":[]}))
}

pub(crate) fn invoke(
    catalog: &Catalog,
    workspace: &mut Workspace,
    desktop: &crate::desktop::Desktop,
    method: &str,
    args: &[Value],
) -> Result<Value, String> {
    let arg = |i| args.get(i).unwrap_or(&Value::Null);
    let profile = game_workspace::profile();
    fs::create_dir_all(&profile).map_err(|_| "无法创建预设目录")?;
    let _lock = install::lock_transaction(&profile)?;
    let mut store = Store::load(&profile)?;
    let enemy = desktop.enemy;
    if method == "restore_examples" {
        let mut restored = 0;
        for (old_name, name, rules) in [
            ("Default", "默认敌人", &[][..]),
            (
                "Horde",
                "虫潮攻势",
                &[
                    (true, "reinf_budget", 2.0),
                    (true, "reinf_rate", 2.0),
                    (true, "patrol_rate", 2.0),
                    (true, "patrol_max", 2.0),
                    (true, "cap", 1.5),
                    (false, "all_health", 0.8),
                ][..],
            ),
            (
                "Glass Cannon",
                "玻璃大炮",
                &[(false, "all_health", 0.5), (false, "all_damage", 2.0)][..],
            ),
            (
                "Elite",
                "精锐敌人",
                &[
                    (false, "all_health", 1.5),
                    (false, "all_armor", 1.0),
                    (false, "all_damage", 1.25),
                    (false, "all_speed", 1.15),
                    (false, "all_sight", 1.5),
                ][..],
            ),
        ] {
            let mut slot = None;
            for n in 1..=FULL {
                if let Some(text) = store.entries.get(&key(true, None, n)) {
                    let existing = Preset::decode(text)?;
                    if existing.name == old_name || existing.name == name {
                        slot = Some(n);
                        break;
                    }
                }
            }
            let Some(n) = slot
                .or_else(|| (1..=FULL).find(|&n| !store.entries.contains_key(&key(true, None, n))))
            else {
                continue;
            };
            let mut example = preset(name.into(), true, None);
            for &(spawn, parameter, value) in rules {
                for faction in [2, 8, 4] {
                    let owner = format!("FFFFFFF{}{faction:08X}", if spawn { 'C' } else { 'B' });
                    example.values.push(Parameter {
                        owner,
                        parameter: parameter.into(),
                        value,
                    });
                }
            }
            store.entries.insert(key(true, None, n), example.encode()?);
            restored += 1;
        }
        store.save(&profile)?;
        return Ok(json!(format!("已恢复 {restored} 个内置敌人预设")));
    }
    if method == "full_presets" {
        let mut out = Vec::new();
        for n in 1..=FULL {
            if let Some(text) = store.entries.get(&key(enemy, None, n)) {
                let p = Preset::decode(text)?;
                out.push(json!({"id":n,"name":p.name,"description":p.description,"count":p.values.len()}));
            }
        }
        return Ok(json!(out));
    }
    let is_weapon = matches!(method, "preset" | "preset_info") || arg(0) == "weapon";
    let weapon = if is_weapon {
        Some(desktop.selected.as_deref().ok_or("请先选择装备")?)
    } else {
        None
    };
    let max = if is_weapon { 5 } else { FULL };
    let n = if method == "preset_info" || method == "preset_code" {
        slot(arg(0), max)?
    } else if (method == "full_preset" && arg(0) == "new")
        || (matches!(method, "preset_import" | "preset_code_import") && arg(1).is_null())
    {
        (1..=max)
            .find(|&n| !store.entries.contains_key(&key(enemy, weapon, n)))
            .ok_or("预设位置已满")?
    } else {
        slot(arg(1), max)?
    };
    let id = key(enemy, weapon, n);
    let saved = store.entries.get(&id);
    match method {
        "preset_info" => {
            let label = saved
                .map(|s| Preset::decode(s).map(|p| p.name))
                .transpose()?
                .unwrap_or_else(|| format!("预设 {n}"));
            Ok(json!({"saved":saved.is_some(),"name":label}))
        }
        "preset_compare" => review(catalog, workspace, saved.ok_or("找不到预设")?, false),
        "preset_export" => Ok(json!(saved.ok_or("找不到预设")?)),
        "preset_rename" => {
            let mut p = Preset::decode(saved.ok_or("找不到预设")?)?;
            p.name = name(arg(2))?;
            store.entries.insert(id, p.encode()?);
            store.save(&profile)?;
            Ok(json!("预设名称已保存"))
        }
        "preset_description" | "preset_duplicate" => {
            let mut p = Preset::decode(saved.ok_or("找不到预设")?)?;
            let key = if method == "preset_description" {
                let description = arg(2).as_str().ok_or("缺少预设说明")?.trim();
                p.description = (!description.is_empty()).then(|| description.into());
                id
            } else {
                let copy = (1..=max)
                    .find(|&n| !store.entries.contains_key(&key(enemy, weapon, n)))
                    .ok_or("预设位置已满")?;
                p.name = name(arg(2))?;
                key(enemy, weapon, copy)
            };
            store.entries.insert(key, p.encode()?);
            store.save(&profile)?;
            Ok(json!("预设已保存"))
        }
        "preset_code" => Ok(json!(crate::preset_code::encode(
            saved.ok_or("找不到预设")?,
            enemy
        )?)),
        "preset_import" | "preset_code_import" => {
            let (p, skipped) = if method == "preset_code_import" {
                crate::preset_code::decode(catalog, arg(0).as_str().ok_or("缺少分享码")?)?
            } else {
                let raw = arg(2).as_str().ok_or("缺少预设文本")?;
                let p = if raw.starts_with("SHODAN-PRESET 1") {
                    Preset::decode(raw)?
                } else {
                    legacy_body(raw, preset(format!("预设 {n}"), enemy, weapon))?
                };
                (p, 0)
            };
            if p.weapon.as_deref() != weapon
                || (weapon.is_none() && (p.editor.as_deref() == Some("enemy")) != enemy)
            {
                return Err("预设类型与当前编辑页面不匹配".into());
            }
            let raw = p.encode()?;
            review(catalog, workspace, &raw, false)?;
            store.entries.insert(id, raw);
            store.save(&profile)?;
            Ok(json!(if skipped == 0 {
                "预设已导入".into()
            } else {
                format!("预设已导入，跳过 {skipped} 项当前目录不存在的内容")
            }))
        }
        "preset" | "full_preset" => {
            let action = arg(0).as_str().ok_or("缺少预设操作")?;
            match action {
                "load" => {
                    review(catalog, workspace, saved.ok_or("找不到预设")?, true)?;
                    return Ok(json!("已读取预设"));
                }
                "clear" | "delete" => {
                    store.entries.remove(&id);
                }
                "save" | "new" => {
                    let label = if action == "new" {
                        name(arg(2))?
                    } else {
                        saved
                            .map(|s| Preset::decode(s).map(|p| p.name))
                            .transpose()?
                            .unwrap_or_else(|| format!("预设 {n}"))
                    };
                    let mut p = Preset::decode(&catalog_preset::export(
                        catalog,
                        workspace,
                        preset(label, enemy, weapon),
                    )?)?;
                    if let Some(previous) = saved {
                        p.description = Preset::decode(previous)?.description;
                    }
                    if !enemy && weapon.is_none() {
                        p.armor = Some(crate::desktop_armor::capture(workspace)?);
                    }
                    store.entries.insert(id, p.encode()?);
                }
                _ => return Err("未知预设操作".into()),
            }
            store.save(&profile)?;
            Ok(json!("预设已保存"))
        }
        _ => Err("尚未接入该预设操作".into()),
    }
}
