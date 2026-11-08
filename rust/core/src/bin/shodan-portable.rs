#![cfg_attr(windows, windows_subsystem = "windows")]
//! Single-file bootstrap for the Flutter executable and its native engine.
use serde::Deserialize;
use shodan_core::hash;
use std::{
    collections::BTreeSet,
    env, fs,
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    process::{Command, ExitCode},
    time::{SystemTime, UNIX_EPOCH},
};

const TRAILER: u64 = 64;
const MAGIC: &[u8] = b"SHODAN-PORTABLE!";
const APP: &str = "SHODAN 数值编辑器.exe";
const MAX_FILE: usize = 96 * 1024 * 1024;

#[derive(Deserialize)]
struct File {
    path: String,
    size: usize,
    packed: usize,
    sha256: String,
}

fn safe_path(path: &str) -> bool {
    !path.is_empty()
        && !path.contains(['\\', ':', '\0'])
        && path.split('/').all(|name| {
            !name.is_empty() && !name.ends_with(['.', ' ']) && !name.chars().any(char::is_control)
        })
}

fn valid_file(path: &Path, spec: &File) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.is_file() && m.len() == spec.size as u64)
        && fs::read(path).is_ok_and(|b| hash::sha256_hex(&b) == spec.sha256)
}

fn cache_valid(root: &Path, files: &[File]) -> bool {
    fs::symlink_metadata(root).is_ok_and(|m| m.is_dir() && !m.file_type().is_symlink())
        && files.iter().all(|spec| {
            let mut target = root.to_path_buf();
            let mut parts = spec.path.split('/').peekable();
            while let Some(part) = parts.next() {
                target.push(part);
                if parts.peek().is_some()
                    && !fs::symlink_metadata(&target)
                        .is_ok_and(|m| m.is_dir() && !m.file_type().is_symlink())
                {
                    return false;
                }
            }
            valid_file(&target, spec)
        })
}

fn extract(cache: &Path, payload: &[u8], files: &[File]) -> Result<(), String> {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "系统时间无效")?
        .as_nanos();
    let staging = cache.with_extension(format!("{}-{stamp}.tmp", std::process::id()));
    fs::create_dir(&staging).map_err(|_| "无法创建程序缓存，请检查磁盘和写入权限")?;
    let result = (|| {
        let mut offset = 0;
        for spec in files {
            let end = offset + spec.packed;
            let packed = payload.get(offset..end).ok_or("程序包内容被截断")?;
            offset = end;
            let mut bytes = Vec::new();
            flate2::read::GzDecoder::new(packed)
                .take(spec.size as u64 + 1)
                .read_to_end(&mut bytes)
                .map_err(|_| "程序包解压失败")?;
            if bytes.len() != spec.size || hash::sha256_hex(&bytes) != spec.sha256 {
                return Err("程序包文件校验失败");
            }
            let target = staging.join(&spec.path);
            fs::create_dir_all(target.parent().unwrap()).map_err(|_| "无法创建程序目录")?;
            let mut output = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(target)
                .map_err(|_| "无法创建解压文件")?;
            output
                .write_all(&bytes)
                .and_then(|_| output.sync_all())
                .map_err(|_| "程序文件未完整写入")?;
        }
        if cache_valid(cache, files) {
            return Ok(());
        }
        // Preserve a damaged cache instead of repeatedly failing to rename a
        // freshly verified directory over an existing directory on Windows.
        let previous = if let Ok(meta) = fs::symlink_metadata(cache) {
            if !meta.is_dir() || meta.file_type().is_symlink() {
                return Err("程序缓存不是普通目录，未覆盖");
            }
            let saved = cache.with_extension(format!("damaged-{}-{stamp}", std::process::id()));
            fs::rename(cache, &saved).map_err(|_| "旧缓存正在使用或无法备份")?;
            Some(saved)
        } else {
            None
        };
        if fs::rename(&staging, cache).is_err() && !cache_valid(cache, files) {
            if let Some(saved) = previous {
                if !cache.exists() {
                    let _ = fs::rename(saved, cache);
                }
            }
            return Err("无法提交程序缓存，旧缓存已保留");
        }
        Ok(())
    })();
    // The staging directory has a unique path we created; never touch another cache.
    if staging.is_dir() {
        let _ = fs::remove_dir_all(&staging);
    }
    result.map_err(str::to_owned)
}

fn run(verify: bool) -> Result<(), String> {
    let exe = env::current_exe().map_err(|_| "无法读取程序自身路径")?;
    let mut input = fs::File::open(&exe).map_err(|_| "无法读取程序包")?;
    let size = input.metadata().map_err(|_| "无法读取程序包长度")?.len();
    if size < TRAILER {
        return Err("程序包不完整".into());
    }
    input
        .seek(SeekFrom::End(-(TRAILER as i64)))
        .map_err(|_| "程序包目录不可读")?;
    let mut trailer = [0; TRAILER as usize];
    input
        .read_exact(&mut trailer)
        .map_err(|_| "程序包目录不完整")?;
    let len = u64::from_le_bytes(trailer[32..40].try_into().unwrap());
    let index_len = u64::from_le_bytes(trailer[40..48].try_into().unwrap());
    if &trailer[48..] != MAGIC
        || len > 64 * 1024 * 1024
        || len > size - TRAILER
        || index_len == 0
        || index_len > len
        || index_len > 1024 * 1024
    {
        return Err("程序包版本无效或不完整".into());
    }
    let mut payload = vec![0; len as usize];
    input
        .seek(SeekFrom::Start(size - TRAILER - len))
        .and_then(|_| input.read_exact(&mut payload))
        .map_err(|_| "无法完整读取程序包")?;
    let digest = hash::sha256(&payload);
    if trailer[..32] != digest {
        return Err("程序包指纹不匹配".into());
    }
    let packed = (len - index_len) as usize;
    let files: Vec<File> =
        serde_json::from_slice(&payload[packed..]).map_err(|_| "程序包目录格式无效")?;
    let mut names = BTreeSet::new();
    if files.len() > 1024
        || files.iter().any(|f| {
            f.size > MAX_FILE
                || f.packed > packed
                || !safe_path(&f.path)
                || !names.insert(f.path.to_lowercase())
        })
        || files
            .iter()
            .try_fold(0usize, |a, f| a.checked_add(f.packed))
            != Some(packed)
        || files
            .iter()
            .try_fold(0usize, |a, f| a.checked_add(f.size))
            .is_none_or(|n| n > 256 * 1024 * 1024)
        || !files.iter().any(|f| f.path == APP)
    {
        return Err("程序包目录条目无效".into());
    }
    let dir_name = hash::sha256_hex(&payload)[..24].to_owned();
    let mut roots = Vec::new();
    if let Some(local) = env::var_os("LOCALAPPDATA") {
        roots.push(PathBuf::from(local).join("SHODAN").join("DesktopRuntime"));
    }
    roots.push(env::temp_dir().join("SHODAN").join("DesktopRuntime"));
    for root in roots {
        if fs::create_dir_all(&root).is_err() {
            continue;
        }
        let cache = root.join(&dir_name);
        let lock = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(root.join(format!(".{dir_name}.lock")));
        let Ok(lock) = lock else { continue };
        if lock.try_lock().is_err() {
            continue;
        }
        if !cache_valid(&cache, &files) && extract(&cache, &payload[..packed], &files).is_err() {
            continue;
        }
        if verify {
            return Ok(());
        }
        let mut child = Command::new(cache.join(APP));
        child.current_dir(&cache);
        if let Some(parent) = exe.parent() {
            child.env("SHODAN_LAUNCH_DIR", parent);
        }
        child.spawn().map_err(|_| "无法启动编辑器界面")?;
        return Ok(());
    }
    Err("无法创建或校验程序缓存，请检查磁盘空间或使用 ZIP 程序包".into())
}

#[cfg(windows)]
fn report(error: &str) {
    #[link(name = "user32")]
    unsafe extern "system" {
        fn MessageBoxW(window: isize, text: *const u16, title: *const u16, kind: u32) -> i32;
    }
    let text: Vec<_> = error.encode_utf16().chain(Some(0)).collect();
    let title: Vec<_> = "SHODAN 启动失败".encode_utf16().chain(Some(0)).collect();
    unsafe { MessageBoxW(0, text.as_ptr(), title.as_ptr(), 0x10) };
}
#[cfg(not(windows))]
fn report(error: &str) {
    eprintln!("{error}");
}

fn main() -> ExitCode {
    let verify = env::args_os()
        .nth(1)
        .is_some_and(|arg| arg == "--verify-package");
    match run(verify) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            if !verify {
                report(&error);
            }
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn corrupt_cache_is_backed_up_and_rebuilt() {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root =
            env::temp_dir().join(format!("shodan-cache-test-{}-{stamp}", std::process::id()));
        fs::create_dir(&root).unwrap();
        let cache = root.join("cache");
        fs::create_dir(&cache).unwrap();
        fs::write(cache.join("asset.dat"), b"damaged").unwrap();
        let raw = b"verified";
        let mut gzip = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        gzip.write_all(raw).unwrap();
        let payload = gzip.finish().unwrap();
        let specs = [File {
            path: "asset.dat".into(),
            size: raw.len(),
            packed: payload.len(),
            sha256: hash::sha256_hex(raw),
        }];
        assert!(!cache_valid(&cache, &specs));
        extract(&cache, &payload, &specs).unwrap();
        assert!(cache_valid(&cache, &specs));
        let saved = fs::read_dir(&root)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .find(|path| path != &cache)
            .unwrap();
        assert_eq!(fs::read(saved.join("asset.dat")).unwrap(), b"damaged");
        extract(&cache, &payload, &specs).unwrap();
        assert_eq!(fs::read_dir(&root).unwrap().count(), 2);
        for dir in [cache, saved] {
            fs::remove_file(dir.join("asset.dat")).unwrap();
            fs::remove_dir(dir).unwrap();
        }
        fs::remove_dir(root).unwrap();
    }
}
