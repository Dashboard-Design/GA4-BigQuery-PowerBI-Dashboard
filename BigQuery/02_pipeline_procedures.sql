-- ============================================================
-- GA4 → Power BI: Pipeline Stored Procedures
-- ============================================================
-- Run this file ONCE (after 01_table_functions.sql) to create two
-- procedures. They replace the old separate backfill / daily scripts:
--
--   refresh_pipeline(start_date, end_date) = load_fact_events + build_models
--       Does the whole build, in dependency order, for a date window.
--       IDEMPOTENT: calling it twice for the same window gives the
--       same result — no duplicates. Used for BOTH the first backfill
--       and the daily load.
--
--   run_daily_refresh(property_timezone, lookback_days)
--       Thin wrapper for the scheduled query: works out the window
--       in the GA4 property's timezone and calls refresh_pipeline.
--
-- Dependency order inside refresh_pipeline:
--   1. fact_events      (partitioned table: replace the date window)
--   2. views            (fact_event_items, bridges — need fact_events' date range)
--   3. dimensions       (dim_* are built FROM fact_events / fact_event_items)
--   4. fact_sessions    (view over fact_events)
--   5. dim_date
--
-- SANDBOX NOTE: the OPTIONS(expiration_timestamp ...) lines exist only
-- because Sandbox forces tables to expire in < 60 days. With billing
-- enabled, DELETE those lines (all of them). In Sandbox, treat the
-- whole pipeline as a demo: when fact_events expires, the next run
-- would silently recreate it empty and load only the new window.
-- PARTITION EXPIRATION: datasets created in Sandbox keep a default
-- 60-day table AND partition expiration even after you enable billing.
-- Partitions older than that are dropped as soon as they're written, so
-- loading historical data into the partitioned fact_events would silently
-- give an empty table. After enabling billing, clear the defaults first:
--   ALTER SCHEMA `<PROJECT_ID>.<DATASET>` SET OPTIONS(
--     default_table_expiration_days = NULL,
--     default_partition_expiration_days = NULL);
-- (and remove the OPTIONS(expiration_timestamp ...) lines below).
-- ============================================================

-- strict_mode=false: BigQuery otherwise validates procedure bodies at
-- creation time and fails because objects are created by the pipeline
-- itself (fact_events, the views) or by other procedures not yet defined.
-- ------------------------------------------------------------
-- load_fact_events: STEP 1 only — replaces the date window in fact_events.
-- Uses DML (DELETE/INSERT), so it needs a project WITH billing enabled.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE `<PROJECT_ID>.<DATASET>.load_fact_events`(start_date DATE, end_date DATE)
OPTIONS(strict_mode=false)
BEGIN
  IF start_date > end_date THEN
    RAISE USING MESSAGE = 'refresh_pipeline: start_date must be on or before end_date';
  END IF;

  -- ----------------------------------------------------------
  -- STEP 1: fact_events — replace the date window atomically
  -- ----------------------------------------------------------
  -- Creates an empty, date-partitioned table on first run only.
  CREATE TABLE IF NOT EXISTS `<PROJECT_ID>.<DATASET>.fact_events`
  PARTITION BY date_key
  OPTIONS(expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 59 DAY))
  AS SELECT * FROM `<PROJECT_ID>.<DATASET>.flatten_events`(start_date, start_date) WHERE FALSE;

  -- Delete + insert in one transaction: a failed run rolls back and
  -- leaves the previous data untouched. Re-running = same result.
  BEGIN
    BEGIN TRANSACTION;

    DELETE FROM `<PROJECT_ID>.<DATASET>.fact_events`
    WHERE date_key BETWEEN start_date AND end_date;

    INSERT INTO `<PROJECT_ID>.<DATASET>.fact_events`
    SELECT * FROM `<PROJECT_ID>.<DATASET>.flatten_events`(start_date, end_date);

    COMMIT TRANSACTION;
  EXCEPTION WHEN ERROR THEN
    ROLLBACK TRANSACTION;
    RAISE;
  END;
END;

-- ------------------------------------------------------------
-- build_models: STEPS 2–5 — views, dimensions, fact_sessions, dim_date.
-- Reads fact_events; uses only CREATE statements (no DML), so it also
-- works in BigQuery Sandbox.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE `<PROJECT_ID>.<DATASET>.build_models`()
OPTIONS(strict_mode=false)
BEGIN
  DECLARE history_start DATE;
  DECLARE history_end DATE;

  -- ----------------------------------------------------------
  -- STEP 2: views over the source, covering exactly the date range
  -- that fact_events holds (re-pointed on every run, so new days
  -- appear automatically).
  -- Views can't reference script variables, hence EXECUTE IMMEDIATE.
  -- ----------------------------------------------------------
  SET (history_start, history_end) = (
    SELECT AS STRUCT MIN(date_key), MAX(date_key) FROM `<PROJECT_ID>.<DATASET>.fact_events`
  );

  IF history_start IS NULL THEN
    RAISE USING MESSAGE = 'build_models: fact_events is empty. Load it first (see 03_backfill.sql).';
  END IF;

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE VIEW `<PROJECT_ID>.<DATASET>.fact_event_items` AS
      SELECT * FROM `<PROJECT_ID>.<DATASET>.flatten_event_items`(DATE '%t', DATE '%t')
    """, history_start, history_end);

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE VIEW `<PROJECT_ID>.<DATASET>.bridge_event_params` AS
      SELECT * FROM `<PROJECT_ID>.<DATASET>.flatten_event_params`(DATE '%t', DATE '%t')
    """, history_start, history_end);

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE VIEW `<PROJECT_ID>.<DATASET>.bridge_user_properties` AS
      SELECT * FROM `<PROJECT_ID>.<DATASET>.flatten_user_properties`(DATE '%t', DATE '%t')
    """, history_start, history_end);

  -- ----------------------------------------------------------
  -- STEP 3: dimensions — full rebuild, exactly ONE row per key
  -- ----------------------------------------------------------
  -- Attributes that are NOT part of the key hash (e.g. device language,
  -- browser_version) take their most recent value. Without this, one
  -- device_key could appear on several rows, and Power BI would reject
  -- the many-to-one relationship.
  -- Dimensions are small, so rebuilding is cheap, can never create
  -- duplicates, and keeps "latest value" attributes (incl. dim_user's
  -- LTV) current automatically.

  CREATE OR REPLACE TABLE `<PROJECT_ID>.<DATASET>.dim_device`
  OPTIONS(expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 59 DAY))
  AS
  SELECT device_key, latest.*
  FROM (
    SELECT device_key,
      ARRAY_AGG(STRUCT(device_category, mobile_brand_name, mobile_model_name, mobile_marketing_name,
                       operating_system, operating_system_version, language, is_limited_ad_tracking,
                       browser, browser_version)
                ORDER BY event_timestamp DESC LIMIT 1)[OFFSET(0)] AS latest
    FROM `<PROJECT_ID>.<DATASET>.fact_events`
    GROUP BY device_key
  );

  CREATE OR REPLACE TABLE `<PROJECT_ID>.<DATASET>.dim_geo`
  OPTIONS(expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 59 DAY))
  AS
  SELECT geo_key, latest.*
  FROM (
    SELECT geo_key,
      ARRAY_AGG(STRUCT(continent, sub_continent, country, region, city, metro)
                ORDER BY event_timestamp DESC LIMIT 1)[OFFSET(0)] AS latest
    FROM `<PROJECT_ID>.<DATASET>.fact_events`
    GROUP BY geo_key
  );

  -- All three attributes are part of the key hash, so DISTINCT is safe here.
  --
  -- first_user_default_channel_group: the export's traffic_source fields are
  -- the user's FIRST-touch source / medium / campaign, so a channel group
  -- derived from them is GA4's "First user default channel group".
  -- The export does NOT contain the channel group itself, so it is derived
  -- here, following GA4's documented rule order. The source lists are
  -- SHORTENED versions of Google's source categories, so results are an
  -- approximation — extend the regexes (or move them into a mapping table)
  -- if a client needs exact parity with the GA4 interface.
  CREATE OR REPLACE TABLE `<PROJECT_ID>.<DATASET>.dim_traffic_source`
  OPTIONS(expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 59 DAY))
  AS
  WITH base AS (
    SELECT DISTINCT traffic_source_key, traffic_medium, traffic_campaign, traffic_source,
      LOWER(IFNULL(traffic_source, '')) AS src,
      LOWER(IFNULL(traffic_medium, '')) AS med,
      LOWER(IFNULL(traffic_campaign, '')) AS cmp
    FROM `<PROJECT_ID>.<DATASET>.fact_events`
  ),
  flagged AS (
    SELECT *,
      REGEXP_CONTAINS(med, r'^(.*cp.*|ppc|retargeting|paid.*)$') AS is_paid,
      REGEXP_CONTAINS(src, r'^(google|bing|yahoo|baidu|duckduckgo|ecosia|yandex|naver|ask|aol|seznam|startpage|qwant|brave)(\.[a-z.]+)?$') AS is_search_src,
      REGEXP_CONTAINS(src, r'^((www|m|l|lm)\.)?(facebook|instagram|twitter|t|x|linkedin|lnkd|pinterest|reddit|tiktok|snapchat|whatsapp|tumblr|quora|vk|weibo|wechat)(\.[a-z.]+)?$|^(ig|fb)$') AS is_social_src,
      REGEXP_CONTAINS(src, r'^((www|m)\.)?(youtube|vimeo|twitch|dailymotion)(\.[a-z.]+)?$') AS is_video_src,
      REGEXP_CONTAINS(src, r'^((www|m)\.)?(shopify|amazon|ebay|etsy|walmart|alibaba|aliexpress|shopping\.google)(\.[a-z.]+)?$')
        OR REGEXP_CONTAINS(cmp, r'^(.*(([^a-df-z]|^)shop|shopping).*)$') AS is_shopping
    FROM base
  )
  SELECT
    traffic_source_key, traffic_medium, traffic_campaign, traffic_source,
    CASE
      WHEN src = '(direct)' AND med IN ('(not set)', '(none)', '') THEN 'Direct'
      WHEN REGEXP_CONTAINS(cmp, r'cross-network') THEN 'Cross-network'
      WHEN is_shopping AND is_paid THEN 'Paid Shopping'
      WHEN is_search_src AND is_paid THEN 'Paid Search'
      WHEN is_social_src AND is_paid THEN 'Paid Social'
      WHEN is_video_src AND is_paid THEN 'Paid Video'
      WHEN med IN ('display', 'banner', 'expandable', 'interstitial', 'cpm') THEN 'Display'
      WHEN is_paid THEN 'Paid Other'
      WHEN is_shopping THEN 'Organic Shopping'
      WHEN is_social_src OR med IN ('social', 'social-network', 'social-media', 'sm', 'social network', 'social media') THEN 'Organic Social'
      WHEN is_video_src OR REGEXP_CONTAINS(med, r'^(.*video.*)$') THEN 'Organic Video'
      WHEN is_search_src OR med = 'organic' THEN 'Organic Search'
      WHEN med IN ('referral', 'app', 'link') THEN 'Referral'
      WHEN REGEXP_CONTAINS(src, r'^(email|e-mail|e_mail|e mail)$') OR REGEXP_CONTAINS(med, r'^(email|e-mail|e_mail|e mail)$') THEN 'Email'
      WHEN med = 'affiliate' THEN 'Affiliates'
      WHEN med = 'audio' THEN 'Audio'
      WHEN src = 'sms' OR med = 'sms' THEN 'SMS'
      WHEN REGEXP_CONTAINS(med, r'push$') OR REGEXP_CONTAINS(med, r'mobile|notification') OR src = 'firebase' THEN 'Mobile Push Notifications'
      ELSE 'Unassigned'
    END AS first_user_default_channel_group
  FROM flagged;

  -- EXPECTED TO BE EMPTY for web-only properties (including the sample
  -- dataset): app_info_key is NULL on every web event. See
  -- Docs/02_transformation_pipeline.md.
  CREATE OR REPLACE TABLE `<PROJECT_ID>.<DATASET>.dim_app_info`
  OPTIONS(expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 59 DAY))
  AS
  SELECT app_info_key, latest.*
  FROM (
    SELECT app_info_key,
      ARRAY_AGG(STRUCT(app_id, app_version, install_store, firebase_app_id, install_source)
                ORDER BY event_timestamp DESC LIMIT 1)[OFFSET(0)] AS latest
    FROM `<PROJECT_ID>.<DATASET>.fact_events`
    WHERE app_info_key IS NOT NULL
    GROUP BY app_info_key
  );

  -- One row per item_id, using the item's most recent name/brand/category.
  -- Reads flatten_event_items directly, over the same date range as
  -- fact_events (so it doesn't depend on the fact_event_items view).
  -- This is the most expensive dimension on big ecommerce sites; with
  -- billing enabled, materialize fact_event_items as a partitioned table first.
  CREATE OR REPLACE TABLE `<PROJECT_ID>.<DATASET>.dim_item`
  OPTIONS(expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 59 DAY))
  AS
  SELECT item_key, latest.*
  FROM (
    SELECT item_id AS item_key,
      ARRAY_AGG(STRUCT(item_name, item_brand, item_variant,
                       item_category, item_category2, item_category3, item_category4, item_category5)
                ORDER BY event_timestamp DESC LIMIT 1)[OFFSET(0)] AS latest
    FROM `<PROJECT_ID>.<DATASET>.flatten_event_items`(history_start, history_end)
    WHERE item_id IS NOT NULL
    GROUP BY item_id
  );

  -- dim_user: LTV and last_seen_date change as users return, so this is
  -- recomputed from fact_events every run (latest LTV per user).
  -- first_seen_date / last_seen_date reflect LOADED history only.
  CREATE OR REPLACE TABLE `<PROJECT_ID>.<DATASET>.dim_user`
  OPTIONS(expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 59 DAY))
  AS
  SELECT
    user_key,
    ARRAY_AGG(user_id IGNORE NULLS ORDER BY event_timestamp DESC LIMIT 1)[SAFE_OFFSET(0)] AS user_id,
    MIN(TIMESTAMP_MICROS(user_first_touch_timestamp)) AS first_touch_timestamp,
    MIN(date_key) AS first_seen_date,
    MAX(date_key) AS last_seen_date,
    ARRAY_AGG(user_ltv_revenue ORDER BY event_timestamp DESC LIMIT 1)[OFFSET(0)] AS user_ltv_revenue,
    ARRAY_AGG(user_ltv_currency ORDER BY event_timestamp DESC LIMIT 1)[OFFSET(0)] AS user_ltv_currency
  FROM `<PROJECT_ID>.<DATASET>.fact_events`
  WHERE user_key IS NOT NULL
  GROUP BY user_key;

  -- ----------------------------------------------------------
  -- STEP 4: fact_sessions — derived session-grain VIEW over ALL of
  -- fact_events, so a session that spans midnight is grouped as one
  -- session (date_key = the day it started).
  -- If you ever materialize this as a physical table with incremental
  -- loads, rebuild every session that has ANY event in the window
  -- (the lookback in run_daily_refresh covers this) — never just
  -- sessions that START in the window, or midnight-spanning sessions
  -- get split.
  -- ----------------------------------------------------------
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

  -- ----------------------------------------------------------
  -- STEP 5: dim_date — calendar through the end of NEXT year, so it
  -- never runs out before the data does. Mark as the Date Table in
  -- Power BI (Modeling → Mark as Date Table).
  -- ----------------------------------------------------------
  CREATE OR REPLACE TABLE `<PROJECT_ID>.<DATASET>.dim_date`
  OPTIONS(expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 59 DAY))
  AS
  SELECT
    d AS date_key, EXTRACT(YEAR FROM d) AS year, EXTRACT(QUARTER FROM d) AS quarter,
    EXTRACT(MONTH FROM d) AS month, FORMAT_DATE('%B', d) AS month_name,
    EXTRACT(DAY FROM d) AS day, FORMAT_DATE('%A', d) AS day_name,
    EXTRACT(DAYOFWEEK FROM d) IN (1,7) AS is_weekend
  FROM UNNEST(GENERATE_DATE_ARRAY(
    DATE '2020-01-01',
    DATE(EXTRACT(YEAR FROM CURRENT_DATE()) + 1, 12, 31)
  )) AS d;
END;

-- ------------------------------------------------------------
-- refresh_pipeline: the whole build, in order. Needs billing (DML).
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE `<PROJECT_ID>.<DATASET>.refresh_pipeline`(start_date DATE, end_date DATE)
OPTIONS(strict_mode=false)
BEGIN
  CALL `<PROJECT_ID>.<DATASET>.load_fact_events`(start_date, end_date);
  CALL `<PROJECT_ID>.<DATASET>.build_models`();
END;

-- ------------------------------------------------------------
-- run_daily_refresh: what the scheduled query calls.
--   property_timezone — the GA4 property's reporting time zone, as an
--       IANA name, e.g. 'America/Los_Angeles' or 'Europe/Berlin'
--       (GA4: Admin → Property settings → Reporting time zone).
--       GA4 names each events_YYYYMMDD table by the property's local
--       date, so "yesterday" must be computed in THAT zone, not UTC.
--   lookback_days — how many complete days to reprocess each run.
--       3 is a sensible default: GA4 can keep updating a daily table
--       for a couple of days after the day ends (late-arriving events;
--       confirm the current window in Google's GA4 export docs), and
--       a lookback also self-heals if a day's export was late or a
--       run failed.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE `<PROJECT_ID>.<DATASET>.run_daily_refresh`(property_timezone STRING, lookback_days INT64)
OPTIONS(strict_mode=false)
BEGIN
  DECLARE today_local DATE DEFAULT CURRENT_DATE(property_timezone);

  CALL `<PROJECT_ID>.<DATASET>.refresh_pipeline`(
    DATE_SUB(today_local, INTERVAL lookback_days DAY),
    DATE_SUB(today_local, INTERVAL 1 DAY)
  );
END;
