-- =====================================================================
-- Sarelly inventory agent — PO views (002)
-- Requires public.po_lines_raw (created by schema.sql in inventory-snapshot,
-- filled daily by sync_pos.py). Run once in the Supabase SQL editor.
-- Safe to re-run. Reads only; changes no data.
--
-- The sheet is typed by people, so parsing is defensive: anything that
-- can't be read with confidence becomes NULL plus a flag in data_issues,
-- never a guess presented as fact.
-- =====================================================================

create schema if not exists agent;


-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

-- 'ene', 'Enero', 'jan', 'Dic', 'DICIEMBRE' -> 1..12 (English or Spanish)
create or replace function agent.month_number(word text)
returns int language sql immutable as $$
  select case left(lower(trim(word)), 3)
    when 'jan' then 1  when 'ene' then 1
    when 'feb' then 2
    when 'mar' then 3
    when 'apr' then 4  when 'abr' then 4
    when 'may' then 5
    when 'jun' then 6
    when 'jul' then 7
    when 'aug' then 8  when 'ago' then 8
    when 'sep' then 9  when 'set' then 9
    when 'oct' then 10
    when 'nov' then 11
    when 'dec' then 12 when 'dic' then 12
  end
$$;

-- A cell that is entirely a date, in any format seen in the sheet:
--   2026-11-20 (ISO, optionally with a time), 29-May-2026, 02-ene-2027,
--   24-Dic-2026, 29-05-2026 (numeric dates are read day-first, as typed
--   in Mexico). Impossible dates (31-02-2026) and anything else -> NULL.
create or replace function agent.parse_sheet_date(txt text)
returns date language plpgsql immutable as $$
declare
  t text := lower(trim(txt));
  m text[];
  mon int;
begin
  if t is null or t = '' then return null; end if;

  m := regexp_match(t, '^(\d{4})-(\d{1,2})-(\d{1,2})');
  if m is not null then
    return make_date(m[1]::int, m[2]::int, m[3]::int);
  end if;

  m := regexp_match(t, '^(\d{1,2})[-/ ]([a-z]{3,})\.?[-/ ](\d{4})$');
  if m is not null then
    mon := agent.month_number(m[2]);
    if mon is null then return null; end if;
    return make_date(m[3]::int, mon, m[1]::int);
  end if;

  m := regexp_match(t, '^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})$');
  if m is not null then
    return make_date(m[3]::int, m[2]::int, m[1]::int);
  end if;

  return null;
exception when others then
  return null;
end $$;

-- A full date written inside other text, e.g. 'After inspection on 26-10-2026'.
create or replace function agent.date_in_text(txt text)
returns date language sql immutable as $$
  select agent.parse_sheet_date(
    (regexp_match(lower(txt), '(\d{1,2}[-/.]\d{1,2}[-/.]\d{4}|\d{1,2}-[a-z]{3,}-\d{4})'))[1]
  )
$$;

-- Month-only text such as 'NOVIEMBRE', 'DICIEMBRE/ENERO', '30 OCT/DICIEMBRE':
-- the LAST day of the LAST month named (the conservative reading), in the
-- first year that isn't more than 45 days before the reference date.
create or replace function agent.month_only_eta(txt text, ref date)
returns date language plpgsql immutable as $$
declare
  words text[];
  mon int;
  y int := extract(year from ref)::int;
  d date;
begin
  select array_agg(w[1]) into words
  from regexp_matches(lower(coalesce(txt, '')),
    '\y(enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre|january|february|march|april|june|july|august|september|october|november|december|ene|feb|mar|abr|may|jun|jul|ago|sep|sept|oct|nov|dic|jan|apr|aug|dec)\y',
    'g') as w;
  if words is null then return null; end if;
  mon := agent.month_number(words[array_length(words, 1)]);
  if mon is null then return null; end if;
  d := (make_date(y, mon, 1) + interval '1 month' - interval '1 day')::date;
  if d < ref - 45 then
    d := (make_date(y + 1, mon, 1) + interval '1 month' - interval '1 day')::date;
  end if;
  return d;
end $$;

-- '5,000' -> 5000; '' / 'NA' / text -> NULL
create or replace function agent.parse_qty(txt text)
returns numeric language sql immutable as $$
  select case when trim(coalesce(txt, '')) ~ '^[0-9][0-9,]*(\.[0-9]+)?$'
              then replace(trim(txt), ',', '')::numeric end
$$;


-- ---------------------------------------------------------------------
-- 1. agent.po_lines
-- Every line of the latest copy of the PO sheet, cleaned, with a
-- data_issues list explaining anything that couldn't be read cleanly.
-- ---------------------------------------------------------------------
create or replace view agent.po_lines with (security_invoker = true) as
with latest as (
  select max(snapshot_date) as d from public.po_lines_raw
),
r as (
  select p.*
  from public.po_lines_raw p
  join latest l on p.snapshot_date = l.d
),
parsed as (
  select
    r.*,
    nullif(upper(trim(r.po_number)), '')                         as po_clean,
    case when upper(trim(coalesce(r.sku, ''))) in ('', 'NA', 'N/A', '-')
         then null else upper(trim(r.sku)) end                   as sku_clean,
    agent.parse_qty(r.po_qty)                                    as qty_ordered,
    agent.parse_qty(r.qty_confirmed)                             as qty_confirmed_n,
    agent.parse_sheet_date(r.po_date)                            as po_date_d,
    agent.parse_sheet_date(r.prepayment_date)                    as prepayment_d,
    coalesce(agent.parse_sheet_date(r.pickup_ready_date),
             agent.date_in_text(r.pickup_ready_date))            as pickup_d,
    agent.parse_sheet_date(r.final_payment_date)                 as final_payment_d,
    agent.parse_sheet_date(r.eta)                                as eta_exact,
    agent.date_in_text(r.eta)                                    as eta_in_text,
    agent.month_only_eta(r.eta, r.snapshot_date)                 as eta_month,
    upper(trim(r.status))                                        as status_clean,
    lower(trim(r.comment))                                       as comment_l
  from r
),
enriched as (
  select
    p.*,
    coalesce(p.eta_exact, p.eta_in_text, p.eta_month)            as eta_d,
    case when p.eta_exact   is not null then 'exact'
         when p.eta_in_text is not null then 'date_in_text'
         when p.eta_month   is not null then 'month_only'
         when p.eta         is not null then 'unreadable'
         else 'missing' end                                      as eta_quality,
    p.tab = 'TRANSITO' and coalesce(p.status_clean, '') <> 'RECIBIDA' as is_open,
    agent.parse_qty((regexp_match(p.comment_l, '([0-9][0-9,]*)\s*(?:pzs?|piezas|unidades)?\s*para\s*(?:usa|us|eeuu|estados unidos)'))[1])
                                                                 as qty_to_us_from_comment,
    agent.parse_qty((regexp_match(p.comment_l, '([0-9][0-9,]*)\s*(?:pzs?|piezas|unidades)?\s*recibid'))[1])
                                                                 as qty_received_from_comment,
    -- latest PO date among lower-numbered POs, to spot dates out of sequence
    max(p.po_date_d) over (
      order by nullif(regexp_replace(coalesce(p.po_clean, ''), '[^0-9]', '', 'g'), '')::int nulls last
      rows between unbounded preceding and 1 preceding
    )                                                            as prev_po_max_date
  from parsed p
)
select
  e.snapshot_date,
  e.tab,
  e.row_number,
  e.po_clean                                    as po_number,
  e.po_date_d                                   as po_date,
  e.sku_clean                                   as internal_sku,
  e.sku                                         as sku_as_typed,
  e.description,
  trim(e.supplier)                              as supplier,
  e.qty_ordered,
  e.qty_confirmed_n                             as qty_confirmed,
  coalesce(e.qty_confirmed_n, e.qty_ordered)    as qty_expected,
  e.status_clean                                as status,
  e.is_open,
  case
    when lower(e.payment_status) like 'anticipo pag%'  then 'prepayment paid'
    when lower(e.payment_status) like 'anticipo sol%'  then 'prepayment requested'
    when lower(e.payment_status) like 'finiquito pag%' then 'final payment paid'
    when lower(e.payment_status) like 'finiquito sol%' then 'final payment requested'
    else lower(trim(e.payment_status))
  end                                           as payment_status,
  e.prepayment_d                                as prepayment_date,
  e.pickup_d                                    as pickup_ready_date,
  e.eta_d                                       as eta,
  e.eta_quality,
  e.eta                                         as eta_as_typed,
  e.final_payment_d                             as final_payment_date,
  e.final_wh,
  e.qty_to_us_from_comment,
  e.qty_received_from_comment,
  e.comment,
  array_remove(array[
    case when e.po_clean is null then 'missing_po_number' end,
    case when e.po_clean is not null and e.po_clean !~ '^PO[0-9]{4}$' then 'po_number_format' end,
    case when e.sku_clean is null then 'missing_sku' end,
    case when e.sku_clean is not null
          and not exists (select 1 from public.sku_master sm where sm.internal_sku = e.sku_clean)
         then 'sku_not_in_sku_master' end,
    case when e.qty_ordered is null then 'missing_qty' end,
    case when e.po_date is null and e.po_clean is not null then 'missing_po_date' end,
    case when e.po_date is not null and e.po_date_d is null then 'po_date_unreadable' end,
    case when e.po_date_d > e.snapshot_date then 'po_date_in_future' end,
    case when e.po_date_d < e.prev_po_max_date - 21 then 'po_date_out_of_sequence' end,
    case when e.eta_quality = 'unreadable' then 'eta_unreadable' end,
    case when e.eta_quality = 'month_only' then 'eta_month_only' end,
    case when e.eta_quality = 'missing' and e.is_open and e.status_clean <> 'CREADA' then 'missing_eta' end,
    case when e.eta_d < e.pickup_d then 'eta_before_pickup' end,
    case when e.is_open and e.eta_d < e.snapshot_date then 'eta_passed_not_received' end,
    case when e.qty_to_us_from_comment is not null and e.final_wh is null then 'us_split_only_in_comment' end,
    case when e.qty_received_from_comment is not null then 'partial_receipt_only_in_comment' end
  ], null)                                      as data_issues
from enriched e;


-- ---------------------------------------------------------------------
-- 2. agent.incoming_by_sku
-- Open PO quantities per SKU, bucketed by ETA. Lines without a SKU
-- (packaging typed as NA) are excluded; they appear in data_issues.
-- ---------------------------------------------------------------------
create or replace view agent.incoming_by_sku with (security_invoker = true) as
select
  l.internal_sku,
  sm.display_name,
  count(*)                                                                   as open_lines,
  string_agg(distinct l.po_number, ', ')                                     as po_numbers,
  string_agg(distinct l.supplier, ', ')                                      as suppliers,
  sum(l.qty_expected)                                                        as qty_incoming,
  sum(l.qty_expected) filter (where l.eta <= l.snapshot_date + 30)          as qty_eta_30d,
  sum(l.qty_expected) filter (where l.eta >  l.snapshot_date + 30
                                and l.eta <= l.snapshot_date + 60)          as qty_eta_31_60d,
  sum(l.qty_expected) filter (where l.eta >  l.snapshot_date + 60)          as qty_eta_later,
  sum(l.qty_expected) filter (where l.eta is null)                          as qty_eta_unknown,
  min(l.eta)                                                                 as next_eta,
  sum(l.qty_to_us_from_comment)                                              as qty_to_us_noted,
  bool_or(l.status = 'EN ADUANA')                                            as any_in_customs,
  count(*) filter (where l.qty_expected is null)                             as lines_missing_qty
from agent.po_lines l
left join public.sku_master sm on sm.internal_sku = l.internal_sku
where l.is_open and l.internal_sku is not null
group by l.internal_sku, sm.display_name;


-- ---------------------------------------------------------------------
-- 3. agent.po_eta_changes
-- For each line in the latest sheet copy: the first ETA ever seen vs. the
-- current one. Fills up as daily history accumulates.
-- ---------------------------------------------------------------------
create or replace view agent.po_eta_changes with (security_invoker = true) as
with h as (
  select
    p.snapshot_date,
    upper(trim(p.po_number))                                  as po_number,
    coalesce(upper(trim(p.sku)), '')                          as sku_key,
    lower(trim(coalesce(p.description, '')))                  as desc_key,
    trim(p.supplier)                                          as supplier,
    p.eta                                                     as eta_as_typed,
    coalesce(agent.parse_sheet_date(p.eta),
             agent.date_in_text(p.eta),
             agent.month_only_eta(p.eta, p.snapshot_date))    as eta
  from public.po_lines_raw p
  where p.po_number is not null
),
agg as (
  select
    po_number, sku_key, desc_key,
    max(supplier)                                                            as supplier,
    min(snapshot_date)                                                       as first_seen,
    max(snapshot_date)                                                       as last_seen,
    (array_agg(eta order by snapshot_date) filter (where eta is not null))[1] as first_eta,
    (array_agg(eta order by snapshot_date desc))[1]                          as current_eta,
    (array_agg(eta_as_typed order by snapshot_date desc))[1]                 as current_eta_as_typed,
    count(distinct eta)                                                      as distinct_etas
  from h
  group by po_number, sku_key, desc_key
)
select
  a.po_number,
  nullif(a.sku_key, '')                         as sku,
  a.desc_key                                    as description,
  a.supplier,
  a.first_seen,
  a.first_eta,
  a.current_eta,
  a.current_eta_as_typed,
  a.current_eta - a.first_eta                   as days_slipped,
  greatest(a.distinct_etas - 1, 0)              as eta_changes
from agg a
where a.last_seen = (select max(snapshot_date) from public.po_lines_raw);
