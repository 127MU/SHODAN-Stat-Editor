"""Build-time migration inventory, never a runtime dependency or game writer.

Run the reference editor against immutable fixtures in an isolated profile,
export declarative catalog/field metadata, and report every dynamic rule that
still needs a native implementation. Lua functions are never serialized.
"""
import argparse
import hashlib
import json
import math
import os
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--vendor', type=pathlib.Path, default=ROOT.parent / 'hd2-hud-plus-repair/vendor')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    profile = args.output / 'profile'
    profile.mkdir()
    os.environ.update(SHODAN_PROFILE=str(profile.resolve()), SHODAN_QA_OUTPUT=str(profile.resolve()))
    sys.path.insert(0, str(args.vendor))
    from lupa.luajit21 import LuaRuntime, lua_type

    lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)
    lua.execute(b'jit.off();SHODAN_EUI=true;arg={...}', (ROOT / 'src/stat_editor.lua').as_posix().encode())
    lua.globals()[b'B'] = lua.execute(b'return dofile(...)', (ROOT / 'offline/host.lua').as_posix().encode())
    lua.execute(b'''
    require('install').write_files=function()error('Game writes forbidden during export')end
    require('install').write_patch=function()error('Game writes forbidden during export')end
    local function up(fn,wanted)
        for i=1,100 do local name,value=debug.getupvalue(fn,i);if not name then break end;if name==wanted then return value end end
    end
    local ffi=require('ffi');local MOD=up(B.rows,'MOD');local ui=up(B.rows,'ui')
    local kinds=up(B.rows,'KINDS');local read=up(B.rows,'read_field');local tables=up(read,'tables')
    local original=up(B.rows,'default_of');local settings=up(B.rows,'settings');local D=require('hostdata')
    local function hex(s)local out={};for i=#s,1,-1 do out[#out+1]=string.format('%02X',s:byte(i))end;return table.concat(out)end
    local function scalar(t)
        local out={};for k,v in pairs(t)do if type(k)=='string' and (type(v)=='string' or type(v)=='number' or type(v)=='boolean')then out[k]=v end end;return out
    end
    local rows_by_type={}
    for kind,entry in pairs(tables)do
        local rows={};for key,at in pairs(entry.index or {})do if type(at)=='number'then rows[#rows+1]={at=at,key=type(key)=='number' and ('id:'..key) or ('hash:'..hex(key))}end end
        table.sort(rows,function(a,b)return a.at<b.at end);rows_by_type[kind]=rows
    end
    local function width(f)
        if f.storage=='virtual'then return 0 end
        if f.storage=='u8' or f.storage=='flag'then return 1 end
        if f.storage=='u16' or f.storage=='bit'then return 2 end
        if f.storage=='rackitem' or f.storage=='mountitem' or f.storage=='package' or f.storage=='dogweapon' or f.storage=='dogmag' or f.storage=='gun' or f.storage=='grenade'then return 8 end
        if f.storage=='tier'then return 12 end
        return 4
    end
    EXPORT_FIELDS={}
    local function field(f)
        if EXPORT_FIELDS[f.key]then return f.key end
        local out=scalar(f);out.width=width(f);out.functions={}
        for k,v in pairs(f)do if type(v)=='function'then out.functions[#out.functions+1]=k end end
        out.allowed={};for k,v in pairs(f.allowed or {})do if type(k)=='number' and v==true then out.allowed[#out.allowed+1]=k end end;table.sort(out.allowed)
        EXPORT_FIELDS[f.key]=out
        local entry=tables[f.kind]
        if entry and type(f.offset)=='number' and f.storage~='virtual' then
            local address=entry.copies[1]+24+f.offset
            for name,file in pairs(D.files)do local at=address-tonumber(ffi.cast('uintptr_t',file.p));if at>=0 and at+out.width<=file.n then out.file=name;out.file_offset=at;out.type=entry.type or f.kind;out.block_offset=at-f.offset;out.block_size=entry.payload;break end end
            local list=rows_by_type[f.kind] or {};local lo,hi=1,#list
            while lo<=hi do local mid=math.floor((lo+hi)/2);if list[mid].at<=f.offset then lo=mid+1 else hi=mid-1 end end
            local row=list[hi];local stride=kinds[f.kind] and kinds[f.kind].stride or kinds[entry.type] and kinds[entry.type].stride or 0
            if row and f.offset+out.width<=row.at+stride then out.record=row.key;out.relative=f.offset-row.at end
            if not out.file and f.kind==0x5F7203C8 then
                local V=require('vehicles');for name,resource in pairs(V.files)do
                    if f.offset>=resource.at and f.offset+out.width<=resource.at+resource.size then out.resource=name;out.relative=f.offset-resource.at;break end
                end
            end
        end
        for _,key in ipairs({'auto_drop','death'})do if type(f[key])=='table' and f[key].key then out[key]=field(f[key])end end
        out.default=original(f);out.current=read(f)
        EXPORT_FIELDS[f.key]=out;return f.key
    end
    function export_owner(item)
        B.select(item.id)
        local w=ui.weapon;local result={item=item,tab=w.slot,english=w.name,hash=w.hash,legacy=w.legacy or {},rows={},dynamic={}}
        result.enemy=not not w.enemy;result.record=not not w.record;result.mounted=not not w.mounted
        result.native_key=w.key and hex(w.key) or nil
        local shown=B.rows(nil,false,true)
        for n,row in ipairs(w.rows or {})do
            local r=scalar(row);r.ui=shown[n];r.parts={};r.functions={}
            for k,v in pairs(row)do if type(v)=='function'then r.functions[#r.functions+1]=k end end;table.sort(r.functions)
            for _,part in ipairs(row.parts or {})do r.parts[#r.parts+1]={id=part.id,field=field(part.field)}end
            if row.span then
                r.span_value=row.span();r.span_default_value=row.span_default and row.span_default()
                local needed,tank,cap,span=up(row.span,'needed'),up(row.span,'tank'),up(row.span,'cap'),up(row.span,'span')
                if needed or tank or cap then r.span_expression={op='field',field=field(needed or tank or cap)}
                elseif span then
                    local capacity,recover=up(span,'capacity'),up(span,'recover')
                    if capacity then r.span_expression={op='field',field=field(capacity)};if up(row.span,'recovered')then r.span_expression={op='subtract',left=r.span_expression,right={op='field',field=field(recover)}}end end
                end
            end
            if row.drain then r.drain=row.drain.id end
            result.rows[#result.rows+1]=r
        end
        return result
    end
    function export_types()
        local out={};for kind,k in pairs(kinds)do out[string.format('%08X',kind)]=scalar(k)end;return out
    end
    function export_methods()
        local out={};for key,value in pairs(B)do if type(value)=='function'then out[#out+1]=key end end;table.sort(out);return out
    end
    function export_source_names()
        local out={};for name in pairs(D.files)do out[#out+1]=name end;table.sort(out);return out
    end
    function export_source(name)
        local G=require('gamedata');local file=assert(D.files[name]);local p,n=assert(G.open_sealed(file.cipher));local bytes=ffi.string(p,n);G.free(p);return bytes
    end
    function export_registries()
        local out={}
        for name,reg in pairs({rackitem=MOD.refs.items(),mountitem=MOD.refs.mounts(),package=MOD.refs.packages(),entry=MOD.refs.entries(),dogweapon=MOD.dogs,dogmag=MOD.dogs.magazines,gun=MOD.enemy.gun_choices()})do
            local list={};for _,item in ipairs(reg.list)do local e=scalar(item);e.raw=item.bytes and hex(item.bytes) or item.key and hex(item.key) or item.raw;e.label=settings.tr(item.label or item.name or '');e.note=item.note;list[#list+1]=e end;out[name]=list
        end
        return out
    end
    function export_resources()
        local out={};local V=require('vehicles');for name,bytes in pairs(V.original)do out[name]=bytes end;return out
    end
    ''')

    def convert(value):
        if isinstance(value, bytes):
            try:
                return value.decode('utf8')
            except UnicodeDecodeError:
                return {'bytes': value.hex()}
        if isinstance(value, float) and not math.isfinite(value):
            raise ValueError('Non-finite descriptor data')
        if lua_type(value) == 'table':
            pairs = list(value.items())
            if all(isinstance(k, int) and not isinstance(k, bool) and 1 <= k <= len(pairs) for k, _ in pairs):
                return [convert(value[i]) for i in range(1, len(pairs) + 1)]
            return {str(convert(k)): convert(v) for k, v in pairs}
        if value is None or isinstance(value, (str, bool, int, float)):
            return value
        raise ValueError(f'Non-declarative descriptor: {lua_type(value)}')

    tabs = ['Primary','Secondary','Support','Throwables','Stratagems','Mechas','Boosters','Attachments',
            'Armors','Helldiver','Terminids','Automatons','Illuminate','SEAF','Spawning','Records']
    items = {}
    for tab in tabs:
        lua.globals()[b'B'][b'editor_mode'](tab in ['Terminids','Automatons','Illuminate','SEAF','Spawning'])
        values = lua.globals()[b'B'][b'items'](tab.encode(), b'')
        for index in range(1, len(values) + 1):
            item = values[index]
            identity = item[b'id'].decode()
            items.setdefault(identity, (tab, item))
    owners = []
    failures = []
    for n, (identity, (tab, item)) in enumerate(items.items(), 1):
        try:
            lua.globals()[b'B'][b'editor_mode'](tab in ['Terminids','Automatons','Illuminate','SEAF','Spawning'])
            owners.append(convert(lua.globals()[b'export_owner'](item)))
        except Exception as error:
            failures.append({'owner': identity, 'tab': tab, 'error': str(error)})
        if n % 100 == 0:
            print(f'Catalog inventory {n}/{len(items)}', flush=True)
    fields = convert(lua.globals()[b'EXPORT_FIELDS'])
    counts = {}
    for field in fields.values():
        encoding = field.get('storage', '?')
        counts[encoding] = counts.get(encoding, 0) + 1
    sources = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (ROOT/'offline/originals').glob('*.dl_plain')}
    fixtures=args.output/'sources';fixtures.mkdir()
    names=lua.globals()[b'export_source_names']()
    fixture_manifest={}
    for n in range(1,len(names)+1):
        name=names[n].decode();plain=lua.globals()[b'export_source'](names[n]);filename=name.removesuffix('.dl_bin')+'.dl_plain'
        (fixtures/filename).write_bytes(plain)
        digest=hashlib.sha256(plain).hexdigest()
        fixture_manifest[name]={'name':filename,'sha256':digest,'trusted':sources.get(filename)==digest}
    resource_fixtures={};resource_folder=args.output/'resources';resource_folder.mkdir()
    for name,raw in lua.globals()[b'export_resources']().items():
        name=name.decode();(resource_folder/name).write_bytes(raw);resource_fixtures[name]={'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
    catalog = {'format': 'SHODAN-NATIVE-CATALOG', 'version': 1, 'sources': sources,
               'types': convert(lua.globals()[b'export_types']()),
               'methods': convert(lua.globals()[b'export_methods']()), 'owners': owners, 'fields': fields,'fixtures':fixture_manifest,
               'registries':convert(lua.globals()[b'export_registries']()),'resource_fixtures':resource_fixtures}
    target = args.output/'catalog.json'
    target.write_text(json.dumps(catalog, ensure_ascii=False, separators=(',', ':')), encoding='utf8')
    audit = {'owners': len(owners), 'rows': sum(len(owner['rows']) for owner in owners), 'fields': len(fields),
             'encodings': counts, 'unmapped': [key for key,field in fields.items() if field.get('storage')!='virtual' and 'file' not in field],
             'unanchored': [key for key,field in fields.items() if field.get('storage')!='virtual' and 'record' not in field],
             'failures': failures, 'bytes': target.stat().st_size}
    (args.output/'audit.json').write_text(json.dumps(audit,ensure_ascii=False,indent=2),encoding='utf8')
    print(json.dumps({key:len(value) if isinstance(value,list) else value for key,value in audit.items()},ensure_ascii=False),flush=True)
    if failures:
        raise SystemExit('Catalog inventory incomplete; see audit.json')


if __name__ == '__main__':
    main()
