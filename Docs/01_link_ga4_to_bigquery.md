# 1. Linking GA4 to BigQuery

This pipeline runs on GA4's native BigQuery export — free, built into GA4, and the source of the most granular, unsampled event data available (versus the GA4 UI or API, which apply sampling and limits).

## For a real GA4 property

1. In GA4: **Admin → Product Links → BigQuery Links**.
2. Choose or create a BigQuery project to link to.
3. Set export frequency: **Daily**, and optionally **Streaming** for near-real-time data (daily is sufficient for this dashboard).
4. Confirm data location matches your BigQuery project's region.
5. Once linked, GA4 automatically creates one table per day — `events_YYYYMMDD` — inside a dataset named `analytics_<property_id>` in your BigQuery project. No further setup needed on the GA4 side; this happens automatically going forward.

## For exploring this repo without a live GA4 property

You don't need one. This repo is built and tested entirely against Google's public sample dataset:

```
bigquery-public-data.ga4_obfuscated_sample_ecommerce
```

An anonymized, real GA4 export from the Google Merchandise Store (~3 months of ecommerce event data). It uses the identical schema a real property produces, so everything in this repo transfers directly — swapping in a real property later is a one-line change (see `SQL/01_table_functions.sql`).

## Getting started with BigQuery, free

1. Create a Google Cloud project (no credit card required).
2. Use **BigQuery Sandbox mode** — free, no billing account needed, sufficient for this entire repo.
3. In the BigQuery console, query the public dataset directly by fully-qualifying the table name (no need to "add" the `bigquery-public-data` project — it's public).

### A known Sandbox limitation, and why it matters here

Sandbox mode enforces a hard 60-day table expiration, and in our testing, `CREATE TABLE` (not `VIEW`) against certain multi-source queries (`UNNEST`/comma-joins) intermittently failed with a misleading `billing not enabled` error — even with an explicit expiration set. See `SQL/02_backfill_base_tables.sql` for the workaround (some tables are built as `VIEW`s instead of physical tables). If you have billing enabled, you likely won't hit this and can convert those back to physical tables for better performance.
