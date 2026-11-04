//! Deterministic provider selection and bounded dependency closure.
use std::collections::{BTreeMap, BTreeSet};
pub type Identity = (u64, u64);
#[derive(Default)]
pub struct Provider {
    pub cost: usize,
    pub resources: BTreeSet<Identity>,
    pub events: BTreeSet<u32>,
}
pub struct Resolution {
    pub packages: Vec<String>,
    pub missing_resources: BTreeSet<Identity>,
    pub missing_events: BTreeSet<u32>,
}
pub fn resolve(
    providers: &BTreeMap<String, Provider>,
    preferred: &[String],
    resources: &BTreeSet<Identity>,
    events: &BTreeSet<u32>,
) -> Result<Resolution, String> {
    let mut r = Resolution {
        packages: Vec::new(),
        missing_resources: resources.clone(),
        missing_events: events.clone(),
    };
    let mut selected = BTreeSet::new();
    let apply = |r: &mut Resolution, name: &String, p: &Provider| {
        r.packages.push(name.clone());
        r.missing_resources.retain(|k| !p.resources.contains(k));
        r.missing_events.retain(|k| !p.events.contains(k));
    };
    for name in preferred {
        let p = providers.get(name).ok_or("首选资源包不存在")?;
        if selected.insert(name.clone()) {
            apply(&mut r, name, p);
        }
    }
    loop {
        let mut best: Option<(&String, &Provider, usize)> = None;
        for (name, p) in providers {
            if selected.contains(name) {
                continue;
            }
            let score = p.resources.intersection(&r.missing_resources).count()
                + p.events.intersection(&r.missing_events).count();
            if score > 0
                && best.is_none_or(|(old, op, s)| {
                    score > s || score == s && (p.cost, name) < (op.cost, old)
                })
            {
                best = Some((name, p, score));
            }
        }
        let Some((name, p, _)) = best else {
            break;
        };
        selected.insert(name.clone());
        apply(&mut r, name, p);
    }
    Ok(r)
}
/// Cycles are legal; missing identities are returned explicitly, never discarded.
pub fn closure(
    roots: &BTreeSet<Identity>,
    edges: &BTreeMap<Identity, BTreeSet<Identity>>,
    limit: usize,
) -> Result<(BTreeSet<Identity>, BTreeSet<Identity>), String> {
    let mut all = BTreeSet::new();
    let mut missing = BTreeSet::new();
    let mut queue: Vec<_> = roots.iter().copied().collect();
    while let Some(key) = queue.pop() {
        if !all.insert(key) {
            continue;
        }
        if all.len() > limit {
            return Err("依赖闭包超出数量限制".into());
        }
        if let Some(next) = edges.get(&key) {
            queue.extend(next.iter().copied());
        } else {
            missing.insert(key);
        }
    }
    Ok((all, missing))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stable_selection_prefers_coverage_then_cost_then_name() {
        let mut p = BTreeMap::new();
        for (name, cost) in [("b", 3), ("a", 3), ("c", 9)] {
            p.insert(
                name.into(),
                Provider {
                    cost,
                    resources: BTreeSet::from([(1, 2)]),
                    events: BTreeSet::new(),
                },
            );
        }
        let r = resolve(
            &p,
            &[],
            &BTreeSet::from([(1, 2), (3, 4)]),
            &BTreeSet::from([7]),
        )
        .unwrap();
        assert_eq!(r.packages, vec!["a"]);
        assert_eq!(r.missing_resources, BTreeSet::from([(3, 4)]));
        assert_eq!(r.missing_events, BTreeSet::from([7]));
    }
    #[test]
    fn cycle_and_missing_are_explicit() {
        let edges = BTreeMap::from([
            ((1, 1), BTreeSet::from([(1, 2)])),
            ((1, 2), BTreeSet::from([(1, 1), (1, 3)])),
        ]);
        let (all, missing) = closure(&BTreeSet::from([(1, 1)]), &edges, 3).unwrap();
        assert_eq!(all.len(), 3);
        assert_eq!(missing, BTreeSet::from([(1, 3)]));
        assert!(closure(&BTreeSet::from([(1, 1)]), &edges, 2).is_err());
    }
}
