-- ============================================================
-- GA4 → Power BI: Daily Incremental Load
-- ============================================================
-- This is the PRODUCTION pattern — what you'd actually configure
-- as a BigQuery Scheduled Query against a real client's GA4 export
-- (their GA4 property auto-exports one new events_YYYYMMDD table
-- per day; this job processes only that new day, not full history).
--
-- Not required to explore this repo's demo, since the demo dataset
-- is static historical data. Included for completeness and as the
-- reference implementation for a real deployment.
--
-- Facts: plain append (each event/session is only ever written once).
-- Dimensions: MERGE (upsert) — the same device/geo/user reappears
-- across many days; a plain append would create duplicate rows and
-- silently inflate counts.
-- ============================================================

-- ---- Facts: append ----

INSERT INTO `<PROJECT_ID>.<DATASET>.fact_events`
SELECT * FROM `<PROJECT_ID>.<DATASET>.flatten_events`(
  DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY), DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY));

-- fact_event_items and both bridge tables are VIEWs (see 02's note) —
-- they recompute live from the source wildcard on every query, so no
-- daily insert job is needed for them at all.

-- ---- Dimensions: upsert (insert-only — static attributes) ----

MERGE `<PROJECT_ID>.<DATASET>.dim_device` T
USING (
  SELECT DISTINCT device_key, device_category, mobile_brand_name, operating_system, browser
  FROM `<PROJECT_ID>.<DATASET>.flatten_events`(DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY), DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY))
) S
ON T.device_key = S.device_key
WHEN NOT MATCHED THEN INSERT ROW;

MERGE `<PROJECT_ID>.<DATASET>.dim_geo` T
USING (
  SELECT DISTINCT geo_key, continent, country, region, city
  FROM `<PROJECT_ID>.<DATASET>.flatten_events`(DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY), DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY))
) S
ON T.geo_key = S.geo_key
WHEN NOT MATCHED THEN INSERT ROW;

MERGE `<PROJECT_ID>.<DATASET>.dim_traffic_source` T
USING (
  SELECT DISTINCT traffic_source_key, traffic_medium, traffic_campaign, traffic_source
  FROM `<PROJECT_ID>.<DATASET>.flatten_events`(DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY), DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY))
) S
ON T.traffic_source_key = S.traffic_source_key
WHEN NOT MATCHED THEN INSERT ROW;

MERGE `<PROJECT_ID>.<DATASET>.dim_item` T
USING (
  SELECT DISTINCT item_id AS item_key, item_name, item_brand, item_category
  FROM `<PROJECT_ID>.<DATASET>.flatten_event_items`(DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY), DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY))
  WHERE item_id IS NOT NULL
) S
ON T.item_key = S.item_key
WHEN NOT MATCHED THEN INSERT ROW;

-- ---- dim_user: upsert with UPDATE — a Slowly Changing Dimension ----
-- LTV grows over time for returning users. An insert-only MERGE would
-- silently freeze LTV at each user's first-seen value.

MERGE `<PROJECT_ID>.<DATASET>.dim_user` T
USING (
  SELECT
    user_key, ANY_VALUE(user_id) AS user_id,
    MIN(TIMESTAMP_MICROS(user_first_touch_timestamp)) AS first_touch_timestamp,
    MIN(date_key) AS seen_date,
    ARRAY_AGG(user_ltv_revenue ORDER BY event_timestamp DESC LIMIT 1)[OFFSET(0)] AS user_ltv_revenue,
    ARRAY_AGG(user_ltv_currency ORDER BY event_timestamp DESC LIMIT 1)[OFFSET(0)] AS user_ltv_currency
  FROM `<PROJECT_ID>.<DATASET>.flatten_events`(DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY), DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY))
  GROUP BY user_key
) S
ON T.user_key = S.user_key
WHEN MATCHED THEN UPDATE SET
  T.last_seen_date = S.seen_date,
  T.user_ltv_revenue = S.user_ltv_revenue,
  T.user_ltv_currency = S.user_ltv_currency
WHEN NOT MATCHED THEN INSERT (user_key, user_id, first_touch_timestamp, first_seen_date, last_seen_date, user_ltv_revenue, user_ltv_currency)
VALUES (S.user_key, S.user_id, S.first_touch_timestamp, S.seen_date, S.seen_date, S.user_ltv_revenue, S.user_ltv_currency);

-- To deploy: BigQuery console → run this script once to confirm it
-- works → Schedule → Create new scheduled query → daily, timed after
-- GA4's export typically lands for the day.
