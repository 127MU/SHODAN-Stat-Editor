//! Typed little-endian numeric editing. Baselines are immutable original bytes.
pub mod armor;
pub mod audio;
pub mod baseline;
pub mod bundles;
pub mod correction;
pub mod dependencies;
pub mod diagnostics;
pub mod dlbin;
pub mod document;
pub mod dsar;
pub mod export;
pub mod hash;
pub mod install;
pub mod mcp;
pub mod native_api;
pub mod parameters;
pub mod passive;
pub mod preset;
pub mod references;
pub mod residency;
pub mod resource_package;
pub mod resource_resolver;
pub mod schema;
pub mod sealed;
pub mod session;
pub mod tables;
pub mod update;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    U32,
    I32,
    F32,
}
#[derive(Clone, Debug)]
pub struct Edit {
    pub offset: usize,
    pub original: [u8; 4],
    pub value: [u8; 4],
}
fn bytes(data: &[u8], offset: usize) -> Result<[u8; 4], &'static str> {
    let end = offset.checked_add(4).ok_or("offset overflow")?;
    data.get(offset..end)
        .ok_or("field out of bounds")?
        .try_into()
        .map_err(|_| "invalid field")
}
pub fn read(data: &[u8], offset: usize, kind: Kind) -> Result<f64, &'static str> {
    let b = bytes(data, offset)?;
    Ok(match kind {
        Kind::U32 => u32::from_le_bytes(b) as f64,
        Kind::I32 => i32::from_le_bytes(b) as f64,
        Kind::F32 => f32::from_le_bytes(b) as f64,
    })
}
pub fn plan(original: &[u8], offset: usize, kind: Kind, value: f64) -> Result<Edit, &'static str> {
    if !value.is_finite() {
        return Err("value must be finite");
    }
    let encoded = match kind {
        Kind::U32 => {
            if value.fract() != 0.0 || value < 0.0 || value > u32::MAX as f64 {
                return Err("outside u32 representation");
            }
            (value as u32).to_le_bytes()
        }
        Kind::I32 => {
            if value.fract() != 0.0 || value < i32::MIN as f64 || value > i32::MAX as f64 {
                return Err("outside i32 representation");
            }
            (value as i32).to_le_bytes()
        }
        Kind::F32 => {
            let v = value as f32;
            if !v.is_finite() {
                return Err("outside f32 representation");
            }
            v.to_le_bytes()
        }
    };
    Ok(Edit {
        offset,
        original: bytes(original, offset)?,
        value: encoded,
    })
}
pub fn apply(snapshot: &[u8], edits: &[Edit]) -> Result<Vec<u8>, &'static str> {
    let mut result = snapshot.to_vec();
    let mut ranges = std::collections::BTreeSet::new();
    for edit in edits {
        if bytes(snapshot, edit.offset)? != edit.original {
            return Err("baseline mismatch");
        }
        for offset in edit.offset..edit.offset + 4 {
            if !ranges.insert(offset) {
                return Err("overlapping edits");
            }
        }
        result[edit.offset..edit.offset + 4].copy_from_slice(&edit.value);
    }
    Ok(result)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn floats_are_not_integer_bits() {
        assert_eq!(read(&1f32.to_le_bytes(), 0, Kind::F32).unwrap(), 1.0);
    }
    #[test]
    fn full_representable_range() {
        let b = [0; 4];
        assert!(plan(&b, 0, Kind::F32, 1e6).is_ok());
        assert!(plan(&b, 0, Kind::F32, -2.5).is_ok());
        assert!(plan(&b, 0, Kind::U32, 4294967295.0).is_ok());
    }
    #[test]
    fn immutable_baseline() {
        let b = 1f32.to_le_bytes();
        let e = plan(&b, 0, Kind::F32, 2.0).unwrap();
        assert_eq!(read(&apply(&b, &[e]).unwrap(), 0, Kind::F32).unwrap(), 2.0);
        assert_eq!(read(&b, 0, Kind::F32).unwrap(), 1.0);
    }
    #[test]
    fn reject_stale_or_overlapping() {
        let b = [0; 8];
        let e = plan(&b, 0, Kind::U32, 3.0).unwrap();
        assert!(apply(&[1; 8], &[e.clone()]).is_err());
        assert!(apply(&b, &[e.clone(), e]).is_err());
    }
    #[test]
    fn invalid_inputs() {
        assert!(read(&[0; 4], usize::MAX, Kind::U32).is_err());
        assert!(plan(&[0; 4], 0, Kind::U32, 1.2).is_err());
        assert!(plan(&[0; 4], 0, Kind::F32, f64::NAN).is_err());
    }
}
