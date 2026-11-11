//! Additions verified against the 26251122 table layouts. Entries use row
//! identities instead of absolute offsets in the loose file. The layouts were
//! re-checked unchanged on Steam build 26568081.
use super::{Field, Row, Source};
use serde_json::{json, Value};
use std::collections::BTreeMap;

#[path = "catalog_vehicles.rs"]
mod vehicles;

const BUILD: &str = "08b756f535cdb9bdd1b4953fba53c3dfacd25730a155ea6593e5de63211acf5f";
const ENTITIES: &str = "generated_entities.dl_bin";
const WEAPON: &str = "88E4DBB1";
const SEEKING: &str = "BF3A6789";
const SPEAR: &str = "25AA2FD4643CF4EE";
const WASP: &str = "CC786F6491FE7E65";
const AVATAR: &str = "4D1C334D294DFA97";
const LAS17: &str = "295BEB26DC4F8FF1";

type Index = BTreeMap<(String, String, String, usize, String), usize>;

struct Bindings<'a> {
    fields: &'a mut Vec<Field>,
    index: Index,
}
impl<'a> Bindings<'a> {
    fn new(fields: &'a mut Vec<Field>) -> Self {
        let mut index = Index::new();
        for (i, field) in fields.iter().enumerate() {
            if field.bindings.len() != 1
                || field.encoding.as_ref().and_then(Value::as_str) != Some(field.storage.as_str())
            {
                continue;
            }
            let binding = &field.bindings[0];
            let (Some(file), Some(typ), Some(record), Some(relative)) = (
                binding["file"].as_str(),
                binding["type"].as_str(),
                binding["record"].as_str(),
                binding["relative"].as_u64(),
            ) else {
                continue;
            };
            index
                .entry((
                    file.into(),
                    typ.into(),
                    record.into(),
                    relative as usize,
                    field.storage.clone(),
                ))
                .or_insert(i);
        }
        Self { fields, index }
    }

    fn field(
        &mut self,
        file: &str,
        typ: &str,
        record: String,
        relative: usize,
        storage: &str,
    ) -> usize {
        let key = (
            file.into(),
            typ.into(),
            record.clone(),
            relative,
            storage.into(),
        );
        *self.index.entry(key).or_insert_with(|| {
            let index = self.fields.len();
            self.fields.push(Field {
                key: format!("{file}:{typ}:{record}:{relative}:{storage}"),
                storage: storage.into(),
                bindings: vec![json!({"file":file,"type":typ,"record":record,"relative":relative})],
                encoding: Some(json!(storage)),
                resource: None,
                virtual_default: None,
                stratagem_code: None,
                stratagem_always: None,
                switch: None,
                toggle: None,
                allowed: vec![],
                unset: None,
                auto_drop: None,
                death: None,
                unresolved: None,
            });
            index
        })
    }

    fn entity(&mut self, typ: &str, id: &str, offset: usize, storage: &str) -> usize {
        self.field(ENTITIES, typ, format!("hash:{id}"), offset, storage)
    }
}

fn row(
    id: &str,
    label: &str,
    section: &str,
    storage: &str,
    choice: Value,
    fields: &[usize],
    note: &str,
    recipes: Value,
) -> Row {
    serde_json::from_value(json!({
        "id":id, "key":id, "label":label, "section":section, "storage":storage,
        "choice":choice, "help":if note.is_empty() {vec![]} else {vec![note]},
        "parts":fields.iter().enumerate().map(|(i,f)| json!({
            "id":if fields.len() == 1 {id.into()} else {format!("{id}_part{}", i+1)},
            "field":f
        })).collect::<Vec<_>>(),
        "recipes":recipes
    }))
    .expect("static supplemental row schema")
}

fn spear_dual(fields: &mut Bindings<'_>) -> Row {
    let mut targets = Vec::new();
    let mut steps = Vec::new();
    for (typ, offset, storage, value) in [
        (WEAPON, 0xB8, "u32", 8),
        (WEAPON, 0x198, "u32", 8),
        (WEAPON, 0x19C, "u32", 0),
        (WEAPON, 0x1A0, "u32", 16),
        (WEAPON, 0x1A4, "u32", 8),
        (WEAPON, 0x1A8, "u32", 1),
        (WEAPON, 0x1AC, "u32", 4),
        ("45171B68", 0x240, "u32", 223),
        ("84957034", 0x48, "u32", 8),
        ("84957034", 0x58, "u32", 1),
        ("84957034", 0x5C, "u8", 1),
    ] {
        targets.push(fields.entity(typ, SPEAR, offset, storage));
        steps.push(json!(value));
    }
    row("spear_dual", "制导与直射双模式（实验性）", "制导", "u32", json!("spear_dual"), &targets,
        "第一档保留锁定发射，第二档使用飞矛自带的无制导射弹 #223 和该射弹的原有参数。需要原配主射弹。菜单沿用游戏原有标签，原版炮口可能让直射稍向上偏。",
        json!({"1":steps}))
}

pub(super) fn extend(data: &mut Source) {
    if data.game_build.as_deref() != Some(BUILD) {
        return;
    }
    vehicles::extend(data);
    let mut fields = Bindings::new(&mut data.fields);
    for owner in &mut data.owners {
        let id = owner.id.as_str();
        match id {
            // Only the four verified one-shot weapons. The value is the
            // auto-drop ability token, which can also be used by infinite ammo.
            "80932FA0ED6901D3" | "B2B5E0D185605F9E" | "7617642765AC38C7" | "5990123D142B16CB" => {
                let field = fields.entity(WEAPON, id, 0x1D0, "u32");
                owner.rows.push(row(
                    "empty_weapon",
                    "打空后的处理",
                    "弹药",
                    "u32",
                    json!("empty_weapon"),
                    &[field],
                    "打空后仍可握持武器。此选项不提供备弹或换弹能力。",
                    json!({"1":[0]}),
                ));
            }
            SPEAR => {
                let targets = [
                    (0x0C, "f32"),
                    (0xB4, "u8"),
                    (0xC0, "f32"),
                    (0xC4, "f32"),
                    (0xE8, "f32"),
                    (0xF0, "f32"),
                ]
                .map(|(offset, storage)| {
                    fields.entity(SEEKING, "1A4323835B84CEA7", offset, storage)
                });
                owner.rows.push(row(
                    "spear_arc",
                    "锁定弹道",
                    "制导",
                    "u32",
                    json!("spear_arc"),
                    &targets,
                    "只影响锁定发射的飞矛导弹。高抛先爬升，再转向目标。",
                    json!({"1":[0.01,1,60,75,0.2,0.8]}),
                ));
                owner.rows.push(spear_dual(&mut fields));
            }
            WASP => {
                let targets = [0xB8, 0xBC, 0xC0, 0xC4, 0xE4]
                    .map(|offset| fields.entity(SEEKING, "14CC0DB942F6D7F2", offset, "f32"));
                owner.rows.push(row(
                    "wasp_burst",
                    "连发档弹道",
                    "制导",
                    "u32",
                    json!("wasp_burst"),
                    &targets,
                    "仅调整连发档的导弹，炮击档仍使用原配置。",
                    json!({"1":[null,null,null,null,2],"2":[-15,15,10,15,2]}),
                ));
            }
            LAS17 => {
                for (tier, threshold) in [(1, 25), (2, 50), (3, 95)] {
                    let field = fields.entity("4C981CD9", id, 20 + (tier - 1) * 24, "u32");
                    owner.rows.push(row(&format!("heatlvl{tier}_status"), "对持枪者施加的状态",
                        &format!("热量高于 {threshold}%"), "u32", json!("heat_status"), &[field],
                        "这是该热量档施加给持枪者的状态。选择「无」可清除该档状态，弹丸和命中效果由其他参数决定。",
                        json!({})));
                }
            }
            AVATAR => {
                for (key, label, offset, section) in [
                    ("slide_cost", "滑步体力消耗（比例）", 0x5C, "耐力"),
                    (
                        "slope_enter_delay",
                        "进入滑行前的时间（秒）",
                        0x9C,
                        "攀爬与滑行",
                    ),
                    (
                        "slope_speed",
                        "陡坡自动滑行速度（米/秒）",
                        0xA0,
                        "攀爬与滑行",
                    ),
                    ("slope_gravity", "陡坡滑行重力倍率", 0xA4, "攀爬与滑行"),
                    (
                        "slope_min_time",
                        "陡坡最短滑行时间（秒）",
                        0xA8,
                        "攀爬与滑行",
                    ),
                    (
                        "slope_exit_delay",
                        "超过可行走坡度后的退出延迟（秒）",
                        0xB0,
                        "攀爬与滑行",
                    ),
                    ("slide_flat_time", "平地滑步时间（秒）", 0xD0, "攀爬与滑行"),
                    (
                        "slide_flat_speed",
                        "平地滑步速度（米/秒）",
                        0xD4,
                        "攀爬与滑行",
                    ),
                    ("slide_up_time", "上坡滑步时间（秒）", 0xD8, "攀爬与滑行"),
                    (
                        "slide_up_speed",
                        "上坡滑步速度（米/秒）",
                        0xDC,
                        "攀爬与滑行",
                    ),
                    ("slide_down_time", "下坡滑步时间（秒）", 0xE0, "攀爬与滑行"),
                    (
                        "slide_down_speed",
                        "下坡滑步速度（米/秒）",
                        0xE4,
                        "攀爬与滑行",
                    ),
                ] {
                    let field = fields.entity("40EF204C", id, offset, "f32");
                    owner.rows.push(row(
                        key,
                        label,
                        section,
                        "f32",
                        Value::Null,
                        &[field],
                        "潜兵基础动作数值。实际表现也可能受护甲重量、被动和实体覆盖影响。",
                        json!({}),
                    ));
                }
            }
            _ => {}
        }
    }
}
