"""Exercise atomic import and replay using only invented records in a test team."""
import copy,json,os,uuid
from server_acceptance import Client,require,expect_rpc_error
from stage45_acceptance import prepare_team,TEST_TEAM
def uid():return str(uuid.uuid4())
def fixture():
    batch,trip,person,booking,part,pay,route=[uid() for _ in range(7)]
    return {'version':1,'team_id':TEST_TEAM,'batch_id':batch,'files':[{'name':'synthetic.xlsx','sha256':'0'*64}],
      'route_id':route,'route_name':'Импорт проверка '+batch,
      'trips':[{'id':trip,'starts_on':'2026-08-31','ends_on':'2026-09-01','title':'Тест импорта '+batch,'notes':'Вымышленные данные','base_price_kopeks':700000}],
      'people':[{'id':person,'name':'Вымышленный участник','phone':'+79990000000','notes':'Тест'}],
      'bookings':[{'id':booking,'trip_id':trip,'contact_person_id':person,'contact_name':'Тест','phone':'','notes':''}],
      'participations':[{'id':part,'trip_id':trip,'person_id':person,'booking_id':booking,'role':'client','status':'confirmed','parameters':{},'price':700000,'payment_recorded':True}],
      'payments':[{'id':pay,'trip_id':trip,'booking_id':booking,'amount':50000,'allocations':[{'participation_id':part,'amount_kopeks':50000}],'notes':'Тест предоплаты'}],
      'crews':[{'trip_id':trip,'label':'Лодка 2','participation_ids':[part],'note':'Инвентарный номер не известен'}],
      'records':[{'file':'synthetic.xlsx','sheet':'31-1','row':4,'kind':'participation','entity_id':part,'data':{'original_name':'Вымышленный участник'}}],
      'issues':[{'file':'synthetic.xlsx','sheet':'31-1','row':8,'kind':'unassigned_money','detail':{'amount_kopeks':10000}}]}
def main():
    prepare_team();key=os.environ['SPLAV_SUPABASE_KEY'];url='http://127.0.0.1:54321'
    a=Client(url,key,'organizer-a@example.com');denied=Client(url,key,'organizer-c@example.com')
    data=fixture()
    def send(d,client=a):return client.post('/rest/v1/rpc/import_excel_batch',{'p_batch_id':d['batch_id'],'p_team_id':d['team_id'],'p_manifest':d})
    expect_rpc_error(lambda:send(data,denied),'42501')
    first=send(data);require(first['trips']==1 and first['payments']==1,first)
    second=send(data);require(second['replayed'] is True,'Repeat created another batch')
    snapshot=a.post('/rest/v1/rpc/roster_snapshot',{'p_trip_id':data['trips'][0]['id'],'p_after_revision':-1})
    require(len(snapshot['participations'])==1 and len(snapshot['payments'])==1,'Replay duplicated data')
    require(snapshot['payments'][0]['source_date_unknown'] is True,'Unknown date fabricated')
    require(len(snapshot['operations']['imported_crews'])==1,'Historical crew lost')
    changed=copy.deepcopy(data);changed['people'][0]['name']='Different'
    expect_rpc_error(lambda:send(changed),'22023')
    bad=fixture();bad['payments'][0]['allocations'][0]['amount_kopeks']=60000
    expect_rpc_error(lambda:send(bad),'22023')
    catalog=a.post('/rest/v1/rpc/list_trips',{})
    require(not any(t['id']==bad['trips'][0]['id'] for t in catalog['trips']),'Failed import partially committed')
    imported=next(t for t in catalog['trips'] if t['id']==data['trips'][0]['id'])
    require(imported['import_metadata']['date_only'] and imported['import_metadata']['capacity_known'] is False,'Missing metadata lost')
    require(not imported['capacity_exceeded'],'Technical capacity placeholder reported as real overflow')
    print('PASS admin access, transaction rollback, idempotent replay, UUID binding, unknown dates/capacity and historical crew snapshot')
if __name__=='__main__':main()
