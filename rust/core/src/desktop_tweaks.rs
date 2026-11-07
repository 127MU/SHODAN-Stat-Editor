//! Reversible global switches. Capture the exact values of the fields they own.
use crate::{
    binary::Encoding,
    catalog::Catalog,
    tables::Key,
    workspace::{Location, Record, Workspace},
};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

fn locations(
    catalog: &Catalog,
    w: &Workspace,
    name: &str,
) -> Result<Vec<(Location, Encoding, f64, f64)>, String> {
    if name == "foliage" {
        let mut targets = BTreeSet::new();
        for owner in catalog.owners.iter().filter(|owner| {
            matches!(
                owner.tab.as_str(),
                "Primary" | "Secondary" | "Support" | "Throwables"
            )
        }) {
            for part in owner.rows.iter().flat_map(|row| &row.parts) {
                if let Some(binding) = &catalog.bindings[part.field] {
                    for loc in &binding.locations {
                        if loc.typ == 0xBD4042C2 {
                            let mut target = loc.clone();
                            target.relative = 248;
                            targets.insert(target);
                        }
                    }
                }
            }
        }
        // Retain the version-pinned ordnance targets as well as player bullets.
        for edit in catalog.tweaks.get(name).into_iter().flatten() {
            if let Some(binding) = &catalog.bindings[edit.field] {
                targets.extend(binding.locations.iter().cloned());
            }
        }
        return Ok(targets
            .into_iter()
            .map(|loc| (loc, Encoding::U32, 0.0, 3.0))
            .collect());
    }
    if let Some(edits) = catalog.tweaks.get(name).filter(|e| !e.is_empty()) {
        return Ok(edits
            .iter()
            .flat_map(|edit| {
                let binding = catalog.bindings[edit.field].as_ref().unwrap();
                binding.locations.iter().map(move |loc| {
                    (
                        loc.clone(),
                        binding.encoding.clone(),
                        edit.before,
                        edit.after,
                    )
                })
            })
            .collect());
    }
    let (typ, offset, codec, before, after) = match name {
        "bounce" => (
            0x30EB6399,
            368,
            Encoding::Flag { width: 1, mask: 2 },
            1.0,
            0.0,
        ),
        "reticle" => (0x88E4DBB1, 404, Encoding::U32, 3.0, 0.0),
        "foliage" => (0xBD4042C2, 248, Encoding::U32, 0.0, 3.0),
        _ => return Err("未知游戏参数开关".into()),
    };
    let foliage: BTreeMap<u32, u32> = if name == "foliage" {
        serde_json::from_str(include_str!("foliage_targets.json")).map_err(|_| "射弹配方无效")?
    } else {
        BTreeMap::new()
    };
    let mut result = Vec::new();
    for loc in w.table_locations(typ, |stride| {
        if name == "reticle" && stride == 1232 {
            400
        } else {
            offset
        }
    })? {
        if name == "foliage" {
            let Record::Table(Key::Id(id)) = loc.record else {
                continue;
            };
            let Some(&expected) = foliage.get(&id) else {
                continue;
            };
            if w.table_value(typ, Key::Id(id), 8)? != Some(f64::from(expected)) {
                continue;
            }
        }
        result.push((loc, codec.clone(), before, after));
    }
    Ok(result)
}
fn identity(loc: &Location, codec: &Encoding) -> String {
    let tag = if let Encoding::Flag { width: 4, mask } = codec {
        format!(":{mask}")
    } else {
        String::new()
    };
    format!(
        "{}:{:08x}:{:?}:{}{tag}",
        loc.file, loc.typ, loc.record, loc.relative,
    )
}
fn inferred(catalog: &Catalog, w: &Workspace, name: &str) -> bool {
    catalog.tweaks.get(name).is_some_and(|v| !v.is_empty())
        && locations(catalog, w, name).is_ok_and(|targets| {
            !targets.is_empty()
                && targets.iter().all(|(loc, codec, _, after)| {
                    w.value(loc, codec).is_ok_and(|v| v.current == *after)
                })
        })
}
pub(crate) fn call(catalog: &Catalog, w: &mut Workspace, args: &[Value]) -> Result<Value, String> {
    if let Some(name) = args.first().and_then(Value::as_str) {
        let on = args
            .get(1)
            .and_then(Value::as_bool)
            .ok_or("开关必须为布尔值")?;
        let mut metadata = w.metadata().clone();
        if !metadata.is_object() {
            metadata = json!({});
        }
        let active = metadata["tweaks"][name].as_array();
        let legacy = active.is_none() && inferred(catalog, w, name);
        if on || on != (active.is_some() || legacy) {
            let targets = locations(catalog, w, name)?;
            let mut edits = Vec::new();
            let mut selected = BTreeSet::new();
            let mut found_saved = BTreeSet::new();
            let saved = active
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .collect::<BTreeSet<_>>();
            if on {
                selected.extend(saved.iter().map(|id| (*id).to_string()));
            }
            for (loc, codec, before, after) in targets {
                let current = w.value(&loc, &codec)?.current;
                let id = identity(&loc, &codec);
                if saved.contains(id.as_str()) {
                    found_saved.insert(id.clone());
                    if current != before && current != after {
                        return Err("开关与当前参数值冲突，未覆盖".into());
                    }
                }
                if on && current == before {
                    selected.insert(id);
                    edits.push((loc, codec, after));
                } else if !on && (legacy || saved.contains(id.as_str())) {
                    if current != after && current != before {
                        return Err("开关与当前参数值冲突，未覆盖".into());
                    }
                    selected.insert(id);
                    edits.push((loc, codec, before));
                }
            }
            if on && selected.is_empty() {
                if legacy {
                    return call(catalog, w, &[]);
                }
                return Err("没有适用于当前数据的游戏参数".into());
            }
            if !legacy && found_saved.len() != saved.len() {
                return Err("找不到全部已修改的开关参数，未恢复".into());
            }
            if on {
                metadata["tweaks"][name] = json!(selected);
            } else if let Some(map) = metadata["tweaks"].as_object_mut() {
                map.remove(name);
            }
            w.set_batch(&edits, Some(metadata))?;
        }
    }
    Ok(json!(["bounce", "reticle", "foliage", "vehicles"]
        .into_iter()
        .map(|name| (
            name,
            w.metadata()["tweaks"][name].is_array() || inferred(catalog, w, name)
        ))
        .collect::<BTreeMap<_, _>>()))
}
