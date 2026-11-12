-- V1 allowed route names of any length, including an empty string. Migration must retain them.
-- New route commands validate names explicitly without constraining legacy rows.
alter table splav.routes drop constraint if exists routes_name_check;

-- Timestamp serialization follows the database session timezone.
alter function splav.trip_json(splav.groups) stable;
