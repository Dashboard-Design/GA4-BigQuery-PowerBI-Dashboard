# 1. Linking GA4 to BigQuery

This pipeline runs on GA4's native BigQuery export — free to set up, built into GA4, and the source of the most granular, unsampled event data available (versus the GA4 UI or API, which apply sampling and limits).

## For a real GA4 property

1. In GA4: **Admin → Product Links → BigQuery Links**. (You need Editor access or above on the property.)
2. Choose or create a BigQuery project to link to.
3. Set export frequency: **Daily**, and optionally **Streaming** for near-real-time data (daily is sufficient for this dashboard).
4. Confirm data location matches your BigQuery project's region.
5. Once linked, GA4 automatically creates one table per day — `events_YYYYMMDD` — inside a dataset named `analytics_<property_id>` in your BigQuery project. No further setup needed on the GA4 side; this happens automatically going forward.

### Limits to know about before promising a client "free"

- **Cost.** Exporting to the BigQuery Sandbox is free within Sandbox limits; beyond those, BigQuery storage and query costs apply on the client's Google Cloud project. For small and mid-size sites this is usually small, but it isn't zero.
- **Volume cap.** Standard (non-360) GA4 properties have a daily export limit of 1 million events. If a property consistently exceeds it, the daily export is paused and previous days are not reprocessed. GA4 lets you exclude data streams and specific events from the export to stay under the cap.
- **No backfill.** The export only contains data from the day the link is created. Link it as early as possible.
- **Sandbox is demo-only.** Sandbox tables expire (under 60 days), DML statements (INSERT/UPDATE/DELETE/MERGE) are blocked, partitions older than 60 days are dropped as soon as they are written (so don't partition historical data in Sandbox), and scheduled queries need billing. Any real client deployment should use a project with billing enabled.

Check Google's current BigQuery Export documentation for exact limits — they change.

## For exploring this repo without a live GA4 property

You don't need one. This repo is built and tested entirely against Google's public sample dataset:

```
bigquery-public-data.ga4_obfuscated_sample_ecommerce
```

An anonymized, real GA4 export from the Google Merchandise Store (~3 months of ecommerce event data). It has the same core structure a real property produces, so the pipeline transfers directly — swapping in a real property later is a one-line change (see `BigQuery/01_table_functions.sql`: the `FROM` line inside `ga4_events_with_id`).

Note that the sample is from 2020–21. Newer exports contain columns the sample doesn't (for example newer traffic-source fields), so test against a recent export of your own before relying on it for a client.

## Getting started with BigQuery, free

1. Create a Google Cloud project (no credit card required).
2. Use **BigQuery Sandbox mode** — free, no billing account needed, sufficient to explore this repo.
3. In the BigQuery console, query the public dataset directly by fully-qualifying the table name (no need to "add" the `bigquery-public-data` project — it's public).

### A known Sandbox limitation, and why it matters here

Sandbox mode enforces a hard 60-day table expiration, and in our testing, `CREATE TABLE` (not `VIEW`) against certain multi-source queries (`UNNEST`/comma-joins) intermittently failed with a misleading `billing not enabled` error — even with an explicit expiration set. See the note at the top of `BigQuery/02_pipeline_procedures.sql`: the item/params tables are built as `VIEW`s, and every table carries a 59-day expiration. With billing enabled you can delete those expiration lines and, if you like, convert the views to physical tables for better performance.
