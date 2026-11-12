create or replace function splav.auto_bus_registration() returns trigger language plpgsql security definer set search_path=splav,public as $$
declare ride record;
begin
 perform splav.fill_bus(new.group_id,'outbound');
 perform splav.fill_bus(new.group_id,'return');
 for ride in select id,data->>'direction' direction from splav.ops_reservations where group_id=new.group_id and kind='ride' and active order by id loop
  perform splav.fill_bus(new.group_id,ride.direction,ride.id);
 end loop;
 return null;
end $$;
