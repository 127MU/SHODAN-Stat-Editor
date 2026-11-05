"""Audit all exported fields against the Rust reader; no game writes.

The inventory's old-engine values are an independent regression oracle, not
runtime defaults. Archive fixtures are immutable originals; loose-file fixtures
may contain previous modifications and are never automatically authenticated.
"""
import argparse
import collections
import gzip
import json
import math
import pathlib
import struct
import subprocess
import sys
import tempfile

ROOT=pathlib.Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--exe',type=pathlib.Path,default=ROOT/'target/debug/shodan-native.exe')
parser.add_argument('--inventory',type=pathlib.Path,default=ROOT/'dist/native-catalog-inventory-7')
parser.add_argument('--catalog',type=pathlib.Path,default=ROOT/'dist/native-catalog-compiled-7/catalog.json.gz')
parser.add_argument('--output',type=pathlib.Path,default=ROOT/'dist/native-catalog-field-audit.json')
args=parser.parse_args()
c=json.loads(gzip.decompress(args.catalog.read_bytes()));old=json.loads((args.inventory/'catalog.json').read_text(encoding='utf8'))
assert c['fields'] and all('current'not in f and 'default'not in f for f in c['fields'])
fixtures={name:(args.inventory/'sources'/record['name'])for name,record in old['fixtures'].items()}
names=sorted(set(b['file']for f in c['fields']for b in f['bindings']))
process=subprocess.Popen([str(args.exe.resolve()),'--stdio'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,encoding='utf8')
def call(method,ok=True,**params):
    process.stdin.write(json.dumps(dict(id=method,method=method,params=params))+'\n');process.stdin.flush()
    result=json.loads(process.stdout.readline());assert result['ok']==ok,result
    return result.get('result',result.get('error'))
failures=[];unavailable=[];matched=0;physical=collections.Counter();row_failures=[];row_unavailable=[];row_matched=0
try:
    info=call('catalog-load',path=str(args.catalog.resolve()))
    assert info['owners']==len(old['owners']) and info['physical_defaults_embedded']is False
    inputs=[]
    for name in names:
        entry=dict(name=name,path=str(fixtures[name].resolve()))
        baseline=ROOT/'offline/originals'/old['fixtures'][name]['name']
        if baseline.exists():entry.update(baseline_name=baseline.name,baseline_path=str(baseline))
        inputs.append(entry)
    opened=call('workspace-open',files=inputs);assert opened['problems']==[],opened
    resources=sorted(old['resource_fixtures'])
    call('catalog-open-resources',files=[dict(identity=name,path=str((args.inventory/'resources'/name).resolve()),baseline_path=str((args.inventory/'resources'/name).resolve()))for name in resources])
    for start in range(0,len(c['fields']),1000):
        values=call('catalog-read-fields',indices=list(range(start,min(start+1000,len(c['fields'])))))
        for value in values:
            field=c['fields'][value['index']];reference=old['fields'][field['key']]
            expected=reference.get('current')
            if value['error']:
                unavailable.append(dict(key=field['key'],storage=field['storage'],why=value['error'],expected=expected))
                continue
            actual=value['value']
            if expected is not None and actual is not None and math.isclose(actual,expected,rel_tol=1e-7,abs_tol=1e-7):matched+=1
            elif expected is None and actual is None:matched+=1
            else:failures.append(dict(key=field['key'],storage=field['storage'],expected=expected,actual=actual))
            physical[field['storage']]+=1
    # Duplicate parameter IDs must remain distinct and searchable.
    spear=next(o for o in c['owners']if o['english']=='FAF-14 Spear')
    rows=call('catalog-describe',owner=spear['id'])['rows']
    duplicate=[r for r in rows if r['id']=='lock_range'];assert len(duplicate)==2 and len({r['key']for r in duplicate})==2
    assert call('catalog-items',query='FAF-14')
    for start in range(0,len(c['owners']),100):
        owners=c['owners'][start:start+100]
        for result,owner,reference in zip(call('catalog-row-values',owners=[o['id']for o in owners]),owners,old['owners'][start:start+100]):
            for row,actual,legacy in zip(owner['rows'],result['rows'],reference['rows']):
                # Residency state is deliberately deferred in the reference UI;
                # a pending placeholder is not a physical parameter value.
                if legacy['ui'].get('patch_pending'):continue
                expected=legacy['ui'].get('value');value=actual['value']
                if actual['error']:
                    row_unavailable.append(dict(owner=owner['id'],key=row['key'],why=actual['error'],expected=expected));continue
                if expected is None and value is None or isinstance(expected,(int,float))and isinstance(value,(int,float))and math.isclose(value,expected,rel_tol=1e-7,abs_tol=1e-7):row_matched+=1
                else:row_failures.append(dict(owner=owner['id'],key=row['key'],expected=expected,actual=value))
    assert call('workspace-preview')['pending_bytes']==0
finally:
    process.stdin.close();assert process.wait(timeout=10)==0
report=dict(matched=matched,total=len(c['fields']),encodings=dict(physical),unavailable=unavailable,mismatches=failures,row_matched=row_matched,row_unavailable=row_unavailable,row_mismatches=row_failures,game_writes=0)
args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
print(json.dumps(dict(matched=matched,total=len(c['fields']),unavailable=len(unavailable),mismatches=len(failures),row_matched=row_matched,row_unavailable=len(row_unavailable),row_mismatches=len(row_failures),game_writes=0)))
if failures or unavailable:
    print(json.dumps((failures+unavailable)[:12],ensure_ascii=True));raise SystemExit('Native field audit mismatch; see report')
if row_failures or row_unavailable:
    print(json.dumps((row_failures+row_unavailable)[:16],ensure_ascii=True));raise SystemExit('Native logical row audit mismatch; see report')
