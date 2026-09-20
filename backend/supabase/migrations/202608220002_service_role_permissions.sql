-- Edge Functions use service_role for trusted server-side inventory processing.
-- RLS bypass does not replace PostgreSQL table privileges, so grant them explicitly.

grant select, insert, update, delete
on table public.inventory_items,
         public.recognition_events,
         public.inventory_reference_images,
         public.shelf_life_rules,
         public.user_settings
to service_role;
