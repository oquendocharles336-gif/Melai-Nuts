-- =============================================================================
-- Melai Nuts — Migration 20261030111500: branch map coordinates
-- =============================================================================
-- Run after 20261029000000_admin_portal_account_status.sql. Idempotent.
--
-- The app selects the customer's nearest branch from the phone's location, which
-- needs each branch's coordinates; all three were empty. These are the stores'
-- positions as given by the owner. A value already set is never overwritten.
-- =============================================================================
begin;

update public.branches set latitude = 14.214111223297447, longitude = 121.15019546414851
 where name = 'Calamba Branch' and latitude is null and longitude is null;
update public.branches set latitude = 14.176370127061539, longitude = 121.26257325608445
 where name = 'Los Baños Branch' and latitude is null and longitude is null;
update public.branches set latitude = 14.25338982439908, longitude = 121.38991834394692
 where name = 'Santa Cruz Branch' and latitude is null and longitude is null;

commit;
