"""Stages 4/5 adversarial RPC checks. Uses an isolated, explicitly named test team."""
import concurrent.futures
import json
import os
import subprocess
import urllib.error
import uuid
from server_acceptance import Client, require, expect_rpc_error
from stage1_acceptance import save

TEST_TEAM = '45000000-0000-4000-8000-000000000001'
TEST_ROUTE = '45000000-0000-4000-8000-000000000002'
def uid(): return str(uuid.uuid4())

def database_sql(sql):
    p = subprocess.run(['docker','exec','-i','supabase_db_splav-prototype','psql','-U','postgres','-v','ON_ERROR_STOP=1'], input=sql, encoding='utf-8', capture_output=True)
    require(p.returncode == 0, p.stderr)

def prepare_team():
    database_sql(f"""begin;
    insert into splav.teams(id,name) values('{TEST_TEAM}','Проверка этапов 4–5 (вымышленные данные)') on conflict(id) do nothing;
    insert into splav.team_members(team_id,user_id,role) select '{TEST_TEAM}',id,'admin' from auth.users
      where email='organizer-a@example.com' on conflict do nothing;
    insert into splav.routes(id,team_id,name) values('{TEST_ROUTE}','{TEST_TEAM}','Тестовый маршрут 4–5') on conflict do nothing;
    commit;""")

def main():
    prepare_team()
    key=os.environ['SPLAV_SUPABASE_KEY']; url=os.environ.get('SPLAV_SUPABASE_URL','http://127.0.0.1:54321')
    a,b,denied=[Client(url,key,email) for email in ['organizer-a@example.com','organizer-a@example.com','organizer-c@example.com']]
    prefix=uid()[:8]; trip,other=uid(),uid()
    fields={'title':'Проверка 4–5 '+prefix,'route_id':TEST_ROUTE,'starts_at':'2038-08-01T09:00:00+04:00',
      'ends_at':'2038-08-02T18:00:00+04:00','timezone':'Europe/Saratov','meeting_at':'2038-08-01T08:00:00+04:00',
      'meeting_point':'Тестовый причал','responsible_names':'Тест','capacity':35,'base_price_kopeks':100000,'status':'open','notes':'Вымышленные данные'}
    for t in [trip,other]: require(save(a,TEST_TEAM,t,fields)[0]['status']=='accepted','Trip failed')
    def cmd(kind,payload,version=0,client=a,t=trip,operation=None):
        envelope={'p_operation_id':operation or uid(),'p_team_id':TEST_TEAM,'p_trip_id':None if kind=='save_person' else t,
          'p_kind':kind,'p_payload':payload,'p_expected_version':version}
        return client.post('/rest/v1/rpc/people_command',envelope),envelope
    def accepted(kind,payload,version=0,**kw):
        result,envelope=cmd(kind,payload,version,**kw); require(result['status']=='accepted',(kind,result)); return result,envelope
    def snap(t=trip,client=a,cursor=-1): return client.post('/rest/v1/rpc/roster_snapshot',{'p_trip_id':t,'p_after_revision':cursor})
    def resource(kind,name,model,cap,roles=None):return {'id':uid(),'kind':kind,'name':name,'code':prefix+'-'+uid()[:8],
      'model':model,'capacity':cap,'available':True,'roles':roles or [],'version':0}
    big,rf,maigun,race_boat,bus,secondary,worker=[
      resource('boat','Большая','big',4),resource('boat','Каяк РФ','rf',3),resource('boat','Майгун','maigun',2),
      resource('boat','Спорная лодка','maigun',2),resource('vehicle','Тестовый автобус','custom',2),
      resource('vehicle','Второй автобус','secondary_bus',20),resource('employee','Тестовая подмена','employee',0,['warehouse','camp_kitchen'])]
    accepted('ops_resources',{'items':[big,rf,maigun,race_boat,bus,secondary,worker]})
    people,parts=[uid() for _ in range(7)],[uid() for _ in range(7)]
    for i,p in enumerate(people): accepted('save_person',{'id':p,'name':f'Тест {prefix} {i}'})
    parameters=[{'height_cm':180,'weight_kg':85,'age_years':35},{'height_cm':130,'weight_kg':30,'age_years':7},
      {'height_cm':155,'weight_kg':50,'age_years':25},{'height_cm':156,'weight_kg':50,'age_years':30},
      {'height_cm':150,'age_years':12},{'height_cm':170,'weight_kg':70,'age_years':35},{'height_cm':160,'weight_kg':60,'age_years':31}]
    accepted('save_booking',{'id':uid(),'contact_name':'Тестовая компания','members':[
      {'id':i,'person_id':p,'role':'instructor' if n==5 else 'client','parameters':parameters[n]} for n,(p,i) in enumerate(zip(people,parts))]})
    accepted('set_status',{'ids':parts,'status':'confirmed','versions':{p:1 for p in parts}})
    def reservation(r,kind,cap,**kw):return {'id':uid(),'resource_id':r['id'],'kind':kind,'capacity':cap,'active':True,
      'starts_at':'2038-08-01T09:00:00+04:00','ends_at':'2038-08-01T16:00:00+04:00','prep_minutes':0,'return_minutes':0,
      'direction':'outbound','points':[{'id':'start','name':'Причал'}],'notes':'Тест',**kw}
    boats=[reservation(big,'boat',4),reservation(rf,'boat',3),reservation(maigun,'boat',2)]
    for boat in boats: accepted('ops_reservation',boat)
    def crew(i,boat,seat,version=0,**kw):return cmd('ops_crew',{'subject_kind':'participant','subject_id':parts[i],
      'reservation_id':boat['id'] if boat else None,'seat':seat},version,**kw)[0]
    adult=crew(0,boats[0],4); require(adult.get('reason')=='seat_restriction',('Adult child-seat result',adult))
    require(crew(1,boats[0],4)['status']=='accepted','130cm child rejected')
    require(crew(3,boats[1],3)['reason']=='seat_restriction','156cm extra seat accepted')
    require(crew(4,boats[1],3)['reason']=='seat_restriction','Missing weight accepted')
    require(crew(2,boats[1],3)['status']=='accepted','155cm 50kg boundary rejected')
    require(crew(0,boats[1],1)['status']=='accepted','Base seat failed')
    require(crew(0,boats[2],2,1)['status']=='accepted','Atomic crew move failed')
    require(len([c for c in snap()['operations']['crews'] if c['registration_id']==parts[0] and c['reservation_id']==boats[2]['id']])==1,'Crew move duplicated person')
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        results=list(pool.map(lambda i:crew(i,boats[2],1),[3,6]))
    require(sum(r['status']=='accepted' for r in results)==1,'Two clients occupied one boat seat')
    # A different trip cannot reserve a physical boat in the same interval.
    contested=[reservation(race_boat,'boat',2) for _ in range(2)]
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        results=[j.result()[0] for j in [pool.submit(cmd,'ops_reservation',contested[0],t=trip),pool.submit(cmd,'ops_reservation',contested[1],t=other,client=b)]]
    require(sum(r['status']=='accepted' for r in results)==1 and any(r.get('reason')=='resource_overlap' for r in results),'Cross-trip booking race failed')
    buffered=reservation(worker,'duty',1,role='warehouse',return_minutes=60)
    accepted('ops_reservation',buffered)
    adjacent=reservation(worker,'duty',1,role='camp_kitchen',starts_at='2038-08-01T16:00:00+04:00',ends_at='2038-08-01T20:00:00+04:00')
    require(cmd('ops_reservation',adjacent,t=other)[0]['reason']=='resource_overlap','Return buffer ignored')
    accepted('ops_reservation',{**adjacent,'id':uid(),'starts_at':'2038-08-01T17:00:00+04:00'},t=other)
    expect_rpc_error(lambda:cmd('ops_reservation',reservation(secondary,'ride',18)),'22023')
    ride=reservation(bus,'ride',2); accepted('ops_reservation',ride)
    def travel(i,seat,version=0,mode='bus',direction='outbound',client=a):
        old=next((t for t in snap()['operations']['travel'] if t['subject_id']==parts[i] and t['direction']==direction),None)
        return cmd('ops_travel',{'id':old['id'] if old else uid(),'subject_kind':'participant','subject_id':parts[i],
          'reservation_id':ride['id'] if mode=='bus' else None,'seat':seat if mode=='bus' else None,'point_id':'start' if mode=='bus' else None,
          'direction':direction,'mode':mode},version,client=client)[0]
    require(travel(0,1)['status']=='accepted','Outbound failed')
    require(travel(0,None,mode='self',direction='return')['status']=='accepted','Independent return failed')
    require(travel(5,2)['status']=='accepted','Instructor failed to take physical seat')
    require(travel(2,2)['reason']=='seat_occupied','Instructor did not occupy capacity')
    # Release the instructor's plan, then race for the last seat.
    require(travel(5,None,version=1,mode='self')['status']=='accepted','Self travel change failed')
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        results=list(pool.map(lambda i:travel(i,2),[2,4]))
    require(sum(r['status']=='accepted' for r in results)==1,'Two clients occupied one bus seat')
    fact={'id':uid(),'reservation_id':ride['id'],'subject_kind':'participant','subject_id':parts[0],'present':True,
      'previous_id':None,'device_id':'acceptance-'+prefix,'occurred_at':'2038-08-01T08:45:00+04:00'}
    result,envelope=accepted('ops_presence',fact)
    require(b.post('/rest/v1/rpc/people_command',envelope)==result,'Lost boarding reply not idempotent')
    require(len(snap()['operations']['presence'])==1,'Boarding replay duplicated fact')
    expect_rpc_error(lambda:b.post('/rest/v1/rpc/people_command',{**envelope,'p_payload':{**fact,'present':False}}),'22023')
    accepted('set_status',{'ids':[parts[0]],'status':'cancelled','versions':{parts[0]:2}})
    s=snap(); o=s['operations']; issue=next(i for i in o['issues'] if i['fact_id']==fact['id'])
    require(next(t for t in o['travel'] if t['subject_id']==parts[0] and t['direction']=='outbound')['mode']=='unset','Cancellation did not free plan')
    require(next(c for c in o['crews'] if c['registration_id']==parts[0])['reservation_id'] is None,'Cancellation did not free crew')
    require(o['presence'][0]['present'] is True,'Cancellation erased physical fact')
    require(travel(6,1)['reason']=='physical_seat_occupied','Actually occupied seat was silently reused')
    accepted('ops_resolve',{'id':uid(),'fact_id':fact['id'],'signature':issue['signature'],'decision':'keep','reason':'Организатор проверил: человек в автобусе'})
    require(snap()['operations']['issues']==[] and snap()['operations']['presence'][0]['present'],'Keep decision erased the fact')
    accepted('ops_resolve',{'id':uid(),'correction_id':uid(),'device_id':'acceptance','fact_id':fact['id'],
      'signature':issue['signature'],'decision':'error','reason':'Позднее выяснено: ошибочная отметка'})
    require(len(snap()['operations']['presence'])==2 and len(snap()['operations']['resolutions'])==2,'Correction history lost')
    require(travel(6,1)['status']=='accepted','Corrected physical seat did not become available')
    accepted('ops_settings',{'many_children':True,'notes':'Детская группа'})
    require(snap()['operations']['settings']['many_children'],'Instructor requirement flag lost')
    latest=snap(); require(snap(cursor=latest['revision'])['unchanged'],'Cursor did not settle')
    expect_rpc_error(lambda:snap(client=denied),'42501')
    expect_rpc_error(lambda:denied.post('/rest/v1/rpc/people_command',envelope),'42501')
    # A formerly authorized caller must also lose access to their own receipts.
    database_sql(f"""insert into splav.team_members(team_id,user_id,role) select '{TEST_TEAM}',id,'organizer' from auth.users
      where email='organizer-c@example.com' on conflict do nothing;
      insert into splav.group_members(group_id,user_id) select '{trip}',id from auth.users where email='organizer-c@example.com' on conflict do nothing;""")
    expect_rpc_error(lambda:cmd('ops_resources',{'items':[{**worker,'version':1}]},client=denied),'42501')
    _,own_receipt=accepted('ops_travel',{'id':uid(),'subject_kind':'participant','subject_id':parts[1],
      'direction':'return','mode':'self','reservation_id':None,'seat':None,'point_id':None},client=denied)
    database_sql(f"delete from splav.group_members where group_id='{trip}' and user_id=(select id from auth.users where email='organizer-c@example.com');")
    expect_rpc_error(lambda:denied.post('/rest/v1/rpc/people_command',own_receipt),'42501')
    expect_rpc_error(lambda:snap(client=denied),'42501')
    accepted('edit_participation',{'id':parts[1],'role':'client','parameters':{'height_cm':131,'weight_kg':30,'age_years':8}},version=2)
    require(next(c for c in snap()['operations']['crews'] if c['registration_id']==parts[1])['reservation_id'] is None,'Changed measurements did not release child seat')
    require(save(a,TEST_TEAM,trip,{**fields,'status':'cancelled'},version=1)[0]['status']=='accepted','Trip cancellation failed')
    require(not any(b['active'] for b in snap()['operations']['reservations']),'Cancelled trip retained active resource bookings')
    require(len(snap()['operations']['presence'])==2,'Trip cancellation erased facts')
    print('PASS fleet restrictions, crew moves, cross-trip interval race, half-open buffers, duty overlap, transport capacity, instructors, separate return, immutable boarding, late cancellation, resolution, cursor and access')
    print('Synthetic team:',TEST_TEAM,'trip:',trip)

if __name__=='__main__':
    try: main()
    except urllib.error.HTTPError as error: raise SystemExit(error.read().decode()) from None
