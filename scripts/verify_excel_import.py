import hashlib,json,os,subprocess,sys,uuid
from pathlib import Path
from server_acceptance import Client,require
def main():
    sys.stdout.reconfigure(encoding='utf-8')
    path=Path('.tools/import-2026/manifest.json');m=json.loads(path.read_text(encoding='utf-8'));batch=str(uuid.UUID(m['batch_id']))
    def stats():
        sql=f"""select jsonb_build_object(
        'trips',(select count(*) from splav.groups where import_metadata->>'batch_id'='{batch}'),
        'people',(select count(*) from splav.people where id in (select person_id from splav.registrations where import_metadata->>'batch_id'='{batch}'
          union select entity_id from splav.excel_import_records where batch_id='{batch}' and kind='person_contact')),
        'participants',(select count(*) from splav.registrations where import_metadata->>'batch_id'='{batch}'),
        'payments',(select count(*) from splav.payments where id in (select entity_id from splav.excel_import_records where batch_id='{batch}' and kind='payment')),
        'payment_kopeks',(select sum(signed_kopeks) from splav.payments where id in (select entity_id from splav.excel_import_records where batch_id='{batch}' and kind='payment')),
        'historical_crews',(select count(*) from splav.excel_historical_crews where batch_id='{batch}'),
        'records',(select count(*) from splav.excel_import_records where batch_id='{batch}'),
        'issues',(select count(*) from splav.excel_import_issues where batch_id='{batch}'),
        'min_day',(select min((starts_at at time zone 'Europe/Saratov')::date) from splav.groups where import_metadata->>'batch_id'='{batch}'),
        'max_day',(select max((ends_at at time zone 'Europe/Saratov')::date) from splav.groups where import_metadata->>'batch_id'='{batch}'));
        """
        r=subprocess.run(['docker','exec','-i','supabase_db_splav-prototype','psql','-U','postgres','-qAt','-v','ON_ERROR_STOP=1'],input=sql,encoding='utf-8',capture_output=True)
        require(r.returncode==0,r.stderr);return json.loads(r.stdout)
    before=stats();require(before['trips']==len(m['trips']) and before['participants']==len(m['participations']) and before['people']==len(m['people']),'Count mismatch')
    require(before['payments']==len(m['payments']) and before['payment_kopeks']==sum(p['amount'] for p in m['payments']),'Cash mismatch')
    c=Client('http://127.0.0.1:54321',os.environ['SPLAV_SUPABASE_KEY'],'organizer-a@example.com')
    replay=c.post('/rest/v1/rpc/import_excel_batch',{'p_batch_id':batch,'p_team_id':m['team_id'],'p_manifest':m})
    require(replay['replayed'] is True,'Import did not replay');after=stats();require(before==after,'Replay changed counts')
    catalog=c.post('/rest/v1/rpc/list_trips',{});known={t['id'] for t in catalog['trips']}
    require(all(t['id'] in known for t in m['trips']),'Trips not visible to working account')
    ui_snapshot=None
    for trip in m['trips']:
        source_parts=[p for p in m['participations'] if p['trip_id']==trip['id']]
        if not source_parts:continue
        s=c.post('/rest/v1/rpc/roster_snapshot',{'p_trip_id':trip['id'],'p_after_revision':-1})
        require(len(s['participations'])==len(source_parts),'Roster snapshot mismatch')
        require(sum(p['signed_kopeks'] for p in s['payments'])==sum(p['amount'] for p in m['payments'] if p['trip_id']==trip['id']),'Ledger snapshot mismatch')
        if '01.08–02.08' in trip['title']:ui_snapshot=s
    require(ui_snapshot is not None,'UI sample missing')
    Path('.tools/import-2026/ui-fixture.json').write_text(json.dumps({'catalog':catalog,'snapshot':ui_snapshot},ensure_ascii=False),encoding='utf-8')
    for f in m['files']:
        file=Path.home()/'OneDrive'/'Рабочий стол'/f['name'];require(hashlib.sha256(file.read_bytes()).hexdigest()==f['sha256'],'Source was modified')
    before['replayed_without_changes']=True
    Path('.tools/import-2026/verified.json').write_text(json.dumps(before,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(before,ensure_ascii=False))
if __name__=='__main__':main()
