-- ============================================================
-- GA4 → Power BI: Backfill — Dimensions & fact_sessions
-- ============================================================
-- Run once, after 02_backfill_base_tables.sql. Depends on
-- fact_events and fact_event_items already existing.
-- ============================================================

-- dim_date: standalone calendar table, marked as the model's
-- official Date table in Power BI (Modeling → Mark as Date Table)
CREATE OR REPLACE TABLE `<PROJECT_ID>.<DATASET>.dim_date`
OPTIONS(expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 59 DAY))
AS
SELECT
  d AS date_key, EXTRACT(YEAR FROM d) AS year, EXTRACT(QUARTER FROM d) AS quarter,
  EXTRACT(MONTH FROM d) AS month, FORMAT_DATE('%B', d) AS month_name,
  EXTRACT(DAY FROM d) AS day, FORMAT_DATE('%A', d) AS day_name,
  EXTRACT(DAYOFWEEK FROM d) IN (1,7) AS is_weekend
FROM UNNEST(GENERATE_DATE_ARRAY('2020-01-01', '2026-12-31')) AS d;

CREATE OR REPLACE TABLE `<PROJECT_ID>.<DATASET>.dim_device`
OPTIONS(expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 59 DAY))
AS
SELECT DISTINCT device_key, device_category, mobile_brand_name, mobile_model_name, mobile_marketing_name,
  operating_system, operating_system_version, language, is_limited_ad_tracking, browser, browser_version
FROM `<PROJECT_ID>.<DATASET>.fact_events`;

CREATE OR REPLACE TABLE `<PROJECT_ID>.<DATASET>.dim_geo`
OPTIONS(expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 59 DAY))
AS
SELECT DISTINCT geo_key, continent, sub_continent, country, region, city, metro
FROM `<PROJECT_ID>.<DATASET>.fact_events`;

CREATE OR REPLACE TABLE `<PROJECT_ID>.<DATASET>.dim_traffic_source`
OPTIONS(expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 59 DAY))
AS
SELECT DISTINCT traffic_source_key, traffic_medium, traffic_campaign, traffic_source
FROM `<PROJECT_ID>.<DATASET>.fact_events`;

CREATE OR REPLACE TABLE `<PROJECT_ID>.<DATASET>.dim_app_info`
OPTIONS(expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 59 DAY))
AS
SELECT DISTINCT app_info_key, app_id, app_version, install_store, firebase_app_id, install_source
FROM `<PROJECT_ID>.<DATASET>.fact_events`
WHERE app_info_key IS NOT NULL;  -- null on all web-only properties, expected

CREATE OR REPLACE TABLE `<PROJECT_ID>.<DATASET>.dim_item`
OPTIONS(expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 59 DAY))
AS
SELECT DISTINCT item_id AS item_key, item_name, item_brand, item_variant,
  item_category, item_category2, item_category3, item_category4, item_category5
FROM `<PROJECT_ID>.<DATASET>.fact_event_items`
WHERE item_id IS NOT NULL;

-- dim_user: a Slowly Changing Dimension — LTV grows with each new
-- event, so the daily incremental job (04_daily_incremental_load.sql)
-- MUST use MERGE...WHEN MATCHED THEN UPDATE, not INSERT-only, or
-- returning users' LTV will silently freeze at their first-seen value.
CREATE OR REPLACE TABLE `<PROJECT_ID>.<DATASET>.dim_user`
OPTIONS(expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 59 DAY))
AS
SELECT
  user_key, ANY_VALUE(user_id) AS user_id,
  MIN(TIMESTAMP_MICROS(user_first_touch_timestamp)) AS first_touch_timestamp,
  MIN(date_key) AS first_seen_date, MAX(date_key) AS last_seen_date,
  ARRAY_AGG(user_ltv_revenue ORDER BY event_timestamp DESC LIMIT 1)[OFFSET(0)] AS user_ltv_revenue,
  ARRAY_AGG(user_ltv_currency ORDER BY event_timestamp DESC LIMIT 1)[OFFSET(0)] AS user_ltv_currency
FROM `<PROJECT_ID>.<DATASET>.fact_events`
GROUP BY user_key;

-- fact_sessions: derived session-grain table. VIEW, not a physical
-- table — see the Sandbox note in 02_backfill_base_tables.sql.
CREATE OR REPLACE VIEW `<PROJECT_ID>.<DATASET>.fact_sessions` AS
SELECT
  user_key, session_id, MIN(date_key) AS date_key,
  MIN(event_timestamp) AS session_start_ts, MAX(event_timestamp) AS session_end_ts,
  TIMESTAMP_DIFF(TIMESTAMP_MICROS(MAX(event_timestamp)), TIMESTAMP_MICROS(MIN(event_timestamp)), SECOND) AS session_duration_seconds,
  COUNT(*) AS event_count, COUNTIF(event_name = 'purchase') > 0 AS has_purchase,
  SUM(purchase_revenue_in_usd) AS session_revenue_usd, LOGICAL_OR(session_engaged = '1') AS is_engaged,
  ARRAY_AGG(page_location ORDER BY event_timestamp ASC LIMIT 1)[OFFSET(0)] AS entrance_page,
  ARRAY_AGG(device_key ORDER BY event_timestamp ASC LIMIT 1)[OFFSET(0)] AS device_key,
  ARRAY_AGG(geo_key ORDER BY event_timestamp ASC LIMIT 1)[OFFSET(0)] AS geo_key,
  ARRAY_AGG(traffic_source_key ORDER BY event_timestamp ASC LIMIT 1)[OFFSET(0)] AS traffic_source_key
FROM `<PROJECT_ID>.<DATASET>.fact_events`
WHERE session_id IS NOT NULL
GROUP BY user_key, session_id;

-- Verification
SELECT 'dim_date' AS table_name, COUNT(*) AS row_count FROM `<PROJECT_ID>.<DATASET>.dim_date`
UNION ALL SELECT 'dim_device', COUNT(*) FROM `<PROJECT_ID>.<DATASET>.dim_device`
UNION ALL SELECT 'dim_geo', COUNT(*) FROM `<PROJECT_ID>.<DATASET>.dim_geo`
UNION ALL SELECT 'dim_traffic_source', COUNT(*) FROM `<PROJECT_ID>.<DATASET>.dim_traffic_source`
UNION ALL SELECT 'dim_app_info', COUNT(*) FROM `<PROJECT_ID>.<DATASET>.dim_app_info`
UNION ALL SELECT 'dim_item', COUNT(*) FROM `<PROJECT_ID>.<DATASET>.dim_item`
UNION ALL SELECT 'dim_user', COUNT(*) FROM `<PROJECT_ID>.<DATASET>.dim_user`
UNION ALL SELECT 'fact_sessions', COUNT(*) FROM `<PROJECT_ID>.<DATASET>.fact_sessions`;
