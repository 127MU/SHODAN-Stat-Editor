//! Native record field descriptions. Offsets follow the 4.6.0 data definitions.
use crate::Kind;
pub struct Parameter {
    pub id: String,
    pub label: String,
    pub relative: usize,
    pub kind: Kind,
}
pub fn parameters(type_id: u32) -> Vec<Parameter> {
    let mut fields = Vec::new();
    let mut add = |id: &str, label: &str, relative, kind| {
        fields.push(Parameter {
            id: id.into(),
            label: label.into(),
            relative,
            kind,
        })
    };
    match type_id {
        0xE0A72CF0 => {
            for (id, label, offset) in [
                ("damage", "伤害", 4),
                ("durable", "耐久伤害", 8),
                ("ap_direct", "穿甲等级（正面）", 12),
                ("ap_slight", "穿甲等级（小倾角）", 16),
                ("ap_large", "穿甲等级（大倾角）", 20),
                ("ap_extreme", "穿甲等级（极端倾角）", 24),
                ("demolition", "拆毁能力", 28),
                ("stagger", "踉跄强度", 32),
                ("push", "击退力度", 36),
            ] {
                add(id, label, offset, Kind::U32);
            }
            for slot in 0..4 {
                add(
                    &format!("slot{}_type", slot + 1),
                    &format!("状态效果 {} 类型", slot + 1),
                    44 + slot * 8,
                    Kind::U32,
                );
                add(
                    &format!("slot{}_strength", slot + 1),
                    &format!("状态效果 {} 强度（每次命中）", slot + 1),
                    48 + slot * 8,
                    Kind::F32,
                );
            }
        }
        0xBD4042C2 => {
            for (id, label, offset) in [
                ("calibre", "口径（毫米）", 24),
                ("velocity", "初速（米/秒）", 32),
                ("mass", "质量（千克）", 36),
                ("drag", "阻力系数", 40),
                ("gravity", "重力系数（可为负数）", 44),
                ("lifetime", "射弹寿命（秒）", 52),
                ("lifetime_random", "寿命随机量（秒）", 56),
                ("pen_slowdown", "穿透减速", 64),
                ("blast_angle", "爆炸角（度）", 136),
                ("fuse_proximity", "近炸引信距离（米）", 148),
                ("fuse_delay", "引爆延迟（秒）", 152),
            ] {
                add(id, label, offset, Kind::F32);
            }
            for (id, label, offset) in [
                ("pellets", "每次射击弹丸数", 28),
                ("steps", "模拟步数", 48),
                ("impact_explosion", "命中爆炸 ID", 144),
                ("expiry_explosion", "到期爆炸 ID", 156),
                ("max_ricochets", "最大跳弹次数", 180),
            ] {
                add(id, label, offset, Kind::U32);
            }
        }
        _ => {}
    }
    fields
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn mass_and_gravity_are_floats_and_all_four_status_strengths_are_present() {
        let fields = parameters(0xBD4042C2);
        for name in ["mass", "gravity"] {
            assert_eq!(
                fields.iter().find(|f| f.id == name).unwrap().kind,
                Kind::F32
            );
        }
        assert_eq!(fields.iter().filter(|f| f.id == "blast_angle").count(), 1);
        let damage = parameters(0xE0A72CF0);
        let fourth = damage.iter().find(|f| f.id == "slot4_strength").unwrap();
        assert_eq!(fourth.relative, 72);
        assert_eq!(fourth.kind, Kind::F32);
        let mut ids = std::collections::BTreeSet::new();
        for f in fields.iter().chain(&damage) {
            assert!(ids.insert((f.relative, f.id.clone())));
        }
    }
}
