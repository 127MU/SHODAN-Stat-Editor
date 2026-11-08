//! Explicit, previewed cleanup of pre-existing numeric differences. Never
//! promotes modded disk bytes to defaults or writes game files automatically.
use crate::{
    binary::Encoding,
    catalog::{Catalog, Mode},
    workspace::{Location, Workspace},
};
use serde_json::{json, Value};
use std::collections::BTreeSet;

fn numeric(codec: &Encoding) -> bool {
    matches!(
        codec,
        Encoding::Bool
            | Encoding::U8
            | Encoding::U16
            | Encoding::U32
            | Encoding::I32
            | Encoding::F32
            | Encoding::Flag { .. }
    )
}

fn overlaps(a: &Location, aw: usize, b: &Location, bw: usize) -> bool {
    a.file == b.file
        && a.typ == b.typ
        && a.record == b.record
        && a.relative < b.relative.saturating_add(bw)
        && b.relative < a.relative.saturating_add(aw)
}

pub(crate) fn call(
    catalog: &Catalog,
    w: &mut Workspace,
    scope: &str,
    token: Option<&str>,
    selected: Option<&Value>,
) -> Result<Value, String> {
    let protected: Vec<_> = catalog
        .bindings
        .iter()
        .enumerate()
        .filter(|(i, _)| catalog.field_edited(*i, w))
        .filter_map(|(_, binding)| binding.as_ref())
        .flat_map(|b| {
            b.locations
                .iter()
                .map(move |l| (l, b.encoding.width().unwrap_or(usize::MAX)))
        })
        .collect();
    let mut seen = BTreeSet::new();
    let mut physical = BTreeSet::new();
    let mut values = Vec::new();
    let mut value_ids = Vec::new();
    let mut entries = Vec::new();
    let mut preserved = 0;
    let mut skipped = 0;
    for owner in &catalog.owners {
        let category = if owner.player {
            "Helldiver"
        } else {
            owner.tab.as_str()
        };
        if !scope.is_empty() && scope != category {
            continue;
        }
        for row in &owner.rows {
            for part in &row.parts {
                if !seen.insert(part.field) {
                    continue;
                }
                let Some(binding) = &catalog.bindings[part.field] else {
                    continue;
                };
                // Armor modifier arrays can grow or reorder. Their dedicated
                // identity-based armor API owns these values; legacy catalog
                // offsets must never be used for a bulk numeric reset.
                if binding
                    .locations
                    .iter()
                    .any(|l| l.file == crate::desktop_armor::PASSIVE)
                {
                    skipped += 1;
                    continue;
                }
                let (Ok(Some(current)), Ok(Some(original))) = (
                    catalog.field_value(part.field, w, Mode::Current),
                    catalog.field_value(part.field, w, Mode::Original),
                ) else {
                    skipped += 1;
                    continue;
                };
                if current == original {
                    continue;
                }
                let width = binding.encoding.width()?;
                if catalog.field_edited(part.field, w)
                    || binding
                        .locations
                        .iter()
                        .any(|l| protected.iter().any(|(p, pw)| overlaps(l, width, p, *pw)))
                {
                    preserved += 1;
                    continue;
                }
                if !numeric(&binding.encoding) || row.unresolved.is_some() {
                    skipped += 1;
                    continue;
                }
                let mut added = false;
                for loc in &binding.locations {
                    let identity = (loc.clone(), format!("{:?}", binding.encoding));
                    if physical.insert(identity) {
                        // Catalog values may display sentinel f32::MAX as -1.
                        // Restore the authenticated stored value, not that UI
                        // substitute, to reproduce the original binary bytes.
                        let stored_original = w
                            .value(loc, &binding.encoding)?
                            .original
                            .ok_or("所选参数缺少可信的存储原值")?;
                        values.push((loc.clone(), binding.encoding.clone(), stored_original));
                        value_ids.push(catalog.fields[part.field].key.clone());
                        added = true;
                    }
                }
                if added {
                    let (before, after) = if row.parts.len() == 1 {
                        (
                            catalog
                                .row_value(owner, row, w, Mode::Current)
                                .ok()
                                .flatten()
                                .unwrap_or(current),
                            catalog
                                .row_value(owner, row, w, Mode::Original)
                                .ok()
                                .flatten()
                                .unwrap_or(original),
                        )
                    } else {
                        (current, original)
                    };
                    entries.push(json!({"id":catalog.fields[part.field].key,"owner":owner.name,"owner_id":owner.id,"parameter":row.label,
                        "key":row.key,"before":before,"after":after,"part":if row.parts.len()>1 {Some(&part.id)} else {None},
                        "file":binding.locations.first().map(|l| &l.file),
                        "shared":catalog.users[part.field].len()}));
                }
            }
        }
    }
    w.validate_batch(&values)?;
    let fingerprint = crate::hash::sha256_hex(
        &serde_json::to_vec(&json!({
            "scope":scope,"entries":entries,"preserved":preserved,"skipped":skipped,
            "metadata":w.metadata()
        }))
        .map_err(|e| e.to_string())?,
    );
    if let Some(expected) = token {
        if expected != fingerprint {
            return Err("数值已发生变化，请重新预览已有差异".into());
        }
        let requested: BTreeSet<_> = selected
            .ok_or("请选择要恢复的参数")?
            .as_array()
            .ok_or("恢复参数清单无效")?
            .iter()
            .map(|v| v.as_str().ok_or("恢复参数标识无效"))
            .collect::<Result<_, _>>()?;
        if requested.is_empty()
            || requested
                .iter()
                .any(|id| !value_ids.iter().any(|v| v == id))
        {
            return Err("恢复参数清单为空或包含预览以外的参数".into());
        }
        values = values
            .into_iter()
            .zip(value_ids)
            .filter_map(|(v, id)| requested.contains(id.as_str()).then_some(v))
            .collect();
        crate::extra_stratagem::validate(catalog, w, &values)?;
        // One history transaction, persisted by Workspace before returning.
        w.set_batch(&values, None)?;
    }
    Ok(
        json!({"entries":entries,"count":entries.len(),"preserved":preserved,"skipped":skipped,
        "token":fingerprint,"applied":token.is_some(),"installed":false,"staged_fields":values.len()}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn overlapping_aliases_are_protected_but_adjacent_fields_are_not() {
        let loc = |relative| Location {
            file: "a".into(),
            typ: 1,
            record: crate::workspace::Record::Table(crate::tables::Key::Id(1)),
            relative,
        };
        assert!(overlaps(&loc(4), 4, &loc(6), 1));
        assert!(!overlaps(&loc(4), 4, &loc(8), 4));
        assert!(!numeric(&Encoding::Demolition));
    }
}
