-- =============================================================================
-- Melai Nuts — Migration 20261119030000: no offensive words in reviews and special instructions
-- =============================================================================
-- Run after 20261119020000_product_reviews.sql. Idempotent, one transaction.
--
-- Customers must not post offensive or cursed words (English and Filipino / Tagalog) in
--   * product_reviews.comment      (the "Leave a review" comment), and
--   * orders.customer_notes        (the "Special instructions" at checkout).
-- The app and the website check while the customer types; THIS is the check that cannot be
-- skipped: a BEFORE trigger refuses the write, whichever client or API call sends it.
--
--   moderation_blocked_terms        the list (kind word | root | phrase | allow). Its master copy
--                                   is moderation/blocked_words.json; after editing the JSON run
--                                   scripts/sync_blocked_words.py and then
--                                   supabase/repair/sync_blocked_words.sql in the SQL editor.
--   moderation_settings             the message: "Please keep your message respectful."
--   contains_blocked_words(text)    true when the text holds a blocked word. Same algorithm as
--                                   admin/app/Support/BlockedWords.php, admin/resources/js/
--                                   blocked-words.js and lib/core/moderation/blocked_words.dart:
--                                   any case, repeated letters, letters split by spaces or
--                                   symbols, leetspeak (@4=a 1!|=i 0=o 3=e $5=s 7=t), accents.
--                                   Words match whole words only (no "class" / "assess" false
--                                   alarms); only "roots" also match inside longer words.
--
-- Only NEW or CHANGED text is checked: old reviews and orders stay as they are, and editing just
-- the rating, or a staff status change on an order, never trips the check.
-- =============================================================================
begin;

-- 1. The list and the message ----------------------------------------------------------------
create table if not exists public.moderation_blocked_terms (
  kind text not null check (kind in ('word', 'root', 'phrase', 'allow')),
  term text not null check (term ~ '^[a-z]+( [a-z]+)*$'),
  -- Repeated letters squeezed out (fuuuck -> fuck), for the comparisons below.
  collapsed text generated always as (regexp_replace(term, '(.)\1+', '\1', 'g')) stored,
  primary key (kind, term)
);
comment on table public.moderation_blocked_terms is
  'Blocked words for reviews and special instructions. Master copy: moderation/blocked_words.json (scripts/sync_blocked_words.py).';

create table if not exists public.moderation_settings (
  id text primary key default 'default' check (id = 'default'),
  message text not null default 'Please keep your message respectful.'
);

-- Only the functions below read them (security definer); nobody writes them through the API.
alter table public.moderation_blocked_terms enable row level security;
alter table public.moderation_settings enable row level security;
revoke all on public.moderation_blocked_terms from public, anon, authenticated;
revoke all on public.moderation_settings from public, anon, authenticated;
grant select, insert, update, delete on public.moderation_blocked_terms to service_role;
grant select, insert, update, delete on public.moderation_settings to service_role;

-- The starting list (the same as moderation/blocked_words.json today). Re-running adds missing
-- terms only; it never undoes an edit made with sync_blocked_words.sql.
insert into public.moderation_blocked_terms (kind, term) values
  ('word', 'arse'),
  ('word', 'arsehole'),
  ('word', 'ass'),
  ('word', 'asshole'),
  ('word', 'asswipe'),
  ('word', 'bastard'),
  ('word', 'bayag'),
  ('word', 'biatch'),
  ('word', 'bilat'),
  ('word', 'bobo'),
  ('word', 'bollocks'),
  ('word', 'boobs'),
  ('word', 'btch'),
  ('word', 'bullshit'),
  ('word', 'burat'),
  ('word', 'chink'),
  ('word', 'cock'),
  ('word', 'cocksucker'),
  ('word', 'cunt'),
  ('word', 'dammit'),
  ('word', 'dick'),
  ('word', 'dickhead'),
  ('word', 'dildo'),
  ('word', 'douche'),
  ('word', 'douchebag'),
  ('word', 'dumbass'),
  ('word', 'etits'),
  ('word', 'fag'),
  ('word', 'faggot'),
  ('word', 'fck'),
  ('word', 'fcking'),
  ('word', 'fking'),
  ('word', 'fuk'),
  ('word', 'fuq'),
  ('word', 'gaga'),
  ('word', 'gago'),
  ('word', 'gagu'),
  ('word', 'goddammit'),
  ('word', 'goddamn'),
  ('word', 'gtfo'),
  ('word', 'hinayupak'),
  ('word', 'hindot'),
  ('word', 'horseshit'),
  ('word', 'inamo'),
  ('word', 'inutil'),
  ('word', 'iyot'),
  ('word', 'jackass'),
  ('word', 'jakol'),
  ('word', 'jerkoff'),
  ('word', 'kantot'),
  ('word', 'kantutan'),
  ('word', 'kupal'),
  ('word', 'lintik'),
  ('word', 'nigga'),
  ('word', 'ogag'),
  ('word', 'olol'),
  ('word', 'pakshet'),
  ('word', 'pakshit'),
  ('word', 'pakyu'),
  ('word', 'pekpek'),
  ('word', 'phuck'),
  ('word', 'phuk'),
  ('word', 'piss'),
  ('word', 'pissed'),
  ('word', 'pokpok'),
  ('word', 'prick'),
  ('word', 'puke'),
  ('word', 'puneta'),
  ('word', 'punyemas'),
  ('word', 'punyeta'),
  ('word', 'pussy'),
  ('word', 'puta'),
  ('word', 'putang'),
  ('word', 'putragis'),
  ('word', 'retard'),
  ('word', 'retarded'),
  ('word', 'salsal'),
  ('word', 'shit'),
  ('word', 'shite'),
  ('word', 'shithead'),
  ('word', 'shithole'),
  ('word', 'shits'),
  ('word', 'shitty'),
  ('word', 'sht'),
  ('word', 'skank'),
  ('word', 'slut'),
  ('word', 'smartass'),
  ('word', 'spic'),
  ('word', 'stfu'),
  ('word', 'tamod'),
  ('word', 'tanga'),
  ('word', 'tangek'),
  ('word', 'tarantada'),
  ('word', 'tarantado'),
  ('word', 'titi'),
  ('word', 'tits'),
  ('word', 'twat'),
  ('word', 'ulol'),
  ('word', 'ulul'),
  ('word', 'wanker'),
  ('word', 'whore'),
  ('word', 'wtf'),
  ('root', 'bitch'),
  ('root', 'bwakanangina'),
  ('root', 'fuck'),
  ('root', 'fvck'),
  ('root', 'kinangina'),
  ('root', 'kingina'),
  ('root', 'motherfuck'),
  ('root', 'nigger'),
  ('root', 'pakingshet'),
  ('root', 'putangina'),
  ('root', 'tangina'),
  ('phrase', 'anak ng puta'),
  ('phrase', 'bobo ka'),
  ('phrase', 'gago ka'),
  ('phrase', 'go to hell'),
  ('phrase', 'king ina'),
  ('phrase', 'pak yu'),
  ('phrase', 'puta ng ina'),
  ('phrase', 'putang ina'),
  ('phrase', 'son of a bitch'),
  ('phrase', 'suck my'),
  ('phrase', 'tang ina'),
  ('phrase', 'tanga ka'),
  ('phrase', 'ulol ka'),
  ('allow', 'assess'),
  ('allow', 'assessment'),
  ('allow', 'bass'),
  ('allow', 'batangas'),
  ('allow', 'brass'),
  ('allow', 'class'),
  ('allow', 'classic'),
  ('allow', 'cockatoo'),
  ('allow', 'cocktail'),
  ('allow', 'computation'),
  ('allow', 'dickens'),
  ('allow', 'glass'),
  ('allow', 'grass'),
  ('allow', 'inamoy'),
  ('allow', 'mass'),
  ('allow', 'massage'),
  ('allow', 'pass'),
  ('allow', 'passion'),
  ('allow', 'peacock'),
  ('allow', 'pistachio'),
  ('allow', 'reputation'),
  ('allow', 'scunthorpe'),
  ('allow', 'shiitake'),
  ('allow', 'tangan')
on conflict (kind, term) do nothing;
insert into public.moderation_settings (id, message) values ('default', 'Please keep your message respectful.')
  on conflict (id) do nothing;

-- 2. The check --------------------------------------------------------------------------------
create or replace function public._bw_collapse(p text)
returns text
language sql
immutable
set search_path = public
as $$
  select regexp_replace(coalesce(p, ''), '(.)\1+', '\1', 'g')
$$;
revoke all on function public._bw_collapse(text) from public, anon, authenticated;

-- One word: whole-word match (also with a plural -s / -es, and with repeated letters squeezed,
-- as long as the typed word is not shorter than the listed one), or a root anywhere inside it.
create or replace function public._bw_is_word(p_w text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_forms text[] := array[p_w];
  v_f text;
begin
  if p_w is null or p_w = '' then
    return false;
  end if;
  if exists (select 1 from public.moderation_blocked_terms where kind = 'allow' and term = p_w) then
    return false;
  end if;
  if length(p_w) >= 4 and right(p_w, 1) = 's' then
    v_forms := v_forms || left(p_w, -1);
  end if;
  if length(p_w) >= 5 and right(p_w, 2) = 'es' then
    v_forms := v_forms || left(p_w, -2);
  end if;
  foreach v_f in array v_forms loop
    if exists (select 1 from public.moderation_blocked_terms t
               where t.kind = 'word' and t.collapsed = public._bw_collapse(v_f) and length(v_f) >= length(t.term)) then
      return true;
    end if;
  end loop;
  return exists (select 1 from public.moderation_blocked_terms t
                 where t.kind = 'root' and strpos(public._bw_collapse(p_w), t.collapsed) > 0);
end;
$$;
revoke all on function public._bw_is_word(text) from public, anon, authenticated;

create or replace function public.contains_blocked_words(p_text text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_t text;
  v_chunk text;
  v_variants text[];
  v_v text;
  v_parts text[];
  v_plain text[] := '{}';
  v_leet text[] := '{}';
  v_squeezed text[] := '{}';
  v_seq text[];
  v_run text[];
  v_w text;
  v_joined text;
  v_line text;
  i int;
  s int;
begin
  if p_text is null or btrim(p_text) = '' then
    return false;
  end if;
  -- Lower case (accented capitals first, whatever the database locale), accents off.
  v_t := lower(translate(p_text, 'ÁÀÂÄÃÉÈÊËÍÌÎÏÓÒÔÖÕÚÙÛÜÑ', 'AAAAAEEEEIIIIOOOOOUUUUN'));
  v_t := translate(v_t, 'áàâäãéèêëíìîïóòôöõúùûüñ', 'aaaaaeeeeiiiiooooouuuun');

  -- Each space-separated chunk as typed, and (when it has letters or @ $ ! |) with leetspeak read
  -- as letters. Words = the letter groups; "squeezed" = the chunk with every non-letter removed.
  foreach v_chunk in array regexp_split_to_array(btrim(v_t), '\s+') loop
    continue when v_chunk = '';
    v_variants := array[v_chunk];
    if v_chunk ~ '[a-z@$!|]' then
      v_variants := v_variants || translate(v_chunk, '@41!|03$57', 'aaiiioesst');
    end if;
    for i in 1 .. array_length(v_variants, 1) loop
      v_v := v_variants[i];
      v_parts := array(select x from unnest(regexp_split_to_array(v_v, '[^a-z]+')) with ordinality u(x, n)
                       where x <> '' order by n);
      if i = 1 then
        v_plain := v_plain || v_parts;
        if array_length(v_variants, 1) = 1 then
          v_leet := v_leet || v_parts;
        end if;
      else
        v_leet := v_leet || v_parts;
      end if;
      v_squeezed := v_squeezed || regexp_replace(v_v, '[^a-z]+', '', 'g');
    end loop;
  end loop;

  foreach v_w in array v_plain || v_leet || v_squeezed loop
    if public._bw_is_word(v_w) then
      return true;
    end if;
  end loop;

  for s in 1 .. 2 loop
    v_seq := case when s = 1 then v_plain else v_leet end;
    -- Three or more single letters in a row (f u c k) read as one word.
    v_run := '{}';
    foreach v_w in array v_seq || array['']::text[] loop
      if length(v_w) = 1 then
        v_run := v_run || v_w;
        continue;
      end if;
      if coalesce(array_length(v_run, 1), 0) >= 3 then
        v_joined := array_to_string(v_run, '');
        if not exists (select 1 from public.moderation_blocked_terms where kind = 'allow' and term = v_joined) then
          if public._bw_is_word(v_joined)
             or exists (select 1 from public.moderation_blocked_terms t
                        where t.kind = 'word' and length(t.term) >= 4 and strpos(public._bw_collapse(v_joined), t.collapsed) > 0) then
            return true;
          end if;
        end if;
      end if;
      v_run := '{}';
    end loop;
    -- Phrases: several words in a row.
    v_line := ' ' || array_to_string(array(select public._bw_collapse(x) from unnest(v_seq) with ordinality u(x, n) order by n), ' ') || ' ';
    if exists (select 1 from public.moderation_blocked_terms t
               where t.kind = 'phrase' and strpos(v_line, ' ' || t.collapsed || ' ') > 0) then
      return true;
    end if;
  end loop;
  return false;
end;
$$;
revoke all on function public.contains_blocked_words(text) from public;
-- Callable by the app and the website too (e.g. a pre-check), it only answers true / false.
grant execute on function public.contains_blocked_words(text) to anon, authenticated, service_role;

create or replace function public.blocked_words_message()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select message from public.moderation_settings where id = 'default'),
                  'Please keep your message respectful.')
$$;
revoke all on function public.blocked_words_message() from public;
grant execute on function public.blocked_words_message() to anon, authenticated, service_role;

-- 3. The triggers: new or changed text only ---------------------------------------------------
create or replace function public._trg_review_comment_respectful()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (tg_op = 'INSERT' or new.comment is distinct from old.comment)
     and public.contains_blocked_words(new.comment) then
    raise exception '%', public.blocked_words_message()
      using hint = 'blocked_words', detail = 'product_reviews.comment';
  end if;
  return new;
end;
$$;
revoke all on function public._trg_review_comment_respectful() from public, anon, authenticated;
drop trigger if exists product_reviews_respectful on public.product_reviews;
create trigger product_reviews_respectful
  before insert or update of comment on public.product_reviews
  for each row execute function public._trg_review_comment_respectful();

create or replace function public._trg_order_notes_respectful()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (tg_op = 'INSERT' or new.customer_notes is distinct from old.customer_notes)
     and public.contains_blocked_words(new.customer_notes) then
    raise exception '%', public.blocked_words_message()
      using hint = 'blocked_words', detail = 'orders.customer_notes';
  end if;
  return new;
end;
$$;
revoke all on function public._trg_order_notes_respectful() from public, anon, authenticated;
drop trigger if exists orders_notes_respectful on public.orders;
create trigger orders_notes_respectful
  before insert or update of customer_notes on public.orders
  for each row execute function public._trg_order_notes_respectful();

commit;
