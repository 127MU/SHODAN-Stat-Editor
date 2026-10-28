"""Narrow mitmproxy addon. Never persists HTTP bodies, credentials or account IDs."""
import json
import os
import re
import copy
import time
import hashlib
from pathlib import Path

HOST = "api.live.prod.thehelldiversgame.com"
STATUS = re.compile(r"^/api/WarSeason/[0-9]+/Status$")
MAX_BODY = 8 * 1024 * 1024
# Verified type40 tag/type71 presence pairs, war 801. Never infer by ID adjacency.
EFFECT_PAIRS = ((1202,1203),(1243,1245),(1244,1386),(1248,1249),(1303,1310),
                (1306,1309),(1307,1308),(1360,1361),(1377,1378),(1380,1379),
                (1401,1400),(1402,1403),(1413,1414))


class LocalRevocationService:
    """Serve only this session's CA-signed CRL on loopback, never files."""
    def __init__(self, certstore):
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        from threading import Thread
        from cryptography import x509
        crl = certstore.default_crl

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path != "/ca.crl":
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/pkix-crl")
                self.send_header("Content-Length", str(len(crl)))
                self.end_headers()
                self.wfile.write(crl)

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.url = "http://127.0.0.1:%s/ca.crl" % self.server.server_port
        try:
            entry = certstore.get_cert(HOST, [x509.DNSName(HOST)], crl_url=self.url)
            certstore.add_cert(entry, HOST)
            self.certificate = entry.cert.to_pem()
            self.thread = Thread(target=self.server.serve_forever, daemon=True)
            self.thread.start()
        except BaseException:
            self.server.server_close()
            raise

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


def normalize_targets(plan):
    if plan.get("schema", 2) != 2:
        raise ValueError("不支持的方案版本")
    targets = plan.get("targets")
    if not isinstance(targets, list) or len(targets) > 64:
        raise ValueError("方案最多包含 64 颗星球")
    result, seen = [], set()
    for raw in targets:
        if not isinstance(raw, dict):
            raise ValueError("星球配置无效")
        if type(raw.get("enabled", True)) is not bool:
            raise ValueError("星球开关必须是布尔值")
        if raw.get("enabled", True) is False:
            continue
        planet = raw.get("planet")
        if type(planet) is not int or not 0 <= planet <= 10000 or planet in seen:
            raise ValueError("星球索引无效或重复")
        seen.add(planet)
        effects = raw.get("effects")
        if effects is None:
            effects = plan.get("variants", {}).get(raw.get("variant"), [])
        if not isinstance(effects, list) or len(effects) > 32 or any(type(e) is not int or e <= 0 for e in effects):
            raise ValueError("效果配置无效")
        owner, campaign_type = raw.get("owner", 0), raw.get("campaign_type", 0)
        if type(owner) is not int or owner not in range(5) or type(campaign_type) is not int or campaign_type not in range(4):
            raise ValueError("阵营或战役类型无效")
        campaign = raw.get("campaign", False)
        if type(campaign) is not bool:
            raise ValueError("战役开关无效")
        result.append(dict(planet=planet, effects=list(dict.fromkeys(effects)), owner=owner, campaign=campaign, campaign_type=campaign_type))
    return result


def rewrite_status(document, plan, allowed, campaign_ids=None, effect_types=None):
    """Pure transformation; malformed/unknown schema must fail before mutation."""
    if not isinstance(document, dict):
        raise ValueError("战况响应不是对象，已保持原样")
    entries = document.get("planetActiveEffects")
    planets = document.get("planetStatus")
    if not isinstance(entries, list) or not isinstance(planets, list):
        raise ValueError("战况结构不兼容，已保持原样")
    if any(not isinstance(p, dict) or type(p.get("index")) is not int for p in planets):
        raise ValueError("星球条目结构不兼容，已保持原样")
    pairs = set()
    for entry in entries:
        if not isinstance(entry, dict) or type(entry.get("index")) is not int or type(entry.get("galacticEffectId")) is not int:
            raise ValueError("星球效果条目结构不兼容，已保持原样")
        pairs.add((entry["index"], entry["galacticEffectId"]))
    known_planets = {p["index"] for p in planets if isinstance(p, dict) and type(p.get("index")) is int}
    additions = []
    targets = normalize_targets(plan)
    # Both members must be present in this session's authoritative catalog and
    # retain their verified types. Cached display data never grants permission.
    if effect_types and allowed is not None:
        for target in targets:
            for tag, presence in EFFECT_PAIRS:
                if (tag in target['effects'] or presence in target['effects']) and effect_types.get(tag)==40 and effect_types.get(presence)==71 and tag in allowed and presence in allowed:
                    for eid in (tag, presence):
                        if eid not in target['effects']:
                            target['effects'].append(eid)
    campaigns = document.get("campaigns", [])
    if any(t["campaign"] or t["owner"] for t in targets) and (not isinstance(campaigns, list) or any(not isinstance(c, dict) or type(c.get("id")) is not int or type(c.get("planetIndex")) is not int for c in campaigns)):
        raise ValueError("战役结构不兼容，已保持原样")
    for target in targets:
        planet = target["planet"]
        if planet not in known_planets:
            raise ValueError("星球 #"+str(planet)+" 不在本次战况中，已保持原样")
        for effect in target["effects"]:
            if allowed is None or effect not in allowed:
                raise ValueError("效果 #"+str(effect)+" 不在本次战争目录中，已保持原样")
            if (planet, effect) not in pairs:
                additions.append({"index": planet, "galacticEffectId": effect})
                pairs.add((planet, effect))
    # Work on copies only: one bad target must never leave a partially changed body.
    result = copy.deepcopy(document)
    result["planetActiveEffects"] = entries + additions
    changes = len(additions)
    campaign_ids = campaign_ids if campaign_ids is not None else {}
    used_ids = {c["id"] for c in campaigns} if any(t["campaign"] or t["owner"] for t in targets) else set()
    for target in targets:
        planet = next(p for p in result["planetStatus"] if p.get("index") == target["planet"])
        if target["owner"] and planet.get("owner") != target["owner"]:
            planet["owner"] = target["owner"]
            changes += 1
        if target["owner"] in (2, 3, 4):
            for campaign in result.get("campaigns", []):
                if campaign["planetIndex"] == target["planet"] and campaign.get("race") != target["owner"]:
                    campaign["race"] = target["owner"]
                    changes += 1
        if target["campaign"]:
            current = next((c for c in result.get("campaigns", []) if c["planetIndex"] == target["planet"]), None)
            if current is None:
                candidate = campaign_ids.get(target["planet"])
                if candidate is None or candidate in used_ids:
                    candidate = max(used_ids | {0}) + 1
                if candidate >= 2**31:
                    raise ValueError("无法分配实验性战役编号")
                campaign_ids[target["planet"]] = candidate
                used_ids.add(candidate)
                current = {"id": candidate, "planetIndex": target["planet"], "type": target["campaign_type"], "count": 1, "race": target["owner"] or planet.get("owner", 2)}
                if current["race"] == 1:
                    current["race"] = 2
                result.setdefault("campaigns", []).append(current)
                changes += 1
            elif current.get("type") != target["campaign_type"]:
                current["type"] = target["campaign_type"]
                changes += 1
            if type(current.get('count')) is not int or current['count'] <= 0:
                current['count'] = 1
                changes += 1
            if target["owner"] in (2, 3, 4) and current.get("race") != target["owner"]:
                current["race"] = target["owner"]
                changes += 1
    return result if changes else document, changes


class WarStatusAddon:
    def __init__(self):
        self.plan = None
        self.allowed = None
        self.effect_types = {}
        self.rewrites = 0
        self.health_path = None
        self.plan_path = None
        self.plan_stamp = None
        self.plan_digest = None
        self.applied_plan_digest = None
        self.campaign_ids = {}
        self.statuses = 0
        self.catalog_count = 0
        self.war_id = None
        self.shutting_down = False
        self.ready = False
        self.revocation_service = None
        self.last_message = "插件已加载，捕获尚未就绪"
        self.failures = {"client_tls": 0, "server_tls": 0, "connect": 0, "http": 0}

    def health(self, message):
        self.last_message = message
        if not self.health_path:
            return
        try:
            target = Path(self.health_path)
            temporary = target.with_suffix(".tmp")
            temporary.write_text(json.dumps({"message": message, "ready": self.ready, "failures": self.failures, "rewrites": self.rewrites, "statuses": self.statuses, "catalog_count": self.catalog_count, "war_id": self.war_id, "applied_plan_digest": self.applied_plan_digest, "updated": time.time()}, ensure_ascii=False), encoding="utf-8")
            os.replace(temporary, target)
        except OSError:
            pass  # Diagnostics must not break forwarding.

    def load(self, loader):
        self.plan_path = Path(os.environ["SHODAN_WAR_PLAN"])
        self.plan = json.loads(self.plan_path.read_text(encoding="utf-8"))
        self.plan_digest = hashlib.sha256(self.plan_path.read_bytes()).hexdigest()
        normalize_targets(self.plan)
        self.plan_stamp = self.plan_path.stat().st_mtime_ns
        self.health_path = self.plan["health_path"]
        self.health("插件已加载，等待游戏获取效果目录")

    def snapshot(self, name, data):
        if self.health_path:
            target = Path(self.health_path).parent / name
            temporary = target.with_suffix(".tmp")
            try:
                temporary.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
                os.replace(temporary, target)
            except OSError:
                pass

    def reload_plan(self):
        if self.plan_path:
            raw = self.plan_path.read_bytes()
            digest = hashlib.sha256(raw).hexdigest()
            if digest == self.plan_digest:
                return
            candidate = json.loads(raw)
            normalize_targets(candidate)
            self.plan = candidate
            self.plan_stamp = self.plan_path.stat().st_mtime_ns
            self.plan_digest = digest
            self.health("方案已更新，等待下一次游戏战况刷新；当前地图和已生成作战可能仍使用缓存")

    def tick(self):
        # Shutdown is owned by this process' private profile directory, not a
        # network endpoint. Let the upstream core release its capture helper.
        if self.health_path and (Path(self.health_path).parent / "stop.request").exists() and not self.shutting_down:
            from mitmproxy import ctx
            self.shutting_down = True
            ctx.master.shutdown()
        if not self.shutting_down:
            try:
                self.reload_plan()
            except (ValueError, OSError) as error:
                self.health("新方案未通过校验，继续保留上次有效方案："+str(error)[:100])

    def request(self, flow):
        request = flow.request
        if request.method=='GET' and request.pretty_host.lower()==HOST and STATUS.fullmatch(request.path.split('?',1)[0]):
            # Only war status cache validators; authentication is untouched.
            for name in ('if-none-match', 'if-modified-since'):
                request.headers.pop(name, None)
            request.headers['cache-control']='no-cache'

    def running(self):
        import asyncio
        if os.environ.get("SHODAN_PREPARE_CA") == "1":
            from mitmproxy import ctx
            ctx.master.shutdown()
            return
        from mitmproxy import ctx
        self.revocation_service = LocalRevocationService(ctx.master.addons.get("tlsconfig").certstore)
        # Use the official custom-cert option so a later TLSConfig configure
        # event cannot replace our session certificate with one without a CDP.
        cert_path = self.plan_path.parent / "session-api-cert.pem"
        cert_path.write_bytes(self.revocation_service.certificate)
        ctx.options.update(certs=[HOST + "=" + str(cert_path)])
        self.ready = True
        self.health("捕获服务已就绪，等待游戏连接")
        async def watch():
            ticks = 0
            while not self.shutting_down:
                self.tick()
                ticks += 1
                if ticks % 20 == 0:
                    self.health(self.last_message)
                await asyncio.sleep(0.25)
        asyncio.create_task(watch())

    def done(self):
        self.shutting_down = True
        self.ready = False
        if self.revocation_service:
            self.revocation_service.close()
            self.revocation_service = None

    @staticmethod
    def api_tls(data):
        context = getattr(data, "context", None)
        client = getattr(context, "client", None)
        server = getattr(context, "server", None)
        return getattr(client, "sni", None) == HOST or getattr(server, "sni", None) == HOST

    def tls_failed_client(self, data):
        if self.api_tls(data):
            self.failures["client_tls"] += 1
            self.health("游戏 API 的客户端 TLS 握手失败；当前用户信任 CA 不代表游戏的 TLS 后端接受该 CA")

    def tls_failed_server(self, data):
        if self.api_tls(data):
            self.failures["server_tls"] += 1
            self.health("游戏 API 的上游 TLS 握手失败；未关闭服务器证书验证，请检查上游代理或路由")

    def server_connect_error(self, data):
        server = getattr(data, "server", None)
        address = getattr(server, "address", None)
        if getattr(server, "sni", None) == HOST or (address and address[0] == HOST):
            self.failures["connect"] += 1
            self.health("无法建立到游戏 API 的上游连接；请检查既有代理、TUN 或路由")

    def error(self, flow):
        request = getattr(flow, "request", None)
        if request and getattr(request, "pretty_host", "").lower() == HOST:
            self.failures["http"] += 1
            if request.method == "CONNECT":
                self.health("捕获到了既有 HTTP 代理的 CONNECT 隧道；透明捕获与现有代理链可能不兼容")
            else:
                self.health("游戏 API 的 HTTP 连接失败；尚未进行战况改写，请查看连接诊断计数")

    def response(self, flow):
        request, response = flow.request, flow.response
        if request.method != "GET" or request.pretty_host.lower() != HOST or response.status_code != 200:
            return
        path = request.path.split("?", 1)[0]
        if path != "/api/WarSeason/GalacticWarEffects" and not STATUS.fullmatch(path):
            return
        try:
            if path == "/api/WarSeason/GalacticWarEffects":
                self.allowed = None
                self.effect_types = {}
                self.catalog_count = 0
            raw = response.content
            if raw is None or len(raw) > MAX_BODY:
                raise ValueError("响应为空或过大，已保持原样")
            document = json.loads(raw)
            if path == "/api/WarSeason/GalacticWarEffects":
                rows = document.get("galacticEffects") if isinstance(document, dict) else document
                if not isinstance(rows, list) or not rows or any(not isinstance(r, dict) or type(r.get("id")) is not int for r in rows):
                    self.allowed = None
                    raise ValueError("效果目录结构不兼容，禁止改写")
                self.allowed = {r["id"] for r in rows}
                self.effect_types = {r['id']: r.get('effectType') for r in rows}
                self.catalog_count = len(rows)
                public = [{k: row[k] for k in ("id", "effectType", "nameHash", "descriptionGamePlayShortHash") if type(row.get(k)) is int} for row in rows]
                self.snapshot("catalog.json", {"effects": public, "updated": time.time()})
                self.health("已收到本次效果目录，等待战况响应")
                return
            self.reload_plan()
            war_id = int(path.split("/")[3])
            if self.war_id is not None and self.war_id != war_id:
                self.campaign_ids.clear()
            self.war_id = war_id
            self.statuses += 1
            planets = document.get("planetStatus", []) if isinstance(document, dict) else []
            public = [{k: p[k] for k in ("index", "owner", "health", "players") if type(p.get(k)) in (int, float)} for p in planets if isinstance(p, dict) and type(p.get("index")) is int]
            self.snapshot("planets.json", {"planets": public, "war_id": war_id, "updated": time.time()})
            if self.allowed is None and any(t["effects"] for t in normalize_targets(self.plan)):
                self.health("尚未获取本次效果目录，战况保持原样；请重新登录游戏")
                return
            changed, count = rewrite_status(document, self.plan, self.allowed, self.campaign_ids, self.effect_types)
            if count:
                response.content = json.dumps(changed, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
                for header in ("etag", "content-md5", "digest"):
                    response.headers.pop(header, None)
                self.rewrites += 1
            target_ids = {t['planet'] for t in normalize_targets(self.plan)}
            # Public structural diagnostics only, never Operation requests or accounts.
            self.snapshot('campaign-diagnostics.json', {'war_id': war_id, 'targets': [
                {'planet': pid, 'campaigns': [{k:c[k] for k in ('id','planetIndex','type','count','race') if k in c}
                  for c in changed.get('campaigns',[]) if c.get('planetIndex')==pid],
                 'effects': [e['galacticEffectId'] for e in changed.get('planetActiveEffects',[]) if e.get('index')==pid]}
                for pid in sorted(target_ids)], 'updated': time.time()})
            self.applied_plan_digest = self.plan_digest
            self.health("方案已应用到本次战况响应；已生成作战和局内效果仍需游戏验证")
        except (ValueError, KeyError, TypeError, UnicodeError, OSError) as error:
            self.health("校验未通过，响应保持原样："+str(error)[:140])


addons = [WarStatusAddon()]
