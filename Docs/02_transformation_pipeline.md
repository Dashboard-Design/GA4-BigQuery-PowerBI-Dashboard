# 2. Transformation Pipeline & Data Model

## Why table functions, not plain views or ad-hoc queries

`BigQuery/01_table_functions.sql` defines five **BigQuery Table Functions** — parameterized views holding all transformation logic. One of them, `ga4_events_with_id`, is the only function that reads the raw GA4 export; the four `flatten_*` functions read from it. Every fact and dimension table is built by calling these functions, never by duplicating logic.

**Why this matters for reuse:** adapting this whole pipeline to a different GA4 property means editing exactly one line — the `FROM` clause inside `ga4_events_with_id`. Nothing else in the repo needs to change.

**Why not plain views for `fact_events`:** a view re-runs its query from scratch on every read. As a real client's history grows to months or years, a view-based `fact_events` would mean every Power BI refresh reprocesses *all* history, not just new data. Instead, `fact_events` is a physical table: written once during the backfill, then (with billing enabled) only a short recent window is replaced each day. With billing it is date-partitioned; in Sandbox it is created unpartitioned, because Sandbox drops partitions older than 60 days as soon as they are written (see `Docs/01_link_ga4_to_bigquery.md`).

## Event IDs: unique and stable

`event_id` is computed once, inside `ga4_events_with_id`, from `user_pseudo_id`, `event_name`, `event_timestamp`, `event_bundle_sequence_id` and a `ROW_NUMBER()` tiebreaker.

The earlier formula (without `event_name` and the tiebreaker) wasn't guaranteed unique: two events in the same bundle can share a microsecond timestamp. A collision would silently duplicate rows in any join on `event_id` (for example against the params bridge). The tiebreaker is ordered by the event's own params/items, so the same raw event gets the same `event_id` on every re-run — which the idempotent daily load relies on. Because the ID is computed in one function, `flatten_events`, `flatten_event_items` and `flatten_event_params` can never disagree.

## Grain: why events, items, and params are three separate tables, not one

GA4's raw export nests two repeated structures inside every event row: `event_params` (key/value pairs) and `items` (ecommerce line items). Flattening everything into a single wide table was considered and rejected, for two reasons:

1. **Sparsity.** The large majority of events (`page_view`, `session_start`, `user_engagement`, etc.) have zero items — only ecommerce events (`view_item`, `add_to_cart`, `purchase`) populate `items`. A merged table would be mostly-null for `item_*` columns on most rows.
2. **Double-counting risk.** A `purchase` event with 3 items would appear as 3 rows if merged with item detail. Any naive `SUM`/`COUNT` on event-level measures (`engagement_time_msec`, session counts) would triple-count that event unless every measure were rewritten as DISTINCT-based.

**Resulting design — three tables, three grains:**
- `fact_events` — one row per event (the atomic grain of the whole export)
- `fact_event_items` — one row per item per event (only rows with items)
- `bridge_event_params` — one row per parameter per event (captures every param, including custom, client-specific ones GA4 allows up to 25 of per event — this is genuinely open-ended, so it's the one part of the model that can't be a fixed column list)

In Power BI: **no direct relationship between `fact_events` and `fact_event_items`.** Fact-to-fact relationships create ambiguous filter propagation. Both connect independently to the same shared dimensions instead — see `Docs/03_connect_powerbi.md`.

## Orchestration: stored procedures

The tables depend on each other (dimensions are built from `fact_events`; `dim_item` from `fact_event_items`; `fact_sessions` from `fact_events`), so the build order matters. Rather than running separate scripts by hand in the right sequence, `BigQuery/02_pipeline_procedures.sql` defines two procedures:

- `refresh_pipeline(start_date, end_date)` — runs the whole build in dependency order for a date window: `fact_events` → views → dimensions → `fact_sessions` → `dim_date`.
- `run_daily_refresh(property_timezone, lookback_days)` — what the scheduled query calls. It works out the window in the GA4 property's timezone and calls `refresh_pipeline`.

The first backfill and every daily run use the same procedure — only the date window differs.

`refresh_pipeline` is itself two procedures called in order: `load_fact_events` (the delete + insert, which uses DML and so needs billing) and `build_models` (views, dimensions, `fact_sessions`, `dim_date` — `CREATE` statements only). In BigQuery Sandbox, which blocks DML, build `fact_events` with `CREATE OR REPLACE TABLE ... AS SELECT` and then call `build_models` — see Option B in `BigQuery/03_backfill.sql`.

**Idempotent by design.** `refresh_pipeline` replaces the `fact_events` rows for its window with a delete + insert inside one transaction. Running it twice for the same window gives the same result, and a failed run rolls back, leaving the previous data intact. This replaces the earlier plain `INSERT` of "yesterday", which duplicated the day on a retry.

**Why a lookback window, not just yesterday.** GA4 can keep updating a daily table for a short time after the day ends (late-arriving events — confirm the current window in Google's GA4 export docs). The daily job therefore reprocesses the last few complete days (default 3). The same lookback self-heals if a run was missed or a day's export landed late.

**Why the property's timezone.** GA4 names `events_YYYYMMDD` tables by the property's local date. `CURRENT_DATE()` returns the UTC date, which can differ by a day. The wrapper computes "today" with `CURRENT_DATE(property_timezone)`.

## Dimension keys: one formula, computed once

`device_key`, `geo_key`, `traffic_source_key`, and `app_info_key` are `MD5` hashes of each dimension's natural attributes, computed inside `flatten_events` and used identically everywhere. A `|` separates the attributes inside each hash, so different combinations can't concatenate to the same string (`'ab' + 'c'` vs `'a' + 'bc'`). Using a hash (not `ROW_NUMBER()`) means re-running a dimension build never creates duplicate or shifted keys — the same input always produces the same key.

**One row per key.** Some dimension attributes are not part of the hash (for example `device.language`, `browser_version`). Selecting `DISTINCT` over all attributes could return several rows for the same key, and Power BI would refuse to treat the relationship as many-to-one. Each dimension is therefore built with exactly one row per key; non-key attributes take their most recent value. `BigQuery/03_backfill.sql` includes checks for this.

## Dimension refresh: rebuilt each run, not merged

Dimensions are small and derived entirely from `fact_events` (or `fact_event_items`), so each run rebuilds them in full. That cannot create duplicates, and it keeps "latest value" columns current without any `MERGE` bookkeeping.

`dim_user` in particular is not static: a user's lifetime value (`user_ltv_revenue`) changes as they return. Because it is recomputed from `fact_events` on every run, it always carries each user's latest LTV and `last_seen_date` — an insert-only approach would freeze it at the first-seen value. Note that `first_seen_date` and `last_seen_date` reflect only the history loaded into BigQuery (the export has no backfill before the link date).

## Why `dim_app_info` is empty for web data

`dim_app_info` is built from events where `app_info_key` is not null, and `app_info_key` is only set when GA4 supplies an app ID. The sample dataset (and any web-only property) has no app data: every event has platform `WEB` and a null `app_info`. So the table is empty — **by design, not a failure.**

It fills up automatically for app (Firebase) properties or web+app properties. For web-only properties, don't import it into Power BI and skip its relationship (see `Docs/03_connect_powerbi.md`). Check 5 in `BigQuery/03_backfill.sql` confirms the platform breakdown.

## `fact_sessions`: derived, not native to the export

GA4's export has no native "session" table — sessions are reconstructed by grouping `fact_events` on `(user_key, session_id)`. This is built as a `VIEW` over all of `fact_events`, so a session that spans midnight is grouped as one session, dated by the day it started. It exists as its own object because it's the grain most marketing reporting needs (bounce rate, session count, entrance pages), and recalculating it inside every DAX measure would be slower and more error-prone.

If you later materialize it as a physical table loaded incrementally, rebuild every session that has *any* event in the load window — not only sessions that start in it — otherwise midnight-spanning sessions will be split.

## A note on BigQuery Sandbox behavior encountered during this build

`fact_event_items`, `bridge_event_params`, `bridge_user_properties` are `VIEW`s rather than physical tables. In Sandbox mode (no billing account), `CREATE TABLE` against these multi-source queries (`UNNEST`/comma-joins) intermittently failed with a `billing not enabled / table expiration must be < 60 days` error — even with an explicit expiration set. Views sidestep the restriction, at the cost of being recomputed on each query. Each view covers exactly the date range `fact_events` holds, and is re-pointed on every run so new days appear automatically.

All physical tables carry a 59-day expiration for the same reason. That is fine for a demo, but not for a real client: with billing enabled, remove those `OPTIONS(expiration_timestamp ...)` lines (see the note at the top of `BigQuery/02_pipeline_procedures.sql`).
