# 2. Transformation Pipeline & Data Model

## Why table functions, not plain views or ad-hoc queries

`SQL/01_table_functions.sql` defines four **BigQuery Table Functions** — parameterized views holding all transformation logic. This is the one place the flattening/keying logic lives; every fact and dimension table is built by calling these functions, never by duplicating logic.

**Why this matters for reuse:** adapting this whole pipeline to a different GA4 property means editing exactly one line — the `FROM` clause — inside these four functions. Nothing else in the repo needs to change.

**Why not plain views for the fact tables:** a view re-runs its query from scratch on every read. As a real client's history grows to months or years, a view-based `fact_events` would mean every Power BI refresh reprocesses *all* history, not just new data. Table functions solve this differently: they're called once during a backfill (writing a physical table) and once daily thereafter (appending only the new day) — see `SQL/04_daily_incremental_load.sql`.

## Grain: why events, items, and params are three separate tables, not one

GA4's raw export nests two repeated structures inside every event row: `event_params` (key/value pairs) and `items` (ecommerce line items). Flattening everything into a single wide table was considered and rejected, for two reasons:

1. **Sparsity.** The large majority of events (`page_view`, `session_start`, `user_engagement`, etc.) have zero items — only ecommerce events (`view_item`, `add_to_cart`, `purchase`) populate `items`. A merged table would be mostly-null for `item_*` columns on most rows.
2. **Double-counting risk.** A `purchase` event with 3 items would appear as 3 rows if merged with item detail. Any naive `SUM`/`COUNT` on event-level measures (`engagement_time_msec`, session counts) would triple-count that event unless every measure were rewritten as DISTINCT-based.

**Resulting design — three tables, three grains:**
- `fact_events` — one row per event (the atomic grain of the whole export)
- `fact_event_items` — one row per item per event (only rows with items)
- `bridge_event_params` — one row per parameter per event (captures every param, including custom, client-specific ones GA4 allows up to 25 of per event — this is genuinely open-ended, so it's the one part of the model that can't be a fixed column list)

In Power BI: **no direct relationship between `fact_events` and `fact_event_items`.** Fact-to-fact relationships create ambiguous filter propagation. Both connect independently to the same shared dimensions instead — see `Docs/03_connect_powerbi.md`.

## Dimension keys: one formula, computed once

`device_key`, `geo_key`, `traffic_source_key`, and `app_info_key` are `MD5` hashes of each dimension's natural attributes, computed inside `flatten_events` and reused identically when building `dim_device`, `dim_geo`, etc. Using a hash (not `ROW_NUMBER()`) means re-running a dimension build never creates duplicate or shifted keys — the same input always produces the same key, which is essential once daily `MERGE` upserts are involved.

## `dim_user`: a Slowly Changing Dimension, not a static one

Unlike device/geo/traffic-source (which are genuinely static — a "mobile / Samsung / Android" combination never changes once seen), a user's lifetime value (`user_ltv`) **grows** with each new event. The daily load for `dim_user` therefore uses `MERGE ... WHEN MATCHED THEN UPDATE`, not an insert-only pattern — an insert-only `MERGE` would silently freeze a returning user's LTV at whatever it was the first day they were ever seen. See `SQL/04_daily_incremental_load.sql`.

## `fact_sessions`: derived, not native to the export

GA4's export has no native "session" table — sessions are reconstructed by grouping `fact_events` on `(user_key, session_id)`. This is built as its own table (a `VIEW`, per the Sandbox note below) because it's the grain most marketing reporting actually needs (bounce rate, session count, entrance pages), and recalculating it inside every DAX measure would be slower and more error-prone than querying a pre-aggregated table.

## A note on BigQuery Sandbox behavior encountered during this build

Several tables (`fact_event_items`, `bridge_event_params`, `bridge_user_properties`, `fact_sessions`) are `VIEW`s rather than physical tables. In Sandbox mode (no billing account), `CREATE TABLE` against these specific multi-source queries intermittently failed with a `billing not enabled / table expiration must be < 60 days` error — even with an explicit `OPTIONS(expiration_timestamp = ...)` set. Converting to views sidesteps the restriction entirely, at the cost of being recomputed on each query rather than stored. If you have a billing account attached, this restriction doesn't apply, and converting these to physical tables (for better performance) is a straightforward change — see the inline notes in `SQL/02_backfill_base_tables.sql`.
