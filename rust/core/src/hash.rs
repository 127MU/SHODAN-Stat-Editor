//! Game-compatible Murmur64A and cryptographic fingerprints, entirely in Rust.
use sha2::{Digest, Sha256};

const MULTIPLIER: u64 = 0xC6A4_A793_5BD1_E995;
const SEED: u64 = 0xDEAD_BEEF_ABAD_1DEA;

pub fn murmur64(data: &[u8]) -> u64 {
    let mut h = SEED ^ (data.len() as u64).wrapping_mul(MULTIPLIER);
    let mut chunks = data.chunks_exact(8);
    for bytes in &mut chunks {
        let mut k = u64::from_le_bytes(bytes.try_into().unwrap()).wrapping_mul(MULTIPLIER);
        k ^= k >> 47;
        k = k.wrapping_mul(MULTIPLIER);
        h = (h ^ k).wrapping_mul(MULTIPLIER);
    }
    let tail = chunks.remainder();
    if !tail.is_empty() {
        let mut bytes = [0u8; 8];
        bytes[..tail.len()].copy_from_slice(tail);
        h = (h ^ u64::from_le_bytes(bytes)).wrapping_mul(MULTIPLIER);
    }
    h ^= h >> 47;
    h = h.wrapping_mul(MULTIPLIER);
    h ^ (h >> 47)
}

pub fn sha256(data: &[u8]) -> [u8; 32] {
    Sha256::digest(data).into()
}

pub fn sha256_hex(data: &[u8]) -> String {
    use std::fmt::Write;
    let mut result = String::with_capacity(64);
    for byte in sha256(data) {
        write!(&mut result, "{byte:02x}").unwrap();
    }
    result
}

/// This matches the legacy executable's hash lookup; it is a version check,
/// not a cryptographic proof of the file's original values or authorship.
pub fn expected_by_game(plain: &[u8], game_dll: &[u8]) -> bool {
    let hash = murmur64(plain).to_le_bytes();
    game_dll.windows(hash.len()).any(|window| window == hash)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn matches_seeded_reference_vectors_and_all_tail_lengths() {
        assert_eq!(murmur64(b""), 0xd9f1_8670_253a_13e6);
        assert_eq!(murmur64(b"a"), 0x83f3_9880_a138_5fb7);
        assert_eq!(murmur64(b"LDLD\x01\0\0\0"), 0xd3df_8079_9730_0ca9);
        assert_eq!(
            murmur64(&(0..31).collect::<Vec<u8>>()),
            0x5f67_d9e7_4aa6_d5d5
        );
    }
    #[test]
    fn fingerprint_and_game_lookup_are_separate() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        let mut dll = vec![0, 1, 2];
        dll.extend(murmur64(b"abc").to_le_bytes());
        assert!(expected_by_game(b"abc", &dll));
        assert!(!expected_by_game(b"abd", &dll));
        assert!(!expected_by_game(b"abc", &[]));
    }
}
