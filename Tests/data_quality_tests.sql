-- ============================================================
-- GA4 → Power BI: Data Quality Tests
-- ============================================================
-- Run this AFTER the backfill (BigQuery/03_backfill.sql) and after any
-- change to the SQL, or on a schedule once the pipeline is live.
--
-- It returns ONE table: one row per test, with a status.
--   PASS  the check found 0 problem rows
--   FAIL  a rule the model depends on is broken — fix before using the data
--   WARN  worth a look, but may be legitimate (see the notes below)
-- "failing_rows" is how many rows broke the rule. Failures sort first.
--
-- Each test is a plain SQL question whose correct answer is "0 bad rows".
-- Replace <PROJECT_ID>.<DATASET> as in the other files.
--
-- What these would have caught during development:
--   * an EMPTY fact_events table (Sandbox partition expiry)  → tests 1, 2
--   * duplicate event_id values                              → test 3
--   * a dimension with 2 rows for one key (Power BI rejects
--     the relationship)                                      → tests 5-9
--
-- Expected WARNs on the 2020-21 SAMPLE dataset:
--   * data_is_fresh — the sample data is years old.
--   * duplicate_purchase_transaction_ids — may be non-zero; real GA4 data
--     can contain duplicate purchase events. Decide how to treat them.
-- ============================================================

DECLARE d0 DATE;
DECLARE d1 DATE;
SET (d0, d1) = (SELECT AS STRUCT MIN(date_key), MAX(date_key) FROM `<PROJECT_ID>.<DATASET>.fact_events`);

WITH results AS (

  -- ---------- fact_events: completeness and identity ----------
  SELECT 'fact_events_not_empty' AS test, 'error' AS severity,
    IF((SELECT COUNT(*) FROM `<PROJECT_ID>.<DATASET>.fact_events`) = 0, 1, 0) AS failing_rows,
    'fact_events contains at least one row' AS what_it_checks

  UNION ALL SELECT 'fact_events_matches_source_row_count', 'error',
    ABS((SELECT COUNT(*) FROM `<PROJECT_ID>.<DATASET>.fact_events`)
      - (SELECT COUNT(*) FROM `<PROJECT_ID>.<DATASET>.ga4_events_with_id`(d0, d1))),
    'row count equals the raw GA4 export for the same dates (nothing dropped or duplicated)'

  UNION ALL SELECT 'event_id_unique', 'error',
    (SELECT COUNT(*) FROM (SELECT event_id FROM `<PROJECT_ID>.<DATASET>.fact_events` GROUP BY event_id HAVING COUNT(*) > 1)),
    'no event_id appears more than once'

  UNION ALL SELECT 'event_id_and_date_key_not_null', 'error',
    (SELECT COUNTIF(event_id IS NULL OR date_key IS NULL) FROM `<PROJECT_ID>.<DATASET>.fact_events`),
    'every event has an event_id and a date_key'

  -- ---------- dimensions: exactly one row per key ----------
  UNION ALL SELECT 'dim_device_one_row_per_key', 'error',
    (SELECT COUNT(*) - COUNT(DISTINCT device_key) FROM `<PROJECT_ID>.<DATASET>.dim_device`),
    'duplicate keys break the many-to-one relationship in Power BI'
  UNION ALL SELECT 'dim_geo_one_row_per_key', 'error',
    (SELECT COUNT(*) - COUNT(DISTINCT geo_key) FROM `<PROJECT_ID>.<DATASET>.dim_geo`), 'as above'
  UNION ALL SELECT 'dim_traffic_source_one_row_per_key', 'error',
    (SELECT COUNT(*) - COUNT(DISTINCT traffic_source_key) FROM `<PROJECT_ID>.<DATASET>.dim_traffic_source`), 'as above'
  UNION ALL SELECT 'dim_item_one_row_per_key', 'error',
    (SELECT COUNT(*) - COUNT(DISTINCT item_key) FROM `<PROJECT_ID>.<DATASET>.dim_item`), 'as above'
  UNION ALL SELECT 'dim_user_one_row_per_key', 'error',
    (SELECT COUNT(*) - COUNT(DISTINCT user_key) FROM `<PROJECT_ID>.<DATASET>.dim_user`), 'as above'

  -- ---------- relationships: every fact key exists in its dimension ----------
  UNION ALL SELECT 'orphans_events_to_dim_device', 'error',
    (SELECT COUNT(*) FROM `<PROJECT_ID>.<DATASET>.fact_events` f
     WHERE NOT EXISTS (SELECT 1 FROM `<PROJECT_ID>.<DATASET>.dim_device` d WHERE d.device_key = f.device_key)),
    'events whose device_key has no dim_device row (rows vanish from visuals)'
  UNION ALL SELECT 'orphans_events_to_dim_geo', 'error',
    (SELECT COUNT(*) FROM `<PROJECT_ID>.<DATASET>.fact_events` f
     WHERE NOT EXISTS (SELECT 1 FROM `<PROJECT_ID>.<DATASET>.dim_geo` d WHERE d.geo_key = f.geo_key)), 'as above'
  UNION ALL SELECT 'orphans_events_to_dim_traffic_source', 'error',
    (SELECT COUNT(*) FROM `<PROJECT_ID>.<DATASET>.fact_events` f
     WHERE NOT EXISTS (SELECT 1 FROM `<PROJECT_ID>.<DATASET>.dim_traffic_source` d WHERE d.traffic_source_key = f.traffic_source_key)), 'as above'
  UNION ALL SELECT 'orphans_events_to_dim_user', 'error',
    (SELECT COUNT(*) FROM `<PROJECT_ID>.<DATASET>.fact_events` f
     WHERE f.user_key IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM `<PROJECT_ID>.<DATASET>.dim_user` d WHERE d.user_key = f.user_key)), 'as above'
  UNION ALL SELECT 'orphans_events_to_dim_date', 'error',
    (SELECT COUNT(*) FROM `<PROJECT_ID>.<DATASET>.fact_events` f
     WHERE NOT EXISTS (SELECT 1 FROM `<PROJECT_ID>.<DATASET>.dim_date` d WHERE d.date_key = f.date_key)),
    'event dates outside the dim_date calendar'
  UNION ALL SELECT 'orphans_sessions_to_dim_device', 'error',
    (SELECT COUNT(*) FROM `<PROJECT_ID>.<DATASET>.fact_sessions` s
     WHERE NOT EXISTS (SELECT 1 FROM `<PROJECT_ID>.<DATASET>.dim_device` d WHERE d.device_key = s.device_key)), 'as above'
  UNION ALL SELECT 'orphans_sessions_to_dim_geo', 'error',
    (SELECT COUNT(*) FROM `<PROJECT_ID>.<DATASET>.fact_sessions` s
     WHERE NOT EXISTS (SELECT 1 FROM `<PROJECT_ID>.<DATASET>.dim_geo` d WHERE d.geo_key = s.geo_key)), 'as above'
  UNION ALL SELECT 'orphans_sessions_to_dim_traffic_source', 'error',
    (SELECT COUNT(*) FROM `<PROJECT_ID>.<DATASET>.fact_sessions` s
     WHERE NOT EXISTS (SELECT 1 FROM `<PROJECT_ID>.<DATASET>.dim_traffic_source` d WHERE d.traffic_source_key = s.traffic_source_key)), 'as above'
  UNION ALL SELECT 'orphans_sessions_to_dim_user', 'error',
    (SELECT COUNT(*) FROM `<PROJECT_ID>.<DATASET>.fact_sessions` s
     WHERE s.user_key IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM `<PROJECT_ID>.<DATASET>.dim_user` d WHERE d.user_key = s.user_key)), 'as above'
  UNION ALL SELECT 'orphans_sessions_to_dim_date', 'error',
    (SELECT COUNT(*) FROM `<PROJECT_ID>.<DATASET>.fact_sessions` s
     WHERE NOT EXISTS (SELECT 1 FROM `<PROJECT_ID>.<DATASET>.dim_date` d WHERE d.date_key = s.date_key)), 'as above'
  UNION ALL SELECT 'orphans_items_to_dim_item', 'error',
    (SELECT COUNT(*) FROM `<PROJECT_ID>.<DATASET>.fact_event_items` i
     WHERE i.item_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM `<PROJECT_ID>.<DATASET>.dim_item` d WHERE d.item_key = i.item_id)), 'as above'

  -- ---------- sessions reconcile with events ----------
  UNION ALL SELECT 'sessions_account_for_all_events', 'error',
    ABS((SELECT COUNTIF(session_id IS NOT NULL) FROM `<PROJECT_ID>.<DATASET>.fact_events`)
      - (SELECT IFNULL(SUM(event_count), 0) FROM `<PROJECT_ID>.<DATASET>.fact_sessions`)),
    'events that carry a session_id all land in exactly one session'

  -- ---------- warnings: look, but may be legitimate ----------
  UNION ALL SELECT 'no_missing_days', 'warn',
    (SELECT COUNT(*) FROM UNNEST(GENERATE_DATE_ARRAY(d0, d1)) AS d
     WHERE NOT EXISTS (SELECT 1 FROM `<PROJECT_ID>.<DATASET>.fact_events` f WHERE f.date_key = d)),
    'days inside the loaded range with zero events (a missed or failed export day)'

  UNION ALL SELECT 'data_is_fresh', 'warn',
    IF(DATE_DIFF(CURRENT_DATE(), d1, DAY) > 3, 1, 0),
    'latest loaded day is within 3 days of today (WARNs on the static sample dataset)'

  UNION ALL SELECT 'duplicate_purchase_transaction_ids', 'warn',
    (SELECT COUNT(*) FROM (
       SELECT transaction_id FROM `<PROJECT_ID>.<DATASET>.fact_events`
       WHERE event_name = 'purchase' AND transaction_id IS NOT NULL AND transaction_id != '(not set)'
       GROUP BY transaction_id HAVING COUNT(*) > 1)),
    'the same transaction_id on more than one purchase event can inflate revenue'
)

SELECT
  test,
  CASE WHEN failing_rows = 0 THEN 'PASS' WHEN severity = 'error' THEN 'FAIL' ELSE 'WARN' END AS status,
  failing_rows,
  what_it_checks
FROM results
ORDER BY CASE WHEN failing_rows = 0 THEN 2 WHEN severity = 'error' THEN 0 ELSE 1 END, test;
