//! Privacy filtering for native diagnostic exports. No automatic upload.
use serde_json::{json, Value};
use std::path::Path;

/// Guidance only; classification never authorizes overwriting a foreign file.
pub fn installation_advice(error: &str) -> Value {
    let lower = error.to_ascii_lowercase();
    let (code, repairability, action) = if error.contains("未完成的安装事务")
        || error.contains("中断安装")
    {
        (
            "interrupted_transaction",
            "automatic",
            "关闭游戏后运行自动修复，按原事务指纹恢复中断写入，再重新预览。",
        )
    } else if error.contains("草稿") {
        (
            "draft",
            "conditional",
            "运行自动修复：损坏草稿会先完整备份；来源已变化的草稿会保留，不会猜测覆盖。",
        )
    } else if error.contains("派生") {
        (
            "derived_record",
            "conditional",
            "运行自动修复，清理与当前文件不一致的旧派生登记，再检查附赠战备。",
        )
    } else if error.contains("备份")
        && (error.contains("缺失") || error.contains("已变化") || error.contains("不匹配"))
    {
        ("backup_invalid", "manual", "原始备份缺失、损坏或版本不符时无法凭空恢复。请保留日志与现有文件，从可靠备份或 Steam 校验恢复对应版本后再检查。")
    } else if lower.contains("disk full")
        || error.contains("系统错误 112")
        || error.contains("Windows 错误 112")
    {
        ("disk_space", "manual", "释放游戏盘与备份目录所在磁盘的空间，再运行自动修复处理未完成事务。自动修复不会删除其他个人文件以腾出空间。")
    } else if lower.contains("permission denied")
        || error.contains("系统错误 5")
        || error.contains("Windows 错误 5")
        || error.contains("权限")
        || error.contains("系统错误 32")
        || error.contains("Windows 错误 32")
    {
        ("access_or_lock", "manual", "完全关闭游戏及其他编辑器，检查报错目标路径的写入权限、只读属性与占用。自动修复不会更改系统权限或强行解锁。")
    } else if error.contains("游戏正在")
        || error.contains("先关闭游戏")
        || error.contains("完全退出游戏")
        || error.contains("请先完全退出")
    {
        (
            "game_running",
            "manual",
            "完全退出游戏进程后重新预览和安装。",
        )
    } else if error.contains("版本")
        || error.contains("没有 package")
        || lower.contains("has no package")
    {
        ("version_or_package", "manual", "核对所选游戏目录、游戏 build 和编辑器参数目录，使用匹配版本；自动修复不能转换未知数据布局或创造不存在的资源包。")
    } else if error.contains("槽位已满") {
        ("patch_capacity", "conditional", "先运行自动修复清理本程序完全缺失的补丁登记；真实占用的外部 Mod 槽位不会自动删除，请手动检查补丁冲突。")
    } else if error.contains("驻留") || error.contains("补丁") || error.contains("伴生文件")
    {
        ("resource_patch", "conditional", "运行自动修复检查本程序登记。完全缺失的自有槽位可清理并补齐中间缺号；被替换或部分缺失的补丁需核对来源，修复后重新安装所需驻留资源。")
    } else if error.contains("其他工具")
        || error.contains("外部工具")
        || error.contains("文件已变化")
    {
        ("external_change", "conditional", "先运行自动修复。已回到安装前备份的文件可清理旧登记；仍含外部修改的文件会保留，确认后选择强制写入或先恢复对应 Mod。")
    } else if error.contains("校验") || error.contains("保留") || error.contains("NoSalt") {
        ("hash_correction", "conditional", "重新生成写入预览，确认允许已提示的浮点校验微调。若仍无法求解，请导出日志；自动修复不能跳过游戏哈希或随意扩展格式保留区。")
    } else if error.contains("缺少") || error.contains("缺失") {
        ("missing_file", "conditional", "自动修复可从本程序已校验且版本匹配的安装备份补回缺失数值文件；没有可靠备份时需重新下载程序或校验游戏文件。")
    } else {
        ("unclassified", "unknown", "运行只读诊断并导出日志，保留失败阶段、目标文件和系统错误码；原因尚未确认，不能报告为已自动修复。")
    };
    json!({"code":code,"repairability":repairability,"action":action})
}

pub(crate) fn checks(runtime: &Path, game: Option<&Path>) -> Value {
    let mut results = Vec::new();
    for name in ["shodan-native.exe", "catalog.json.gz", "data/app.so"] {
        let ok = std::fs::metadata(runtime.join(name)).is_ok_and(|m| m.is_file() && m.len() > 0);
        results.push(json!({"name":name,"ok":ok,
            "message":if ok {"文件存在且非空"} else {"文件缺失或为空"}}));
    }
    results.push(json!({"name":"Rust 数据引擎","ok":true,"message":"响应正常"}));
    let game = game.is_some_and(|path| path.join("game.dll").is_file());
    results.push(json!({"name":"游戏数据目录","ok":game,
        "message":if game {"已读取游戏工作区"} else {"工作区尚未打开"}}));
    json!(results)
}
pub struct Privacy {
    pub profile: Option<String>,
    pub username: Option<String>,
}
fn replace_case(text: &str, needle: &str, replacement: &str) -> String {
    if needle.is_empty() {
        return text.into();
    }
    let lower = text.to_ascii_lowercase();
    let needle = needle.to_ascii_lowercase();
    let mut result = String::new();
    let mut at = 0;
    while let Some(relative) = lower[at..].find(&needle) {
        let start = at + relative;
        result.push_str(&text[at..start]);
        result.push_str(replacement);
        at = start + needle.len();
    }
    result.push_str(&text[at..]);
    result
}
fn sensitive(key: &str) -> bool {
    matches!(
        key.to_ascii_lowercase().replace(['_', '-'], "").as_str(),
        "token"
            | "password"
            | "secret"
            | "apikey"
            | "authorization"
            | "accesstoken"
            | "refreshtoken"
    )
}
impl Privacy {
    pub fn local() -> Self {
        Self {
            profile: std::env::var("USERPROFILE").ok(),
            username: std::env::var("USERNAME").ok(),
        }
    }
    pub fn text(&self, text: &str) -> String {
        let mut text = text.to_string();
        if let Some(profile) = &self.profile {
            for path in [
                profile.clone(),
                profile.replace('\\', "/"),
                profile.replace('\\', "\\\\"),
            ] {
                text = replace_case(&text, &path, "<用户目录>");
            }
        }
        // Redact all Windows profile names, including paths from another computer.
        for marker in [
            "users\\",
            "users/",
            "documents and settings\\",
            "documents and settings/",
        ] {
            let mut start = 0;
            loop {
                let lower = text.to_ascii_lowercase();
                let Some(relative) = lower[start..].find(marker) else {
                    break;
                };
                let mut from = start + relative + marker.len();
                while matches!(text.as_bytes().get(from), Some(b'\\' | b'/')) {
                    from += 1;
                }
                let to = text[from..]
                    .find(['\\', '/', '\r', '\n', '"', '<', '>'])
                    .map_or(text.len(), |n| from + n);
                if to > from {
                    text.replace_range(from..to, "<用户>");
                    start = from + "<用户>".len();
                } else {
                    start = from;
                }
                if start >= text.len() {
                    break;
                }
            }
        }
        if let Some(username) = &self.username {
            text = replace_case(&text, username, "<用户>");
        }
        let mut at = 0;
        loop {
            let lower = text.to_ascii_lowercase();
            let Some(relative) = lower[at..].find("bearer ") else {
                break;
            };
            let from = at + relative + 7;
            let to = text[from..]
                .find(|c: char| c.is_whitespace() || [',', ';', '"'].contains(&c))
                .map_or(text.len(), |n| from + n);
            text.replace_range(from..to, "<已隐藏>");
            at = from + "<已隐藏>".len();
        }
        for key in ["token", "password", "secret", "api_key", "api-key"] {
            let mut at = 0;
            loop {
                let lower = text.to_ascii_lowercase();
                let Some(relative) = lower[at..].find(key) else {
                    break;
                };
                let end = at + relative + key.len();
                let mut from = end;
                while matches!(text.as_bytes().get(from), Some(b' ' | b'\t' | b'"' | b'\'')) {
                    from += 1;
                }
                if !matches!(text.as_bytes().get(from), Some(b':' | b'=')) {
                    at = end;
                    continue;
                }
                from += 1;
                while matches!(text.as_bytes().get(from), Some(b' ' | b'\t' | b'"' | b'\'')) {
                    from += 1;
                }
                let to = text[from..]
                    .find(|c: char| c.is_whitespace() || [',', ';', '"', '\'', '}'].contains(&c))
                    .map_or(text.len(), |n| from + n);
                text.replace_range(from..to, "<已隐藏>");
                at = from + "<已隐藏>".len();
            }
        }
        text
    }
    pub fn scrub(&self, value: &Value) -> Value {
        match value {
            Value::String(s) => Value::String(self.text(s)),
            Value::Array(a) => Value::Array(a.iter().map(|v| self.scrub(v)).collect()),
            Value::Object(map) => Value::Object(
                map.iter()
                    .map(|(k, v)| {
                        (
                            self.text(k),
                            if sensitive(k) {
                                Value::String("<已隐藏>".into())
                            } else {
                                self.scrub(v)
                            },
                        )
                    })
                    .collect(),
            ),
            _ => value.clone(),
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn installation_guidance_distinguishes_repair_from_manual_intervention() {
        for (message, expected, repair) in [
            (
                "发现未完成的安装事务，请先恢复",
                "interrupted_transaction",
                "automatic",
            ),
            (
                "generated_entities.dl_bin 已被其他工具修改，已停止写入",
                "external_change",
                "conditional",
            ),
            (
                "无法创建事务文件（系统错误 5：拒绝访问）",
                "access_or_lock",
                "manual",
            ),
            (
                "generated_entities.dl_bin 的原始备份已变化",
                "backup_invalid",
                "manual",
            ),
            ("驻留补丁槽位 121 缺失", "resource_patch", "conditional"),
            (
                "原生参数目录与当前游戏版本不匹配",
                "version_or_package",
                "manual",
            ),
            ("unrecognized failure", "unclassified", "unknown"),
        ] {
            let advice = installation_advice(message);
            assert_eq!(advice["code"], expected);
            assert_eq!(advice["repairability"], repair);
        }
    }
    #[test]
    fn exported_nested_errors_remove_other_users_and_credentials() {
        let privacy = Privacy {
            profile: Some("C:\\Users\\Tester".into()),
            username: Some("Tester".into()),
        };
        let input = json!({"nested":[{"message":"C:\\Users\\Other\\config.txt C:/Users/Someone/AppData/test Tester Bearer ABC123 token=XYZ password: abc"}],"api_key":"do-not-export","path":"C:\\Users\\Tester\\AppData"});
        let output = privacy.scrub(&input).to_string();
        for secret in [
            "Tester",
            "Other",
            "Someone",
            "ABC123",
            "XYZ",
            " abc",
            "do-not-export",
        ] {
            assert!(!output.contains(secret), "{output}");
        }
        assert!(output.contains("config.txt"));
    }
    #[test]
    fn escaped_and_unicode_profiles_are_hidden() {
        let p = Privacy {
            profile: Some("C:\\Users\\小明".into()),
            username: Some("小明".into()),
        };
        let text = p.text("C:\\\\Users\\\\小明\\\\a C:/Users/另一个人/file 小明");
        assert!(!text.contains("小明"));
        assert!(!text.contains("另一个人"));
        assert!(text.contains("file"));
    }
}
