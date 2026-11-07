//! Line-delimited JSON transport for the Rust-only editing engine.
//! Explicit game installation is isolated from the generic editing endpoints.
use crate::{
    baseline::Baseline,
    session::{Field, Session},
    tables::{Key, Layout},
    Kind,
};
use serde_json::{json, Value};
use std::{
    fs,
    io::{BufRead, Write},
    path::PathBuf,
};

#[derive(Default)]
pub struct Api {
    active: Option<(Session, PathBuf)>,
    parameters: crate::parameters::Parameters,
    armor: Option<crate::armor_session::Session>,
    workspace: Option<crate::workspace::Workspace>,
    catalog: Option<crate::catalog::Catalog>,
    game: Option<crate::game_workspace::Game>,
    last_open: Option<(PathBuf, PathBuf)>,
    desktop: crate::desktop::Desktop,
    update_job: Option<std::thread::JoinHandle<Result<Value, String>>>,
    resolver: Option<(
        PathBuf,
        u64,
        std::time::SystemTime,
        crate::resource_resolver::Resolver,
    )>,
}
fn identity(v: &Value) -> Result<crate::dependencies::Identity, String> {
    let hex =
        |key| u64::from_str_radix(text(v, key)?, 16).map_err(|_| format!("无效资源身份：{key}"));
    Ok((hex("type")?, hex("id")?))
}
fn identities(
    v: &Value,
) -> Result<std::collections::BTreeSet<crate::dependencies::Identity>, String> {
    v.as_array()
        .ok_or("资源清单无效")?
        .iter()
        .map(identity)
        .collect()
}
fn identity_json((typ, id): crate::dependencies::Identity) -> Value {
    json!({"type":format!("{typ:016x}"),"id":format!("{id:016x}")})
}
fn number(v: &Value, key: &str) -> Result<usize, String> {
    usize::try_from(
        v[key]
            .as_u64()
            .ok_or_else(|| format!("缺少有效整数：{key}"))?,
    )
    .map_err(|_| "整数超出平台范围".into())
}
fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str, String> {
    v[key].as_str().ok_or_else(|| format!("缺少文本：{key}"))
}
fn record(v: &Value) -> Result<Key, String> {
    let record = text(v, "record")?;
    let record = if let Some(id) = record.strip_prefix("id:") {
        Key::Id(id.parse().map_err(|_| "记录 ID 无效")?)
    } else if let Some(hash) = record.strip_prefix("hash:") {
        Key::Hash(u64::from_str_radix(hash, 16).map_err(|_| "记录哈希无效")?)
    } else {
        return Err("记录必须使用 id: 或 hash: 前缀".into());
    };
    Ok(record)
}
fn field(v: &Value) -> Result<Field, String> {
    let record = record(v)?;
    let kind = match text(v, "kind")? {
        "f32" => Kind::F32,
        "u32" => Kind::U32,
        "i32" => Kind::I32,
        _ => return Err("不支持的字段类型".into()),
    };
    Ok(Field {
        block: number(v, "block")?,
        record,
        relative: number(v, "relative")?,
        kind,
    })
}
impl Api {
    pub fn invoke(&mut self, request: &Value) -> Result<Value, String> {
        self.invoke_with_game_writes(request, true)
    }
    pub(crate) fn invoke_mcp(&mut self, request: &Value) -> Result<Value, String> {
        self.invoke_with_game_writes(request, false)
    }
    fn invoke_with_game_writes(
        &mut self,
        request: &Value,
        game_writes: bool,
    ) -> Result<Value, String> {
        let method = text(request, "method")?;
        let p = &request["params"];
        if method == "desktop-call" {
            return self.desktop_call(
                text(p, "name")?,
                p["args"].as_array().map(Vec::as_slice).unwrap_or(&[]),
                game_writes,
            );
        }
        if method == "game-open" {
            let runtime = p["runtime"]
                .as_str()
                .map(PathBuf::from)
                .or_else(|| {
                    std::env::current_exe()
                        .ok()?
                        .parent()
                        .map(std::path::Path::to_path_buf)
                })
                .ok_or("无法定位程序目录")?;
            let profile = crate::game_workspace::profile();
            let root = crate::game_workspace::find_game(
                p["game"].as_str().map(std::path::Path::new),
                &runtime,
                &profile,
            )?;
            let bytes =
                fs::read(runtime.join("catalog.json.gz")).map_err(|_| "缺少原生参数目录")?;
            let catalog = crate::catalog::Catalog::from_gzip(&bytes)?;
            self.last_open = Some((runtime.clone(), root.clone()));
            let (game, workspace) =
                crate::game_workspace::Game::open(&catalog, root, &runtime, &profile)?;
            let info = json!({"game":game.root,"problems":workspace.problems(),
                "migration_notes":game.migration_notes,"catalog":catalog.info()});
            self.catalog = Some(catalog);
            self.workspace = Some(workspace);
            self.game = Some(game);
            self.desktop = Default::default();
            return Ok(info);
        }
        if method == "game-repair" {
            if !game_writes {
                return Err("请从桌面设置启动自动修复".into());
            }
            if self.game.is_none() {
                let runtime = self
                    .last_open
                    .as_ref()
                    .map(|(runtime, _)| runtime.clone())
                    .or_else(|| p["runtime"].as_str().map(PathBuf::from))
                    .ok_or("无法定位程序目录")?;
                let profile = crate::game_workspace::profile();
                let root = crate::game_workspace::find_game(
                    self.last_open.as_ref().map(|(_, root)| root.as_path()),
                    &runtime,
                    &profile,
                )?;
                let bytes = fs::read(runtime.join("catalog.json.gz"))
                    .map_err(|_| "缺少原生参数目录，请重新下载完整程序包")?;
                let catalog = crate::catalog::Catalog::from_gzip(&bytes)?;
                let game = crate::game_workspace::Game::load(&catalog, root, &runtime, &profile)?;
                self.catalog = Some(catalog);
                self.game = Some(game);
            }
            let game = self.game.as_ref().unwrap();
            let catalog = self.catalog.as_ref().ok_or("原生参数目录未载入")?;
            let (workspace, report) = game.repair(catalog, |event| {
                let stage = match event.stage {
                    "repair_recover" => "正在检查并恢复中断安装",
                    "repair_reload" => "正在重新读取游戏数据和草稿",
                    "repair_check" => "正在复查资源补丁和参数索引",
                    "repair_done" => "自动修复检查完成",
                    "backup" => "正在备份恢复前的文件",
                    "commit" => "正在恢复中断安装的文件",
                    "rollback" => "正在回滚恢复操作",
                    _ => "正在处理恢复事务",
                };
                eprintln!(
                    "@shodan-progress {}",
                    json!({"stage":stage,"done":event.done,"total":event.total})
                );
            })?;
            self.workspace = Some(workspace);
            self.desktop = Default::default();
            self.resolver = None;
            return Ok(report);
        }
        if matches!(method, "game-install" | "game-restore" | "game-recover") {
            let game = self.game.as_ref().ok_or("请先打开游戏工作区")?;
            let progress = |event: crate::install::Progress| {
                let stage = match event.stage {
                    "prepare" => "正在准备并封装数值",
                    "backup" => "正在创建备份",
                    "commit" => "正在写入游戏文件",
                    "rollback" => "正在回滚",
                    _ => "写入完成",
                };
                eprintln!(
                    "@shodan-progress {}",
                    json!({"stage":stage,"done":event.done,"total":event.total})
                );
            };
            let report = match method {
                "game-install" => {
                    let workspace = self.workspace.as_ref().ok_or("请先打开游戏工作区")?;
                    let catalog = self.catalog.as_ref().ok_or("原生参数目录未载入")?;
                    let allowed = if p["allow_float_adjustment"] == true {
                        crate::game_workspace::changed_floats(catalog, workspace)
                    } else {
                        Vec::new()
                    };
                    let (codes, _) = catalog.code_overrides(workspace, workspace.metadata())?;
                    let force = p["force"] == true;
                    if force && !game_writes {
                        return Err("强制写入需要在桌面确认".into());
                    }
                    game.install(catalog, workspace, &allowed, &codes, force, progress)?
                }
                "game-restore" => {
                    let force = p["force"] == true;
                    if force && !game_writes {
                        return Err("强制恢复需要在桌面确认".into());
                    }
                    game.restore(
                        self.catalog.as_ref().ok_or("原生参数目录未载入")?,
                        self.workspace.as_ref().ok_or("请先打开游戏工作区")?,
                        force,
                        progress,
                    )?
                }
                _ => {
                    let files = game.recover(progress)?;
                    json!({"ok":true,"files":files,"message":"中断事务已恢复"})
                }
            };
            self.workspace = Some(game.reopen()?);
            return Ok(report);
        }
        if method == "catalog-load" {
            if self.game.is_some() {
                return Err("桌面会话已载入与游戏版本绑定的参数目录".into());
            }
            let path = std::path::Path::new(text(p, "path")?);
            if fs::metadata(path)
                .map_err(|_| "无法读取原生参数目录")?
                .len()
                > 16 * 1024 * 1024
            {
                return Err("参数目录压缩文件过大".into());
            }
            let bytes = fs::read(path).map_err(|_| "无法读取原生参数目录")?;
            let catalog = crate::catalog::Catalog::from_gzip(&bytes)?;
            let info = catalog.info();
            self.catalog = Some(catalog);
            return Ok(info);
        }
        if method.starts_with("catalog-") {
            let catalog = self.catalog.as_ref().ok_or("请先载入原生参数目录")?;
            return match method {
                "catalog-info" => Ok(catalog.info()),
                "catalog-set" | "catalog-restore" | "catalog-edit-preview" => {
                    let workspace = self.workspace.as_mut().ok_or("请先打开原生工作区")?;
                    let value = if method == "catalog-restore" {
                        None
                    } else {
                        Some(p["value"].as_f64().ok_or("缺少有效参数数值")?)
                    };
                    let plan = crate::catalog_edit::prepare(
                        catalog,
                        workspace,
                        text(p, "owner")?,
                        text(p, "key")?,
                        value,
                    )?;
                    let mut warnings =
                        crate::extra_stratagem::validate(catalog, workspace, &plan.values)?;
                    warnings.extend(catalog.code_overrides(workspace, &plan.metadata)?.1);
                    if method == "catalog-edit-preview" {
                        workspace.validate_batch(&plan.values)?;
                    } else {
                        workspace.set_batch(&plan.values, Some(plan.metadata))?;
                    }
                    Ok(
                        json!({"changes":plan.changes,"warnings":warnings,"applied":method!="catalog-edit-preview","installed":false}),
                    )
                }
                "catalog-items" => {
                    Ok(catalog.items(p["tab"].as_str(), p["query"].as_str().unwrap_or("")))
                }
                "catalog-preset-preview" | "catalog-preset-apply" => {
                    let workspace = self.workspace.as_mut().ok_or("请先打开原生工作区")?;
                    let preset = crate::preset::Preset::decode(text(p, "text")?)?;
                    let (plan, mut warnings) = crate::catalog_preset::prepare(
                        catalog,
                        workspace,
                        &preset,
                        p["skip_missing"].as_bool().unwrap_or(false),
                        p["replace_pending"].as_bool().unwrap_or(false),
                    )?;
                    let extra_warnings =
                        crate::extra_stratagem::validate(catalog, workspace, &plan.values)?;
                    warnings.extend(catalog.code_overrides(workspace, &plan.metadata)?.1);
                    let applied = method == "catalog-preset-apply";
                    if applied {
                        if !extra_warnings.is_empty()
                            && p["accept_warnings"].as_bool() != Some(true)
                        {
                            return Err("预设含重复附赠战备，请先预览并确认是否继续".into());
                        }
                        workspace.set_batch(&plan.values, Some(plan.metadata))?;
                    }
                    warnings.extend(extra_warnings);
                    Ok(
                        json!({"name":preset.name,"kind":preset.kind,"changes":plan.changes,
                        "warnings":warnings,"applied":applied,"installed":false}),
                    )
                }
                "catalog-preset-export" => {
                    let preset = crate::preset::Preset {
                        kind: text(p, "kind")?.into(),
                        name: text(p, "name")?.into(),
                        weapon: p["owner"].as_str().map(str::to_ascii_uppercase),
                        editor: p["editor"].as_str().map(str::to_owned),
                        armor: None,
                        description: None,
                        texts: Default::default(),
                        values: Vec::new(),
                    };
                    preset.encode()?;
                    let workspace = self.workspace.as_ref().ok_or("请先打开原生工作区")?;
                    Ok(json!({"text":crate::catalog_preset::export(catalog, workspace, preset)?}))
                }
                "catalog-reference-choices" | "catalog-reference-detail" | "catalog-shared" => {
                    let (_, owner) = catalog.owner(text(p, "owner")?)?;
                    let key = text(p, "key")?;
                    let row = owner
                        .rows
                        .iter()
                        .find(|r| r.key == key)
                        .ok_or("找不到参数")?;
                    if method == "catalog-shared" {
                        return Ok(catalog.shared(owner, row));
                    }
                    let workspace = self.workspace.as_ref().ok_or("请先打开原生工作区")?;
                    if method == "catalog-reference-detail" {
                        let value = catalog.row_value(
                            owner,
                            row,
                            workspace,
                            crate::catalog::Mode::Current,
                        )?;
                        let reference = crate::catalog_refs::row_link(catalog, row, value);
                        let rows = reference
                            .as_ref()
                            .and_then(|r| r["owner"].as_str())
                            .map(|owner| catalog.read_rows(owner, workspace))
                            .transpose()?;
                        return Ok(json!({"reference":reference,"rows":rows}));
                    }
                    if row.choice == "stratagem" {
                        return crate::extra_stratagem::choices(catalog, workspace, row);
                    }
                    crate::catalog_refs::choices(catalog, workspace, row)
                }
                "catalog-references" => crate::catalog_refs::graph(
                    catalog,
                    self.workspace.as_ref().ok_or("请先打开原生工作区")?,
                    catalog.owner(text(p, "owner")?)?.1,
                ),
                "catalog-describe" => Ok(json!(catalog.owner(text(p, "owner")?)?.1)),
                "catalog-read-rows" => catalog.read_rows(
                    text(p, "owner")?,
                    self.workspace.as_ref().ok_or("请先打开原生工作区")?,
                ),
                "catalog-read-fields" => catalog.read_fields(
                    &p["indices"],
                    self.workspace.as_ref().ok_or("请先打开原生工作区")?,
                ),
                "catalog-row-values" => catalog.row_values(
                    &p["owners"],
                    self.workspace.as_ref().ok_or("请先打开原生工作区")?,
                ),
                "catalog-open-resources" => Ok(json!(catalog.open_resources(
                    self.workspace.as_mut().ok_or("请先打开原生工作区")?,
                    &p["files"]
                )?)),
                _ => Err("未提供该原生目录接口".into()),
            };
        }
        if method == "armor-assign-preview" || method == "armor-assign-export-copy" {
            return crate::armor_assign::invoke(p, method == "armor-assign-export-copy");
        }
        if method == "workspace-open" {
            if self.game.is_some() {
                return Err("桌面会话已载入游戏工作区".into());
            }
            let workspace = crate::workspace_api::open(p)?;
            let problems = workspace.problems();
            self.workspace = Some(workspace);
            self.game = None;
            return Ok(json!({"problems":problems}));
        }
        if method == "workspace-close" {
            self.game = None;
            self.workspace = None;
            return Ok(json!(true));
        }
        if method.starts_with("workspace-") {
            return crate::workspace_api::invoke(
                self.workspace.as_mut().ok_or("请先打开原生工作区")?,
                method,
                p,
            );
        }
        if method == "update-open-link" {
            crate::update::open_link(text(p, "url")?)?;
            return Ok(json!(true));
        }
        if method == "update-parse" {
            return crate::update::parse(text(p, "json")?, text(p, "current")?);
        }
        if method == "update-start" {
            if self
                .update_job
                .as_ref()
                .is_some_and(|job| !job.is_finished())
            {
                return Ok(json!({"pending":true}));
            }
            let current = text(p, "current")?.to_string();
            self.update_job = Some(std::thread::spawn(move || crate::update::check(&current)));
            return Ok(json!({"pending":true}));
        }
        if method == "update-poll" {
            if self
                .update_job
                .as_ref()
                .is_some_and(|job| !job.is_finished())
            {
                return Ok(json!({"pending":true}));
            }
            let Some(job) = self.update_job.take() else {
                return Ok(json!({"pending":false,"idle":true}));
            };
            return job
                .join()
                .map_err(|_| "更新检查异常退出".to_string())?
                .map(|offer| json!({"pending":false,"offer":offer}));
        }
        if method == "residency-plan" {
            let root = std::path::Path::new(text(p, "root")?);
            let ledger = crate::residency::read_ledger(std::path::Path::new(text(p, "ledger")?))?;
            let plan = crate::residency::plan(root, &ledger, text(p, "host")?, text(p, "name")?)?;
            let entry = ledger.iter().find(|e| {
                e.host.eq_ignore_ascii_case(text(p, "host").unwrap_or(""))
                    && e.name.eq_ignore_ascii_case(text(p, "name").unwrap_or(""))
            });
            let state = entry
                .map(|e| crate::residency::state(root, e))
                .transpose()?;
            return Ok(
                json!({"slot":plan.index,"reuse":plan.reuse,"state":state.unwrap_or(0),"read_only":true}),
            );
        }
        if method == "dependency-closure" {
            let roots = identities(&p["roots"])?;
            let mut edges = std::collections::BTreeMap::new();
            for edge in p["edges"].as_array().ok_or("依赖边清单无效")? {
                if edges
                    .insert(
                        identity(&edge["resource"])?,
                        identities(&edge["dependencies"])?,
                    )
                    .is_some()
                {
                    return Err("依赖节点重复".into());
                }
            }
            let (all, missing) = crate::dependencies::closure(&roots, &edges, 4096)?;
            return Ok(
                json!({"resources":all.into_iter().map(identity_json).collect::<Vec<_>>(),"unknown":missing.into_iter().map(identity_json).collect::<Vec<_>>(),"read_only":true}),
            );
        }
        if method == "resource-scan" || method == "resources-resolve" {
            let root = fs::canonicalize(text(p, "root")?).map_err(|_| "资源目录不可读")?;
            let meta = fs::metadata(root.join("bundles.nxa")).map_err(|_| "资源索引不可读")?;
            let stamp = meta.modified().map_err(|_| "无法核对资源索引时间")?;
            if !self
                .resolver
                .as_ref()
                .is_some_and(|(r, len, time, _)| *r == root && *len == meta.len() && *time == stamp)
            {
                let resolver =
                    crate::resource_resolver::Resolver::new(crate::bundles::Bundles::open(&root)?);
                self.resolver = Some((root, meta.len(), stamp, resolver));
            }
            let resolver = &mut self.resolver.as_mut().unwrap().3;
            let progress = |done, total| {
                if done % 32 == 0 {
                    eprintln!(
                        "@shodan-progress {}",
                        json!({"stage":"核对资源与音效来源","done":done,"total":total})
                    );
                }
            };
            if method == "resource-scan" {
                let mut blobs = Vec::new();
                let mut total = 0usize;
                for input in p["blobs"].as_array().ok_or("缺少资源引用数据")? {
                    let hex = input.as_str().ok_or("资源引用数据格式无效")?;
                    total = total.checked_add(hex.len()).ok_or("资源引用数据过大")?;
                    if total > 32 * 1024 * 1024
                        || hex.len() % 2 != 0
                        || !hex.bytes().all(|c| c.is_ascii_hexdigit())
                    {
                        return Err("资源引用数据过大或十六进制无效".into());
                    }
                    blobs.push(
                        (0..hex.len())
                            .step_by(2)
                            .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
                            .collect(),
                    );
                }
                let found = resolver.scan(&blobs, progress)?;
                return Ok(
                    json!({"candidates":found.into_iter().map(identity_json).collect::<Vec<_>>(),"read_only":true,"note":"按完整资源哈希查找的候选引用，需要结合实际字段核对"}),
                );
            }
            let preferred = p["preferred"]
                .as_array()
                .ok_or("首选资源包清单无效")?
                .iter()
                .map(|v| {
                    v.as_str()
                        .map(|s| s.to_ascii_lowercase())
                        .ok_or("资源包名称无效")
                })
                .collect::<Result<Vec<_>, _>>()?;
            let resources = identities(&p["resources"])?;
            let events = p["events"]
                .as_array()
                .ok_or("音效事件清单无效")?
                .iter()
                .map(|v| {
                    v.as_u64()
                        .and_then(|n| u32::try_from(n).ok())
                        .filter(|n| *n != 0)
                        .ok_or("音效事件 ID 无效")
                })
                .collect::<Result<std::collections::BTreeSet<_>, _>>()?;
            let (resolved, providers, warnings) =
                resolver.resolve(&preferred, &resources, &events, progress)?;
            let mut details = Vec::new();
            for key in &resources {
                details.push(json!({"resource":identity_json(*key),"providers":resolved.packages.iter().filter(|n|providers[*n].resources.contains(key)).collect::<Vec<_>>(),"missing":resolved.missing_resources.contains(key)}));
            }
            for event in &events {
                details.push(json!({"event":event,"providers":resolved.packages.iter().filter(|n|providers[*n].events.contains(event)).collect::<Vec<_>>(),"missing":resolved.missing_events.contains(event)}));
            }
            return Ok(
                json!({"packages":resolved.packages,"details":details,"missing_resources":resolved.missing_resources.into_iter().map(identity_json).collect::<Vec<_>>(),"missing_events":resolved.missing_events,"warnings":warnings,"read_only":true,"audio_binding":"Wwise 事件目录身份匹配，不代表全部声音播放链已验证"}),
            );
        }
        if method == "bundle-inspect"
            || method == "bundle-package-inspect"
            || method == "bundle-patch-preview"
        {
            let mut bundles =
                crate::bundles::Bundles::open(std::path::Path::new(text(p, "root")?))?;
            if method == "bundle-inspect" {
                return Ok(
                    json!({"count":bundles.packages.len(),"names":bundles.packages.keys().take(100).collect::<Vec<_>>()}),
                );
            }
            if method == "bundle-patch-preview" {
                let mode = match text(p, "mode")? {
                    "light" => crate::bundles::Mode::Light,
                    "full" => crate::bundles::Mode::Full,
                    "res" => crate::bundles::Mode::Overrides,
                    _ => return Err("驻留模式无效".into()),
                };
                let mut overrides = std::collections::BTreeMap::new();
                if let Some(entries) = p.get("overrides") {
                    for entry in entries.as_array().ok_or("覆盖清单无效")? {
                        let id = u64::from_str_radix(text(entry, "id")?, 16)
                            .map_err(|_| "资源 ID 无效")?;
                        let typ = u64::from_str_radix(text(entry, "type")?, 16)
                            .map_err(|_| "资源类型无效")?;
                        let hex = text(entry, "hex")?;
                        if hex.len() % 2 != 0 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
                            return Err("资源覆盖内容不是有效十六进制".into());
                        }
                        let bytes = (0..hex.len())
                            .step_by(2)
                            .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
                            .collect();
                        if overrides.insert((typ, id), bytes).is_some() {
                            return Err("资源覆盖身份重复".into());
                        }
                    }
                }
                let built = bundles.build_patch(text(p, "name")?, mode, &overrides)?;
                let report = |bytes: &[u8]| json!({"bytes":bytes.len(),"sha256":crate::hash::sha256_hex(bytes)});
                return Ok(
                    json!({"toc":report(&built.toc),"gpu":report(&built.gpu),"stream":report(&built.stream),"installed":false}),
                );
            }
            let package = bundles.package(text(p, "name")?)?;
            return Ok(
                json!({"entries":package.entries.len(),"types":package.types.len(),"read_only":true}),
            );
        }
        if method == "package-inspect" || method == "package-rebuild-copy" {
            let input = fs::read(text(p, "path")?).map_err(|_| "无法读取资源包")?;
            let package = crate::resource_package::Package::parse(&input)?;
            if method == "package-inspect" {
                return Ok(
                    json!({"types":package.types.len(),"entries":package.entries.iter().map(|e|json!({
                "id":format!("{:016X}",u64::from_le_bytes(e[..8].try_into().unwrap())),"type":format!("{:016X}",u64::from_le_bytes(e[8..16].try_into().unwrap()))})).collect::<Vec<_>>()}),
                );
            }
            let side = |key| -> Result<Vec<u8>, String> {
                if p[key].is_null() {
                    Ok(Vec::new())
                } else {
                    fs::read(text(p, key)?).map_err(|_| "无法读取资源伴生文件".into())
                }
            };
            let blobs = package.blobs(&input, &side("gpu_path")?, &side("stream_path")?)?;
            let built = package.build(&blobs)?;
            let out = PathBuf::from(text(p, "output")?);
            // All three files are one export transaction; no game directory is inferred.
            let parent = out.parent().ok_or("导出目录无效")?;
            let backup = parent.join(format!(
                "shodan-export-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_err(|_| "系统时间无效")?
                    .as_nanos()
            ));
            let gpu = PathBuf::from(format!("{}.gpu_resources", out.display()));
            let stream = PathBuf::from(format!("{}.stream", out.display()));
            if out.exists() || gpu.exists() || stream.exists() {
                return Err("导出文件已存在，不会覆盖".into());
            }
            crate::install::apply(
                vec![
                    crate::install::Change {
                        path: out,
                        before: None,
                        after: Some(built.toc),
                    },
                    crate::install::Change {
                        path: gpu,
                        before: None,
                        after: Some(built.gpu),
                    },
                    crate::install::Change {
                        path: stream,
                        before: None,
                        after: Some(built.stream),
                    },
                ],
                &backup,
                |_| {},
            )?;
            return Ok(json!({"resources":blobs.len(),"installed":false}));
        }
        if method == "reference-files" {
            let paths = p["paths"].as_array().ok_or("缺少引用数据文件")?;
            if paths.len() > 64 {
                return Err("引用数据文件过多".into());
            }
            let sessions = paths
                .iter()
                .map(|v| {
                    let bytes = fs::read(v.as_str().ok_or("文件路径无效")?)
                        .map_err(|_| "引用数据无法读取")?;
                    Session::new(bytes, None)
                })
                .collect::<Result<Vec<_>, String>>()?;
            let data = crate::references::Data::new(sessions.iter().collect())?;
            let roots = p["roots"]
                .as_array()
                .ok_or("缺少引用根节点")?
                .iter()
                .map(|root| {
                    Ok((
                        text(root, "kind")?.to_string(),
                        u32::try_from(number(root, "id")?).map_err(|_| "引用 ID 超出范围")?,
                        root["via"].as_str().unwrap_or("当前记录").to_string(),
                    ))
                })
                .collect::<Result<Vec<_>, String>>()?;
            return data.graph(&roots);
        }
        if method == "diagnostic-scrub" {
            return Ok(crate::diagnostics::Privacy::local().scrub(&p["data"]));
        }
        if method == "diagnostic-check" {
            let runtime = std::env::current_exe()
                .ok()
                .and_then(|p| p.parent().map(std::path::Path::to_owned))
                .ok_or("无法定位运行目录")?;
            return Ok(crate::diagnostics::checks(
                &runtime,
                self.game.as_ref().map(|g| g.root.as_path()),
            ));
        }
        if method == "diagnostic-export" {
            if !game_writes {
                return Err("请从桌面选择日志导出位置".into());
            }
            let path = std::path::Path::new(text(p, "path")?);
            if path
                .extension()
                .and_then(|ext| ext.to_str())
                .is_none_or(|ext| !ext.eq_ignore_ascii_case("json"))
            {
                return Err("诊断报告路径必须使用 .json 后缀".into());
            }
            let report = crate::diagnostics::Privacy::local().scrub(&p["report"]);
            let bytes = serde_json::to_vec_pretty(&report).map_err(|_| "诊断报告编码失败")?;
            crate::install::save_atomic(path, &bytes)?;
            return Ok(json!(true));
        }
        if method == "armor-open" {
            let session = crate::armor_session::Session::open(
                PathBuf::from(text(p, "path")?),
                text(p, "baseline_path")?,
            )?;
            let count = session.row_count();
            self.armor = Some(session);
            return Ok(json!({"rows":count}));
        }
        if method.starts_with("armor-") {
            return self
                .armor
                .as_mut()
                .ok_or("请先打开护甲数据")?
                .invoke(method, p);
        }
        if method == "schema" {
            let type_id =
                u32::from_str_radix(text(p, "type")?, 16).map_err(|_| "数据块类型无效")?;
            let fields = crate::schema::parameters(type_id);
            if fields.is_empty() {
                return Err("该类型的原生参数描述尚未迁移".into());
            }
            return Ok(json!(fields
                .iter()
                .map(|f| json!({"id":f.id,"label":f.label,"relative":f.relative,
                "kind":match f.kind {Kind::F32=>"f32",Kind::U32=>"u32",Kind::I32=>"i32"}}))
                .collect::<Vec<_>>()));
        }
        if method == "info" {
            return Ok(
                json!({"runtime":"rust-native","version":env!("CARGO_PKG_VERSION"),"lua":false,"installation":false}),
            );
        }
        if method == "close" {
            self.active = None;
            self.armor = None;
            self.workspace = None;
            self.parameters = Default::default();
            return Ok(json!(true));
        }
        if method == "preset-inspect" {
            let preset = crate::preset::Preset::decode(text(p, "text")?)?;
            return Ok(
                json!({"kind":preset.kind,"name":preset.name,"weapon":preset.weapon,
                "editor":preset.editor,"armor":preset.armor,"values":preset.values.iter().map(|v|
                    json!({"owner":v.owner,"parameter":v.parameter,"value":v.value})).collect::<Vec<_>>(),
                "normalized":preset.encode()?}),
            );
        }
        if method == "open" {
            let path = PathBuf::from(text(p, "path")?);
            let bytes = fs::read(&path).map_err(|_| "无法读取数据文件")?;
            let baseline = if p["baseline_path"].is_null() {
                None
            } else {
                let filename = text(p, "baseline_name")?;
                let bytes = fs::read(text(p, "baseline_path")?).map_err(|_| "无法读取原值文件")?;
                Some(Baseline::shipped(filename, bytes)?)
            };
            let blocks = crate::dlbin::index(&bytes).map_err(|e| e.to_string())?;
            let report = json!({"blocks":blocks.iter().enumerate().map(|(index,b)|json!({"index":index,"type":format!("{:08X}",b.type_id),"bytes":b.payload.len()})).collect::<Vec<_>>()});
            let session = Session::new(bytes, baseline)?;
            self.active = Some((session, path));
            self.parameters = Default::default();
            return Ok(report);
        }
        let (session, path) = self.active.as_mut().ok_or("请先打开数据文件")?;
        match method {
            "references" => {
                let data = crate::references::Data::new(vec![session])?;
                let roots = if let Some(entity) = p["entity"].as_str() {
                    data.roots(u64::from_str_radix(entity, 16).map_err(|_| "实体哈希无效")?)?
                } else {
                    p["roots"]
                        .as_array()
                        .ok_or("缺少引用根节点")?
                        .iter()
                        .map(|root| {
                            Ok((
                                text(root, "kind")?.to_string(),
                                u32::try_from(number(root, "id")?)
                                    .map_err(|_| "引用 ID 超出范围")?,
                                "当前数据记录".into(),
                            ))
                        })
                        .collect::<Result<Vec<_>, String>>()?
                };
                data.graph(&roots)
            }
            "bind-parameter" => {
                let parts = p["fields"].as_array().ok_or("缺少参数字段")?;
                let fields = parts
                    .iter()
                    .map(|part| {
                        session.named_field(
                            number(part, "block")?,
                            record(part)?,
                            text(part, "parameter")?,
                        )
                    })
                    .collect::<Result<Vec<_>, String>>()?;
                self.parameters
                    .bind(session, text(p, "owner")?, text(p, "parameter")?, fields)?;
                Ok(json!(true))
            }
            "preset-compare" | "preset-apply-values" => {
                let preset = crate::preset::Preset::decode(text(p, "text")?)?;
                let allow_missing = match p.get("allow_missing") {
                    None => false,
                    Some(v) => v.as_bool().ok_or("跳过缺失参数选项必须为布尔值")?,
                };
                let plan = if method == "preset-compare" {
                    self.parameters.plan(session, &preset, allow_missing)?
                } else {
                    self.parameters.apply(session, &preset, allow_missing)?
                };
                Ok(
                    json!({"changes":plan.changes.iter().map(|(owner,parameter,before,after)|json!({"owner":owner,"parameter":parameter,"before":before,"after":after})).collect::<Vec<_>>(),
                    "warnings":plan.warnings,"pending":session.pending_count(),"applied":method=="preset-apply-values"}),
                )
            }
            "history" => {
                let (undo, redo) = session.history();
                Ok(json!({"undo":undo,"redo":redo}))
            }
            "undo" => Ok(json!({"changed":session.undo(),"pending":session.pending_count()})),
            "redo" => Ok(json!({"changed":session.redo(),"pending":session.pending_count()})),
            "index" => {
                let layout = match text(p, "layout")? {
                    "rows" => Layout::Rows {
                        stride: number(p, "stride")?,
                        id_offset: number(p, "id_offset")?,
                    },
                    "keyed" => Layout::Keyed {
                        stride: number(p, "stride")?,
                        slack: number(p, "slack")?,
                    },
                    _ => return Err("未知表布局".into()),
                };
                session.index_table(number(p, "block")?, layout)?;
                Ok(json!(true))
            }
            "get" => {
                let value = session.value(field(p)?)?;
                Ok(json!({"value":value.current,"original":value.original}))
            }
            "set" => {
                session.set(field(p)?, p["value"].as_f64().ok_or("数值无效")?)?;
                Ok(json!({"pending":session.pending_count()}))
            }
            "apply-batch" => {
                let edits = p["fields"].as_array().ok_or("缺少批量字段列表")?;
                if edits.len() > 100000 {
                    return Err("批量字段过多".into());
                }
                let edits = edits
                    .iter()
                    .map(|entry| Ok((field(entry)?, entry["value"].as_f64().ok_or("数值无效")?)))
                    .collect::<Result<Vec<_>, String>>()?;
                session.apply_batch(&edits)?;
                Ok(json!({"pending":session.pending_count(),"accepted":edits.len()}))
            }
            "restore" => {
                session.restore(field(p)?)?;
                Ok(json!({"pending":session.pending_count()}))
            }
            "preview" => Ok(json!({"pending":session.pending_count(),"installed":false})),
            "export-copy" => {
                // Re-read before export: external tools must not be overwritten by stale edits.
                let current = fs::read(path).map_err(|_| "无法重新读取磁盘快照")?;
                let edited = session.render(&current)?;
                let mut output = fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(text(p, "path")?)
                    .map_err(|_| "无法创建新文件，不会覆盖已有文件")?;
                output
                    .write_all(&edited)
                    .and_then(|_| output.sync_all())
                    .map_err(|_| "导出写入失败")?;
                Ok(
                    json!({"bytes":edited.len(),"sha256":crate::hash::sha256_hex(&edited),"installed":false,"sealed":false}),
                )
            }
            _ => Err(format!("未提供原生接口：{method}")),
        }
    }

    fn desktop_call(
        &mut self,
        method: &str,
        args: &[Value],
        game_writes: bool,
    ) -> Result<Value, String> {
        use crate::desktop;
        let arg = |i| args.get(i).unwrap_or(&Value::Null);
        if method == "install_task" || method == "restore_task" {
            if !game_writes {
                return Err("请从桌面确认游戏文件写入".into());
            }
            return self.invoke(
                &json!({"method":if method=="install_task" {"game-install"} else {"game-restore"},
                "params":{"allow_float_adjustment":arg(0)==&Value::Bool(true),"force":arg(1)==&Value::Bool(true)}}),
            );
        }
        let catalog = self.catalog.as_ref().ok_or("请先打开游戏工作区")?;
        let workspace = self.workspace.as_mut().ok_or("请先打开游戏工作区")?;
        match method {
            "attachment_options" => {
                return crate::attachments::list(
                    &self.game.as_ref().ok_or("请先打开游戏工作区")?.root,
                )
            }
            "baseline_check" => {
                return Ok(self
                    .game
                    .as_ref()
                    .ok_or("请先打开游戏工作区")?
                    .baseline_check(workspace))
            }
            "tweaks" => return crate::desktop_tweaks::call(catalog, workspace, args),
            "ragdoll_preview" | "ragdoll_apply" => {
                let game = self.game.as_ref().ok_or("请先打开游戏工作区")?;
                let on = if method == "ragdoll_apply" {
                    if !game_writes {
                        return Err("请从桌面确认资源补丁写入".into());
                    }
                    Some(arg(0).as_bool().ok_or("开关必须为布尔值")?)
                } else {
                    None
                };
                return crate::desktop_resource_edits::ragdoll(game, on);
            }
            "info" => {
                return Ok(json!({"game":self.game.as_ref().map(|g|&g.root),
                "armor":crate::armor::catalog()["list"],"version":env!("CARGO_PKG_VERSION"),"runtime":"rust-native"}))
            }
            "flush" => return Ok(json!(true)),
            "extra_warnings" | "extra_validate" => {
                return Ok(json!(crate::extra_stratagem::current_warnings(
                    catalog, workspace
                )?));
            }
            "status" => {
                return Ok(json!({"phase":"ready","dirty":workspace.pending_count()!=0,
                "problems":workspace.problems()}))
            }
            "editor_mode" => {
                if let Some(enemy) = arg(0).as_bool() {
                    self.desktop.enemy = enemy;
                }
                return Ok(json!(self.desktop.enemy));
            }
            "items" => {
                return Ok(desktop::items(
                    catalog,
                    workspace,
                    arg(0).as_str().unwrap_or(""),
                    arg(1).as_str().unwrap_or(""),
                ))
            }
            "select" => {
                let owner = catalog.owner(arg(0).as_str().ok_or("缺少条目标识")?)?.1;
                self.desktop.selected = Some(owner.id.clone());
                return Ok(json!(true));
            }
            "history" | "history_status" => {
                let (undo, redo) = workspace.history();
                if method == "history_status" {
                    return Ok(json!({"undo":undo,"redo":redo}));
                }
                return Ok(
                    json!({"undo":undo,"redo":redo,"entries":desktop::pending(catalog,workspace)}),
                );
            }
            "undo" => return Ok(json!(workspace.replay(false)?)),
            "redo" => return Ok(json!(workspace.replay(true)?)),
            "armor_rows" | "armor_set" | "armor_profile" | "armor_update" | "armor_item"
            | "armor_capture" | "armor_apply" | "armor_compare" | "armor_count"
            | "armor_validate" => {
                return crate::desktop_armor::invoke(catalog, workspace, method, args);
            }
            "full_presets" | "full_preset" | "preset" | "preset_info" | "preset_compare"
            | "preset_export" | "preset_import" | "preset_rename" | "preset_code"
            | "preset_code_import" | "preset_description" | "preset_duplicate"
            | "restore_examples" => {
                return crate::desktop_presets::invoke(
                    catalog,
                    workspace,
                    &self.desktop,
                    method,
                    args,
                );
            }
            "install_preview" | "pending_preview" => {
                let mut entries = desktop::pending(catalog, workspace);
                if let Some(array) = entries.as_array_mut() {
                    array.extend(crate::desktop_armor::preview(workspace)?);
                }
                if method == "pending_preview" {
                    return Ok(entries);
                }
                let (_, mut warnings) = catalog.code_overrides(workspace, workspace.metadata())?;
                warnings.extend(crate::extra_stratagem::current_warnings(
                    catalog, workspace,
                )?);
                warnings.extend(crate::extra_stratagem::derive(catalog, workspace)?.warnings);
                let allow_float_adjustment =
                    !crate::game_workspace::changed_floats(catalog, workspace).is_empty();
                if allow_float_adjustment {
                    warnings.push(
                        "部分文件的校验空间不足时，需要明确允许微调本次已修改的浮点数值。".into(),
                    );
                }
                let mut problems = workspace.data_problems();
                if let Some(game) = &self.game {
                    let report = game.install_check(workspace);
                    problems.extend(
                        report["problems"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .filter_map(Value::as_str)
                            .map(str::to_owned),
                    );
                    warnings.extend(
                        report["warnings"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .filter_map(Value::as_str)
                            .map(str::to_owned),
                    );
                    problems.sort();
                    problems.dedup();
                }
                return Ok(
                    json!({"entries":entries,"problems":problems,"warnings":warnings,
                        "allow_float_adjustment":allow_float_adjustment}),
                );
            }
            _ => {}
        }
        if method == "game_text" && self.desktop.selected.is_none() && arg(1).is_null() {
            return Ok(json!({"available":false}));
        }
        let id = self.desktop.selected.as_deref().ok_or("请先选择条目")?;
        let owner = catalog.owner(id)?.1;
        if method == "game_text" {
            let game = self.game.as_ref().ok_or("请先打开游戏工作区")?;
            let field = arg(0).as_str().ok_or("无效的文字字段")?;
            if owner.text.is_none() {
                return Ok(json!({"available":false}));
            }
            let mut originals = game.text_originals.borrow_mut();
            if originals.is_none() {
                *originals = Some(crate::desktop_text::load_originals(game)?);
            }
            return crate::desktop_text::edit(
                workspace,
                owner,
                originals.as_ref().unwrap(),
                field,
                arg(1).as_str(),
            );
        }
        if matches!(method, "choices" | "choose" | "set" | "reset") && !arg(0).is_null() {
            let row = desktop::row(owner, arg(0))?;
            if row.choice == "smres" && method == "choices" {
                let game = self.game.as_ref().ok_or("请先打开游戏工作区")?;
                return crate::desktop_resource_edits::machine_choices(
                    game, catalog, workspace, owner, row,
                );
            }
            if row.choice == "smres" && matches!(method, "choose" | "set") {
                let game = self.game.as_ref().ok_or("请先打开游戏工作区")?;
                let requested = desktop::number(arg(1))?;
                let choices = crate::desktop_resource_edits::machine_choices(
                    game, catalog, workspace, owner, row,
                )?;
                if !choices
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|item| item["id"].as_f64() == Some(requested))
                {
                    return Err("所选状态机不在资源包内".into());
                }
            }
            if row.choice == "smmode" && method != "choices" {
                if !game_writes {
                    return Err("请从桌面确认资源补丁写入".into());
                }
                let game = self.game.as_ref().ok_or("请先打开游戏工作区")?;
                let mode = if method == "reset" {
                    2.0
                } else {
                    desktop::number(arg(1))?
                };
                let on = match mode {
                    0.0 => return Ok(json!("未更改状态机补丁")),
                    1.0 => true,
                    2.0 => false,
                    _ => return Err("状态机补丁模式无效".into()),
                };
                return crate::desktop_resource_edits::machine(
                    game,
                    catalog,
                    workspace,
                    owner,
                    row,
                    Some(on),
                );
            }
        }
        if method == "diagnostic_resources" {
            let game = self.game.as_ref().ok_or("请先打开游戏工作区")?;
            let mut report = game.resource_report(
                crate::desktop_resources::plan(catalog, workspace, owner, true)?,
                id,
                None,
            )?;
            report["equipment"] = json!(owner.name);
            report["owner"] = json!(owner.id);
            return Ok(report);
        }
        if matches!(method, "choose" | "set" | "reset")
            && !arg(0).is_null()
            && desktop::row(owner, arg(0))?.choice == "resomode"
        {
            if !game_writes {
                return Err("请从桌面确认资源补丁写入".into());
            }
            let game = self.game.as_ref().ok_or("请先打开游戏工作区")?;
            let mode = if method == "reset" {
                3.0
            } else {
                desktop::number(arg(1))?
            };
            if mode == 0.0 {
                return Ok(json!("未更改资源驻留补丁"));
            }
            let plan = match mode {
                1.0 => crate::desktop_resources::plan(catalog, workspace, owner, false)?,
                3.0 => Default::default(),
                _ => return Err("请选择完整驻留或移除补丁".into()),
            };
            return game.resource_report(plan, id, Some(mode as u32));
        }
        match method {
            "rows" | "rows_fast" | "rows_section" | "rows_delta" => {
                let section = if method == "rows_section" {
                    Some(arg(0).as_str().ok_or("分类无效")?)
                } else {
                    None
                };
                let row = if method == "rows_delta" {
                    Some(desktop::row(owner, arg(0))?)
                } else {
                    None
                };
                let mut rows = desktop::rows(catalog, workspace, owner, section, row);
                if method != "rows_fast" {
                    if let Some(entry) = rows
                        .as_array_mut()
                        .into_iter()
                        .flatten()
                        .find(|r| r["choice_kind"] == "resomode")
                    {
                        if let Some(game) = &self.game {
                            match game.residency_state(id) {
                                Ok(on) => {
                                    entry["value"] = json!(u32::from(on));
                                    entry["choice_name"] = json!(if on {
                                        "完整（含贴图）"
                                    } else {
                                        "未安装"
                                    });
                                    entry["patch_pending"] = json!(false);
                                }
                                Err(err) => {
                                    entry["error"] = json!(err);
                                }
                            }
                        }
                    }
                    if let Some(game) = &self.game {
                        for entry in rows
                            .as_array_mut()
                            .into_iter()
                            .flatten()
                            .filter(|r| r["choice_kind"] == "smmode")
                        {
                            let row = desktop::row(owner, &entry["id"])?;
                            match crate::desktop_resource_edits::machine(
                                game, catalog, workspace, owner, row, None,
                            ) {
                                Ok(state) => {
                                    let on = state["enabled"] == true;
                                    entry["value"] = json!(u32::from(on));
                                    entry["choice_name"] =
                                        json!(if on { "已安装" } else { "未安装" });
                                    entry["patch_pending"] = json!(false);
                                }
                                Err(err) => {
                                    entry["error"] = json!(err);
                                }
                            }
                        }
                    }
                }
                Ok(rows)
            }
            "shared" => Ok(catalog.shared(owner, desktop::row(owner, arg(0))?)),
            "choices" => desktop::choices(catalog, workspace, desktop::row(owner, arg(0))?),
            "diagnostic_chain" => crate::catalog_refs::graph(catalog, workspace, owner),
            "set" | "choose" => desktop::apply(
                catalog,
                workspace,
                id,
                &desktop::row(owner, arg(0))?.key,
                Some(desktop::number(arg(1))?),
            ),
            "reset" if arg(0).is_null() => {
                let plan = crate::catalog_edit::reset_owner(catalog, workspace, owner)?;
                crate::extra_stratagem::validate(catalog, workspace, &plan.values)?;
                catalog.code_overrides(workspace, &plan.metadata)?;
                workspace.set_batch(&plan.values, Some(plan.metadata))?;
                Ok(json!(true))
            }
            "reset" => desktop::apply(
                catalog,
                workspace,
                id,
                &desktop::row(owner, arg(0))?.key,
                None,
            ),
            "code_set" => {
                let row = desktop::row(owner, arg(0))?;
                if !row.code {
                    return Err("此参数不是战备指令".into());
                }
                let arrows = arg(1)
                    .as_array()
                    .ok_or("战备方向输入无效")?
                    .iter()
                    .map(|d| {
                        d.as_u64()
                            .and_then(|n| u8::try_from(n).ok())
                            .ok_or("战备方向输入无效")
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                let value = crate::stratagem_code::number(&arrows)?;
                desktop::apply(catalog, workspace, id, &row.key, Some(f64::from(value)))
            }
            _ => Err(format!("该桌面操作尚未接入原生数据核心：{method}")),
        }
    }
}
fn request_line(
    input: &mut impl BufRead,
    limit: usize,
) -> Result<Option<Result<Vec<u8>, String>>, String> {
    let mut line = Vec::new();
    let mut too_large = false;
    loop {
        let buffer = input.fill_buf().map_err(|_| "请求读取失败")?;
        if buffer.is_empty() {
            return if line.is_empty() && !too_large {
                Ok(None)
            } else {
                Ok(Some(if too_large {
                    Err("请求过大".into())
                } else {
                    Ok(line)
                }))
            };
        }
        let newline = buffer.iter().position(|b| *b == b'\n');
        let consumed = newline.map_or(buffer.len(), |at| at + 1);
        if !too_large {
            if line.len().saturating_add(consumed) > limit {
                too_large = true;
                line.clear();
            } else {
                line.extend_from_slice(&buffer[..consumed]);
            }
        }
        input.consume(consumed);
        if newline.is_some() {
            return Ok(Some(if too_large {
                Err("请求过大".into())
            } else {
                Ok(line)
            }));
        }
    }
}
pub fn serve(mut input: impl BufRead, mut output: impl Write) -> Result<(), String> {
    let api = std::sync::Arc::new(std::sync::Mutex::new(Api::default()));
    let mut mcp: Option<crate::mcp::Server> = None;
    // Permit an 8 MiB preset even if JSON escapes every byte. Bound allocation
    // while reading, and drain oversized requests so the next call remains usable.
    while let Some(line) = request_line(&mut input, 50 * 1024 * 1024)? {
        let parsed = line.and_then(|line| {
            serde_json::from_slice::<Value>(&line).map_err(|_| "请求 JSON 无效".to_string())
        });
        let id = parsed
            .as_ref()
            .ok()
            .and_then(|r| r.get("id"))
            .cloned()
            .unwrap_or(Value::Null);
        let result = parsed.and_then(|r| match r["method"].as_str() {
            Some("mcp-start") => {
                if mcp.is_none() {
                    mcp = Some(crate::mcp::Server::start(api.clone())?);
                }
                Ok(json!({"enabled":true,"config":mcp.as_ref().unwrap().config()}))
            }
            Some("mcp-stop") => {
                mcp = None;
                Ok(json!({"enabled":false}))
            }
            Some("mcp-status") => Ok(json!({"enabled":mcp.is_some()})),
            Some("mcp-config") => mcp
                .as_ref()
                .map(|s| s.config())
                .ok_or("MCP 尚未开启".into()),
            _ => api
                .lock()
                .map_err(|_| "原生会话不可用".to_string())?
                .invoke(&r),
        });
        let response = match result {
            Ok(value) => json!({"id":id,"ok":true,"result":value}),
            Err(e) => json!({"id":id,"ok":false,"error":e}),
        };
        writeln!(output, "{response}")
            .and_then(|_| output.flush())
            .map_err(|_| "响应写入失败")?;
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn automatic_repair_requires_desktop_authorization() {
        let mut api = Api::default();
        let error = api
            .invoke_mcp(&json!({"method":"game-repair","params":{}}))
            .unwrap_err();
        assert!(error.contains("桌面设置"));
    }
    #[test]
    fn oversized_lines_are_drained_and_following_requests_remain_readable() {
        let mut input = std::io::BufReader::with_capacity(3, &b"123456789\n{}\n"[..]);
        assert!(request_line(&mut input, 5).unwrap().unwrap().is_err());
        assert_eq!(
            request_line(&mut input, 5).unwrap().unwrap().unwrap(),
            b"{}\n"
        );
        assert!(request_line(&mut input, 5).unwrap().is_none());
    }
    #[test]
    fn transport_preserves_ids_and_recovers_after_bad_requests() {
        let input=b"bad\n{\"id\":7,\"method\":\"get\",\"params\":{}}\n{\"id\":\"hello\",\"method\":\"info\"}\n";
        let mut output = Vec::new();
        serve(&input[..], &mut output).unwrap();
        let replies: Vec<Value> = String::from_utf8(output)
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        assert_eq!(replies[0]["ok"], false);
        assert_eq!(replies[1]["id"], 7);
        assert_eq!(replies[2]["id"], "hello");
        assert_eq!(replies[2]["result"]["lua"], false);
    }
}
