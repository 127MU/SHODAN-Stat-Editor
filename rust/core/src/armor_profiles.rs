//! Armor selection configuration, separate from numeric overrides.
use crate::passive::{Policy, Profile};
use std::collections::{BTreeMap, BTreeSet};
pub const EVERY: u32 = 999;
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Group {
    pub profile: Profile,
    pub configured: bool,
}
#[derive(Clone, Default, Debug, PartialEq, Eq)]
pub struct Profiles {
    pub groups: BTreeMap<u32, Group>,
}
pub struct Parsed {
    pub profiles: Profiles,
    pub ignored_numeric: usize,
    pub warnings: Vec<String>,
}
fn norm(text: &str) -> String {
    text.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_lowercase())
        .collect()
}
fn names() -> BTreeMap<String, u32> {
    let mut names = BTreeMap::new();
    for entry in crate::armor::catalog()["list"]
        .as_array()
        .expect("catalog list")
    {
        let id = entry["id"].as_u64().expect("catalog ID") as u32;
        names.insert(norm(entry["name"].as_str().unwrap()), id);
        names.insert(entry["zh"].as_str().unwrap().to_string(), id);
    }
    for name in ["Every armor", "Every", "All armors", "Any armor"] {
        names.insert(norm(name), EVERY);
    }
    names.insert("所有护甲".into(), EVERY);
    names
}
fn find(text: &str, names: &BTreeMap<String, u32>, available: &BTreeSet<u32>) -> Option<u32> {
    let text = text.trim();
    let id = text
        .parse::<u32>()
        .ok()
        .or_else(|| text.strip_prefix("被动 #").and_then(|v| v.parse().ok()))
        .or_else(|| {
            norm(text)
                .strip_prefix("passive")
                .and_then(|v| v.parse().ok())
        })
        .or_else(|| names.get(text).or_else(|| names.get(&norm(text))).copied())?;
    (id == EVERY || available.contains(&id)).then_some(id)
}
impl Profiles {
    pub fn parse(text: &str, available: &BTreeSet<u32>) -> Result<Parsed, String> {
        if text.len() > 1024 * 1024 {
            return Err("护甲组合配置过大".into());
        }
        let names = names();
        let mut profiles = Self::default();
        let mut current = None;
        let mut warnings = Vec::new();
        let mut ignored_numeric = 0;
        for raw in text.trim_start_matches('\u{feff}').lines() {
            let raw = raw.trim();
            if raw.is_empty() || raw.starts_with([';', '#']) {
                continue;
            }
            let comment = raw
                .char_indices()
                .find(|(at, c)| {
                    (*c == ';' || *c == '#') && *at > 0 && raw[..*at].ends_with(char::is_whitespace)
                })
                .map(|(at, _)| at);
            let line = raw[..comment.unwrap_or(raw.len())].trim();
            if let Some(section) = line.strip_prefix('[').and_then(|s| s.strip_suffix(']')) {
                current = None;
                if let Some((kind, name)) = section.split_once(':') {
                    if kind.trim().eq_ignore_ascii_case("profile") {
                        if let Some(id) = find(name, &names, available) {
                            profiles.groups.insert(
                                id,
                                Group {
                                    profile: Profile::default(),
                                    configured: true,
                                },
                            );
                            current = Some(id);
                        } else {
                            warnings.push(format!("未知护甲组 [{section}]，已跳过"));
                        }
                    }
                }
                continue;
            }
            let Some(id) = current else {
                continue;
            };
            let Some((key, value)) = line.split_once('=') else {
                warnings.push("无法解析护甲配置行，已跳过".into());
                continue;
            };
            let key = key.trim();
            let value = value.trim().to_ascii_lowercase();
            let group = profiles.groups.get_mut(&id).unwrap();
            match key.to_ascii_lowercase().as_str() {
                "conflicts" => {
                    if !["stack", "strongest"].contains(&value.as_str()) {
                        warnings.push("未知同类效果处理方式，已按叠加处理".into());
                    }
                    group.profile.policy = if value == "strongest" {
                        Policy::Strongest
                    } else {
                        Policy::Stack
                    }
                }
                "own_passive" | "own" => {
                    if ![
                        "on", "yes", "true", "1", "y", "off", "no", "false", "0", "n",
                    ]
                    .contains(&value.as_str())
                    {
                        warnings.push("保留原生被动的开关值无效，已保留原生被动".into());
                    }
                    group.profile.own = !["off", "no", "false", "0", "n"].contains(&value.as_str())
                }
                "raw" | "raw_stats" | "swap" | "weight" | "base" | "retire" | "hotkey"
                | "swap_hotkey" | "panel_scale" | "name" => {}
                _ if key.contains('.') => ignored_numeric += 1,
                _ => {
                    if let Some(source) = find(key, &names, available).filter(|id| *id != EVERY) {
                        if ["on", "yes", "true", "1", "y"].contains(&value.as_str()) {
                            if !group.profile.enabled.contains(&source) {
                                group.profile.enabled.push(source);
                            }
                        } else if ["off", "no", "false", "0", "n", ""].contains(&value.as_str()) {
                            group.profile.enabled.retain(|v| *v != source);
                        } else {
                            warnings.push(format!("被动 {key} 的开关值无效，已忽略此行"));
                        }
                    } else {
                        warnings.push(format!("未知被动 {key}，已跳过"));
                    }
                }
            }
        }
        for group in profiles.groups.values_mut() {
            group.profile.enabled.sort_unstable();
        }
        Ok(Parsed {
            profiles,
            ignored_numeric,
            warnings,
        })
    }
    pub fn validate(&self, available: &BTreeSet<u32>) -> Result<(), String> {
        for (id, group) in &self.groups {
            if *id != EVERY && !available.contains(id) {
                return Err(format!("目标被动不存在：{id}"));
            }
            let mut seen = BTreeSet::new();
            for source in &group.profile.enabled {
                if !available.contains(source) || !seen.insert(source) {
                    return Err(format!("来源被动不存在或重复：{source}"));
                }
            }
        }
        Ok(())
    }
    pub fn encode(&self, available: &BTreeSet<u32>) -> Result<String, String> {
        self.validate(available)?;
        let mut text =
            "; SHODAN 护甲组合选择；数值由被动参数独立管理。\n[settings]\nname = SHODAN armory\n"
                .to_string();
        for (id, group) in &self.groups {
            if !group.configured && group.profile.own && group.profile.enabled.is_empty() {
                continue;
            }
            text += &format!(
                "\n[profile: {id}]\nconflicts = {}\nown_passive = {}\n",
                if group.profile.policy == Policy::Strongest {
                    "strongest"
                } else {
                    "stack"
                },
                if group.profile.own { "on" } else { "off" }
            );
            let mut ids = group.profile.enabled.clone();
            ids.sort_unstable();
            for source in ids {
                text += &format!("{source} = on\n");
            }
        }
        Ok(text)
    }
    pub fn selection(
        &self,
        base: &BTreeMap<u32, Profile>,
        available: &BTreeSet<u32>,
    ) -> Result<BTreeMap<u32, Profile>, String> {
        self.validate(available)?;
        for (id, p) in base {
            if !available.contains(id) || p.enabled.iter().any(|s| !available.contains(s)) {
                return Err("基础护甲选择包含当前数据不存在的被动".into());
            }
        }
        let active = |g: &&Group| g.configured || !g.profile.own || !g.profile.enabled.is_empty();
        let every = self.groups.get(&EVERY).filter(active);
        let mut out = base.clone();
        for id in available {
            let Some(group) = self.groups.get(id).filter(active).or(every) else {
                continue;
            };
            let profile = out.entry(*id).or_default();
            profile.own = profile.own && group.profile.own;
            profile.policy = group.profile.policy;
            let mut ids: BTreeSet<_> = profile.enabled.iter().copied().collect();
            ids.extend(
                group
                    .profile
                    .enabled
                    .iter()
                    .copied()
                    .filter(|source| source != id || !group.profile.own),
            );
            profile.enabled = ids.into_iter().collect();
        }
        Ok(out)
    }
    pub fn counts(&self) -> (usize, usize) {
        let active: Vec<_> = self
            .groups
            .values()
            .filter(|g| !g.profile.own || !g.profile.enabled.is_empty())
            .collect();
        (
            active.len(),
            active.iter().map(|g| g.profile.enabled.len()).sum(),
        )
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn individual_empty_profile_overrides_every_and_roundtrips() {
        let ids = BTreeSet::from([1, 2, 42]);
        let parsed = Profiles::parse(
            "[profile: 所有护甲]\n侦察 = on\n[profile: 42]\nown_passive=on\n",
            &ids,
        )
        .unwrap();
        let profiles = parsed.profiles;
        let selection = profiles.selection(&BTreeMap::new(), &ids).unwrap();
        assert_eq!(selection[&1].enabled, vec![2]);
        assert!(selection[&2].enabled.is_empty());
        assert!(selection[&42].enabled.is_empty());
        assert_eq!(
            Profiles::parse(&profiles.encode(&ids).unwrap(), &ids)
                .unwrap()
                .profiles,
            profiles
        );
        assert_eq!(profiles.counts(), (1, 1));
    }
    #[test]
    fn base_own_off_and_numeric_lines_are_preserved_separately() {
        let ids = BTreeSet::from([1, 2]);
        let parsed=Profiles::parse("[profile: Every armor]\n1=yes\n1=off\n2=true\nMedic.damage=999\nconflicts=strongest\n[profile: not found]\n1=on",&ids).unwrap();
        assert_eq!(parsed.ignored_numeric, 1);
        assert_eq!(parsed.warnings.len(), 1);
        let base = BTreeMap::from([(
            1,
            Profile {
                own: false,
                enabled: vec![2],
                policy: Policy::Stack,
            },
        )]);
        let selection = parsed.profiles.selection(&base, &ids).unwrap();
        assert!(!selection[&1].own);
        assert_eq!(selection[&1].enabled, vec![2]);
        assert_eq!(selection[&1].policy, Policy::Strongest);
    }
}
