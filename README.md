# GA4 → BigQuery → Power BI: Marketing Analytics Dashboard

A free, fully documented Power BI dashboard built on GA4 export data —
covering the entire pipeline, not just the report.

## What this is

- A complete, working data pipeline: **GA4 → BigQuery export → transformation → Power BI**
- Built and tested against Google's public GA4 sample dataset (`bigquery-public-data.ga4_obfuscated_sample_ecommerce`) — no live GA4 property needed to explore or reuse this
- Setup docs for every stage, including the part most guides skip: scheduling the pipeline to refresh on its own, and connecting via the **free** GA4→BigQuery export route (not a paid third-party connector)

## Architecture

```
GA4 property
   │  (free, native, automatic daily export)
   ▼
BigQuery export (events_YYYYMMDD tables)
   │  (table functions: 01_table_functions.sql)
   ▼
Transformation layer
   │  (backfill: 02 + 03  |  daily incremental: 04)
   ▼
Power BI semantic model
   │  (Import mode, star schema — see Docs/03)
   ▼
Dashboard
```

## Repo structure

```
├── SQL/
│   ├── 01_table_functions.sql        ← all transformation logic, one place
│   ├── 02_backfill_base_tables.sql   ← fact_events, fact_event_items, bridges
│   ├── 03_backfill_dimensions.sql    ← all dim_* tables + fact_sessions
│   └── 04_daily_incremental_load.sql ← production scheduled-query pattern
├── Docs/
│   ├── 01_link_ga4_to_bigquery.md
│   ├── 02_transformation_pipeline.md ← data modeling decisions, why things are built this way
│   └── 03_connect_powerbi.md         ← relationships, refresh, star schema
└── Dashboard/
    └── (Power BI .pbix — added once the report is built)
```

## Get started

1. [Link GA4 to BigQuery](Docs/01_link_ga4_to_bigquery.md) *(or skip straight to the public sample dataset — see that doc)*
2. Run `SQL/01_table_functions.sql`, then `02_backfill_base_tables.sql`, then `03_backfill_dimensions.sql`
3. Read [the transformation pipeline doc](Docs/02_transformation_pipeline.md) — explains the *why* behind the data model, not just the *what*
4. [Connect Power BI](Docs/03_connect_powerbi.md)

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
