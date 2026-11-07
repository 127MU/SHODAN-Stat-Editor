//! Version-checked resource transformations for ragdoll and mounted turrets.
use crate::{
    catalog::{Catalog, Mode, Owner, Row},
    dependencies::Identity,
    game_workspace::Game,
    workspace::Workspace,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

pub(crate) const MACHINE: u64 = 0xa486d4045106165c;
const DEPLOYED: u64 = 0x823905bd6b62ba3e;
const TRANSITION: u64 = 0x79de1870039a1a7e;
const SWEEP: u64 = 0x9ea750d5873eb183;
const EMPTY: u64 = 0x86342d705e08ad12;

fn span(b: &[u8], at: usize, len: usize) -> Result<&[u8], String> {
    let end = at.checked_add(len).ok_or("资源偏移溢出")?;
    b.get(at..end).ok_or_else(|| "资源结构截断".into())
}
fn u32at(b: &[u8], at: usize) -> Result<u32, String> {
    Ok(u32::from_le_bytes(span(b, at, 4)?.try_into().unwrap()))
}
fn u64at(b: &[u8], at: usize) -> Result<u64, String> {
    Ok(u64::from_le_bytes(span(b, at, 8)?.try_into().unwrap()))
}
type Step = (usize, u32, u32);
fn machine_steps(b: &[u8]) -> Result<Vec<Step>, String> {
    span(b, 0, 60)?;
    let groups = u32at(b, 8)? as usize;
    if u32at(b, 4)? == 0 || groups == 0 {
        return Ok(vec![]);
    }
    let n = u32at(b, groups)? as usize;
    if n > 4096 {
        return Err("状态机层数异常".into());
    }
    span(b, groups + 4, n * 4)?;
    let mut seen = BTreeSet::new();
    let mut result = Vec::new();
    for i in 0..n {
        let layer = groups + u32at(b, groups + 4 + i * 4)? as usize;
        let at = layer + 4;
        if !seen.insert(at) {
            return Err("状态机层偏移重复".into());
        }
        let count = u32at(b, layer + 8)? as usize;
        if count > 65536 {
            return Err("状态机状态数量异常".into());
        }
        span(b, layer + 12, count * 4)?;
        let before = u32at(b, at)?;
        let mut states = BTreeMap::new();
        for index in 0..count {
            let offset = layer + u32at(b, layer + 12 + index * 4)? as usize;
            span(b, offset, 80)?;
            let name = u64at(b, offset)?;
            if ![DEPLOYED, TRANSITION, SWEEP, EMPTY].contains(&name) {
                continue;
            }
            if states.insert(name, index as u32).is_some() {
                return Err("部署状态标识重复".into());
            }
        }
        let target = if count < 2 {
            None
        } else if i == 0 {
            states.get(&DEPLOYED).or_else(|| states.get(&TRANSITION))
        } else if states.contains_key(&SWEEP) {
            states.get(&EMPTY)
        } else {
            None
        };
        if let Some(&after) = target.filter(|&&after| before != after) {
            result.push((at, before, after));
        }
    }
    if result.len() > 2 {
        return Err("状态机不匹配已验证的部署布局".into());
    }
    Ok(result)
}

fn apply_bytes(
    current: &mut [u8],
    at: usize,
    before: &[u8],
    after: &[u8],
    on: bool,
) -> Result<bool, String> {
    let live = span(current, at, before.len())?;
    let active = live == after;
    if live != before && !active {
        return Err("资源字段已被其他修改覆盖".into());
    }
    current[at..at + before.len()].copy_from_slice(if on { after } else { before });
    Ok(active)
}

fn machine_package(
    catalog: &Catalog,
    workspace: &Workspace,
    owner: &Owner,
    row: &Row,
) -> Result<(String, String), String> {
    let suffix = row
        .id
        .strip_prefix("smmode")
        .or_else(|| row.id.strip_prefix("smres"))
        .ok_or("状态机行无效")?;
    let id = format!("load_package{suffix}");
    let pkg = owner
        .rows
        .iter()
        .find(|r| r.id == id)
        .ok_or("状态机缺少来源包")?;
    let value = catalog
        .row_value(owner, pkg, workspace, Mode::Current)?
        .ok_or("状态机来源包不可读")?;
    let package = catalog
        .registries
        .get("package")
        .into_iter()
        .flatten()
        .find(|item| item.id as f64 == value)
        .map(|item| item.raw.to_ascii_lowercase())
        .filter(|name| crate::residency::package_name(name))
        .ok_or("请先选择状态机的来源资源包")?;
    Ok((package, format!("smres{suffix}")))
}

pub(crate) fn machine_choices(
    game: &Game,
    catalog: &Catalog,
    workspace: &Workspace,
    owner: &Owner,
    row: &Row,
) -> Result<Value, String> {
    let (package, _) = machine_package(catalog, workspace, owner, row)?;
    let list = game
        .resources()?
        .as_mut()
        .unwrap()
        .bundles
        .entries(&package, MACHINE)?;
    Ok(json!(list.iter().enumerate().map(|(i,(id,size))|json!({
        "id":i+1,"name":format!("状态机 {}/{}（{size} 字节）",i+1,list.len()),"description":format!("{id:016x}")
    })).collect::<Vec<_>>()))
}

pub(crate) fn machine(
    game: &Game,
    catalog: &Catalog,
    workspace: &Workspace,
    owner: &Owner,
    row: &Row,
    on: Option<bool>,
) -> Result<Value, String> {
    let (package, pick) = machine_package(catalog, workspace, owner, row)?;
    let pick = owner
        .rows
        .iter()
        .find(|r| r.id == pick)
        .ok_or("状态机选择项缺失")?;
    let selected = catalog
        .row_value(owner, pick, workspace, Mode::Current)?
        .unwrap_or(1.0)
        .max(1.0) as usize;
    let (id, base) = {
        let mut cache = game.resources()?;
        let bundles = &mut cache.as_mut().unwrap().bundles;
        let entries = bundles.entries(&package, MACHINE)?;
        let &(id, _) = entries.get(selected - 1).ok_or("该资源包没有所选状态机")?;
        (id, bundles.resource(&package, (MACHINE, id))?)
    };
    let steps = machine_steps(&base)?;
    let key = (MACHINE, id);
    let held = game.overrides(&package)?;
    let mut current = held.get(&key).cloned().unwrap_or_else(|| base.clone());
    let mut active = 0;
    for &(at, before, after) in &steps {
        active += usize::from(apply_bytes(
            &mut current,
            at,
            &before.to_le_bytes(),
            &after.to_le_bytes(),
            on.unwrap_or(true),
        )?);
    }
    let Some(on) = on else {
        return Ok(
            json!({"enabled":!steps.is_empty() && active==steps.len(),"fields":steps.len()}),
        );
    };
    if steps.is_empty() && on {
        return Err("没有可调整的部署状态，请选择其他状态机".into());
    }
    if held.get(&key).map_or(base.as_slice(), Vec::as_slice) != current {
        game.patch_edits(BTreeMap::from([(
            package,
            BTreeMap::from([(key, (current != base).then_some(current))]),
        )]))?;
    }
    Ok(json!(if on {
        "状态机补丁已写入，重启游戏后生效"
    } else {
        "状态机补丁已移除，重启游戏后生效"
    }))
}

#[derive(Deserialize)]
struct Recipe {
    package: String,
    resources: Vec<Spec>,
}
#[derive(Deserialize)]
struct Spec {
    id: String,
    #[serde(rename = "type")]
    typ: String,
    size: usize,
    sha256: String,
    edits: Vec<(usize, String, String)>,
}
fn decode(s: &str) -> Result<[u8; 4], String> {
    let n = u32::from_str_radix(s, 16).map_err(|_| "资源配方十六进制无效")?;
    Ok(n.to_be_bytes())
}
pub(crate) fn ragdoll(
    game: &Game,
    on: Option<bool>,
) -> Result<(Value, crate::residency_install::Edits), String> {
    let recipe: Recipe =
        serde_json::from_str(include_str!("ragdoll_recipe.json")).map_err(|_| "布娃娃配方无效")?;
    let held = game.overrides(&recipe.package)?;
    let mut active = 0;
    let mut total = 0;
    let mut edits = BTreeMap::<Identity, Option<Vec<u8>>>::new();
    {
        let mut cache = game.resources()?;
        let bundles = &mut cache.as_mut().unwrap().bundles;
        for spec in &recipe.resources {
            let parse = |s: &str| u64::from_str_radix(s, 16).map_err(|_| "资源配方身份无效");
            let key = (parse(&spec.typ)?, parse(&spec.id)?);
            let base = bundles.resource(&recipe.package, key)?;
            if base.len() != spec.size || crate::hash::sha256_hex(&base) != spec.sha256 {
                return Err("当前版本的布娃娃资源与已核验版本不同".into());
            }
            let mut current = held.get(&key).cloned().unwrap_or_else(|| base.clone());
            for (at, before, after) in &spec.edits {
                let (before, after) = (decode(before)?, decode(after)?);
                if span(&base, *at, 4)? != before {
                    return Err("布娃娃配方的原始字节不匹配".into());
                }
                active += usize::from(apply_bytes(
                    &mut current,
                    *at,
                    &before,
                    &after,
                    on.unwrap_or(true),
                )?);
                total += 1;
            }
            if held.get(&key).map_or(base.as_slice(), Vec::as_slice) != current {
                edits.insert(key, (current != base).then_some(current));
            }
        }
    }
    Ok((
        json!({"supported":true,"enabled":on.unwrap_or(active==total),"partial":active>0&&active<total,"fields":total,
        "message":"当前资源版本已核对。配置保存后需点击写入游戏生效。"}),
        if on.is_some() && !edits.is_empty() {
            BTreeMap::from([(recipe.package, edits)])
        } else {
            BTreeMap::new()
        },
    ))
}
