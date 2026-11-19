-- =============================================================================
-- Melai Nuts — Migration 20261119020000: product ratings and reviews
-- =============================================================================
-- Run after 20261119010000_customer_name_parts.sql. Idempotent, one transaction.
--
-- A signed-in customer rates a product 1-5 stars with an optional comment (at most 500
-- characters, InputLimits.review / Rules::REVIEW_MAX), only for a product they actually
-- received: a COMPLETED order of theirs that contains it. One review per customer per product;
-- they can edit or delete it. Staff and owners can hide / show / delete any review (app only).
--
--   product_reviews                  the reviews. RLS: anyone reads visible rows; a customer
--                                    reads, writes and deletes only their own, and writes only
--                                    with a completed order for that product (can_review_product).
--   product_rating_stats (view)      average rating (1 decimal) and count of visible reviews.
--   get_product_reviews(product, limit, offset)
--                                    visible reviews with the reviewer shown as "Juan D."
--                                    (first name + last initial), newest first. Anyone.
--   my_product_review_status(product)
--                                    {can_review, order_id, review} for the signed-in customer.
--   staff_list_product_reviews(product|null, include_hidden, limit, offset)
--   staff_moderate_product_review(review, 'hide' | 'show' | 'delete')
--                                    active staff / owner; written to staff_audit_logs.
--
-- The customer never chooses the order: when order_id is left out, the trigger takes their
-- latest completed order with the product (RLS still checks it). The customer can only change
-- rating and comment (column grants); moderation columns change only through the staff function.
-- =============================================================================
begin;

-- 1. Table ---------------------------------------------------------------------------------
create table if not exists public.product_reviews (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  customer_id text not null references public.customer_profiles(firebase_uid) on delete cascade,
  order_id text not null references public.orders(id) on delete cascade,
  rating smallint not null,
  comment text not null default '',
  is_hidden boolean not null default false,
  hidden_at timestamptz,
  hidden_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint product_reviews_rating_range check (rating between 1 and 5),
  constraint product_reviews_comment_len check (char_length(comment) <= 500),
  constraint product_reviews_one_per_customer unique (product_id, customer_id)
);
create index if not exists product_reviews_product_visible_idx
  on public.product_reviews (product_id, created_at desc) where not is_hidden;
create index if not exists product_reviews_customer_idx on public.product_reviews (customer_id);
comment on table public.product_reviews is
  'Customer ratings (1-5) and comments. Only for a product of a completed order of the customer; one per customer per product.';

-- 2. Eligibility ---------------------------------------------------------------------------
-- The customer's latest completed order that contains the product (null = may not review).
create or replace function public._reviewable_order(p_uid text, p_product_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select o.id
  from public.orders o
  where o.firebase_uid = p_uid and o.status = 'completed'
    and exists (select 1 from public.order_items oi where oi.order_id = o.id and oi.product_id = p_product_id)
  order by o.created_at desc
  limit 1
$$;
revoke all on function public._reviewable_order(text, uuid) from public, anon, authenticated;

-- Used by the RLS policies: the order is the CALLER's, completed, and contains the product.
-- Only about the signed-in customer (no uid parameter), so it reveals nothing about anyone else.
create or replace function public.can_review_product(p_product_id uuid, p_order_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.current_firebase_uid() is not null and exists (
    select 1 from public.orders o
    where o.id = p_order_id and o.firebase_uid = public.current_firebase_uid() and o.status = 'completed'
      and exists (select 1 from public.order_items oi where oi.order_id = o.id and oi.product_id = p_product_id))
$$;
revoke all on function public.can_review_product(uuid, text) from public, anon;
grant execute on function public.can_review_product(uuid, text) to authenticated;

-- 3. Trigger: fills the order, trims the comment, keeps the keys fixed ----------------------
create or replace function public._product_reviews_before_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.comment := btrim(coalesce(new.comment, ''));
  if tg_op = 'INSERT' then
    if new.order_id is null then
      new.order_id := public._reviewable_order(new.customer_id, new.product_id);
      if new.order_id is null then
        raise exception 'You can review a product only after an order with it is completed.'
          using errcode = '42501';
      end if;
    end if;
    new.created_at := now();
    new.updated_at := now();
    return new;
  end if;
  if new.product_id is distinct from old.product_id or new.customer_id is distinct from old.customer_id then
    raise exception 'A review stays on its product and customer.';
  end if;
  if new.order_id is distinct from old.order_id then
    new.order_id := old.order_id;
  end if;
  if new.rating is distinct from old.rating or new.comment is distinct from old.comment then
    new.updated_at := now();
  else
    new.updated_at := old.updated_at;
  end if;
  new.created_at := old.created_at;
  return new;
end;
$$;
revoke all on function public._product_reviews_before_write() from public, anon, authenticated;
drop trigger if exists product_reviews_before_write on public.product_reviews;
create trigger product_reviews_before_write
  before insert or update on public.product_reviews
  for each row execute function public._product_reviews_before_write();

-- 4. Row-level security ----------------------------------------------------------------------
alter table public.product_reviews enable row level security;
revoke all on public.product_reviews from public, anon, authenticated;
-- Reading: everyone (the shop and the app show reviews to guests too). customer_id and the
-- moderation columns are not readable through the API; names come from get_product_reviews().
grant select (id, product_id, rating, comment, is_hidden, created_at, updated_at) on public.product_reviews to anon, authenticated;
-- Writing: a customer, their own row only (RLS below), rating and comment only.
grant insert (product_id, customer_id, order_id, rating, comment) on public.product_reviews to authenticated;
grant update (rating, comment) on public.product_reviews to authenticated;
grant delete on public.product_reviews to authenticated;
grant select, insert, update, delete on public.product_reviews to service_role;

drop policy if exists "product_reviews: anyone reads visible" on public.product_reviews;
create policy "product_reviews: anyone reads visible" on public.product_reviews
  for select to anon, authenticated using (not is_hidden);
drop policy if exists "product_reviews: customer reads own" on public.product_reviews;
create policy "product_reviews: customer reads own" on public.product_reviews
  for select to authenticated using (customer_id = public.current_firebase_uid());
drop policy if exists "product_reviews: customer writes own after a completed order" on public.product_reviews;
create policy "product_reviews: customer writes own after a completed order" on public.product_reviews
  for insert to authenticated
  with check (customer_id = public.current_firebase_uid()
              and not is_hidden
              and public.can_review_product(product_id, order_id));
drop policy if exists "product_reviews: customer edits own" on public.product_reviews;
create policy "product_reviews: customer edits own" on public.product_reviews
  for update to authenticated
  using (customer_id = public.current_firebase_uid())
  with check (customer_id = public.current_firebase_uid()
              and public.can_review_product(product_id, order_id));
drop policy if exists "product_reviews: customer deletes own" on public.product_reviews;
create policy "product_reviews: customer deletes own" on public.product_reviews
  for delete to authenticated using (customer_id = public.current_firebase_uid());

-- 5. Average rating and count ----------------------------------------------------------------
create or replace view public.product_rating_stats
with (security_invoker = true)
as
  select r.product_id,
         round(avg(r.rating)::numeric, 1) as average_rating,
         count(*)::int as review_count
  from public.product_reviews r
  where not r.is_hidden
  group by r.product_id;
grant select on public.product_rating_stats to anon, authenticated, service_role;
comment on view public.product_rating_stats is
  'Average rating (1 decimal) and number of visible reviews per product. Products without reviews have no row.';

-- 6. Reading reviews (with the reviewer's first name + last initial) -----------------------------
create or replace function public._reviewer_display_name(p_uid text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(nullif(concat_ws(' ', nullif(btrim(f), ''),
                                   case when nullif(btrim(l), '') is not null then upper(left(btrim(l), 1)) || '.' end), ''),
                  'Customer')
  from (
    select coalesce(cp.first_name, s.first_name) as f, coalesce(cp.last_name, s.last_name) as l
    from public.customer_profiles cp
    cross join lateral public._split_full_name(cp.full_name) s
    where cp.firebase_uid = p_uid
  ) x
$$;
revoke all on function public._reviewer_display_name(text) from public, anon, authenticated;

create or replace function public.get_product_reviews(p_product_id uuid, p_limit int default 20, p_offset int default 0)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc, t.id), '[]'::jsonb)
  from (
    select r.id, r.product_id, r.rating, r.comment, r.created_at, r.updated_at,
           coalesce(public._reviewer_display_name(r.customer_id), 'Customer') as reviewer_name,
           (r.customer_id = public.current_firebase_uid()) as is_mine
    from public.product_reviews r
    where r.product_id = p_product_id and not r.is_hidden
    order by r.created_at desc, r.id
    limit least(greatest(coalesce(p_limit, 20), 1), 50)
    offset greatest(coalesce(p_offset, 0), 0)
  ) t
$$;
revoke all on function public.get_product_reviews(uuid, int, int) from public;
grant execute on function public.get_product_reviews(uuid, int, int) to anon, authenticated;

-- What the review form needs: may this customer review, with which order, and their own review.
create or replace function public.my_product_review_status(p_product_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v_review public.product_reviews;
  v_order text;
begin
  if v_uid is null then
    return jsonb_build_object('signed_in', false, 'can_review', false, 'order_id', null, 'review', null);
  end if;
  select * into v_review from public.product_reviews where product_id = p_product_id and customer_id = v_uid;
  v_order := public._reviewable_order(v_uid, p_product_id);
  return jsonb_build_object(
    'signed_in', true,
    'can_review', v_order is not null,
    'order_id', v_order,
    'review', case when v_review.id is null then null else jsonb_build_object(
      'id', v_review.id, 'product_id', v_review.product_id, 'rating', v_review.rating,
      'comment', v_review.comment, 'is_hidden', v_review.is_hidden,
      'created_at', v_review.created_at, 'updated_at', v_review.updated_at,
      'reviewer_name', public._reviewer_display_name(v_uid), 'is_mine', true) end);
end;
$$;
revoke all on function public.my_product_review_status(uuid) from public, anon;
grant execute on function public.my_product_review_status(uuid) to authenticated;

-- 7. Staff / owner moderation (the app's staff side) -----------------------------------------
create or replace function public.staff_list_product_reviews(
  p_product_id uuid default null,
  p_include_hidden boolean default true,
  p_limit int default 50,
  p_offset int default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_active_staff() then
    raise exception 'Only active staff can moderate reviews.' using errcode = '42501';
  end if;
  return (
    select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc, t.id), '[]'::jsonb)
    from (
      select r.id, r.product_id, p.name as product_name, r.order_id, r.rating, r.comment,
             r.is_hidden, r.hidden_at, r.created_at, r.updated_at,
             public._reviewer_display_name(r.customer_id) as reviewer_name
      from public.product_reviews r
      join public.products p on p.id = r.product_id
      where (p_product_id is null or r.product_id = p_product_id)
        and (coalesce(p_include_hidden, true) or not r.is_hidden)
      order by r.created_at desc, r.id
      limit least(greatest(coalesce(p_limit, 50), 1), 100)
      offset greatest(coalesce(p_offset, 0), 0)
    ) t);
end;
$$;
revoke all on function public.staff_list_product_reviews(uuid, boolean, int, int) from public, anon;
grant execute on function public.staff_list_product_reviews(uuid, boolean, int, int) to authenticated;

create or replace function public.staff_moderate_product_review(p_review_id uuid, p_action text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v_review public.product_reviews;
  v_action text := lower(btrim(coalesce(p_action, '')));
begin
  if not public.is_active_staff() then
    raise exception 'Only active staff can moderate reviews.' using errcode = '42501';
  end if;
  if v_action not in ('hide', 'show', 'delete') then
    raise exception 'Choose hide, show or delete.';
  end if;
  select * into v_review from public.product_reviews where id = p_review_id for update;
  if not found then raise exception 'This review no longer exists.'; end if;

  if v_action = 'delete' then
    delete from public.product_reviews where id = p_review_id;
  else
    update public.product_reviews
       set is_hidden = (v_action = 'hide'),
           hidden_at = case when v_action = 'hide' then now() end,
           hidden_by = case when v_action = 'hide' then v_uid end
     where id = p_review_id;
  end if;

  insert into public.staff_audit_logs (staff_firebase_uid, action, entity_type, entity_id, metadata)
  values (v_uid, 'review.' || v_action, 'product_review', p_review_id::text,
          jsonb_build_object('product_id', v_review.product_id, 'rating', v_review.rating,
                             'comment', left(v_review.comment, 200)));

  return jsonb_build_object('id', p_review_id, 'action', v_action,
                            'is_hidden', case v_action when 'hide' then true when 'show' then false end);
end;
$$;
revoke all on function public.staff_moderate_product_review(uuid, text) from public, anon;
grant execute on function public.staff_moderate_product_review(uuid, text) to authenticated;

commit;
