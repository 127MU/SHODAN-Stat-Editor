//! Pinned shipped baselines; current disk bytes are never promoted to defaults.
//! Matching the active game's version remains a separate caller requirement.
use crate::{
    dlbin, hash,
    tables::{self, Key, Layout, Table},
    Kind,
};
use std::{collections::BTreeMap, sync::Mutex};

pub struct Baseline {
    bytes: Vec<u8>,
    blocks: Vec<dlbin::Block>,
    tables: Mutex<BTreeMap<(u32, u8, usize, usize), Table>>,
}
impl Baseline {
    pub fn shipped(file: &str, bytes: Vec<u8>) -> Result<Self, String> {
        // The 26251122 damage and projectile tables were decrypted from copies
        // matching the published vanilla file fingerprints for that build.
        let digest = match file {
            // Build 26251122: independently matched to Steam depot 553853,
            // manifest 87932884035420122 (exact sealed-file SHA-1 + size).
            // See offline/originals/depot-baseline-evidence.json.
            "generated_customization_armor_sets.dl_plain" => {
                "9dab2ea0b40a11e5d3b16eb5bd3d3e7d87fe61f34c0a060313162c82d3fe6274"
            }
            "generated_entity_deltas.dl_plain" => {
                "78841155dfe02f567cbc7c21239a16fd5273910a9f0ce9537fc9a9c86b3f9ca7"
            }
            "generated_status_effect_settings.dl_plain" => {
                "19a98ff7151ddad048cbf1b292fd2d4c59d9fcad1b546a57446d7329de487a2e"
            }
            "generated_destruction_settings.dl_plain" => {
                "de7fd850f68bf0e7f64f61dfc0ddaa2df6769a3a7660bb075ce24f120b3d8c87"
            }
            "generated_beam_settings.dl_plain" => {
                "19989b016123c1f0816107e1352fa740e67ff5b134e77129fe04ce72a66b8a30"
            }
            "generated_customization_passive_bonuses.dl_plain" => {
                "6ba67061fa05b1aa98cd9cbea19df182a80c6c07c5294440c6da41f3bbb8ad40"
            }
            "generated_arc_settings.dl_plain" => {
                "b9319245ea9c018376878243f5516f816ed46b27441dde98b762c795035551fc"
            }
            "generated_damage_settings.dl_plain" => {
                "240343e52c73c7d58c2806216171e2ac58e8a7aed8fc1ca25080e03873dd72eb"
            }
            "generated_entities.dl_plain" => {
                "dc6d52a14900942b2f59f56bf8ab1552259832202dcb0745c3c84a009ff5f98b"
            }
            "generated_explosion_settings.dl_plain" => {
                "96d0b30f5ef3e68d882beca7058f16defce345d1631656ed1ee5f8907b3eea79"
            }
            "generated_projectile_settings.dl_plain" => {
                "18419e3ee058fbd4ef68bca6ab42da7ff2cf59f7e87c24428057d04f21e9f43d"
            }
            "generated_stratagem_settings.dl_plain" => {
                "5a5d54a1d0acab62b4e657f3bdb3ab55e4f279d43482f6d1edafe762a4bc7c2d"
            }
            _ => return Err("没有该文件的可信原值清单".into()),
        };
        Self::verified(bytes, digest)
    }
    pub(crate) fn bytes(&self) -> &[u8] {
        &self.bytes
    }
    pub(crate) fn into_bytes(self) -> Vec<u8> {
        self.bytes
    }
    fn verified(bytes: Vec<u8>, digest: &str) -> Result<Self, String> {
        if hash::sha256_hex(&bytes) != digest {
            return Err("原值文件指纹不匹配，不能作为默认值".into());
        }
        let blocks = dlbin::index(&bytes).map_err(|e| e.to_string())?;
        Ok(Self {
            bytes,
            blocks,
            tables: Mutex::new(BTreeMap::new()),
        })
    }
    /// Locate by type + stable record key, never by current row position.
    /// Missing keys return None; ambiguous block/key layouts fail closed.
    pub fn original(
        &self,
        current: &Table,
        layout: Layout,
        key: Key,
        relative: usize,
        kind: Kind,
    ) -> Result<Option<f64>, String> {
        if current.duplicate_keys != 0 {
            return Err("当前表存在重复记录 ID，无法对应原值".into());
        }
        current.field_offset(key, relative, 4)?;
        let matching: Vec<_> = self
            .blocks
            .iter()
            .filter(|b| b.type_id == current.type_id)
            .collect();
        if matching.is_empty() {
            return Ok(None);
        }
        if matching.len() != 1 {
            return Err("原值文件含有重复类型块，无法唯一对应".into());
        }
        let cachekey = match layout {
            Layout::Rows { stride, id_offset } => (current.type_id, 0, stride, id_offset),
            Layout::Keyed { stride, slack } => (current.type_id, 1, stride, slack),
        };
        let mut cache = self.tables.lock().map_err(|_| "原值索引缓存不可用")?;
        if let std::collections::btree_map::Entry::Vacant(entry) = cache.entry(cachekey) {
            entry.insert(tables::parse(&self.bytes, matching[0], layout)?);
        }
        let original = &cache[&cachekey];
        if original.duplicate_keys != 0 {
            return Err("原值表存在重复记录 ID".into());
        }
        if !original.rows.contains_key(&key) {
            return Ok(None);
        }
        original
            .read_number(&self.bytes, key, relative, kind)
            .map(Some)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn depot_matched_baselines_are_pinned_and_reject_modified_bytes() {
        let folder =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../offline/originals");
        for stem in [
            "customization_armor_sets",
            "entity_deltas",
            "status_effect_settings",
            "destruction_settings",
            "beam_settings",
            "stratagem_settings",
        ] {
            let name = format!("generated_{stem}.dl_plain");
            let bytes = std::fs::read(folder.join(&name)).unwrap();
            assert!(Baseline::shipped(&name, bytes.clone()).is_ok(), "{name}");
            let mut modified = bytes;
            *modified.last_mut().unwrap() ^= 1;
            assert!(Baseline::shipped(&name, modified).is_err(), "{name}");
        }
    }
    fn fixture(rows: &[(u32, f32)]) -> Vec<u8> {
        let mut data = b"LDLD\x01\0\0\0".to_vec();
        data.extend(1u32.to_le_bytes());
        data.extend(((16 + rows.len() * 8) as u32).to_le_bytes());
        data.extend([0; 8]);
        data.extend([0; 8]);
        data.extend((rows.len() as u32).to_le_bytes());
        data.extend([0; 4]);
        for (id, value) in rows {
            data.extend(id.to_le_bytes());
            data.extend(value.to_le_bytes());
        }
        data
    }
    #[test]
    fn reordered_modified_records_keep_their_true_originals() {
        let bytes = fixture(&[(1, 10.0), (2, 20.0)]);
        let baseline = Baseline::verified(bytes.clone(), &hash::sha256_hex(&bytes)).unwrap();
        let disk = fixture(&[(2, 999.0), (1, 888.0), (3, 777.0)]);
        let layout = Layout::Rows {
            stride: 8,
            id_offset: 0,
        };
        let table = tables::parse(&disk, &dlbin::index(&disk).unwrap()[0], layout).unwrap();
        assert_eq!(
            baseline
                .original(&table, layout, Key::Id(2), 4, Kind::F32)
                .unwrap(),
            Some(20.0)
        );
        assert_eq!(
            baseline
                .original(&table, layout, Key::Id(1), 4, Kind::F32)
                .unwrap(),
            Some(10.0)
        );
        assert_eq!(
            baseline
                .original(&table, layout, Key::Id(3), 4, Kind::F32)
                .unwrap(),
            None
        );
        assert!(baseline
            .original(&table, layout, Key::Id(1), 6, Kind::F32)
            .is_err());
        assert!(Baseline::verified(disk, &hash::sha256_hex(&bytes)).is_err());
        assert!(Baseline::shipped("unknown", bytes).is_err());
    }
}
