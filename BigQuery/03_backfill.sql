-- ============================================================
-- GA4 → Power BI: Backfill (run once) + verification
-- ============================================================
-- Run after 01_table_functions.sql and 02_pipeline_procedures.sql.
-- Replace <PROJECT_ID> and <DATASET> as in the other files.

-- ------------------------------------------------------------
-- OPTIONAL — only if you built the PREVIOUS version of this repo.
-- The old fact_events has the old event_id / key formulas and isn't
-- partitioned; the procedure uses CREATE TABLE IF NOT EXISTS, so it
-- would keep the old table and mix two formulas. Drop the old
-- objects first (uncomment and run once):
-- ------------------------------------------------------------
-- DROP TABLE IF EXISTS `<PROJECT_ID>.<DATASET>.fact_events`;
-- DROP VIEW  IF EXISTS `<PROJECT_ID>.<DATASET>.fact_event_items`;
-- DROP VIEW  IF EXISTS `<PROJECT_ID>.<DATASET>.bridge_event_params`;
-- DROP VIEW  IF EXISTS `<PROJECT_ID>.<DATASET>.bridge_user_properties`;
-- DROP VIEW  IF EXISTS `<PROJECT_ID>.<DATASET>.fact_sessions`;

-- ------------------------------------------------------------
-- Backfill. The sample dataset covers 2020-11-01 → 2021-01-31.
-- For a real client, use the date their GA4 export started.
-- refresh_pipeline is idempotent, so a long history can safely be
-- loaded in chunks (e.g. one call per month) if a single call is too
-- heavy — and a failed chunk can simply be re-run.
-- ------------------------------------------------------------
-- OPTION A — project WITH billing enabled (required for the daily job):
CALL `<PROJECT_ID>.<DATASET>.refresh_pipeline`(DATE '2020-11-01', DATE '2021-01-31');

-- OPTION B — BigQuery Sandbox (no billing). Sandbox blocks DML
-- (DELETE/INSERT), so fact_events is rebuilt with CREATE OR REPLACE
-- TABLE and only the DDL-based steps are run. To use it: comment out
-- Option A and uncomment the lines below.
-- -- NOTE: no PARTITION BY here on purpose. Sandbox sets a 60-day partition
-- -- expiration, and BigQuery expires any partition older than that the moment
-- -- data is written — so the 2020-21 sample data would load as ZERO rows.
-- CREATE OR REPLACE TABLE `<PROJECT_ID>.<DATASET>.fact_events`
-- OPTIONS(expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 59 DAY))
-- AS SELECT * FROM `<PROJECT_ID>.<DATASET>.flatten_events`(DATE '2020-11-01', DATE '2021-01-31');
-- CALL `<PROJECT_ID>.<DATASET>.build_models`();

-- ============================================================
-- Verification
-- ============================================================

-- 1. Row counts — everything should be non-zero EXCEPT dim_app_info
--    on a web-only property (expected empty — see Docs/02).
SELECT 'fact_events' AS table_name, COUNT(*) AS row_count FROM `<PROJECT_ID>.<DATASET>.fact_events`
UNION ALL SELECT 'fact_event_items', COUNT(*) FROM `<PROJECT_ID>.<DATASET>.fact_event_items`
UNION ALL SELECT 'bridge_event_params', COUNT(*) FROM `<PROJECT_ID>.<DATASET>.bridge_event_params`
UNION ALL SELECT 'bridge_user_properties', COUNT(*) FROM `<PROJECT_ID>.<DATASET>.bridge_user_properties`
UNION ALL SELECT 'fact_sessions', COUNT(*) FROM `<PROJECT_ID>.<DATASET>.fact_sessions`
UNION ALL SELECT 'dim_date', COUNT(*) FROM `<PROJECT_ID>.<DATASET>.dim_date`
UNION ALL SELECT 'dim_device', COUNT(*) FROM `<PROJECT_ID>.<DATASET>.dim_device`
UNION ALL SELECT 'dim_geo', COUNT(*) FROM `<PROJECT_ID>.<DATASET>.dim_geo`
UNION ALL SELECT 'dim_traffic_source', COUNT(*) FROM `<PROJECT_ID>.<DATASET>.dim_traffic_source`
UNION ALL SELECT 'dim_app_info', COUNT(*) FROM `<PROJECT_ID>.<DATASET>.dim_app_info`
UNION ALL SELECT 'dim_item', COUNT(*) FROM `<PROJECT_ID>.<DATASET>.dim_item`
UNION ALL SELECT 'dim_user', COUNT(*) FROM `<PROJECT_ID>.<DATASET>.dim_user`;

-- 2. event_id must be unique — this should return ZERO rows.
SELECT event_id, COUNT(*) AS n
FROM `<PROJECT_ID>.<DATASET>.fact_events`
GROUP BY event_id HAVING n > 1
LIMIT 10;

-- 3. Every dimension must have exactly one row per key
--    (rows = distinct_keys). A mismatch means Power BI will refuse
--    the many-to-one relationship.
SELECT 'dim_device' AS dim, COUNT(*) AS row_count, COUNT(DISTINCT device_key) AS distinct_keys FROM `<PROJECT_ID>.<DATASET>.dim_device`
UNION ALL SELECT 'dim_geo', COUNT(*), COUNT(DISTINCT geo_key) FROM `<PROJECT_ID>.<DATASET>.dim_geo`
UNION ALL SELECT 'dim_traffic_source', COUNT(*), COUNT(DISTINCT traffic_source_key) FROM `<PROJECT_ID>.<DATASET>.dim_traffic_source`
UNION ALL SELECT 'dim_item', COUNT(*), COUNT(DISTINCT item_key) FROM `<PROJECT_ID>.<DATASET>.dim_item`
UNION ALL SELECT 'dim_user', COUNT(*), COUNT(DISTINCT user_key) FROM `<PROJECT_ID>.<DATASET>.dim_user`;

-- 4. Orphan check — events whose key has no dimension row. Should be 0.
SELECT 'device' AS dim, COUNT(*) AS orphan_events
FROM `<PROJECT_ID>.<DATASET>.fact_events` f
LEFT JOIN `<PROJECT_ID>.<DATASET>.dim_device` d ON f.device_key = d.device_key
WHERE d.device_key IS NULL
UNION ALL
SELECT 'geo', COUNT(*)
FROM `<PROJECT_ID>.<DATASET>.fact_events` f
LEFT JOIN `<PROJECT_ID>.<DATASET>.dim_geo` d ON f.geo_key = d.geo_key
WHERE d.geo_key IS NULL
UNION ALL
SELECT 'traffic_source', COUNT(*)
FROM `<PROJECT_ID>.<DATASET>.fact_events` f
LEFT JOIN `<PROJECT_ID>.<DATASET>.dim_traffic_source` d ON f.traffic_source_key = d.traffic_source_key
WHERE d.traffic_source_key IS NULL;

-- 5. Why dim_app_info is empty: on web data every event is platform = WEB
--    and app_info_key is NULL. Expect events_with_app_info = 0.
SELECT platform, COUNT(*) AS events, COUNTIF(app_info_key IS NOT NULL) AS events_with_app_info
FROM `<PROJECT_ID>.<DATASET>.fact_events`
GROUP BY platform;
