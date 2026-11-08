//! The desktop game's numeric session and its owned installation transactions.
use crate::{
    binary::Encoding,
    catalog::Catalog,
    hash,
    install::{self, Change, Progress},
    workspace::{Location, Workspace},
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    env, fs,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

const DLL: &str = "game.dll";

pub(crate) fn profile() -> PathBuf {
    env::var_os("SHODAN_PROFILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            env::var_os("LOCALAPPDATA")
                .map(PathBuf::from)
                .unwrap_or_else(env::temp_dir)
                .join("SHODAN")
                .join("StatEditor")
        })
}

fn game_at(root: &Path, allow_missing_entities: bool) -> Option<PathBuf> {
    [
        root.to_path_buf(),
        root.join("data/game"),
        root.join("steamapps/common/Helldivers 2/data/game"),
    ]
    .into_iter()
    .find_map(|p| {
        (p.join(DLL).is_file()
            && (allow_missing_entities || p.join("generated_entities.dl_bin").is_file()))
        .then(|| fs::canonicalize(p).ok())
        .flatten()
    })
}

fn steam_libraries(text: &str) -> impl Iterator<Item = PathBuf> + '_ {
    text.lines().filter_map(|line| {
        let rest = line.trim_start().strip_prefix("\"path\"")?.trim();
        let path = rest.strip_prefix('"')?.strip_suffix('"')?;
        Some(PathBuf::from(path.replace("\\\\", "\\")))
    })
}

#[cfg(windows)]
fn steam_path() -> Option<PathBuf> {
    #[link(name = "advapi32")]
    unsafe extern "system" {
        fn RegGetValueW(
            key: isize,
            sub: *const u16,
            name: *const u16,
            flags: u32,
            typ: *mut u32,
            data: *mut u16,
            size: *mut u32,
        ) -> i32;
    }
    let wide = |s: &str| s.encode_utf16().chain(Some(0)).collect::<Vec<_>>();
    let mut buf = [0_u16; 4096];
    let mut bytes = (buf.len() * 2) as u32;
    let status = unsafe {
        RegGetValueW(
            -2147483647,
            wide("Software\\Valve\\Steam").as_ptr(),
            wide("SteamPath").as_ptr(),
            2,
            std::ptr::null_mut(),
            buf.as_mut_ptr(),
            &mut bytes,
        )
    };
    let end = buf.iter().position(|c| *c == 0)?;
    (status == 0 && end > 0).then(|| PathBuf::from(String::from_utf16_lossy(&buf[..end])))
}

#[cfg(not(windows))]
fn steam_path() -> Option<PathBuf> {
    None
}

pub(crate) fn find_game(
    explicit: Option<&Path>,
    runtime: &Path,
    profile: &Path,
) -> Result<PathBuf, String> {
    find_game_checked(explicit, runtime, profile, false)
}

pub(crate) fn find_game_for_repair(
    explicit: Option<&Path>,
    runtime: &Path,
    profile: &Path,
) -> Result<PathBuf, String> {
    find_game_checked(explicit, runtime, profile, true)
}

fn find_game_checked(
    explicit: Option<&Path>,
    runtime: &Path,
    profile: &Path,
    allow_missing: bool,
) -> Result<PathBuf, String> {
    if let Some(path) = explicit {
        return game_at(path, allow_missing)
            .ok_or_else(|| "所选目录不含有效的 Helldivers 2 数据".into());
    }
    let launch_dir = env::var_os("SHODAN_LAUNCH_DIR").map(PathBuf::from);
    for dir in [Some(profile), launch_dir.as_deref(), Some(runtime)]
        .into_iter()
        .flatten()
    {
        if let Ok(text) = fs::read_to_string(dir.join("game folder.txt")) {
            if let Some(path) = game_at(
                Path::new(text.trim_start_matches('\u{feff}').trim()),
                allow_missing,
            ) {
                return Ok(path);
            }
        }
    }
    let mut roots = Vec::new();
    if let Some(steam) = steam_path() {
        if let Ok(vdf) = fs::read_to_string(steam.join("steamapps/libraryfolders.vdf")) {
            roots.extend(steam_libraries(&vdf));
        }
        roots.push(steam);
    }
    if let Some(x86) = env::var_os("ProgramFiles(x86)") {
        roots.push(PathBuf::from(x86).join("Steam"));
    }
    roots
        .into_iter()
        .find_map(|p| game_at(&p, allow_missing))
        .ok_or_else(|| "没有找到游戏。请将安装目录写入程序旁的 game folder.txt 后重启。".into())
}

#[cfg(windows)]
fn require_closed() -> Result<(), String> {
    #[repr(C)]
    struct Entry {
        size: u32,
        usage: u32,
        pid: u32,
        heap: usize,
        module: u32,
        threads: u32,
        parent: u32,
        priority: i32,
        flags: u32,
        exe: [u16; 260],
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn CreateToolhelp32Snapshot(flags: u32, pid: u32) -> isize;
        fn Process32FirstW(snapshot: isize, entry: *mut Entry) -> i32;
        fn Process32NextW(snapshot: isize, entry: *mut Entry) -> i32;
        fn CloseHandle(handle: isize) -> i32;
    }
    let snapshot = unsafe { CreateToolhelp32Snapshot(2, 0) };
    if snapshot == -1 {
        return Err("无法检查游戏进程，已停止写入".into());
    }
    let mut entry: Entry = unsafe { std::mem::zeroed() };
    entry.size = std::mem::size_of::<Entry>() as u32;
    let first = unsafe { Process32FirstW(snapshot, &mut entry) };
    let mut next = first;
    let mut running = false;
    while next != 0 {
        let end = entry
            .exe
            .iter()
            .position(|c| *c == 0)
            .unwrap_or(entry.exe.len());
        if String::from_utf16_lossy(&entry.exe[..end]).eq_ignore_ascii_case("helldivers2.exe") {
            running = true;
            break;
        }
        next = unsafe { Process32NextW(snapshot, &mut entry) };
    }
    unsafe { CloseHandle(snapshot) };
    if first == 0 {
        Err("无法检查游戏进程，已停止写入".into())
    } else if running {
        Err("请先完全退出《绝地潜兵 2》".into())
    } else {
        Ok(())
    }
}

#[cfg(not(windows))]
fn require_closed() -> Result<(), String> {
    Err("游戏文件写入仅支持 Windows".into())
}

pub(crate) fn valid_file(name: &str) -> bool {
    name.strip_prefix("generated_")
        .and_then(|s| s.strip_suffix(".dl_bin"))
        .is_some_and(|s| {
            !s.is_empty()
                && s.bytes()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_')
        })
}

#[derive(Clone, Deserialize, Serialize)]
struct Owned {
    transaction: String,
    index: usize,
    original: String,
    installed: String,
}

pub(crate) struct Game {
    pub(crate) root: PathBuf,
    state: PathBuf,
    inputs: Value,
    build: String,
    resources: std::cell::RefCell<Option<crate::resource_resolver::Resolver>>,
    archive: BTreeMap<String, crate::catalog::ResourceSource>,
    pub(crate) text_originals: std::cell::RefCell<Option<BTreeMap<u32, String>>>,
    pub(crate) migration_notes: Vec<String>,
}

fn archive_identity(name: &str) -> Result<crate::dependencies::Identity, String> {
    let (id, typ) = name.split_once('.').ok_or("独立资源身份无效")?;
    Ok((
        u64::from_str_radix(typ, 16).map_err(|_| "资源类型无效")?,
        u64::from_str_radix(id, 16).map_err(|_| "资源 ID 无效")?,
    ))
}

fn save_stamp() -> Result<String, String> {
    let instant = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "系统时间无效")?;
    Ok(format!("{}-{}", instant.as_nanos(), std::process::id()))
}

impl Game {
    pub(crate) fn open(
        catalog: &Catalog,
        root: PathBuf,
        runtime: &Path,
        profile: &Path,
    ) -> Result<(Self, Workspace), String> {
        let mut game = Self::load(catalog, root, runtime, profile)?;
        let mut workspace = game.reopen()?;
        if !game.state.join("configuration.json").exists()
            && !game.state.join("draft.json").exists()
        {
            match crate::desktop_presets::migrate_profile(catalog, &mut workspace, profile) {
                Ok(notes) => game.migration_notes.extend(notes),
                Err(error) => game
                    .migration_notes
                    .push(format!("旧配置导入未完成 · {error}")),
            }
        }
        Ok((game, workspace))
    }

    pub(crate) fn load(
        catalog: &Catalog,
        root: PathBuf,
        runtime: &Path,
        profile: &Path,
    ) -> Result<Self, String> {
        Self::load_checked(catalog, root, runtime, profile, false)
    }

    pub(crate) fn load_for_repair(
        catalog: &Catalog,
        root: PathBuf,
        runtime: &Path,
        profile: &Path,
    ) -> Result<Self, String> {
        Self::load_checked(catalog, root, runtime, profile, true)
    }

    fn load_checked(
        catalog: &Catalog,
        root: PathBuf,
        runtime: &Path,
        profile: &Path,
        allow_missing: bool,
    ) -> Result<Self, String> {
        let dll = fs::read(root.join(DLL)).map_err(|_| "无法读取游戏版本")?;
        let build = hash::sha256_hex(&dll);
        if catalog.game_build.as_deref() != Some(build.as_str()) {
            return Err("原生参数目录与当前游戏版本不匹配".into());
        }
        let original_dir = runtime.join("originals");
        let mut names: BTreeSet<_> = catalog
            .bindings
            .iter()
            .flatten()
            .flat_map(|b| &b.locations)
            .map(|l| l.file.as_str())
            .filter(|name| valid_file(name))
            .collect();
        names.extend([crate::desktop_armor::PASSIVE, crate::desktop_armor::KITS]);
        let mut files = Vec::new();
        for name in names {
            let path = root.join(name);
            if !path.is_file()
                && !(allow_missing
                    && fs::symlink_metadata(&path)
                        .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound))
            {
                return Err(format!("游戏目录缺少 {name}"));
            }
            let stem = name.strip_suffix(".dl_bin").unwrap_or(name);
            let baseline_name = format!("{stem}.dl_plain");
            let baseline_path = original_dir.join(&baseline_name);
            let mut input = json!({"name":name,"path":path,"sealed":true});
            if name == crate::desktop_armor::PASSIVE
                && hash::expected_by_game(crate::desktop_armor::BASELINE, &dll)
            {
                input["embedded_armor"] = json!(true);
            }
            if baseline_path.is_file() {
                let original = fs::read(&baseline_path).map_err(|_| "无法读取随附原值")?;
                if hash::expected_by_game(&original, &dll) {
                    input["baseline_name"] = json!(baseline_name);
                    input["baseline_path"] = json!(baseline_path);
                }
            }
            files.push(input);
        }
        let key = hash::sha256_hex(root.to_string_lossy().as_bytes());
        let state = profile.join("native-game").join(&key[..16]);
        let inputs = json!({"files":files,"isolate_invalid_files":true});
        let mut game = Self {
            root,
            state,
            inputs,
            build,
            resources: Default::default(),
            archive: catalog
                .resources
                .iter()
                .filter(|(_, s)| crate::residency::package_name(&s.package))
                .map(|(name, s)| (name.clone(), s.clone()))
                .collect(),
            text_originals: Default::default(),
            migration_notes: Vec::new(),
        };
        if profile.join("residency.txt").is_file() && !game.state.join("residency.json").exists() {
            match game.migrate_residency(profile) {
                Ok(notes) => game.migration_notes.extend(notes),
                Err(error) => game
                    .migration_notes
                    .push(format!("旧资源补丁记录未接管 · {error}")),
            }
        }
        Ok(game)
    }

    fn migrate_residency(&self, profile: &Path) -> Result<Vec<String>, String> {
        fs::create_dir_all(&self.state).map_err(|_| "无法创建新版配置目录")?;
        let _lock = install::lock_transaction(&self.state)?;
        let known = self
            .archive
            .iter()
            .filter_map(|(name, source)| {
                archive_identity(name)
                    .ok()
                    .map(|key| (source.package.as_str(), key))
            })
            .collect::<BTreeSet<_>>();
        let mut resources = self.resources()?;
        crate::residency_install::migrate_legacy(
            self.data()?,
            &self.state.join("residency.json"),
            profile,
            &mut resources.as_mut().unwrap().bundles,
            |package, key| {
                known.contains(&(package, key))
                    || package == crate::residency_install::CARRIER
                        && key.0 == crate::desktop_text::STRINGS
                    || key.0 == crate::desktop_resource_edits::MACHINE
            },
        )
    }

    pub(crate) fn reopen(&self) -> Result<Workspace, String> {
        let mut workspace = crate::workspace_api::open(&self.inputs)?;
        if !self.archive.is_empty() {
            let mut cache = self.resources()?;
            let resolver = cache.as_mut().unwrap();
            let mut overrides = BTreeMap::new();
            for (name, spec) in &self.archive {
                let (typ, id) = archive_identity(name)?;
                let base = resolver.bundles.resource(&spec.package, (typ, id))?;
                if base.len() != spec.bytes || hash::sha256_hex(&base) != spec.sha256 {
                    return Err(format!("独立资源 {name} 与该版本的参数目录不匹配"));
                }
                if !overrides.contains_key(&spec.package) {
                    overrides.insert(spec.package.clone(), self.overrides(&spec.package));
                }
                let changes = match &overrides[&spec.package] {
                    Ok(changes) => changes,
                    Err(error) => {
                        workspace.block_resource(name.clone(), error.clone());
                        continue;
                    }
                };
                let current = changes
                    .get(&(typ, id))
                    .cloned()
                    .unwrap_or_else(|| base.clone());
                let record = crate::workspace::Record::Resource { typ, id };
                workspace.add(
                    name.clone(),
                    crate::workspace::File::resource(
                        self.root.join(name),
                        current,
                        record,
                        Some(base),
                    )?,
                )?;
            }
        }
        if let Ok((_, owned)) = self.owned() {
            for (name, item) in owned
                .iter()
                .filter(|(name, _)| workspace.contains(name))
                .collect::<Vec<_>>()
            {
                if let Ok((_, bytes)) = self.verified_backup(name, item, false) {
                    if let Ok(original) = crate::sealed::open_data(&bytes) {
                        let _ = workspace.remember_install_source(name, original);
                    }
                }
            }
        }
        let configuration = (|| {
            if let Some(bytes) = install::read(&self.state.join("configuration.json"))? {
                if bytes.len() > 8 * 1024 * 1024 {
                    return Err("已安装编辑器配置过大".into());
                }
                workspace.set_loaded_metadata(
                    serde_json::from_slice(&bytes).map_err(|_| "已安装编辑器配置无效")?,
                )?;
            }
            Ok::<(), String>(())
        })();
        if let Err(error) = configuration {
            workspace.block_profile(format!("本地 configuration.json 无法读取：{error}；已保留原文件，当前游戏参数仍可浏览，请先运行自动修复"));
        } else if let Err(error) = workspace.configure_draft(self.state.join("draft.json")) {
            workspace.block_profile(format!("本地 draft.json 无法读取：{error}；已保留原文件，当前游戏参数仍可浏览，请先运行自动修复"));
        }
        Ok(workspace)
    }

    fn game_dll(&self) -> Result<Vec<u8>, String> {
        let bytes = fs::read(self.root.join(DLL)).map_err(|_| "无法核对游戏版本")?;
        if hash::sha256_hex(&bytes) != self.build {
            return Err("打开编辑器后游戏版本已改变，请重新启动编辑器".into());
        }
        Ok(bytes)
    }

    pub(crate) fn baseline_check(&self, workspace: &Workspace) -> Value {
        self.check(workspace, true, true)
    }

    /// Repair only state owned by this editor. Transaction recovery verifies
    /// both fingerprints before touching a target; foreign patches stay intact.
    pub(crate) fn repair(
        &self,
        catalog: &Catalog,
        mut progress: impl FnMut(Progress),
    ) -> Result<(Workspace, Value), String> {
        require_closed()?;
        self.game_dll()?;
        progress(Progress {
            stage: "repair_recover",
            done: 0,
            total: 3,
        });
        let recovery = self.recover(&mut progress);
        let unreadable_repair = if recovery.is_ok() {
            self.repair_unreadable_files(&self.game_dll()?, &mut progress)
        } else {
            Err("安装事务尚未恢复，未修复无法解析的数值文件".into())
        };
        let numeric_repair = if recovery.is_ok() {
            self.repair_numeric_records(&self.game_dll()?)
        } else {
            Err("安装事务尚未恢复，未变更数值安装登记".into())
        };
        let invalid_draft = self.repair_invalid_draft()?;
        let invalid_configuration = self.repair_invalid_state("configuration.json", |bytes| {
            serde_json::from_slice::<Value>(bytes)
                .is_ok_and(|value| value.is_object() || value.is_null())
        })?;
        let residency_repair = (|| {
            let (_lock, _, backup) = self.begin()?;
            let (changes, count) = crate::residency_install::repair_missing(
                self.data()?,
                &self.state.join("residency.json"),
            )?;
            install::apply(changes, &backup, &mut progress)?;
            Ok::<_, String>(count)
        })();
        progress(Progress {
            stage: "repair_reload",
            done: 1,
            total: 3,
        });
        *self.resources.borrow_mut() = None;
        *self.text_originals.borrow_mut() = None;
        let mut workspace = self.reopen().map_err(|error| match &numeric_repair {
            Ok((_, _, problems)) if !problems.is_empty() => {
                format!("{error}；数值修复未完成：{}", problems.join("；"))
            }
            Err(problem) => format!("{error}；{problem}"),
            _ => error,
        })?;
        let saved_warnings = workspace.draft_conflicts().cloned().collect::<Vec<_>>();
        let reconciled = self.repair_derived(&workspace);
        if reconciled.as_ref().is_ok_and(|count| *count > 0) {
            workspace = self.reopen()?;
        }
        progress(Progress {
            stage: "repair_check",
            done: 2,
            total: 3,
        });
        let mut report = self.baseline_check(&workspace);
        let mut problems = workspace.blocking_problems();
        problems.extend(
            report["problems"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_owned),
        );
        if let Err(error) = crate::extra_stratagem::derive(catalog, &workspace) {
            problems.push(error);
        }
        let mut actions = vec![
            "已重新读取游戏数据并重建参数索引".to_string(),
            "已刷新资源查询缓存，保留现有数值、预设和外观设置".to_string(),
        ];
        match unreadable_repair {
            Ok((restored, remaining)) => {
                if restored > 0 {
                    actions.push(format!("已备份损坏文件，并从当前版本的已校验备份或随附原版数据恢复 {restored} 个无法解析的数值文件"));
                }
                problems.extend(remaining);
            }
            Err(error) => problems.push(format!("损坏数值文件修复未完成：{error}")),
        }
        if crate::desktop_armor::needs_reapply(&workspace) {
            actions.push("已保留护甲配置并标记为待写入，请重新写入游戏以应用原有选择".into());
        }
        match numeric_repair {
            Ok((restored, detached, remaining)) => {
                if restored > 0 {
                    actions.push(format!(
                        "已从当前版本的已校验安装备份恢复 {restored} 个缺失数值文件"
                    ));
                }
                if detached > 0 {
                    actions.push(format!(
                        "已备份并清理 {detached} 项已恢复到安装前状态的过期登记"
                    ));
                }
                problems.extend(remaining);
            }
            Err(error) => problems.push(format!("数值安装登记修复未完成：{error}")),
        }
        if invalid_draft {
            actions.push("已完整备份损坏的编辑草稿并解除其启动阻塞".into());
        }
        if invalid_configuration {
            actions.push("已完整备份无法解析的本地安装配置并重新加载当前游戏参数；旧配置保留在 configuration-recovery 恢复副本中".into());
        }
        match recovery {
            Ok(0) => actions.push("未发现需要回滚的安装文件".into()),
            Ok(count) => actions.push(format!(
                "已恢复中断安装中的 {count} 个文件，恢复前内容已备份"
            )),
            Err(error) => problems.push(format!("安装事务恢复未完成：{error}")),
        }
        match reconciled {
            Ok(0) => actions.push("派生战备记录与当前文件一致".into()),
            Ok(count) => actions.push(format!(
                "已备份并解除 {count} 项失效派生记录，保留当前游戏文件"
            )),
            Err(error) => problems.push(format!("派生战备记录修复未完成：{error}")),
        }
        let warnings = report["warnings"].as_array_mut().unwrap();
        match residency_repair {
            Ok(0) => {}
            Ok(count) => {
                actions.push(format!(
                    "已备份并清理 {count} 个完全缺失的驻留槽位登记，必要的中间缺号已补齐"
                ));
                warnings.push(json!("缺失补丁原有的模型、特效或音效未恢复；需要这些资源时，请重新安装对应资源驻留。"));
            }
            Err(error) => problems.push(format!("驻留记录修复未完成：{error}")),
        }
        for warning in saved_warnings {
            let value = json!(warning);
            if !warnings.contains(&value) {
                warnings.push(value);
            }
        }
        problems.sort();
        problems.dedup();
        let ok = problems.is_empty();
        report["problems"] = json!(problems);
        report["issues"] = json!(problems
            .iter()
            .map(|problem| {
                let mut entry = crate::diagnostics::installation_advice(problem);
                entry["problem"] = json!(problem);
                entry
            })
            .collect::<Vec<_>>());
        report["actions"] = json!(actions);
        report["ok"] = json!(ok);
        report["message"] = json!(if ok {
            "自动修复完成"
        } else {
            "可自动处理的步骤已完成，仍有项目需要手动处理"
        });
        progress(Progress {
            stage: "repair_done",
            done: 3,
            total: 3,
        });
        Ok((workspace, report))
    }

    fn repair_unreadable_files(
        &self,
        dll: &[u8],
        progress: &mut impl FnMut(Progress),
    ) -> Result<(usize, Vec<String>), String> {
        let (_lock, _, backup) = self.begin()?;
        let mut changes = Vec::new();
        let mut problems = Vec::new();
        let owned = self.owned().map(|(_, owned)| owned).unwrap_or_default();
        for input in self.inputs["files"].as_array().ok_or("缺少数值文件清单")? {
            let name = input["name"].as_str().ok_or("数值文件名无效")?;
            if !valid_file(name) {
                return Err("数值文件名无效".into());
            }
            let path = self.root.join(name);
            let Some(before) = install::read(&path)? else {
                continue;
            };
            if crate::sealed::open_data(&before).is_ok() {
                continue;
            }
            if let Some(saved) = owned
                .get(name)
                .and_then(|item| self.verified_backup(name, item, true).ok())
                .map(|(_, saved)| saved)
                .filter(|saved| {
                    crate::sealed::open_data(saved)
                        .is_ok_and(|plain| hash::expected_by_game(&plain, dll))
                })
            {
                changes.push(Change {
                    path,
                    before: Some(before),
                    after: Some(saved),
                });
                continue;
            }
            let candidate = if input["embedded_armor"] == true {
                Some(crate::desktop_armor::BASELINE.to_vec())
            } else {
                input["baseline_path"]
                    .as_str()
                    .and_then(|path| fs::read(path).ok())
            };
            let baseline_name = input["baseline_name"]
                .as_str()
                .unwrap_or("generated_customization_passive_bonuses.dl_plain");
            let candidate = candidate.filter(|plain| {
                hash::expected_by_game(plain, dll)
                    && crate::baseline::Baseline::shipped(baseline_name, plain.clone()).is_ok()
            });
            let Some(plain) = candidate else {
                problems.push(format!("{name} 无法解析，且没有匹配当前版本的可信原版数据；已保留该文件，请通过 Steam 验证游戏文件完整性"));
                continue;
            };
            let after = crate::sealed::seal(&plain).map_err(|error| format!("{name}：{error}"))?;
            changes.push(Change {
                path,
                before: Some(before),
                after: Some(after),
            });
        }
        let count = changes.len();
        install::apply(changes, &backup, progress)?;
        Ok((count, problems))
    }

    fn repair_numeric_records(&self, dll: &[u8]) -> Result<(usize, usize, Vec<String>), String> {
        let (_lock, _, backup) = self.begin()?;
        let (disk, mut owned) = self.owned()?;
        let mut changes = Vec::new();
        let mut retired = Vec::new();
        let mut problems = Vec::new();
        let mut restored = 0;
        for (name, item) in &owned {
            if !valid_file(name) {
                return Err("安装记录含无效文件名".into());
            }
            let current = match install::read(&self.root.join(name)) {
                Ok(value) => value,
                Err(error) => {
                    problems.push(format!("{name}：{error}"));
                    continue;
                }
            };
            if current.as_deref().map(hash::sha256_hex).as_deref() == Some(item.installed.as_str())
            {
                continue;
            }
            let (_, saved) = match self.verified_backup(name, item, true) {
                Ok(value) => value,
                Err(error) => {
                    problems.push(error);
                    continue;
                }
            };
            if current.as_ref() == Some(&saved) {
                // An external restore already put back our exact pre-install
                // bytes. Retiring only the stale ledger cannot erase a Mod.
                retired.push(name.clone());
            } else if current.is_none() {
                if !crate::sealed::open_data(&saved)
                    .is_ok_and(|plain| hash::expected_by_game(&plain, dll))
                {
                    problems.push(format!("{name} 缺失，且备份与当前游戏版本不匹配，未恢复"));
                    continue;
                }
                changes.push(Change {
                    path: self.root.join(name),
                    before: None,
                    after: Some(saved),
                });
                restored += 1;
                retired.push(name.clone());
            } else {
                problems.push(format!("{name} 已被外部工具修改，自动修复保留该文件；请确认冲突后强制写入或先还原对应 Mod"));
            }
        }
        if !retired.is_empty() {
            if retired.iter().any(|name| {
                [crate::desktop_armor::PASSIVE, crate::desktop_armor::KITS].contains(&name.as_str())
            }) {
                let path = self.state.join("configuration.json");
                if let Some(before) = install::read(&path)? {
                    if before.len() > 8 * 1024 * 1024 {
                        return Err("已安装编辑器配置过大".into());
                    }
                    let mut config: Value =
                        serde_json::from_slice(&before).map_err(|_| "已安装编辑器配置无效")?;
                    if config.get("armor").is_some_and(Value::is_object) {
                        config[crate::desktop_armor::REAPPLY] = json!(true);
                        changes.push(Change {
                            path,
                            before: Some(before),
                            after: Some(
                                serde_json::to_vec(&config)
                                    .map_err(|_| "无法保存护甲待写入状态")?,
                            ),
                        });
                    }
                }
            }
            for name in &retired {
                owned.remove(name);
            }
            changes.push(Change {
                path: self.state.join("managed.json"),
                before: disk,
                after: Some(serde_json::to_vec(&owned).map_err(|_| "无法保存修复后的安装登记")?),
            });
            install::apply(changes, &backup, |_| {})?;
        }
        Ok((restored, retired.len(), problems))
    }

    fn repair_invalid_draft(&self) -> Result<bool, String> {
        self.repair_invalid_state("draft.json", Workspace::valid_draft)
    }

    fn repair_invalid_state(
        &self,
        name: &str,
        valid: impl Fn(&[u8]) -> bool,
    ) -> Result<bool, String> {
        let path = self.state.join(name);
        let Some(bytes) = install::read(&path)? else {
            return Ok(false);
        };
        if bytes.len() > 8 * 1024 * 1024 {
            return Err(format!("本地 {name} 过大，请导出诊断后手动检查"));
        }
        if valid(&bytes) {
            return Ok(false);
        }
        let (_lock, _, backup) = self.begin()?;
        let recovery = self.state.join(format!(
            "{}-recovery-{}.json",
            name.trim_end_matches(".json"),
            hash::sha256_hex(&bytes)
        ));
        let saved = install::read(&recovery)?;
        if saved.as_ref().is_some_and(|saved| saved != &bytes) {
            return Err("旧草稿恢复副本与原内容不一致，未覆盖".into());
        }
        let mut changes = vec![Change {
            path,
            before: Some(bytes.clone()),
            after: None,
        }];
        if saved.is_none() {
            changes.push(Change {
                path: recovery,
                before: None,
                after: Some(bytes),
            });
        }
        install::apply(changes, &backup, |_| {})?;
        Ok(true)
    }

    fn repair_derived(&self, workspace: &Workspace) -> Result<usize, String> {
        let (replacement, count) = crate::extra_stratagem::reconcile(workspace)?;
        if count == 0 {
            return Ok(0);
        }
        let (_lock, _, backup) = self.begin()?;
        let path = self.state.join("configuration.json");
        let before = install::read(&path)?.ok_or("派生记录来源配置缺失")?;
        let mut metadata: Value =
            serde_json::from_slice(&before).map_err(|_| "派生记录来源配置无效")?;
        let key = crate::extra_stratagem::GENERATED;
        if metadata[key] != workspace.loaded_metadata()[key] {
            return Err("其他编辑器已更改派生记录，请重新修复".into());
        }
        if replacement.is_null() {
            metadata
                .as_object_mut()
                .ok_or("派生记录来源配置无效")?
                .remove(key);
        } else {
            metadata[key] = replacement.clone();
        }
        let mut changes = vec![Change {
            path,
            before: Some(before),
            after: Some(serde_json::to_vec(&metadata).map_err(|_| "无法保存派生记录")?),
        }];
        if let Some(change) = workspace.draft_metadata_change(key, &replacement)? {
            changes.push(change);
        }
        install::apply(changes, &backup, |_| {})?;
        Ok(count)
    }

    pub(crate) fn needs_resource_changes(workspace: &Workspace) -> bool {
        !workspace.changed_resources().is_empty()
            || workspace.metadata()["ragdoll"] != workspace.loaded_metadata()["ragdoll"]
            || workspace.metadata()[crate::desktop_text::STATE]
                != workspace.loaded_metadata()[crate::desktop_text::STATE]
    }

    pub(crate) fn install_check(&self, workspace: &Workspace) -> Value {
        self.check(workspace, Self::needs_resource_changes(workspace), false)
    }

    fn check(&self, workspace: &Workspace, resources: bool, all_owned: bool) -> Value {
        let mut problems: BTreeSet<_> = if resources {
            workspace.resource_conflicts().cloned().collect()
        } else {
            BTreeSet::new()
        };
        let mut warnings: Vec<String> = workspace.draft_conflicts().cloned().collect();
        problems.extend(workspace.profile_conflicts().cloned());
        if !resources {
            warnings.extend(workspace.resource_conflicts().cloned());
        }
        let mut entries = Vec::new();
        match self.owned() {
            Ok((_, owned)) => {
                for (name, item) in owned {
                    if all_owned
                        || workspace.file_has_pending(&name)
                        || ([crate::desktop_armor::PASSIVE, crate::desktop_armor::KITS]
                            .contains(&name.as_str())
                            && (workspace.metadata()["armor"]
                                != workspace.loaded_metadata()["armor"]
                                || crate::desktop_armor::needs_reapply(workspace)))
                    {
                        if let Err(error) = self.verified_backup(&name, &item, false) {
                            if all_owned {
                                problems.insert(error);
                            } else {
                                warnings
                                    .push(format!("数值安装登记检查：{error}；建议先运行自动修复"));
                            }
                        }
                    }
                }
            }
            Err(error) => {
                problems.insert(error);
            }
        }
        match self.game_dll() {
            Ok(_) => entries.push(
                json!({"equipment":"游戏版本","parameter":"game.dll","after":"与当前参数目录一致"}),
            ),
            Err(error) => {
                problems.insert(error);
            }
        }
        for (name, status) in workspace.disk_checks() {
            match status {
                Ok(status) => {
                    entries.push(json!({"equipment":"数值文件","parameter":name,"after":status}))
                }
                Err(error) => {
                    problems.insert(format!("{name}：{error}"));
                }
            }
        }
        if resources {
            match self.data().and_then(|root| {
                crate::residency_install::audit(root, &self.state.join("residency.json"))
            }) {
                Ok(result) => problems.extend(result),
                Err(error) => {
                    problems.insert(error);
                }
            }
        }
        match self.interrupted() {
            Ok(transactions) if !transactions.is_empty() => {
                problems.insert("发现未完成的安装事务，请先恢复".into());
            }
            Err(error) => {
                problems.insert(error);
            }
            _ => {}
        }
        if !problems.is_empty() {
            warnings.push("请核对游戏更新、其他工具和已登记补丁。检查未写入任何文件。".into());
        }
        json!({"entries":entries,"problems":problems,"warnings":warnings})
    }

    fn owned(&self) -> Result<(Option<Vec<u8>>, BTreeMap<String, Owned>), String> {
        let disk = install::read(&self.state.join("managed.json"))?;
        let owned = disk
            .as_deref()
            .map(|bytes| {
                if bytes.len() > 1024 * 1024 {
                    return Err("安装记录过大");
                }
                serde_json::from_slice(bytes).map_err(|_| "安装记录格式无效")
            })
            .transpose()?
            .unwrap_or_default();
        Ok((disk, owned))
    }

    /// Returns the current disk bytes and the original backup for an owned file.
    ///
    /// `allow_current_change` is the forced path: the game file may have been
    /// replaced by another tool, so its bytes no longer match the install
    /// record and the backup is used to overwrite it. The backup itself is
    /// always verified against the record: without a trustworthy source a
    /// forced restore would write unknown data into the game.
    fn verified_backup(
        &self,
        name: &str,
        item: &Owned,
        allow_current_change: bool,
    ) -> Result<(Option<Vec<u8>>, Vec<u8>), String> {
        if !valid_file(name)
            || item.transaction.is_empty()
            || !item
                .transaction
                .bytes()
                .all(|c| c.is_ascii_digit() || c == b'-')
        {
            return Err("安装记录含无效文件或事务标识".into());
        }
        let source = self
            .state
            .join("transactions")
            .join(&item.transaction)
            .join(format!("{}.original", item.index));
        if !fs::symlink_metadata(&source).is_ok_and(|m| m.is_file()) {
            return Err(format!("{name} 的原始备份缺失"));
        }
        let saved = fs::read(source).map_err(|_| "无法读取安装备份")?;
        if hash::sha256_hex(&saved) != item.original {
            return Err(format!("{name} 的原始备份已变化，无法确认恢复内容"));
        }
        let current = install::read(&self.root.join(name))?;
        if current.as_deref().map(hash::sha256_hex).as_deref() != Some(item.installed.as_str())
            && !allow_current_change
        {
            return Err(format!("{name} 的文件已变化"));
        }
        Ok((current, saved))
    }

    fn interrupted(&self) -> Result<Vec<PathBuf>, String> {
        let root = self.state.join("transactions");
        if !root.exists() {
            return Ok(Vec::new());
        }
        let mut interrupted = Vec::new();
        for entry in fs::read_dir(root).map_err(|_| "无法查看安装事务目录")? {
            let path = entry.map_err(|_| "无法查看安装事务记录")?.path();
            if path.join("journal.json").is_file()
                && !install::committed(&path)?
                && !path.join("recovered").exists()
            {
                interrupted.push(path);
            }
        }
        interrupted.sort();
        Ok(interrupted)
    }

    pub(crate) fn recover(&self, mut progress: impl FnMut(Progress)) -> Result<usize, String> {
        require_closed()?;
        fs::create_dir_all(&self.state).map_err(|_| "无法创建安装备份目录")?;
        let _lock = install::lock_transaction(&self.state)?;
        let mut count = 0;
        for path in self.interrupted()? {
            let backup = self.state.join("recovery").join(save_stamp()?);
            fs::create_dir_all(backup.parent().unwrap()).map_err(|_| "无法创建恢复备份目录")?;
            count += install::recover_scoped(
                &path,
                &backup,
                &[self.data()?, &self.state],
                &mut progress,
            )?
            .changed;
            fs::File::options()
                .write(true)
                .create_new(true)
                .open(path.join("recovered"))
                .map_err(|_| "恢复成功，但无法记录完成状态")?;
        }
        Ok(count)
    }

    fn begin(&self) -> Result<(fs::File, String, PathBuf), String> {
        fs::create_dir_all(self.state.join("transactions")).map_err(|_| "无法创建安装备份目录")?;
        let lock = install::lock_transaction(&self.state)?;
        if !self.interrupted()?.is_empty() {
            return Err("发现未完成的安装事务，请先恢复".into());
        }
        let id = save_stamp()?;
        let path = self.state.join("transactions").join(&id);
        Ok((lock, id, path))
    }

    fn data(&self) -> Result<&Path, String> {
        self.root
            .parent()
            .ok_or_else(|| "找不到游戏资源目录".into())
    }
    pub(crate) fn resources(
        &self,
    ) -> Result<std::cell::RefMut<'_, Option<crate::resource_resolver::Resolver>>, String> {
        let mut cache = self.resources.borrow_mut();
        if cache.is_none() {
            *cache = Some(crate::resource_resolver::Resolver::new(
                crate::bundles::Bundles::open(self.data()?)?,
            ));
        }
        Ok(cache)
    }
    pub(crate) fn overrides(
        &self,
        name: &str,
    ) -> Result<crate::residency_install::Overrides, String> {
        crate::residency_install::read_overrides(
            self.data()?,
            &self.state.join("residency.json"),
            name,
        )
    }
    pub(crate) fn patch_edits(
        &self,
        edits: crate::residency_install::Edits,
    ) -> Result<usize, String> {
        require_closed()?;
        let (_lock, _, backup) = self.begin()?;
        self.game_dll()?;
        let changes = self.prepare_patch_edits(edits)?;
        require_closed()?;
        Ok(install::apply(changes, &backup, |p| {
            eprintln!(
                "@shodan-progress {}",
                json!({"stage":"正在写入资源补丁","done":p.done,"total":p.total})
            )
        })?
        .changed)
    }
    fn prepare_patch_edits(
        &self,
        edits: crate::residency_install::Edits,
    ) -> Result<Vec<Change>, String> {
        if edits.is_empty() {
            return Ok(vec![]);
        }
        let mut cache = self.resources()?;
        let bundles = &mut cache.as_mut().unwrap().bundles;
        crate::residency_install::prepare_edits(
            self.data()?,
            &self.state.join("residency.json"),
            edits,
            |name, mode, overrides, shared| {
                bundles.build_patch_shared(name, mode, overrides, shared)
            },
        )
    }

    pub(crate) fn residency_state(&self, group: &str) -> Result<bool, String> {
        crate::residency_install::installed(self.data()?, &self.state.join("residency.json"), group)
    }

    pub(crate) fn resource_report(
        &self,
        mut plan: crate::desktop_resources::Plan,
        group: &str,
        mode: Option<u32>,
    ) -> Result<Value, String> {
        let root = self.data()?;
        let ledger = self.state.join("residency.json");
        let progress = |stage, done, total| {
            eprintln!(
                "@shodan-progress {}",
                json!({"stage":stage,"done":done,"total":total})
            );
        };
        if mode == Some(3) {
            require_closed()?;
            let (_lock, _, backup) = self.begin()?;
            self.game_dll()?;
            let mut cache = self.resources()?;
            let bundles = &mut cache.as_mut().unwrap().bundles;
            let changes = crate::residency_install::prepare(
                root,
                &ledger,
                group,
                None,
                |name, mode, overrides, shared| {
                    bundles.build_patch_shared(name, mode, overrides, shared)
                },
            )?;
            install::apply(changes, &backup, |p| {
                progress("正在移除驻留补丁", p.done, p.total)
            })?;
            return Ok(json!("已移除该条目的资源驻留补丁，重启游戏后生效"));
        }
        if mode.is_some_and(|m| m != 1) {
            return Err("请选择完整驻留或移除补丁".into());
        }
        if mode.is_some() {
            require_closed()?;
            self.game_dll()?;
        }
        let mut cache = self.resources()?;
        let resolver = cache.as_mut().unwrap();
        let scan = |done, total| {
            if done % 32 == 0 {
                progress("正在核对资源与音效来源", done, total);
            }
        };
        if !plan.scan.is_empty() {
            plan.resources.extend(resolver.scan(&plan.scan, scan)?);
        }
        let (resolved, providers, _) =
            resolver.resolve(&plan.preferred, &plan.resources, &plan.events, scan)?;
        if mode.is_some() {
            if !resolved.missing_resources.is_empty() {
                return Err(format!(
                    "找不到必需资源，未安装：{}",
                    resolved
                        .missing_resources
                        .iter()
                        .take(12)
                        .map(|(typ, id)| format!("{typ:016x}:{id:016x}"))
                        .collect::<Vec<_>>()
                        .join("、")
                ));
            }
            let signature = hash::sha256_hex(
                &serde_json::to_vec(&(&resolved.packages, &plan.resources, &plan.events))
                    .map_err(|_| "无法生成资源方案标识")?,
            );
            let (_lock, _, backup) = self.begin()?;
            let total = resolved.packages.len();
            let mut done = 0;
            let changes = crate::residency_install::prepare(
                root,
                &ledger,
                group,
                Some((&signature, &resolved.packages)),
                |name, mode, overrides, shared| {
                    progress("正在生成驻留补丁", done, total);
                    done += 1;
                    resolver
                        .bundles
                        .build_patch_shared(name, mode, overrides, shared)
                },
            )?;
            require_closed()?;
            self.game_dll()?;
            install::apply(changes, &backup, |p| {
                progress("正在写入驻留补丁", p.done, p.total)
            })?;
            let missed = resolved
                .missing_events
                .iter()
                .map(u32::to_string)
                .collect::<Vec<_>>()
                .join("、");
            let audio = if missed.is_empty() {
                String::new()
            } else {
                format!("。未匹配音效事件 {missed}")
            };
            return Ok(json!(format!(
                "已为该条目登记 {total} 个驻留资源包，重启游戏后生效{audio}"
            )));
        }
        let mut entries = Vec::new();
        for (typ, id) in &plan.resources {
            let key = (*typ, *id);
            let names: Vec<_> = resolved
                .packages
                .iter()
                .filter(|n| providers[*n].resources.contains(&key))
                .collect();
            entries.push(json!({"kind":"资源","id":format!("{typ:016x}:{id:016x}"),"providers":names,"provider_names":names,"missing":names.is_empty()}));
        }
        for id in &plan.events {
            let names: Vec<_> = resolved
                .packages
                .iter()
                .filter(|n| providers[*n].events.contains(id))
                .collect();
            entries.push(json!({"kind":"音效事件","id":id,"providers":names,"provider_names":names,"missing":names.is_empty()}));
        }
        let packages: Vec<_> = resolved
            .packages
            .iter()
            .map(|id| json!({"id":id,"name":id,"declared":plan.preferred.contains(id)}))
            .collect();
        Ok(
            json!({"entries":entries,"packages":packages,"note":"音效事件按 Wwise 事件目录匹配，游戏内播放结果需要实机确认。"}),
        )
    }

    pub(crate) fn install(
        &self,
        catalog: &Catalog,
        workspace: &Workspace,
        allowed: &[Location],
        codes: &BTreeMap<u32, u32>,
        force: bool,
        mut progress: impl FnMut(Progress),
    ) -> Result<Value, String> {
        require_closed()?;
        if let Some(error) = workspace.profile_conflicts().next() {
            return Err(error.clone());
        }
        if Self::needs_resource_changes(workspace) {
            if let Some(error) = workspace.resource_conflicts().next() {
                return Err(error.clone());
            }
        }
        let (_lock, transaction, backup) = self.begin()?;
        let dll = self.game_dll()?;
        progress(Progress {
            stage: "prepare",
            done: 0,
            total: 0,
        });
        let (disk, mut owned) = self.owned()?;
        let armor_baseline = |name: &str| -> Result<Option<Vec<u8>>, String> {
            owned
                .get(name)
                .map(|record| {
                    let (_, saved) = self.verified_backup(name, record, force)?;
                    crate::sealed::open_data(&saved).map_err(|e| e.to_string())
                })
                .transpose()
        };
        let (armor, armor_metadata) = crate::desktop_armor::prepare(workspace, armor_baseline)?;
        let mut allowed = allowed.to_vec();
        allowed.retain(|location| !armor.contains_key(&location.file));
        let derived = crate::extra_stratagem::derive(catalog, workspace)?;
        let mut warnings = crate::extra_stratagem::current_warnings(catalog, workspace)?;
        warnings.extend(derived.warnings);
        let prepared = workspace.prepare_game_changes(&allowed, codes, &armor, &derived.words)?;
        let mut changes = Vec::new();
        let mut adjusted = Vec::new();
        for (name, prepared) in prepared {
            if !valid_file(&name) {
                return Err("安装目标文件名无效".into());
            }
            let before = workspace.checked_cipher(&name)?;
            let hash = prepared.target_hash.to_le_bytes();
            if !dll.windows(hash.len()).any(|window| window == hash) {
                return Err(format!("{name} 与当前游戏版本的文件哈希不匹配"));
            }
            let before_digest = crate::hash::sha256_hex(&before);
            let after_digest = crate::hash::sha256_hex(&prepared.ciphertext);
            if let Some(item) = owned
                .get(&name)
                .filter(|item| item.installed == before_digest)
            {
                // Do not continue overwriting an owned file whose restore
                // source has been removed or tampered with.
                self.verified_backup(&name, item, false)?;
            }
            if let Some(item) = owned.get_mut(&name) {
                if item.installed != before_digest {
                    if !force {
                        return Err(format!("{name} 已被其他工具修改，已停止写入"));
                    }
                    // The transaction backs up the actual disk bytes. Restore
                    // after a forced takeover must return to that external state.
                    item.transaction = transaction.clone();
                    item.index = changes.len();
                    item.original = before_digest;
                    warnings.push(format!(
                        "{name} 已强制接管旧安装记录；恢复将回到本次写入前的文件"
                    ));
                }
                item.installed = after_digest;
            } else {
                owned.insert(
                    name.clone(),
                    Owned {
                        transaction: transaction.clone(),
                        index: changes.len(),
                        original: before_digest,
                        installed: after_digest,
                    },
                );
            }
            if let Some((offset, before, after)) = prepared.correction.adjusted_float {
                adjusted.push(json!({"file":name,"offset":offset,"before":before,"after":after}));
            }
            changes.push(Change {
                path: self.root.join(&name),
                before: Some(before),
                after: Some(prepared.ciphertext),
            });
        }
        let count = changes.len();
        let mut edits = crate::desktop_text::prepare(
            self,
            catalog,
            &workspace.metadata()[crate::desktop_text::STATE],
            &workspace.loaded_metadata()[crate::desktop_text::STATE],
        )?;
        if workspace.metadata()["ragdoll"].as_bool().is_some() {
            let (_, pending) = crate::desktop_resource_edits::ragdoll(
                self,
                workspace.metadata()["ragdoll"].as_bool(),
            )?;
            for (package, resources) in pending {
                edits.entry(package).or_default().extend(resources);
            }
        }
        for name in workspace.changed_resources() {
            let source = self.archive.get(name).ok_or("缺少独立资源的来源包")?;
            let key = archive_identity(name)?;
            let current = workspace.snapshot(name)?;
            let base = workspace
                .original_snapshot(name)
                .ok_or("独立资源缺少已校验原始内容")?;
            let held = self.overrides(&source.package)?;
            if held.get(&key).map_or(base, Vec::as_slice) != current {
                return Err(format!("独立资源 {name} 已由其他工具修改"));
            }
            let replacement = workspace.rendered(name)?;
            edits
                .entry(source.package.clone())
                .or_default()
                .insert(key, (replacement != base).then_some(replacement));
        }
        let resource_count: usize = edits.values().map(BTreeMap::len).sum();
        changes.extend(self.prepare_patch_edits(edits)?);
        let mut configuration = workspace.metadata().clone();
        if let Some(config) = configuration.as_object_mut() {
            config.remove(crate::desktop_armor::REAPPLY);
        }
        if !derived.metadata.is_null() {
            configuration[crate::extra_stratagem::GENERATED] = derived.metadata;
        } else if let Some(config) = configuration.as_object_mut() {
            config.remove(crate::extra_stratagem::GENERATED);
        }
        if let Some(armor_metadata) = armor_metadata {
            configuration["armor"] = armor_metadata;
        }
        if let Some(virtuals) = configuration
            .get_mut("virtual")
            .and_then(Value::as_object_mut)
        {
            for f in catalog.fields.iter().filter(|f| f.stratagem_code.is_some()) {
                virtuals.remove(&f.key);
            }
        }
        let changed_configuration = &configuration != workspace.loaded_metadata();
        if changed_configuration {
            let path = self.state.join("configuration.json");
            changes.push(Change {
                before: install::read(&path)?,
                path,
                after: Some(serde_json::to_vec(&configuration).map_err(|_| "无法保存编辑器配置")?),
            });
        }
        if count > 0 || resource_count > 0 || changed_configuration {
            if let Some(recovery) = workspace.draft_recovery()? {
                changes.push(recovery);
            }
            if let Some(draft) = workspace.finish_draft() {
                changes.push(draft);
            }
            changes.push(Change {
                path: self.state.join("managed.json"),
                before: disk,
                after: Some(serde_json::to_vec(&owned).map_err(|_| "无法记录安装状态")?),
            });
            require_closed()?;
            install::apply(changes, &backup, progress)?;
        }
        Ok(
            json!({"ok":true,"files":count,"resources":resource_count,"adjusted":adjusted,"warnings":warnings,
            "message":format!("已写入 {count} 个数值文件、{resource_count} 个独立资源")}),
        )
    }

    pub(crate) fn restore(
        &self,
        catalog: &Catalog,
        workspace: &Workspace,
        force: bool,
        progress: impl FnMut(Progress),
    ) -> Result<Value, String> {
        require_closed()?;
        if let Some(error) = workspace.resource_conflicts().next() {
            return Err(error.clone());
        }
        let (_lock, _, backup) = self.begin()?;
        self.game_dll()?;
        let (disk, owned) = self.owned()?;
        let mut changes = Vec::new();
        let mut restored = BTreeMap::new();
        let mut warnings = Vec::new();
        for (name, item) in &owned {
            let (current, saved) = self.verified_backup(name, item, force)?;
            if force
                && current.as_deref().map(hash::sha256_hex).as_deref()
                    != Some(item.installed.as_str())
            {
                warnings.push(format!("{name} 已被其他工具修改，已强制恢复为备份内容"));
            }
            restored.insert(
                name.clone(),
                crate::workspace::RestoredFile {
                    bytes: crate::sealed::open_data(&saved).map_err(|e| e.to_string())?,
                    source: hash::sha256_hex(&saved),
                },
            );
            changes.push(Change {
                path: self.root.join(name),
                before: current,
                after: Some(saved),
            });
        }
        let count = changes.len();
        let configuration = workspace.loaded_metadata();
        let mut edits = crate::desktop_text::prepare(
            self,
            catalog,
            &Value::Null,
            &configuration[crate::desktop_text::STATE],
        )?;
        let mut packages = BTreeMap::new();
        if configuration["ragdoll"].as_bool().is_some() {
            let (_, pending) = crate::desktop_resource_edits::ragdoll(self, Some(false))?;
            for (package, resources) in pending {
                edits.entry(package).or_default().extend(resources);
            }
        }
        for (name, source) in &self.archive {
            if !packages.contains_key(&source.package) {
                packages.insert(source.package.clone(), self.overrides(&source.package)?);
            }
            let identity = archive_identity(name)?;
            if packages[&source.package].contains_key(&identity) {
                let base = workspace
                    .original_snapshot(name)
                    .ok_or("无法取得独立资源的原始内容")?;
                restored.insert(
                    name.clone(),
                    crate::workspace::RestoredFile {
                        bytes: base.to_vec(),
                        source: hash::sha256_hex(base),
                    },
                );
                edits
                    .entry(source.package.clone())
                    .or_default()
                    .insert(identity, None);
            }
        }
        let resources = edits.values().map(BTreeMap::len).sum::<usize>();
        if count > 0 || resources > 0 || !configuration.is_null() {
            if let Some(recovery) = workspace.draft_recovery()? {
                changes.push(recovery);
            }
            if let Some(draft) =
                workspace.restored_draft(catalog, &restored, workspace.metadata().clone())?
            {
                changes.push(draft);
            }
            changes.extend(self.prepare_patch_edits(edits)?);
            changes.push(Change {
                path: self.state.join("managed.json"),
                before: disk,
                after: None,
            });
            let path = self.state.join("configuration.json");
            if let Some(before) = install::read(&path)? {
                changes.push(Change {
                    path,
                    before: Some(before),
                    after: None,
                });
            }
            require_closed()?;
            install::apply(changes, &backup, progress)?;
        }
        Ok(
            json!({"ok":true,"files":count,"resources":resources,"warnings":warnings,
            "forced":force && !warnings.is_empty(),
            "message":format!("已恢复 {count} 个数值文件、{resources} 个独立资源")}),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NAME: &str = "generated_test_settings.dl_bin";

    #[test]
    fn invalid_numeric_files_are_isolated_and_repair_requires_pinned_current_build_data() {
        let root = scratch("invalid-numeric");
        let name = crate::desktop_armor::PASSIVE;
        let original = crate::desktop_armor::BASELINE;
        let broken = crate::sealed::seal(b"LDLD\x01\0\0\0broken-table").unwrap();
        fs::write(root.join(name), &broken).unwrap();
        fs::write(root.join(NAME), crate::sealed::seal(original).unwrap()).unwrap();
        let mut game = game_at(&root);
        game.inputs = json!({"isolate_invalid_files":true,"files":[
            {"name":name,"path":root.join(name),"sealed":true,"embedded_armor":true},
            {"name":NAME,"path":root.join(NAME),"sealed":true}
        ]});
        let workspace = crate::workspace_api::open(&game.inputs).unwrap();
        assert!(workspace.contains(NAME));
        assert!(!workspace.contains(name));
        assert!(workspace
            .blocking_problems()
            .iter()
            .any(|p| p.contains(name)));
        let mut strict = game.inputs.clone();
        strict["isolate_invalid_files"] = json!(false);
        let error = crate::workspace_api::open(&strict).err().unwrap();
        assert!(error.contains(name) && error.contains("LDLD"));
        assert_eq!(fs::read(root.join(name)).unwrap(), broken);

        let (restored, problems) = game
            .repair_unreadable_files(b"wrong-build", &mut |_| {})
            .unwrap();
        assert_eq!(restored, 0);
        assert_eq!(problems.len(), 1);
        assert_eq!(fs::read(root.join(name)).unwrap(), broken);
        let dll = hash::murmur64(original).to_le_bytes();
        let (restored, problems) = game.repair_unreadable_files(&dll, &mut |_| {}).unwrap();
        assert_eq!(restored, 1);
        assert!(problems.is_empty());
        assert_eq!(
            crate::sealed::open_data(&fs::read(root.join(name)).unwrap()).unwrap(),
            original
        );
        let originals = fs::read_dir(root.join("state/transactions"))
            .unwrap()
            .filter_map(Result::ok)
            .filter_map(|entry| fs::read(entry.path().join("0.original")).ok())
            .collect::<Vec<_>>();
        assert!(originals.contains(&broken));
        assert!(crate::workspace_api::open(&game.inputs)
            .unwrap()
            .blocking_problems()
            .is_empty());
        let intact = fs::read(root.join(name)).unwrap();
        assert_eq!(
            game.repair_unreadable_files(&dll, &mut |_| {}).unwrap().0,
            0
        );
        assert_eq!(fs::read(root.join(name)).unwrap(), intact);

        // An unpinned table cannot be fabricated from another file's baseline.
        fs::write(root.join(NAME), &broken).unwrap();
        let (restored, problems) = game.repair_unreadable_files(&dll, &mut |_| {}).unwrap();
        assert_eq!(restored, 0);
        assert!(problems[0].contains(NAME));
        assert_eq!(fs::read(root.join(NAME)).unwrap(), broken);
        let saved = crate::sealed::seal(original).unwrap();
        let item = owned(&root, &saved, b"old-installed-data");
        fs::write(
            root.join("state/managed.json"),
            serde_json::to_vec(&BTreeMap::from([(NAME, item)])).unwrap(),
        )
        .unwrap();
        let (restored, problems) = game.repair_unreadable_files(&dll, &mut |_| {}).unwrap();
        assert_eq!(restored, 1);
        assert!(problems.is_empty());
        assert_eq!(fs::read(root.join(NAME)).unwrap(), saved);
        let _ = fs::remove_dir_all(root);
    }

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "shodan-game-workspace-{}-{name}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("state")).unwrap();
        dir
    }

    fn game_at(root: &Path) -> Game {
        Game {
            root: root.to_path_buf(),
            state: root.join("state"),
            inputs: json!({}),
            build: String::new(),
            resources: Default::default(),
            archive: BTreeMap::new(),
            text_originals: Default::default(),
            migration_notes: Vec::new(),
        }
    }

    fn owned(root: &Path, saved: &[u8], installed: &[u8]) -> Owned {
        let transaction = "0-1".to_string();
        let dir = root.join("state/transactions").join(&transaction);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("0.original"), saved).unwrap();
        Owned {
            transaction,
            index: 0,
            original: hash::sha256_hex(saved),
            installed: hash::sha256_hex(installed),
        }
    }

    #[test]
    fn changed_game_file_needs_forced_restore() {
        let root = scratch("force-file");
        let saved = b"saved-backup".to_vec();
        let item = owned(&root, &saved, b"installed-bytes");
        fs::write(root.join(NAME), b"changed-by-another-tool").unwrap();
        let game = game_at(&root);
        assert_eq!(
            game.verified_backup(NAME, &item, false).unwrap_err(),
            format!("{NAME} 的文件已变化")
        );
        let (current, backup) = game.verified_backup(NAME, &item, true).unwrap();
        assert_eq!(
            current.as_deref(),
            Some(b"changed-by-another-tool".as_slice())
        );
        assert_eq!(backup, saved);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn changed_backup_is_never_forced() {
        let root = scratch("force-backup");
        let saved = b"saved-backup".to_vec();
        let item = owned(&root, &saved, b"installed-bytes");
        fs::write(root.join(NAME), b"installed-bytes").unwrap();
        fs::write(
            root.join("state/transactions/0-1/0.original"),
            b"tampered-backup",
        )
        .unwrap();
        let game = game_at(&root);
        assert_eq!(
            game.verified_backup(NAME, &item, true).unwrap_err(),
            format!("{NAME} 的原始备份已变化，无法确认恢复内容")
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn numeric_repair_restores_only_verified_missing_files_and_retires_restored_records() {
        let root = scratch("repair-numeric");
        let plain = include_bytes!("../data/armor-baseline.bin");
        let saved = crate::sealed::seal(plain).unwrap();
        let item = owned(&root, &saved, b"installed");
        let game = game_at(&root);
        let ledger = BTreeMap::from([(NAME.to_owned(), item.clone())]);
        let store = || {
            fs::write(
                game.state.join("managed.json"),
                serde_json::to_vec(&ledger).unwrap(),
            )
            .unwrap()
        };
        store();
        let dll = hash::murmur64(plain).to_le_bytes();
        let (restored, detached, problems) = game.repair_numeric_records(&dll).unwrap();
        assert_eq!((restored, detached), (1, 1));
        assert!(problems.is_empty());
        assert_eq!(fs::read(root.join(NAME)).unwrap(), saved);
        assert!(game.owned().unwrap().1.is_empty());
        store();
        let (restored, detached, problems) = game.repair_numeric_records(&dll).unwrap();
        assert_eq!((restored, detached), (0, 1));
        assert!(problems.is_empty());
        store();
        fs::write(root.join(NAME), b"foreign-mod").unwrap();
        let (restored, detached, problems) = game.repair_numeric_records(&dll).unwrap();
        assert_eq!((restored, detached), (0, 0));
        assert_eq!(problems.len(), 1);
        assert_eq!(fs::read(root.join(NAME)).unwrap(), b"foreign-mod");
        assert_eq!(game.owned().unwrap().1.len(), 1);
        fs::remove_file(root.join(NAME)).unwrap();
        let (restored, detached, problems) = game.repair_numeric_records(b"wrong-version").unwrap();
        assert_eq!((restored, detached), (0, 0));
        assert!(problems[0].contains("版本"));
        assert!(!root.join(NAME).exists());
        fs::write(root.join("state/transactions/0-1/0.original"), b"damaged").unwrap();
        let (_, _, problems) = game.repair_numeric_records(&dll).unwrap();
        assert!(problems[0].contains("备份"));
        assert!(!root.join(NAME).exists());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn forced_restore_recreates_a_missing_game_file() {
        let root = scratch("force-missing");
        let saved = b"saved-backup".to_vec();
        let item = owned(&root, &saved, b"installed-bytes");
        let game = game_at(&root);
        assert!(game.verified_backup(NAME, &item, false).is_err());
        let (current, backup) = game.verified_backup(NAME, &item, true).unwrap();
        assert!(current.is_none());
        assert_eq!(backup, saved);
        install::apply(
            vec![Change {
                path: root.join(NAME),
                before: current,
                after: Some(backup),
            }],
            &root.join("recreate-transaction"),
            |_| {},
        )
        .unwrap();
        assert_eq!(fs::read(root.join(NAME)).unwrap(), saved);
        fs::remove_file(root.join(NAME)).unwrap();
        fs::create_dir(root.join(NAME)).unwrap();
        assert!(
            game.verified_backup(NAME, &item, true).is_err(),
            "不可读取的目标不能作为缺失文件强制覆盖"
        );
        let _ = fs::remove_dir_all(root);
    }
}

pub(crate) fn changed_floats(catalog: &Catalog, workspace: &Workspace) -> Vec<Location> {
    let mut fields = Vec::new();
    let mut seen = BTreeSet::new();
    for binding in catalog
        .bindings
        .iter()
        .flatten()
        .filter(|b| matches!(b.encoding, Encoding::F32))
    {
        for location in &binding.locations {
            let key = (
                location.file.as_str(),
                location.typ,
                &location.record,
                location.relative,
            );
            if valid_file(&location.file)
                && seen.insert(key)
                && workspace
                    .value(location, &Encoding::F32)
                    .is_ok_and(|v| v.current != v.loaded)
            {
                fields.push(location.clone());
            }
        }
    }
    let edited_files = fields
        .iter()
        .map(|loc| loc.file.clone())
        .collect::<BTreeSet<_>>();
    for binding in catalog
        .bindings
        .iter()
        .flatten()
        .filter(|b| matches!(b.encoding, Encoding::F32))
    {
        for loc in &binding.locations {
            if loc.typ == 0xBD4042C2
                && loc.relative == 32
                && !edited_files.contains(&loc.file)
                && !fields.iter().any(|entry| entry.file == loc.file)
                && workspace.file_has_pending(&loc.file)
                && workspace.snapshot(&loc.file).is_ok_and(|bytes| {
                    crate::dlbin::index(bytes).is_ok_and(|blocks| blocks.len() == 1)
                })
                && workspace.value(loc, &Encoding::F32).is_ok_and(|v| {
                    v.current.is_finite() && v.current > 0.0 && v.current < f32::MAX as f64
                })
            {
                fields.push(loc.clone());
            }
        }
    }
    fields
}
