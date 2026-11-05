"""Compile declarative migration inventory into bounded, compressed Rust data.

No interpreter or executable callbacks are embedded. Physical defaults/current
values are deliberately excluded: runtime values must come from the open files
and independently authenticated originals. This does not mark unresolved rules
as implemented; they remain explicit in the migration audit.
"""
import argparse
import collections
import gzip
import hashlib
import json
import pathlib
import re
import struct

ROOT=pathlib.Path(__file__).resolve().parents[1]
def blocks(data):
    at=data.find(b'LDLD\1\0\0\0',0,64)
    while at>=0:
        typ,size=struct.unpack_from('<II',data,at+8);start=at+24;end=start+size
        if end>len(data):raise ValueError('Truncated block')
        yield typ,start,end
        if end==len(data):return
        at=data.find(b'LDLD\1\0\0\0',end,end+64)
    raise ValueError('Unparsed input')

def delta_ranges(data):
    out=[]
    for typ,base,end in blocks(data):
        if typ!=0x683E604F:continue
        arrays=[struct.unpack_from('<QI',data,base+i*16)for i in range(5)]
        at,count=arrays[0];final={}
        for i in range(count):
            resource,slot=struct.unpack_from('<QI',data,base+at+i*16)
            if not resource:continue
            nc,first=struct.unpack_from('<II',data,base+arrays[1][0]+slot*8)
            for c in range(first,first+nc):
                comp,first_delta,nd=struct.unpack_from('<III',data,base+arrays[2][0]+c*12)
                for d in range(first_delta,first_delta+nd):
                    field,size,offset=struct.unpack_from('<III',data,base+arrays[3][0]+d*12)
                    start=base+arrays[4][0]+offset
                    assert start+size<=end
                    final[resource,comp,field]=(start,start+size)
        out.extend((start,end,f'delta:{resource:016X}:{comp}:{field}')for(resource,comp,field),(start,end)in final.items())
    return sorted(out)

def special_ranges(source):
    out=[]
    data=(source/'sources/generated_status_effect_settings.dl_plain').read_bytes()
    for typ,base,end in blocks(data):
        if typ!=0xC63E0B22:continue
        for i in range(struct.unpack_from('<I',data,base+8)[0]):
            row=base+16+i*160;status=struct.unpack_from('<I',data,row)[0]
            pointer,count=struct.unpack_from('<QI',data,row+112);ordinals=collections.Counter()
            for j in range(count):
                at=base+pointer+j*8;stat=struct.unpack_from('<I',data,at)[0];ordinal=ordinals[stat];ordinals[stat]+=1
                out.append((typ,at,at+8,f'stat:{status}:{stat}:{ordinal}'))
    data=(source/'sources/generated_destruction_settings.dl_plain').read_bytes();settings=[];entities={}
    for typ,base,end in blocks(data):
        if typ==0xD6A11545:settings.append((base,end))
        elif typ==0x49795156:
            for i in range(struct.unpack_from('<I',data,base+8)[0]):
                entity,slot=struct.unpack_from('<QQ',data,base+16+i*16)
                if entity:entities[entity]=slot
    for entity,slot in entities.items():
        base,end=settings[slot]
        for level in range(3):
            for direct in range(2):
                start=base+level*48+(32 if direct else 16)
                out.append((0xD6A11545,start,start+12,f'demolition:{entity:016X}:{level}:{direct}'))
    return out

def compile_catalog(source):
    source=pathlib.Path(source);inventory=json.loads((source/'catalog.json').read_text(encoding='utf8'))
    fields=inventory['fields'];keys=sorted(fields);indices={key:n for n,key in enumerate(keys)}
    delta=delta_ranges((source/'sources/generated_entity_deltas.dl_plain').read_bytes())
    specials=special_ranges(source)
    compiled=[];unresolved=collections.Counter();encodings=collections.Counter()
    registries={}
    for name,items in inventory.get('registries',{}).items():
        registries[name]=[{key:value for key,value in item.items() if key in {'id','raw','label','note'}}for item in items]
    for key in keys:
        field=fields[key];storage=field['storage'];encodings[storage]+=1
        result={'key':key,'storage':storage,'bindings':[]}
        for name in ['allowed','unset','bolt_on','bolt_off']:
            if name in field and field[name]!=[]:result[name]=field[name]
        for name in ['auto_drop','death']:
            if name in field:result[name]=indices[field[name]]
        if storage=='virtual':
            result['virtual_default']=field.get('default')
            if field['functions']:result['unresolved']='virtual callback: '+','.join(field['functions'])
        elif field.get('resource'):
            result['resource']={'identity':field['resource'],'relative':field['relative']}
            result['unresolved']='archive resource binding'
        elif 'file'not in field:result['unresolved']='source file missing'
        else:
            typ=field.get('type',field['kind']);record=field.get('record');relative=field.get('relative',field['offset'])
            kit=re.fullmatch(r'armor kit ([0-9A-F]{8}) ([0-9A-F]{8}) ([0-9A-F]{8}) (\d+)',str(field['kind']))
            passive=re.fullmatch(r'armor passive (\d+)',str(field['kind']))
            bindings=[]
            if kit:typ=0xD9A55AA0;record='kit:'+':'.join(kit.groups());relative=field['offset']
            elif passive:typ=0x63CE0FEB;record='id:'+passive[1];relative=field['offset']
            elif field['kind']==0x683E604F:
                for start,end,identity in delta:
                    if start<=field['file_offset'] and field['file_offset']+field['width']<=end:
                        bindings.append(dict(file=field['file'],type='683E604F',record=identity,relative=field['file_offset']-start))
            elif not record:
                for special_type,start,end,identity in specials:
                    if field['kind']==special_type and start<=field['file_offset'] and field['file_offset']+field['width']<=end:
                        bindings.append(dict(file=field['file'],type=f'{special_type:08X}',record=identity,relative=field['file_offset']-start))
            if record:bindings.append(dict(file=field['file'],type=f'{typ:08X}',record=record,relative=relative))
            codec=None
            if storage in {'f32','u32','i32','u8','u16'}:codec=storage
            elif storage=='entry':codec='u32'
            elif storage=='tier':codec='demolition'
            elif storage=='flag':codec=dict(kind='flag',width=1,mask=field['mask'])if field.get('mask')else'bool'
            elif storage=='bit':codec=dict(kind='flag',width=2,mask=1<<field['bit'])
            elif storage in {'bolt','boltcycle'}:codec=dict(kind='switch',on=field['bolt_on'],off=field['bolt_off'])
            elif storage in registries:
                entries={str(item['id']):item['raw']for item in registries[storage]if item.get('raw')and re.fullmatch('[0-9A-Fa-f]{16}',item['raw'])}
                codec=dict(kind='reference',registry=storage)
                if not entries:result['unresolved']='empty reference registry'
            else:result['unresolved']='special encoding: '+storage
            if not bindings:result['unresolved']=result.get('unresolved','record anchor missing')
            elif codec:
                result['encoding']=codec;result['bindings']=bindings
        if result.get('unresolved'):unresolved[result['unresolved']]+=1
        compiled.append(result)
    owners=[]
    for owner in inventory['owners']:
        item=owner['item'];out={key:item[key]for key in ['id','name','english','groups','note']if key in item}
        out['tab']=owner['tab'];out['rows']=[]
        for row in owner['rows']:
            ui=row['ui'];r={key:row[key]for key in ['id','storage','choice','lead','show_first','mult','inverse','scale','zero','never','rate_plus','suppression','code','slot','drow','set','add','each','rack','hash32']if key in row}
            r.update(label=ui['label'],section=ui['section'],help=ui.get('help',[]),note=ui.get('note',''),parts=[dict(field=indices[p['field']],id=p['id'])for p in row['parts']])
            if r['help']==[]:r.pop('help')
            if not r['note']:r.pop('note')
            if 'drain'in row:r['drain']=row['drain']
            if 'span_expression'in row:
                def expr(e):return {k:indices[v]if k=='field'else expr(v)if isinstance(v,dict)else v for k,v in e.items()}
                r['span']=expr(row['span_expression'])
            elif 'span_value'in row:
                # flinch-recovery numerator is Targeting +44 on the first member.
                if row['id']=='flinch_recover':
                    rate=fields[row['parts'][0]['field']];match=next((k for k,f in fields.items()if f['kind']==rate['kind']and f['offset']==rate['offset']+4 and f['storage']=='f32'),None)
                    if match:r['span']={'op':'field','field':indices[match]}
                    else:r['unresolved']='missing flinch numerator'
                else:r['unresolved']='dynamic span'
            if row.get('functions'):
                pending=set(row['functions'])-{'span','span_default','label_of','note','inline_note'}
                if pending:r['unresolved']='callbacks: '+','.join(sorted(pending))
            out['rows'].append(r)
        counts=collections.Counter(r['id']for r in out['rows']);used=collections.Counter()
        for row in out['rows']:
            identity=row['id']
            if counts[identity]>1:
                semantic=[]
                for part in row['parts']:
                    field=compiled[part['field']]
                    semantic.append(dict(id=part['id'],storage=field['storage'],bindings=field['bindings'],resource=field.get('resource'),virtual=field['key']if field['storage']=='virtual'else None))
                identity+='@'+hashlib.sha256(json.dumps(semantic,sort_keys=True).encode()).hexdigest()[:16]
            used[identity]+=1
            row['key']=identity if used[identity]==1 else identity+f':{used[identity]}'
        owners.append(out)
    result=dict(format='SHODAN-NATIVE-DESCRIPTORS',version=1,owners=owners,fields=compiled,registries=registries,
                sources=inventory['sources'],resource_sources=inventory.get('resource_fixtures',{}))
    audit=dict(owners=len(owners),rows=sum(len(o['rows'])for o in owners),fields=len(compiled),encodings=dict(encodings),unresolved=dict(unresolved),
               unresolved_rows=sum('unresolved'in r for o in owners for r in o['rows']),physical_defaults_embedded=False,executable_callbacks_embedded=False)
    return result,audit

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--inventory',type=pathlib.Path,required=True);parser.add_argument('--output',type=pathlib.Path,required=True)
    args=parser.parse_args();result,audit=compile_catalog(args.inventory)
    raw=json.dumps(result,ensure_ascii=False,separators=(',',':')).encode();compressed=gzip.compress(raw,compresslevel=9,mtime=0)
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_bytes(compressed)
    audit.update(json_bytes=len(raw),compressed_bytes=len(compressed),sha256=hashlib.sha256(compressed).hexdigest())
    args.output.with_suffix('.audit.json').write_text(json.dumps(audit,ensure_ascii=False,indent=2),encoding='utf8')
    print(json.dumps(audit,ensure_ascii=True))

if __name__=='__main__':main()
