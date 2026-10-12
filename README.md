# GA4 → BigQuery → Power BI: Marketing Analytics Dashboard

A free, fully documented Power BI dashboard built on GA4 export data —
covering the entire pipeline, not just the report.

## What this is

- A complete, working data pipeline: **GA4 → BigQuery export → transformation → Power BI**
- Built and tested against Google's public GA4 sample dataset (`bigquery-public-data.ga4_obfuscated_sample_ecommerce`) — no live GA4 property needed to explore or reuse this
- Setup docs for every stage, including the part most guides skip: scheduling the pipeline to refresh on its own, and connecting via the native GA4→BigQuery export (free to set up — not a paid third-party connector)

## Architecture

```
GA4 property
   │  (native daily export — free to set up; limits apply, see Docs/01)
   ▼
BigQuery export (events_YYYYMMDD tables)
   │  (table functions: BigQuery/01_table_functions.sql)
   ▼
Transformation layer
   │  (stored procedures: BigQuery/02  |  backfill: 03  |  daily scheduled CALL: Refresh Schedule/04)
   ▼
Power BI semantic model
   │  (Import mode, star schema — see Docs/03)
   ▼
Dashboard
```

## Repo structure

```
├── BigQuery/
│   ├── 01_table_functions.sql        ← all transformation logic; the raw-source FROM lives in one place
│   ├── 02_pipeline_procedures.sql    ← refresh_pipeline + run_daily_refresh (build order, idempotent)
│   └── 03_backfill.sql               ← one CALL to load history + verification queries
├── Refresh Schedule/
│   └── 04_daily_incremental_load.sql ← the scheduled query (a single CALL)
├── Tests/
│   └── data_quality_tests.sql        ← one query: PASS/FAIL/WARN per data-quality rule
├── Docs/
│   ├── 01_link_ga4_to_bigquery.md
│   ├── 02_transformation_pipeline.md ← data modeling decisions, why things are built this way
│   └── 03_connect_powerbi.md         ← relationships, refresh, star schema
├── Sample Dataset/
│   └── about_the_dataset.md
└── Dashboard/
    └── (Power BI .pbix — added once the report is built)
```

## Get started

1. [Link GA4 to BigQuery](Docs/01_link_ga4_to_bigquery.md) *(or skip straight to the public sample dataset — see that doc)*
2. Run `BigQuery/01_table_functions.sql`, then `BigQuery/02_pipeline_procedures.sql` (each once)
3. Run `BigQuery/03_backfill.sql` to load history and check the results
4. Run `Tests/data_quality_tests.sql` — every row should be PASS (see its header for the expected WARNs on the sample data)
5. Read [the transformation pipeline doc](Docs/02_transformation_pipeline.md) — explains the *why* behind the data model, not just the *what*
6. [Connect Power BI](Docs/03_connect_powerbi.md)
7. For a real client: schedule `Refresh Schedule/04_daily_incremental_load.sql`

## Built with

Power BI · Google BigQuery · SQL

## What's free vs. what's premium

This repo covers the **Traffic Overview** tier — sessions, users, engagement, channel breakdown — built to work standalone for any business, ecommerce or not.

A premium version — full ecommerce/revenue analytics, cohort & retention analysis, attribution comparison, and an anomaly/insight layer (automated flags on meaningful week-over-week shifts) — is available on [BIBB](https://bibb.pro).

## More from Dashboard-Design

- [Power-BI-Design-Files](https://github.com/Dashboard-Design/PowerBI-Design-Files)
- [Power-BI-UDF-Library](https://github.com/Dashboard-Design/Power-BI-UDF-Library)

## License

MIT
