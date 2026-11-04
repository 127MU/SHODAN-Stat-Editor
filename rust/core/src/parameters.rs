//! Logical owner/parameter bindings and conflict-aware preset plans.
//! The owner is a full hash string, never a lossy JSON number.
use crate::{
    preset::Preset,
    session::{Field, Session},
};
use std::collections::BTreeMap;

#[derive(Default)]
pub struct Parameters {
    bindings: BTreeMap<(String, String), Vec<Field>>,
}
pub struct Plan {
    pub edits: Vec<(Field, f64)>,
    pub warnings: Vec<String>,
    pub changes: Vec<(String, String, f64, f64)>,
}
fn owner(value: &str) -> Result<String, String> {
    if value.len() != 16 || !value.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("装备标识必须是完整的 16 位哈希".into());
    }
    Ok(value.to_ascii_uppercase())
}
impl Parameters {
    pub fn bind(
        &mut self,
        session: &Session,
        hash: &str,
        parameter: &str,
        fields: Vec<Field>,
    ) -> Result<(), String> {
        let hash = owner(hash)?;
        if parameter.is_empty()
            || !parameter
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_')
        {
            return Err("参数标识无效".into());
        }
        if fields.is_empty() {
            return Err("参数不能绑定空字段".into());
        }
        for field in &fields {
            session.value(*field)?;
        }
        self.bindings.insert((hash, parameter.into()), fields);
        Ok(())
    }
    /// Missing parameters are skipped only after an explicit caller decision.
    /// All shared-field conflicts and storage errors reject the entire plan.
    pub fn plan(
        &self,
        session: &Session,
        preset: &Preset,
        allow_missing: bool,
    ) -> Result<Plan, String> {
        if preset.armor.is_some() {
            return Err("护甲配置应用尚未完成原生迁移，未应用任何参数".into());
        }
        let mut plan = Plan {
            edits: Vec::new(),
            warnings: Vec::new(),
            changes: Vec::new(),
        };
        let mut physical = BTreeMap::new();
        for value in &preset.values {
            let key = (owner(&value.owner)?, value.parameter.clone());
            let Some(fields) = self.bindings.get(&key) else {
                let why = format!("当前数据没有参数：{} / {}", key.0, key.1);
                if !allow_missing {
                    return Err(why);
                }
                plan.warnings.push(why);
                continue;
            };
            for field in fields {
                let (offset, bytes) = session.encoded_field(*field, value.value)?;
                if let Some(previous) = physical.insert(offset, bytes) {
                    if previous != bytes {
                        return Err(format!("预设对共享字段赋予冲突数值：{}", key.1));
                    }
                    continue;
                }
                let current = session.value(*field)?.current;
                let encoded = crate::read(&bytes, 0, field.kind).map_err(str::to_string)?;
                plan.changes
                    .push((key.0.clone(), key.1.clone(), current, encoded));
                plan.edits.push((*field, value.value));
            }
        }
        // Also reject partial overlaps, regardless of field names or storage types.
        let offsets: Vec<_> = physical.keys().copied().collect();
        if offsets.windows(2).any(|v| v[1] - v[0] < 4) {
            return Err("预设字段范围重叠".into());
        }
        Ok(plan)
    }
    pub fn apply(
        &self,
        session: &mut Session,
        preset: &Preset,
        allow_missing: bool,
    ) -> Result<Plan, String> {
        let plan = self.plan(session, preset, allow_missing)?;
        session.apply_batch(&plan.edits)?;
        Ok(plan)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        preset::Value,
        tables::{Key, Layout},
        Kind,
    };
    fn setup() -> (Session, Parameters) {
        let mut bytes = b"LDLD\x01\0\0\0".to_vec();
        bytes.extend(0xBD4042C2u32.to_le_bytes());
        bytes.extend(288u32.to_le_bytes());
        bytes.extend([0; 8]);
        bytes.extend([0; 8]);
        bytes.extend(1u32.to_le_bytes());
        bytes.extend([0; 4]);
        let mut row = vec![0; 272];
        row[..4].copy_from_slice(&67u32.to_le_bytes());
        row[36..40].copy_from_slice(&1.0f32.to_le_bytes());
        bytes.extend(row);
        let mut session = Session::new(bytes, None).unwrap();
        session
            .index_table(
                0,
                Layout::Rows {
                    stride: 272,
                    id_offset: 0,
                },
            )
            .unwrap();
        let mass = session.named_field(0, Key::Id(67), "mass").unwrap();
        assert_eq!(mass.kind, Kind::F32);
        let mut registry = Parameters::default();
        registry
            .bind(&session, "FFFFFFFFFFFFFFFF", "mass", vec![mass])
            .unwrap();
        registry
            .bind(&session, "0000000000000001", "mass", vec![mass])
            .unwrap();
        (session, registry)
    }
    fn preset(values: Vec<Value>) -> Preset {
        Preset {
            kind: "full".into(),
            name: "测试".into(),
            weapon: None,
            editor: None,
            armor: None,
            values,
        }
    }
    fn value(owner: &str, parameter: &str, value: f64) -> Value {
        Value {
            owner: owner.into(),
            parameter: parameter.into(),
            value,
        }
    }
    #[test]
    fn shared_conflicts_and_missing_fields_do_not_partially_apply() {
        let (mut s, r) = setup();
        let p = preset(vec![
            value("FFFFFFFFFFFFFFFF", "mass", 1e6),
            value("0000000000000001", "mass", 1.0),
        ]);
        assert!(r.apply(&mut s, &p, false).is_err());
        assert_eq!(s.pending_count(), 0);
        let p = preset(vec![
            value("FFFFFFFFFFFFFFFF", "mass", 1e6),
            value("0000000000000001", "unknown", 2.0),
        ]);
        assert!(r.apply(&mut s, &p, false).is_err());
        assert_eq!(s.pending_count(), 0);
        let plan = r.apply(&mut s, &p, true).unwrap();
        assert_eq!(plan.warnings.len(), 1);
        assert_eq!(s.history(), (1, 0));
        assert!(s.undo());
        assert_eq!(s.pending_count(), 0);
    }
    #[test]
    fn identical_aliases_are_applied_once_and_armor_is_not_silently_lost() {
        let (mut s, r) = setup();
        let mut p = preset(vec![
            value("FFFFFFFFFFFFFFFF", "mass", 1e6),
            value("0000000000000001", "mass", 1e6),
        ]);
        assert_eq!(r.apply(&mut s, &p, false).unwrap().edits.len(), 1);
        p.armor = Some("unmigrated".into());
        assert!(r.plan(&s, &p, true).is_err());
    }
}
