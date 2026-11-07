//! The public picker uses stratagem types; table records use a separate key.
use crate::{
    binary::Encoding,
    catalog::{Catalog, Mode, Row},
    tables::Key,
    workspace::{Location, Record, Workspace},
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

const TYPE: u32 = 0x30EB6399;
const EXTRA: usize = 200;
const PACKAGE: u32 = 0x7A858691;
const LOADOUT: u32 = 0x4F2CF417;
const MANDATORY: [u32; 3] = [2266266587, 3193487269, 867876502];
const HIDDEN: [u32; 5] = [2663642538, 905054095, 101457192, 3702563421, 4264661046];
pub(crate) const GENERATED: &str = "derived_stratagem_words";

#[derive(Clone, Copy, Serialize, Deserialize)]
struct Word {
    before: u32,
    after: u32,
}

type Ledger = BTreeMap<u32, BTreeMap<usize, Word>>;

fn ledger(workspace: &Workspace) -> Result<Ledger, String> {
    let saved = &workspace.loaded_metadata()[GENERATED];
    if saved.is_null() {
        return Ok(BTreeMap::new());
    }
    let data: Ledger = serde_json::from_value(saved.clone()).map_err(|_| "派生战备记录损坏")?;
    if data.len() > 64
        || data.values().any(|words| {
            words.keys().any(|offset| {
                !matches!(
                    *offset,
                    40 | 44 | 72 | 80 | 112 | 116 | 124 | 168 | 172 | 176 | 180 | EXTRA
                )
            })
        })
    {
        return Err("派生战备记录不合法".into());
    }
    Ok(data)
}

/// Explicit repair detaches stale bookkeeping, never rewrites a game word.
/// Still-matching words retain their original undo information.
pub(crate) fn reconcile(workspace: &Workspace) -> Result<(Value, usize), String> {
    let mut saved = ledger(workspace)?;
    let mut removed = 0;
    for (&record, words) in &mut saved {
        let mut stale = Vec::new();
        for (&offset, word) in words.iter() {
            let location = workspace.table_location(TYPE, record, offset)?;
            if id(workspace.value(&location, &Encoding::U32)?.loaded)? != word.after {
                stale.push(offset);
            }
        }
        for offset in stale {
            words.remove(&offset);
            removed += 1;
        }
    }
    saved.retain(|_, words| !words.is_empty());
    Ok((
        if saved.is_empty() {
            Value::Null
        } else {
            json!(saved)
        },
        removed,
    ))
}

fn logical(
    workspace: &Workspace,
    saved: &Ledger,
    record: u32,
    offset: usize,
) -> Result<u32, String> {
    let location = workspace.table_location(TYPE, record, offset)?;
    let raw = workspace.value(&location, &Encoding::U32)?;
    let Some(word) = saved.get(&record).and_then(|fields| fields.get(&offset)) else {
        return id(raw.current);
    };
    if id(raw.loaded)? != word.after {
        return Err(format!(
            "派生战备记录 #{record}（+{offset}）与当前文件不符，请到设置运行自动修复"
        ));
    }
    if raw.current == raw.loaded {
        Ok(word.before)
    } else {
        id(raw.current)
    }
}

struct Node {
    target: u32,
    original: u32,
}

struct Graph {
    nodes: BTreeMap<u32, Node>,
    by_record: BTreeMap<u32, u32>,
    labels: BTreeMap<u32, String>,
}

fn id(value: f64) -> Result<u32, String> {
    if value.fract() != 0.0 || !(0.0..=u32::MAX as f64).contains(&value) {
        return Err("附赠战备编号无效".into());
    }
    Ok(value as u32)
}

fn record(location: &Location) -> Option<u32> {
    match location.record {
        Record::Table(Key::Id(id)) if location.typ == TYPE && location.relative == EXTRA => {
            Some(id)
        }
        _ => None,
    }
}

impl Graph {
    fn read(catalog: &Catalog, workspace: &Workspace) -> Result<Self, String> {
        let saved = ledger(workspace)?;
        let mut graph = Self {
            nodes: BTreeMap::new(),
            by_record: BTreeMap::new(),
            labels: BTreeMap::new(),
        };
        for key in workspace.table_ids(TYPE)? {
            let mut location = workspace.table_location(TYPE, key, 0)?;
            let typ = workspace.value(&location, &Encoding::U32)?.current as u32;
            if typ == 0 {
                continue;
            }
            location.relative = EXTRA;
            let value = workspace.value(&location, &Encoding::U32)?;
            if graph
                .nodes
                .insert(
                    typ,
                    Node {
                        target: logical(workspace, &saved, key, EXTRA)?,
                        original: value.original.unwrap_or(value.loaded) as u32,
                    },
                )
                .is_some()
            {
                return Err(format!("战备类型 #{typ} 对应多个记录"));
            }
            graph.by_record.insert(key, typ);
        }
        if graph.nodes.is_empty() {
            return Err("当前工作区没有载入战备表".into());
        }
        for entry in catalog.registries.get("stratagem").into_iter().flatten() {
            if let Ok(typ) = u32::try_from(entry.id) {
                if graph.nodes.contains_key(&typ) {
                    graph.labels.insert(typ, entry.label.clone());
                }
            }
        }
        Ok(graph)
    }

    fn label(&self, typ: u32) -> String {
        self.labels
            .get(&typ)
            .cloned()
            .unwrap_or_else(|| format!("战备 #{typ}"))
    }

    fn validate(&self, desired: &BTreeMap<u32, u32>) -> Result<Vec<String>, String> {
        let next = |typ| {
            self.nodes
                .get(&typ)
                .map(|node| desired.get(&typ).copied().unwrap_or(node.target))
        };
        let mut claimed = BTreeMap::new();
        let mut warnings = Vec::new();
        for (&root, node) in &self.nodes {
            let mut target = next(root).unwrap();
            if target == 0 || target == node.original {
                continue;
            }
            let mut visited = BTreeSet::from([root]);
            while target != 0 {
                if visited.len() > 64 || !visited.insert(target) {
                    return Err(format!(
                        "附赠战备形成循环或链条过长，起点为 {}",
                        self.label(root)
                    ));
                }
                let Some(following) = next(target) else {
                    return Err(format!(
                        "附赠战备无法识别，{} 引用了 #{target}",
                        self.label(root)
                    ));
                };
                if let Some(other) = claimed.get(&target) {
                    warnings.push(format!(
                        "{} 与 {} 都会附赠 {}，同时携带可能导致任务加载失败",
                        self.label(*other),
                        self.label(root),
                        self.label(target)
                    ));
                } else {
                    claimed.insert(target, root);
                }
                target = following;
            }
        }
        Ok(warnings)
    }
}

#[derive(Default)]
pub(crate) struct Derived {
    pub words: BTreeMap<Location, u32>,
    pub metadata: Value,
    pub warnings: Vec<String>,
}

pub(crate) fn clear_words(workspace: &Workspace) -> Result<BTreeMap<Location, u32>, String> {
    let saved = ledger(workspace)?;
    let mut words = BTreeMap::new();
    for (&record, offsets) in &saved {
        for &offset in offsets.keys() {
            let location = workspace.table_location(TYPE, record, offset)?;
            words.insert(location, logical(workspace, &saved, record, offset)?);
        }
    }
    Ok(words)
}

struct Donor {
    package: [u32; 2],
    label: String,
    hosts: BTreeSet<u32>,
}

fn read_swaps(catalog: &Catalog, workspace: &Workspace) -> Result<Vec<Donor>, String> {
    let mut donors = Vec::<Donor>::new();
    for owner in &catalog.owners {
        let Some(own) = owner
            .native_key
            .as_deref()
            .and_then(|s| u64::from_str_radix(s, 16).ok())
        else {
            continue;
        };
        for (mode, &field) in owner.swaps.iter().enumerate() {
            let current = catalog.field_value(field, workspace, Mode::Current);
            let original = catalog.field_value(field, workspace, Mode::Original);
            let (Ok(Some(current)), Ok(Some(original))) = (current, original) else {
                continue;
            };
            if current == original {
                continue;
            }
            let Some(source) = catalog.projectile_sources.get(&id(current)?) else {
                continue;
            };
            let key = u64::from_str_radix(&source.key, 16).map_err(|_| "射弹来源编号无效")?;
            if key == own {
                continue;
            }
            let Some(lo) = workspace.table_value(PACKAGE, Key::Hash(key), 8)? else {
                continue;
            };
            let hi = workspace
                .table_value(PACKAGE, Key::Hash(key), 12)?
                .ok_or("射弹来源包不完整")?;
            let package = [id(lo)?, id(hi)?];
            if package == [0, 0] {
                continue;
            }
            let support = matches!(owner.tab.as_str(), "Support" | "Support weapons");
            let host = if support && mode == 0 {
                workspace
                    .table_value(LOADOUT, Key::Hash(own), 0)?
                    .map(id)
                    .transpose()?
            } else {
                None
            };
            donors.push(Donor {
                package,
                label: source.label.clone(),
                hosts: host.into_iter().collect(),
            });
        }
    }
    let mut unique = Vec::<Donor>::new();
    for donor in donors {
        if let Some(existing) = unique
            .iter_mut()
            .find(|existing| existing.package == donor.package)
        {
            if donor.hosts.is_empty() || existing.hosts.is_empty() {
                existing.hosts.clear();
            } else {
                existing.hosts.extend(donor.hosts);
            }
        } else {
            unique.push(donor);
        }
    }
    Ok(unique)
}

fn tail(
    graph: &Graph,
    links: &BTreeMap<(u32, usize), u32>,
    root: u32,
    visited: &mut BTreeSet<u32>,
) -> Result<u32, String> {
    let mut current = root;
    loop {
        if !visited.insert(current) || visited.len() > 64 {
            return Err("战备链重复或过长，无法安装自动加载资源".into());
        }
        let next = links
            .get(&(current, EXTRA))
            .copied()
            .unwrap_or(graph.nodes[&current].target);
        if next == 0 {
            return Ok(current);
        }
        if !graph.nodes.contains_key(&next) {
            return Err(format!("战备链引用了未知类型 #{next}"));
        }
        current = next;
    }
}

pub(crate) fn derive(catalog: &Catalog, workspace: &Workspace) -> Result<Derived, String> {
    let saved = ledger(workspace)?;
    let always: BTreeSet<_> = catalog
        .fields
        .iter()
        .filter_map(|field| {
            field
                .stratagem_always
                .filter(|_| workspace.metadata()["virtual"][&field.key].as_f64() == Some(1.0))
        })
        .collect();
    let donors = read_swaps(catalog, workspace)?;
    if always.is_empty() && donors.is_empty() && saved.is_empty() {
        return Ok(Derived::default());
    }
    let graph = Graph::read(catalog, workspace)?;
    let mut result = Derived::default();
    let mut links = BTreeMap::new();
    let mut reverse = BTreeMap::new();
    for (&record, &typ) in &graph.by_record {
        reverse.insert(typ, record);
    }
    result.words = clear_words(workspace)?;
    if !always.is_empty() || !donors.is_empty() {
        let mandatory = MANDATORY
            .iter()
            .map(|r| graph.by_record.get(r).copied())
            .collect::<Option<Vec<_>>>()
            .ok_or("当前版本缺少基础战备载体")?;
        let hidden: Vec<_> = HIDDEN
            .iter()
            .filter_map(|r| graph.by_record.get(r).copied())
            .collect();
        let mut shared = BTreeSet::new();
        let mut tails = mandatory
            .iter()
            .map(|&typ| tail(&graph, &links, typ, &mut shared))
            .collect::<Result<Vec<_>, _>>()?;
        let (mut global, own): (Vec<_>, Vec<_>) =
            donors.into_iter().partition(|d| d.hosts.is_empty());
        for (host, donor) in mandatory
            .iter()
            .copied()
            .take(2)
            .zip(global.drain(..global.len().min(2)))
        {
            links.insert((host, 168), donor.package[0]);
            links.insert((host, 172), donor.package[1]);
        }
        let room = 4usize.min(hidden.len());
        let own_count = own.len().min(room);
        let global_count = global.len().min(room - own_count);
        let mut used = 0;
        for (local, (index, donor)) in global
            .iter()
            .take(global_count)
            .chain(own.iter().take(own_count))
            .enumerate()
            .map(|(index, donor)| (!donor.hosts.is_empty(), (index, donor)))
        {
            let slot = hidden[index];
            if graph.nodes[&slot].target != 0 || shared.contains(&slot) {
                return Err("备用战备载体已由其他设置占用".into());
            }
            for (offset, value) in [
                (40, 0),
                (44, 0),
                (72, 0),
                (80, 0),
                (112, 2),
                (116, 2),
                (124, 19),
                (168, donor.package[0]),
                (172, donor.package[1]),
                (176, 0),
                (180, 0),
            ] {
                links.insert((slot, offset), value);
            }
            if local {
                for &record in &donor.hosts {
                    let root = *graph
                        .by_record
                        .get(&record)
                        .ok_or("支援武器缺少对应战备载体")?;
                    let mut visited = BTreeSet::new();
                    let last = tail(&graph, &links, root, &mut visited)?;
                    if shared.contains(&last) || visited.contains(&slot) {
                        return Err("支援武器的附赠战备与基础战备载体重叠".into());
                    }
                    links.insert((last, EXTRA), slot);
                }
            } else {
                let index = used % tails.len();
                links.insert((tails[index], EXTRA), slot);
                tails[index] = slot;
                shared.insert(slot);
                used += 1;
            }
        }
        for donor in global
            .iter()
            .skip(global_count)
            .chain(own.iter().skip(own_count))
        {
            result.warnings.push(format!(
                "自动驻留容量已满，{} 的来源资源未加入",
                donor.label
            ));
        }
        let mut available = room - own_count - global_count;
        let mut last = *tails.last().ok_or("当前版本缺少常驻战备载体")?;
        for typ in always {
            if shared.contains(&typ) {
                continue;
            }
            if available == 0 {
                result
                    .warnings
                    .push(format!("常驻战备容量已满，{} 未加入", graph.label(typ)));
                continue;
            }
            if !graph.nodes.contains_key(&typ) {
                return Err("常驻战备不存在于当前版本".into());
            }
            let mut visited = BTreeSet::new();
            let next_tail = tail(&graph, &links, typ, &mut visited)?;
            if !visited.is_disjoint(&shared) || visited.iter().any(|node| hidden.contains(node)) {
                return Err("常驻战备的附赠链与已有常驻战备重叠".into());
            }
            links.insert((last, EXTRA), typ);
            last = next_tail;
            shared.extend(visited);
            available -= 1;
        }
    }
    let mut next = Ledger::new();
    for ((typ, offset), after) in links {
        let record = reverse[&typ];
        let before = logical(workspace, &saved, record, offset)?;
        if before != after {
            result
                .words
                .insert(workspace.table_location(TYPE, record, offset)?, after);
            next.entry(record)
                .or_default()
                .insert(offset, Word { before, after });
        }
    }
    result.metadata = if next.is_empty() {
        Value::Null
    } else {
        json!(next)
    };
    Ok(result)
}

pub(crate) fn validate(
    catalog: &Catalog,
    workspace: &Workspace,
    values: &[(Location, Encoding, f64)],
) -> Result<Vec<String>, String> {
    let mut edits = BTreeMap::new();
    for (location, _, value) in values {
        if let Some(key) = record(location) {
            let target = id(*value)?;
            if edits.insert(key, target).is_some_and(|old| old != target) {
                return Err("同一战备的附赠项有冲突".into());
            }
        }
    }
    if edits.is_empty() {
        return Ok(Vec::new());
    }
    let graph = Graph::read(catalog, workspace)?;
    let mut desired = BTreeMap::new();
    for (key, target) in edits {
        let typ = *graph.by_record.get(&key).ok_or("没有对应的战备记录")?;
        desired.insert(typ, target);
    }
    graph.validate(&desired)
}

pub(crate) fn current_warnings(
    catalog: &Catalog,
    workspace: &Workspace,
) -> Result<Vec<String>, String> {
    let mut edits = Vec::new();
    for binding in catalog.bindings.iter().flatten() {
        if !matches!(binding.encoding, Encoding::U32) {
            continue;
        }
        for location in &binding.locations {
            if record(location).is_some() {
                let value = workspace.value(location, &Encoding::U32)?;
                if value.current != value.loaded {
                    edits.push((location.clone(), Encoding::U32, value.current));
                }
            }
        }
    }
    validate(catalog, workspace, &edits)
}

pub(crate) fn choices(
    catalog: &Catalog,
    workspace: &Workspace,
    row: &Row,
) -> Result<Value, String> {
    let field = row.parts.first().ok_or("附赠战备绑定缺失")?.field;
    let binding = catalog.bindings[field].as_ref().ok_or("附赠战备绑定缺失")?;
    let graph = Graph::read(catalog, workspace)?;
    let types = binding
        .locations
        .iter()
        .map(|location| {
            record(location)
                .and_then(|key| graph.by_record.get(&key).copied())
                .ok_or("没有对应的战备记录")
        })
        .collect::<Result<Vec<_>, _>>()?;
    let mut out = vec![json!({"id":0,"label":"无","disabled":null})];
    let mut choices: Vec<_> = graph.labels.iter().collect();
    choices.sort_by(|a, b| a.1.cmp(b.1).then(a.0.cmp(b.0)));
    for (&id, label) in choices {
        let desired = types.iter().map(|&typ| (typ, id)).collect();
        let disabled = graph.validate(&desired).err();
        out.push(json!({"id":id,"label":label,"disabled":disabled}));
    }
    Ok(json!(out))
}
