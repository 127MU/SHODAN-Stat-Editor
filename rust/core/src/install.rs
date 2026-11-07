//! Native filesystem transaction. Prepared files are verified before replacement;
//! failure rolls back only files still matching this transaction's output.
use crate::hash::sha256_hex;
use serde_json::{json, Value};
use std::{
    collections::BTreeSet,
    fs,
    io::Write,
    path::{Path, PathBuf},
};
pub struct Change {
    pub path: PathBuf,
    pub before: Option<Vec<u8>>,
    pub after: Option<Vec<u8>>,
}
pub struct Receipt {
    pub changed: usize,
    pub backup: PathBuf,
}
pub struct Progress {
    pub stage: &'static str,
    pub done: usize,
    pub total: usize,
}
fn io_failure(action: &str, path: &Path, error: std::io::Error) -> String {
    format!(
        "{action}：{}（系统错误 {}：{error}）",
        path.display(),
        error.raw_os_error().unwrap_or(0)
    )
}
pub(crate) fn read(path: &Path) -> Result<Option<Vec<u8>>, String> {
    match fs::read(path) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(io_failure("无法读取待安装文件", path, error)),
    }
}
fn create(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|error| io_failure("无法创建事务文件", path, error))?;
    file.write_all(bytes)
        .and_then(|_| file.sync_all())
        .map_err(|error| io_failure("无法完整写入事务文件", path, error))?;
    if fs::read(path).map_err(|_| "无法回读事务文件")? != bytes {
        return Err("事务文件回读不一致".into());
    }
    Ok(())
}
#[cfg(windows)]
fn replace(source: &Path, target: &Path) -> Result<(), String> {
    use std::os::windows::ffi::OsStrExt;
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn MoveFileExW(from: *const u16, to: *const u16, flags: u32) -> i32;
    }
    let from: Vec<_> = source.as_os_str().encode_wide().chain(Some(0)).collect();
    let to: Vec<_> = target.as_os_str().encode_wide().chain(Some(0)).collect();
    if unsafe { MoveFileExW(from.as_ptr(), to.as_ptr(), 1 | 8) } == 0 {
        return Err(format!(
            "无法替换目标文件 {}（Windows 错误 {}）",
            target.display(),
            std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
        ));
    }
    Ok(())
}
#[cfg(not(windows))]
fn replace(source: &Path, target: &Path) -> Result<(), String> {
    fs::rename(source, target).map_err(|_| "无法替换目标文件".into())
}
fn stage_path(path: &Path, tag: &str, index: usize) -> Result<PathBuf, String> {
    let parent = path.parent().ok_or("目标缺少父目录")?;
    Ok(parent.join(format!(".shodan-{tag}-{index}.tmp")))
}
pub(crate) fn save_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let folder = path.parent().ok_or("缺少配置目录")?;
    fs::create_dir_all(folder).map_err(|error| io_failure("无法创建配置目录", folder, error))?;
    if fs::symlink_metadata(path).is_ok_and(|m| !m.is_file()) {
        return Err("配置目标必须是普通文件".into());
    }
    let tag = format!(
        "{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| "系统时间无效")?
            .as_nanos()
    );
    let stage = stage_path(path, &tag, 0)?;
    let result = create(&stage, bytes).and_then(|()| replace(&stage, path));
    if stage.is_file() {
        let _ = fs::remove_file(stage);
    }
    result
}
pub(crate) fn lock_transaction(backup: &Path) -> Result<fs::File, String> {
    let path = backup.join("active.lock");
    if fs::symlink_metadata(&path).is_ok_and(|m| !m.is_file()) {
        return Err("事务锁必须是普通文件".into());
    }
    let file = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)
        .map_err(|_| "无法打开安装事务锁")?;
    file.try_lock().map_err(|_| "该安装事务正在处理")?;
    Ok(file)
}
pub(crate) fn committed(backup: &Path) -> Result<bool, String> {
    match read(&backup.join("committed"))?.as_deref() {
        Some(b"1\n") => Ok(true),
        None | Some(b"" | b"1") => Ok(false),
        _ => Err("事务完成标记无效".into()),
    }
}
fn commit_one(change: &Change, stage: &Path) -> Result<(), String> {
    if read(&change.path)? != change.before {
        return Err("目标在准备后被其他程序修改".into());
    }
    if change.after.is_some() {
        replace(stage, &change.path)?;
    } else if change.before.is_some() {
        fs::remove_file(&change.path).map_err(|_| "无法移除已管理文件")?;
    }
    if read(&change.path)? != change.after {
        return Err("目标写入回读不一致".into());
    }
    Ok(())
}
pub fn apply(
    changes: Vec<Change>,
    backup: &Path,
    mut progress: impl FnMut(Progress),
) -> Result<Receipt, String> {
    // Resolve parents before writing; aliases and casing cannot install one target twice.
    let mut unique = BTreeSet::new();
    let mut changes = changes;
    for change in &mut changes {
        let directory = change.path.parent().ok_or("目标缺少父目录")?;
        let parent = fs::canonicalize(directory)
            .map_err(|error| io_failure("目标目录不存在或不可读", directory, error))?;
        let filename = change.path.file_name().ok_or("目标不是文件")?;
        change.path = parent.join(filename);
        if fs::symlink_metadata(&change.path)
            .is_ok_and(|m| m.file_type().is_symlink() || m.is_dir())
        {
            return Err("目标不是普通文件".into());
        }
        let key = change.path.to_string_lossy().to_string();
        #[cfg(windows)]
        let key = key.to_lowercase();
        if !unique.insert(key) {
            return Err("安装计划含有重复目标".into());
        }
        if read(&change.path)? != change.before {
            return Err("磁盘文件已变化，未安装任何内容".into());
        }
    }
    changes.retain(|c| c.before != c.after);
    if changes.is_empty() {
        return Ok(Receipt {
            changed: 0,
            backup: backup.to_path_buf(),
        });
    }
    fs::create_dir(backup).map_err(|error| io_failure("无法创建全新的备份目录", backup, error))?;
    let _lock = lock_transaction(backup)?;
    let tag = format!(
        "{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| "系统时间无效")?
            .as_nanos()
    );
    let total = changes.len();
    let mut stages = Vec::new();
    let mut committed = 0usize;
    let journal = json!({"version":1,"state":"prepared","files":changes.iter().enumerate().map(|(index,c)|json!({"target":c.path,"backup":format!("{index}.original"),
        "before":c.before.as_ref().map(|b|sha256_hex(b)),"after":c.after.as_ref().map(|b|sha256_hex(b))})).collect::<Vec<_>>()});
    let result = (|| {
        for (index, c) in changes.iter().enumerate() {
            progress(Progress {
                stage: "backup",
                done: index,
                total,
            });
            if let Some(bytes) = &c.before {
                create(&backup.join(format!("{index}.original")), bytes)?;
            }
            let stage = stage_path(&c.path, &tag, index)?;
            // Register before create so a partial write is also removed on failure.
            stages.push(stage.clone());
            if let Some(bytes) = &c.after {
                create(&stage, bytes)?;
            }
        }
        create(&backup.join("journal.json"), journal.to_string().as_bytes())?;
        for (index, c) in changes.iter().enumerate() {
            progress(Progress {
                stage: "commit",
                done: index,
                total,
            });
            // Include this entry in rollback if replacement succeeds but verification fails.
            if read(&c.path)? != c.before {
                return Err("提交前发现外部修改".into());
            }
            committed = index + 1;
            commit_one(c, &stages[index])?;
        }
        create(&backup.join("committed"), b"1\n")?;
        progress(Progress {
            stage: "complete",
            done: total,
            total,
        });
        Ok(Receipt {
            changed: total,
            backup: backup.to_path_buf(),
        })
    })();
    let mut rollback_errors = 0;
    if result.is_err() {
        for index in (0..committed).rev() {
            progress(Progress {
                stage: "rollback",
                done: committed - index - 1,
                total: committed,
            });
            let c = &changes[index];
            let current = read(&c.path);
            if current.as_ref().is_ok_and(|b| b == &c.before) {
                continue;
            }
            if !current.as_ref().is_ok_and(|b| b == &c.after) {
                rollback_errors += 1;
                continue;
            }
            let rollback = (|| {
                if let Some(bytes) = &c.before {
                    let stage = stage_path(&c.path, &format!("{tag}-rollback"), index)?;
                    create(&stage, bytes)?;
                    let restored = replace(&stage, &c.path);
                    if stage.exists() {
                        let _ = fs::remove_file(&stage);
                    }
                    restored?;
                } else {
                    fs::remove_file(&c.path).map_err(|_| "无法撤回新增文件")?;
                }
                if read(&c.path)? != c.before {
                    return Err("回滚回读不一致".into());
                }
                Ok::<(), String>(())
            })();
            if rollback.is_err() {
                rollback_errors += 1;
            }
        }
    }
    for stage in stages {
        if stage.exists() {
            let _ = fs::remove_file(stage);
        }
    }
    if rollback_errors > 0 {
        return Err(format!(
            "安装失败，另有 {rollback_errors} 项无法安全回滚；备份和事务日志已保留"
        ));
    }
    result
}

/// Build reverse changes only after checking every backup and installed fingerprint.
fn read_journal(backup: &Path) -> Result<Value, String> {
    let path = backup.join("journal.json");
    let meta = fs::symlink_metadata(&path).map_err(|_| "无法读取备份日志")?;
    if !meta.is_file() || meta.len() > 8 * 1024 * 1024 {
        return Err("备份日志过大".into());
    }
    let bytes = fs::read(path).map_err(|_| "无法读取备份日志")?;
    let journal: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|_| "备份日志格式无效")?;
    if journal["version"] != 1 || journal["state"] != "prepared" {
        return Err("不支持的备份版本".into());
    }
    Ok(journal)
}

fn fingerprint(row: &Value, key: &str) -> Result<Option<String>, String> {
    match row.get(key) {
        Some(Value::Null) => Ok(None),
        Some(Value::String(hash))
            if hash.len() == 64 && hash.bytes().all(|b| b.is_ascii_hexdigit()) =>
        {
            Ok(Some(hash.to_ascii_lowercase()))
        }
        _ => Err("备份日志指纹无效".into()),
    }
}

fn original(
    backup: &Path,
    index: usize,
    expected: Option<&str>,
) -> Result<Option<Vec<u8>>, String> {
    let Some(expected) = expected else {
        return Ok(None);
    };
    // The journal never supplies the location of the backup bytes.
    let path = backup.join(format!("{index}.original"));
    if !fs::symlink_metadata(&path).is_ok_and(|m| m.is_file()) {
        return Err("原始备份缺失或不是普通文件".into());
    }
    let bytes = fs::read(path).map_err(|_| "原始备份缺失")?;
    if sha256_hex(&bytes) != expected {
        return Err("原始备份指纹不匹配".into());
    }
    Ok(Some(bytes))
}

/// Build reverse changes only after checking every backup and installed fingerprint.
pub fn restore(
    backup: &Path,
    new_backup: &Path,
    progress: impl FnMut(Progress),
) -> Result<Receipt, String> {
    let _lock = lock_transaction(backup)?;
    if !committed(backup)? {
        return Err("该事务未完成，不能按已安装记录恢复".into());
    }
    let journal = read_journal(backup)?;
    let rows = journal["files"].as_array().ok_or("缺少备份条目")?;
    let mut changes = Vec::new();
    for (index, row) in rows.iter().enumerate() {
        let path = PathBuf::from(row["target"].as_str().ok_or("备份目标无效")?);
        let current = read(&path)?;
        let actual = current.as_ref().map(|b| sha256_hex(b));
        let expected = fingerprint(row, "after")?;
        if actual != expected {
            return Err("目标已被外部修改，停止恢复".into());
        }
        let before = original(backup, index, fingerprint(row, "before")?.as_deref())?;
        changes.push(Change {
            path,
            before: current,
            after: before,
        });
    }
    apply(changes, new_backup, progress)
}

/// Recover a prepared transaction after a process exit. Every target must be
/// either unchanged or an exact transaction output before any reversal starts.
pub fn recover_interrupted(
    backup: &Path,
    new_backup: &Path,
    target_root: &Path,
    progress: impl FnMut(Progress),
) -> Result<Receipt, String> {
    recover_scoped(backup, new_backup, &[target_root], progress)
}

pub(crate) fn recover_scoped(
    backup: &Path,
    new_backup: &Path,
    target_roots: &[&Path],
    progress: impl FnMut(Progress),
) -> Result<Receipt, String> {
    let roots = target_roots
        .iter()
        .map(|root| {
            let root = fs::canonicalize(root).map_err(|_| "无法确认事务目标目录")?;
            if !root.is_dir() {
                return Err("事务目标范围必须是目录");
            }
            Ok(root)
        })
        .collect::<Result<Vec<_>, _>>()?;
    let _lock = lock_transaction(backup)?;
    if committed(backup)? {
        return Err("该事务已完成，请使用备份恢复".into());
    }
    let journal = read_journal(backup)?;
    let rows = journal["files"].as_array().ok_or("缺少备份条目")?;
    let mut changes = Vec::new();
    for (index, row) in rows.iter().enumerate() {
        let path = PathBuf::from(row["target"].as_str().ok_or("备份目标无效")?);
        let parent = path.parent().ok_or("备份目标缺少父目录")?;
        let parent = fs::canonicalize(parent).map_err(|_| "无法核对备份目标目录")?;
        if !roots.iter().any(|root| parent.starts_with(root)) {
            return Err("备份目标超出当前事务目录".into());
        }
        let path = parent.join(path.file_name().ok_or("备份目标文件名无效")?);
        if fs::symlink_metadata(&path).is_ok_and(|m| !m.is_file()) {
            return Err("备份目标不是普通文件".into());
        }
        let current = read(&path)?;
        let actual = current.as_ref().map(|bytes| sha256_hex(bytes));
        let before = fingerprint(row, "before")?;
        let after = fingerprint(row, "after")?;
        if actual == before {
            continue;
        }
        if actual != after {
            return Err("中断后发现外部修改，已保留当前文件".into());
        }
        changes.push(Change {
            path,
            before: current,
            after: original(backup, index, before.as_deref())?,
        });
    }
    changes.reverse();
    apply(changes, new_backup, progress)
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Sandbox {
        root: PathBuf,
        path: PathBuf,
    }
    impl Sandbox {
        fn new() -> Self {
            let root =
                Path::new(env!("CARGO_MANIFEST_DIR")).join("../../dist/native-install-tests");
            fs::create_dir_all(&root).unwrap();
            let root = fs::canonicalize(root).unwrap();
            let path = root.join(format!(
                "{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            fs::create_dir(&path).unwrap();
            Self { root, path }
        }
    }
    impl Drop for Sandbox {
        fn drop(&mut self) {
            assert!(self.path.starts_with(&self.root) && self.path != self.root);
            let _ = fs::remove_dir_all(&self.path);
        }
    }
    fn change(path: PathBuf, before: Option<&[u8]>, after: Option<&[u8]>) -> Change {
        Change {
            path,
            before: before.map(Vec::from),
            after: after.map(Vec::from),
        }
    }
    #[test]
    fn install_restore_create_delete_and_backups_are_verified() {
        let s = Sandbox::new();
        let a = s.path.join("数值.bin");
        let b = s.path.join("patch.new");
        let c = s.path.join("old.patch");
        fs::write(&a, b"original").unwrap();
        fs::write(&c, b"remove").unwrap();
        let backup = s.path.join("backup");
        let receipt = apply(
            vec![
                change(a.clone(), Some(b"original"), Some(b"edited")),
                change(b.clone(), None, Some(b"new")),
                change(c.clone(), Some(b"remove"), None),
            ],
            &backup,
            |_| {},
        )
        .unwrap();
        assert_eq!(receipt.changed, 3);
        assert_eq!(fs::read(&a).unwrap(), b"edited");
        assert!(!c.exists());
        restore(&backup, &s.path.join("restore-backup"), |_| {}).unwrap();
        assert_eq!(fs::read(a).unwrap(), b"original");
        assert!(!b.exists());
        assert_eq!(fs::read(c).unwrap(), b"remove");
    }
    #[test]
    fn external_change_during_commit_keeps_external_bytes_and_rolls_back_previous_file() {
        let s = Sandbox::new();
        let a = s.path.join("a");
        let b = s.path.join("b");
        fs::write(&a, b"A").unwrap();
        fs::write(&b, b"B").unwrap();
        let result = apply(
            vec![
                change(a.clone(), Some(b"A"), Some(b"newA")),
                change(b.clone(), Some(b"B"), Some(b"newB")),
            ],
            &s.path.join("backup"),
            |p| {
                if p.stage == "commit" && p.done == 1 {
                    fs::write(&b, b"external").unwrap();
                }
            },
        );
        assert!(result.is_err());
        assert_eq!(fs::read(a).unwrap(), b"A");
        assert_eq!(fs::read(b).unwrap(), b"external");
        assert!(!s.path.join("backup/committed").exists());
    }
    #[test]
    fn corrupted_backup_and_stale_target_are_not_restored() {
        let s = Sandbox::new();
        let a = s.path.join("a");
        fs::write(&a, b"A").unwrap();
        let backup = s.path.join("backup");
        apply(
            vec![change(a.clone(), Some(b"A"), Some(b"new"))],
            &backup,
            |_| {},
        )
        .unwrap();
        fs::write(backup.join("0.original"), b"corrupt").unwrap();
        assert!(restore(&backup, &s.path.join("r1"), |_| {}).is_err());
        assert_eq!(fs::read(&a).unwrap(), b"new");
        fs::write(&a, b"external").unwrap();
        assert!(restore(&backup, &s.path.join("r2"), |_| {}).is_err());
        assert_eq!(fs::read(&a).unwrap(), b"external");
    }

    #[test]
    fn interrupted_recovery_checks_scope_lock_and_fingerprints_before_reversing() {
        let s = Sandbox::new();
        let data = s.path.join("data");
        fs::create_dir(&data).unwrap();
        let a = data.join("已替换");
        let b = data.join("已新增");
        let c = data.join("尚未替换");
        fs::write(&a, b"A").unwrap();
        fs::write(&c, b"C").unwrap();
        let backup = s.path.join("backup");
        let recovered = s.path.join("recovered");
        apply(
            vec![
                change(a.clone(), Some(b"A"), Some(b"newA")),
                change(b.clone(), None, Some(b"B")),
                change(c.clone(), Some(b"C"), Some(b"newC")),
            ],
            &backup,
            |progress| {
                if progress.stage == "commit" {
                    assert!(recover_interrupted(&backup, &recovered, &data, |_| {}).is_err());
                }
            },
        )
        .unwrap();
        fs::write(backup.join("committed"), b"").unwrap();
        fs::write(&c, b"C").unwrap();
        let unrelated = s.path.join("unrelated");
        fs::create_dir(&unrelated).unwrap();
        assert!(recover_interrupted(&backup, &recovered, &unrelated, |_| {}).is_err());
        fs::write(&c, b"external").unwrap();
        assert!(recover_interrupted(&backup, &recovered, &data, |_| {}).is_err());
        assert_eq!(fs::read(&a).unwrap(), b"newA");
        assert_eq!(fs::read(&b).unwrap(), b"B");
        assert!(!recovered.exists());
        fs::write(&c, b"C").unwrap();
        assert_eq!(
            recover_interrupted(&backup, &recovered, &data, |_| {})
                .unwrap()
                .changed,
            2
        );
        assert_eq!(fs::read(&a).unwrap(), b"A");
        assert_eq!(fs::read(&c).unwrap(), b"C");
        assert!(!b.exists());
        assert_eq!(
            recover_interrupted(&backup, &recovered, &data, |_| {})
                .unwrap()
                .changed,
            0
        );
    }
}
