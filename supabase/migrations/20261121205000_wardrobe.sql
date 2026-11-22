-- Every photo revision has its own immutable Storage paths.
create table public.wardrobe_photo_uploads (
    revision uuid primary key,
    owner_id uuid not null references auth.users(id) on delete cascade,
    item_id uuid not null,
    has_cleaned boolean not null,
    state text not null default 'staging' check (state in ('staging', 'in_use', 'cleanup')),
    created_at timestamptz not null default now(),
    cleanup_after timestamptz
);
create index wardrobe_photo_uploads_owner_state on public.wardrobe_photo_uploads(owner_id, state, created_at);

create table public.wardrobe_items (
    id uuid primary key,
    owner_id uuid not null references auth.users(id) on delete cascade,
    name text check (char_length(name) <= 100),
    category text not null check (category in ('tshirt', 'pants', 'shoes', 'accessory')),
    photo_revision uuid not null references public.wardrobe_photo_uploads(revision),
    original_path text not null,
    cleaned_path text,
    thumbnail_path text not null,
    prefers_cleaned boolean not null,
    row_version uuid not null default gen_random_uuid(),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    check (original_path = owner_id::text || '/' || id || '/' || photo_revision || '/original.jpg'),
    check (cleaned_path is null or cleaned_path = owner_id::text || '/' || id || '/' || photo_revision || '/cleaned.jpg'),
    check (thumbnail_path = owner_id::text || '/' || id || '/' || photo_revision || '/thumbnail.jpg'),
    check (not prefers_cleaned or cleaned_path is not null)
);
create index wardrobe_items_owner_updated on public.wardrobe_items(owner_id, updated_at desc, id);

alter table public.wardrobe_items enable row level security;
alter table public.wardrobe_photo_uploads enable row level security;

revoke all on public.wardrobe_items, public.wardrobe_photo_uploads from public, anon, authenticated;
grant select, delete on public.wardrobe_items to authenticated;
grant select on public.wardrobe_photo_uploads to authenticated;
grant insert (id, owner_id, name, category, photo_revision, original_path, cleaned_path, thumbnail_path, prefers_cleaned),
    update (name, category, photo_revision, original_path, cleaned_path, thumbnail_path, prefers_cleaned)
    on public.wardrobe_items to authenticated;
grant insert (revision, owner_id, item_id, has_cleaned) on public.wardrobe_photo_uploads to authenticated;

create policy wardrobe_items_read on public.wardrobe_items for select to authenticated using (owner_id = (select auth.uid()));
create policy wardrobe_items_add on public.wardrobe_items for insert to authenticated with check (owner_id = (select auth.uid()));
create policy wardrobe_items_edit on public.wardrobe_items for update to authenticated
    using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy wardrobe_items_delete on public.wardrobe_items for delete to authenticated using (owner_id = (select auth.uid()));
create policy wardrobe_uploads_read on public.wardrobe_photo_uploads for select to authenticated using (owner_id = (select auth.uid()));
create policy wardrobe_uploads_stage on public.wardrobe_photo_uploads for insert to authenticated with check (owner_id = (select auth.uid()));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('wardrobe-photos', 'wardrobe-photos', false, 8388608, array['image/jpeg']);

-- Restrictive policies keep this bucket private even if another feature has a wider Storage policy.
create policy wardrobe_storage_owner on storage.objects as restrictive for all to public
    using (bucket_id <> 'wardrobe-photos' or (storage.foldername(name))[1] = (select auth.uid())::text)
    with check (bucket_id <> 'wardrobe-photos' or (storage.foldername(name))[1] = (select auth.uid())::text);
create policy wardrobe_storage_read on storage.objects for select to authenticated
    using (bucket_id = 'wardrobe-photos');
create policy wardrobe_storage_no_overwrite on storage.objects as restrictive for update to public
    using (bucket_id <> 'wardrobe-photos') with check (bucket_id <> 'wardrobe-photos');

-- Evaluate the upload state without expanding authenticated table grants to anonymous callers.
create function public.wardrobe_storage_has_upload(object_name text, required_state text) returns boolean
language sql stable security definer set search_path = '' as $$
    select exists (
        select 1 from public.wardrobe_photo_uploads as upload
        where upload.owner_id = (select auth.uid()) and upload.state = required_state
          and storage.foldername(object_name) = array[upload.owner_id::text, upload.item_id::text, upload.revision::text]
          and (storage.filename(object_name) in ('original.jpg', 'thumbnail.jpg')
              or (upload.has_cleaned and storage.filename(object_name) = 'cleaned.jpg'))
    );
$$;
revoke all on function public.wardrobe_storage_has_upload(text, text) from public;
grant execute on function public.wardrobe_storage_has_upload(text, text) to anon, authenticated, service_role;

create policy wardrobe_storage_requires_stage on storage.objects as restrictive for insert to public
    with check (bucket_id <> 'wardrobe-photos' or public.wardrobe_storage_has_upload(name, 'staging'));
create policy wardrobe_storage_add on storage.objects for insert to authenticated
    with check (bucket_id = 'wardrobe-photos');

create policy wardrobe_storage_requires_cleanup on storage.objects as restrictive for delete to public
    using (bucket_id <> 'wardrobe-photos' or public.wardrobe_storage_has_upload(name, 'cleanup'));
create policy wardrobe_storage_remove on storage.objects for delete to authenticated
    using (bucket_id = 'wardrobe-photos');

-- Commit an uploaded revision and retire the previous one in the same transaction as the item.
create function public.wardrobe_commit_photo() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
    new_photo boolean;
begin
    if tg_op = 'DELETE' then
        update public.wardrobe_photo_uploads set state = 'cleanup' where revision = old.photo_revision;
        return old;
    end if;

    new_photo := tg_op = 'INSERT';
    if tg_op = 'UPDATE' then
        new.updated_at := clock_timestamp();
        new.row_version := gen_random_uuid();
        new_photo := new.photo_revision <> old.photo_revision;
        if not new_photo and
            (new.original_path, new.cleaned_path, new.thumbnail_path, new.prefers_cleaned)
            is distinct from
            (old.original_path, old.cleaned_path, old.thumbnail_path, old.prefers_cleaned) then
            raise exception 'Changing photo fields requires a new photo revision';
        end if;
    end if;

    if new_photo then
        update public.wardrobe_photo_uploads set state = 'in_use'
            where revision = new.photo_revision and owner_id = new.owner_id and item_id = new.id
              and has_cleaned = (new.cleaned_path is not null) and state = 'staging';
        if not found then
            raise exception 'Wardrobe upload is no longer available';
        end if;

        if (select count(*) from storage.objects
            where bucket_id = 'wardrobe-photos' and name in (new.original_path, new.cleaned_path, new.thumbnail_path))
            <> (case when new.cleaned_path is null then 2 else 3 end) then
            raise exception 'Wardrobe photos have not finished uploading';
        end if;

        if tg_op = 'UPDATE' then
            update public.wardrobe_photo_uploads set state = 'cleanup' where revision = old.photo_revision;
        end if;
    end if;
    return new;
end;
$$;

revoke all on function public.wardrobe_commit_photo() from public, anon, authenticated;
create trigger wardrobe_commit_photo before insert or update or delete on public.wardrobe_items
    for each row execute function public.wardrobe_commit_photo();

-- Both operations lock the upload row, so cleanup and photo commit cannot win the same revision.
create function public.wardrobe_abandon_upload(upload_revision uuid) returns void
language sql security definer set search_path = '' as $$
    -- Retain the entry briefly in case an interrupted upload is still completing at Storage.
    update public.wardrobe_photo_uploads set state = 'cleanup', cleanup_after = now() + interval '2 minutes'
    where owner_id = (select auth.uid()) and revision = upload_revision and state = 'staging';
$$;

create function public.wardrobe_expire_uploads() returns void
language sql security definer set search_path = '' as $$
    update public.wardrobe_photo_uploads set state = 'cleanup'
    where owner_id = (select auth.uid()) and state = 'staging' and created_at < now() - interval '1 day';
$$;

-- The client removes bytes through the Storage API. Verify its object metadata is gone before
-- forgetting the cleanup entry, even if Storage reported partial success without an error.
create function public.wardrobe_finish_cleanup(upload_revision uuid) returns boolean
language sql security definer set search_path = '' as $$
    with finished as (
        delete from public.wardrobe_photo_uploads as upload
        where upload.revision = upload_revision and upload.owner_id = (select auth.uid())
            and upload.state = 'cleanup' and coalesce(upload.cleanup_after, now()) <= now()
            and not exists (
                select 1 from storage.objects as object where object.bucket_id = 'wardrobe-photos'
                  and object.name in (
                    upload.owner_id || '/' || upload.item_id || '/' || upload.revision || '/original.jpg',
                    upload.owner_id || '/' || upload.item_id || '/' || upload.revision || '/cleaned.jpg',
                    upload.owner_id || '/' || upload.item_id || '/' || upload.revision || '/thumbnail.jpg'
                  )
            )
        returning 1
    )
    select exists (select 1 from finished) or not exists (
        select 1 from public.wardrobe_photo_uploads where revision = upload_revision and owner_id = (select auth.uid())
    );
$$;

revoke all on function public.wardrobe_abandon_upload(uuid), public.wardrobe_expire_uploads(),
    public.wardrobe_finish_cleanup(uuid) from public, anon, authenticated;
grant execute on function public.wardrobe_abandon_upload(uuid), public.wardrobe_expire_uploads(),
    public.wardrobe_finish_cleanup(uuid) to authenticated;
