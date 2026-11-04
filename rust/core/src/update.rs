//! Release metadata only: no Lua/DLL helper, installer execution or game traffic.
use serde_json::{json, Value};
const REPO: &str = "127MU/SHODAN-Stat-Editor";
pub fn open_link(url: &str) -> Result<(), String> {
    let prefix = format!("https://github.com/{REPO}/releases/");
    let tail = url.strip_prefix(&prefix).ok_or("更新链接与项目不匹配")?;
    if url.len() > 4096 || url.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err("更新链接格式无效".into());
    }
    if let Some(tag) = tail.strip_prefix("tag/") {
        version(tag)?;
    } else if let Some(download) = tail.strip_prefix("download/") {
        let (tag, file) = download.split_once('/').ok_or("下载链接格式无效")?;
        version(tag)?;
        if file.is_empty()
            || file.contains(['/', '\\', '?', '#'])
            || !file.to_ascii_lowercase().ends_with(".exe")
        {
            return Err("下载链接格式无效".into());
        }
    } else {
        return Err("未提供此更新链接类型".into());
    }
    open_browser(url)
}
#[cfg(not(windows))]
fn open_browser(_: &str) -> Result<(), String> {
    Err("当前平台尚未提供打开更新链接功能".into())
}
#[cfg(windows)]
fn open_browser(url: &str) -> Result<(), String> {
    use std::{ffi::c_void, ptr};
    #[link(name = "shell32")]
    unsafe extern "system" {
        fn ShellExecuteW(
            window: *mut c_void,
            verb: *const u16,
            file: *const u16,
            params: *const u16,
            directory: *const u16,
            show: i32,
        ) -> isize;
    }
    let wide = |s: &str| s.encode_utf16().chain(Some(0)).collect::<Vec<_>>();
    let result = unsafe {
        ShellExecuteW(
            ptr::null_mut(),
            wide("open").as_ptr(),
            wide(url).as_ptr(),
            ptr::null(),
            ptr::null(),
            1,
        )
    };
    if result <= 32 {
        return Err(format!("无法打开更新链接（{result}）"));
    }
    Ok(())
}
fn version(text: &str) -> Result<[u32; 4], String> {
    let text = text.strip_prefix('v').unwrap_or(text);
    let (base, revision) = text.split_once("-r").unwrap_or((text, "0"));
    let parts = base
        .split('.')
        .map(str::parse::<u32>)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| "版本号无效")?;
    if parts.len() != 3 || revision.is_empty() || !revision.bytes().all(|b| b.is_ascii_digit()) {
        return Err("版本号无效".into());
    }
    Ok([
        parts[0],
        parts[1],
        parts[2],
        revision.parse().map_err(|_| "版本修订号无效")?,
    ])
}
pub fn parse(body: &str, current: &str) -> Result<Value, String> {
    if body.len() > 1024 * 1024 {
        return Err("更新信息过大".into());
    }
    let release: Value = serde_json::from_str(body).map_err(|_| "发行版信息格式无效")?;
    if release["draft"] == true || release["prerelease"] == true {
        return Err("获取到的不是正式发行版".into());
    }
    let tag = release["tag_name"].as_str().ok_or("发行版没有版本号")?;
    let newer = version(tag)? > version(current)?;
    let url = format!("https://github.com/{REPO}/releases/tag/{tag}");
    if release["html_url"].as_str() != Some(&url) {
        return Err("发行版地址与项目不匹配".into());
    }
    let prefix = format!("https://github.com/{REPO}/releases/download/{tag}/");
    let preferred = format!("SHODAN_{}.exe", tag.strip_prefix('v').unwrap_or(tag));
    let mut assets = Vec::new();
    for asset in release["assets"].as_array().ok_or("发行版缺少文件清单")? {
        let Some(name) = asset["name"].as_str() else {
            continue;
        };
        let Some(link) = asset["browser_download_url"].as_str() else {
            continue;
        };
        if !name.to_ascii_lowercase().ends_with(".exe") || !link.starts_with(&prefix) {
            continue;
        }
        let tail = &link[prefix.len()..];
        if tail.is_empty()
            || tail.contains(['/', '\\', '?', '#', '\r', '\n'])
            || !tail.to_ascii_lowercase().ends_with(".exe")
        {
            continue;
        }
        assets.push((name != preferred, name.to_owned(), link.to_owned()));
    }
    assets.sort();
    Ok(
        json!({"version":tag,"current":current,"newer":newer,"url":url,"notes":release["body"].as_str().unwrap_or(""),"download_url":assets.first().map(|a|&a.2),"source":"github"}),
    )
}
pub fn check(current: &str) -> Result<Value, String> {
    version(current)?;
    let path = format!("/repos/{REPO}/releases/latest");
    let mut failures = Vec::new();
    for (host, path, mirror) in [
        ("api.github.com".to_string(), path.clone(), false),
        (
            "gh-proxy.com".to_string(),
            format!("/https://api.github.com{path}"),
            true,
        ),
    ] {
        match get(&host, &path).and_then(|(status, body)| {
            if status == 200 {
                parse(&body, current)
            } else {
                Err(format!("HTTP {status}"))
            }
        }) {
            Ok(mut result) => {
                if mirror {
                    result["source"] = json!("gh-proxy");
                    result["mirror_notice"] =
                        json!("通过 GH-Proxy 获取公开更新信息，发行版仍来自项目仓库。");
                }
                return Ok(result);
            }
            Err(e) => failures.push(format!("{host}：{e}")),
        }
    }
    Err(format!("检查更新失败；{}", failures.join("；")))
}
#[cfg(not(windows))]
fn get(_: &str, _: &str) -> Result<(u32, String), String> {
    Err("当前平台尚未提供 HTTPS 更新传输".into())
}
#[cfg(windows)]
fn get(host: &str, path: &str) -> Result<(u32, String), String> {
    use std::{ffi::c_void, ptr};
    type H = *mut c_void;
    #[link(name = "winhttp")]
    unsafe extern "system" {
        fn WinHttpOpen(
            agent: *const u16,
            access: u32,
            proxy: *const u16,
            bypass: *const u16,
            flags: u32,
        ) -> H;
        fn WinHttpConnect(session: H, host: *const u16, port: u16, reserved: u32) -> H;
        fn WinHttpOpenRequest(
            connection: H,
            verb: *const u16,
            path: *const u16,
            version: *const u16,
            referer: *const u16,
            accept: *const *const u16,
            flags: u32,
        ) -> H;
        fn WinHttpSetTimeouts(
            handle: H,
            resolve: i32,
            connect: i32,
            send: i32,
            receive: i32,
        ) -> i32;
        fn WinHttpSetOption(handle: H, option: u32, buffer: *mut c_void, len: u32) -> i32;
        fn WinHttpSendRequest(
            handle: H,
            headers: *const u16,
            len: u32,
            data: *mut c_void,
            data_len: u32,
            total: u32,
            context: usize,
        ) -> i32;
        fn WinHttpReceiveResponse(handle: H, reserved: *mut c_void) -> i32;
        fn WinHttpQueryHeaders(
            handle: H,
            info: u32,
            name: *const u16,
            buffer: *mut c_void,
            len: *mut u32,
            index: *mut u32,
        ) -> i32;
        fn WinHttpReadData(handle: H, buffer: *mut c_void, len: u32, read: *mut u32) -> i32;
        fn WinHttpCloseHandle(handle: H) -> i32;
    }
    struct Handle(H);
    impl Drop for Handle {
        fn drop(&mut self) {
            unsafe {
                WinHttpCloseHandle(self.0);
            }
        }
    }
    let handle = |p: H| {
        if p.is_null() {
            Err(format!(
                "网络初始化失败（{}）",
                std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
            ))
        } else {
            Ok(Handle(p))
        }
    };
    let wide = |s: &str| s.encode_utf16().chain(Some(0)).collect::<Vec<_>>();
    unsafe {
        let session = handle(WinHttpOpen(
            wide(concat!("SHODAN-Native-Update/", env!("CARGO_PKG_VERSION"))).as_ptr(),
            4,
            ptr::null(),
            ptr::null(),
            0,
        ))?;
        if WinHttpSetTimeouts(session.0, 2500, 3000, 5000, 5000) == 0 {
            return Err("无法设置网络超时".into());
        }
        let connection = handle(WinHttpConnect(session.0, wide(host).as_ptr(), 443, 0))?;
        let request = handle(WinHttpOpenRequest(
            connection.0,
            wide("GET").as_ptr(),
            wide(path).as_ptr(),
            ptr::null(),
            ptr::null(),
            ptr::null(),
            0x00800000,
        ))?;
        let mut never_redirect = 0u32;
        if WinHttpSetOption(request.0, 88, &mut never_redirect as *mut _ as _, 4) == 0 {
            return Err("无法限制更新重定向".into());
        }
        let headers =
            wide("Accept: application/vnd.github+json\r\nX-GitHub-Api-Version: 2022-11-28\r\n");
        if WinHttpSendRequest(
            request.0,
            headers.as_ptr(),
            u32::MAX,
            ptr::null_mut(),
            0,
            0,
            0,
        ) == 0
            || WinHttpReceiveResponse(request.0, ptr::null_mut()) == 0
        {
            return Err(format!(
                "连接失败（{}）",
                std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
            ));
        }
        let mut status = 0u32;
        let mut len = 4;
        if WinHttpQueryHeaders(
            request.0,
            19 | 0x20000000,
            ptr::null(),
            &mut status as *mut _ as _,
            &mut len,
            ptr::null_mut(),
        ) == 0
        {
            return Err("无法读取更新响应状态".into());
        }
        if status != 200 {
            return Ok((status, String::new()));
        }
        let mut body = Vec::new();
        let mut buffer = [0u8; 16384];
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
        loop {
            if std::time::Instant::now() > deadline {
                return Err("读取更新信息超时".into());
            }
            let mut n = 0;
            if WinHttpReadData(
                request.0,
                buffer.as_mut_ptr() as _,
                buffer.len() as u32,
                &mut n,
            ) == 0
            {
                return Err("读取更新信息失败".into());
            }
            if n == 0 {
                break;
            }
            if body.len() + n as usize > 1024 * 1024 {
                return Err("更新信息过大".into());
            }
            body.extend_from_slice(&buffer[..n as usize]);
        }
        Ok((
            status,
            String::from_utf8(body).map_err(|_| "更新信息不是 UTF-8")?,
        ))
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn revisions_notes_and_asset_validation() {
        let mut data = json!({"tag_name":"v4.6.0-r2","html_url":format!("https://github.com/{REPO}/releases/tag/v4.6.0-r2"),"body":"更新日志\n修复被动","assets":[{"name":"SHODAN_4.6.0-r2.exe","browser_download_url":format!("https://github.com/{REPO}/releases/download/v4.6.0-r2/SHODAN_4.6.0-r2.exe")}]});
        let r = parse(&data.to_string(), "4.6.0-r1").unwrap();
        assert_eq!(r["newer"], true);
        assert_eq!(r["notes"], "更新日志\n修复被动");
        assert!(r["download_url"].is_string());
        assert_eq!(parse(&data.to_string(), "4.6.1").unwrap()["newer"], false);
        data["assets"][0]["browser_download_url"] = json!("https://example.com/malware.exe");
        assert!(parse(&data.to_string(), "4.6.0").unwrap()["download_url"].is_null());
        data["html_url"] = json!("https://example.com");
        assert!(parse(&data.to_string(), "4.6.0").is_err());
        assert!(version("v4.6.0<script>").is_err());
    }
    #[test]
    fn foreign_or_malformed_links_never_reach_the_browser() {
        for url in [
            "file:///C:/bad.exe",
            "https://example.com/download.exe",
            "https://github.com/127MU/SHODAN-Stat-Editor/releases/tag/v4.6.0?next=bad",
            "https://github.com/127MU/SHODAN-Stat-Editor/releases/download/v4.6.0/bad.exe/extra",
        ] {
            assert!(open_link(url).is_err());
        }
    }
}
