"""Deterministic import of the supplied season schedule and August roster.

Build a reviewable manifest first. --apply sends that exact manifest to an
administrator-only transactional RPC. Source workbooks are never recalculated.
"""
import argparse
from collections import defaultdict
from datetime import date, datetime, timedelta
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import uuid
import urllib.error
from inspect_trip_workbooks import read_book

NAMESPACE=uuid.UUID('26000000-0000-4000-8000-000000000001')
def ident(key):return str(uuid.uuid5(NAMESPACE,key))
def normal(value):return re.sub(r'\s+',' ',str(value or '')).strip().lower().replace('ё','е')
def column(address):return re.sub(r'\d','',address)
def phone(cell):
    if not cell:return ''
    value=cell.get('value')
    if 'formula' in cell:
        f=cell['formula'].strip()
        if not re.fullmatch(r'\+?\d{10,15}',f):return ''
        value=f
    if not isinstance(value,(int,str)):return ''
    raw=str(value).strip()
    if not re.fullmatch(r'[+\d ()\-]+',raw):return ''
    digits=re.sub(r'\D','',raw)
    if len(digits)==11 and digits[0] in '78':return '+7'+digits[1:]
    if len(digits)==10:return '+7'+digits
    return '+'+digits if 11<=len(digits)<=15 else ''
def money(cell):
    if not cell or 'formula' in cell or cell.get('type')=='e':return None
    value=cell.get('value')
    if isinstance(value,str):
        value=re.sub(r'\s|руб(?:лей|ля)?\.?|р\.?|₽','',value,flags=re.I).replace(',','.')
        if not re.fullmatch(r'\d+(?:\.\d{1,2})?',value):return None
    if isinstance(value,bool) or value is None:return None
    try:
        n=Decimal(str(value))*100
        return int(n) if n==n.to_integral_value() and 0<=n<=1000000000000 else None
    except Exception:return None
def name_and_parameters(raw,f='',g=''):
    text=str(raw).strip();text=re.sub(r'^\s*\d+\s*(?:[.)-]\s*|\s+(?=[А-Яа-яЁёA-Za-z]))','',text)
    text=re.sub(r'^\d{2,3}\s*[-/]\s*\d{2,3}\s+','',text)
    name=re.split(r'\d|[,(;]|\b(?:размер|разм\.?|рост|вес)\b',text,maxsplit=1,flags=re.I)[0]
    name=re.sub(r'[- /]+(?:XXXL|XXL|XL|XS|S|M|L|ХХЛ|ХЛ|Л|М)\s*$','',name,flags=re.I)
    name=re.sub(r'\s+',' ',name).strip(' -./\\')
    params={}; combined=' '.join(str(v) for v in [text,g] if v)
    for key,pattern,low,high in [
      ('height_cm',r'(?:рост\s*[:=]?\s*(\d+(?:[.,]\d+)?))|(?:(\d+(?:[.,]\d+)?)\s*см)',30,300),
      ('weight_kg',r'(?:вес\s*[:=]?\s*(\d+(?:[.,]\d+)?))|(?:(\d+(?:[.,]\d+)?)\s*кг)',1,500),
      ('age_years',r'(\d+(?:[.,]\d+)?)\s*(?:лет|года?\b)',0,120)]:
        m=re.search(pattern,combined,re.I)
        if m:
            n=float(next(v for v in m.groups() if v is not None).replace(',','.'))
            if low<=n<=high:params[key]=int(n) if n.is_integer() else n
    m=re.search(r'(?:размер(?:\s+одежды)?|разм\.?)\s*[:=-]?\s*((?:\d{2,3}(?:\s*[-/]\s*\d{2,3})?)|[XХ]*[SMLСМЛ])|\b(\d{2,3}(?:-\d{2,3})?)\s*р(?:\b|[\s,])|\b(XXXL|XXL|XL|XS|S|M|L)\b',text,re.I)
    if m:params['clothing_size']=next(v for v in m.groups() if v).strip()
    elif isinstance(f,(int,float)) and 36<=f<=70:params['clothing_size']=str(int(f))
    notes=[f'Исходная запись: {raw}']
    if f and not re.fullmatch(r'\d{4}-\d{2}-\d{2}T.*',str(f)):notes.append(f'Параметры Excel: {f}')
    if g:notes.append(str(g))
    params['notes']='\n'.join(notes)[:1000]
    return name[:100],params

def manifest(books,team,year=2026):
    issues=[];records=[];trips={};people={};bookings=[];parts=[];payments=[];crews=[]
    def issue(file,sheet,row,kind,detail):issues.append({'file':file,'sheet':sheet,'row':row,'kind':kind,'detail':detail})
    def provenance(file,sheet,row,kind,entity,raw,cell=''):
        records.append({'file':file,'sheet':sheet,'row':row,'cell':cell,'kind':kind,'entity_id':entity,'data':raw})
    schedule=next(s for s in books[0]['sheets'] if normal(s['name'])=='расписание')
    for r in schedule['rows']:
        n=r['row'];c=r['cells'];last=c.get('C'+str(n),{}).get('value');first=c.get('A'+str(n),{}).get('value')
        if not isinstance(first,(int,float)) or not last:continue
        if re.match(r'\d{4}-\d{2}-\d{2}',str(last)):end=date.fromisoformat(str(last)[:10]).replace(year=year)
        else:
            m=re.fullmatch(r'(\d{1,2})\.(сен|авг|июл|июн|май)\.?',str(last),re.I)
            if not m:issue(books[0]['file'],schedule['name'],n,'date_unparsed',{'value':last});continue
            end=date(year,{'май':5,'июн':6,'июл':7,'авг':8,'сен':9}[m[2].lower()],int(m[1]))
        start=end-timedelta(days=1);key=f'{start}/{end}';trip=ident(f'{team}:season:{key}')
        if int(first)!=start.day:issue(books[0]['file'],schedule['name'],n,'corrected_start_day',{'source':first,'used':start.day})
        label=str(c.get('G'+str(n),{}).get('value') or '').strip()
        notes=[f'Импорт Excel 2026. Время и лимит клиентов в источнике не указаны.',f'Источник: {Path(books[0]["file"]).name}, {schedule["name"]}, строка {n}.']
        for col in ['G','H','I']:
            v=c.get(col+str(n),{})
            if v.get('value') and 'formula' not in v:notes.append(f'{col}: {v["value"]}')
        trips[key]={'id':trip,'starts_on':str(start),'ends_on':str(end),'base_price_kopeks':money(c.get('E'+str(n))) or 0,
          'title':f'Сплав {start:%d.%m}–{end:%d.%m.%Y}'+(f' · {label}' if label else ''),'notes':'\n'.join(notes),
          'label':label,'source_rows':[],'historical_count':None}
        provenance(books[0]['file'],schedule['name'],n,'trip',trip,{col:v['value'] for col,v in c.items() if column(col)!='F' and 'formula' not in v})
    for sheet in books[1]['sheets']:
        match=re.fullmatch(r'(\d{1,2})-(\d{1,2})',sheet['name'])
        if not match:continue
        start=date(year,8,int(match[1]));end=date(year,8 if int(match[2])>=int(match[1]) else 9,int(match[2]));key=f'{start}/{end}'
        if key not in trips:trips[key]={'id':ident(f'{team}:season:{key}'),'starts_on':str(start),'ends_on':str(end),'base_price_kopeks':0,
          'title':f'Сплав {start:%d.%m}–{end:%d.%m.%Y}','notes':'Импорт Excel. Время, цена и лимит не указаны.','label':'','source_rows':[]}
        trip=trips[key];rows={r['row']:r['cells'] for r in sheet['rows']}
        def cell(row,col):return rows.get(row,{}).get(f'{col}{row}',{})
        def value(row,col):return cell(row,col).get('value')
        footer=next((n for n in rows if normal(value(n,'A'))=='четырешка'),10000)
        entries={};primary=[];price_rows={}
        for n in rows:
            raw=value(n,'D')
            if n<4 or n>=footer or not isinstance(raw,str) or not re.search('[А-Яа-яЁёA-Za-z]',raw):continue
            if normal(raw) in ('инструктор','резерв','фио','итого'):continue
            name,params=name_and_parameters(raw,value(n,'F'),value(n,'G'))
            if not name:issue(books[1]['file'],sheet['name'],n,'name_unparsed',{'text':raw});continue
            entries[n]={'row':n,'name':name,'raw':raw,'parameters':params,'status':'confirmed'};primary.append(n)
        # Supplementary priced list on 30-31 repeats the seating roster, not new people or receipts.
        if sheet['name']=='30-31':
            for n in rows:
                if n<=footer or not isinstance(value(n,'D'),int) or not isinstance(value(n,'E'),str) or normal(value(n,'E'))=='итого':continue
                name,params=name_and_parameters(value(n,'E'),'',value(n,'I'))
                matches=[e for e in entries.values() if normal(e['name'])==normal(name)]
                if len(matches)==1:
                    entry=matches[0];entry['parameters'].update({k:v for k,v in params.items() if k!='notes'});
                    if money(cell(n,'G')):entry['price']=money(cell(n,'G'))
                    entry.setdefault('supplements',[]).append(n)
                    provenance(books[1]['file'],sheet['name'],n,'participation_supplement',ident(f'{trip["id"]}:row:{entry["row"]}'),
                      {'name':value(n,'E'),'price':value(n,'G'),'source_mark':value(n,'H'),'notes':value(n,'I')})
                else:issue(books[1]['file'],sheet['name'],n,'unmatched_supplement',{'name':name,'price':value(n,'G')})
        else:
            for n in rows:
                raw=value(n,'D')
                if n<=footer or not isinstance(raw,str) or len(re.findall('[А-Яа-яЁёA-Za-z]+',raw))<2:continue
                name,params=name_and_parameters(raw,value(n,'F'),value(n,'G'))
                if not name:continue
                same=[e for e in entries.values() if normal(e['name'])==normal(name)]
                if same:
                    issue(books[1]['file'],sheet['name'],n,'duplicate_tail_row',{'name':name});continue
                entries[n]={'row':n,'name':name,'raw':raw,'parameters':params,'status':'application','unplaced':True}
                issue(books[1]['file'],sheet['name'],n,'unplaced_person',{'name':name})
        # A valid explicitly merged telephone joins a company. Boat adjacency is ignored.
        groups={n:n for n in entries};contacts={};merge_phone={}
        for merge in sheet['merges']:
            m=re.fullmatch(r'E(\d+):E(\d+)',merge)
            if m and phone(cell(int(m[1]),'E')):
                head=int(m[1]);members=[n for n in entries if head<=n<=int(m[2])]
                if members:
                    for n in members:groups[n]=members[0];merge_phone[n]=phone(cell(head,'E'))
        # One named collective with one explicit contact: the numbered Щитова list.
        unique_phones={phone(cell(n,'E')) for n in primary if phone(cell(n,'E'))}
        leader=entries.get(primary[0]) if primary else None
        if leader and len(unique_phones)==1 and trip['label'] and normal(trip['label']) in normal(leader['name']) and isinstance(value(primary[0],'F'),str) and normal(trip['label']) in normal(value(primary[0],'F')):
            for n in primary:groups[n]=primary[0];merge_phone[n]=next(iter(unique_phones))
            contacts[primary[0]]=str(value(primary[0],'F'))
        for n,e in entries.items():
            ph=phone(cell(n,'E'));contact_phone=ph or merge_phone.get(n,'')
            person_key=f'{team}:person:{normal(e["name"])}:{contact_phone}' if contact_phone and len(e['name'].split())>=2 else f'{team}:{books[1]["sha256"]}:{sheet["name"]}:person:{n}'
            person_id=ident(person_key);part_id=ident(f'{trip["id"]}:row:{n}');booking_id=ident(f'{trip["id"]}:party:{groups[n]}')
            e.update({'person_id':person_id,'id':part_id,'booking_id':booking_id})
            people.setdefault(person_id,{'id':person_id,'name':e['name'],'phone':ph or contact_phone,'notes':f'Импорт: {Path(books[1]["file"]).name}.'})
            if groups[n] not in contacts:contacts[groups[n]]=entries[groups[n]]['name']
            price=e.get('price',trip['base_price_kopeks'])
            inline=re.search(r'(?<!\d)([1-9]\d{3,4})(?!\d)',e['raw']) if sheet['name']=='1-2' else re.search(r'(?<!\d)([1-9]\d{3,4})\s*(?:руб|₽)',e['raw'],re.I)
            if inline:price=int(inline[1])*100
            parts.append({'id':part_id,'trip_id':trip['id'],'person_id':person_id,'booking_id':booking_id,'status':e['status'],
              'role':'client','price':price,'parameters':e['parameters'],
              'payment_recorded':any(money(cell(n,col)) is not None for col in ['H','I'])})
            provenance(books[1]['file'],sheet['name'],n,'participation',part_id,{'original_name':e['raw'],'phone':ph,'parameters':e['parameters'],'unplaced':e.get('unplaced',False)})
        for head in sorted(set(groups.values())):
            members=[e for n,e in entries.items() if groups[n]==head]
            bookings.append({'id':members[0]['booking_id'],'trip_id':trip['id'],'contact_name':contacts[head],
              'phone':next((phone(cell(e['row'],'E')) or merge_phone.get(e['row'],'') for e in members if phone(cell(e['row'],'E')) or merge_phone.get(e['row'],'')),''),
              'contact_person_id':entries[head]['person_id'],'notes':f'Excel {sheet["name"]}: строки '+', '.join(str(e['row']) for e in members)})
        for n,c in rows.items():
            if n<3 or (n>=footer and n not in entries):continue
            for col in ['H','I']:
                amount=money(cell(n,col))
                if amount is None:
                    source=cell(n,col)
                    if source.get('value') not in (None,'') and 'formula' not in source:
                        issue(books[1]['file'],sheet['name'],n,'unparsed_money',{'cell':f'{col}{n}','value':source['value']})
                    continue
                if amount==0:continue
                if n not in entries:
                    issue(books[1]['file'],sheet['name'],n,'unassigned_money',{'cell':f'{col}{n}','amount_kopeks':amount});continue
                e=entries[n];bulk=amount>next(p['price'] for p in parts if p['id']==e['id']) and sum(1 for v in entries.values() if v['booking_id']==e['booking_id'])>1
                if bulk:next(p for p in parts if p['id']==e['id'])['payment_recorded']=False
                payments.append({'id':ident(f'{trip["id"]}:payment:{col}{n}'),'trip_id':trip['id'],'booking_id':e['booking_id'],'amount':amount,
                  'allocations':[] if bulk else [{'participation_id':e['id'],'amount_kopeks':amount}],
                  'notes':f'Импорт Excel {sheet["name"]}!{col}{n}: {"предоплата" if col=="H" else "оплата"}. Дата получения не указана.'})
                provenance(books[1]['file'],sheet['name'],n,'payment',payments[-1]['id'],{'amount_kopeks':amount,'purpose':'deposit' if col=='H' else 'payment'},f'{col}{n}')
        # Keep trip-local crew labels without pretending they are physical inventory IDs.
        for merge in sheet['merges']:
            m=re.fullmatch(r'A(\d+):A(\d+)',merge)
            if not m:continue
            first,last=int(m[1]),int(m[2]);label=value(first,'A')
            if not isinstance(label,str) or not re.match(r'лодка\s*\d+',label,re.I):continue
            members=[entries[n]['id'] for n in entries if first<=n<=last]
            if members or first==2:
                crews.append({'trip_id':trip['id'],'label':label,'participation_ids':members,'source_rows':[first,last],
                  'note':'Имя инструктора не указано' if first==2 else 'Инвентарная лодка и её тип в источнике не указаны.'})
        trip['detail_sheet']=sheet['name'];trip['detail_count']=len(primary)
        # Preserve other genuine notes/contacts for review, not as payments or fictional passengers.
        for n in rows:
            if n>footer and sheet['name']!='30-31':
                raw={a:v['value'] for a,v in rows[n].items() if column(a) in ['D','E','F','G','H','I'] and 'formula' not in v and v['value'] is not None}
                if raw:provenance(books[1]['file'],sheet['name'],n,'source_note',trip['id'],raw)
                if isinstance(value(n,'D'),str) and phone(cell(n,'E')) and n not in entries:
                    person_id=ident(f'{team}:{books[1]["sha256"]}:{sheet["name"]}:contact:{n}')
                    people[person_id]={'id':person_id,'name':str(value(n,'D'))[:100],'phone':phone(cell(n,'E')),'notes':'Контакт в примечании Excel, без подтверждённого участия.'}
                    provenance(books[1]['file'],sheet['name'],n,'person_contact',person_id,{'name':value(n,'D'),'phone':phone(cell(n,'E'))})
    # Read-only provenance is not a second operational roster or cash ledger.
    for book in books:
        for sheet in book['sheets']:
            for row in sheet['rows']:
                raw={a:v['value'] for a,v in row['cells'].items() if 'formula' not in v and v['type']!='e'
                    and not (book is books[1] and column(a)=='F' and re.match(r'\d{4}-\d{2}-\d{2}T',str(v['value'])))}
                if raw:provenance(book['file'],sheet['name'],row['row'],'raw_row',None,raw)
    labels=defaultdict(list)
    for crew in crews:labels[(crew['trip_id'],crew['label'])].append(crew)
    for group in labels.values():
        if len(group)>1:
            for crew in group:
                original=crew['label'];crew['label']=f'{original} · строки {crew["source_rows"][0]}–{crew["source_rows"][1]}'
                issue(books[1]['file'],next(t['detail_sheet'] for t in trips.values() if t['id']==crew['trip_id']),crew['source_rows'][0],
                  'duplicate_crew_label',{'source_label':original,'display_label':crew['label']})
    trips=list(trips.values())
    result={'version':1,'team_id':team,'year':year,'policies':{'company_link':'explicit_phone_merge_or_named_contact','formula_values':'excluded','source_year_corrected':True},
      'files':[{'name':Path(b['file']).name,'sha256':b['sha256']} for b in books],
      'route_id':ident(f'{team}:excel-route-unspecified'),'route_name':'Маршрут не указан · импорт Excel',
      'trips':trips,'people':list(people.values()),'bookings':bookings,'participations':parts,'payments':payments,'crews':crews,'records':records,'issues':issues}
    result['batch_id']=ident(f'{team}:excel-import:'+':'.join(b['sha256'] for b in books)+f':year={year}:policy=1')
    return result

def main():
    sys.stdout.reconfigure(encoding='utf-8')
    p=argparse.ArgumentParser();p.add_argument('--schedule',type=Path);p.add_argument('--august',type=Path);p.add_argument('--team',default='00000000-0000-4000-8000-000000000010');
    p.add_argument('--manifest',type=Path,required=True);p.add_argument('--year',type=int,default=2026);p.add_argument('--apply',action='store_true');args=p.parse_args()
    if args.apply:
        from server_acceptance import Client
        data=json.loads(args.manifest.read_text(encoding='utf-8'))
        client=Client(os.environ.get('SPLAV_SUPABASE_URL','http://127.0.0.1:54321'),os.environ['SPLAV_SUPABASE_KEY'],os.environ.get('SPLAV_IMPORT_EMAIL','organizer-a@example.com'))
        result=client.post('/rest/v1/rpc/import_excel_batch',{'p_batch_id':data['batch_id'],'p_team_id':data['team_id'],'p_manifest':data})
        print(json.dumps(result,ensure_ascii=False));return
    data=manifest([read_book(args.schedule),read_book(args.august)],args.team,args.year)
    args.manifest.parent.mkdir(parents=True,exist_ok=True);args.manifest.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({'batch_id':data['batch_id'],'counts':{k:len(data[k]) for k in ['trips','people','bookings','participations','payments','crews','records','issues']},
      'payment_kopeks':sum(p['amount'] for p in data['payments']),'issues':dict(__import__('collections').Counter(i['kind'] for i in data['issues']))},ensure_ascii=False))
if __name__=='__main__':
    try:main()
    except urllib.error.HTTPError as error:raise SystemExit(error.read().decode('utf-8')) from None
