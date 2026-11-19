-- =============================================================================
-- Melai Nuts — Migration 20261119040000: product reviews on the admin website
-- =============================================================================
-- Run after 20261119030000_blocked_words.sql. Idempotent, one transaction.
--
-- The admin website's "Product reviews" page (owner) lists EVERY review, hidden ones included,
-- with the product, the customer's name, rating, comment and date; it filters by product,
-- searches and sorts, and hides / shows / deletes a review with the existing
-- staff_moderate_product_review() (20261119020000, written to staff_audit_logs).
--
-- Why a function: product_reviews RLS lets a signed-in user read only visible rows and their
-- own, and never customer_id. This SECURITY DEFINER function is the one way to read them all, and
-- only for an active staff member / owner (is_active_staff(), the same check as the moderation
-- function). Customers and guests get an error, never rows.
--
--   admin_list_product_reviews(query, product, status, sort, limit, offset)
--     status: all | visible | hidden          sort: newest | oldest | rating_high | rating_low
--     -> { total, rows: [...], products: [{id, name, review_count}], summary: {...} }
-- =============================================================================
begin;

create or replace function public.admin_list_product_reviews(
  p_query text default null,
  p_product_id uuid default null,
  p_status text default 'all',
  p_sort text default 'newest',
  p_limit int default 50,
  p_offset int default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_q text := nullif(lower(btrim(coalesce(p_query, ''))), '');
  v_status text := lower(coalesce(nullif(btrim(p_status), ''), 'all'));
  v_sort text := lower(coalesce(nullif(btrim(p_sort), ''), 'newest'));
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_result jsonb;
begin
  if not public.is_active_staff() then
    raise exception 'Only active staff can moderate reviews.' using errcode = '42501';
  end if;
  if v_status not in ('all', 'visible', 'hidden') then v_status := 'all'; end if;
  if v_sort not in ('newest', 'oldest', 'rating_high', 'rating_low') then v_sort := 'newest'; end if;

  with base as (
    select r.id, r.product_id, p.name as product_name, r.order_id, r.rating, r.comment,
           r.is_hidden, r.hidden_at, r.created_at, r.updated_at, r.customer_id,
           coalesce(nullif(btrim(concat_ws(' ', nullif(btrim(cp.first_name), ''), nullif(btrim(cp.last_name), ''))), ''),
                    nullif(btrim(cp.full_name), ''), 'Customer') as customer_name,
           cp.email as customer_email
    from public.product_reviews r
    join public.products p on p.id = r.product_id
    left join public.customer_profiles cp on cp.firebase_uid = r.customer_id
  ),
  filtered as (
    select * from base b
    where (p_product_id is null or b.product_id = p_product_id)
      and (v_status = 'all' or (v_status = 'hidden') = b.is_hidden)
      -- Plain text search (no LIKE wildcards from the search box): product, customer, comment.
      and (v_q is null
           or strpos(lower(b.product_name), v_q) > 0
           or strpos(lower(b.customer_name), v_q) > 0
           or strpos(lower(coalesce(b.customer_email, '')), v_q) > 0
           or strpos(lower(b.comment), v_q) > 0)
  ),
  page as (
    select * from filtered
    order by
      case when v_sort = 'rating_high' then rating end desc nulls last,
      case when v_sort = 'rating_low' then rating end asc nulls last,
      case when v_sort = 'oldest' then created_at end asc,
      created_at desc, id
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total', (select count(*) from filtered),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'id', pg.id, 'product_id', pg.product_id, 'product_name', pg.product_name, 'order_id', pg.order_id,
        'customer_name', pg.customer_name, 'customer_email', pg.customer_email,
        'rating', pg.rating, 'comment', pg.comment, 'is_hidden', pg.is_hidden, 'hidden_at', pg.hidden_at,
        'created_at', pg.created_at, 'updated_at', pg.updated_at)
      order by
        case when v_sort = 'rating_high' then pg.rating end desc nulls last,
        case when v_sort = 'rating_low' then pg.rating end asc nulls last,
        case when v_sort = 'oldest' then pg.created_at end asc,
        pg.created_at desc, pg.id) from page pg), '[]'::jsonb),
    -- For the product filter: every product with at least one review.
    'products', coalesce((select jsonb_agg(jsonb_build_object('id', x.product_id, 'name', x.product_name, 'review_count', x.n) order by lower(x.product_name))
                          from (select product_id, product_name, count(*) as n from base group by product_id, product_name) x), '[]'::jsonb),
    'summary', (select jsonb_build_object(
        'total', count(*),
        'hidden', count(*) filter (where is_hidden),
        'average_rating', round(avg(rating) filter (where not is_hidden)::numeric, 1),
        'last_30_days', count(*) filter (where created_at > now() - interval '30 days')) from base)
  ) into v_result;
  return v_result;
end;
$$;
revoke all on function public.admin_list_product_reviews(text, uuid, text, text, int, int) from public, anon;
grant execute on function public.admin_list_product_reviews(text, uuid, text, text, int, int) to authenticated;

commit;
