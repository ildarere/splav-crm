create or replace function splav.ops_check_seat(p_resource jsonb,p_capacity integer,p_seat integer,p_parameters jsonb) returns boolean
language sql immutable set search_path='' as $$
 select p_seat between 1 and p_capacity and case
 when p_resource->>'planned'='true' and p_capacity=4 and p_seat=4 then
   coalesce((p_parameters->>'age_years')::numeric>=0 and (p_parameters->>'age_years')::numeric<18,false)
 when p_resource->>'model'='big' and p_capacity=4 and p_seat=4 then
   coalesce((p_parameters->>'height_cm')::numeric>0 and (p_parameters->>'height_cm')::numeric<=130
     and (p_parameters->>'age_years')::numeric>=0 and (p_parameters->>'age_years')::numeric<18,false)
 when p_resource->>'model'='rf' and p_seat=3 then
   coalesce((p_parameters->>'height_cm')::numeric>0 and (p_parameters->>'height_cm')::numeric<=155
     and (p_parameters->>'weight_kg')::numeric>0 and (p_parameters->>'weight_kg')::numeric<=50,false)
 else true end;
$$;
