# 3. Connecting Power BI

## Getting the data in

**Get Data → Google BigQuery → Import mode.**

Use **Import**, not DirectQuery — DirectQuery against BigQuery has documented latency (tens of seconds per interaction in some setups), which makes for a poor report experience. Import + scheduled refresh (matching the daily pipeline cadence) is the reliable choice.

## Which tables to import

| Table | Import? | Why |
|---|---|---|
| `fact_events` | ✅ | Core event-grain fact |
| `fact_event_items` | ✅ | Item-grain fact, for ecommerce pages |
| `fact_sessions` | ✅ | Session-grain fact |
| `dim_date`, `dim_device`, `dim_geo`, `dim_traffic_source`, `dim_app_info`, `dim_item`, `dim_user` | ✅ | All dimensions |
| `bridge_event_params` | ❌ | Full-fidelity audit/completeness table (millions of rows) — exists for warehouse completeness, not for dashboard use. Importing this will bloat the .pbix significantly for no reporting benefit. |
| `bridge_user_properties` | ❌ | Same reasoning as above |

## Relationships

| From (fact) | Column | To (dimension) | Column |
|---|---|---|---|
| `fact_events` | `date_key` | `dim_date` | `date_key` |
| `fact_events` | `device_key` | `dim_device` | `device_key` |
| `fact_events` | `geo_key` | `dim_geo` | `geo_key` |
| `fact_events` | `traffic_source_key` | `dim_traffic_source` | `traffic_source_key` |
| `fact_events` | `app_info_key` | `dim_app_info` | `app_info_key` |
| `fact_events` | `user_key` | `dim_user` | `user_key` |
| `fact_sessions` | `date_key` | `dim_date` | `date_key` |
| `fact_sessions` | `device_key` | `dim_device` | `device_key` |
| `fact_sessions` | `geo_key` | `dim_geo` | `geo_key` |
| `fact_sessions` | `traffic_source_key` | `dim_traffic_source` | `traffic_source_key` |
| `fact_sessions` | `user_key` | `dim_user` | `user_key` |
| `fact_event_items` | `item_id` | `dim_item` | `item_key` |

**Rules:**
- Every relationship: cardinality = **Many-to-one**, cross-filter direction = **Single**.
- **No relationship between `fact_events`, `fact_sessions`, and `fact_event_items`** — all three connect independently to shared dimensions instead (see `Docs/02_transformation_pipeline.md` for why).
- Mark `dim_date` as the model's official **Date Table** (Modeling tab → Mark as Date Table) to enable built-in time-intelligence functions.

## Refresh schedule

Set a scheduled refresh in the Power BI Service matching the pipeline's daily cadence (see `SQL/04_daily_incremental_load.sql`), timed after the scheduled query typically completes for the day.
