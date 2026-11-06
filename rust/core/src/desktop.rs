//! Native implementation of the Flutter data bridge. Stable row keys cross IPC.
use crate::{
    catalog::{Catalog, Mode, Owner, Row},
    catalog_edit, catalog_refs,
    workspace::Workspace,
};
use serde_json::{json, Value};
use std::collections::BTreeSet;

#[derive(Default)]
pub(crate) struct Desktop {
    pub selected: Option<String>,
    pub enemy: bool,
}

pub(crate) fn row<'a>(owner: &'a Owner, id: &Value) -> Result<&'a Row, String> {
    let key = id.as_str().ok_or("参数标识无效")?;
    owner
        .rows
        .iter()
        .find(|r| r.key == key)
        .ok_or_else(|| "找不到当前参数".into())
}

pub(crate) fn number(v: &Value) -> Result<f64, String> {
    let value = v.as_f64().or_else(|| {
        let text = v.as_str()?.trim();
        if let Some(hex) = text.strip_prefix("0x").or_else(|| text.strip_prefix("0X")) {
            u32::from_str_radix(hex, 16).ok().map(f64::from)
        } else {
            text.parse().ok()
        }
    });
    value
        .filter(|v| v.is_finite())
        .ok_or_else(|| "请输入有效的有限数值".into())
}

fn static_choices(kind: &str) -> &'static [(u64, &'static str)] {
    match kind {
        "resomode" => &[(0, "未安装"), (1, "完整（含贴图）"), (3, "移除补丁")],
        "smmode" => &[(0, "未安装"), (1, "写入状态机补丁"), (2, "移除补丁")],
        "holster" => &[(0, "背部"), (1, "腰侧")],
        "pod_twin" => &[(1, "原配：一件"), (2, "双侧投放：两件")],
        "weight" => &[(0, "轻型"), (1, "中型"), (2, "重型")],
        "apex_fire" => &[(2677, "原始开火动作"), (2719, "站立开火")],
        "empty_weapon" => &[(0, "原版：打空丢弃"), (1, "打空后保留")],
        "spear_arc" => &[(0, "原版"), (1, "锁定高抛")],
        "spear_dual" => &[(0, "原版"), (1, "锁定制导／免锁直射")],
        "wasp_burst" => &[
            (0, "原版"),
            (1, "保留弧线，不打转"),
            (2, "收窄散射，不打转"),
        ],
        "slot" => &[(1, "主武器"), (3, "副武器")],
        "mountside" => &[(0, "默认"), (1, "右侧"), (2, "左侧")],
        "faction" => &[
            (0, "默认"),
            (1, "超级地球"),
            (2, "终结族"),
            (4, "机器人"),
            (8, "光能族"),
        ],
        "crosshair" => &[(1, "显示准星"), (2, "隐藏准星")],
        "firemode" => &[
            (0, "空槽（不显示）"),
            (1, "自动"),
            (2, "半自动"),
            (3, "连发"),
            (4, "齐射"),
            (5, "充能"),
            (6, "连发"),
            (7, "特殊模式"),
            (8, "特殊模式"),
        ],
        "fntype" => &[
            (0, "无功能"),
            (2, "射速档位"),
            (3, "射击模式"),
            (4, "双弹药池"),
            (8, "功能 8"),
            (11, "功能 11"),
        ],
        _ => &[],
    }
}

fn choice_name(catalog: &Catalog, row: &Row, value: f64) -> String {
    if !row.recipes.is_empty() && value == 255.0 {
        return "自定义".into();
    }
    if value == 0.0 && catalog_refs::namespace(row).is_some() {
        return "无".into();
    }
    if let Some(link) = catalog_refs::row_link(catalog, row, Some(value)) {
        return link["label"]
            .as_str()
            .map(str::to_owned)
            .unwrap_or_else(|| format!("#{value}"));
    }
    let kind = row.choice.as_str().unwrap_or_default();
    if let Some(label) = catalog
        .registries
        .get(kind)
        .and_then(|r| r.iter().find(|c| c.id as f64 == value))
    {
        return label.label.clone();
    }
    if let Some((_, label)) = static_choices(kind)
        .iter()
        .find(|(id, _)| *id as f64 == value)
    {
        return (*label).into();
    }
    format!("条目 #{value}")
}

pub(crate) fn choices(
    catalog: &Catalog,
    workspace: &Workspace,
    row: &Row,
) -> Result<Value, String> {
    let kind = row.choice.as_str().unwrap_or_default();
    let items = if catalog_refs::namespace(row).is_some() {
        catalog_refs::choices(catalog, workspace, row)?
    } else if kind == "stratagem" {
        crate::extra_stratagem::choices(catalog, workspace, row)?
    } else if let Some(choices) = catalog.registries.get(kind) {
        let field = row.parts.first().map(|p| &catalog.fields[p.field]);
        json!(choices
            .iter()
            .filter(|c| field.is_none_or(|f| f.allowed.is_empty() || f.allowed.contains(&c.id)))
            .map(|c| json!({"id":c.id,"name":c.label,"description":c.note}))
            .collect::<Vec<_>>())
    } else {
        json!(static_choices(kind)
            .iter()
            .map(|(id, label)| json!({"id":id,"label":label}))
            .collect::<Vec<_>>())
    };
    let mut result = items.as_array().cloned().unwrap_or_default();
    if result.is_empty() {
        return Err("当前参数没有可用选项".into());
    }
    for item in &mut result {
        if let Some(why) = item["disabled"].as_str() {
            item["description"] = json!(why);
            item["disabled"] = json!(true);
        }
    }
    Ok(json!(result))
}

fn format_value(row: &Row, value: Option<f64>) -> String {
    let Some(value) = value else {
        return "未知".into();
    };
    if row.code {
        crate::stratagem_code::label(value as u32)
    } else if matches!(row.storage.as_str(), "flag" | "bit") {
        if value == 0.0 { "关" } else { "开" }.into()
    } else {
        value.to_string()
    }
}

pub(crate) fn rows(
    catalog: &Catalog,
    workspace: &Workspace,
    owner: &Owner,
    section: Option<&str>,
    only: Option<&Row>,
) -> Value {
    let affected: BTreeSet<_> = only
        .into_iter()
        .flat_map(|r| r.parts.iter().map(|p| p.field))
        .collect();
    json!(owner.rows.iter().filter(|row| section.is_none_or(|s| row.section == s)
        && (only.is_none() || row.parts.iter().any(|p| affected.contains(&p.field))))
        .map(|row| {
            let current = catalog.row_value(owner,row,workspace,Mode::Current);
            let value = current.as_ref().ok().copied().flatten();
            let original = catalog.row_value(owner,row,workspace,Mode::Original).ok().flatten();
            let loaded = catalog.row_value(owner,row,workspace,Mode::Loaded).ok().flatten();
            let choice = !matches!(row.choice, Value::Null | Value::Bool(false));
            let kind = row.choice.as_str().unwrap_or_default();
            let reference = matches!(kind,"package"|"rackitem"|"mountitem"|"dogweapon"|"dogmag");
            let display = |v: Option<f64>| if reference { v.map_or_else(|| "未知资源引用".into(), |v| choice_name(catalog,row,v)) }
                else { format_value(row,v) };
            json!({"id":row.key,"label":row.label,"section":row.section,"value":value,"original":original,
                "text":format_value(row,value),"default_text":display(original),"loaded_text":display(loaded),
                "code":row.code,"flag":matches!(row.storage.as_str(),"flag"|"bit"),
                "choice":choice,"choice_kind":kind,"choice_name":value.filter(|_|choice).map(|v|choice_name(catalog,row,v)),
                "note":row.note,"inline_note":row.inline_note,"help":row.help,"shared_pending":row.parts.iter().any(|p|catalog.users[p.field].len()>1),
                "reference":reference,"projectile_source":row.choice==true,
                "changed":row.parts.iter().any(|p| catalog.field_edited(p.field, workspace)),
                "error":current.err(),"patch_pending":matches!(kind,"resomode"|"smmode")})
        }).collect::<Vec<_>>())
}

pub(crate) fn pending(catalog: &Catalog, workspace: &Workspace) -> Value {
    let mut checked = BTreeSet::new();
    let mut entries = Vec::new();
    for owner in &catalog.owners {
        for row in &owner.rows {
            for part in &row.parts {
                if !checked.insert(part.field) {
                    continue;
                }
                let before = catalog
                    .field_value(part.field, workspace, Mode::Loaded)
                    .ok()
                    .flatten();
                let after = catalog
                    .field_value(part.field, workspace, Mode::Current)
                    .ok()
                    .flatten();
                if let (Some(before), Some(after)) = (before, after) {
                    if before != after {
                        let file = catalog.bindings[part.field]
                            .as_ref()
                            .and_then(|b| b.locations.first())
                            .map(|a| a.file.as_str());
                        entries.push(json!({"equipment":owner.name,"parameter":row.label,
                            "before":format_value(row,Some(before)),"after":format_value(row,Some(after)),"file":file}));
                    }
                }
            }
        }
    }
    json!(entries)
}

pub(crate) fn items(catalog: &Catalog, workspace: &Workspace, tab: &str, query: &str) -> Value {
    let query = query.trim().to_lowercase();
    let mut changes = vec![None; catalog.fields.len()];
    json!(catalog
        .owners
        .iter()
        .filter(|owner| {
            let category = if owner.player {
                "Helldiver"
            } else {
                &owner.tab
            };
            (tab.is_empty() || category == tab)
                && (query.is_empty()
                    || owner.name.to_lowercase().contains(&query)
                    || owner.english.to_lowercase().contains(&query)
                    || owner.id.to_ascii_lowercase().contains(&query))
        })
        .map(|owner| {
            let changed = owner.rows.iter().any(|r| {
                r.parts.iter().any(|p| {
                    *changes[p.field]
                        .get_or_insert_with(|| catalog.field_edited(p.field, workspace))
                })
            });
            json!({"id":owner.id,"name":owner.name,"english":owner.english,"groups":owner.groups,
            "note":owner.note,"changed":changed})
        })
        .collect::<Vec<_>>())
}

pub(crate) fn apply(
    catalog: &Catalog,
    workspace: &mut Workspace,
    owner: &str,
    key: &str,
    value: Option<f64>,
) -> Result<Value, String> {
    let plan = catalog_edit::prepare(catalog, workspace, owner, key, value)?;
    let mut warnings = crate::extra_stratagem::validate(catalog, workspace, &plan.values)?;
    warnings.extend(catalog.code_overrides(workspace, &plan.metadata)?.1);
    workspace.set_batch(&plan.values, Some(plan.metadata))?;
    Ok(json!({"changes":plan.changes,"warnings":warnings}))
}
