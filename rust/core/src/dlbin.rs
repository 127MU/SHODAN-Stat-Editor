//! Bounds-checked LDLD block indexing. No Lua, FFI, or game process is required.
//!
//! Blocks have a 24-byte header; bytes around headers are deliberately opaque.
//! In particular, the bytes before a block are not reliably zero padding.
use std::{fmt, ops::Range};

const MAGIC: &[u8; 8] = b"LDLD\x01\0\0\0";
const HEADER_LEN: usize = 24;
const SEARCH_WINDOW: usize = 64;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Block {
    pub header_offset: usize,
    pub type_id: u32,
    pub payload: Range<usize>,
    pub flag: u8,
    pub reserved: [u8; 7],
}

impl Block {
    /// Only describes the header. It does NOT prove that payload values are original.
    pub fn has_original_header(&self) -> bool {
        self.flag == 1 && self.reserved == [0; 7]
    }

    pub fn contains(&self, offset: usize, length: usize) -> bool {
        offset >= self.payload.start
            && offset
                .checked_add(length)
                .is_some_and(|end| end <= self.payload.end)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ParseError {
    NoBlocks,
    TruncatedHeader(usize),
    TruncatedPayload {
        offset: usize,
        declared: u32,
        available: usize,
    },
    UnexpectedData(usize),
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoBlocks => write!(f, "未找到 LDLD 数据块"),
            Self::TruncatedHeader(at) => write!(f, "数据块头不完整：偏移 {at:#x}"),
            Self::TruncatedPayload {
                offset,
                declared,
                available,
            } => write!(
                f,
                "数据块越界：偏移 {offset:#x}，声明 {declared} 字节，可用 {available} 字节"
            ),
            Self::UnexpectedData(at) => write!(f, "无法识别后续数据块：偏移 {at:#x}"),
        }
    }
}

impl std::error::Error for ParseError {}

fn locate(data: &[u8], start: usize) -> Option<usize> {
    let end = start.saturating_add(SEARCH_WINDOW).min(data.len());
    data.get(start..end)?
        .windows(MAGIC.len())
        .position(|s| s == MAGIC)
        .map(|n| start + n)
}

pub fn index(data: &[u8]) -> Result<Vec<Block>, ParseError> {
    let mut at = locate(data, 0).ok_or(ParseError::NoBlocks)?;
    let mut blocks = Vec::new();
    loop {
        let header = data
            .get(at..at.saturating_add(HEADER_LEN))
            .ok_or(ParseError::TruncatedHeader(at))?;
        let type_id = u32::from_le_bytes(header[8..12].try_into().unwrap());
        let size = u32::from_le_bytes(header[12..16].try_into().unwrap());
        let start = at + HEADER_LEN;
        let end = start
            .checked_add(size as usize)
            .filter(|&end| end <= data.len())
            .ok_or(ParseError::TruncatedPayload {
                offset: at,
                declared: size,
                available: data.len() - start,
            })?;
        blocks.push(Block {
            header_offset: at,
            type_id,
            payload: start..end,
            flag: header[16],
            reserved: header[17..24].try_into().unwrap(),
        });
        if end == data.len() {
            break;
        }
        match locate(data, end) {
            Some(next) => at = next,
            // Never silently accept an unparsed suffix, even when a legacy scan did.
            None => return Err(ParseError::UnexpectedData(end)),
        }
    }
    Ok(blocks)
}

#[cfg(test)]
mod tests {
    use super::*;
    pub(super) fn block(kind: u32, payload: &[u8]) -> Vec<u8> {
        let mut b = MAGIC.to_vec();
        b.extend(kind.to_le_bytes());
        b.extend((payload.len() as u32).to_le_bytes());
        b.extend([1, 0, 0, 0, 0, 0, 0, 0]);
        b.extend(payload);
        b
    }
    #[test]
    fn duplicate_types_and_opaque_prefixes_are_preserved() {
        let mut data = 42u32.to_le_bytes().to_vec();
        data.extend(block(42, &[0; 4]));
        data.extend([3, 9, 1, 7]);
        data.extend(block(42, &[8; 4]));
        let blocks = index(&data).unwrap();
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[1].type_id, 42);
        assert_eq!(blocks[0].header_offset, 4);
        assert!(blocks[0].has_original_header());
    }
    #[test]
    fn malformed_blocks_are_not_silently_dropped() {
        let mut data = block(1, &[0; 4]);
        data.pop();
        assert!(matches!(
            index(&data),
            Err(ParseError::TruncatedPayload { .. })
        ));
        assert!(matches!(index(MAGIC), Err(ParseError::TruncatedHeader(0))));
        let mut data = block(1, &[]);
        data.extend([7; 70]);
        assert!(matches!(index(&data), Err(ParseError::UnexpectedData(24))));
    }
    #[test]
    fn markers_inside_payload_are_not_headers() {
        let data = block(7, MAGIC);
        assert_eq!(index(&data).unwrap().len(), 1);
    }
    #[test]
    fn original_header_does_not_imply_original_payload() {
        let mut data = block(3, &u32::MAX.to_le_bytes());
        let first = index(&data).unwrap().remove(0);
        assert!(first.has_original_header());
        data[17] = 99;
        assert!(!index(&data).unwrap()[0].has_original_header());
        assert!(!first.contains(usize::MAX, 4));
    }
}
