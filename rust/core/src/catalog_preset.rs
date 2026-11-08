//! Legacy preset identifiers resolve to raw fields before the workspace edit.
use crate::{
    binary::Encoding,
    catalog::{Catalog, Mode, Owner, Row},
    catalog_edit::{Builder, Plan},
    catalog_refs,
    preset::{Preset, Value},
    workspace::Workspace,
};
use std::collections::{BTreeMap, BTreeSet};

type Parts<'a> = BTreeMap<&'a str, Vec<(&'a Row, usize)>>;

fn parts(owner: &Owner) -> Parts<'_> {
    let mut parts = Parts::new();
    for row in &owner.rows {
        for (position, part) in row.parts.iter().enumerate() {
            parts.entry(&part.id).or_default().push((row, position));
        }
    }
    parts
}

fn status_alias(
    catalog: &Catalog,
    workspace: &Workspace,
    owner: &Owner,
    id: &str,
    values: &BTreeMap<&str, f64>,
) -> Result<Option<String>, String> {
    let Some((prefix, effect)) = id
        .strip_suffix("_strength")
        .and_then(|id| id.rsplit_once("status"))
    else {
        return Ok(None);
    };
    let Ok(effect) = effect.parse::<u32>() else {
        return Ok(None);
    };
    if effect == 0 {
        return Ok(None);
    }
    let base = format!("{prefix}slot");
    let slots: Vec<_> = owner
        .rows
        .iter()
        .filter_map(|row| {
            let part = row.parts.first()?;
            (row.choice == "status"
                && matches!(part.id.strip_prefix(&base), Some("1" | "2" | "3" | "4")))
            .then_some(part)
        })
        .collect();
    for mode in [None, Some(Mode::Original), Some(Mode::Current)] {
        let mut matches = BTreeSet::new();
        for slot in &slots {
            let kind = if let Some(mode) = mode {
                catalog
                    .field_value(slot.field, workspace, mode)
                    .ok()
                    .flatten()
            } else {
                values.get(slot.id.as_str()).copied()
            };
            if kind == Some(effect as f64) {
                matches.insert((&slot.id, slot.field));
            }
        }
        if matches.len() > 1 {
            return Err(format!(
                "状态效果 #{effect} 同时匹配多个槽位，请在预设中使用明确的槽位强度编号"
            ));
        }
        if let Some((slot, _)) = matches.first() {
            return Ok(Some(format!("{slot}_strength")));
        }
    }
    Ok(None)
}

fn identify<'a>(
    id: &str,
    owner: &'a Owner,
    parts: &Parts<'a>,
) -> Result<Vec<(&'a Row, usize)>, String> {
    let id = owner.aliases.get(id).map(String::as_str).unwrap_or(id);
    if owner.preset_ambiguous.get(id) == Some(&true) {
        return Err(format!("旧参数 {id} 曾对应多个不同字段"));
    }
    let ids = if parts.contains_key(id) {
        vec![id]
    } else {
        owner
            .legacy
            .get(id)
            .into_iter()
            .flatten()
            .map(String::as_str)
            .collect()
    };
    let mut out = Vec::new();
    for id in ids {
        let Some(matches) = parts.get(id) else {
            return Ok(Vec::new());
        };
        let &(row, position) = &matches[0];
        let field = row.parts[position].field;
        if matches
            .iter()
            .any(|(row, position)| row.parts[*position].field != field)
        {
            return Err(format!(
                "参数 {id} 对应多个不同字段，请在当前版本重新保存预设"
            ));
        }
        out.push((row, position));
    }
    Ok(out)
}

fn supported(row: &Row) -> bool {
    row.unresolved.is_none()
        && !matches!(
            row.choice.as_str(),
            Some("resomode" | "smmode" | "smres" | "grenade")
        )
}

fn scope<'a>(catalog: &'a Catalog, preset: &Preset) -> Result<Vec<&'a Owner>, String> {
    if let Some(weapon) = &preset.weapon {
        return Ok(vec![catalog.owner(weapon)?.1]);
    }
    let enemy = preset.editor.as_deref() == Some("enemy");
    Ok(catalog
        .owners
        .iter()
        .filter(|owner| owner.enemy == enemy)
        .collect())
}

fn validate_status_groups(builder: &Builder<'_>) -> Result<(), String> {
    let mut groups = BTreeMap::new();
    for (&field, &value) in &builder.fields {
        if let Some(binding) = &builder.catalog.bindings[field] {
            for at in &binding.locations {
                if let Some(slot) = catalog_refs::status_slot(at) {
                    let (_, slots) = groups
                        .entry((at.file.as_str(), &at.record))
                        .or_insert_with(|| (at, [None; 4]));
                    slots[slot] = Some(value);
                }
            }
        }
    }
    for (_, (anchor, slots)) in groups {
        let mut location = anchor.clone();
        let mut empty = false;
        for (slot, desired) in slots.into_iter().enumerate() {
            location.relative = 44 + slot * 8;
            let value = match desired {
                Some(value) => value,
                None => builder.workspace.value(&location, &Encoding::U32)?.current,
            };
            let id = catalog_refs::validate_record(builder.workspace, "status", true, value)?;
            if empty && id > 0 {
                return Err("预设的状态效果不能跳过空槽".into());
            }
            empty |= id == 0;
        }
    }
    Ok(())
}

fn record_value(
    builder: &mut Builder<'_>,
    row: &Row,
    field: usize,
    value: f64,
) -> Result<(), String> {
    if let Some((kind, _)) = catalog_refs::namespace(row) {
        catalog_refs::validate_record(builder.workspace, kind, true, value)?;
    }
    if let Some(binding) = &builder.catalog.bindings[field] {
        if !matches!(binding.encoding, Encoding::Demolition) {
            binding.encoding.encode(0, value)?;
        }
    }
    builder.write(field, value)
}

pub(crate) fn prepare(
    catalog: &Catalog,
    workspace: &Workspace,
    preset: &Preset,
    skip_missing: bool,
    replace_pending: bool,
) -> Result<(Plan, Vec<String>), String> {
    let owners = scope(catalog, preset)?;
    let allowed: BTreeSet<_> = owners
        .iter()
        .map(|owner| owner.id.to_ascii_uppercase())
        .collect();
    let mut grouped: BTreeMap<&str, BTreeMap<&str, f64>> = BTreeMap::new();
    let mut warnings = Vec::new();
    for entry in &preset.values {
        if catalog.owner(&entry.owner).is_err() && skip_missing {
            warnings.push(format!(
                "当前版本缺少条目 {} 的参数 {}，已跳过",
                entry.owner, entry.parameter
            ));
            continue;
        }
        if !allowed.contains(&entry.owner) {
            return Err(format!("当前预设范围内没有条目 {}", entry.owner));
        }
        grouped
            .entry(&entry.owner)
            .or_default()
            .insert(&entry.parameter, entry.value);
    }
    let mut builder = Builder::new(catalog, workspace);
    for (owner_id, entries) in grouped {
        let (_, owner) = catalog.owner(owner_id)?;
        let parts = parts(owner);
        let mut explicit = BTreeMap::new();
        let mut derived = Vec::new();
        for (&id, &value) in &entries {
            let alias = status_alias(catalog, workspace, owner, id, &entries)?;
            let matches = identify(alias.as_deref().unwrap_or(id), owner, &parts)?;
            if matches.is_empty() {
                let why = format!("{} 缺少参数 {id}", owner.name);
                if !skip_missing {
                    return Err(why);
                }
                warnings.push(format!("{why}，已跳过"));
                continue;
            }
            for (row, position) in matches {
                if !supported(row) {
                    if skip_missing {
                        warnings.push(format!(
                            "{} 的参数 {id} 需要专用处理，已跳过并保留原预设",
                            owner.name
                        ));
                        continue;
                    }
                    return Err(format!("参数 {id} 需要专用预设处理"));
                }
                let field = row.parts[position].field;
                if explicit
                    .insert(field, (row, value))
                    .is_some_and(|(_, previous)| previous != value)
                {
                    return Err(format!("预设参数 {id} 和其别名指定了不同数值"));
                }
                if position == 0
                    && (row.mult
                        || row.choice == true
                        || (row.choice != serde_json::Value::Null
                            && row.choice != false
                            && !row.each)
                        || (row.lead && row.storage == "flag"))
                {
                    derived.push((row, value));
                }
            }
        }
        for (&field, &(row, value)) in &explicit {
            record_value(&mut builder, row, field, value)?;
        }
        for (row, value) in derived {
            for part in row.parts.iter().skip(1) {
                if explicit.contains_key(&part.field) {
                    continue;
                }
                let target = if row.mult {
                    let original = builder.original(part.field)?;
                    if row.inverse {
                        original / value
                    } else {
                        original * value
                    }
                } else {
                    value
                };
                record_value(&mut builder, row, part.field, target)?;
            }
        }
    }
    if !preset.values.is_empty()
        && builder.fields.is_empty()
        && preset.armor.is_none()
        && preset.texts.is_empty()
    {
        return Err("此预设的数值参数均无法识别，已停止读取以免清空当前修改；请使用原版本重新导出或提供原预设进行核对".into());
    }
    if replace_pending {
        let mut seen = BTreeSet::new();
        for row in owners
            .iter()
            .flat_map(|owner| &owner.rows)
            .filter(|row| supported(row))
        {
            for part in &row.parts {
                if builder.fields.contains_key(&part.field) || !seen.insert(part.field) {
                    continue;
                }
                let current = catalog.field_value(part.field, workspace, Mode::Current);
                let loaded = catalog.field_value(part.field, workspace, Mode::Loaded);
                if let (Ok(Some(current)), Ok(Some(loaded))) = (current, loaded) {
                    if current != loaded {
                        // Only revert edits in this session. An external tool's
                        // already installed values remain the loaded baseline.
                        record_value(&mut builder, row, part.field, loaded)?;
                    }
                }
            }
        }
    }
    validate_status_groups(&builder)?;
    let mut plan = builder.finish()?;
    if let Some(armor) = preset.armor.as_deref() {
        crate::desktop_armor::add_to_plan(workspace, &mut plan.metadata, armor)?;
    }
    if !preset.texts.is_empty()
        || (replace_pending && !workspace.metadata()[crate::desktop_text::STATE].is_null())
    {
        if !plan.metadata.is_object() {
            plan.metadata = serde_json::json!({});
        }
        let state = crate::desktop_text::STATE;
        if replace_pending {
            for owner in &owners {
                if let Some(texts) = plan.metadata[state].as_object_mut() {
                    texts.remove(&owner.id);
                }
            }
        }
        for (owner, fields) in &preset.texts {
            if !owners.iter().any(|o| &o.id == owner && o.text.is_some()) {
                if skip_missing {
                    warnings.push(format!("已跳过无法定位的文字条目 {owner}"));
                    continue;
                }
                return Err(format!("找不到预设文字条目 {owner}"));
            }
            plan.metadata[state][owner] = serde_json::json!(fields);
        }
    }
    workspace.validate_batch(&plan.values)?;
    Ok((plan, warnings))
}

pub(crate) fn export(
    catalog: &Catalog,
    workspace: &Workspace,
    mut preset: Preset,
) -> Result<String, String> {
    let mut seen = BTreeSet::new();
    let mut texts = BTreeMap::new();
    for owner in scope(catalog, &preset)? {
        if let Some(fields) =
            workspace.metadata()[crate::desktop_text::STATE][&owner.id].as_object()
        {
            let fields = fields
                .iter()
                .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_owned())))
                .collect();
            texts.insert(owner.id.clone(), fields);
        }
        let parts = parts(owner);
        for (id, entries) in parts {
            let (row, position) = entries[0];
            let field = row.parts[position].field;
            let current = catalog.field_value(field, workspace, Mode::Current);
            let loaded = catalog.field_value(field, workspace, Mode::Loaded);
            if let (Ok(Some(current)), Ok(Some(loaded))) = (current, loaded) {
                if current == loaded || seen.contains(&field) {
                    continue;
                }
                if !supported(row) || entries.iter().any(|(r, p)| r.parts[*p].field != field) {
                    return Err(format!("无法导出有歧义或需要专用处理的参数 {id}"));
                }
                seen.insert(field);
                preset.values.push(Value {
                    owner: owner.id.to_ascii_uppercase(),
                    parameter: id.into(),
                    value: current,
                });
            }
        }
    }
    preset.texts = texts;
    preset.encode()
}
