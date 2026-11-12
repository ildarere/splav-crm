"""Read XLSX source cells without recalculation or changes to the source books."""
import argparse
import datetime as dt
import hashlib
import json
import sys
from pathlib import Path
import posixpath
import zipfile
import xml.etree.ElementTree as ET
from openpyxl.styles.numbers import BUILTIN_FORMATS, is_date_format
from openpyxl.utils.datetime import from_excel, CALENDAR_MAC_1904, CALENDAR_WINDOWS_1900

NS={'x':'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
REL='{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id'
def text(element): return ''.join(element.itertext()) if element is not None else ''
def read_book(path):
    with zipfile.ZipFile(path) as z:
        book=ET.fromstring(z.read('xl/workbook.xml'))
        rels={r.attrib['Id']:r.attrib['Target'] for r in ET.fromstring(z.read('xl/_rels/workbook.xml.rels'))}
        shared=[]
        if 'xl/sharedStrings.xml' in z.namelist():
            shared=[''.join(t.text or '' for t in si.findall('.//x:t',NS)) for si in ET.fromstring(z.read('xl/sharedStrings.xml')).findall('x:si',NS)]
        styles=ET.fromstring(z.read('xl/styles.xml'))
        formats={**BUILTIN_FORMATS,**{int(n.attrib['numFmtId']):n.attrib['formatCode'] for n in styles.findall('x:numFmts/x:numFmt',NS)}}
        fills=[ET.tostring(f,encoding='unicode') for f in styles.findall('x:fills/x:fill',NS)]
        xfs=[{'format':formats.get(int(x.attrib.get('numFmtId',0)),''),'fill':int(x.attrib.get('fillId',0)),'font':int(x.attrib.get('fontId',0))} for x in styles.findall('x:cellXfs/x:xf',NS)]
        epoch=CALENDAR_MAC_1904 if book.find('x:workbookPr',NS) is not None and book.find('x:workbookPr',NS).attrib.get('date1904') in ('1','true') else CALENDAR_WINDOWS_1900
        sheets=[]
        for s in book.findall('x:sheets/x:sheet',NS):
            target=rels[s.attrib[REL]]; target=target.lstrip('/') if target.startswith('/') else posixpath.normpath('xl/'+target)
            xml=ET.fromstring(z.read(target)); rows=[]; errors=0
            for row in xml.findall('x:sheetData/x:row',NS):
                cells={}
                for c in row.findall('x:c',NS):
                    typ=c.attrib.get('t','n'); raw=c.find('x:v',NS); f=c.find('x:f',NS); inline=c.find('x:is',NS)
                    value=raw.text if raw is not None else None
                    if typ=='s' and value is not None: value=shared[int(value)]
                    elif typ=='inlineStr': value=''.join(t.text or '' for t in inline.findall('.//x:t',NS)) if inline is not None else None
                    elif typ=='b': value=value=='1'
                    elif typ=='n' and value is not None:
                        number=float(value); value=int(number) if number.is_integer() else number
                        style=xfs[int(c.attrib.get('s',0))]
                        if is_date_format(style['format']):
                            parsed=from_excel(value,epoch); value=parsed.isoformat()
                    if value is None and f is None: continue
                    if typ=='e': errors+=1
                    cells[c.attrib['r']]={'value':value,'type':typ,'style':int(c.attrib.get('s',0)),
                        **({'formula':f.text or '', 'formula_attributes':f.attrib} if f is not None else {})}
                if cells: rows.append({'row':int(row.attrib['r']),'cells':cells})
            sheets.append({'name':s.attrib['name'],'state':s.attrib.get('state','visible'),
                'dimension':xml.find('x:dimension',NS).attrib if xml.find('x:dimension',NS) is not None else {},
                'merges':[m.attrib['ref'] for m in xml.findall('x:mergeCells/x:mergeCell',NS)],'rows':rows,'errors':errors})
        comments=[]
        for member in z.namelist():
            if 'comments' in member.lower() and member.endswith('.xml') and 'threaded' not in member.lower():
                root=ET.fromstring(z.read(member))
                for c in root.findall('.//x:comment',NS): comments.append({'part':member,'cell':c.attrib.get('ref'),'text':text(c.find('x:text',NS))})
        return {'file':str(path),'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'styles':xfs,'fills':fills,'comments':comments,'sheets':sheets}

def main():
    sys.stdout.reconfigure(encoding='utf-8')
    p=argparse.ArgumentParser();p.add_argument('files',nargs='+',type=Path);p.add_argument('--output',type=Path,required=True);args=p.parse_args()
    books=[read_book(f) for f in args.files];args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(books,ensure_ascii=False,indent=2),encoding='utf-8')
    for b in books:
        print(json.dumps({'file':Path(b['file']).name,'sheets':[{'name':s['name'],'rows':len(s['rows']),'dimension':s['dimension'],'errors':s['errors'],
          'sample':[{k:('='+v['formula'][:100] if 'formula' in v else str(v['value'])[:150]) for k,v in r['cells'].items()} for r in s['rows'][:3]]} for s in b['sheets']]},ensure_ascii=False))
if __name__=='__main__':main()
