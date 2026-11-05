//! Pure Rust logical-row edits, prepared before mutating the shared workspace.
//! Ordinary scaling, time/rate conversion and coupled switches use the same
//! transaction as virtual multipliers, so a late failure cannot leave half edits.
use crate::{
    binary::Encoding,
    catalog::{Catalog, Expression, Mode, Owner, Row},
    workspace::{Location, Workspace},
};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
pub struct Plan {
    pub values: Vec<(Location, Encoding, f64)>,
    pub metadata: Value,
    pub changes: Value,
}
struct Builder<'a> {
    catalog: &'a Catalog,
    workspace: &'a Workspace,
    fields: BTreeMap<usize, f64>,
    metadata: Value,
    active: BTreeSet<usize>,
}
impl<'a> Builder<'a> {
    fn current(&self, index: usize) -> Result<f64, String> {
        self.fields.get(&index).copied().map(Ok).unwrap_or_else(|| {
            self.catalog
                .field_value(index, self.workspace, Mode::Current)?
                .ok_or("参数当前值不可读".into())
        })
    }
    fn original(&self, index: usize) -> Result<f64, String> {
        self.catalog
            .field_value(index, self.workspace, Mode::Original)?
            .ok_or("该参数没有可信原始值，未应用任何修改".into())
    }
    fn write(&mut self, index: usize, mut value: f64) -> Result<(), String> {
        if !value.is_finite() {
            return Err("联动计算产生非有限数值，未应用任何修改".into());
        }
        let field = self.catalog.fields.get(index).ok_or("参数索引越界")?;
        if !self.active.insert(index) {
            return Err("参数联动形成循环".into());
        }
        let result = (|| {
            if matches!(field.storage.as_str(), "u8" | "u16" | "u32" | "entry") {
                value = (value + 0.5).floor();
            }
            if field.storage == "flag" || field.storage == "bit" {
                value = if value >= 0.5 { 1.0 } else { 0.0 };
            }
            if !field.allowed.is_empty() && !field.allowed.iter().any(|v| *v as f64 == value) {
                return Err("该字段不支持所选枚举值".into());
            }
            if field.storage == "virtual" {
                if !self.metadata.is_object() {
                    self.metadata = json!({});
                }
                if !self.metadata["virtual"].is_object() {
                    self.metadata["virtual"] = json!({});
                }
                if field.virtual_default == Some(value) {
                    self.metadata["virtual"]
                        .as_object_mut()
                        .unwrap()
                        .remove(&field.key);
                } else {
                    self.metadata["virtual"][&field.key] = json!(value);
                }
            } else {
                let binding = self.catalog.bindings[index]
                    .as_ref()
                    .ok_or("该字段原生写入尚未完成")?;
                self.current(index)?;
                if matches!(binding.encoding, Encoding::Demolition) {
                    let (threshold, id) = self
                        .workspace
                        .demolition_choice(&binding.locations[0], value)?;
                    value = threshold as f64;
                    if let Some(death) = field.death {
                        self.write(death, id as f64)?;
                    }
                } else {
                    // Encode now to reject storage errors before changing metadata.
                    let patch = binding.encoding.encode(0, value)?;
                    value = binding.encoding.read(&patch.bytes)?;
                }
            }
            if let Some(previous) = self.fields.insert(index, value) {
                if previous != value {
                    return Err("联动参数要求互相冲突的数值".into());
                }
            }
            if let Some(drop) = field.auto_drop {
                self.write(
                    drop,
                    if value == 1.0 {
                        0.0
                    } else {
                        self.original(drop)?
                    },
                )?;
            }
            Ok(())
        })();
        self.active.remove(&index);
        result
    }
    fn expression(&self, expr: &Expression) -> Result<f64, String> {
        match expr {
            Expression::Field { field } => self.current(*field),
            Expression::Subtract { left, right } => {
                Ok(self.expression(left)? - self.expression(right)?)
            }
        }
    }
    fn row(&mut self, owner: &Owner, row: &Row, target: f64, restore: bool) -> Result<(), String> {
        if row.code {
            return Err("战备指令需要专用录入接口".into());
        }
        if row.unresolved.is_some() {
            return Err("该参数规则尚未完成原生迁移".into());
        }
        if matches!(
            row.choice.as_str(),
            Some(
                "resomode"
                    | "smmode"
                    | "smres"
                    | "grenade"
                    | "status"
                    | "explosion"
                    | "shrapnel"
                    | "stratagem"
            )
        ) || row.choice == true
        {
            return Err("该选择需要完整引用或资源事务，当前接口未应用任何修改".into());
        }
        if restore {
            for part in &row.parts {
                self.write(part.field, self.original(part.field)?)?;
            }
            return Ok(());
        }
        let current = self
            .catalog
            .row_value(owner, row, self.workspace, Mode::Current)?
            .ok_or("参数当前值不可读")?;
        if target == current {
            return Ok(());
        }
        let target = if row.storage == "u32" {
            (target + 0.5).floor()
        } else {
            target
        };
        if row.suppression {
            if row.parts.len() != 2 {
                return Err("消音联动字段不完整".into());
            }
            let target = if target >= 0.5 { 1.0 } else { 0.0 };
            let flag = row.parts[0].field;
            let noise = row.parts[1].field;
            let flag_original = self.original(flag)?;
            let noise_original = self.original(noise)?;
            let noise_value = if target == 1.0 {
                if noise_original == 0.0 {
                    0.0
                } else {
                    10.0
                }
            } else if flag_original == 1.0 {
                7.0
            } else {
                noise_original
            };
            self.write(noise, noise_value)?;
            self.write(flag, target)?;
            return Ok(());
        }
        if row.choice == "holster" {
            if ![0.0, 1.0].contains(&target) {
                return Err("收纳位置只能选择背部或腰侧".into());
            }
            for (i, part) in row.parts.iter().enumerate() {
                let value = if target == 0.0 {
                    self.original(part.field)?
                } else if i == 0 {
                    0xCCF501C7u32 as f64
                } else {
                    0.0
                };
                self.write(part.field, value)?;
            }
            return Ok(());
        }
        if row.choice == "pod_twin" {
            if ![1.0, 2.0].contains(&target) || row.parts.len() != 17 {
                return Err("双侧投放配置无效".into());
            }
            for (i, part) in row.parts.iter().enumerate() {
                let value = if target == 1.0 {
                    self.original(part.field)?
                } else if i == 16 {
                    self.original(part.field)?.max(2.0)
                } else if i == 2 {
                    0x7FE13CFFu32 as f64
                } else if i == 13 {
                    1.0
                } else {
                    let binding = self.catalog.bindings[part.field]
                        .as_ref()
                        .ok_or("双侧投放绑定缺失")?;
                    let mut left = binding.locations.first().ok_or("双侧投放记录缺失")?.clone();
                    left.relative = left.relative.checked_sub(64).ok_or("左侧投放槽位越界")?;
                    self.workspace.value(&left, &Encoding::U32)?.current
                };
                self.write(part.field, value)?;
            }
            return Ok(());
        }
        let choice = row.choice.as_str();
        if let Some(allowed) = match choice {
            Some("weight") => Some(&[0.0, 1.0, 2.0][..]),
            Some("slot") => Some(&[1.0, 3.0][..]),
            Some("faction") => Some(&[1.0, 2.0, 4.0, 8.0][..]),
            Some("apex_fire") => Some(&[2677.0, 2719.0][..]),
            Some("crosshair") => Some(&[1.0, 2.0][..]),
            Some("firemode") => Some(&[0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0][..]),
            Some("fntype") => Some(&[0.0, 2.0, 3.0, 4.0, 8.0, 11.0][..]),
            _ => None,
        } {
            if !allowed.contains(&target) {
                return Err("不支持所选参数枚举值".into());
            }
        }
        let mut scale = row.scale.unwrap_or(1.0);
        if let Some(drain) = &row.drain {
            let r = owner
                .rows
                .iter()
                .find(|r| r.id == *drain)
                .ok_or("流失速率参数不存在")?;
            let rate = self.current(r.parts.first().ok_or("流失速率字段缺失")?.field)?;
            if rate > 0.0 {
                scale = 1.0 / rate;
            }
        }
        for (i, part) in row.parts.iter().enumerate() {
            let value = if row.mult {
                if i == 0 {
                    target
                } else {
                    let original = self.original(part.field)?;
                    if row.inverse {
                        original / target
                    } else {
                        original * target
                    }
                }
            } else if row.choice != Value::Null && row.choice != Value::Bool(false) {
                target
            } else if let Some(span) = &row.span {
                let span = self.expression(span)?;
                if span <= 0.0 {
                    return Err("总量为零，请先设置大于零的总量".into());
                }
                if row.never && target == 0.0 {
                    0.0
                } else {
                    span / target - row.rate_plus.unwrap_or(0.0)
                }
            } else if row.parts.len() > 1 {
                if current > 0.0 {
                    self.current(part.field)? * target / current
                } else {
                    target / scale
                }
            } else if row.zero.is_some_and(|zero| (target - zero).abs() < 1e-4)
                && self.original(part.field)? == 0.0
            {
                0.0
            } else {
                target / scale
            };
            self.write(part.field, value)?;
        }
        // Changing hover fuel capacity preserves the two visible hover times.
        if row.id == "bp_recharge" {
            for kept in owner
                .rows
                .iter()
                .filter(|r| matches!(r.id.as_str(), "bp_hover_fuel" | "bp_climb_fuel"))
            {
                if let (Some(time), Some(span)) = (
                    self.catalog
                        .row_value(owner, kept, self.workspace, Mode::Current)?,
                    &kept.span,
                ) {
                    let span = self.expression(span)?;
                    if time > 0.0 && span > 0.0 {
                        let part = kept.parts.first().ok_or("悬停时间字段缺失")?;
                        let mut value = span / time - kept.rate_plus.unwrap_or(0.0);
                        if let Ok(original) = self.original(part.field) {
                            if (value - original).abs() < 1e-4 {
                                value = original;
                            }
                        }
                        self.write(part.field, value)?;
                    }
                }
            }
        }
        Ok(())
    }
}
pub fn prepare(
    catalog: &Catalog,
    workspace: &Workspace,
    owner: &str,
    key: &str,
    value: Option<f64>,
) -> Result<Plan, String> {
    let (_, owner) = catalog.owner(owner)?;
    let row = owner
        .rows
        .iter()
        .find(|r| r.key == key)
        .ok_or("找不到参数，请重新打开条目")?;
    if value.is_some_and(|v| !v.is_finite()) {
        return Err("请输入有限数值".into());
    }
    let mut builder = Builder {
        catalog,
        workspace,
        fields: BTreeMap::new(),
        metadata: workspace.metadata().clone(),
        active: BTreeSet::new(),
    };
    builder.row(owner, row, value.unwrap_or(0.0), value.is_none())?;
    let mut values = Vec::new();
    let mut changes = Vec::new();
    for (index, value) in builder.fields {
        let field = &catalog.fields[index];
        let before = catalog.field_value(index, workspace, Mode::Current)?;
        if before != Some(value) {
            changes.push(json!({"field":field.key,"before":before,"after":value}));
        }
        if let Some(binding) = &catalog.bindings[index] {
            for location in &binding.locations {
                values.push((location.clone(), binding.encoding.clone(), value));
            }
        }
    }
    if builder.metadata["virtual"]
        .as_object()
        .is_some_and(|values| values.is_empty())
    {
        builder.metadata.as_object_mut().unwrap().remove("virtual");
    }
    if builder
        .metadata
        .as_object()
        .is_some_and(|values| values.is_empty())
        && workspace.metadata().is_null()
    {
        builder.metadata = Value::Null;
    }
    Ok(Plan {
        values,
        metadata: builder.metadata,
        changes: json!(changes),
    })
}
