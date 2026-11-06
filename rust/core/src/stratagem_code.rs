//! Call-in direction arrays use block-relative pointers and stable stratagem types.
use crate::dlbin::{self, Block};
use std::collections::{BTreeMap, BTreeSet};

pub(crate) const FILE: &str = "generated_stratagem_settings.dl_bin";
const TYPE: u32 = 0x30EB6399;
const STRIDE: usize = 400;
pub(crate) const MAX: usize = 9;

#[derive(Clone)]
struct Code {
    at: usize,
    row: usize,
    directions: Vec<u8>,
}

pub(crate) struct Codebook {
    blocks: Vec<Block>,
    items: BTreeMap<u32, (usize, Code)>,
}

pub(crate) fn number(directions: &[u8]) -> Result<u32, String> {
    if directions.is_empty()
        || directions.len() > MAX
        || directions.iter().any(|d| !(1..=4).contains(d))
    {
        return Err("战备指令必须包含 1～9 个有效方向".into());
    }
    Ok(directions
        .iter()
        .fold(0_u32, |value, direction| value * 5 + *direction as u32))
}

pub(crate) fn directions(mut value: u32) -> Result<Vec<u8>, String> {
    let mut code = Vec::new();
    while value > 0 && code.len() <= MAX {
        code.push((value % 5) as u8);
        value /= 5;
    }
    code.reverse();
    number(&code)?;
    Ok(code)
}

pub(crate) fn label(value: u32) -> String {
    directions(value)
        .ok()
        .map(|arrows| {
            arrows
                .into_iter()
                .map(|d| ["↑", "→", "↓", "←"][d as usize - 1])
                .collect::<Vec<_>>()
                .join(" ")
        })
        .unwrap_or_default()
}

fn word(bytes: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap())
}

impl Codebook {
    pub(crate) fn parse(bytes: &[u8]) -> Result<Self, String> {
        let blocks = dlbin::index(bytes).map_err(|err| err.to_string())?;
        let mut items = BTreeMap::new();
        for (index, block) in blocks.iter().enumerate().filter(|(_, b)| b.type_id == TYPE) {
            let bytes = &bytes[block.payload.clone()];
            if bytes.len() < 16 {
                return Err("战备数据块不完整".into());
            }
            let rows = word(bytes, 8) as usize;
            let table_end = rows
                .checked_mul(STRIDE)
                .and_then(|len| len.checked_add(16))
                .filter(|end| *end <= bytes.len())
                .ok_or("战备记录表越界")?;
            for row in (16..table_end).step_by(STRIDE) {
                let id = word(bytes, row);
                let count = word(bytes, row + 72) as usize;
                let at = u64::from_le_bytes(bytes[row + 64..row + 72].try_into().unwrap());
                let Ok(at) = usize::try_from(at) else {
                    continue;
                };
                if id == 0
                    || !(1..=MAX).contains(&count)
                    || at < table_end
                    || at
                        .checked_add(count * 4)
                        .is_none_or(|end| end > bytes.len())
                {
                    continue;
                }
                let mut directions = Vec::with_capacity(count);
                for off in (at..at + count * 4).step_by(4) {
                    let direction = word(bytes, off);
                    if !(1..=4).contains(&direction) {
                        break;
                    }
                    directions.push(direction as u8);
                }
                if directions.len() == count
                    && items
                        .insert(
                            id,
                            (
                                index,
                                Code {
                                    at,
                                    row,
                                    directions,
                                },
                            ),
                        )
                        .is_some()
                {
                    return Err(format!("战备类型 #{id} 存在重复指令记录"));
                }
            }
        }
        Ok(Self { blocks, items })
    }

    pub(crate) fn get(&self, id: u32) -> Option<u32> {
        self.items
            .get(&id)
            .and_then(|(_, item)| number(&item.directions).ok())
    }

    pub(crate) fn validate(
        &self,
        overrides: &BTreeMap<u32, u32>,
        rules: &[crate::catalog::Choice],
    ) -> Result<Vec<String>, String> {
        let mut warnings = BTreeSet::new();
        for (&id, &number) in overrides {
            if !self.items.contains_key(&id) {
                return Err(format!("战备 #{id} 缺少可编辑指令"));
            }
            let target = directions(number)?;
            for rule in rules {
                let Ok(other_id) = u32::try_from(rule.id) else {
                    continue;
                };
                if id == other_id || !matches!(rule.note.as_str(), "always" | "loadout") {
                    continue;
                }
                let Some(number) = overrides
                    .get(&other_id)
                    .copied()
                    .or_else(|| self.get(other_id))
                else {
                    continue;
                };
                let other = directions(number)?;
                if target.starts_with(&other) || other.starts_with(&target) {
                    if rule.note == "always" {
                        return Err(format!("指令与每场任务都可用的 {} 冲突", rule.label));
                    }
                    warnings.insert(format!("指令与 {} 冲突，配装时请核对", rule.label));
                }
            }
        }
        Ok(warnings.into_iter().collect())
    }

    pub(crate) fn rebuild(
        &self,
        input: &[u8],
        overrides: &BTreeMap<u32, u32>,
    ) -> Result<Vec<u8>, String> {
        let mut changes = BTreeMap::<usize, Vec<(&Code, Vec<u8>)>>::new();
        for (id, value) in overrides {
            let (block, code) = self.items.get(id).ok_or("战备指令记录已失效")?;
            let directions = directions(*value)?;
            if directions != code.directions {
                changes.entry(*block).or_default().push((code, directions));
            }
        }
        if changes.is_empty() {
            return Ok(input.to_vec());
        }
        let mut output = Vec::with_capacity(input.len());
        output.extend_from_slice(&input[..self.blocks[0].header_offset]);
        for (index, block) in self.blocks.iter().enumerate() {
            let next = self
                .blocks
                .get(index + 1)
                .map_or(input.len(), |b| b.header_offset);
            let Some(edits) = changes.get(&index) else {
                output.extend_from_slice(&input[block.header_offset..next]);
                continue;
            };
            let mut payload = input[block.payload.clone()].to_vec();
            let original_size = payload.len();
            for (code, directions) in edits {
                // An array can be shared by two records. Update in place only
                // if no other record has an overlapping range in this block.
                let shared = self.items.values().any(|(i, other)| {
                    *i == index
                        && other.row != code.row
                        && other.at < code.at + code.directions.len() * 4
                        && code.at < other.at + other.directions.len() * 4
                });
                let at = if directions.len() > code.directions.len() || shared {
                    let at = payload.len().next_multiple_of(8);
                    payload.resize(at + directions.len() * 4, 0);
                    payload[code.row + 64..code.row + 72]
                        .copy_from_slice(&(at as u64).to_le_bytes());
                    at
                } else {
                    code.at
                };
                payload[code.row + 72..code.row + 76]
                    .copy_from_slice(&(directions.len() as u32).to_le_bytes());
                for (slot, direction) in directions.iter().enumerate() {
                    payload[at + slot * 4..at + slot * 4 + 4]
                        .copy_from_slice(&(*direction as u32).to_le_bytes());
                }
            }
            payload.resize(
                original_size + (payload.len() - original_size).next_multiple_of(16),
                0,
            );
            let mut header = input[block.header_offset..block.payload.start].to_vec();
            header[12..16].copy_from_slice(
                &u32::try_from(payload.len())
                    .map_err(|_| "战备数据块过大")?
                    .to_le_bytes(),
            );
            output.extend(header);
            output.extend(payload);
            output.extend_from_slice(&input[block.payload.end..next]);
        }
        let verified = Self::parse(&output)?;
        if overrides
            .iter()
            .any(|(&id, &value)| verified.get(id) != Some(value))
        {
            return Err("战备指令重建回读失败".into());
        }
        Ok(output)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn codes_grow_without_overwriting_a_shared_array_or_opaque_tail() {
        let mut input = b"LDLD\x01\0\0\0".to_vec();
        input.extend(TYPE.to_le_bytes());
        input.extend(832_u32.to_le_bytes());
        input.extend([1, 0, 0, 0, 0, 0, 0, 0]);
        let mut payload = [0_u8; 832];
        payload[8..12].copy_from_slice(&2_u32.to_le_bytes());
        for (id, row) in [(10_u32, 16), (20, 416)] {
            payload[row..row + 4].copy_from_slice(&id.to_le_bytes());
            payload[row + 64..row + 72].copy_from_slice(&816_u64.to_le_bytes());
            payload[row + 72..row + 76].copy_from_slice(&2_u32.to_le_bytes());
        }
        payload[816..820].copy_from_slice(&1_u32.to_le_bytes());
        payload[820..824].copy_from_slice(&4_u32.to_le_bytes());
        payload[824..832].fill(0x5A);
        input.extend(payload);
        let data = Codebook::parse(&input).unwrap();
        let edited = data
            .rebuild(&input, &BTreeMap::from([(10, number(&[3, 2, 4]).unwrap())]))
            .unwrap();
        let output = Codebook::parse(&edited).unwrap();
        assert_eq!(output.get(10), number(&[3, 2, 4]).ok());
        assert_eq!(output.get(20), number(&[1, 4]).ok());
        assert_eq!(edited[24 + 824..24 + 832], [0x5A; 8]);
    }
}
