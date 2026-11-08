"""Share named multi-stratagem presets across profiles without writing game files."""
import argparse
import json
import os
import pathlib
import subprocess


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('exe','runtime','game-data','output'):
        parser.add_argument('--'+name,type=pathlib.Path,required=True)
    a=parser.parse_args(); root=a.output.resolve();root.mkdir()
    def start(profile):
        p=subprocess.Popen([a.exe.resolve(),'--stdio'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,
            encoding='utf8',env=os.environ|{'SHODAN_PROFILE':str(root/profile)})
        def call(method,**params):
            p.stdin.write(json.dumps(dict(method=method,params=params))+'\n');p.stdin.flush()
            r=json.loads(p.stdout.readline());assert r['ok'],r;return r['result']
        def d(name,*args):return call('desktop-call',name=name,args=args)
        call('game-open',runtime=str(a.runtime.resolve()),game=str(a.game_data.resolve()))
        return p,d
    def close(p):p.stdin.close();assert p.wait(timeout=30)==0
    def cooldown(d):return next(r for r in d('rows_fast') if r['id']=='cooldown')['value']
    p,d=start('sender')
    try:
        choices=d('items','Stratagems','')
        ids=[next(x['id'] for x in choices if 'FAF-14' in x['name']),next(x['id'] for x in choices if 'A/G-16' in x['name'])]
        d('select',ids[0]);d('set','cooldown','73')
        d('select',ids[1]);d('set','cooldown','91')
        bundle=d('library_capture','测试：飞矛与加特林',[*ids])
        text=d('library_export',bundle['id'])
        preview=d('library_preview',text)
        assert preview['groups'][0]['name']=='测试：飞矛与加特林'
        assert set(preview['groups'][0]['owners'])==set(ids)
        d('library_rename',bundle['id'],'我的自定义战备 English 2')
        text=d('library_export',bundle['id'])
        assert '我的自定义战备 English 2' in text
        d('select',ids[0]);d('set','cooldown','74')
        other=d('library_capture','另一套',[ids[0]])
        joined=d('library_join',[text,d('library_export',other['id'])])
        assert len(d('library_preview',joined)['groups'])==2
        full=d('library_capture','整套当前修改',None)
        assert full['id'] and full['text']
        all_text=d('library_export',None)
        assert len(d('library_preview',all_text)['groups'])==3
    finally:close(p)
    p,d=start('recipient')
    try:
        d('select',ids[0]);before=cooldown(d)
        imported=d('library_import',text);key=imported['selected']
        assert cooldown(d)==before,'Import must only store, not apply without a read action'
        assert d('library_list')[0]['name']=='我的自定义战备 English 2'
        d('library_load',key);assert cooldown(d)==73
        d('select',ids[1]);assert cooldown(d)==91
        d('undo');assert cooldown(d)!=91
        d('redo');assert cooldown(d)==91
        existing=d('library_list')
        broken=text.replace(ids[0],'FFFFFFFFFFFFFFF0')
        try:d('library_import',broken)
        except AssertionError:pass
        else:raise AssertionError('Unknown owner accepted')
        assert d('library_list')==existing
        assert cooldown(d)==91
        d('library_import',joined)
        assert len(d('library_list'))==2,'Independent conflicting variants must coexist in the library'
        d('library_import',all_text)
        assert len(d('library_list'))==3
    finally:close(p)
    p,d=start('recipient')
    try:
        assert len(d('library_list'))==3
        d('select',ids[1]);assert cooldown(d)==91
    finally:close(p)
    print('Named TXT, multi-owner matching, independent variants, all-presets import, atomic load/undo, invalid-input rollback and restart persistence passed.')


if __name__=='__main__':main()
