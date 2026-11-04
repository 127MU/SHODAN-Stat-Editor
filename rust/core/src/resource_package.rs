//! Stored resource package containers. IDs remain full u64 values; bytes outside
//! the documented offset/count fields are copied unchanged into rebuilt entries.
use std::collections::{BTreeMap, BTreeSet};
pub const MAGIC: u32 = 0xF0000011;
pub struct Package {
    pub header: [u8; 72],
    pub types: Vec<[u8; 32]>,
    pub entries: Vec<[u8; 80]>,
}
pub struct Blob {
    pub entry: [u8; 80],
    pub toc: Vec<u8>,
    pub gpu: Vec<u8>,
    pub stream: Vec<u8>,
}
pub struct Built {
    pub toc: Vec<u8>,
    pub gpu: Vec<u8>,
    pub stream: Vec<u8>,
}
fn u32at(b: &[u8], at: usize) -> Result<u32, String> {
    Ok(u32::from_le_bytes(
        b.get(at..at + 4)
            .ok_or("资源包字段越界")?
            .try_into()
            .unwrap(),
    ))
}
fn u64at(b: &[u8], at: usize) -> Result<u64, String> {
    Ok(u64::from_le_bytes(
        b.get(at..at + 8)
            .ok_or("资源包字段越界")?
            .try_into()
            .unwrap(),
    ))
}
fn put32(b: &mut [u8], at: usize, v: usize) -> Result<(), String> {
    b[at..at + 4].copy_from_slice(
        &u32::try_from(v)
            .map_err(|_| "资源段超过 32 位长度")?
            .to_le_bytes(),
    );
    Ok(())
}
fn put64(b: &mut [u8], at: usize, v: usize) {
    b[at..at + 8].copy_from_slice(&(v as u64).to_le_bytes());
}
fn slice(b: &[u8], offset: u64, len: u32) -> Result<Vec<u8>, String> {
    if len == 0 {
        return Ok(Vec::new());
    }
    let at = usize::try_from(offset).map_err(|_| "资源偏移溢出")?;
    let end = at.checked_add(len as usize).ok_or("资源长度溢出")?;
    Ok(b.get(at..end).ok_or("资源内容缺失或越界")?.to_vec())
}
fn pad(b: &mut Vec<u8>, alignment: usize) -> Result<(), String> {
    let end = b.len().checked_add(alignment - 1).ok_or("资源对齐溢出")? / alignment * alignment;
    b.resize(end, 0);
    Ok(())
}
impl Package {
    pub fn parse(bytes: &[u8]) -> Result<Self, String> {
        if u32at(bytes, 0)? != MAGIC {
            return Err("资源包容器标记无效".into());
        }
        let type_count = u32at(bytes, 4)? as usize;
        let entry_count = u32at(bytes, 8)? as usize;
        if type_count > 4096 || entry_count > 100000 {
            return Err("资源包目录数量异常".into());
        }
        let end = 72usize
            .checked_add(type_count * 32)
            .and_then(|n| n.checked_add(entry_count * 80))
            .ok_or("资源目录溢出")?;
        if end > bytes.len() {
            return Err("资源目录不完整".into());
        }
        let header = bytes[..72].try_into().unwrap();
        let types = bytes[72..72 + type_count * 32]
            .chunks_exact(32)
            .map(|r| r.try_into().unwrap())
            .collect();
        let entries = bytes[72 + type_count * 32..end]
            .chunks_exact(80)
            .map(|r| r.try_into().unwrap())
            .collect();
        let result = Self {
            header,
            types,
            entries,
        };
        let mut seen = BTreeSet::new();
        for e in &result.entries {
            if !seen.insert((u64at(e, 8)?, u64at(e, 0)?)) {
                return Err("资源包含重复资源身份".into());
            }
        }
        Ok(result)
    }
    pub fn blobs(&self, toc: &[u8], gpu: &[u8], stream: &[u8]) -> Result<Vec<Blob>, String> {
        self.entries
            .iter()
            .map(|entry| {
                Ok(Blob {
                    entry: *entry,
                    toc: slice(toc, u64at(entry, 16)?, u32at(entry, 56)?)?,
                    stream: slice(stream, u64at(entry, 24)?, u32at(entry, 60)?)?,
                    gpu: slice(gpu, u64at(entry, 32)?, u32at(entry, 64)?)?,
                })
            })
            .collect()
    }
    pub fn build(&self, blobs: &[Blob]) -> Result<Built, String> {
        let mut types = self.types.clone();
        let mut counts = BTreeMap::new();
        let mut known = BTreeSet::new();
        for typ in &types {
            if !known.insert(u64at(typ, 8)?) {
                return Err("资源类型目录重复".into());
            }
        }
        let mut resources = BTreeSet::new();
        for blob in blobs {
            let typ = u64at(&blob.entry, 8)?;
            let id = u64at(&blob.entry, 0)?;
            if !resources.insert((typ, id)) {
                return Err("合并后资源身份重复".into());
            }
            *counts.entry(typ).or_insert(0usize) += 1;
            if known.insert(typ) {
                let mut row = [0; 32];
                row[8..16].copy_from_slice(&typ.to_le_bytes());
                put32(&mut row, 24, 16)?;
                put32(&mut row, 28, 64)?;
                types.push(row);
            }
        }
        if types.len() > 4096 || blobs.len() > 100000 {
            return Err("资源目录过大".into());
        }
        let base = 72 + types.len() * 32 + blobs.len() * 80;
        let mut toc = vec![0; base];
        toc[..72].copy_from_slice(&self.header);
        put32(&mut toc, 4, types.len())?;
        put32(&mut toc, 8, blobs.len())?;
        for (i, typ) in types.iter_mut().enumerate() {
            let count = *counts.get(&u64at(typ, 8)?).unwrap_or(&0);
            put64(typ, 16, count);
            toc[72 + i * 32..104 + i * 32].copy_from_slice(typ);
        }
        let mut gpu = Vec::new();
        let mut stream = Vec::new();
        for (index, blob) in blobs.iter().enumerate() {
            pad(&mut toc, 16)?;
            let mut entry = blob.entry;
            put64(&mut entry, 16, toc.len());
            put64(&mut entry, 32, gpu.len());
            if !blob.gpu.is_empty() {
                pad(&mut gpu, 64)?;
                put64(&mut entry, 32, gpu.len());
            }
            put64(&mut entry, 24, stream.len());
            put32(&mut entry, 56, blob.toc.len())?;
            put32(&mut entry, 60, blob.stream.len())?;
            put32(&mut entry, 64, blob.gpu.len())?;
            put32(&mut entry, 76, index + 1)?;
            let at = 72 + types.len() * 32 + index * 80;
            toc[at..at + 80].copy_from_slice(&entry);
            toc.extend_from_slice(&blob.toc);
            gpu.extend_from_slice(&blob.gpu);
            stream.extend_from_slice(&blob.stream);
        }
        pad(&mut toc, 16)?;
        let minimum = 256usize
            .checked_mul(blobs.len().max(1))
            .ok_or("资源包长度溢出")?;
        if toc.len() < minimum {
            toc.resize(minimum, 0);
        }
        Ok(Built { toc, gpu, stream })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rebuild_preserves_full_ids_metadata_and_side_streams() {
        let mut header = [0; 72];
        header[..4].copy_from_slice(&MAGIC.to_le_bytes());
        header[12] = 33;
        header[20] = 99;
        let p = Package {
            header,
            types: Vec::new(),
            entries: Vec::new(),
        };
        let mut a = [0; 80];
        a[..8].copy_from_slice(&u64::MAX.to_le_bytes());
        a[8..16].copy_from_slice(&77u64.to_le_bytes());
        a[40..56].fill(42);
        let mut b = a;
        b[0] = 3;
        let blobs = vec![
            Blob {
                entry: a,
                toc: vec![1; 5],
                gpu: vec![2; 7],
                stream: vec![3; 9],
            },
            Blob {
                entry: b,
                toc: vec![4; 8],
                gpu: vec![5; 3],
                stream: vec![6; 2],
            },
        ];
        let built = p.build(&blobs).unwrap();
        let parsed = Package::parse(&built.toc).unwrap();
        assert_eq!(parsed.header[20], 99);
        assert_eq!(&parsed.entries[0][40..56], &[42; 16]);
        assert_eq!(u64at(&parsed.entries[1], 32).unwrap(), 64);
        let read = parsed.blobs(&built.toc, &built.gpu, &built.stream).unwrap();
        assert_eq!(read[0].stream, blobs[0].stream);
        assert_eq!(read[1].gpu, blobs[1].gpu);
        assert_eq!(read[1].toc, blobs[1].toc);
        assert!(parsed.blobs(&built.toc, &[], &built.stream).is_err());
        assert!(Package::parse(&built.toc[..100]).is_err());
    }
}
