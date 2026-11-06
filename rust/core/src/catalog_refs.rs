//! Record choices and the reference graph read the same pending bytes as the editor.
use crate::{
    binary::Encoding,
    catalog::{Catalog, Mode, Owner, Row},
    references,
    tables::Key,
    workspace::{Location, Record, Workspace},
};
use serde_json::{json, Value};

const DAMAGE: u32 = 0xE0A72CF0;

pub(crate) fn namespace(row: &Row) -> Option<(&'static str, bool)> {
    match row.choice.as_str() {
        Some("explosion") => Some(("blast", true)),
        Some("shrapnel") => Some(("shot", true)),
        Some("status" | "heat_status") => Some(("status", true)),
        _ if row.choice == true => Some(("shot", false)),
        _ => None,
    }
}

pub(crate) fn status_slot(location: &Location) -> Option<usize> {
    if location.typ == DAMAGE
        && matches!(location.record, Record::Table(Key::Id(_)))
        && (44..=68).contains(&location.relative)
        && (location.relative - 44) % 8 == 0
    {
        Some((location.relative - 44) / 8)
    } else {
        None
    }
}

pub(crate) fn status_neighbor(
    workspace: &Workspace,
    location: &Location,
    target: u32,
) -> Result<(), String> {
    let slot = status_slot(location).ok_or("状态效果槽绑定无效")?;
    let mut neighbor = location.clone();
    if target > 0 && slot > 0 {
        neighbor.relative -= 8;
        if workspace.value(&neighbor, &Encoding::U32)?.current == 0.0 {
            return Err(format!("请先选择第 {slot} 槽的状态效果"));
        }
    } else if target == 0 && slot < 3 {
        neighbor.relative += 8;
        if workspace.value(&neighbor, &Encoding::U32)?.current != 0.0 {
            return Err(format!("请先清空第 {} 槽的状态效果", slot + 2));
        }
    }
    Ok(())
}

pub(crate) fn validate_record(
    workspace: &Workspace,
    kind: &str,
    allow_zero: bool,
    value: f64,
) -> Result<u32, String> {
    if value.fract() != 0.0 || !(0.0..=u32::MAX as f64).contains(&value) {
        return Err("请输入有效的记录编号".into());
    }
    let id = value as u32;
    if id == 0 && allow_zero {
        return Ok(id);
    }
    let typ = references::kind(kind).ok_or("未知引用命名空间")?;
    if id == 0 || workspace.table_value(typ, Key::Id(id), 0)?.is_none() {
        return Err(format!("当前游戏数据没有该记录 #{id}"));
    }
    Ok(id)
}

pub(crate) fn status_strength(id: u32) -> f64 {
    match id {
        5 | 6 => 3.0,
        33 | 39 => 50.0,
        38 => 10.0,
        40 => 25.0,
        43 | 45 => 100.0,
        _ => 1.0,
    }
}

fn record_owner_id(kind: &str, id: u32) -> Option<String> {
    let prefix = match kind {
        "shot" => "F1",
        "blast" => "F2",
        "status" => "F3",
        "arc" => "F4",
        _ => return None,
    };
    Some(format!("{prefix}{id:014X}"))
}

pub(crate) fn record_owner<'a>(catalog: &'a Catalog, kind: &str, id: u32) -> Option<&'a Owner> {
    catalog
        .owner(&record_owner_id(kind, id)?)
        .ok()
        .map(|(_, owner)| owner)
}

pub(crate) fn row_link(catalog: &Catalog, row: &Row, value: Option<f64>) -> Option<Value> {
    let (kind, _) = namespace(row)?;
    let id = value.filter(|v| (1.0..=u32::MAX as f64).contains(v))? as u32;
    let owner = record_owner(catalog, kind, id);
    Some(json!({"kind":kind,"id":id,"owner":owner.map(|o| &o.id),"label":owner.map(|o| &o.name)}))
}

fn status_locations<'a>(catalog: &'a Catalog, row: &Row) -> Result<&'a [Location], String> {
    let field = row.parts.first().ok_or("状态效果槽没有绑定字段")?.field;
    let locations = &catalog.bindings[field]
        .as_ref()
        .ok_or("状态效果槽没有绑定")?
        .locations;
    if locations.is_empty() || locations.iter().any(|at| status_slot(at).is_none()) {
        return Err("状态效果槽绑定无效".into());
    }
    Ok(locations)
}

pub(crate) fn choices(
    catalog: &Catalog,
    workspace: &Workspace,
    row: &Row,
) -> Result<Value, String> {
    let (kind, mut allow_zero) = namespace(row).ok_or("该参数没有记录选择列表")?;
    allow_zero |= row.parts.iter().any(|p| {
        let field = &catalog.fields[p.field];
        field.switch.is_some() || field.toggle.is_some()
    });
    let typ = references::kind(kind).ok_or("未知引用命名空间")?;
    let mut ids = workspace.table_ids(typ)?;
    if ids.is_empty() {
        return Err("当前工作区没有载入所需的记录表".into());
    }
    ids.retain(|id| *id != 0);
    if allow_zero {
        ids.insert(0, 0);
    }
    let status = if row.choice == "status" {
        Some(status_locations(catalog, row)?)
    } else {
        None
    };
    let mut items = Vec::with_capacity(ids.len());
    for id in ids {
        let record = record_owner(catalog, kind, id);
        let label = match (id, record) {
            (0, _) => "无".into(),
            (_, Some(owner)) => owner.name.clone(),
            _ => format!("记录 #{id}"),
        };
        let disabled = status.and_then(|locations| {
            locations
                .iter()
                .find_map(|at| status_neighbor(workspace, at, id).err())
        });
        items.push(json!({"id":id,"label":label,"owner":record.map(|o|&o.id),"disabled":disabled}));
    }
    Ok(json!(items))
}

pub(crate) fn graph(
    catalog: &Catalog,
    workspace: &Workspace,
    owner: &Owner,
) -> Result<Value, String> {
    let mut roots = Vec::new();
    // A record page has a natural root. Equipment rows read delta-backed
    // projectile choices too, where an entity's nominal fire mode is insufficient.
    if owner.tab == "Records" {
        let (prefix, digits) = owner.id.split_at(2);
        let kind = match prefix {
            "F1" => Some("shot"),
            "F2" => Some("blast"),
            "F3" => Some("status"),
            "F4" => Some("arc"),
            _ => None,
        };
        if let (Some(kind), Ok(id)) = (kind, u32::from_str_radix(digits, 16)) {
            roots.push((kind.into(), id, "当前记录".into()));
        }
    }
    if roots.is_empty() {
        let mut bound_fire_modes = false;
        for row in &owner.rows {
            if row.choice == "heat_status" {
                if let Some(id) = catalog
                    .row_value(owner, row, workspace, Mode::Current)?
                    .filter(|id| *id > 0.0)
                {
                    roots.push(("status".into(), id as u32, row.label.clone()));
                }
            }
            if row.choice != true {
                continue;
            }
            bound_fire_modes = true;
            if let Some(id) = catalog.row_value(owner, row, workspace, Mode::Current)? {
                if id > 0.0 {
                    roots.push(("shot".into(), id as u32, row.label.clone()));
                }
            }
        }
        if let Some(key) = owner.native_key.as_deref() {
            let key = u64::from_str_radix(key, 16).map_err(|_| "装备原生身份无效")?;
            roots.extend(references::roots(bound_fire_modes, |typ, offset| {
                workspace.table_value(typ, Key::Hash(key), offset)
            })?);
        }
    }
    let mut graph = references::graph(&roots, |typ, id, offset| {
        workspace.table_value(typ, Key::Id(id), offset)
    })?;
    if let Some(entries) = graph["entries"].as_array_mut() {
        for entry in entries {
            let record = entry["kind"]
                .as_str()
                .zip(entry["id"].as_u64())
                .and_then(|(kind, id)| record_owner(catalog, kind, id as u32));
            if let Some(record) = record {
                entry["owner"] = json!(record.id);
                entry["label"] = json!(record.name);
                entry["record_hash"] = json!(record.id);
                entry["title"] = json!(record.name);
            }
        }
    }
    Ok(graph)
}
