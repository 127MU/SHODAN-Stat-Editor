//! Optional loopback MCP transport sharing the native editor session.
//! No filesystem IPC, browser origins, remote bind or unauthenticated calls.
use crate::native_api::Api;
use crypto_box::aead::rand_core::{OsRng, RngCore};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    io::{BufReader, Read, Write},
    net::{TcpListener, TcpStream},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};
pub const METHODS: &[&str] = &[
    "workspace-open",
    "workspace-close",
    "workspace-get",
    "workspace-read-batch",
    "workspace-apply",
    "workspace-restore",
    "workspace-undo",
    "workspace-redo",
    "workspace-history",
    "workspace-preview",
    "workspace-export-copy",
    "update-parse",
    "update-start",
    "update-poll",
    "info",
    "open",
    "close",
    "index",
    "schema",
    "get",
    "set",
    "restore",
    "preview",
    "apply-batch",
    "history",
    "undo",
    "redo",
    "export-copy",
    "preset-inspect",
    "bind-parameter",
    "preset-compare",
    "preset-apply-values",
    "armor-open",
    "armor-assign-preview",
    "armor-assign-export-copy",
    "armor-rows",
    "armor-set",
    "armor-capture",
    "armor-apply-snapshot",
    "armor-export-copy",
    "armor-profiles-get",
    "armor-profiles-load",
    "armor-profiles-update",
    "armor-profiles-remove",
    "armor-profiles-clear",
    "armor-profiles-export-copy",
    "armor-state-capture",
    "armor-state-apply",
    "armor-compose-preview",
    "armor-compose-export-copy",
    "armor-history",
    "armor-undo",
    "armor-redo",
    "diagnostic-scrub",
    "package-inspect",
    "package-rebuild-copy",
    "bundle-inspect",
    "bundle-package-inspect",
    "bundle-patch-preview",
    "references",
    "reference-files",
    "residency-plan",
    "resource-scan",
    "resources-resolve",
    "dependency-closure",
];
pub struct Server {
    alive: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
    pub port: u16,
    secret: String,
}
impl Server {
    pub fn start(api: Arc<Mutex<Api>>) -> Result<Self, String> {
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
            .map_err(|_| "无法启动本地 MCP 服务")?;
        let port = listener
            .local_addr()
            .map_err(|_| "无法读取 MCP 端口")?
            .port();
        listener
            .set_nonblocking(true)
            .map_err(|_| "无法设置 MCP 服务")?;
        let mut bytes = [0; 32];
        OsRng
            .try_fill_bytes(&mut bytes)
            .map_err(|_| "无法生成 MCP 连接密钥")?;
        let secret: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        let alive = Arc::new(AtomicBool::new(true));
        let running = alive.clone();
        let token = secret.clone();
        let worker = thread::spawn(move || {
            while running.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((mut client, _)) => {
                        // Windows may inherit the listening socket's nonblocking
                        // mode. A split header/body must wait for the body.
                        if client.set_nonblocking(false).is_err() {
                            continue;
                        }
                        let _ = client.set_read_timeout(Some(Duration::from_secs(2)));
                        let _ = client.set_write_timeout(Some(Duration::from_secs(2)));
                        handle(&mut client, port, &token, &api, &running);
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(10))
                    }
                    Err(_) => break,
                }
            }
        });
        Ok(Self {
            alive,
            worker: Some(worker),
            port,
            secret,
        })
    }
    pub fn config(&self) -> Value {
        json!({"mcpServers":{"shodan":{"type":"http","url":format!("http://127.0.0.1:{}/mcp",self.port),"headers":{"Authorization":format!("Bearer {}",self.secret)}}}})
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.alive.store(false, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
fn reply(client: &mut TcpStream, status: u16, body: &str) {
    let _ = write!(client,"HTTP/1.1 {status} Response\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n{body}",body.len());
}
fn equal(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut mismatch = 0;
    for (a, b) in a.iter().zip(b) {
        mismatch |= a ^ b;
    }
    std::hint::black_box(mismatch) == 0
}
fn request(client: &mut TcpStream, port: u16, secret: &str) -> Result<Value, u16> {
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut reader = BufReader::new(client);
    let mut header = Vec::new();
    while !header.ends_with(b"\r\n\r\n") {
        if header.len() >= 16384 {
            return Err(413);
        }
        if Instant::now() > deadline {
            return Err(408);
        }
        let mut byte = [0];
        reader.read_exact(&mut byte).map_err(|_| 400u16)?;
        header.push(byte[0]);
    }
    let header = std::str::from_utf8(&header).map_err(|_| 400u16)?;
    let mut lines = header.split("\r\n");
    let first: Vec<_> = lines.next().ok_or(400u16)?.split_whitespace().collect();
    if first.len() != 3 || first[2] != "HTTP/1.1" {
        return Err(400);
    }
    if first[1] != "/mcp" {
        return Err(404);
    }
    if first[0] != "POST" {
        return Err(405);
    }
    let mut headers = BTreeMap::new();
    for line in lines.filter(|l| !l.is_empty()) {
        let (key, value) = line.split_once(':').ok_or(400u16)?;
        if headers
            .insert(key.to_ascii_lowercase(), value.trim().to_string())
            .is_some()
        {
            return Err(400);
        }
    }
    let get = |key| headers.get(key).map_or("", String::as_str);
    let host = format!("127.0.0.1:{port}");
    let localhost = format!("localhost:{port}");
    let mut denied = None;
    if ![host.as_str(), localhost.as_str()].contains(&get("host")) {
        denied = Some(403);
    }
    if headers.contains_key("origin")
        && ![format!("http://{host}"), format!("http://{localhost}")]
            .contains(&get("origin").to_string())
    {
        denied = Some(403);
    }
    if !equal(
        get("authorization").as_bytes(),
        format!("Bearer {secret}").as_bytes(),
    ) {
        if denied.is_none() {
            denied = Some(401);
        }
    }
    if headers.contains_key("transfer-encoding")
        || get("content-type").split(';').next().unwrap_or("").trim() != "application/json"
    {
        return Err(400);
    }
    let length = get("content-length");
    if length.is_empty() || !length.bytes().all(|c| c.is_ascii_digit()) {
        return Err(400);
    }
    let length: usize = length.parse().map_err(|_| 413u16)?;
    if length > 8 * 1024 * 1024 {
        return Err(413);
    }
    let mut body = vec![0; length];
    // Consume bounded request bodies before replying to a rejected request.
    // Closing Windows TCP sockets with unread data can reset the connection and
    // discard the response body, turning a clear 401/403 into a connection error.
    for chunk in body.chunks_mut(8192) {
        if Instant::now() > deadline {
            return Err(408);
        }
        reader.read_exact(chunk).map_err(|_| 400u16)?;
    }
    if let Some(status) = denied {
        return Err(status);
    }
    serde_json::from_slice(&body).map_err(|_| 422)
}
fn rpc_error(id: Value, code: i32, message: &str) -> Value {
    json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}})
}
fn handle(
    client: &mut TcpStream,
    port: u16,
    secret: &str,
    api: &Arc<Mutex<Api>>,
    alive: &AtomicBool,
) {
    let request = match request(client, port, secret) {
        Ok(v) => v,
        Err(status) => {
            eprintln!("@shodan-mcp HTTP 请求被拒绝：{status}");
            if status == 422 {
                reply(
                    client,
                    200,
                    &rpc_error(Value::Null, -32700, "JSON 格式无效").to_string(),
                );
            } else {
                reply(client, status, "{}");
            }
            return;
        }
    };
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    if !request.is_object() || request["jsonrpc"] != "2.0" || !request["method"].is_string() {
        reply(client, 200, &rpc_error(id, -32600, "无效请求").to_string());
        return;
    }
    if request.get("id").is_none() {
        reply(client, 202, "");
        return;
    }
    let result = match request["method"].as_str().unwrap() {
        "initialize" => {
            json!({"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"SHODAN Native","version":env!("CARGO_PKG_VERSION")},"instructions":"工具共享当前原生编辑会话；仅提供已实现接口，参数和导出文件路径需明确指定。"})
        }
        "ping" => json!({}),
        "tools/list" => {
            json!({"tools":[{"name":"shodan_native_call","description":"调用 Rust 原生数据接口，编辑与界面共享同一会话。export-copy 等导出接口会创建文件；不会隐式安装游戏。","inputSchema":{"type":"object","properties":{"method":{"type":"string","enum":METHODS},"params":{"type":"object"}},"required":["method","params"],"additionalProperties":false}}]})
        }
        "tools/call" => {
            let args = &request["params"]["arguments"];
            if request["params"]["name"] != "shodan_native_call"
                || !METHODS.contains(&args["method"].as_str().unwrap_or(""))
                || !args["params"].is_object()
            {
                reply(
                    client,
                    200,
                    &rpc_error(id, -32602, "工具或参数无效").to_string(),
                );
                return;
            }
            if !alive.load(Ordering::Acquire) {
                reply(client, 503, "{}");
                return;
            }
            let outcome = match api.try_lock() {
                Ok(mut api) => api.invoke(args),
                Err(_) => Err("数据引擎忙，请稍后重试".into()),
            };
            match outcome {
                Ok(value) => {
                    json!({"content":[{"type":"text","text":value.to_string()}],"isError":false})
                }
                Err(e) => json!({"content":[{"type":"text","text":e}],"isError":true}),
            }
        }
        _ => {
            reply(
                client,
                200,
                &rpc_error(id, -32601, "未提供此方法").to_string(),
            );
            return;
        }
    };
    reply(
        client,
        200,
        &json!({"jsonrpc":"2.0","id":id,"result":result}).to_string(),
    );
}
