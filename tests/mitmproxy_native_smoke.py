"""Run with official mitmdump, a loopback port 0 and a temporary confdir.
Synthetic flows only: no game capture, outgoing requests, or certificate trust.
"""
import gzip
import importlib.util
import json
import os
from pathlib import Path
from mitmproxy import connection, ctx, http


class NativeSmoke:
    def running(self):
        report = Path(os.environ["SHODAN_NATIVE_REPORT"])
        try:
            spec = importlib.util.spec_from_file_location("shodan_addon", os.environ["SHODAN_NATIVE_ADDON"])
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            # Real certificate store and loopback-only CRL. No trust changes.
            from cryptography import x509
            from http.client import HTTPConnection
            from urllib.parse import urlsplit
            service = module.LocalRevocationService(ctx.master.addons.get("tlsconfig").certstore)
            try:
                leaf = x509.load_pem_x509_certificate(service.certificate)
                urls = leaf.extensions.get_extension_for_class(x509.CRLDistributionPoints).value
                assert urls[0].full_name[0].value == service.url
                address = urlsplit(service.url)
                client = HTTPConnection(address.hostname, address.port, timeout=3)
                client.request('GET', '/ca.crl')
                response = client.getresponse()
                assert response.status == 200
                crl = x509.load_der_x509_crl(response.read())
                assert crl.is_signature_valid(ctx.master.addons.get("tlsconfig").certstore.default_ca._cert.public_key())
                client.close()
                client = HTTPConnection(address.hostname, address.port, timeout=3)
                client.request('GET', '/private-key.pem')
                response = client.getresponse()
                assert response.status == 404
                response.read()
                client.close()
            finally:
                service.close()
            addon = module.WarStatusAddon()
            addon.plan = {"targets": [{"planet": 182, "variant": "test"}], "variants": {"test": [1373]}}

            def make(path, document):
                f = http.HTTPFlow(connection.Client(peername=("127.0.0.1", 1), sockname=("127.0.0.1", 2)), connection.Server(address=(module.HOST, 443)))
                f.request = http.Request.make("GET", "https://"+module.HOST+path)
                f.response = http.Response.make(200, b"", {"content-encoding": "gzip", "content-type": "application/json", "etag": "old"})
                f.response.content = json.dumps(document).encode()
                return f

            catalog = make("/api/WarSeason/GalacticWarEffects", {"galacticEffects": [{"id": 1373}]})
            addon.response(catalog)
            f = make("/api/WarSeason/9999/Status", {"planetStatus": [{"index": 182}], "planetActiveEffects": []})
            addon.response(f)
            assert addon.rewrites == 1
            decoded = json.loads(gzip.decompress(f.response.raw_content))
            assert decoded["planetActiveEffects"] == [{"index": 182, "galacticEffectId": 1373}]
            assert int(f.response.headers["content-length"]) == len(f.response.raw_content)
            assert "etag" not in f.response.headers
            addon.response(f)
            assert addon.rewrites == 1
            report.write_text(json.dumps({"official_core": True, "signed_loopback_crl": True, "gzip_roundtrip": True, "content_length": True, "deduplicate": True, "game_capture": False, "trust_changes": False}), encoding="utf-8")
        except Exception as error:
            import traceback
            report.write_text(json.dumps({"error": str(error), "traceback": traceback.format_exc()}), encoding="utf-8")
        finally:
            ctx.master.shutdown()


addons = [NativeSmoke()]
