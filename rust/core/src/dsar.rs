//! Bounded DSAR range reader and raw LZ4 block decoder. No external codec DLL.
use std::collections::{BTreeMap, VecDeque};
use std::io::{Read, Seek, SeekFrom};
fn u32at(b: &[u8], at: usize) -> Result<u32, String> {
    Ok(u32::from_le_bytes(
        b.get(at..at + 4)
            .ok_or("DSAR 字段截断")?
            .try_into()
            .unwrap(),
    ))
}
fn u64at(b: &[u8], at: usize) -> Result<u64, String> {
    Ok(u64::from_le_bytes(
        b.get(at..at + 8)
            .ok_or("DSAR 字段截断")?
            .try_into()
            .unwrap(),
    ))
}
pub fn lz4(input: &[u8], size: usize) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    out.try_reserve_exact(size)
        .map_err(|_| "LZ4 输出内存不足")?;
    let mut at = 0;
    let length = |at: &mut usize, base: usize| -> Result<usize, String> {
        let mut n = base;
        if base == 15 {
            loop {
                let extra = *input.get(*at).ok_or("LZ4 长度截断")? as usize;
                *at += 1;
                n = n.checked_add(extra).ok_or("LZ4 长度溢出")?;
                if extra != 255 {
                    break;
                }
            }
        }
        Ok(n)
    };
    while at < input.len() {
        let token = input[at];
        at += 1;
        let literals = length(&mut at, (token >> 4) as usize)?;
        let end = at.checked_add(literals).ok_or("LZ4 长度溢出")?;
        if out.len().checked_add(literals).is_none_or(|n| n > size) {
            return Err("LZ4 输出超过声明长度".into());
        }
        out.extend_from_slice(input.get(at..end).ok_or("LZ4 原始段截断")?);
        at = end;
        if at == input.len() {
            break;
        }
        let off = input.get(at..at + 2).ok_or("LZ4 匹配偏移截断")?;
        let offset = u16::from_le_bytes(off.try_into().unwrap()) as usize;
        at += 2;
        if offset == 0 || offset > out.len() {
            return Err("LZ4 匹配偏移无效".into());
        }
        let count = length(&mut at, (token & 15) as usize)?
            .checked_add(4)
            .ok_or("LZ4 匹配长度溢出")?;
        if out.len().checked_add(count).is_none_or(|n| n > size) {
            return Err("LZ4 匹配超过声明长度".into());
        }
        for _ in 0..count {
            out.push(out[out.len() - offset]);
        }
    }
    if out.len() != size {
        return Err("LZ4 解压长度与声明不一致".into());
    }
    Ok(out)
}
pub struct Chunk {
    pub uncompressed: u64,
    pub compressed: u64,
    pub size: u32,
    pub stored: u32,
    pub compression: u8,
}
pub struct Dsar<R> {
    source: R,
    pub chunks: Vec<Chunk>,
    cache: BTreeMap<usize, Vec<u8>>,
    order: VecDeque<usize>,
}
impl<R: Read + Seek> Dsar<R> {
    pub fn open(mut source: R) -> Result<Self, String> {
        let file_size = source
            .seek(SeekFrom::End(0))
            .map_err(|_| "无法获取 DSAR 长度")?;
        source
            .seek(SeekFrom::Start(0))
            .map_err(|_| "无法定位 DSAR")?;
        let mut head = [0; 32];
        source.read_exact(&mut head).map_err(|_| "DSAR 头部截断")?;
        if &head[..4] != b"DSAR" {
            return Err("DSAR 标记无效".into());
        }
        let count = u32at(&head, 8)? as usize;
        if count > 1000000 || 32 + count as u64 * 32 > file_size {
            return Err("DSAR 分块目录无效".into());
        }
        let mut chunks = Vec::new();
        let mut previous_end = 0;
        for _ in 0..count {
            let mut row = [0; 32];
            source
                .read_exact(&mut row)
                .map_err(|_| "DSAR 分块目录截断")?;
            let c = Chunk {
                uncompressed: u64at(&row, 0)?,
                compressed: u64at(&row, 8)?,
                size: u32at(&row, 16)?,
                stored: u32at(&row, 20)?,
                compression: row[24],
            };
            if c.uncompressed < previous_end
                || c.compressed
                    .checked_add(c.stored as u64)
                    .is_none_or(|end| end > file_size)
            {
                return Err("DSAR 分块范围无效".into());
            }
            if ![0, 3].contains(&c.compression) {
                return Err(format!("不支持的 DSAR 压缩类型：{}", c.compression));
            }
            if c.compressed < 32 + count as u64 * 32 && c.stored > 0 {
                return Err("DSAR 内容覆盖分块目录".into());
            }
            previous_end = c
                .uncompressed
                .checked_add(c.size as u64)
                .ok_or("DSAR 地址溢出")?;
            chunks.push(c);
        }
        Ok(Self {
            source,
            chunks,
            cache: BTreeMap::new(),
            order: VecDeque::new(),
        })
    }
    fn load(&mut self, index: usize) -> Result<(), String> {
        if self.cache.contains_key(&index) {
            return Ok(());
        }
        let c = &self.chunks[index];
        if c.stored > 256 * 1024 * 1024 || c.size > 256 * 1024 * 1024 {
            return Err("DSAR 单块超过当前内存读取上限".into());
        }
        self.source
            .seek(SeekFrom::Start(c.compressed))
            .map_err(|_| "无法定位 DSAR 内容")?;
        let mut bytes = vec![0; c.stored as usize];
        self.source
            .read_exact(&mut bytes)
            .map_err(|_| "DSAR 内容截断")?;
        let decoded = if c.compression == 3 {
            lz4(&bytes, c.size as usize)?
        } else {
            if bytes.len() != c.size as usize {
                return Err("DSAR 原始分块长度不一致".into());
            }
            bytes
        };
        self.cache.insert(index, decoded);
        self.order.push_back(index);
        while self.order.len() > 4 {
            if let Some(old) = self.order.pop_front() {
                self.cache.remove(&old);
            }
        }
        Ok(())
    }
    pub fn read_range(&mut self, offset: u64, size: usize) -> Result<Vec<u8>, String> {
        let end = offset.checked_add(size as u64).ok_or("DSAR 读取范围溢出")?;
        let mut out = Vec::new();
        out.try_reserve_exact(size)
            .map_err(|_| "DSAR 读取内存不足")?;
        let mut at = offset;
        while at < end {
            let index = self
                .chunks
                .partition_point(|c| c.uncompressed <= at)
                .checked_sub(1)
                .ok_or("DSAR 读取未映射")?;
            let c = &self.chunks[index];
            let remaining = c.uncompressed + c.size as u64;
            if at >= remaining {
                return Err("DSAR 读取范围存在空洞".into());
            }
            let start = (at - c.uncompressed) as usize;
            let n = (end.min(remaining) - at) as usize;
            self.load(index)?;
            out.extend_from_slice(&self.cache[&index][start..start + n]);
            at += n as u64;
        }
        Ok(out)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn lz4_overlap_and_malformed_inputs() {
        assert_eq!(lz4(&[0x15, b'a', 1, 0], 10).unwrap(), b"aaaaaaaaaa");
        assert_eq!(lz4(&[0x30, b'a', b'b', b'c'], 3).unwrap(), b"abc");
        for data in [&[0x10, b'a', 0, 0][..], &[0xf0, 255][..]] {
            assert!(lz4(data, 10).is_err());
        }
    }
    #[test]
    fn ranges_cross_raw_and_compressed_chunks() {
        let mut bytes = vec![0; 96];
        bytes[..4].copy_from_slice(b"DSAR");
        bytes[8..12].copy_from_slice(&2u32.to_le_bytes());
        for (index, (uoff, coff, usize, csize, comp)) in
            [(0u64, 96u64, 3u32, 3u32, 0u8), (3, 99, 10, 4, 3)]
                .iter()
                .enumerate()
        {
            let at = 32 + index * 32;
            bytes[at..at + 8].copy_from_slice(&uoff.to_le_bytes());
            bytes[at + 8..at + 16].copy_from_slice(&coff.to_le_bytes());
            bytes[at + 16..at + 20].copy_from_slice(&usize.to_le_bytes());
            bytes[at + 20..at + 24].copy_from_slice(&csize.to_le_bytes());
            bytes[at + 24] = *comp;
        }
        bytes.extend(b"abc");
        bytes.extend([0x15, b'a', 1, 0]);
        let mut d = Dsar::open(std::io::Cursor::new(bytes)).unwrap();
        assert_eq!(d.read_range(1, 7).unwrap(), b"bcaaaaa");
        assert!(d.read_range(12, 2).is_err());
    }
}
