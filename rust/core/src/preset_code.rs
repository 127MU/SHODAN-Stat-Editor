//! Share codes. Read the original Rice-coded format and write a lossless
//! compressed container that also carries armor combinations and text edits.
use crate::{
    catalog::Catalog,
    desktop_presets,
    preset::{Preset, Value},
};
use std::{
    collections::BTreeMap,
    io::{Read, Write},
};

const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const LIMIT: usize = 8 * 1024 * 1024;
fn base64(bytes: &[u8]) -> String {
    let mut result = String::new();
    for c in bytes.chunks(3) {
        let n = (u32::from(c[0]) << 16)
            | (u32::from(*c.get(1).unwrap_or(&0)) << 8)
            | u32::from(*c.get(2).unwrap_or(&0));
        for i in (3 - c.len()..=3).rev() {
            result.push(ALPHABET[((n >> (i * 6)) & 63) as usize] as char);
        }
    }
    result
}
fn unbase64(text: &str) -> Result<Vec<u8>, String> {
    if text.len() > LIMIT {
        return Err("预设分享码过长".into());
    }
    let mut output = Vec::new();
    let mut n = 0u32;
    let mut bits = 0usize;
    let mut count = 0usize;
    for c in text.bytes() {
        if c.is_ascii_whitespace() {
            continue;
        }
        if c == b'=' {
            break;
        }
        let v = ALPHABET
            .iter()
            .position(|&x| x == c)
            .ok_or("分享码包含非法字符")?;
        n = (n << 6) | v as u32;
        bits += 6;
        count += 1;
        if bits >= 8 {
            bits -= 8;
            output.push((n >> bits) as u8);
        }
    }
    if count % 4 == 1 || n & ((1 << bits) - 1) != 0 {
        return Err("分享码结尾不完整".into());
    }
    Ok(output)
}
pub(crate) fn encode(text: &str, enemy: bool) -> Result<String, String> {
    let mut gzip = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::best());
    gzip.write_all(text.as_bytes())
        .map_err(|_| "无法编码分享码")?;
    let bytes = gzip.finish().map_err(|_| "无法编码分享码")?;
    Ok(format!(
        "SSEO-{}2-{}",
        if enemy { 'E' } else { 'S' },
        base64(&bytes)
    ))
}

struct Reader<'a> {
    bytes: &'a [u8],
    bit: usize,
}
impl Reader<'_> {
    fn read(&mut self, n: usize) -> Result<usize, String> {
        if n > 31
            || self
                .bit
                .checked_add(n)
                .is_none_or(|end| end > self.bytes.len() * 8)
        {
            return Err("旧分享码内容截断".into());
        }
        let mut v = 0;
        for i in self.bit..self.bit + n {
            v = v * 2 + usize::from((self.bytes[i / 8] >> (7 - i % 8)) & 1);
        }
        self.bit += n;
        Ok(v)
    }
    fn number(&mut self, max: usize) -> Result<usize, String> {
        let mut n = 0;
        for i in 0..5 {
            let b = self.read(8)?;
            n |= (b & 127) << (i * 7);
            if b < 128 {
                return if n <= max {
                    Ok(n)
                } else {
                    Err("旧分享码条目数量异常".into())
                };
            }
        }
        Err("旧分享码变长整数无效".into())
    }
    fn text(&mut self) -> Result<String, String> {
        let n = self.number(4096)?;
        let at = self.bit / 8;
        let raw = self.bytes.get(at..at + n).ok_or("旧分享码文本截断")?;
        self.bit += n * 8;
        String::from_utf8(raw.to_vec()).map_err(|_| "旧分享码文本编码无效".into())
    }
    fn zeros(&mut self, max: usize) -> Result<usize, String> {
        for n in 0..=max {
            if self.read(1)? == 1 {
                return Ok(n);
            }
        }
        Err("旧分享码参数编号超限".into())
    }
    fn gamma(&mut self) -> Result<usize, String> {
        let n = self.zeros(17)?;
        Ok((1 << n) | self.read(n)?)
    }
}

fn tag(text: &str) -> usize {
    (text
        .bytes()
        .fold(0u32, |a, b| a.wrapping_mul(33).wrapping_add(u32::from(b)))
        & 0xffffff) as usize
}
fn old(catalog: &Catalog, bytes: &[u8], enemy: bool) -> Result<(Preset, usize), String> {
    let sum = bytes
        .get(2..)
        .ok_or("旧分享码过短")?
        .iter()
        .fold(0u16, |a, &b| a.wrapping_mul(33).wrapping_add(u16::from(b)));
    if bytes[..2] != sum.to_be_bytes() {
        return Err("旧分享码校验失败".into());
    }
    let mut reader = Reader { bytes, bit: 16 };
    let mut tags = BTreeMap::new();
    for owner in &catalog.owners {
        tags.entry(tag(&owner.id))
            .and_modify(|v| *v = None)
            .or_insert(Some(owner.id.as_str()));
    }
    let owner = |tag| tags.get(&tag).copied().flatten();
    let mut result = desktop_presets::legacy_body(
        &reader.text()?,
        desktop_presets::preset("导入预设".into(), enemy, None),
    )?;
    let mut skipped = 0usize;
    for _ in 0..reader.number(30000)? {
        let id = owner(reader.read(24)?);
        let field = match reader.read(8)? {
            1 => "name",
            2 => "code",
            3 => "desc",
            _ => return Err("旧分享码文字字段无效".into()),
        };
        let value = reader.text()?;
        if let Some(id) = id {
            crate::desktop_text::validate(field, &value)?;
            if !value.is_empty() {
                result
                    .texts
                    .entry(id.into())
                    .or_default()
                    .insert(field.into(), value);
            }
        } else {
            skipped += 1;
        }
    }
    let mut literals = Vec::new();
    for _ in 0..reader.number(100000)? {
        literals.push(reader.text()?);
    }
    let base = reader.number(200000)?;
    let count = reader.number(150000)?;
    let mut values = Vec::with_capacity(count);
    for _ in 0..count {
        let mut raw = Vec::new();
        loop {
            let digit = reader.read(4)?;
            if digit == 14 {
                break;
            }
            if raw.len() >= 128 {
                return Err("旧分享码数值过长".into());
            }
            raw.push(*b"0123456789.-e+".get(digit).ok_or("旧分享码数字无效")?);
        }
        let value: f64 = std::str::from_utf8(&raw)
            .unwrap()
            .parse()
            .map_err(|_| "旧分享码数值无效")?;
        if !value.is_finite() {
            return Err("旧分享码数值不是有限数".into());
        }
        values.push(value);
    }
    let rice = reader.read(4)?;
    let width = usize::BITS as usize - count.saturating_sub(1).leading_zeros() as usize;
    let pages = reader.gamma()? - 1;
    if pages > 10000 {
        return Err("旧分享码装备数量过多".into());
    }
    for _ in 0..pages {
        let owner = owner(reader.read(24)?);
        let rows = reader.gamma()?;
        let mut rank = 0;
        for _ in 0..rows {
            let step = reader.zeros(300000)?;
            rank += 1 + (step << rice) + reader.read(rice)?;
            let id = if rank <= base {
                catalog.code_ids.get(rank - 1)
            } else {
                Some(
                    literals
                        .get(rank - base - 1)
                        .ok_or("旧分享码未知参数编号越界")?,
                )
            };
            let value = *values
                .get(reader.read(width)?)
                .ok_or("旧分享码数值编号越界")?;
            if let Some((owner, parameter)) = owner.zip(id) {
                result.values.push(Value {
                    owner: owner.into(),
                    parameter: parameter.clone(),
                    value,
                });
            } else {
                skipped += 1;
            }
            if result.values.len() + skipped > 150000 {
                return Err("旧分享码参数过多".into());
            }
        }
    }
    Ok((result, skipped))
}
pub(crate) fn decode(catalog: &Catalog, input: &str) -> Result<(Preset, usize), String> {
    let pos = input.find("SSEO-").ok_or("找不到预设分享码")?;
    let tail = &input[pos + 5..];
    let (prefix, body) = tail.split_once('-').ok_or("分享码格式无效")?;
    let bytes = unbase64(body.trim())?;
    match prefix {
        "S1" | "E1" => old(catalog, &bytes, prefix == "E1"),
        "S2" | "E2" => {
            let mut text = String::new();
            flate2::read::GzDecoder::new(bytes.as_slice())
                .take((LIMIT + 1) as u64)
                .read_to_string(&mut text)
                .map_err(|_| "分享码压缩数据无效")?;
            let preset = Preset::decode(&text)?;
            if preset.kind != "full"
                || (preset.editor.as_deref() == Some("enemy")) != (prefix == "E2")
            {
                return Err("分享码的预设类型无效".into());
            }
            Ok((preset, 0))
        }
        _ => Err("不支持的分享码版本".into()),
    }
}
