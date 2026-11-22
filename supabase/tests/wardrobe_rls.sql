-- Run with psql -X -v ON_ERROR_STOP=1 -f supabase/tests/wardrobe_rls.sql against a fresh,
-- disposable PostgreSQL cluster. Storage object rows stand in for successful uploads.
begin;
\ir fixtures/wardrobe_dependencies.sql
\ir ../migrations/20261121205000_wardrobe.sql

create function pg_temp.check_that(ok boolean, description text) returns void
language plpgsql as $$
begin
    if ok is distinct from true then raise exception 'Wardrobe test failed: %', description; end if;
end;
$$;

create function pg_temp.upload_files(upload uuid, item uuid, files text[]) returns void
language sql as $$
    insert into storage.objects (bucket_id, name)
    select 'wardrobe-photos', auth.uid() || '/' || item || '/' || upload || '/' || file
    from unnest(files) as file;
$$;

insert into auth.users(id) values
    ('e3043504-bb9c-41da-8ba5-1641ee830aaa'), ('e3043504-bb9c-41da-8ba5-1641ee830bbb');

-- Exercise the wardrobe restrictions even alongside a permissive legacy policy.
create policy wardrobe_test_legacy_policy on storage.objects for all to public using (true) with check (true);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'e3043504-bb9c-41da-8ba5-1641ee830aaa', true);
select set_config('request.jwt.claims', '{"sub":"e3043504-bb9c-41da-8ba5-1641ee830aaa","role":"authenticated"}', true);

do $$
declare
    owner uuid := auth.uid();
    item uuid := '295410f5-a545-4a84-8a09-681c97d63333';
    initial uuid := '3b1e1aaa-beac-49ad-be68-62a411489111';
    replacement uuid := '3b1e1aaa-beac-49ad-be68-62a411489222';
    partial uuid := '3b1e1aaa-beac-49ad-be68-62a411489333';
    initial_prefix text := owner || '/' || item || '/' || initial || '/';
    next_prefix text := owner || '/' || item || '/' || replacement || '/';
    initial_row_version uuid;
    changed integer;
begin
    insert into public.wardrobe_photo_uploads (revision, owner_id, item_id, has_cleaned)
        values (initial, owner, item, true), (replacement, owner, item, false), (partial, owner, item, false);
    perform pg_temp.upload_files(initial, item, array['original.jpg']);
    begin
        insert into public.wardrobe_items (id, owner_id, name, category, photo_revision, original_path, cleaned_path, thumbnail_path, prefers_cleaned)
        values (item, owner, 'White tee', 'tshirt', initial, initial_prefix || 'original.jpg',
                initial_prefix || 'cleaned.jpg', initial_prefix || 'thumbnail.jpg', true);
        raise exception 'incomplete upload was published';
    exception when raise_exception then
        if sqlerrm <> 'Wardrobe photos have not finished uploading' then raise; end if;
    end;

    perform pg_temp.upload_files(initial, item, array['cleaned.jpg', 'thumbnail.jpg']);
    insert into public.wardrobe_items (id, owner_id, name, category, photo_revision, original_path, cleaned_path, thumbnail_path, prefers_cleaned)
        values (item, owner, 'White tee', 'tshirt', initial, initial_prefix || 'original.jpg',
                initial_prefix || 'cleaned.jpg', initial_prefix || 'thumbnail.jpg', true)
        returning row_version into initial_row_version;
    perform public.wardrobe_abandon_upload(initial);
    perform pg_temp.check_that((select state = 'in_use' from public.wardrobe_photo_uploads where revision = initial),
                             'retry must preserve the committed revision');
    perform pg_temp.check_that((select count(*) = 3 from storage.objects where bucket_id = 'wardrobe-photos'
                               and name like initial_prefix || '%'), 'owner can see every active image');
    delete from storage.objects where bucket_id = 'wardrobe-photos' and name = initial_prefix || 'cleaned.jpg';
    get diagnostics changed = row_count;
    perform pg_temp.check_that(changed = 0, 'active files cannot be deleted directly');

    update public.wardrobe_items set name = null, category = 'pants' where id = item;
    perform pg_temp.check_that((select name is null and category = 'pants' and row_version <> initial_row_version
                               from public.wardrobe_items where id = item), 'rename and category edit update the row version');
    perform pg_temp.upload_files(replacement, item, array['original.jpg', 'thumbnail.jpg']);
    update public.wardrobe_items set photo_revision = replacement, original_path = next_prefix || 'original.jpg',
        cleaned_path = null, thumbnail_path = next_prefix || 'thumbnail.jpg', prefers_cleaned = false
        where id = item and row_version = initial_row_version;
    get diagnostics changed = row_count;
    perform pg_temp.check_that(changed = 0, 'a stale edit cannot replace the newer record');
    perform pg_temp.check_that((select state = 'in_use' from public.wardrobe_photo_uploads where revision = initial),
                             'the old image is active until a replacement commits');

    update public.wardrobe_items set photo_revision = replacement, original_path = next_prefix || 'original.jpg',
        cleaned_path = null, thumbnail_path = next_prefix || 'thumbnail.jpg', prefers_cleaned = false where id = item;
    perform pg_temp.check_that((select photo_revision = replacement and cleaned_path is null
                               from public.wardrobe_items where id = item), 'replacement retains the stable item ID');
    perform pg_temp.check_that((select state = 'cleanup' from public.wardrobe_photo_uploads where revision = initial),
                             'replacement durably retires the old photos');
    perform pg_temp.upload_files(partial, item, array['original.jpg']);
    perform public.wardrobe_abandon_upload(partial);
    perform pg_temp.check_that((select state = 'cleanup' from public.wardrobe_photo_uploads where revision = partial),
                             'failed uploads enter the same durable retry queue');
    begin
        perform pg_temp.upload_files(partial, item, array['thumbnail.jpg']);
        raise exception 'an abandoned revision could still accept uploads';
    exception when insufficient_privilege then null;
    end;
end;
$$;

select set_config('request.jwt.claim.sub', 'e3043504-bb9c-41da-8ba5-1641ee830bbb', true);
select set_config('request.jwt.claims', '{"sub":"e3043504-bb9c-41da-8ba5-1641ee830bbb","role":"authenticated"}', true);

select pg_temp.check_that((select count(*) = 0 from public.wardrobe_items), 'second user cannot read items');
select pg_temp.check_that((select count(*) = 0 from public.wardrobe_photo_uploads), 'second user cannot read the upload queue');
select pg_temp.check_that((select count(*) = 0 from storage.objects where bucket_id = 'wardrobe-photos'),
                          'second user cannot see any private image');
do $$
declare
    changed integer;
begin
    update public.wardrobe_items set category = 'shoes';
    get diagnostics changed = row_count;
    perform pg_temp.check_that(changed = 0, 'second user cannot edit items');
    delete from public.wardrobe_items;
    get diagnostics changed = row_count;
    perform pg_temp.check_that(changed = 0, 'second user cannot delete items');
    delete from storage.objects where bucket_id = 'wardrobe-photos';
    get diagnostics changed = row_count;
    perform pg_temp.check_that(changed = 0, 'second user cannot delete photos even during cleanup');
    begin
        insert into storage.objects (bucket_id, name) values ('wardrobe-photos',
            'e3043504-bb9c-41da-8ba5-1641ee830aaa/295410f5-a545-4a84-8a09-681c97d63333/3b1e1aaa-beac-49ad-be68-62a411489333/thumbnail.jpg');
        raise exception 'second user could insert into the owner prefix';
    exception when insufficient_privilege then null;
    end;
end;
$$;

set local role anon;
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.check_that((select count(*) = 0 from storage.objects where bucket_id = 'wardrobe-photos'),
                          'signed-out callers cannot see private images');
insert into storage.buckets (id, name, public) values ('wardrobe-test-other', 'wardrobe-test-other', false);
insert into storage.objects (bucket_id, name) values ('wardrobe-test-other', 'independent.jpg');
select pg_temp.check_that((select count(*) = 1 from storage.objects where bucket_id = 'wardrobe-test-other'),
                          'wardrobe policies do not narrow access to other buckets');

set local role authenticated;
select set_config('request.jwt.claim.sub', 'e3043504-bb9c-41da-8ba5-1641ee830aaa', true);
select set_config('request.jwt.claims', '{"sub":"e3043504-bb9c-41da-8ba5-1641ee830aaa","role":"authenticated"}', true);
delete from public.wardrobe_items;
select pg_temp.check_that((select count(*) = 3 from public.wardrobe_photo_uploads where state = 'cleanup'),
                          'deletion queues the last revision along with any pending cleanup');
select pg_temp.check_that(not public.wardrobe_finish_cleanup('3b1e1aaa-beac-49ad-be68-62a411489111'),
                          'a partial removal cannot clear the retry queue');
delete from storage.objects where bucket_id = 'wardrobe-photos';
select pg_temp.check_that((select count(*) = 0 from storage.objects where bucket_id = 'wardrobe-photos'),
                          'owner can retry and finish removal of retired photos');
select pg_temp.check_that(public.wardrobe_finish_cleanup('3b1e1aaa-beac-49ad-be68-62a411489111'),
                          'old photos clear on successful cleanup');
select pg_temp.check_that(public.wardrobe_finish_cleanup('3b1e1aaa-beac-49ad-be68-62a411489222'),
                          'deleted photos clear on successful cleanup');
select pg_temp.check_that(not public.wardrobe_finish_cleanup('3b1e1aaa-beac-49ad-be68-62a411489333'),
                          'abandoned revision remains queued while a delayed upload might still arrive');

reset role;
update public.wardrobe_photo_uploads set cleanup_after = now() - interval '1 second'
    where revision = '3b1e1aaa-beac-49ad-be68-62a411489333';
set local role authenticated;
select pg_temp.check_that(public.wardrobe_finish_cleanup('3b1e1aaa-beac-49ad-be68-62a411489333'),
                          'abandoned revision clears after the grace period');
select pg_temp.check_that((select count(*) = 0 from public.wardrobe_photo_uploads), 'queue clears on successful cleanup');

-- A process can quit before it has a chance to abandon an interrupted upload.
reset role;
insert into public.wardrobe_photo_uploads (revision, owner_id, item_id, has_cleaned, created_at)
values ('3b1e1aaa-beac-49ad-be68-62a411489444', auth.uid(), '295410f5-a545-4a84-8a09-681c97d63333',
        false, now() - interval '2 days');
set local role authenticated;
select public.wardrobe_expire_uploads();
select pg_temp.check_that((select state = 'cleanup' from public.wardrobe_photo_uploads),
                          'interrupted uploads are queued on a later visit');
select pg_temp.check_that(public.wardrobe_finish_cleanup('3b1e1aaa-beac-49ad-be68-62a411489444'),
                          'an expired upload with no files clears cleanly');

rollback;
