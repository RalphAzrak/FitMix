-- Minimal Supabase roles and metadata used to exercise RLS in the disposable test cluster.
create role anon;
create role authenticated;
create role service_role bypassrls;
create schema auth;
create schema storage;
create table auth.users (id uuid primary key);

create function auth.uid() returns uuid language sql stable as
$$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create table storage.buckets (
    id text primary key, name text not null, public boolean default false,
    file_size_limit bigint, allowed_mime_types text[]
);
create table storage.objects (
    id uuid primary key default gen_random_uuid(), bucket_id text not null references storage.buckets(id),
    name text not null, unique(bucket_id, name)
);
create function storage.foldername(name text) returns text[] language sql immutable as
$$ select (string_to_array(name, '/'))[1:cardinality(string_to_array(name, '/')) - 1] $$;
create function storage.filename(name text) returns text language sql immutable as
$$ select (string_to_array(name, '/'))[cardinality(string_to_array(name, '/'))] $$;
alter table storage.objects enable row level security;
grant usage on schema auth, storage to anon, authenticated;
grant select, insert, update, delete on storage.objects, storage.buckets to anon, authenticated;
