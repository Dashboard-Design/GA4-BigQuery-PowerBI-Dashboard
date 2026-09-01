-- ============================================================
-- GA4 → Power BI: Backfill — Base Tables
-- ============================================================
-- Run once, after 01_table_functions.sql, to build the base
-- warehouse layer from historical data.
--
-- IMPORTANT — BigQuery Sandbox note:
-- fact_events is created as a physical TABLE with an explicit
-- expiration under 60 days. fact_event_items and both bridge
-- tables are created as VIEWs instead of physical tables.
-- This is a deliberate workaround: in BigQuery Sandbox mode
-- (no billing account attached), CREATE TABLE against these
-- particular multi-source (UNNEST/comma-join) queries
-- intermittently failed with a misleading "billing not enabled /
-- table expiration must be < 60 days" error, even with an
-- explicit expiration set. Converting to VIEWs sidesteps the
-- issue entirely, since views hold no storage and aren't subject
-- to the same restriction. If you have billing enabled on your
-- project, you can safely convert these back to physical tables
-- for better query performance — remove "VIEW", add
-- OPTIONS(expiration_timestamp = ...), and use CREATE TABLE.
-- ============================================================

CREATE OR REPLACE TABLE `<PROJECT_ID>.<DATASET>.fact_events`
OPTIONS(expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 59 DAY))
AS SELECT * FROM `<PROJECT_ID>.<DATASET>.flatten_events`(DATE('2020-11-01'), DATE('2021-01-31'));

CREATE OR REPLACE VIEW `<PROJECT_ID>.<DATASET>.fact_event_items` AS
SELECT * FROM `<PROJECT_ID>.<DATASET>.flatten_event_items`(DATE('2020-11-01'), DATE('2021-01-31'));

CREATE OR REPLACE VIEW `<PROJECT_ID>.<DATASET>.bridge_event_params` AS
SELECT * FROM `<PROJECT_ID>.<DATASET>.flatten_event_params`(DATE('2020-11-01'), DATE('2021-01-31'));

CREATE OR REPLACE VIEW `<PROJECT_ID>.<DATASET>.bridge_user_properties` AS
SELECT * FROM `<PROJECT_ID>.<DATASET>.flatten_user_properties`(DATE('2020-11-01'), DATE('2021-01-31'));

-- Verification — every row should show a real, non-zero count
SELECT 'fact_events' AS table_name, COUNT(*) AS row_count FROM `<PROJECT_ID>.<DATASET>.fact_events`
UNION ALL SELECT 'fact_event_items', COUNT(*) FROM `<PROJECT_ID>.<DATASET>.fact_event_items`
UNION ALL SELECT 'bridge_event_params', COUNT(*) FROM `<PROJECT_ID>.<DATASET>.bridge_event_params`
UNION ALL SELECT 'bridge_user_properties', COUNT(*) FROM `<PROJECT_ID>.<DATASET>.bridge_user_properties`;
