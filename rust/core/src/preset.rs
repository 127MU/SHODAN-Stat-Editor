//! Portable SHODAN-PRESET 1 codec, compatible with the legacy text container.
//! Parameter IDs are preserved verbatim; resolving them requires native schemas.
use std::collections::{BTreeMap, BTreeSet};

#[derive(Debug, PartialEq)]
pub struct Value {
    pub owner: String,
    pub parameter: String,
    pub value: f64,
}
#[derive(Debug, PartialEq)]
pub struct Preset {
    pub kind: String,
    pub name: String,
    pub weapon: Option<String>,
    pub editor: Option<String>,
    pub armor: Option<String>,
    pub description: Option<String>,
    pub texts: BTreeMap<String, BTreeMap<String, String>>,
    pub values: Vec<Value>,
}
fn hex(text: &str) -> String {
    text.as_bytes().iter().map(|b| format!("{b:02x}")).collect()
}
fn unhex(text: &str) -> Result<String, String> {
    if text.len() % 2 != 0 || !text.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("预设文本编码无效".into());
    }
    let bytes = (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap())
        .collect();
    String::from_utf8(bytes).map_err(|_| "预设文本不是有效 UTF-8".into())
}
fn hash(text: &str) -> Result<String, String> {
    if text.len() != 16 || !text.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("预设装备标识无效".into());
    }
    Ok(text.to_ascii_uppercase())
}
impl Preset {
    pub fn decode(input: &str) -> Result<Self, String> {
        let input = input.trim_start_matches('\u{feff}').trim();
        if input.len() > 8 * 1024 * 1024 || input.contains('\0') {
            return Err("预设文件过大或包含无效字符".into());
        }
        let normalized = input.replace("\r\n", "\n");
        let mut lines = normalized.split('\n');
        if lines.next() != Some("SHODAN-PRESET 1") {
            return Err("不是支持的 SHODAN 预设文件".into());
        }
        let mut meta = BTreeMap::new();
        let mut values = Vec::new();
        let mut seen = BTreeSet::new();
        let mut texts = BTreeMap::<String, BTreeMap<String, String>>::new();
        for line in lines.filter(|l| !l.is_empty()) {
            let (key, body) = line.split_once(' ').ok_or("预设行格式错误")?;
            if key == "value" {
                let parts: Vec<_> = body.split_whitespace().collect();
                if parts.len() != 3 {
                    return Err("预设数值行格式错误".into());
                }
                let owner = hash(parts[0])?;
                let parameter = parts[1].to_string();
                if !parameter
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_')
                {
                    return Err("预设参数标识无效".into());
                }
                let value: f64 = parts[2].parse().map_err(|_| "预设数值无效")?;
                if !value.is_finite() {
                    return Err("预设数值必须为有限数".into());
                }
                if !seen.insert((owner.clone(), parameter.clone())) {
                    return Err("预设存在重复参数".into());
                }
                values.push(Value {
                    owner,
                    parameter,
                    value,
                });
                if values.len() > 150000 {
                    return Err("预设参数过多".into());
                }
            } else if key == "text" {
                let mut p = body.split_whitespace();
                let owner = hash(p.next().ok_or("预设文字缺少条目")?)?;
                let field = p.next().ok_or("预设文字缺少字段")?;
                let value = unhex(p.next().ok_or("预设文字缺少内容")?)?;
                crate::desktop_text::validate(field, &value)?;
                if p.next().is_some()
                    || value.is_empty()
                    || texts
                        .entry(owner)
                        .or_default()
                        .insert(field.into(), value)
                        .is_some()
                {
                    return Err("预设包含重复或无效的文字字段".into());
                }
            } else {
                if !["kind", "name", "weapon", "editor", "armor", "description"].contains(&key)
                    || body.is_empty()
                    || meta.insert(key, body).is_some()
                {
                    return Err("预设包含未知或重复字段".into());
                }
            }
        }
        let kind = meta.get("kind").ok_or("缺少预设类型")?.to_string();
        if kind != "weapon" && kind != "full" {
            return Err("预设类型无效".into());
        }
        let name = unhex(meta.get("name").ok_or("缺少预设名称")?)?;
        let name = name.trim().to_string();
        if name.is_empty() || name.len() > 96 || name.chars().any(char::is_control) {
            return Err("预设名称无效".into());
        }
        let weapon = meta.get("weapon").map(|s| hash(s)).transpose()?;
        let editor = meta.get("editor").map(|s| s.to_string());
        if editor
            .as_deref()
            .is_some_and(|s| s != "enemy" && s != "equipment")
        {
            return Err("预设编辑器类型无效".into());
        }
        let armor = meta.get("armor").map(|s| unhex(s)).transpose()?;
        let description = meta.get("description").map(|s| unhex(s)).transpose()?;
        if description
            .as_ref()
            .is_some_and(|s| s.len() > 400 || s.chars().any(char::is_control))
        {
            return Err("预设说明无效".into());
        }
        if armor.is_some() && (kind != "full" || editor.as_deref() == Some("enemy")) {
            return Err("此预设不应包含护甲数值".into());
        }
        if kind == "weapon" {
            let owner = weapon.as_ref().ok_or("缺少装备标识")?;
            if values.iter().any(|v| &v.owner != owner) || texts.keys().any(|key| key != owner) {
                return Err("装备预设混入了其他装备".into());
            }
        } else if weapon.is_some() {
            return Err("全局预设不应包含单个装备标识".into());
        }
        Ok(Self {
            kind,
            name,
            weapon,
            editor,
            armor,
            description,
            texts,
            values,
        })
    }
    pub fn encode(&self) -> Result<String, String> {
        let mut lines = vec![
            "SHODAN-PRESET 1".to_string(),
            format!("kind {}", self.kind),
            format!("name {}", hex(&self.name)),
        ];
        if let Some(editor) = &self.editor {
            lines.push(format!("editor {editor}"));
        }
        if let Some(weapon) = &self.weapon {
            lines.push(format!("weapon {weapon}"));
        }
        if let Some(armor) = &self.armor {
            lines.push(format!("armor {}", hex(armor)));
        }
        if let Some(description) = self.description.as_deref().filter(|s| !s.is_empty()) {
            lines.push(format!("description {}", hex(description)));
        }
        for (owner, fields) in &self.texts {
            for (field, value) in fields {
                lines.push(format!("text {owner} {field} {}", hex(value)));
            }
        }
        for value in &self.values {
            lines.push(format!(
                "value {} {} {}",
                value.owner, value.parameter, value.value
            ));
        }
        let result = lines.join("\n") + "\n";
        // Apply identical rules to programmatically built presets as imported ones.
        Self::decode(&result)?;
        Ok(result)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn windows_bom_and_outer_whitespace_are_accepted() {
        let raw = "SHODAN-PRESET 1\nkind full\nname 54657374\neditor equipment\nvalue FFFFFFFFFFFFFFFF slot1_strength 2.5\n";
        assert_eq!(
            Preset::decode(raw).unwrap(),
            Preset::decode(&format!("\u{feff}\r\n{raw}\r\n")).unwrap()
        );
    }
    #[test]
    fn legacy_roundtrip_preserves_unicode_hash_and_armor_values() {
        let input=format!("SHODAN-PRESET 1\r\nkind full\r\nname {}\r\neditor equipment\r\narmor {}\r\nvalue FFFFFFFFFFFFFFFF slot1_strength -2.5\r\n",hex("中文 English"),hex("被动数值配置"));
        let preset = Preset::decode(&input).unwrap();
        assert_eq!(preset.name, "中文 English");
        assert_eq!(preset.values[0].owner, "FFFFFFFFFFFFFFFF");
        assert_eq!(Preset::decode(&preset.encode().unwrap()).unwrap(), preset);
    }
    #[test]
    fn rejects_ambiguous_and_nonfinite_values_without_dropping_parameters() {
        let head = "SHODAN-PRESET 1\nkind weapon\nname 41\nweapon 0000000000000001\n";
        for tail in [
            "kind full\n",
            "value 0000000000000002 mass 1\n",
            "value 0000000000000001 mass NaN\n",
            "value 0000000000000001 mass 1\nvalue 0000000000000001 mass 2\n",
            "unknown a\n",
        ] {
            assert!(Preset::decode(&(head.to_string() + tail)).is_err());
        }
    }
}
