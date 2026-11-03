//! Construct a sealed export and reopen it for verification. Never installs files.
use crate::{correction, dlbin, hash, sealed};

pub struct Prepared {
    pub ciphertext: Vec<u8>,
    pub target_hash: u64,
    pub plaintext_sha256: String,
    pub correction: correction::Report,
}

pub fn prepare(
    snapshot: &[u8],
    edited: &[u8],
    options: &correction::Options,
    progress: impl FnMut(usize),
) -> Result<Prepared, String> {
    let original = dlbin::index(snapshot).map_err(|e| e.to_string())?;
    let changed = dlbin::index(edited).map_err(|e| e.to_string())?;
    if snapshot.len() != edited.len() || original != changed {
        return Err("导出前数据块布局或头部已改变，不能按当前快照写入".into());
    }
    // Every requested edit must be inside a payload. Padding and reference
    // metadata outside the blocks cannot be changed by a numeric transaction.
    for (at, (&before, &after)) in snapshot.iter().zip(edited).enumerate() {
        if before != after && !original.iter().any(|b| b.contains(at, 1)) {
            return Err(format!("修改越过有效载荷：{at:#x}"));
        }
    }
    // Explicit float borrowing must refer to a field the caller actually edited.
    for &at in options.float_offsets {
        let end = at.checked_add(4).ok_or("浮点字段偏移溢出")?;
        if snapshot.get(at..end).is_none() || snapshot.get(at..end) == edited.get(at..end) {
            return Err(format!("只能明确允许微调已修改的浮点字段：{at:#x}"));
        }
    }
    let target_hash = hash::murmur64(snapshot);
    let corrected =
        correction::correct(edited, target_hash, options, progress).map_err(|e| e.to_string())?;
    let ciphertext = sealed::seal(&corrected.bytes).map_err(|e| e.to_string())?;
    let reopened = sealed::open_data(&ciphertext).map_err(|e| e.to_string())?;
    if reopened != corrected.bytes || hash::murmur64(&reopened) != target_hash {
        return Err("导出文件回读校验失败".into());
    }
    Ok(Prepared {
        ciphertext,
        target_hash,
        plaintext_sha256: hash::sha256_hex(&reopened),
        correction: corrected.report,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> Vec<u8> {
        let mut b = b"LDLD\x01\0\0\0".to_vec();
        b.extend(1u32.to_le_bytes());
        b.extend(8u32.to_le_bytes());
        b.extend([1, 0, 0, 0, 0, 0, 0, 0]);
        b.extend(1f32.to_le_bytes());
        b.extend([0; 4]);
        b
    }
    #[test]
    fn unmodified_export_roundtrips_and_preserves_hash() {
        let input = fixture();
        let result = prepare(&input, &input, &correction::Options::default(), |_| {}).unwrap();
        assert_eq!(sealed::open_data(&result.ciphertext).unwrap(), input);
        assert_eq!(result.target_hash, hash::murmur64(&input));
    }
    #[test]
    fn rejects_changed_metadata_and_unedited_float_permissions() {
        let input = fixture();
        let mut bad = input.clone();
        bad[8] = 2;
        assert!(prepare(&input, &bad, &correction::Options::default(), |_| {}).is_err());
        assert!(prepare(
            &input,
            &input,
            &correction::Options {
                float_offsets: &[24],
                ..Default::default()
            },
            |_| {}
        )
        .is_err());
    }
}
