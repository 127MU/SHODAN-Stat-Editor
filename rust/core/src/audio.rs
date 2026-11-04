//! Read Wwise event identities without interpreting event hashes as sound names.
use std::collections::BTreeSet;
fn u32at(bytes: &[u8], at: usize) -> Result<u32, String> {
    Ok(u32::from_le_bytes(
        bytes
            .get(at..at + 4)
            .ok_or("音效目录截断")?
            .try_into()
            .unwrap(),
    ))
}
/// Accept bare banks and the game's 16-byte bank wrapper. DATA is never loaded.
pub fn events(
    size: usize,
    mut read: impl FnMut(usize, usize) -> Result<Vec<u8>, String>,
) -> Result<BTreeSet<u32>, String> {
    let head = read(0, size.min(24))?;
    let mut at = if head.starts_with(b"BKHD") { 0 } else { 16 };
    if head.get(at..at + 4) != Some(b"BKHD") {
        return Err("无法识别音效资源包头".into());
    }
    let mut result = BTreeSet::new();
    while at < size {
        if size - at < 8 {
            return Err("音效分块头截断".into());
        }
        let header = read(at, 8)?;
        let len = u32at(&header, 4)? as usize;
        let end = at
            .checked_add(8)
            .and_then(|p| p.checked_add(len))
            .filter(|p| *p <= size)
            .ok_or("音效分块越界")?;
        if header.get(..4) == Some(b"HIRC") {
            if !(4..=16 * 1024 * 1024).contains(&len) {
                return Err("音效对象目录大小异常".into());
            }
            let data = read(at + 8, len)?;
            let count = u32at(&data, 0)? as usize;
            if count > (len - 4) / 9 {
                return Err("音效对象数量异常".into());
            }
            let mut p = 4;
            for _ in 0..count {
                let kind = *data.get(p).ok_or("音效对象截断")?;
                let n = u32at(&data, p + 1)? as usize;
                let next = p
                    .checked_add(5)
                    .and_then(|p| p.checked_add(n))
                    .filter(|p| *p <= len)
                    .ok_or("音效对象越界")?;
                if n < 4 {
                    return Err("音效对象缺少身份".into());
                }
                if kind == 4 {
                    result.insert(u32at(&data, p + 5)?);
                }
                p = next;
            }
        }
        at = end;
    }
    Ok(result)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn skips_data_reads_and_accepts_wrapper() {
        let mut b = vec![0; 16];
        b.extend(b"BKHD\0\0\0\0DATA");
        b.extend(100u32.to_le_bytes());
        b.extend([0; 100]);
        b.extend(b"HIRC");
        b.extend(13u32.to_le_bytes());
        b.extend(1u32.to_le_bytes());
        b.push(4);
        b.extend(4u32.to_le_bytes());
        b.extend(123u32.to_le_bytes());
        let events = events(b.len(), |at, n| {
            assert!(at != 32);
            Ok(b[at..at + n].to_vec())
        })
        .unwrap();
        assert_eq!(events, BTreeSet::from([123]));
        b.pop();
        assert!(events_from(&b).is_err());
    }
    fn events_from(b: &[u8]) -> Result<BTreeSet<u32>, String> {
        events(b.len(), |p, n| Ok(b[p..p + n].to_vec()))
    }
}
