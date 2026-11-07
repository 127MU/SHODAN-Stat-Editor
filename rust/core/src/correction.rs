//! Hash-preserving LDLD export preparation, without Lua or shodan_hash.dll.
//! All work uses a private copy; failure, cancellation and timeout cannot modify input.
use crate::{dlbin, hash::murmur64};
use std::{
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};

const MUL: u64 = 0xC6A4_A793_5BD1_E995;
const INV: u64 = 0x5F7A_0EA7_E59B_19BD;
const SEED: u64 = 0xDEAD_BEEF_ABAD_1DEA;
const BATCH: usize = 256;

pub struct Options<'a> {
    /// Explicitly allowed edited f32 fields. Empty means no payload adjustment.
    pub float_offsets: &'a [usize],
    pub workers: usize,
    pub timeout: Duration,
    pub cancelled: Option<&'a AtomicBool>,
}
impl Default for Options<'_> {
    fn default() -> Self {
        Self {
            float_offsets: &[],
            workers: std::thread::available_parallelism().map_or(1, |n| n.get().min(8)),
            timeout: Duration::from_secs(60),
            cancelled: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    InvalidData(String),
    InvalidHeader(usize),
    UnsupportedAlignment(usize),
    InvalidFloat(usize),
    NoSalt,
    NoSolution,
    Cancelled,
    Timeout,
    Verification,
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidData(s) => write!(f, "数据结构无效：{s}"),
            Self::InvalidHeader(at) => write!(f, "数据块标记异常：{at:#x}"),
            Self::UnsupportedAlignment(at) => write!(f, "不支持的数据块对齐：{at:#x}"),
            Self::InvalidFloat(at) => write!(f, "不允许借用此浮点字段：{at:#x}"),
            Self::NoSalt => f.write_str("没有可用的保留字节；需要明确允许微调已编辑的浮点字段"),
            Self::NoSolution => f.write_str("在允许的范围内未找到哈希修正"),
            Self::Cancelled => f.write_str("哈希修正已取消，输入未改变"),
            Self::Timeout => f.write_str("哈希修正超时，输入未改变"),
            Self::Verification => f.write_str("哈希或保护区域复核失败，未输出修改"),
        }
    }
}
impl std::error::Error for Error {}

#[derive(Clone, Debug)]
pub struct Report {
    pub header: Option<usize>,
    pub salts_tested: usize,
    pub adjusted_float: Option<(usize, f32, f32)>,
}
pub struct Corrected {
    pub bytes: Vec<u8>,
    pub report: Report,
}

#[derive(Clone, Copy)]
enum Salt {
    Header(usize),
    Float(usize),
}
impl Salt {
    fn offset(self) -> usize {
        match self {
            Self::Header(at) | Self::Float(at) => at,
        }
    }
    fn end(self) -> usize {
        self.offset()
            + match self {
                Self::Header(_) => 2,
                Self::Float(_) => 4,
            }
    }
    fn tries(self) -> u32 {
        match self {
            Self::Header(_) => 65535,
            Self::Float(_) => 4095,
        }
    }
    fn put(self, data: &mut [u8], original: u32, value: u32) {
        let at = self.offset();
        match self {
            Self::Header(_) => data[at..at + 2].copy_from_slice(&(value as u16).to_le_bytes()),
            Self::Float(_) => data[at..at + 4].copy_from_slice(&(original ^ value).to_le_bytes()),
        }
    }
}
fn word(data: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(data[at..at + 8].try_into().unwrap())
}
fn mix(mut v: u64) -> u64 {
    v = v.wrapping_mul(MUL);
    v ^= v >> 47;
    v.wrapping_mul(MUL)
}
fn unmix(mut v: u64) -> u64 {
    v = v.wrapping_mul(INV);
    v ^= v >> 47;
    v.wrapping_mul(INV)
}
fn forward(mut h: u64, data: &[u8], start: usize, end: usize) -> u64 {
    for at in (start..end).step_by(8) {
        h = (h ^ mix(word(data, at))).wrapping_mul(MUL);
    }
    h
}
fn backward(mut h: u64, data: &[u8], start: usize, end: usize) -> u64 {
    for at in (start..end).step_by(8).rev() {
        h = h.wrapping_mul(INV) ^ mix(word(data, at));
    }
    h
}
fn before_final(target: u64, data: &[u8]) -> (u64, usize) {
    let mut h = target ^ (target >> 47);
    h = h.wrapping_mul(INV);
    h ^= h >> 47;
    let whole = data.len() / 8 * 8;
    if whole < data.len() {
        let mut t = [0; 8];
        t[..data.len() - whole].copy_from_slice(&data[whole..]);
        h = h.wrapping_mul(INV) ^ u64::from_le_bytes(t);
    }
    (h, whole)
}
fn interrupted(options: &Options, start: Instant) -> Option<Error> {
    if options.cancelled.is_some_and(|v| v.load(Ordering::Relaxed)) {
        Some(Error::Cancelled)
    } else if start.elapsed() >= options.timeout {
        Some(Error::Timeout)
    } else {
        None
    }
}

/// The unaligned search shares each mixed header word across a batch of salts.
/// Workers are bounded and stop cooperatively; no raw pointers or native threads.
fn search(
    states: &[(u64, u64)],
    fixed: u64,
    high: u64,
    options: &Options,
    start: Instant,
) -> Option<(usize, u64, u64)> {
    let stop = AtomicBool::new(false);
    std::thread::scope(|scope| {
        let count = options.workers.clamp(1, 64);
        let span = (1u32 << 24).div_ceil(count as u32);
        let mut jobs = Vec::with_capacity(count);
        for job in 0..count {
            let stop = &stop;
            jobs.push(scope.spawn(move || {
                let from = job as u32 * span;
                let to = (from + span).min(1 << 24);
                for t in from..to {
                    if t & 1023 == 0
                        && (stop.load(Ordering::Relaxed) || interrupted(options, start).is_some())
                    {
                        return None;
                    }
                    let w = fixed | ((t as u64) << 40);
                    let v = mix(w);
                    for (salt, &(before, need)) in states.iter().enumerate() {
                        let u = unmix((before ^ v).wrapping_mul(MUL) ^ need);
                        if u >> 32 == high {
                            stop.store(true, Ordering::Relaxed);
                            return Some((salt, w, u));
                        }
                    }
                }
                None
            }));
        }
        let mut answer = None;
        for job in jobs {
            if let Ok(Some(found)) = job.join() {
                answer = Some(found);
            }
        }
        answer
    })
}

pub fn correct(
    input: &[u8],
    target: u64,
    options: &Options,
    mut progress: impl FnMut(usize),
) -> Result<Corrected, Error> {
    let start = Instant::now();
    if let Some(error) = interrupted(options, start) {
        return Err(error);
    }
    let blocks = dlbin::index(input).map_err(|e| Error::InvalidData(e.to_string()))?;
    for b in &blocks {
        if b.flag != 1 {
            return Err(Error::InvalidHeader(b.header_offset));
        }
        if b.header_offset % 4 != 0 {
            return Err(Error::UnsupportedAlignment(b.header_offset));
        }
    }
    if murmur64(input) == target {
        return Ok(Corrected {
            bytes: input.to_vec(),
            report: Report {
                header: None,
                salts_tested: 0,
                adjusted_float: None,
            },
        });
    }
    let mut data = input.to_vec();
    // Normalise only reserved correction bytes. Payload and metadata stay intact.
    for b in &blocks {
        data[b.header_offset + 17..b.header_offset + 24].fill(0);
    }
    let header = blocks
        .iter()
        .rev()
        .find(|b| b.header_offset % 8 == 0)
        .unwrap_or_else(|| blocks.last().unwrap());
    let x = header.header_offset;
    let aligned = x % 8 == 0;
    if !aligned && header.payload.len() < 4 {
        return Err(Error::InvalidData("未对齐块缺少载荷前四字节".into()));
    }
    let first = if aligned { x + 16 } else { x + 12 };
    let end = if aligned { x + 24 } else { x + 28 };
    let (final_state, whole) = before_final(target, &data);
    if end > whole {
        return Err(Error::InvalidData("修正区超过完整字边界".into()));
    }
    let mut salts: Vec<_> = blocks
        .iter()
        .filter(|b| b.header_offset != x)
        .map(|b| Salt::Header(b.header_offset + 17))
        .collect();
    for &at in options.float_offsets {
        if !blocks.iter().any(|b| b.contains(at, 4))
            || at.checked_add(4).is_none_or(|end| end > whole)
            || !f32::from_le_bytes(
                data.get(at..at.saturating_add(4))
                    .ok_or(Error::InvalidFloat(at))?
                    .try_into()
                    .unwrap(),
            )
            .is_finite()
        {
            return Err(Error::InvalidFloat(at));
        }
        if salts.iter().any(|s| matches!(s,Salt::Float(o) if *o==at)) {
            continue;
        }
        salts.push(Salt::Float(at));
    }
    salts.sort_by_key(|s| (matches!(s, Salt::Float(_)), s.offset().abs_diff(x)));
    if salts.is_empty() {
        return Err(Error::NoSalt);
    }
    let initial = SEED ^ (data.len() as u64).wrapping_mul(MUL);
    let mut tested = 0;
    for salt in salts {
        let at = salt.offset();
        let lo = at / 8 * 8;
        let hi = (salt.end() + 7) / 8 * 8;
        // The caller's float cannot share one of the two solved words.
        if !(hi <= first || lo >= end) {
            if matches!(salt, Salt::Float(_)) {
                return Err(Error::InvalidFloat(at));
            }
            continue;
        }
        let original = if matches!(salt, Salt::Float(_)) {
            u32::from_le_bytes(data[at..at + 4].try_into().unwrap())
        } else {
            0
        };
        let (before, after) = if hi <= first {
            (
                forward(initial, &data, 0, lo),
                backward(final_state, &data, end, whole),
            )
        } else {
            (
                forward(initial, &data, 0, first),
                backward(final_state, &data, hi, whole),
            )
        };
        let fixed = if aligned {
            0
        } else {
            word(&data, x + 12) & 0xFF_FFFF_FFFF
        };
        let high = if aligned {
            0
        } else {
            word(&data, x + 20) >> 32
        };
        let mut value = 1;
        while value <= salt.tries() {
            if let Some(error) = interrupted(options, start) {
                return Err(error);
            }
            let count = if aligned {
                1
            } else {
                BATCH.min((salt.tries() - value + 1) as usize)
            };
            let mut states = Vec::with_capacity(count);
            for k in 0..count {
                salt.put(&mut data, original, value + k as u32);
                let (a, b) = if hi <= first {
                    (forward(before, &data, lo, first), after)
                } else {
                    (before, backward(after, &data, end, hi))
                };
                states.push((a, b.wrapping_mul(INV)));
            }
            let found = if aligned {
                let w = unmix(states[0].0 ^ states[0].1);
                (w & 255 == 1).then_some((0, w, 0))
            } else {
                search(&states, fixed, high, options, start)
            };
            tested += count;
            progress(tested);
            if let Some(error) = interrupted(options, start) {
                return Err(error);
            }
            if let Some((k, w12, w20)) = found {
                salt.put(&mut data, original, value + k as u32);
                if aligned {
                    data[x + 16..x + 24].copy_from_slice(&w12.to_le_bytes());
                } else {
                    data[x + 12..x + 20].copy_from_slice(&w12.to_le_bytes());
                    data[x + 20..x + 28].copy_from_slice(&w20.to_le_bytes());
                }
                if murmur64(&data) != target {
                    return Err(Error::Verification);
                }
                // Every changed byte must be a reserved byte or an opted-in float.
                for (at, (&old, &new)) in input.iter().zip(&data).enumerate() {
                    if old != new
                        && !blocks
                            .iter()
                            .any(|b| at >= b.header_offset + 17 && at < b.header_offset + 24)
                        && !(matches!(salt, Salt::Float(_))
                            && at >= salt.offset()
                            && at < salt.end())
                    {
                        return Err(Error::Verification);
                    }
                }
                let adjusted_float = match salt {
                    Salt::Float(at) => Some((
                        at,
                        f32::from_bits(original),
                        f32::from_le_bytes(data[at..at + 4].try_into().unwrap()),
                    )),
                    _ => None,
                };
                return Ok(Corrected {
                    bytes: data,
                    report: Report {
                        header: Some(x),
                        salts_tested: tested,
                        adjusted_float,
                    },
                });
            }
            if let Some(error) = interrupted(options, start) {
                return Err(error);
            }
            value += count as u32;
        }
        salt.put(&mut data, original, 0);
    }
    Err(Error::NoSolution)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn block() -> Vec<u8> {
        let mut b = b"LDLD\x01\0\0\0".to_vec();
        b.extend(1u32.to_le_bytes());
        b.extend(8u32.to_le_bytes());
        b.extend([1, 0, 0, 0, 0, 0, 0, 0]);
        b.extend(1f32.to_le_bytes());
        b.extend([0; 4]);
        b
    }
    #[test]
    fn inverse_and_tail_states_match_forward_hash() {
        for n in 0..64 {
            let bytes: Vec<_> = (0..n).map(|x| x as u8).collect();
            let (end, whole) = before_final(murmur64(&bytes), &bytes);
            let start = SEED ^ (n as u64).wrapping_mul(MUL);
            assert_eq!(forward(start, &bytes, 0, whole), end);
            assert_eq!(backward(end, &bytes, 0, whole), start);
            assert_eq!(unmix(mix(n as u64)), n as u64);
        }
    }
    #[test]
    fn aligned_correction_only_changes_reserved_bytes() {
        let mut input = block();
        input.extend(block());
        let mut expected = input.clone();
        expected[17] = 1;
        expected[49] = 25;
        let target = murmur64(&expected);
        let before = input.clone();
        let result = correct(&input, target, &Options::default(), |_| {}).unwrap();
        assert_eq!(murmur64(&result.bytes), target);
        assert_eq!(input, before);
        assert!(result.report.adjusted_float.is_none());
    }
    #[test]
    fn unaligned_parallel_search_preserves_size_flag_and_payload() {
        let mut input = vec![0; 4];
        input.extend(block());
        input.extend(block());
        let mut expected = input.clone();
        expected[21] = 1;
        expected[56..60].copy_from_slice(&77u32.to_le_bytes());
        let target = murmur64(&expected);
        let result = correct(
            &input,
            target,
            &Options {
                workers: 2,
                ..Options::default()
            },
            |_| {},
        )
        .unwrap();
        assert_eq!(murmur64(&result.bytes), target);
        assert_eq!(&result.bytes[60..], &input[60..]);
        assert_eq!(dlbin::index(&result.bytes).unwrap()[1].payload.len(), 8);
    }

    #[test]
    fn unaligned_float_can_be_used_as_correction_salt() {
        let mut original = block();
        original[12..16].copy_from_slice(&24u32.to_le_bytes());
        original.resize(48, 0);
        for at in [25, 26, 27, 29, 30, 31] {
            let mut edited = original.clone();
            edited[at..at + 4].copy_from_slice(&32.0f32.to_le_bytes());
            let result = correct(
                &edited,
                murmur64(&original),
                &Options {
                    float_offsets: &[at],
                    workers: 2,
                    ..Options::default()
                },
                |_| {},
            )
            .unwrap();
            assert_eq!(murmur64(&result.bytes), murmur64(&original));
            assert_eq!(result.report.adjusted_float.map(|item| item.0), Some(at));
        }
    }

    #[test]
    fn float_crossing_into_partial_tail_is_rejected_without_changing_input() {
        let mut original = block();
        original[12..16].copy_from_slice(&12u32.to_le_bytes());
        original.resize(36, 0);
        let mut edited = original.clone();
        edited[29..33].copy_from_slice(&32.0f32.to_le_bytes());
        let before = edited.clone();
        assert!(matches!(
            correct(
                &edited,
                murmur64(&original),
                &Options {
                    float_offsets: &[29],
                    ..Options::default()
                },
                |_| {}
            ),
            Err(Error::InvalidFloat(29))
        ));
        assert_eq!(edited, before);
    }
    #[test]
    fn single_block_never_silently_adjusts_payload() {
        let mut input = vec![0; 4];
        input.extend(block());
        let target = murmur64(&block());
        assert!(matches!(
            correct(&input, target, &Options::default(), |_| {}),
            Err(Error::NoSalt)
        ));
    }
    #[test]
    fn cancellation_timeout_and_invalid_float_leave_input_intact() {
        let input = block();
        let target = murmur64(&input) ^ 1;
        let cancelled = AtomicBool::new(true);
        assert!(matches!(
            correct(
                &input,
                target,
                &Options {
                    cancelled: Some(&cancelled),
                    ..Options::default()
                },
                |_| {}
            ),
            Err(Error::Cancelled)
        ));
        assert!(matches!(
            correct(
                &input,
                target,
                &Options {
                    timeout: Duration::ZERO,
                    ..Options::default()
                },
                |_| {}
            ),
            Err(Error::Timeout)
        ));
        assert!(matches!(
            correct(
                &input,
                target,
                &Options {
                    float_offsets: &[12],
                    ..Options::default()
                },
                |_| {}
            ),
            Err(Error::InvalidFloat(12))
        ));
        assert_eq!(input, block());
    }
}
