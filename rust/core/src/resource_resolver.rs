//! On-demand package/resource providers. Only complete scans are published.
use crate::{
    bundles::Bundles,
    dependencies::{self, Identity, Provider, Resolution},
    resource_package::Package,
};
use std::collections::{BTreeMap, BTreeSet};
pub struct Resolver {
    pub bundles: Bundles,
    headers: BTreeMap<String, Package>,
    index: Option<BTreeMap<u64, BTreeSet<u64>>>,
    banks: BTreeMap<(String, u64), Result<BTreeSet<u32>, String>>,
}
impl Resolver {
    pub fn new(bundles: Bundles) -> Self {
        Self {
            bundles,
            headers: BTreeMap::new(),
            index: None,
            banks: BTreeMap::new(),
        }
    }
    fn header(&mut self, name: &str) -> Result<&Package, String> {
        if !self.headers.contains_key(name) {
            let p = self.bundles.package(name)?;
            self.headers.insert(name.into(), p);
        }
        Ok(&self.headers[name])
    }
    pub fn names(&self) -> Vec<String> {
        self.bundles
            .packages
            .keys()
            .filter(|s| crate::residency::package_name(s))
            .cloned()
            .collect()
    }
    pub fn scan(
        &mut self,
        blobs: &[Vec<u8>],
        mut progress: impl FnMut(usize, usize),
    ) -> Result<BTreeSet<Identity>, String> {
        if self.index.is_none() {
            let names = self.names();
            let mut index: BTreeMap<u64, BTreeSet<u64>> = BTreeMap::new();
            let mut count = 0usize;
            for (i, name) in names.iter().enumerate() {
                progress(i, names.len());
                for e in &self.header(name)?.entries {
                    let id = u64::from_le_bytes(e[..8].try_into().unwrap());
                    let typ = u64::from_le_bytes(e[8..16].try_into().unwrap());
                    if id != 0 {
                        index.entry(id).or_default().insert(typ);
                    }
                    count += 1;
                    if count > 5_000_000 {
                        return Err("资源索引超过数量限制".into());
                    }
                }
            }
            if index.is_empty() {
                return Err("资源索引为空".into());
            }
            self.index = Some(index);
        }
        let index = self.index.as_ref().unwrap();
        let mut result = BTreeSet::new();
        for b in blobs {
            for at in (0..b.len().saturating_sub(7)).step_by(4) {
                let id = u64::from_le_bytes(b[at..at + 8].try_into().unwrap());
                if let Some(types) = index.get(&id) {
                    result.extend(types.iter().map(|typ| (*typ, id)));
                }
            }
        }
        Ok(result)
    }
    fn provider(
        &mut self,
        name: &str,
        audio: bool,
        warnings: &mut BTreeSet<String>,
    ) -> Result<Provider, String> {
        let entries = self.header(name)?.entries.clone();
        let mut p = Provider {
            cost: entries.len(),
            ..Provider::default()
        };
        for e in entries {
            let id = u64::from_le_bytes(e[..8].try_into().unwrap());
            let typ = u64::from_le_bytes(e[8..16].try_into().unwrap());
            p.resources.insert((typ, id));
            if audio && typ == 0x535a7bd3e650d799 {
                let key = (name.to_string(), id);
                if !self.banks.contains_key(&key) {
                    let base = u64::from_le_bytes(e[16..24].try_into().unwrap());
                    let size = u32::from_le_bytes(e[56..60].try_into().unwrap()) as usize;
                    let events = crate::audio::events(size, |at, n| {
                        self.bundles.read(
                            name,
                            base.checked_add(at as u64).ok_or("音效偏移溢出")?,
                            n,
                        )
                    });
                    self.banks.insert(key.clone(), events);
                }
                match &self.banks[&key] {
                    Ok(events) => p.events.extend(events),
                    Err(e) => {
                        warnings.insert(format!("{name}:{id:016x}：{e}"));
                    }
                }
            }
        }
        Ok(p)
    }
    pub fn resolve(
        &mut self,
        preferred: &[String],
        resources: &BTreeSet<Identity>,
        events: &BTreeSet<u32>,
        mut progress: impl FnMut(usize, usize),
    ) -> Result<(Resolution, BTreeMap<String, Provider>, BTreeSet<String>), String> {
        let mut providers = BTreeMap::new();
        let mut warnings = BTreeSet::new();
        for name in preferred {
            if !crate::residency::package_name(name) {
                return Err("首选资源包名称无效".into());
            }
            providers.insert(
                name.clone(),
                self.provider(name, !events.is_empty(), &mut warnings)?,
            );
        }
        let mut result = dependencies::resolve(&providers, preferred, resources, events)?;
        if !result.missing_resources.is_empty() || !result.missing_events.is_empty() {
            let names = self.names();
            for (i, name) in names.iter().enumerate() {
                progress(i, names.len());
                if !providers.contains_key(name) {
                    providers.insert(
                        name.clone(),
                        self.provider(name, !events.is_empty(), &mut warnings)?,
                    );
                }
            }
            result = dependencies::resolve(&providers, preferred, resources, events)?;
        }
        Ok((result, providers, warnings))
    }
}
