use crate::{dlbin, sealed};
use serde_json::{json, Value};
use std::{collections::BTreeMap, fs, path::Path};

const FILE: &str = "generated_weapon_customization_settings.dl_bin";
const SLOTS: [&str; 10] = [
    "未知",
    "下挂",
    "瞄具",
    "涂装",
    "枪口",
    "弹匣",
    "弹种",
    "备用弹种",
    "内部配件",
    "扳机",
];

fn word(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap())
}

fn range(bytes: &[u8], offset: u32, count: u32, stride: usize) -> Result<&[u8], String> {
    let start = offset as usize;
    let end = (count as usize)
        .checked_mul(stride)
        .and_then(|length| start.checked_add(length))
        .ok_or("配件列表越界")?;
    bytes.get(start..end).ok_or_else(|| "配件列表越界".into())
}

fn options(data: &[u8]) -> Result<Value, String> {
    let mut options = BTreeMap::new();
    for block in dlbin::index(data).map_err(|e| e.to_string())? {
        if block.type_id != 0x1E604234 {
            continue;
        }
        let body = &data[block.payload];
        if body.len() < 16 || word(body, 4) != 0 {
            return Err("配件数据块头无效".into());
        }
        for row in range(body, word(body, 0), word(body, 8), 88)?.chunks_exact(88) {
            let id = word(row, 8);
            let offset = word(row, 0);
            let name = if offset == 0 {
                ""
            } else {
                let text = body.get(offset as usize..).ok_or("配件名称越界")?;
                let end = text
                    .iter()
                    .position(|b| *b == 0)
                    .ok_or("配件名称没有终止符")?;
                std::str::from_utf8(&text[..end]).map_err(|_| "配件名称编码无效")?
            };
            if word(row, 52) != 0 {
                return Err("配件槽位指针无效".into());
            }
            let slots: Vec<_> = range(body, word(row, 48), word(row, 56), 4)?
                .chunks_exact(4)
                .map(|slot| {
                    let slot = word(slot, 0);
                    SLOTS
                        .get(slot as usize)
                        .map(|s| s.to_string())
                        .unwrap_or_else(|| format!("槽位 #{slot}"))
                })
                .collect();
            let resource = u64::from_le_bytes(row[32..40].try_into().unwrap());
            if options
                .insert(
                    id,
                    json!({
                        "id":id,"hex":format!("0x{id:08X}"),"name":name,"slots":slots,
                        "resource":format!("{resource:016X}")
                    }),
                )
                .is_some()
            {
                return Err("配件目录含重复编号".into());
            }
        }
    }
    if options.is_empty() {
        return Err("当前游戏没有可识别的配件选项目录".into());
    }
    let mut options: Vec<_> = options.into_values().collect();
    options.sort_by_cached_key(|row| row["name"].as_str().unwrap_or("").to_lowercase());
    Ok(json!(options))
}

pub(crate) fn list(game: &Path) -> Result<Value, String> {
    let path = game.join(FILE);
    if fs::metadata(&path).map_err(|_| "找不到游戏配件目录")?.len() > 2 * 1024 * 1024 {
        return Err("游戏配件目录过大".into());
    }
    let bytes = fs::read(&path).map_err(|_| "无法读取游戏配件目录")?;
    let plain = sealed::open_data(&bytes).map_err(|e| e.to_string())?;
    options(&plain)
}
