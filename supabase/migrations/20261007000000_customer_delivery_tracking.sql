-- Customer-side delivery tracking: let the customer call their rider.
--
-- `orders.rider_name` and `orders.eta_label` already exist and are shown on the
-- customer's tracking screen. This adds the rider's phone so the "call rider"
-- button on that screen can actually work. It is set by whoever assigns/claims
-- the order (rider or staff); customers can already read their own order rows,
-- so no policy change is needed.

alter table public.orders add column if not exists rider_phone text;
