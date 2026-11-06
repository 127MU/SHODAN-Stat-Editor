//! Privacy filtering for native diagnostic exports. No automatic upload.
use serde_json::{json, Value};
use std::path::Path;

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
