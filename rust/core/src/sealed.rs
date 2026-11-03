//! RustCrypto NaCl sealed boxes, wire-compatible with the existing game codec.
//! No DLL loading or custom cryptographic primitive implementations.
use crypto_box::{aead::rand_core::OsRng, PublicKey, SecretKey};
use std::fmt;

// Format keys already used by offline/gamedata.lua; never include them in logs.
const PUBLIC: [u8; 32] = [
    0x2d, 0xc9, 0xaa, 0x7c, 0x30, 0xe6, 0xee, 0xd5, 0xf7, 0xfd, 0x0e, 0x0e, 0x95, 0xc7, 0x28, 0x72,
    0x99, 0xb1, 0x26, 0xf7, 0x95, 0x20, 0xcc, 0x41, 0xde, 0x75, 0x09, 0x82, 0xee, 0x7f, 0xf5, 0x0c,
];
const SECRET: [u8; 32] = [
    0xa0, 0x29, 0x6b, 0x81, 0x31, 0x0b, 0x58, 0xf0, 0x13, 0xd8, 0xa9, 0xb3, 0x43, 0xa1, 0xc2, 0x92,
    0x00, 0x80, 0x03, 0xdf, 0xd9, 0xab, 0x15, 0xfc, 0xf3, 0x51, 0x54, 0x30, 0x48, 0xb4, 0x9b, 0x64,
];
pub const OVERHEAD: usize = crypto_box::SEALBYTES;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CodecError {
    TooShort,
    Authentication,
    Encryption,
    InvalidData,
}
impl fmt::Display for CodecError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::TooShort => "密封文件不完整",
            Self::Authentication => "密封文件认证失败，文件可能损坏或格式不匹配",
            Self::Encryption => "无法封装数据文件",
            Self::InvalidData => "解密数据的 LDLD 结构无效",
        })
    }
}
impl std::error::Error for CodecError {}

/// Authenticate the complete sealed box before exposing any plaintext.
pub fn open(ciphertext: &[u8]) -> Result<Vec<u8>, CodecError> {
    if ciphertext.len() < OVERHEAD {
        return Err(CodecError::TooShort);
    }
    SecretKey::from(SECRET)
        .unseal(ciphertext)
        .map_err(|_| CodecError::Authentication)
}

pub fn seal(plaintext: &[u8]) -> Result<Vec<u8>, CodecError> {
    PublicKey::from(PUBLIC)
        .seal(&mut OsRng, plaintext)
        .map_err(|_| CodecError::Encryption)
}

/// Authentication and parsing are separate from verification of trusted originals.
pub fn open_data(ciphertext: &[u8]) -> Result<Vec<u8>, CodecError> {
    let plain = open(ciphertext)?;
    crate::dlbin::index(&plain).map_err(|_| CodecError::InvalidData)?;
    Ok(plain)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn format_keypair_matches_and_sealing_is_randomized() {
        assert_eq!(SecretKey::from(SECRET).public_key().to_bytes(), PUBLIC);
        for plain in [b"".as_slice(), b"hello", &[0; 33]] {
            let a = seal(plain).unwrap();
            let b = seal(plain).unwrap();
            assert_eq!(a.len(), plain.len() + OVERHEAD);
            assert_ne!(a, b);
            assert_eq!(open(&a).unwrap(), plain);
            assert_eq!(open(&b).unwrap(), plain);
        }
    }
    #[test]
    fn rejects_corruption_truncation_and_wrong_recipient() {
        let valid = seal(b"reference plaintext").unwrap();
        for length in 0..valid.len() {
            assert!(open(&valid[..length]).is_err());
        }
        for at in 0..valid.len() {
            let mut damaged = valid.clone();
            damaged[at] ^= 1;
            assert!(open(&damaged).is_err());
        }
        assert!(SecretKey::from([42; 32]).unseal(&valid).is_err());
        assert_eq!(open_data(&valid), Err(CodecError::InvalidData));
    }
}
