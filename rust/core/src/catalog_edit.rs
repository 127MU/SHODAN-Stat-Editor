//! Pure Rust logical-row edits, prepared before mutating the shared workspace.
//! Ordinary scaling, time/rate conversion and coupled switches use the same
//! transaction as virtual multipliers, so a late failure cannot leave half edits.
use crate::{
    binary::Encoding,
    catalog::{Catalog, Expression, Mode, Owner, Row},
    catalog_refs,
    workspace::{Location, Workspace},
};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
pub struct Plan {
    pub values: Vec<(Location, Encoding, f64)>,
    pub metadata: Value,
    pub changes: Value,
}
pub(crate) struct Builder<'a> {
    pub(crate) catalog: &'a Catalog,
    pub(crate) workspace: &'a Workspace,
    pub(crate) fields: BTreeMap<usize, f64>,
    metadata: Value,
    active: BTreeSet<usize>,
}
impl<'a> Builder<'a> {
    pub(crate) fn new(catalog: &'a Catalog, workspace: &'a Workspace) -> Self {
        Self {
            catalog,
            workspace,
            fields: BTreeMap::new(),
            metadata: workspace.metadata().clone(),
            active: BTreeSet::new(),
        }
    }
    pub(crate) fn current(&self, index: usize) -> Result<f64, String> {
        self.fields.get(&index).copied().map(Ok).unwrap_or_else(|| {
            self.catalog
                .field_value(index, self.workspace, Mode::Current)?
                .ok_or("参数当前值不可读".into())
        })
    }
    pub(crate) fn original(&self, index: usize) -> Result<f64, String> {
        self.catalog
            .field_value(index, self.workspace, Mode::Original)?
            .ok_or("该参数没有可信原始值，未应用任何修改".into())
    }
    pub(crate) fn write(&mut self, index: usize, mut value: f64) -> Result<(), String> {
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
                let loaded = if field.stratagem_code.is_some() {
                    if value.fract() != 0.0 || !(1.0..=u32::MAX as f64).contains(&value) {
                        return Err("战备指令无效".into());
                    }
                    crate::stratagem_code::directions(value as u32)?;
                    self.catalog
                        .field_value(index, self.workspace, Mode::Loaded)?
                } else {
                    field.virtual_default
                };
                if !self.metadata.is_object() {
                    self.metadata = json!({});
                }
                if !self.metadata["virtual"].is_object() {
                    self.metadata["virtual"] = json!({});
                }
                if loaded == Some(value) {
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
    fn reference(
        &mut self,
        owner: &Owner,
        row: &Row,
        target: f64,
        restore: bool,
        kind: &str,
        allow_zero: bool,
    ) -> Result<(), String> {
        for part in &row.parts {
            let value = if restore {
                self.original(part.field)?
            } else {
                target
            };
            if self.current(part.field)? == value {
                continue;
            }
            // A trusted original fire-mode reference may be empty.
            let field = &self.catalog.fields[part.field];
            let extra_ammo = field.switch.is_some() || field.toggle.is_some();
            let id = catalog_refs::validate_record(
                self.workspace,
                kind,
                allow_zero || restore || extra_ammo,
                value,
            )?;
            if row.choice == "status" {
                let locations = &self.catalog.bindings[part.field]
                    .as_ref()
                    .ok_or("状态效果槽没有绑定")?
                    .locations;
                for location in locations {
                    catalog_refs::status_neighbor(self.workspace, location, id)?;
                }
                if id != 0 && !restore {
                    let strength = owner
                        .rows
                        .iter()
                        .filter(|r| r.id == format!("{}_strength", part.id))
                        .flat_map(|r| &r.parts)
                        .find(|p| {
                            self.catalog.bindings[p.field]
                                .as_ref()
                                .is_some_and(|binding| {
                                    binding.locations.len() == locations.len()
                                        && locations.iter().zip(&binding.locations).all(
                                            |(slot, strength)| {
                                                slot.file == strength.file
                                                    && slot.typ == strength.typ
                                                    && slot.record == strength.record
                                                    && slot.relative + 4 == strength.relative
                                            },
                                        )
                                })
                        })
                        .ok_or("状态效果强度字段缺失")?;
                    if self.current(strength.field)? == 0.0 {
                        self.write(strength.field, catalog_refs::status_strength(id))?;
                    }
                }
            }
            self.write(part.field, value)?;
        }
        Ok(())
    }
    fn row(&mut self, owner: &Owner, row: &Row, target: f64, restore: bool) -> Result<(), String> {
        if row.code {
            let field = row.parts.first().ok_or("战备指令未绑定字段")?.field;
            if self.catalog.fields[field].stratagem_code.is_none() {
                return Err("战备指令未绑定记录".into());
            }
            return self.write(
                field,
                if restore {
                    self.original(field)?
                } else {
                    target
                },
            );
        }
        if row.unresolved.is_some() {
            return Err("该参数规则尚未完成原生迁移".into());
        }
        if !row.recipes.is_empty() && !restore && target != 0.0 {
            if row.choice == "spear_dual" {
                let projectile = |key| -> Result<f64, String> {
                    let part = owner
                        .rows
                        .iter()
                        .find(|r| r.id == key)
                        .and_then(|r| r.parts.first())
                        .ok_or("飞矛射弹绑定缺失")?;
                    self.current(part.field)
                };
                if projectile("projectile")? != 229.0 {
                    return Err("请先恢复飞矛的原配主射弹 #229".into());
                }
                let mode = self.current(row.parts[0].field)?;
                let alternate = projectile("projectile_2")?;
                if (mode, alternate) != (0.0, 0.0) && (mode, alternate) != (8.0, 223.0) {
                    return Err("飞矛的功能档位或备用射弹已被占用，请先恢复这些参数".into());
                }
            }
            let recipe = row
                .recipes
                .get(&(target as u32))
                .filter(|_| target.fract() == 0.0)
                .ok_or("不支持所选参数预设")?;
            for (part, step) in row.parts.iter().zip(recipe) {
                let value = match *step {
                    Some(value) => value,
                    None => self.original(part.field)?,
                };
                self.write(part.field, value)?;
            }
            return Ok(());
        }
        if let Some((kind, allow_zero)) = catalog_refs::namespace(row) {
            return self.reference(owner, row, target, restore, kind, allow_zero);
        }
        if row.choice == "stratagem" && !restore {
            Encoding::U32.encode(0, target)?;
        }
        if matches!(row.choice.as_str(), Some("resomode" | "smmode" | "grenade")) {
            return Err("该选择需要完整引用或资源事务，当前接口未应用任何修改".into());
        }
        if restore || !row.recipes.is_empty() {
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
        if row.id == "second_toggle" && ![1.0, 2.0].contains(&target) {
            return Err("第二弹种只能替换功能键 1 或 2".into());
        }
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
            Some("crosshair") => Some(&[0.0, 3.0, 4.0, 16.0][..]),
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
    let mut builder = Builder::new(catalog, workspace);
    builder.row(owner, row, value.unwrap_or(0.0), value.is_none())?;
    builder.finish()
}

impl Builder<'_> {
    fn ammo_switches(&mut self) -> Result<(), String> {
        let changed: Vec<_> = self.fields.keys().copied().collect();
        for index in changed {
            let f = &self.catalog.fields[index];
            if let Some(switch) = f.switch {
                let on = self.current(index)? != 0.0;
                self.write(switch, if on { 8.0 } else { self.original(switch)? })?;
            }
            if let Some(toggle) = f.toggle {
                let on = self.current(toggle.second)? != 0.0;
                let pick = self.current(toggle.pick)?;
                for (side, index) in [(1.0, toggle.left), (2.0, toggle.right)] {
                    let wanted = if on && pick == side {
                        8.0
                    } else {
                        self.original(index)?
                    };
                    self.write(index, wanted)?;
                }
            }
        }
        Ok(())
    }
    pub(crate) fn finish(mut self) -> Result<Plan, String> {
        self.ammo_switches()?;
        let mut values = Vec::new();
        let mut changes = Vec::new();
        for (index, value) in self.fields {
            let field = &self.catalog.fields[index];
            let before = self
                .catalog
                .field_value(index, self.workspace, Mode::Current)?;
            if before != Some(value) {
                changes.push(json!({"field":field.key,"before":before,"after":value}));
            }
            if let Some(binding) = &self.catalog.bindings[index] {
                for location in &binding.locations {
                    values.push((location.clone(), binding.encoding.clone(), value));
                }
            }
        }
        if self.metadata["virtual"]
            .as_object()
            .is_some_and(|values| values.is_empty())
        {
            self.metadata.as_object_mut().unwrap().remove("virtual");
        }
        if self
            .metadata
            .as_object()
            .is_some_and(|values| values.is_empty())
            && self.workspace.metadata().is_null()
        {
            self.metadata = Value::Null;
        }
        Ok(Plan {
            values,
            metadata: self.metadata,
            changes: json!(changes),
        })
    }
}

pub(crate) fn reset_owner(
    catalog: &Catalog,
    workspace: &Workspace,
    owner: &Owner,
) -> Result<Plan, String> {
    let mut builder = Builder::new(catalog, workspace);
    for row in &owner.rows {
        if row.unresolved.is_some()
            || matches!(
                row.choice.as_str(),
                Some("resomode" | "smmode" | "smres" | "grenade")
            )
        {
            continue;
        }
        for part in &row.parts {
            if builder.fields.contains_key(&part.field) {
                continue;
            }
            if let (Ok(current), Ok(original)) =
                (builder.current(part.field), builder.original(part.field))
            {
                if current != original {
                    builder.write(part.field, original)?;
                }
            }
        }
    }
    builder.finish()
}
