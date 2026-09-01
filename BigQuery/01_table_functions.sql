-- ============================================================
-- GA4 → Power BI: Table Functions
-- ============================================================
-- These are BigQuery Table Functions — parameterized views that hold
-- ALL transformation logic in one place. To adapt this pipeline to a
-- real client's GA4 export, change ONLY the FROM line in each function
-- (swap `bigquery-public-data.ga4_obfuscated_sample_ecommerce` for
-- their `project.analytics_XXXXXXX` dataset). Nothing else needs to
-- change — every downstream table calls these functions by name.
--
-- Replace <PROJECT_ID> and <DATASET> below with your own values.
-- ============================================================

-- ------------------------------------------------------------
-- flatten_events: one row per event.
-- Normalizes device/geo/traffic_source/app_info into pre-computed
-- hash keys (device_key, geo_key, traffic_source_key, app_info_key)
-- so downstream fact/dimension tables share one identical key
-- formula. Raw attribute columns are also kept, so dimension
-- tables can be built directly from this function's output.
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE FUNCTION `<PROJECT_ID>.<DATASET>.flatten_events`(start_date DATE, end_date DATE)
AS (
  SELECT
    TO_HEX(MD5(CONCAT(user_pseudo_id, CAST(event_timestamp AS STRING), CAST(event_bundle_sequence_id AS STRING)))) AS event_id,
    PARSE_DATE('%Y%m%d', event_date) AS date_key,
    event_timestamp, event_name, event_previous_timestamp,
    event_value_in_usd, event_bundle_sequence_id, event_server_timestamp_offset,
    user_id, user_pseudo_id AS user_key, user_first_touch_timestamp,
    user_ltv.revenue AS user_ltv_revenue, user_ltv.currency AS user_ltv_currency,
    privacy_info.analytics_storage, privacy_info.ads_storage, privacy_info.uses_transient_token,

    -- normalized dimension keys — formula must stay identical wherever reused
    TO_HEX(MD5(CONCAT(IFNULL(device.category,''), IFNULL(device.mobile_brand_name,''), IFNULL(device.operating_system,''), IFNULL(device.web_info.browser,'')))) AS device_key,
    TO_HEX(MD5(CONCAT(IFNULL(geo.continent,''), IFNULL(geo.country,''), IFNULL(geo.region,''), IFNULL(geo.city,'')))) AS geo_key,
    TO_HEX(MD5(CONCAT(IFNULL(traffic_source.medium,''), IFNULL(traffic_source.name,''), IFNULL(traffic_source.source,'')))) AS traffic_source_key,
    IF(app_info.id IS NOT NULL, TO_HEX(MD5(CONCAT(IFNULL(app_info.id,''), IFNULL(app_info.version,'')))), NULL) AS app_info_key,

    -- raw attributes — kept so dim_* tables can be built straight from this function
    device.category AS device_category, device.mobile_brand_name, device.mobile_model_name, device.mobile_marketing_name,
    device.operating_system, device.operating_system_version, device.language, device.is_limited_ad_tracking,
    device.web_info.browser, device.web_info.browser_version,
    geo.continent, geo.sub_continent, geo.country, geo.region, geo.city, geo.metro,
    app_info.id AS app_id, app_info.version AS app_version, app_info.install_store, app_info.firebase_app_id, app_info.install_source,
    traffic_source.medium AS traffic_medium, traffic_source.name AS traffic_campaign, traffic_source.source AS traffic_source,
    stream_id, platform, event_dimensions.hostname,

    -- ecommerce (null on non-purchase events — expected, not an error)
    ecommerce.total_item_quantity, ecommerce.purchase_revenue_in_usd, ecommerce.purchase_revenue,
    ecommerce.refund_value_in_usd, ecommerce.refund_value, ecommerce.shipping_value_in_usd,
    ecommerce.shipping_value, ecommerce.tax_value_in_usd, ecommerce.tax_value,
    ecommerce.unique_items, ecommerce.transaction_id,

    -- near-universal event_params, pulled out for direct use.
    -- bridge_event_params (below) still captures 100% of params, including these.
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location') AS page_location,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_title') AS page_title,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_referrer') AS page_referrer,
    (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS session_id,
    (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_number') AS session_number,
    (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'engagement_time_msec') AS engagement_time_msec,
    (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'entrances') AS is_entrance,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'session_engaged') AS session_engaged

  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', start_date) AND FORMAT_DATE('%Y%m%d', end_date)
);

-- ------------------------------------------------------------
-- flatten_event_items: one row per item per event.
-- Kept as a separate grain from flatten_events on purpose — see
-- Docs/02_data_modeling.md for why merging event + item grain
-- causes double-counting on session/event-level measures.
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE FUNCTION `<PROJECT_ID>.<DATASET>.flatten_event_items`(start_date DATE, end_date DATE)
AS (
  SELECT
    TO_HEX(MD5(CONCAT(user_pseudo_id, CAST(event_timestamp AS STRING), CAST(event_bundle_sequence_id AS STRING)))) AS event_id,
    item.item_id, item.item_name, item.item_brand, item.item_variant,
    item.item_category, item.item_category2, item.item_category3, item.item_category4, item.item_category5,
    item.price_in_usd, item.price, item.quantity,
    item.item_revenue_in_usd, item.item_revenue, item.item_refund_in_usd, item.item_refund,
    item.coupon, item.affiliation, item.location_id,
    item.item_list_id, item.item_list_name, item.item_list_index,
    item.promotion_id, item.promotion_name, item.creative_name, item.creative_slot
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`, UNNEST(items) AS item
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', start_date) AND FORMAT_DATE('%Y%m%d', end_date)
);

-- ------------------------------------------------------------
-- flatten_event_params: every event_params key/value, no exceptions.
-- This is what guarantees full schema capture — GA4 lets each event
-- carry custom parameters that differ per implementation, so this
-- generic bridge is what stays complete for ANY future client,
-- rather than betting on a fixed list of param names.
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE FUNCTION `<PROJECT_ID>.<DATASET>.flatten_event_params`(start_date DATE, end_date DATE)
AS (
  SELECT
    TO_HEX(MD5(CONCAT(user_pseudo_id, CAST(event_timestamp AS STRING), CAST(event_bundle_sequence_id AS STRING)))) AS event_id,
    ep.key AS param_key, ep.value.string_value, ep.value.int_value, ep.value.float_value, ep.value.double_value
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`, UNNEST(event_params) AS ep
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', start_date) AND FORMAT_DATE('%Y%m%d', end_date)
);

-- ------------------------------------------------------------
-- flatten_user_properties: same bridge pattern, for user_properties.
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE FUNCTION `<PROJECT_ID>.<DATASET>.flatten_user_properties`(start_date DATE, end_date DATE)
AS (
  SELECT
    user_pseudo_id AS user_key,
    up.key AS property_key, up.value.string_value, up.value.int_value, up.value.float_value,
    up.value.double_value, up.value.set_timestamp_micros
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`, UNNEST(user_properties) AS up
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', start_date) AND FORMAT_DATE('%Y%m%d', end_date)
);
