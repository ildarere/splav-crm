-- A measurements change releases an ineligible conditional seat atomically.
create or replace function splav.ops_participation_changed() returns trigger language plpgsql set search_path='' as $$
begin
 if new.status<>'confirmed' then
  update splav.ops_crews set reservation_id=null,seat=null,version=version+1,author_id=coalesce(auth.uid(),author_id),updated_at=now()
    where registration_id=new.id and group_id=new.group_id and reservation_id is not null;
  update splav.ops_travel set mode='unset',reservation_id=null,seat=null,point_id=null,version=version+1,author_id=coalesce(auth.uid(),author_id),updated_at=now()
    where subject_kind='participant' and subject_id=new.id and group_id=new.group_id and mode<>'unset';
 elsif new.parameters is distinct from old.parameters then
  update splav.ops_crews c set reservation_id=null,seat=null,version=c.version+1,author_id=coalesce(auth.uid(),c.author_id),updated_at=now()
    from splav.ops_reservations b join splav.ops_resources r on r.id=b.resource_id
    where c.registration_id=new.id and c.group_id=new.group_id and c.reservation_id=b.id and not splav.ops_check_seat(r.data,b.capacity,c.seat,new.parameters);
 end if;
 return new;
end $$;

