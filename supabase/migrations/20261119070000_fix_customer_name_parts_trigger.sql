-- =============================================================================
-- Fix: new customers could not create their profile
-- =============================================================================
-- 20261119010000_customer_name_parts.sql revoked EXECUTE on
-- public._split_full_name from authenticated, but the customer_profiles trigger
-- function public._customer_profiles_name_parts() ran as the caller (not
-- SECURITY DEFINER) and calls it. Every customer insert into customer_profiles
-- therefore failed with "permission denied for function _split_full_name"
-- (403 on POST /rest/v1/customer_profiles). With no profile row,
-- sync_customer_cart then failed on carts_firebase_uid_fkey (409), so cart,
-- orders and notifications broke for new customers.
--
-- The trigger function now runs as its owner, with a fixed search_path.
-- _split_full_name stays closed to anon/authenticated.
-- =============================================================================
begin;

alter function public._customer_profiles_name_parts() security definer;
alter function public._customer_profiles_name_parts() set search_path = public;

commit;
