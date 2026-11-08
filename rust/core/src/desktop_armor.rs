//! Armor selections, numeric overrides and equipment presets share the workspace.
use crate::{
    armor::Armor,
    armor_profiles::{Group, Profiles, EVERY},
    baseline::Baseline,
    catalog::Catalog,
    passive::{self, Policy},
    workspace::Workspace,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

pub(crate) const PASSIVE: &str = "generated_customization_passive_bonuses.dl_bin";
pub(crate) const KITS: &str = "generated_customization_armor_sets.dl_bin";
const STATE: &str = "armor";
pub(crate) const REAPPLY: &str = "repair_pending_armor";
pub(crate) fn needs_reapply(workspace: &Workspace) -> bool {
    workspace.metadata()[REAPPLY] == true || workspace.loaded_metadata()[REAPPLY] == true
}
pub(crate) const BASELINE: &[u8] = include_bytes!("../data/armor-baseline.bin");

#[derive(Default, Deserialize, Serialize)]
pub(crate) struct State {
    numeric: Option<String>,
    profiles: String,
    assigned: BTreeMap<u32, Vec<u32>>,
}

fn integer(v: &Value) -> Result<u32, String> {
    v.as_u64()
        .and_then(|v| u32::try_from(v).ok())
        .ok_or_else(|| "被动编号无效".into())
}

fn state(workspace: &Workspace) -> Result<State, String> {
    if workspace.metadata()[STATE].is_null() {
        Ok(State::default())
    } else {
        serde_json::from_value(workspace.metadata()[STATE].clone())
            .map_err(|_| "护甲会话状态无效".into())
    }
}

fn armor(workspace: &Workspace, settings: &State) -> Result<Armor, String> {
    let current = workspace.rendered(PASSIVE)?;
    armor_from(workspace, settings, current)
}

fn armor_from(workspace: &Workspace, settings: &State, current: Vec<u8>) -> Result<Armor, String> {
    let baseline = Baseline::shipped(
        "generated_customization_passive_bonuses.dl_plain",
        workspace
            .original_snapshot(PASSIVE)
            .ok_or("缺少当前版本的可信护甲原值")?
            .to_vec(),
    )?;
    let mut armor = Armor::new(current, baseline)?;
    if let Some(numeric) = &settings.numeric {
        armor.apply_snapshot(numeric)?;
    }
    Ok(armor)
}

fn profiles(settings: &State, available: &BTreeSet<u32>) -> Result<Profiles, String> {
    let parsed = Profiles::parse(&settings.profiles, available)?;
    if !parsed.warnings.is_empty() {
        return Err("护甲组合包含不适用于此版本的被动".into());
    }
    Ok(parsed.profiles)
}

fn store(metadata: &mut Value, armor: State) -> Result<(), String> {
    if !metadata.is_object() {
        *metadata = json!({});
    }
    metadata[STATE] = serde_json::to_value(armor).map_err(|_| "护甲状态编码失败")?;
    Ok(())
}

pub(crate) fn capture(workspace: &Workspace) -> Result<String, String> {
    let mut settings = state(workspace)?;
    settings.numeric = Some(armor(workspace, &settings)?.capture()?);
    serde_json::to_string(&settings).map_err(|_| "无法导出护甲预设".into())
}

pub(crate) fn legacy(
    workspace: &Workspace,
    root: &Path,
    config: &str,
    metadata: &mut Value,
) -> Result<Vec<String>, String> {
    let mut settings = state(workspace)?;
    let mut armor = armor(workspace, &settings)?;
    let mut warnings = Vec::new();
    if let Some(text) = super::desktop_presets::read_text(&root.join("armory.ini"), 1024 * 1024)? {
        let parsed = Profiles::parse(&text, &armor.available)?;
        warnings.extend(parsed.warnings);
        settings.profiles = parsed.profiles.encode(&armor.available)?;
    }
    if let Some(text) =
        super::desktop_presets::read_text(&root.join("armory-values.txt"), 1024 * 1024)?
    {
        let text = text.replace("\r\n", "\n");
        let lines = text
            .strip_prefix("AFUI1\n")
            .ok_or("旧护甲数值文件格式无效")?;
        for line in lines.lines().filter(|l| !l.is_empty()) {
            let mut words = line.split_ascii_whitespace();
            let (Some(key), Some(base), Some(value), None) =
                (words.next(), words.next(), words.next(), words.next())
            else {
                warnings.push("已跳过格式无效的旧护甲数值".into());
                continue;
            };
            let expected = base.parse::<f32>().ok().filter(|n| n.is_finite());
            let value = value.parse::<f64>().ok().filter(|n| n.is_finite());
            if expected.is_none()
                || armor.rows.get(key).and_then(|row| row.original) != expected
                || value.is_none_or(|value| armor.set(key, value).is_err())
            {
                warnings.push(format!("已跳过与当前版本不符的旧护甲参数 {key}"));
            }
        }
        settings.numeric = Some(armor.capture()?);
    }
    let available = kit_passives(&workspace.rendered(KITS)?)?;
    for line in config.lines() {
        let Some(line) = line
            .split('#')
            .next()
            .unwrap_or("")
            .trim()
            .strip_prefix("armor_passive ")
        else {
            continue;
        };
        let Some((name, ids)) = line.split_once(' ') else {
            continue;
        };
        let Ok(id) = u32::from_str_radix(name, 16) else {
            continue;
        };
        let ids = ids.trim();
        let list = if ids == "none" {
            Some(Vec::new())
        } else {
            ids.split(',').map(|v| v.parse::<u32>().ok()).collect()
        };
        if let Some(list) = list.filter(|list| {
            available.contains_key(&id) && validate_list(list, &armor.available).is_ok()
        }) {
            settings.assigned.insert(id, list);
        } else {
            warnings.push(format!("已跳过旧护甲组合 #{id}"));
        }
    }
    if settings.numeric.is_some() || !settings.profiles.is_empty() || !settings.assigned.is_empty()
    {
        store(metadata, settings)?;
    }
    Ok(warnings)
}

fn label(id: u32) -> String {
    crate::armor::catalog()["list"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|item| item["id"].as_u64() == Some(u64::from(id)))
        .and_then(|item| item["zh"].as_str())
        .map(str::to_owned)
        .unwrap_or_else(|| format!("被动 #{id}"))
}

pub(crate) fn preview(workspace: &Workspace) -> Result<Vec<Value>, String> {
    if workspace.metadata()[STATE] == workspace.loaded_metadata()[STATE]
        && !needs_reapply(workspace)
    {
        return Ok(Vec::new());
    }
    let current = state(workspace)?;
    let active = armor(workspace, &current)?;
    let before: State = if workspace.loaded_metadata()[STATE].is_null() {
        State::default()
    } else {
        serde_json::from_value(workspace.loaded_metadata()[STATE].clone())
            .map_err(|_| "已安装护甲配置无效")?
    };
    let previous = armor(workspace, &before)?;
    let mut entries = Vec::new();
    if needs_reapply(workspace) {
        entries.push(json!({"equipment":"护甲配置","parameter":"修复后重新应用",
            "before":"已恢复安装前文件","after":"重新写入当前护甲配置","file":PASSIVE}));
    }
    for row in active.rows.values() {
        let from = previous.value(&row.key)?;
        let to = active.value(&row.key)?;
        if from != to {
            entries.push(json!({"equipment":label(row.passive),"parameter":row.label,
                "before":from,"after":to,"file":PASSIVE}));
        }
    }
    let from = profiles(&before, &active.available)?;
    let to = profiles(&current, &active.available)?;
    for id in from
        .groups
        .keys()
        .chain(to.groups.keys())
        .copied()
        .collect::<BTreeSet<_>>()
    {
        let describe = |group: Option<&Group>| {
            let Some(group) = group else {
                return "游戏原有被动".to_owned();
            };
            if group.profile.own && group.profile.enabled.is_empty() {
                return "游戏原有被动".to_owned();
            }
            format!(
                "{}原生被动 · {} · {}",
                if group.profile.own {
                    "保留"
                } else {
                    "移除"
                },
                group
                    .profile
                    .enabled
                    .iter()
                    .map(|&id| label(id))
                    .collect::<Vec<_>>()
                    .join("、"),
                if group.profile.policy == Policy::Strongest {
                    "保留最强"
                } else {
                    "叠加"
                }
            )
        };
        let old = describe(from.groups.get(&id));
        let new = describe(to.groups.get(&id));
        if old != new {
            entries.push(json!({"equipment":"护甲被动组合","parameter":if id==EVERY {"所有护甲".to_owned()} else { label(id) },
                "before":old,"after":new,"file":PASSIVE}));
        }
    }
    Ok(entries)
}

pub(crate) fn add_to_plan(
    workspace: &Workspace,
    metadata: &mut Value,
    preset: &str,
) -> Result<(), String> {
    if preset.len() > 2 * 1024 * 1024 {
        return Err("护甲预设过大".into());
    }
    let settings = if preset.starts_with("AVP1\n") {
        let mut previous = state(workspace)?;
        previous.numeric = Some(preset.into());
        previous
    } else {
        serde_json::from_str(preset).map_err(|_| "护甲预设格式无效")?
    };
    let armor = armor(workspace, &settings)?;
    profiles(&settings, &armor.available)?;
    let kits = kit_passives(&workspace.rendered(KITS)?)?;
    for (&kit, selected) in &settings.assigned {
        if !kits.contains_key(&kit) {
            return Err("预设包含未知护甲".into());
        }
        validate_list(selected, &armor.available)?;
    }
    store(metadata, settings)
}

fn kit_passives(bytes: &[u8]) -> Result<BTreeMap<u32, u32>, String> {
    let mut kits = BTreeMap::new();
    for block in crate::dlbin::index(bytes).map_err(|e| e.to_string())? {
        if block.type_id == crate::arrays::ARMOR_KIT {
            let kit = crate::arrays::Kit::parse(&bytes[block.payload])?;
            if kit.kind == 0 {
                kits.entry(kit.name).or_insert(kit.passive);
            }
        }
    }
    Ok(kits)
}

fn validate_list(selected: &[u32], available: &BTreeSet<u32>) -> Result<(), String> {
    let set: BTreeSet<_> = selected.iter().copied().collect();
    if selected.len() > 14 || selected.len() != set.len() || !set.is_subset(available) {
        return Err("护甲最多允许 14 个不同且有效的被动".into());
    }
    Ok(())
}

pub(crate) fn invoke(
    catalog: &Catalog,
    workspace: &mut Workspace,
    method: &str,
    args: &[Value],
) -> Result<Value, String> {
    let arg = |i| args.get(i).unwrap_or(&Value::Null);
    let mut settings = state(workspace)?;
    let mut armor = armor(workspace, &settings)?;
    let mut profiles = profiles(&settings, &armor.available)?;
    let result = match method {
        "armor_capture" => return Ok(json!(armor.capture()?)),
        "armor_apply" | "armor_compare" | "armor_count" | "armor_validate" => {
            let text = arg(0).as_str().ok_or("缺少护甲数值预设")?;
            let current = armor
                .rows
                .keys()
                .map(|key| armor.value(key).map(|v| (key.clone(), v)))
                .collect::<Result<BTreeMap<_, _>, _>>()?;
            armor.apply_snapshot(text)?;
            if method == "armor_apply" {
                settings.numeric = Some(armor.capture()?);
                json!(true)
            } else {
                let mut entries = Vec::new();
                let mut count = 0;
                for row in armor.rows.values() {
                    let after = armor.value(&row.key)?;
                    let before = current[&row.key];
                    count += usize::from(Some(after) != row.original.map(f64::from));
                    if method == "armor_validate" || before != after {
                        entries.push(json!({"equipment":label(row.passive),"parameter":row.label,
                            "pid":row.passive,"key":row.key,"value":after,"default":row.original,
                            "before":before,"after":after,"file":PASSIVE}));
                    }
                }
                return Ok(if method == "armor_count" {
                    json!(count)
                } else {
                    json!(entries)
                });
            }
        }
        "armor_rows" => {
            let id = integer(arg(0))?;
            return Ok(json!(armor
                .rows
                .values()
                .filter(|row| row.passive == id)
                .map(|row| armor
                    .value(&row.key)
                    .map(|value| json!({"key":row.key,"label":row.label,
                    "value":value,"default":row.original,"original":row.original})))
                .collect::<Result<Vec<_>, _>>()?));
        }
        "armor_set" => {
            let id = integer(arg(0))?;
            let key = arg(1).as_str().ok_or("护甲参数无效")?;
            if armor.rows.get(key).is_none_or(|row| row.passive != id) {
                return Err("护甲参数不属于当前被动".into());
            }
            armor.set(key, crate::desktop::number(arg(2))?)?;
            settings.numeric = Some(armor.capture()?);
            json!(true)
        }
        "armor_profile" | "armor_update" => {
            let target = integer(arg(0))?;
            if target != EVERY && !armor.available.contains(&target) {
                return Err("目标被动不存在".into());
            }
            let mut group = profiles.groups.get(&target).cloned().unwrap_or(Group {
                profile: Default::default(),
                configured: false,
            });
            if method == "armor_profile" {
                let enabled: serde_json::Map<String, Value> = group
                    .profile
                    .enabled
                    .iter()
                    .map(|id| (id.to_string(), json!(true)))
                    .collect();
                return Ok(
                    json!({"own":group.profile.own,"conflicts":if group.profile.policy==Policy::Strongest {
                    "strongest"} else {"stack"},"enabled":enabled,"configured":group.configured}),
                );
            }
            if !arg(1).is_null() {
                let source = integer(arg(1))?;
                if !armor.available.contains(&source) {
                    return Err("来源被动不存在".into());
                }
                group.profile.enabled.retain(|v| *v != source);
                if arg(2).as_bool().ok_or("被动开关无效")? {
                    group.profile.enabled.push(source);
                }
                group.profile.enabled.sort_unstable();
            }
            if let Some(own) = arg(3).as_bool() {
                group.profile.own = own;
            }
            if let Some(policy) = arg(4).as_str() {
                group.profile.policy = match policy {
                    "stack" => Policy::Stack,
                    "strongest" => Policy::Strongest,
                    _ => return Err("被动叠加方式无效".into()),
                };
            }
            group.configured = true;
            profiles.groups.insert(target, group);
            settings.profiles = profiles.encode(&armor.available)?;
            json!(true)
        }
        "armor_item" => {
            let owner = catalog.owner(arg(0).as_str().ok_or("缺少护甲标识")?)?.1;
            let Some(kit) = owner.armor else {
                return Ok(json!({"available":false}));
            };
            let mut modified = false;
            if let Some(items) = arg(1).as_array() {
                let selected = items.iter().map(integer).collect::<Result<Vec<_>, _>>()?;
                validate_list(&selected, &armor.available)?;
                settings.assigned.insert(kit, selected);
                modified = true;
            }
            let default = kit_passives(&workspace.rendered(KITS)?)?
                .get(&kit)
                .copied()
                .ok_or("护甲配置不存在")?;
            let selected = settings.assigned.get(&kit).cloned().unwrap_or_else(|| {
                if default == 0 {
                    Vec::new()
                } else {
                    vec![default]
                }
            });
            let labels = crate::armor::catalog();
            let choices: Vec<_> = labels["list"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|p| {
                    p["id"]
                        .as_u64()
                        .is_some_and(|id| armor.available.contains(&(id as u32)))
                })
                .map(|p| json!({"id":p["id"],"name":p["zh"]}))
                .collect();
            let result = json!({"available":true,"selected":selected,"choices":choices});
            if !modified {
                return Ok(result);
            }
            result
        }
        _ => return Err("未知护甲操作".into()),
    };
    let mut metadata = workspace.metadata().clone();
    store(&mut metadata, settings)?;
    workspace.set_batch(&[], Some(metadata))?;
    Ok(result)
}

fn kit_restore(
    kits: &mut [u8],
    previous: &BTreeMap<u32, Vec<u32>>,
    backup: &[u8],
) -> Result<(), String> {
    let mut old = BTreeMap::<[u32; 3], Vec<u32>>::new();
    for block in crate::dlbin::index(backup).map_err(|e| e.to_string())? {
        if block.type_id == crate::arrays::ARMOR_KIT {
            let kit = crate::arrays::Kit::parse(&backup[block.payload])?;
            if kit.kind == 0 && previous.contains_key(&kit.name) {
                old.entry(kit.identity).or_default().push(kit.passive);
            }
        }
    }
    let mut used = BTreeMap::<[u32; 3], usize>::new();
    for block in crate::dlbin::index(kits).map_err(|e| e.to_string())? {
        if block.type_id == crate::arrays::ARMOR_KIT {
            let kit = crate::arrays::Kit::parse(&kits[block.payload.clone()])?;
            if kit.kind == 0 && previous.contains_key(&kit.name) {
                let n = used.entry(kit.identity).or_default();
                let value = old
                    .get(&kit.identity)
                    .and_then(|ids| ids.get(*n))
                    .ok_or("无法核对原有护甲被动")?;
                kits[block.payload.start + 28..block.payload.start + 32]
                    .copy_from_slice(&value.to_le_bytes());
                *n += 1;
            }
        }
    }
    Ok(())
}

pub(crate) fn prepare(
    workspace: &Workspace,
    backup: impl Fn(&str) -> Result<Option<Vec<u8>>, String>,
) -> Result<(BTreeMap<String, Vec<u8>>, Option<Value>), String> {
    if workspace.metadata()[STATE] == workspace.loaded_metadata()[STATE]
        && !needs_reapply(workspace)
    {
        return Ok((BTreeMap::new(), None));
    }
    let mut settings = state(workspace)?;
    let previous: State = if workspace.loaded_metadata()[STATE].is_null() {
        State::default()
    } else {
        serde_json::from_value(workspace.loaded_metadata()[STATE].clone())
            .map_err(|_| "已安装护甲配置无效")?
    };
    let mut current = workspace.rendered(PASSIVE)?;
    if !previous.profiles.is_empty() || !previous.assigned.is_empty() {
        if let Some(original) = backup(PASSIVE)? {
            current = workspace.rebase_passive_changes(PASSIVE, original)?;
        }
    }
    let armor = armor_from(workspace, &settings, current.clone())?;
    settings.numeric = Some(armor.capture()?);
    let profile = profiles(&settings, &armor.available)?;
    let selection = profile.selection(&BTreeMap::new(), &armor.available)?;
    let mut passives = armor.render(&current)?;
    let mut prepared = BTreeMap::new();
    if !settings.assigned.is_empty() || !previous.assigned.is_empty() {
        let mut kits = workspace.rendered(KITS)?;
        if !previous.assigned.is_empty() {
            if let Some(original) = backup(KITS)? {
                kit_restore(&mut kits, &previous.assigned, &original)?;
            }
        }
        let assigned =
            crate::armor_assign::prepare(&passives, &kits, &settings.assigned, &BTreeMap::new())?;
        passives = assigned.passives;
        prepared.insert(KITS.into(), assigned.armors);
    }
    passives = passive::rebuild(&passives, &selection)?.bytes;
    prepared.insert(PASSIVE.into(), passives);
    let metadata = serde_json::to_value(settings).map_err(|_| "无法保存护甲配置")?;
    Ok((prepared, Some(metadata)))
}
