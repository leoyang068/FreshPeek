-- 智能冰箱 V1 后端补充迁移。
-- 可在 Supabase SQL Editor 中整体运行；重复运行保持幂等。

create extension if not exists pgcrypto;

alter table public.recognition_events
  add column if not exists source_event_id uuid,
  add column if not exists food_index integer,
  add column if not exists food_name text,
  add column if not exists canonical_name text,
  add column if not exists recognition_confidence text,
  add column if not exists target_clarity text,
  add column if not exists hand_occlusion text,
  add column if not exists best_frame_storage_path text;

create unique index if not exists recognition_event_item_idempotency
  on public.recognition_events (owner_id, source_event_id, food_index)
  where source_event_id is not null and food_index is not null;

create index if not exists recognition_events_match_lookup
  on public.recognition_events (owner_id, canonical_name, created_at desc);

create unique index if not exists reference_image_storage_path_unique
  on public.inventory_reference_images (storage_path);

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'inventory-reference-images',
  'inventory-reference-images',
  false,
  2097152,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- App 只能访问完成界面功能所需的最小数据集；事件和参考图只给服务端使用。
revoke all on public.inventory_items,
              public.recognition_events,
              public.inventory_reference_images,
              public.shelf_life_rules,
              public.user_settings
from authenticated;

grant select, insert, update, delete on public.inventory_items to authenticated;
grant select, insert, update, delete on public.user_settings to authenticated;
grant select on public.shelf_life_rules to authenticated;

alter table public.inventory_items enable row level security;
alter table public.recognition_events enable row level security;
alter table public.inventory_reference_images enable row level security;
alter table public.shelf_life_rules enable row level security;
alter table public.user_settings enable row level security;

drop policy if exists "users manage own inventory" on public.inventory_items;
create policy "users manage own inventory"
on public.inventory_items for all to authenticated
using (owner_id = (select auth.uid()))
with check (owner_id = (select auth.uid()));

drop policy if exists "users manage own recognition events" on public.recognition_events;
create policy "users manage own recognition events"
on public.recognition_events for all to authenticated
using (owner_id = (select auth.uid()))
with check (owner_id = (select auth.uid()));

drop policy if exists "users manage own reference images" on public.inventory_reference_images;
create policy "users manage own reference images"
on public.inventory_reference_images for all to authenticated
using (owner_id = (select auth.uid()))
with check (owner_id = (select auth.uid()));

drop policy if exists "users manage own shelf life rules" on public.shelf_life_rules;
create policy "users manage own shelf life rules"
on public.shelf_life_rules for all to authenticated
using (owner_id = (select auth.uid()))
with check (owner_id = (select auth.uid()));

drop policy if exists "users manage own settings" on public.user_settings;
create policy "users manage own settings"
on public.user_settings for all to authenticated
using (owner_id = (select auth.uid()))
with check (owner_id = (select auth.uid()));

-- 为 App 的实时库存刷新启用复制发布。
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'inventory_items'
  ) then
    alter publication supabase_realtime add table public.inventory_items;
  end if;
end
$$;

create or replace function public.apply_fridge_item_event(
  p_owner_id uuid,
  p_source_event_id uuid,
  p_food_index integer,
  p_payload jsonb,
  p_match_inventory_id uuid default null,
  p_shelf_life_days integer default null,
  p_decision_reason text default null,
  p_best_frame_path text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
  v_existing_event record;
  v_candidate record;
  v_inventory_id uuid;
  v_action text := 'no_action';
  v_reason text := coalesce(p_decision_reason, 'no_action');
  v_direction text := lower(coalesce(p_payload->>'direction', ''));
  v_food_name text := nullif(trim(p_payload->>'name'), '');
  v_canonical_name text := nullif(trim(p_payload->>'canonical_name'), '');
  v_gesture boolean := coalesce((p_payload->>'gesture')::boolean, false);
  v_confidence text := coalesce(p_payload->>'recognition_confidence', 'low');
  v_clarity text := coalesce(p_payload->>'target_clarity', 'poor');
  v_occlusion text := coalesce(p_payload->>'hand_occlusion', 'high');
  v_threshold integer := 3;
  v_days integer := greatest(1, least(coalesce(p_shelf_life_days, 3), 365));
  v_new_expiry date := current_date + greatest(1, least(coalesce(p_shelf_life_days, 3), 365));
begin
  if p_owner_id is null or p_source_event_id is null or p_food_index is null then
    raise exception 'owner_id, source_event_id and food_index are required';
  end if;

  if v_direction not in ('in', 'out') then
    raise exception 'invalid direction';
  end if;

  if v_food_name is null then
    raise exception 'food name is required';
  end if;

  v_canonical_name := coalesce(v_canonical_name, v_food_name);

  select id, action, matched_inventory_id, decision_reason
  into v_existing_event
  from public.recognition_events
  where owner_id = p_owner_id
    and source_event_id = p_source_event_id
    and food_index = p_food_index;

  if found then
    return jsonb_build_object(
      'event_record_id', v_existing_event.id,
      'action', v_existing_event.action,
      'inventory_item_id', v_existing_event.matched_inventory_id,
      'reason', v_existing_event.decision_reason,
      'duplicate', true
    );
  end if;

  v_event_id := gen_random_uuid();

  insert into public.recognition_events (
    id,
    owner_id,
    source_event_id,
    food_index,
    direction,
    food_name,
    canonical_name,
    recognition_confidence,
    target_clarity,
    hand_occlusion,
    raw_result,
    normalized_result,
    action,
    decision_reason,
    best_frame_storage_path
  ) values (
    v_event_id,
    p_owner_id,
    p_source_event_id,
    p_food_index,
    v_direction,
    v_food_name,
    v_canonical_name,
    v_confidence,
    v_clarity,
    v_occlusion,
    p_payload,
    p_payload,
    'no_action',
    v_reason,
    p_best_frame_path
  );

  select coalesce(expiring_threshold_days, 3)
  into v_threshold
  from public.user_settings
  where owner_id = p_owner_id;

  v_threshold := coalesce(v_threshold, 3);

  if v_direction = 'in' then
    select *
    into v_candidate
    from public.inventory_items
    where owner_id = p_owner_id
      and deleted_at is null
      and lower(trim(canonical_name)) = lower(trim(v_canonical_name))
    order by expiry_date asc, created_at asc
    limit 1
    for update;

    if v_gesture and found then
      v_inventory_id := v_candidate.id;
      v_action := 'no_action';
      v_reason := 'return_matched_existing';
    elsif v_gesture then
      select i.*
      into v_candidate
      from public.inventory_items i
      join public.recognition_events e on e.matched_inventory_id = i.id
      where i.owner_id = p_owner_id
        and i.deleted_at is not null
        and i.deleted_at::date = current_date
        and lower(trim(i.canonical_name)) = lower(trim(v_canonical_name))
        and e.action = 'deleted'
      order by e.created_at desc
      limit 1
      for update of i;

      if found then
        update public.inventory_items
        set deleted_at = null,
            updated_at = now()
        where id = v_candidate.id;

        v_inventory_id := v_candidate.id;
        v_action := 'restored';
        v_reason := 'return_restored_today_outgoing';
      end if;
    end if;

    if v_inventory_id is null and not v_gesture then
      select *
      into v_candidate
      from public.inventory_items
      where owner_id = p_owner_id
        and deleted_at is null
        and lower(trim(canonical_name)) = lower(trim(v_canonical_name))
        and expiry_date > current_date + v_threshold
      order by expiry_date asc, created_at asc
      limit 1
      for update;

      if found then
        update public.inventory_items
        set added_at = case when v_new_expiry < v_candidate.expiry_date then now() else added_at end,
            last_added_at = now(),
            shelf_life_days = case when v_new_expiry < v_candidate.expiry_date then v_days else shelf_life_days end,
            expiry_date = least(expiry_date, v_new_expiry),
            updated_at = now()
        where id = v_candidate.id;

        v_inventory_id := v_candidate.id;
        v_action := 'merged';
        v_reason := 'merged_same_name_fresh_item';
      end if;
    end if;

    if v_inventory_id is null then
      v_inventory_id := gen_random_uuid();

      insert into public.inventory_items (
        id,
        owner_id,
        food_name,
        canonical_name,
        added_at,
        last_added_at,
        shelf_life_days,
        expiry_date,
        user_corrected,
        created_at,
        updated_at
      ) values (
        v_inventory_id,
        p_owner_id,
        v_food_name,
        v_canonical_name,
        now(),
        now(),
        v_days,
        v_new_expiry,
        false,
        now(),
        now()
      );

      v_action := 'created';
      v_reason := case when v_gesture then 'return_not_found_created' else 'new_inventory_item' end;
    end if;
  else
    if p_match_inventory_id is not null then
      select *
      into v_candidate
      from public.inventory_items
      where id = p_match_inventory_id
        and owner_id = p_owner_id
        and deleted_at is null
      for update;

      if found then
        update public.inventory_items
        set deleted_at = now(),
            updated_at = now()
        where id = v_candidate.id;

        v_inventory_id := v_candidate.id;
        v_action := 'deleted';
        v_reason := coalesce(p_decision_reason, 'matched_outgoing_item');
      else
        v_reason := 'candidate_missing_or_already_deleted';
      end if;
    else
      v_reason := coalesce(p_decision_reason, 'no_reliable_outgoing_match');
    end if;
  end if;

  update public.recognition_events
  set action = v_action,
      matched_inventory_id = v_inventory_id,
      decision_reason = v_reason,
      normalized_result = p_payload
  where id = v_event_id;

  return jsonb_build_object(
    'event_record_id', v_event_id,
    'action', v_action,
    'inventory_item_id', v_inventory_id,
    'reason', v_reason,
    'duplicate', false
  );
exception
  when unique_violation then
    select id, action, matched_inventory_id, decision_reason
    into v_existing_event
    from public.recognition_events
    where owner_id = p_owner_id
      and source_event_id = p_source_event_id
      and food_index = p_food_index;

    return jsonb_build_object(
      'event_record_id', v_existing_event.id,
      'action', v_existing_event.action,
      'inventory_item_id', v_existing_event.matched_inventory_id,
      'reason', v_existing_event.decision_reason,
      'duplicate', true
    );
end;
$$;

revoke all on function public.apply_fridge_item_event(uuid, uuid, integer, jsonb, uuid, integer, text, text)
from public, anon, authenticated;

grant execute on function public.apply_fridge_item_event(uuid, uuid, integer, jsonb, uuid, integer, text, text)
to service_role;
