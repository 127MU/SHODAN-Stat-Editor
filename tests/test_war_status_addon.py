"""Offline mitmproxy hook/transform regression. Never opens network listeners."""
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
import os
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("war_status_addon", Path(__file__).resolve().parents[1]/"offline/war_status_addon.py")
addon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(addon)
PLAN = {"targets": [{"planet": 182, "variant": "test"}], "variants": {"test": [1373, 1386]}}
BASE = {"planetStatus": [{"index": 182}], "planetActiveEffects": [], "unchanged": {"owner": 4}}


def flow(path, document, host=addon.HOST, method="GET"):
    return SimpleNamespace(request=SimpleNamespace(pretty_host=host, path=path, method=method),
                           response=SimpleNamespace(status_code=200, content=json.dumps(document).encode(), headers={"etag": "old"}))


class TestWarStatusAddon(unittest.TestCase):
    def ready(self):
        instance = addon.WarStatusAddon()
        instance.plan = PLAN
        instance.response(flow("/api/WarSeason/GalacticWarEffects", {"galacticEffects": [{"id": 1373}, {"id": 1386}]}))
        return instance

    def test_add_only_and_deduplicate(self):
        original = json.dumps(BASE)
        changed, count = addon.rewrite_status(BASE, PLAN, {1373, 1386})
        self.assertEqual(count, 2)
        self.assertEqual(json.dumps(BASE), original)
        self.assertEqual(changed["unchanged"], BASE["unchanged"])
        self.assertEqual(addon.rewrite_status(changed, PLAN, {1373, 1386})[1], 0)

    def test_unknown_effect_is_atomic(self):
        with self.assertRaises(ValueError):
            addon.rewrite_status(BASE, PLAN, {1373})
        self.assertEqual(BASE["planetActiveEffects"], [])

    def test_bad_schema(self):
        for document in ({}, [], dict(BASE, planetActiveEffects=[{}]), dict(BASE, planetStatus=[])):
            with self.assertRaises(ValueError):
                addon.rewrite_status(document, PLAN, {1373, 1386})

    def test_new_war_and_query(self):
        instance = self.ready()
        f = flow("/api/WarSeason/9999/Status?x=1", BASE)
        instance.response(f)
        self.assertEqual(instance.rewrites, 1)
        self.assertEqual(len(json.loads(f.response.content)["planetActiveEffects"]), 2)
        self.assertNotIn("etag", f.response.headers)

    def test_never_rewrites_requests_or_other_paths(self):
        instance = self.ready()
        for path, host, method in [("/api/Account", addon.HOST, "GET"), ("/api/WarSeason/801/Status", "example.com", "GET"), ("/api/WarSeason/801/Status", addon.HOST, "POST")]:
            f = flow(path, BASE, host, method)
            original = f.response.content
            instance.response(f)
            self.assertEqual(f.response.content, original)
        self.assertEqual(instance.rewrites, 0)

    def test_requires_fresh_catalog(self):
        instance = addon.WarStatusAddon()
        instance.plan = PLAN
        f = flow("/api/WarSeason/801/Status", BASE)
        original = f.response.content
        instance.response(f)
        self.assertEqual(f.response.content, original)

    def test_rejects_broken_new_catalog(self):
        instance = self.ready()
        instance.response(flow("/api/WarSeason/GalacticWarEffects", {"galacticEffects": [{}]}))
        self.assertIsNone(instance.allowed)

    def test_malformed_status_fails_open(self):
        instance = self.ready()
        f = flow("/api/WarSeason/801/Status", BASE)
        f.response.content = b"not json"
        instance.response(f)
        self.assertEqual(f.response.content, b"not json")
        self.assertEqual(instance.rewrites, 0)

    def test_multiple_planets_and_disabled(self):
        plan = {"targets": [{"planet": 182, "effects": [1373]}, {"planet": 93, "effects": [1386]}, {"planet": 999, "effects": [999], "enabled": False}]}
        original = dict(BASE, planetStatus=[{"index": 182}, {"index": 93}])
        changed, count = addon.rewrite_status(original, plan, {1373, 1386})
        self.assertEqual(count, 2)
        self.assertEqual(changed["planetActiveEffects"], [{"index": 182, "galacticEffectId": 1373}, {"index": 93, "galacticEffectId": 1386}])
        plan["targets"][0]["enabled"] = False
        changed, count = addon.rewrite_status(original, plan, {1373, 1386})
        self.assertEqual(count, 1)
        self.assertEqual(changed["planetActiveEffects"][0]["index"], 93)

    def test_campaign_and_owner_without_effect_catalog(self):
        plan = {"targets": [{"planet": 182, "effects": [], "owner": 3, "campaign": True, "campaign_type": 2}]}
        original = dict(BASE, planetStatus=[{"index": 182, "owner": 4}], campaigns=[{"id": 10, "planetIndex": 93, "type": 0, "count": 4}])
        ids = {}
        changed, count = addon.rewrite_status(original, plan, None, ids)
        self.assertEqual(changed["planetStatus"][0]["owner"], 3)
        new = changed["campaigns"][-1]
        self.assertEqual((new["id"], new["planetIndex"], new["type"], new["race"]), (11, 182, 2, 3))
        self.assertEqual(addon.rewrite_status(original, plan, None, ids)[0]["campaigns"][-1]["id"], 11)
        self.assertEqual(original["planetStatus"][0]["owner"], 4)
        self.assertEqual(len(original["campaigns"]), 1)
        self.assertEqual(addon.rewrite_status(changed, plan, None, ids)[1], 0)

    def test_campaign_existing_and_collision(self):
        plan = {"targets": [{"planet": 182, "effects": [], "campaign": True, "campaign_type": 3}]}
        original = dict(BASE, campaigns=[{"id": 90, "planetIndex": 182, "type": 0, "count": 4, "keep": "preserved"}])
        changed, _ = addon.rewrite_status(original, plan, None)
        self.assertEqual(changed["campaigns"], [{"id": 90, "planetIndex": 182, "type": 3, "count": 4, "keep": "preserved"}])
        original["campaigns"][0]["planetIndex"] = 93
        changed, _ = addon.rewrite_status(original, plan, None, {182: 90})
        self.assertEqual(changed["campaigns"][-1]["id"], 91)

    def test_cyberstan_native_bots_are_not_replaced_with_terminids(self):
        original={'planetStatus':[{'index':260,'owner':1}], 'planetActiveEffects':[{'index':260,'galacticEffectId':1361}], 'campaigns':[]}
        plan={'targets':[{'planet':260,'effects':[],'owner':1,'campaign':True}]}
        changed,_=addon.rewrite_status(original,plan,None)
        self.assertEqual(changed['campaigns'][0]['race'],3)
        self.assertEqual(changed['planetStatus'][0]['owner'],1)
        # Adding a cross-faction effect must not change native inference.
        plan['targets'][0]['effects']=[1373]
        changed,_=addon.rewrite_status(original,plan,{1373})
        self.assertEqual(changed['campaigns'][0]['race'],3)
        plan['targets'][0]['campaign_race']=4
        changed,_=addon.rewrite_status(original,plan,{1373})
        self.assertEqual(changed['campaigns'][0]['race'],4)
        self.assertEqual(addon.rewrite_status(changed,plan,{1373})[1],0)
        self.assertFalse(original['campaigns'])

    def test_owner_change_keeps_original_enemy_for_new_campaign(self):
        original={'planetStatus':[{'index':93,'owner':4}], 'planetActiveEffects':[], 'campaigns':[]}
        plan={'targets':[{'planet':93,'effects':[],'owner':1,'campaign':True}]}
        changed,_=addon.rewrite_status(original,plan,None)
        self.assertEqual(changed['campaigns'][0]['race'],4)
        original['planetStatus'][0]['owner']=1
        changed,_=addon.rewrite_status(original,plan,None)
        self.assertEqual(changed['campaigns'][0]['race'],1)

    def test_owner_without_opening_campaign(self):
        plan={"targets":[{"planet":182,"effects":[],"owner":3}]}
        original=dict(BASE,campaigns=[{"id":90,"planetIndex":182,"type":2,"count":4,"race":4}])
        changed,_=addon.rewrite_status(original,plan,None)
        self.assertEqual(len(changed["campaigns"]),1)
        self.assertEqual(changed["campaigns"][0],{"id":90,"planetIndex":182,"type":2,"count":4,"race":3})

    def test_bad_plan_rejected(self):
        for targets in ([{"planet": 182, "effects": [True]}], [{"planet": 182, "effects": [], "owner": 9}], [{"planet": 182, "effects": [], "campaign_type": 4}], [{"planet": 182, "effects": []}]*2):
            with self.assertRaises(ValueError):
                addon.normalize_targets({"targets": targets})

    def test_verified_effect_pair_is_written_with_campaign(self):
        instance = self.ready()
        instance.plan = {'targets':[{'planet':182,'effects':[1308],'campaign':True,'campaign_type':0,'owner':2}]}
        instance.response(flow('/api/WarSeason/GalacticWarEffects', {'galacticEffects':[
            {'id':1307,'effectType':40},{'id':1308,'effectType':71}]}))
        f=flow('/api/WarSeason/801/Status',dict(BASE,campaigns=[]))
        instance.response(f)
        result=json.loads(f.response.content)
        self.assertEqual({e['galacticEffectId'] for e in result['planetActiveEffects']},{1307,1308})
        self.assertEqual(result['campaigns'][0]['planetIndex'],182)
        self.assertEqual(result['campaigns'][0]['type'],0)
        self.assertGreater(result['campaigns'][0]['count'],0)
        self.assertEqual(instance.plan['targets'][0]['effects'],[1308])

    def test_pair_requires_both_ids_and_verified_types(self):
        plan={'targets':[{'planet':182,'effects':[1308]}]}
        for allowed,types in [({1308},{1308:71}),({1307,1308},{1307:72,1308:71})]:
            result,_=addon.rewrite_status(BASE,plan,allowed,effect_types=types)
            self.assertEqual(result['planetActiveEffects'],[{'index':182,'galacticEffectId':1308}])

    def test_opening_zero_count_campaign(self):
        plan={'targets':[{'planet':182,'effects':[],'campaign':True}]}
        original=dict(BASE,campaigns=[{'id':10,'planetIndex':182,'type':0,'count':0}])
        result,count=addon.rewrite_status(original,plan,None)
        self.assertEqual(result['campaigns'][0]['count'],1)
        self.assertGreater(count,0)
        self.assertEqual(original['campaigns'][0]['count'],0)

    def test_only_status_cache_validators_are_removed(self):
        instance=addon.WarStatusAddon()
        f=flow('/api/WarSeason/801/Status',BASE)
        f.request.headers={'if-none-match':'old','if-modified-since':'old','authorization':'keep'}
        instance.request(f)
        self.assertEqual(f.request.headers,{'authorization':'keep','cache-control':'no-cache'})
        f.request.path='/api/Account'
        f.request.headers={'if-none-match':'keep','authorization':'keep'}
        instance.request(f)
        self.assertEqual(f.request.headers,{'if-none-match':'keep','authorization':'keep'})

    def test_observe_only(self):
        result, count = addon.rewrite_status(BASE, {"targets": []}, None)
        self.assertIs(result, BASE)
        self.assertEqual(count, 0)

    def test_bad_catalog_cannot_reuse_previous(self):
        instance = self.ready()
        f = flow("/api/WarSeason/GalacticWarEffects", {})
        f.response.content = b"bad json"
        instance.response(f)
        self.assertIsNone(instance.allowed)

    def test_live_reload_and_private_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);p=root/"plan.json"
            config={"schema":2,"targets":[{"planet":182,"effects":[1373]}],"health_path":str(root/"health.json")}
            p.write_text(json.dumps(config),encoding="utf8")
            instance=addon.WarStatusAddon()
            with patch.dict(os.environ,{"SHODAN_WAR_PLAN":str(p)}):instance.load(None)
            catalog=flow("/api/WarSeason/GalacticWarEffects",{"galacticEffects":[{"id":1373,"effectType":71,"accountId":"must-not-cache","values":["must-not-cache"]},{"id":1386,"effectType":71}]})
            instance.response(catalog)
            status=flow("/api/WarSeason/801/Status",dict(BASE,accountId="must-not-cache"))
            instance.response(status)
            self.assertEqual(json.loads(status.response.content)["planetActiveEffects"][0]["galacticEffectId"],1373)
            config["targets"][0]["effects"]=[1386]
            p.write_text(json.dumps(config),encoding="utf8");stamp=instance.plan_stamp+1000000000;os.utime(p,ns=(stamp,stamp))
            status=flow("/api/WarSeason/801/Status",BASE);instance.response(status)
            self.assertEqual(json.loads(status.response.content)["planetActiveEffects"][0]["galacticEffectId"],1386)
            for name in ("catalog.json","planets.json","health.json"):
                self.assertNotIn("must-not-cache",(root/name).read_text("utf8"))

    def test_disabling_live_target_stops_modification(self):
        instance=self.ready()
        instance.plan={"schema":2,"targets":[{"planet":182,"effects":[1373],"enabled":False}]}
        f=flow("/api/WarSeason/801/Status",BASE);original=f.response.content;instance.response(f)
        self.assertEqual(f.response.content,original)

    def test_live_ack_waits_for_successful_status_even_with_same_mtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);path=root/'plan.json'
            config={'targets':[{'planet':182,'effects':[1373]}],'health_path':str(root/'health.json')}
            path.write_text(json.dumps(config),encoding='utf8')
            instance=addon.WarStatusAddon()
            with patch.dict(os.environ,{'SHODAN_WAR_PLAN':str(path)}):instance.load(None)
            instance.response(flow('/api/WarSeason/GalacticWarEffects',{'galacticEffects':[{'id':1373},{'id':1386}]}))
            instance.response(flow('/api/WarSeason/801/Status',BASE))
            old=instance.applied_plan_digest
            stamp=instance.plan_stamp
            config['targets'][0]['effects']=[1386]
            path.write_text(json.dumps(config),encoding='utf8');os.utime(path,ns=(stamp,stamp))
            instance.tick()
            self.assertNotEqual(instance.plan_digest,old)
            self.assertEqual(instance.applied_plan_digest,old)
            instance.response(flow('/api/WarSeason/801/Status',{}))
            self.assertEqual(instance.applied_plan_digest,old)
            instance.response(flow('/api/WarSeason/801/Status',BASE))
            self.assertEqual(instance.applied_plan_digest,instance.plan_digest)

    def test_tls_diagnostics_do_not_log_credentials(self):
        instance=addon.WarStatusAddon()
        data=SimpleNamespace(context=SimpleNamespace(client=SimpleNamespace(sni=addon.HOST),server=SimpleNamespace(sni=addon.HOST)))
        instance.tls_failed_client(data);instance.tls_failed_server(data)
        self.assertEqual(instance.failures["client_tls"],1)
        self.assertEqual(instance.failures["server_tls"],1)
        other=SimpleNamespace(context=SimpleNamespace(client=SimpleNamespace(sni="example.com"),server=SimpleNamespace(sni="example.com")))
        instance.tls_failed_client(other)
        self.assertEqual(instance.failures["client_tls"],1)
        self.assertFalse(instance.ready)

    def test_connection_diagnostics_only_keep_categories(self):
        instance=addon.WarStatusAddon()
        data=SimpleNamespace(context=SimpleNamespace(client=SimpleNamespace(sni=addon.HOST,error="unknown ca https://secret:password@example.com/private"),server=SimpleNamespace(sni=addon.HOST)))
        instance.tls_failed_client(data)
        self.assertEqual(instance.connection['failure_kind'],'证书信任失败')
        self.assertNotIn('password',json.dumps(instance.connection))
        instance.tls_established_client(data);instance.tls_established_server(data)
        self.assertEqual(instance.connection['client_tls'],1)
        self.assertEqual(instance.connection['server_tls'],1)

    def test_http_failure_categories_hide_url_and_credentials(self):
        instance=addon.WarStatusAddon()
        failed=SimpleNamespace(request=SimpleNamespace(pretty_host=addon.HOST,method='GET',path='/api/WarSeason/801/Status?token=secret',http_version='HTTP/2'),error=SimpleNamespace(msg='HTTP/2 stream reset https://private:secret@example.com'))
        instance.error(failed)
        self.assertEqual(instance.connection['failure_kind'],'HTTP/2 流失败')
        self.assertEqual(instance.connection['failed_endpoint'],'战况接口')
        self.assertNotIn('secret',json.dumps(instance.connection))

    def test_api_router_bypasses_every_other_destination(self):
        import socket
        import socketserver
        import threading
        seen=[]
        class Echo(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.settimeout(3)
                data=self.request.recv(16384);seen.append(data)
                self.request.sendall(data)
        class Server(socketserver.ThreadingTCPServer):
            daemon_threads=True
        with Server(('127.0.0.1',0),Echo) as direct, Server(('127.0.0.1',0),Echo) as core:
            threads=[threading.Thread(target=s.serve_forever,daemon=True) for s in (direct,core)]
            for t in threads:t.start()
            router=addon.ApiOnlyRouter(core.server_address[1])
            try:
                with socket.create_connection(('127.0.0.1',router.port),timeout=3) as client:
                    client.sendall(('CONNECT 127.0.0.1:%s HTTP/1.1\r\n\r\n'%direct.server_address[1]).encode())
                    self.assertIn(b'200',client.recv(4096))
                    client.sendall(b'end-to-end-data');self.assertEqual(client.recv(4096),b'end-to-end-data')
                self.assertEqual(seen,[b'end-to-end-data'])
                with socket.create_connection(('127.0.0.1',router.port),timeout=3) as client:
                    client.sendall(('CONNECT '+addon.HOST+':443 HTTP/1.1\r\nProxy-Authorization: secret\r\n\r\n').encode())
                    data=client.recv(4096)
                    self.assertIn(addon.HOST.encode(),data);self.assertNotIn(b'secret',data)
                self.assertEqual(len(seen),2)
                with socket.create_connection(('127.0.0.1',router.port),timeout=3) as client:
                    client.sendall(('GET http://127.0.0.1:%s/update?q=1 HTTP/1.1\r\nHost: localhost\r\nProxy-Authorization: secret\r\n\r\n'%direct.server_address[1]).encode())
                    data=client.recv(4096)
                    self.assertTrue(data.startswith(b'GET /update?q=1 HTTP/1.1\r\n'))
                    self.assertNotIn(b'secret',data)
                self.assertEqual(len(seen),3)
            finally:
                router.close()
                for s in (direct,core):s.shutdown()

    def test_loaded_is_not_capture_ready(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);p=root/"plan.json";p.write_text(json.dumps({"targets":[],"health_path":str(root/"health.json")}),encoding="utf8")
            instance=addon.WarStatusAddon()
            with patch.dict(os.environ,{"SHODAN_WAR_PLAN":str(p)}):instance.load(None)
            self.assertFalse(json.loads((root/"health.json").read_text("utf8"))["ready"])


if __name__ == "__main__":
    unittest.main()
