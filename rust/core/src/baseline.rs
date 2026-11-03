//! Pinned shipped baselines; current disk bytes are never promoted to defaults.
//! Matching the active game's version remains a separate caller requirement.
use crate::{
    dlbin, hash,
    tables::{self, Key, Layout, Table},
    Kind,
};

pub struct Baseline {
    bytes: Vec<u8>,
}
impl Baseline {
    pub fn shipped(file: &str, bytes: Vec<u8>) -> Result<Self, String> {
        let digest = match file {
            "generated_arc_settings.dl_plain" => {
                "b9319245ea9c018376878243f5516f816ed46b27441dde98b762c795035551fc"
            }
            "generated_damage_settings.dl_plain" => {
                "c28bce58c816a8008ca9e4a761eca6249c34680cb23c6f988a2435ec677c598d"
            }
            "generated_entities.dl_plain" => {
                "dc6d52a14900942b2f59f56bf8ab1552259832202dcb0745c3c84a009ff5f98b"
            }
            "generated_explosion_settings.dl_plain" => {
                "96d0b30f5ef3e68d882beca7058f16defce345d1631656ed1ee5f8907b3eea79"
            }
            "generated_projectile_settings.dl_plain" => {
                "a2f3046fb251bd7ce456e88db4df1d7e1def3b778df4a020ce3a631d7454ae82"
            }
            "generated_stratagem_settings.dl_plain" => {
                "925fc5da32a1e3a822807ea7571fd0979c571e5e4ea16142ee6a4968d40ca078"
            }
            _ => return Err("没有该文件的可信原值清单".into()),
        };
        Self::verified(bytes, digest)
    }
    fn verified(bytes: Vec<u8>, digest: &str) -> Result<Self, String> {
        if hash::sha256_hex(&bytes) != digest {
            return Err("原值文件指纹不匹配，不能作为默认值".into());
        }
        dlbin::index(&bytes).map_err(|e| e.to_string())?;
        Ok(Self { bytes })
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
        let blocks = dlbin::index(&self.bytes).map_err(|e| e.to_string())?;
        let matching: Vec<_> = blocks
            .iter()
            .filter(|b| b.type_id == current.type_id)
            .collect();
        if matching.is_empty() {
            return Ok(None);
        }
        if matching.len() != 1 {
            return Err("原值文件含有重复类型块，无法唯一对应".into());
        }
        let original = tables::parse(&self.bytes, matching[0], layout)?;
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
