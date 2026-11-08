//! Vehicle identities and active wheels come from the pinned original, not
//! user-modified files. Inner component GUIDs are not outer LDLD table IDs.
use super::{row, Bindings, Source};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;

#[derive(Deserialize)]
struct Vehicle {
    entity: String,
    wheels: Vec<usize>,
    components: Vec<String>,
}
type Spec<'a> = (&'a str, &'a str, usize, &'a str);

fn append(
    owner: &mut super::super::Owner,
    fields: &mut Bindings<'_>,
    vehicle: &Vehicle,
    typ: &str,
    section: &str,
    specs: &[Spec<'_>],
) {
    if !vehicle.components.iter().any(|component| component == typ) {
        return;
    }
    for &(id, label, offset, storage) in specs {
        if owner.rows.iter().any(|existing| existing.id == id) {
            continue;
        }
        // Reuse existing rows even when their public IDs differ. Never show
        // two controls for the same physical field.
        if owner.rows.iter().any(|existing| {
            existing.parts.iter().any(|part| {
                fields.fields[part.field].bindings.iter().any(|binding| {
                    binding["file"] == super::ENTITIES
                        && binding["type"] == typ
                        && binding["record"] == format!("hash:{}", vehicle.entity)
                        && binding["relative"].as_u64() == Some(offset as u64)
                })
            })
        }) {
            continue;
        }
        let field = fields.entity(typ, &vehicle.entity, offset, storage);
        let note = if let Some(note) = match id {
            "vehicle_fuel_min" => Some("载具生成时的最低初始燃料量；与容量共同决定初始油量。"),
            "vehicle_fuel_damaged" => Some("油箱损坏后每秒流失的燃料量。"),
            "vehicle_fast_exit" => {
                Some("下车动画的速度阈值（米/秒），不是载具速度上限；低于此值爬下，高于此值跳车。")
            }
            "vehicle_low_fuel" => Some("剩余燃料低于此比例时显示低油量警告。"),
            "motion_acceleration" => {
                Some("移动速度的增长速度；上游资料标注负值表示立即响应，尚待实机验证。")
            }
            "motion_friction" => Some("推测为地面摩擦系数；字段已定位，具体物理效果尚未实机验证。"),
            "motion_particle_speed" => {
                Some("进入高速状态、改变粒子效果的速度阈值（米/秒），不是最高车速。")
            }
            "motion_gear_time" => Some("变速箱损坏时的换挡时间倍率；大于 1 换挡更慢。"),
            "motion_steering" => {
                Some("从转向输入到实际响应的插值速度，越大响应越直接；不改变最大转向角。")
            }
            "motion_throttle" | "motion_brake" => {
                Some("输入响应的插值速度，越大响应越直接；不改变最高车速。")
            }
            "collision_demolition_lower_speed" | "collision_demolition_upper_speed" => {
                Some("单位：千米/小时。-1 沿用对应的普通碰撞伤害速度阈值。")
            }
            _ => None,
        } {
            note
        } else if label.contains("哈希") {
            "实验性：资源或骨骼名称的哈希编号，不是普通数值。须使用有效编号，随意修改可能导致载具异常。"
        } else if storage == "bool" {
            "控制此组件的行为；仅修改该开关，不改动相邻标志。写入后重新投送载具验证。"
        } else {
            "载具自身组件参数。写入后重新投送载具生效；实机效果尚未验证，可能同时受其他组件影响。原值取自对应版本的可信原始数据。"
        };
        owner.rows.push(row(
            id,
            label,
            section,
            if storage == "bool" { "flag" } else { storage },
            Value::Null,
            &[field],
            note,
            json!({}),
        ));
    }
}

pub(super) fn extend(data: &mut Source) {
    let inventory: BTreeMap<String, Vehicle> =
        serde_json::from_str(include_str!("../data/vehicle_inventory.json"))
            .expect("verified vehicle inventory");
    let mut fields = Bindings::new(&mut data.fields);
    for owner in &mut data.owners {
        let Some(vehicle) = inventory.get(&owner.id) else {
            continue;
        };
        append(
            owner,
            &mut fields,
            vehicle,
            "EAEB2B0D",
            "燃料与引擎（实验性）",
            &[
                ("vehicle_fuel_min", "初始燃料量下限", 0x860, "f32"),
                ("vehicle_fuel_max", "燃料容量", 0x864, "f32"),
                ("vehicle_fuel_idle", "怠速燃料消耗", 0x868, "f32"),
                ("vehicle_fuel_full", "全油门燃料消耗", 0x86C, "f32"),
                (
                    "vehicle_fuel_damaged",
                    "油箱受损燃料泄漏（每秒）",
                    0x870,
                    "f32",
                ),
                ("vehicle_fast_exit", "快速下车动画速度阈值", 0x874, "f32"),
                ("vehicle_engine_start", "引擎启动时间（秒）", 0x878, "f32"),
                ("vehicle_low_fuel", "低燃料警告阈值", 0x87C, "f32"),
            ],
        );
        append(
            owner,
            &mut fields,
            vehicle,
            "EAEB2B0D",
            "载具效果（实验性）",
            &[
                ("vehicle_dust_min_speed", "扬尘最低速度", 0x850, "f32"),
                ("vehicle_dust_max_speed", "扬尘最高速度", 0x854, "f32"),
                ("vehicle_dust_min_amount", "最低扬尘量", 0x858, "f32"),
                ("vehicle_dust_max_amount", "最高扬尘量", 0x85C, "f32"),
                ("vehicle_nav_radius", "导航视线检测半径", 0xDA4, "f32"),
                (
                    "vehicle_landing_air_time",
                    "触发落地效果的腾空时间（秒）",
                    0xE40,
                    "f32",
                ),
                ("vehicle_landing_impact", "落地冲击效果编号", 0xE44, "u32"),
                ("vehicle_spawn_state", "生成状态编号", 0x000, "u32"),
                ("vehicle_migrated_state", "迁移状态编号", 0x004, "u32"),
                ("vehicle_track_animation", "履带动画标志", 0x808, "u8"),
                ("vehicle_audio_source", "音效来源哈希", 0x80C, "u32"),
                ("vehicle_hud_type", "载具界面类型编号", 0xE5C, "u32"),
                ("vehicle_ignore_motion", "忽略运动标志（0/1）", 0xE50, "u32"),
                ("vehicle_kill_height", "检测致死高度（0/1）", 0xE54, "u32"),
                (
                    "vehicle_hud_left_low",
                    "左侧界面资源哈希（低32位）",
                    0x818,
                    "u32",
                ),
                (
                    "vehicle_hud_left_high",
                    "左侧界面资源哈希（高32位）",
                    0x81C,
                    "u32",
                ),
                (
                    "vehicle_hud_right_low",
                    "右侧界面资源哈希（低32位）",
                    0x820,
                    "u32",
                ),
                (
                    "vehicle_hud_right_high",
                    "右侧界面资源哈希（高32位）",
                    0x824,
                    "u32",
                ),
            ],
        );
        for &wheel in &vehicle.wheels {
            let base = 8 + wheel * 64;
            let section = format!("车轮 {} 悬挂（实验性）", wheel + 1);
            for (suffix, label, relative, storage) in [
                ("length", "悬挂长度", 0, "f32"),
                ("drive", "驱动轮", 4, "bool"),
                ("trigger", "悬挂触发阈值", 8, "f32"),
                ("maxed", "悬挂压缩极限阈值", 12, "f32"),
                ("suspension_node", "悬挂骨骼哈希", 16, "u32"),
                ("steering_node", "转向骨骼哈希", 20, "u32"),
                ("rotation_node", "旋转骨骼哈希", 24, "u32"),
                ("suspension_animation", "悬挂动画变量哈希", 28, "u32"),
                ("rotation_animation", "旋转动画变量哈希", 32, "u32"),
            ] {
                append(
                    owner,
                    &mut fields,
                    vehicle,
                    "EAEB2B0D",
                    &section,
                    &[(
                        &format!("wheel{}_{}", wheel + 1, suffix),
                        label,
                        base + relative,
                        storage,
                    )],
                );
            }
        }
        for slot in 0..5 {
            append(
                owner,
                &mut fields,
                vehicle,
                "EAEB2B0D",
                "悬挂效果（实验性）",
                &[(
                    &format!("vehicle_suspension_effect{}_cooldown", slot + 1),
                    &format!("悬挂效果 {} 冷却时间（秒）", slot + 1),
                    0xDA8 + slot * 24 + 16,
                    "f32",
                )],
            );
            for (suffix, label, offset) in [
                ("anchor_a", "挂点骨骼哈希", 8),
                ("anchor_c", "挂点脚本名称哈希", 16),
            ] {
                append(
                    owner,
                    &mut fields,
                    vehicle,
                    "3845B1E0",
                    "挂载（实验性功能）",
                    &[(
                        &format!("mount{}_{}", slot + 1, suffix),
                        &format!("槽 {} {}", slot + 1, label),
                        slot * 24 + offset,
                        "u32",
                    )],
                );
            }
        }
        append(
            owner,
            &mut fields,
            vehicle,
            "4AEAFC86",
            "座位行为（实验性）",
            &[
                ("seat_transition", "上下车动画编号", 0, "u32"),
                ("seat_root_motion", "使用动画根运动", 0x108, "bool"),
                ("seat_inherit_velocity", "下车继承载具速度", 0x109, "bool"),
                ("seat_kill_passengers", "摧毁时杀死乘员", 0x10A, "bool"),
                ("seat_kill_attachments", "摧毁时销毁附着物", 0x10B, "bool"),
                ("seat_door_open", "车门初始打开", 0x10C, "bool"),
                ("seat_block_check", "检查入口遮挡", 0x10D, "bool"),
                ("seat_ignore_entrance", "忽略入口检查", 0x10E, "bool"),
                ("seat_music", "启用载具音乐", 0x10F, "bool"),
                ("seat_stratagem", "允许使用战略配备", 0x110, "bool"),
                ("seat_holster", "收起乘员武器", 0x111, "bool"),
                ("seat_occupy_audio", "入座音效哈希", 0x128, "u32"),
                ("seat_leave_audio", "离座音效哈希", 0x12C, "u32"),
                ("seat_manual_leave", "允许手动离座", 0x130, "bool"),
                ("seat_hide_nameplate", "隐藏乘员名牌", 0x131, "bool"),
            ],
        );
        for passenger in 0..16 {
            append(
                owner,
                &mut fields,
                vehicle,
                "4AEAFC86",
                "乘员入口（实验性）",
                &[(
                    &format!("seat_passenger{}_entrance", passenger + 1),
                    &format!("乘员 {} 入口编号", passenger + 1),
                    8 + passenger * 16,
                    "u32",
                )],
            );
        }
        append(
            owner,
            &mut fields,
            vehicle,
            "83B65443",
            "驾驶响应（实验性）",
            &[
                ("motion_acceleration", "加速度", 0, "f32"),
                ("motion_friction", "摩擦系数", 4, "f32"),
                ("motion_particle_speed", "高速状态粒子速度阈值", 0xC, "f32"),
                ("motion_damaged_rpm", "受损引擎转速倍率", 0x158, "f32"),
                ("motion_damaged_torque", "受损引擎扭矩倍率", 0x15C, "f32"),
                ("motion_gear_time", "变速箱受损换挡时间倍率", 0x160, "f32"),
                ("motion_rim_radius", "无轮胎轮辋半径", 0x164, "f32"),
                (
                    "motion_damaged_wheel_friction",
                    "受损车轮摩擦倍率",
                    0x168,
                    "f32",
                ),
                ("motion_steering", "转向响应速度", 0x16C, "f32"),
                ("motion_throttle", "油门响应速度", 0x170, "f32"),
                ("motion_brake", "制动响应速度", 0x174, "f32"),
            ],
        );
        append(
            owner,
            &mut fields,
            vehicle,
            "20288698",
            "碰撞伤害（实验性）",
            &[
                (
                    "collision_lower_speed",
                    "造成伤害的最低速度（千米/小时）",
                    0,
                    "f32",
                ),
                (
                    "collision_upper_speed",
                    "伤害达到上限的速度（千米/小时）",
                    4,
                    "f32",
                ),
                ("collision_force", "撞击力度倍率", 8, "f32"),
                ("collision_character_absorb", "角色碰撞吸收比例", 12, "f32"),
                ("collision_damage_base", "基础碰撞伤害", 16, "f32"),
                ("collision_damage_upper", "碰撞伤害上限", 20, "f32"),
                ("collision_demolition_base", "基础拆毁力", 24, "f32"),
                ("collision_demolition_upper", "拆毁力上限", 28, "f32"),
                ("collision_knockback_base", "基础击退力", 32, "f32"),
                ("collision_knockback_upper", "击退力上限", 36, "f32"),
                (
                    "collision_self_lower_speed",
                    "承受自损的最低速度（千米/小时）",
                    40,
                    "f32",
                ),
                (
                    "collision_self_upper_speed",
                    "自损达到上限的速度（千米/小时）",
                    44,
                    "f32",
                ),
                ("collision_self_damage_base", "基础碰撞自损", 48, "f32"),
                ("collision_self_damage_upper", "碰撞自损上限", 52, "f32"),
                ("collision_impact_absorb", "撞击吸收比例", 56, "f32"),
                (
                    "collision_demolition_lower_speed",
                    "拆毁最低速度（-1沿用伤害阈值）",
                    60,
                    "f32",
                ),
                (
                    "collision_demolition_upper_speed",
                    "拆毁上限速度（-1沿用伤害阈值）",
                    64,
                    "f32",
                ),
                ("collision_damage_type", "碰撞伤害类型编号", 72, "u32"),
                (
                    "collision_self_inward_distance",
                    "自损向内检测距离",
                    76,
                    "f32",
                ),
            ],
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn inventory_ignores_empty_wheel_defaults() {
        let inventory: BTreeMap<String, Vehicle> =
            serde_json::from_str(include_str!("../data/vehicle_inventory.json")).unwrap();
        assert!(inventory["00000000119EF38F"].wheels.is_empty());
        assert_eq!(inventory["00000000EA902C4B"].wheels.len(), 4);
        assert_eq!(inventory["0801B6B3C5D12EBC"].wheels.len(), 10);
        assert_eq!(inventory["000000001B7853AC"].wheels.len(), 10);
    }
}
