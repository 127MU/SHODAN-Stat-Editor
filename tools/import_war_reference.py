"""Read the user's XLSX reference without modifying its nonstandard styles."""
import argparse
import json
from pathlib import Path
import re
from xml.etree import ElementTree as ET
from zipfile import ZipFile

NS = {'s': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}


def read_effects(path):
    with ZipFile(path) as z:
        shared = []
        if 'xl/sharedStrings.xml' in z.namelist():
            shared = [''.join(t.text or '' for t in n.findall('.//s:t', NS))
                      for n in ET.fromstring(z.read('xl/sharedStrings.xml')).findall('s:si', NS)]
        rels = {r.attrib['Id']: r.attrib['Target'] for r in ET.fromstring(z.read('xl/_rels/workbook.xml.rels'))}
        sheets = ET.fromstring(z.read('xl/workbook.xml')).findall('s:sheets/s:sheet', NS)
        sheet = next(s for s in sheets if s.attrib['name'] == '星球词条')
        target = rels[sheet.attrib['{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id']]
        target = target.lstrip('/') if target.startswith('/') else 'xl/'+target
        tree = ET.fromstring(z.read(target))
        cells = {}
        for c in tree.findall('s:sheetData/s:row/s:c', NS):
            v = c.find('s:v', NS)
            value = (v.text or '') if v is not None else ''.join(t.text or '' for t in c.findall('.//s:t', NS))
            if c.attrib.get('t') == 's' and value:
                value = shared[int(value)]
            if value:
                cells[c.attrib['r']] = value.strip()
        # Expand only vertical B-column merged labels (e.g. a pair of SEAF IDs).
        for merged in tree.findall('s:mergeCells/s:mergeCell', NS):
            match = re.fullmatch(r'B(\d+):B(\d+)', merged.attrib['ref'])
            if match and cells.get('B'+match[1]):
                for row in range(int(match[1]), int(match[2])+1):
                    cells.setdefault('B'+str(row), cells['B'+match[1]])
        result = {}
        for cell, value in cells.items():
            if not re.fullmatch(r'A\d+', cell) or not value.isdigit() or int(value) <= 0:
                continue
            note = cells.get('B'+cell[1:], '').strip()
            if not note:
                continue
            eid = int(value)
            entry = {'name': note.splitlines()[0].strip(), 'note': note,
                     'translation_source': '用户提供的资源 ID 对照表',
                     'reference_sheet': '星球词条', 'reference_cell': 'B'+cell[1:]}
            if str(eid) in result:
                old = result[str(eid)]
                if old['note'] != note:
                    old.setdefault('aliases', []).append(entry['name'])
                    old['note'] += '\n'+note
                    old.setdefault('additional_cells', []).append(entry['reference_cell'])
                continue
            result[str(eid)] = entry
        return result


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--xlsx', type=Path, required=True)
    p.add_argument('--catalog', type=Path, required=True)
    p.add_argument('--live-catalog', type=Path, required=True)
    a = p.parse_args()
    reference = read_effects(a.xlsx)
    catalog = json.loads(a.catalog.read_text('utf-8'))
    live = {int(e['id']): e for e in json.loads(a.live_catalog.read_text('utf-8'))['effects']}
    for key, entry in reference.items():
        current = live.get(int(key))
        if current:
            entry['effectType'] = current['effectType']
            entry['nameHash'] = current['nameHash']
    catalog['effect_reference'] = reference
    for effect in catalog['effects']:
        entry = reference.get(str(effect['id']))
        if entry and entry.get('effectType', effect['effectType']) == effect['effectType']:
            effect.update(name=entry['name'], translation_source=entry['translation_source'], translated=True)
    a.catalog.write_text(json.dumps(catalog, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    print(json.dumps({'reference_names': len(reference), 'matched_live': len(set(map(int, reference)) & set(live)),
                      'unmatched_live': sorted(set(live)-set(map(int, reference)))}, ensure_ascii=False))


if __name__ == '__main__':
    main()
