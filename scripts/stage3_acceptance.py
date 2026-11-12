"""Repeatable financial checks using synthetic trips; never resets existing data."""
import concurrent.futures
import os
import uuid
import urllib.error
from server_acceptance import Client, require, expect_rpc_error
from stage1_acceptance import save

def uid(): return str(uuid.uuid4())
def main():
    url=os.environ.get('SPLAV_SUPABASE_URL','http://127.0.0.1:54321'); key=os.environ['SPLAV_SUPABASE_KEY']
    a=Client(url,key,'organizer-a@example.com'); b=Client(url,key,'organizer-a@example.com'); denied=Client(url,key,'organizer-c@example.com')
    catalog=a.post('/rest/v1/rpc/list_trips',{}); team=next(t['id'] for t in catalog['teams'] if t['role']=='admin')
    route=next(r['id'] for r in catalog['routes'] if r['team_id']==team); trip=uid(); booking=uid()
    fields={'title':'Этап 3 '+trip,'route_id':route,'starts_at':'2035-08-01T09:00:00+04:00','ends_at':'2035-08-02T18:00:00+04:00',
      'timezone':'Europe/Saratov','meeting_at':'2035-08-01T08:30:00+04:00','meeting_point':'Причал','responsible_names':'Организатор',
      'capacity':2,'base_price_kopeks':100000,'status':'open','notes':'Вымышленные данные платежей'}
    require(save(a,team,trip,fields)[0]['status']=='accepted','Trip failed')
    def command(kind,payload,version=0,client=a,operation=None):
        envelope={'p_operation_id':operation or uid(),'p_team_id':team,'p_trip_id':trip if kind!='save_person' else None,
          'p_kind':kind,'p_payload':payload,'p_expected_version':version}
        return client.post('/rest/v1/rpc/people_command',envelope),envelope
    def snapshot(client=a):return client.post('/rest/v1/rpc/roster_snapshot',{'p_trip_id':trip,'p_after_revision':-1})
    people=[uid() for _ in range(3)]; ids=[uid() for _ in range(3)]
    for i,p in enumerate(people):require(command('save_person',{'id':p,'name':f'Семья {i} {trip}'})[0]['status']=='accepted','Person failed')
    require(command('save_booking',{'id':booking,'contact_name':'Контакт семьи','members':[
      {'id':i,'person_id':p,'role':'client','parameters':{}} for i,p in zip(ids,people)]})[0]['status']=='accepted','Family failed')
    s=snapshot();require(s['finance_protocol']==1 and s['payments']==[],'Missing finance snapshot')
    require(all(p['agreed_price_kopeks']==100000 for p in s['participations']),'Initial agreed prices wrong')
    require(save(a,team,trip,{**fields,'base_price_kopeks':200000},version=1)[0]['status']=='accepted','Base price failed')
    require(all(p['agreed_price_kopeks']==100000 for p in snapshot()['participations']),'Base price changed old agreements')
    prices={'booking_id':booking,'reason':'Согласовано с семьёй','lines':[{'id':p['id'],'version':p['version'],'amount_kopeks':100000} for p in snapshot()['participations']]}
    require(command('set_prices',prices)[0]['status']=='accepted','Price command failed')
    require(command('set_prices',prices)[0]['reason']=='version_conflict','Stale price overwrote a change')
    require(len(snapshot()['price_history'])==3,'No price audit')
    new_person,new_part,new_booking=uid(),uid(),uid()
    command('save_person',{'id':new_person,'name':'Новая запись после изменения базы'})
    require(command('save_booking',{'id':new_booking,'contact_name':'Новая заявка','members':[{'id':new_part,'person_id':new_person,'role':'client','parameters':{}}]})[0]['status']=='accepted','New visitor failed')
    require(next(p['agreed_price_kopeks'] for p in snapshot()['participations'] if p['id']==new_part)==200000,'New booking missed the changed base price')
    def lines(*amounts):return [{'participation_id':p,'amount_kopeks':n} for p,n in zip(ids,amounts) if n]
    def pay(amount,allocation,direction='income'):
        return {'id':uid(),'booking_id':booking,'amount_kopeks':amount,'allocations':allocation,'direction':direction,
          'method':'transfer','occurred_at':'2035-07-01T12:30:00+04:00','notes':'Тестовый платёж'}
    first=pay(250000,lines(100000,100000,50000)); accepted,envelope=command('add_payment',first)
    require(accepted['status']=='accepted',accepted);require(b.post('/rest/v1/rpc/people_command',envelope)==accepted,'Replay differs')
    require(len(snapshot()['payments'])==1,'Payment duplicated')
    expect_rpc_error(lambda:command('add_payment',{**pay(10000,[]),'occurred_at':'infinity'}),'22023')
    expect_rpc_error(lambda:command('add_payment',pay(10000,[{'participation_id':new_part,'amount_kopeks':10000}])),'42501')
    second=pay(100000,lines(50000,0,50000));require(command('add_payment',second)[0]['status']=='accepted','Overpayment rejected')
    refund=pay(30000,lines(30000,0,0),'refund');require(command('add_payment',refund)[0]['status']=='accepted','Refund failed')
    def total():return sum(p['signed_kopeks'] for p in snapshot()['payments'])
    require(total()==320000,'Payments counted more than once')
    require(command('add_payment',pay(500000,[],'refund'))[0]['reason']=='refund_exceeds_received','Excess refund accepted')
    require(command('add_payment',pay(10000,[],'refund'))[0]['reason']=='refund_allocation_required','Unfunded unallocated refund accepted')
    expect_rpc_error(lambda:command('add_payment',pay(10000,lines(20000,0,0))),'22023')
    require(total()==320000 and len(snapshot()['payments'])==3,'A rejected command partially wrote the ledger')
    allocation={'id':first['id'],'booking_id':booking,'reason':'Распределение уточнено','allocations':lines(90000,100000,60000)}
    require(command('allocate_payment',allocation,version=1)[0]['status']=='accepted','Allocation failed')
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        jobs=[pool.submit(command,'allocate_payment',allocation,2,c) for c in [a,b]]
        results=[j.result()[0] for j in jobs]
    require(sum(r['status']=='accepted' for r in results)==1 and any(r.get('reason')=='version_conflict' for r in results),'Allocation CAS failed')
    correction={'id':second['id'],'booking_id':booking,'reason':'Опечатка в сумме','reversal_id':uid(),
      'replacement':pay(80000,lines(30000,0,50000))}
    corrected,envelope=command('correct_payment',correction,version=1)
    require(corrected['status']=='accepted',corrected);require(a.post('/rest/v1/rpc/people_command',envelope)==corrected,'Correction replay differs')
    require(total()==300000 and len(snapshot()['payments'])==5,'Correction lost history or doubled cash')
    require(command('allocate_payment',{**allocation,'id':second['id']},version=2)[0]['reason']=='payment_reversed','Reversed payment changed')
    version=next(p['version'] for p in snapshot()['payments'] if p['id']==first['id'])
    require(command('correct_payment',{'id':first['id'],'booking_id':booking,'reversal_id':uid(),'replacement':None,'reason':'Ошибочная запись'},version)[0]['status']=='accepted','Void failed')
    require(total()==50000,'Void lost refund effects')
    require(len(snapshot()['allocation_history'])>=6,'Allocation history missing')
    expect_rpc_error(lambda:snapshot(denied),'42501')
    expect_rpc_error(lambda:denied.post('/rest/v1/rpc/people_command',envelope),'42501')
    print('PASS agreed prices, base-price independence, partial/overpayment, refund, allocation CAS, immutable correction, replay and access')
    print('Synthetic trip:',trip)
if __name__=='__main__':
    try: main()
    except urllib.error.HTTPError as error: raise SystemExit(error.read().decode()) from None
