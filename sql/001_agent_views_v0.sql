-- =====================================================================
-- Sarelly inventory agent — v0 views
-- Run once in the Supabase SQL editor (the Claude connector is read-only).
-- Safe to re-run: every statement uses "create ... if not exists" or
-- "create or replace". Nothing here changes or deletes existing data.
--
-- Why a separate "agent" schema: Supabase only exposes "public" through
-- its API by default, so these views stay internal. Keep it that way
-- (don't add "agent" to Settings > API > Exposed schemas).
-- security_invoker = true makes each view respect the permissions of
-- whoever queries it, instead of the view owner's.
-- =====================================================================

create schema if not exists agent;


-- ---------------------------------------------------------------------
-- 1. agent.inventory_daily
-- Base view: every snapshot row, with the internal SKU resolved through
-- sku_mappings as well. New mappings apply to history immediately,
-- without re-running the pipeline.
-- ---------------------------------------------------------------------
create or replace view agent.inventory_daily with (security_invoker = true) as
with m as (
  select distinct on (source, external_id) source, external_id, internal_sku
  from public.sku_mappings
  where internal_sku is not null
  order by source, external_id, id desc
)
select
  s.snapshot_date,
  s.source,
  s.external_id,
  s.external_sku,
  coalesce(s.internal_sku, m.internal_sku)      as internal_sku,
  coalesce(s.qty_available, s.qty_on_hand, 0)   as qty_available,
  coalesce(s.qty_on_hand, 0)                    as qty_on_hand,
  coalesce(s.qty_inbound, 0)                    as qty_inbound
from public.inventory_snapshots s
left join m on m.source = s.source and m.external_id = s.external_id;


-- ---------------------------------------------------------------------
-- 2. agent.channel_stock
-- Latest stock per internal SKU per source, and whether a channel is at
-- zero while other sources still show stock (rebalancing opportunities).
-- Note: Shopify can mirror 3PL stock, so totals across sources may
-- double count. Use "other_sources_available" as a signal, not a count.
-- ---------------------------------------------------------------------
create or replace view agent.channel_stock with (security_invoker = true) as
with latest as (
  select source, max(snapshot_date) as d
  from public.inventory_snapshots
  group by source
),
cur as (
  select i.internal_sku, i.source,
         sum(i.qty_available) as qty_available,
         sum(i.qty_inbound)   as qty_inbound
  from agent.inventory_daily i
  join latest l on l.source = i.source and l.d = i.snapshot_date
  where i.internal_sku is not null
  group by 1, 2
),
tot as (
  select internal_sku, sum(qty_available) as total_available
  from cur group by 1
)
select
  c.internal_sku,
  sm.display_name,
  sm.category,
  c.source,
  c.qty_available,
  c.qty_inbound,
  t.total_available - c.qty_available                           as other_sources_available,
  (c.qty_available <= 0 and t.total_available - c.qty_available > 0)
                                                                as stockout_with_stock_elsewhere
from cur c
join tot t using (internal_sku)
left join public.sku_master sm using (internal_sku);


-- ---------------------------------------------------------------------
-- 3. agent.stock_changes_7d
-- Latest stock vs. 7 days earlier, per SKU per source.
-- ---------------------------------------------------------------------
create or replace view agent.stock_changes_7d with (security_invoker = true) as
with latest as (
  select source, max(snapshot_date) as d
  from public.inventory_snapshots
  group by source
),
agg as (
  select internal_sku, source, snapshot_date, sum(qty_available) as q
  from agent.inventory_daily
  where internal_sku is not null
    and snapshot_date >= current_date - 30
  group by 1, 2, 3
)
select
  a.internal_sku,
  sm.display_name,
  a.source,
  a.q                         as qty_now,
  p.q                         as qty_7d_ago,
  a.q - coalesce(p.q, 0)      as change_units,
  case when p.q > 0 then round(100.0 * (a.q - p.q) / p.q, 1) end as change_pct
from agg a
join latest l on l.source = a.source and l.d = a.snapshot_date
left join agg p on p.internal_sku = a.internal_sku
               and p.source = a.source
               and p.snapshot_date = l.d - 7
left join public.sku_master sm on sm.internal_sku = a.internal_sku;


-- ---------------------------------------------------------------------
-- 4. agent.source_freshness
-- Is every source still updating, and with a normal number of rows?
-- ---------------------------------------------------------------------
create or replace view agent.source_freshness with (security_invoker = true) as
with d as (
  select source, snapshot_date, count(*) as n
  from public.inventory_snapshots
  where snapshot_date >= current_date - 15
  group by 1, 2
)
select
  source,
  max(snapshot_date)                              as last_snapshot,
  current_date - max(snapshot_date)               as days_since_update,
  (array_agg(n order by snapshot_date desc))[1]   as rows_latest,
  round(avg(n))                                   as avg_rows_15d
from d
group by source;


-- ---------------------------------------------------------------------
-- 5. agent.unmapped_items
-- Items in the latest snapshot with no internal SKU, plus suggestions:
--   suggested_sku_same_code     -> the code already exists in sku_master
--                                  (only the mapping is missing)
--   suggested_sku_other_channel -> the same code is mapped in another
--                                  source (n_candidates > 1 = ambiguous)
-- product_name comes from the source's raw data where available
-- (Amazon, US 3PL, TikTok; the MX 3PL and Shopify don't send names).
-- ---------------------------------------------------------------------
create or replace view agent.unmapped_items with (security_invoker = true) as
with latest as (
  select source, max(snapshot_date) as d
  from public.inventory_snapshots
  group by source
),
m as (
  select distinct on (source, external_id) source, external_id, internal_sku
  from public.sku_mappings
  where internal_sku is not null
  order by source, external_id, id desc
),
fs as (
  select source, external_id, min(snapshot_date) as first_seen
  from public.inventory_snapshots
  group by 1, 2
),
u as (
  select
    s.source, s.external_id, s.external_sku,
    coalesce(s.qty_on_hand, 0) as qty_on_hand,
    case when jsonb_typeof(s.raw_data) = 'string'
              and pg_input_is_valid(s.raw_data #>> '{}', 'jsonb')
         then (s.raw_data #>> '{}')::jsonb
         when jsonb_typeof(s.raw_data) in ('object', 'array')
         then s.raw_data
    end as raw
  from public.inventory_snapshots s
  join latest l on l.source = s.source and l.d = s.snapshot_date
  left join m on m.source = s.source and m.external_id = s.external_id
  where s.internal_sku is null and m.internal_sku is null
)
select
  u.source,
  u.external_id,
  u.external_sku,
  coalesce(u.raw ->> 'product-name',
           u.raw ->> 'ItemDesc1',
           u.raw -> 0 -> 'goods' ->> 'name')                       as product_name,
  u.qty_on_hand,
  upper(substring(coalesce(u.external_sku, u.external_id) from '^([A-Za-z]+)')) as code_prefix,
  fs.first_seen,
  ex.internal_sku                                                  as suggested_sku_same_code,
  oc.internal_sku                                                  as suggested_sku_other_channel,
  oc.n_candidates
from u
join fs on fs.source = u.source and fs.external_id = u.external_id
left join lateral (
  select sm.internal_sku
  from public.sku_master sm
  where upper(sm.internal_sku) in (upper(u.external_sku), upper(u.external_id))
  limit 1
) ex on true
left join lateral (
  select min(mm.internal_sku) as internal_sku,
         count(distinct mm.internal_sku) as n_candidates
  from public.sku_mappings mm
  where mm.source <> u.source
    and mm.internal_sku is not null
    and (upper(mm.external_sku) = upper(u.external_sku)
         or upper(mm.external_id) = upper(u.external_id))
  having count(*) > 0
) oc on true;


-- ---------------------------------------------------------------------
-- 6. agent.sku_master_review
-- Every SKU in sku_master with a lifecycle status, to spot SKUs that may
-- need to be deactivated (is_active = false), never deleted.
-- ---------------------------------------------------------------------
create or replace view agent.sku_master_review with (security_invoker = true) as
with latest as (
  select source, max(snapshot_date) as d
  from public.inventory_snapshots
  group by source
),
hist as (
  select internal_sku,
         min(snapshot_date)                                   as first_seen,
         max(snapshot_date)                                   as last_seen,
         max(snapshot_date) filter (where qty_on_hand > 0)    as last_with_stock
  from agent.inventory_daily
  where internal_sku is not null
  group by 1
),
cur as (
  select i.internal_sku,
         sum(i.qty_on_hand)        as units_now,
         count(distinct i.source)  as sources_listed_now
  from agent.inventory_daily i
  join latest l on l.source = i.source and l.d = i.snapshot_date
  where i.internal_sku is not null
  group by 1
),
maps as (
  select internal_sku, count(*) as n_mappings
  from public.sku_mappings
  group by 1
)
select
  sm.internal_sku,
  sm.display_name,
  sm.category,
  sm.is_bundle,
  sm.is_active,
  coalesce(maps.n_mappings, 0)        as n_mappings,
  coalesce(cur.sources_listed_now, 0) as sources_listed_now,
  coalesce(cur.units_now, 0)          as units_now,
  hist.first_seen,
  hist.last_seen,
  hist.last_with_stock,
  case
    when sm.is_bundle                              then 'bundle (stock not tracked directly)'
    when hist.internal_sku is null                 then 'never seen in any source'
    when hist.last_with_stock is null              then 'seen but never had stock'
    when hist.last_with_stock < current_date - 60  then 'no stock in 60+ days'
    else 'active'
  end as status
from public.sku_master sm
left join hist using (internal_sku)
left join cur  using (internal_sku)
left join maps using (internal_sku);
