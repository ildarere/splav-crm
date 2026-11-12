alter table splav.groups alter column base_price_kopeks set default 700000;
update splav.groups set base_price_kopeks=700000, metadata_version=metadata_version+1;
