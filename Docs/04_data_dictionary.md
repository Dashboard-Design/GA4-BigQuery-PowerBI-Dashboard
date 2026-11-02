# 4. Data Dictionary — GA4 Marketing Dashboard semantic model

Star schema built on the GA4 BigQuery export, loaded into Power BI in **Import** mode.

**New here?** Read **§0** first: it explains in plain English what each table is for, with one worked example. **§8** explains why `fact_events` has so many columns.

**How to read this**
- **Type** column = BigQuery type (Power BI maps it: STRING → Text, INT64 → Whole number, FLOAT64 → Decimal, DATE → Date, BOOL → True/False).
- **Key**: `PK` primary key, `FK` foreign key (the column that carries a relationship), `—` none.
- Status legend for relationships: ✅ confirmed in the model · ⏳ defined but blocked/pending · 🔍 defined in the design, not re-checked (see §7 to verify).
- §6 lists where the **loaded Power BI model differs from the repo SQL**. Read it before trusting column counts.

---

## 0. Start here — the business picture

### 0.1 Facts record what happened, dimensions describe it

- A **fact table** is a log. One row is added every time something happens (a click, a visit, a product line in an order). You **count and sum** facts.
- A **dimension table** is a lookup list. One row per *thing* (a day, a device type, a country, a product). You **slice and filter** by dimensions.

| Question in plain English | Dimension that answers it |
|---|---|
| **When** did it happen? | `dim_date` |
| **Who** did it (an anonymous visitor)? | `dim_user` |
| On **what device**? | `dim_device` |
| **Where** in the world? | `dim_geo` |
| **How did they first find us** (Google, direct, a campaign)? | `dim_traffic_source` |
| Which **product**? | `dim_item` |
| Which **mobile app** version (apps only)? | `dim_app_info` |

### 0.2 The three fact tables, explained with one visit

The three fact tables are **the same activity seen at three levels of detail**: what the visitor *did* (events), the *visit* as a whole (session), and the *products* involved (items).

**The visit:** user `U1`, on a mobile phone, arrives from google / organic on 5 Jan 2021, browses, puts a T-shirt and 2 mugs in the basket, and buys them (order T-1001, $50).

**`fact_events` — one row per thing the visitor did (6 rows here)**

| # | Time | `event_name` | What happened | `purchase_revenue_in_usd` |
|---|---|---|---|---|
| 1 | 10:00:00 | `session_start` | the visit begins | — |
| 2 | 10:00:01 | `page_view` | opened the store page | — |
| 3 | 10:01:20 | `view_item` | looked at the Google Tee | — |
| 4 | 10:02:05 | `add_to_cart` | added 1 Google Tee | — |
| 5 | 10:03:30 | `add_to_cart` | added 2 Mugs | — |
| 6 | 10:05:10 | `purchase` | paid for order T-1001 | **50.00** |

**`fact_event_items` — one row per product inside an ecommerce event (5 rows here)**

| Event | `item_name` | `quantity` | `price_in_usd` | `item_revenue_in_usd` |
|---|---|---|---|---|
| `view_item` | Google Tee | 1 | 20 | — |
| `add_to_cart` | Google Tee | 1 | 20 | — |
| `add_to_cart` | Mug | 2 | 15 | — |
| `purchase` | Google Tee | 1 | 20 | 20 |
| `purchase` | Mug | 2 | 15 | 30 |

**`fact_sessions` — one row for the whole visit (1 row here)**

| `user_key` | `session_id` | `date_key` | `event_count` | `session_duration_seconds` | `is_engaged` | `has_purchase` | `session_revenue_usd` | `entrance_page` |
|---|---|---|---|---|---|---|---|---|
| U1 | 1609840800 | 2021-01-05 | 6 | 310 | true | true | 50.00 | /store |

**What the model reports for this single visit**

| Measure | Value | Where it comes from |
|---|---|---|
| Total users | 1 | distinct `user_key` in `fact_events` |
| Sessions | 1 | rows in `fact_sessions` |
| Ecommerce purchases | 1 | `fact_events` rows named `purchase` (row 6) |
| Purchase revenue | $50 | sum of `purchase_revenue_in_usd` (only row 6 has a value) |
| ECVR | 100% | 1 purchase ÷ 1 session |
| Best-selling product | Mug $30, Tee $20 | only `fact_event_items` knows products |

**Why three tables and not one?**
- **Items are a different grain.** If you attached the 2 item rows to the purchase event, that single purchase would become 2 rows: *Ecommerce purchases = 2* and *Purchase revenue = $100*. Keeping items in their own table prevents this double counting. For the same reason the facts are **not** related to each other, only to shared dimensions.
- **Sessions are not in the GA4 export.** GA4 only stores events, so the session table is built once by grouping events on `(user_key, session_id)`. That gives cheap, correct *Sessions*, *Engagement rate* and *Session duration* instead of expensive distinct counts in every measure.

### 0.3 Which table answers which question

| Business question | Table | Measure / column |
|---|---|---|
| How many people visited? | `fact_events` | `Total users` |
| How many of them are new? | `fact_events` | `New users` |
| How many visits were there? | `fact_sessions` | `Sessions` |
| Are visits engaging? How long do they last? | `fact_sessions` | `Engagement rate`, `session_duration_seconds` |
| Which page do visits start on? | `fact_sessions` | `entrance_page` |
| How many orders, and how much revenue? | `fact_events` | `Ecommerce purchases`, `Purchase revenue` |
| What share of visits end in a purchase? | `fact_events` + `fact_sessions` | `ECVR` = purchases ÷ sessions |
| Where do people drop off (view → cart → buy)? | `fact_events` | count rows by `event_name` |
| Which products sell, and in what quantity? | `fact_event_items` (+ `dim_item`) | `quantity`, `item_revenue_in_usd` |
| Which source, device or country is better? | any fact | slice by `dim_traffic_source`, `dim_device`, `dim_geo` |
| Did it go up or down vs before? | measures | `… (Comparison)` and `… Change %` |

### 0.4 Key terms

| Term | Meaning in this model |
|---|---|
| **Event** | One recorded interaction (page view, add to cart, purchase…). |
| **User** | An anonymous browser/device id (`user_pseudo_id`), **not a person**. The same person on a phone and a laptop counts as 2 users. |
| **New user** | A user whose first-ever event was recorded (`first_visit` / `first_open`). |
| **Session** | One visit: the events of one user between arriving and leaving. GA4 ends a session after 30 minutes of inactivity by default. |
| **Engaged session** | A session that lasted 10 seconds or more, had a conversion, or had at least 2 page/screen views (GA4's definition). |
| **ECVR** | Ecommerce conversion rate in this model: purchases ÷ sessions. |
| **First-touch source** | How the user was *first* acquired. It stays with the user for life; it is **not** the source of the current visit. |
| **Previous period** | The same number of days immediately before the selected date range. |
| **Grain** | What one row of a table means (e.g. "one event"). Never mix grains in one table. |

---

## 1. Model at a glance

| Table | Role | Grain (one row per…) | Primary key | What it is for (business purpose) | Built from (BigQuery) |
|---|---|---|---|---|---|
| `fact_events` | **Fact** | GA4 event | `event_id` | The activity log: users, purchases, revenue, funnels | `flatten_events` → physical table |
| `fact_sessions` | **Fact** | session | `user_key` + `session_id` (composite) | Visits: sessions, engagement, duration, landing pages | view over `fact_events` |
| `fact_event_items` | **Fact** | item line within an event | none guaranteed (`event_id` + `item_id` identifies a line) | Products inside ecommerce events: what is viewed, carted, sold | view over `flatten_event_items` |
| `dim_date` | **Dimension** | calendar day | `date_key` | Filter and group by day, week, month; compare periods | generated calendar; marked as the model's Date table |
| `dim_device` | **Dimension** | device combination | `device_key` | Desktop vs mobile vs tablet, browser, OS | rebuilt from `fact_events` |
| `dim_geo` | **Dimension** | continent/country/region/city combination | `geo_key` | Where visitors are | rebuilt from `fact_events` |
| `dim_traffic_source` | **Dimension** | first-touch source/medium/campaign combination | `traffic_source_key` | How users first found the site (and channel group) | rebuilt from `fact_events` |
| `dim_app_info` | **Dimension** | app id + version | `app_info_key` | Mobile app versions (apps only) | rebuilt from `fact_events` (empty for web-only data) |
| `dim_item` | **Dimension** | product | `item_key` | Product catalogue: name, brand, category | rebuilt from `flatten_event_items` |
| `dim_user` | **Dimension** | user (device/browser id) | `user_key` | First/last seen, lifetime value per user | rebuilt from `fact_events` |
| `KPI Selector` | Parameter (disconnected) | selectable KPI | `KPI Selector Order` | Lets the report user pick which KPI the page shows | calculated table (field parameter) |
| `#_Measures_` | Measure container | — (no columns) | — | Holds every DAX measure in one place | DAX measures only |

Sample data loaded: **1 Nov 2020 – 31 Jan 2021**; at last check `fact_events` had 4,295,584 rows and `fact_sessions` 360,129 rows.

Not loaded into Power BI (kept in BigQuery only, on purpose — millions of rows): `bridge_event_params` (one row per event parameter) and `bridge_user_properties` (one row per user property).

---

## 2. Relationships

All relationships: **many-to-one (fact → dimension), single-direction filtering**, active.

| # | From (many) | To (one) | Status |
|---|---|---|---|
| 1 | `fact_events[date_key]` | `dim_date[date_key]` | ✅ |
| 2 | `fact_sessions[date_key]` | `dim_date[date_key]` | ✅ |
| 3 | `fact_event_items[date_key]` | `dim_date[date_key]` | ⏳ column missing until the table is re-imported (§6) |
| 4 | `fact_events[traffic_source_key]` | `dim_traffic_source[traffic_source_key]` | ✅ |
| 5 | `fact_sessions[traffic_source_key]` | `dim_traffic_source[traffic_source_key]` | ✅ |
| 6 | `fact_events[device_key]` | `dim_device[device_key]` | ⏳ blocked: loaded `dim_device` has duplicate keys until refreshed |
| 7 | `fact_sessions[device_key]` | `dim_device[device_key]` | ⏳ same |
| 8 | `fact_events[geo_key]` | `dim_geo[geo_key]` | ⏳ blocked: loaded `dim_geo` has duplicate keys until refreshed |
| 9 | `fact_sessions[geo_key]` | `dim_geo[geo_key]` | ⏳ same |
| 10 | `fact_events[user_key]` | `dim_user[user_key]` | 🔍 |
| 11 | `fact_sessions[user_key]` | `dim_user[user_key]` | 🔍 |
| 12 | `fact_events[app_info_key]` | `dim_app_info[app_info_key]` | 🔍 (table is empty for web-only data) |
| 13 | `fact_event_items[item_id]` | `dim_item[item_key]` | 🔍 |

**Rules**
- **No relationship between the three fact tables.** They connect only through the shared dimensions. `fact_event_items[event_id]` points logically at `fact_events[event_id]`, but a fact-to-fact relationship would make filter propagation ambiguous, so it is deliberately not modelled.
- `dim_user` is not used by the User Acquisition page; relationships 10–11 are optional (they add model size, since `user_key` is high-cardinality).
- `KPI Selector` and `#_Measures_` have no relationships.

---

## 3. ERD (Mermaid)

Solid line = relationship ✅/🔍 in the design · dotted line = ⏳ pending. Only key columns and a few representative attributes are drawn; full column lists are in §4.

```mermaid
erDiagram
    dim_date ||--o{ fact_events : "date_key"
    dim_date ||--o{ fact_sessions : "date_key"
    dim_date ||..o{ fact_event_items : "date_key (pending)"

    dim_traffic_source ||--o{ fact_events : "traffic_source_key"
    dim_traffic_source ||--o{ fact_sessions : "traffic_source_key"

    dim_device ||..o{ fact_events : "device_key (pending)"
    dim_device ||..o{ fact_sessions : "device_key (pending)"

    dim_geo ||..o{ fact_events : "geo_key (pending)"
    dim_geo ||..o{ fact_sessions : "geo_key (pending)"

    dim_user ||--o{ fact_events : "user_key"
    dim_user ||--o{ fact_sessions : "user_key"

    dim_app_info ||--o{ fact_events : "app_info_key"
    dim_item ||--o{ fact_event_items : "item_id = item_key"

    fact_events {
        string event_id PK
        date date_key FK
        string user_key FK
        string device_key FK
        string geo_key FK
        string traffic_source_key FK
        string app_info_key FK
        string event_name
        int session_id
        float purchase_revenue_in_usd
    }

    fact_sessions {
        string user_key PK, FK
        int session_id PK
        date date_key FK
        string device_key FK
        string geo_key FK
        string traffic_source_key FK
        int event_count
        bool has_purchase
        float session_revenue_usd
    }

    fact_event_items {
        string event_id "logical link to fact_events, not modelled"
        date date_key FK
        string item_id FK
        string item_name
        int quantity
        float item_revenue_in_usd
    }

    dim_date {
        date date_key PK
        int year
        int quarter
        int month
        bool is_weekend
    }

    dim_traffic_source {
        string traffic_source_key PK
        string traffic_source
        string traffic_medium
        string traffic_campaign
        string first_user_default_channel_group
    }

    dim_device {
        string device_key PK
        string device_category
        string operating_system
        string browser
    }

    dim_geo {
        string geo_key PK
        string country
        string region
        string city
    }

    dim_user {
        string user_key PK
        date first_seen_date
        date last_seen_date
        float user_ltv_revenue
    }

    dim_app_info {
        string app_info_key PK
        string app_id
        string app_version
    }

    dim_item {
        string item_key PK
        string item_name
        string item_brand
        string item_category
    }
```

---

## 4. Tables and columns

### 4.1 `fact_events` — Fact · grain: one row per GA4 event · PK: `event_id`

**Business meaning.** The activity log of the website: every interaction GA4 records (page views, product views, add to cart, purchases…). With this table alone you can already answer "how many users, how many purchases, how much revenue".

**Example.** One visitor who browses and buys produces about 6 rows (see §0.2).

**Use it for:** `Total users`, `New users`, `Ecommerce purchases`, `Purchase revenue`, funnels by `event_name`.

**Watch out.** Revenue columns are filled only on purchase events (NULL elsewhere), so summing them is safe, but *counting rows* without filtering `event_name` counts **all** events, not purchases. It has 66 columns on purpose in BigQuery; see §8 before importing them all into Power BI.

The atomic table of the whole model. 66 columns (§8 explains why it is so wide and which columns Power BI really needs).

**Keys and time**

| Column | Type | Key | Description |
|---|---|---|---|
| `event_id` | STRING | PK | Unique, stable hash of user id, event name, event timestamp, bundle sequence id and a tiebreaker row number. |
| `date_key` | DATE | FK → `dim_date` | Event date in the GA4 property's reporting time zone. |
| `event_timestamp` | INT64 | — | Event time, microseconds since the Unix epoch (UTC). |
| `event_previous_timestamp` | INT64 | — | Time the user last triggered this same event, microseconds. |
| `event_name` | STRING | — | GA4 event name, e.g. `page_view`, `purchase`, `first_visit`. |
| `event_value_in_usd` | FLOAT64 | — | Event value converted to USD, if the event carried one. |
| `event_bundle_sequence_id` | INT64 | — | Sequence id of the upload bundle that delivered the event. |
| `event_server_timestamp_offset` | INT64 | — | Microseconds between client collection and server receipt. |

**User and consent**

| Column | Type | Key | Description |
|---|---|---|---|
| `user_key` | STRING | FK → `dim_user` | GA4 `user_pseudo_id`: anonymous device/browser identifier. |
| `user_id` | STRING | — | Your own User-ID, if sent. Usually NULL. |
| `user_first_touch_timestamp` | INT64 | — | Microsecond timestamp of the user's first visit. |
| `user_ltv_revenue` | FLOAT64 | — | Lifetime revenue GA4 attributes to the user (often NULL on web). |
| `user_ltv_currency` | STRING | — | Currency of `user_ltv_revenue`. |
| `analytics_storage` | STRING | — | Analytics consent state (Yes/No). |
| `ads_storage` | STRING | — | Ads consent state (Yes/No). |
| `uses_transient_token` | STRING | — | Whether a transient token was used in place of a user id. |

**Dimension keys** (MD5 hashes computed once in `flatten_events`; the attributes are hashed with a `|` separator)

| Column | Type | Key | Description |
|---|---|---|---|
| `device_key` | STRING | FK → `dim_device` | Hash of device category, brand, operating system and browser. |
| `geo_key` | STRING | FK → `dim_geo` | Hash of continent, country, region and city. |
| `traffic_source_key` | STRING | FK → `dim_traffic_source` | Hash of first-touch medium, campaign and source. |
| `app_info_key` | STRING | FK → `dim_app_info` | Hash of app id and version. NULL on web events. |

**Device attributes** (kept on the fact so dimensions can be rebuilt from it)

| Column | Type | Description |
|---|---|---|
| `device_category` | STRING | `desktop`, `mobile` or `tablet`. |
| `mobile_brand_name` | STRING | Device manufacturer. |
| `mobile_model_name` | STRING | Device model. |
| `mobile_marketing_name` | STRING | Marketing name of the device. |
| `operating_system` | STRING | OS name. |
| `operating_system_version` | STRING | OS version. |
| `language` | STRING | Device/browser language setting. |
| `is_limited_ad_tracking` | STRING | Limited ad tracking flag (Yes/No). |
| `browser` | STRING | Browser name (web). |
| `browser_version` | STRING | Browser version (web). |

**Geography**

| Column | Type | Description |
|---|---|---|
| `continent` | STRING | Continent of the user. |
| `sub_continent` | STRING | Sub-continent. |
| `country` | STRING | Country. |
| `region` | STRING | Region / state. |
| `city` | STRING | City. |
| `metro` | STRING | Metro area. |

**App and stream**

| Column | Type | Description |
|---|---|---|
| `app_id` | STRING | App package / bundle id. NULL on web. |
| `app_version` | STRING | App version. NULL on web. |
| `install_store` | STRING | Store the app was installed from. |
| `firebase_app_id` | STRING | Firebase app id. |
| `install_source` | STRING | Install source. |
| `stream_id` | STRING | GA4 data stream id. |
| `platform` | STRING | `WEB`, `IOS` or `ANDROID`. |
| `hostname` | STRING | Hostname the event was collected on. |

**Traffic source (first touch)** — in this export schema these describe how the **user was first acquired**, not the current session's source.

| Column | Type | Description |
|---|---|---|
| `traffic_source` | STRING | First-touch source, e.g. `google`, `(direct)`. |
| `traffic_medium` | STRING | First-touch medium, e.g. `organic`, `cpc`, `(none)`. |
| `traffic_campaign` | STRING | First-touch campaign name. |

**Ecommerce** (NULL on events that are not ecommerce events — expected)

| Column | Type | Description |
|---|---|---|
| `transaction_id` | STRING | Order id on `purchase` events. |
| `purchase_revenue_in_usd` | FLOAT64 | Purchase revenue in USD. Source of the **Purchase revenue** measure. |
| `purchase_revenue` | FLOAT64 | Purchase revenue in the original currency. |
| `refund_value_in_usd` | FLOAT64 | Refund value in USD. |
| `refund_value` | FLOAT64 | Refund value in the original currency. |
| `shipping_value_in_usd` | FLOAT64 | Shipping value in USD. |
| `shipping_value` | FLOAT64 | Shipping value in the original currency. |
| `tax_value_in_usd` | FLOAT64 | Tax value in USD. |
| `tax_value` | FLOAT64 | Tax value in the original currency. |
| `total_item_quantity` | INT64 | Total units across the event's items. |
| `unique_items` | INT64 | Number of distinct items in the event. |

**Page and session** (pulled out of `event_params`; the full parameter set stays in BigQuery's `bridge_event_params`)

| Column | Type | Description |
|---|---|---|
| `page_location` | STRING | Full page URL. |
| `page_title` | STRING | Page title. |
| `page_referrer` | STRING | Referrer URL. |
| `session_id` | INT64 | GA4 `ga_session_id`. Unique only **together with** `user_key`. NULL when consent is denied. |
| `session_number` | INT64 | The user's nth session. |
| `engagement_time_msec` | INT64 | Engagement time since the previous event, milliseconds. |
| `is_entrance` | INT64 | 1 on the session's landing event, otherwise NULL. |
| `session_engaged` | STRING | `'1'` when the session counts as engaged. |

---

### 4.2 `fact_sessions` — Fact · grain: one row per session · PK: `user_key` + `session_id`

**Business meaning.** One row per **visit**. It answers "how many visits, how engaging were they, how long did they last, where did they start, did they end in a purchase".

**Example.** The 6 events of user U1 on 5 Jan become one row: `event_count` 6, `session_duration_seconds` 310, `has_purchase` true, `session_revenue_usd` 50, `entrance_page` /store.

**Use it for:** `Sessions`, `Engagement rate`, the denominator of `ECVR`, landing-page analysis.

**Watch out.** `session_id` is only unique together with `user_key`. A session that runs past midnight stays one row, dated by the day it started.

Derived (GA4 has no native session table) by grouping `fact_events` on `(user_key, session_id)`. Sessions that span midnight stay as one row, dated by the day they started. 14 columns.

| Column | Type | Key | Description |
|---|---|---|---|
| `user_key` | STRING | PK (part), FK → `dim_user` | User of the session. |
| `session_id` | INT64 | PK (part) | GA4 session id. |
| `date_key` | DATE | FK → `dim_date` | Date of the session's first event. |
| `session_start_ts` | INT64 | — | First event time, microseconds. |
| `session_end_ts` | INT64 | — | Last event time, microseconds. |
| `session_duration_seconds` | INT64 | — | Last minus first event time, in seconds. |
| `event_count` | INT64 | — | Events in the session. |
| `has_purchase` | BOOL | — | True if the session contains a `purchase` event. |
| `session_revenue_usd` | FLOAT64 | — | Sum of `purchase_revenue_in_usd` in the session. |
| `is_engaged` | BOOL | — | True if any event had `session_engaged = '1'`. |
| `entrance_page` | STRING | — | `page_location` of the session's first event. |
| `device_key` | STRING | FK → `dim_device` | Device of the first event. |
| `geo_key` | STRING | FK → `dim_geo` | Location of the first event. |
| `traffic_source_key` | STRING | FK → `dim_traffic_source` | First-touch source of the first event. |

---

### 4.3 `fact_event_items` — Fact · grain: one row per item per event · PK: none guaranteed

**Business meaning.** The **products inside** ecommerce events (`view_item`, `add_to_cart`, `purchase`…). One order with 3 products is 1 row in `fact_events` and 3 rows here.

**Example.** An order of 1 Tee ($20) and 2 Mugs ($30) gives two item rows with `item_revenue_in_usd` 20 and 30.

**Use it for:** best sellers, revenue by category or brand, what gets added to cart but not bought, coupon usage.

**Watch out.** Never add `item_revenue_in_usd` to `purchase_revenue_in_usd` (same money, two grains). Only ecommerce events have item rows. It is not related to `fact_events` on purpose (§2 rules).

Only ecommerce events (`view_item`, `add_to_cart`, `purchase`, …) have rows. GA4 does not guarantee that `event_id` + `item_id` is unique.

| Column | Type | Key | Description |
|---|---|---|---|
| `event_id` | STRING | — (logical → `fact_events`) | Event this item line belongs to. Not a modelled relationship. |
| `date_key` | DATE | FK → `dim_date` | Event date. *Repo version only — see §6.* |
| `event_timestamp` | INT64 | — | Event time, microseconds. *Repo version only — see §6.* |
| `item_id` | STRING | FK → `dim_item[item_key]` | Product id. |
| `item_name` | STRING | — | Product name. |
| `item_brand` | STRING | — | Brand. |
| `item_variant` | STRING | — | Variant (size, colour…). |
| `item_category` … `item_category5` | STRING (5 columns) | — | Category hierarchy, level 1 to 5. |
| `price_in_usd` / `price` | FLOAT64 | — | Unit price in USD / original currency. |
| `quantity` | INT64 | — | Units. |
| `item_revenue_in_usd` / `item_revenue` | FLOAT64 | — | Item revenue in USD / original currency. |
| `item_refund_in_usd` / `item_refund` | FLOAT64 | — | Item refund in USD / original currency. |
| `coupon` | STRING | — | Item-level coupon. |
| `affiliation` | STRING | — | Supplier / store affiliation. |
| `location_id` | STRING | — | Location id. |
| `item_list_id` / `item_list_name` / `item_list_index` | STRING / STRING / INT64 | — | List the item was shown in, and its position. |
| `promotion_id` / `promotion_name` | STRING | — | Promotion the item was part of. |
| `creative_name` / `creative_slot` | STRING | — | Promotion creative and slot. |

---

### 4.4 `dim_date` — Dimension · grain: one row per day · PK: `date_key`

**Business meaning.** The calendar. It lets the report filter by date range, group by day/week/month, and shift dates to compare with the previous period.

**Example.** Selecting 18–31 Jan in the date slicer filters every fact through this table; the comparison measures then look at the 14 days before 18 Jan.

Marked as the model's **Date table** (required for time-intelligence functions). Covers 2020-01-01 to the end of next year.

| Column | Type | Key | Description |
|---|---|---|---|
| `date_key` | DATE | PK | The day. Used by the date slicer and the chart axis. |
| `year` | INT64 | — | Calendar year. |
| `quarter` | INT64 | — | Quarter, 1–4. |
| `month` | INT64 | — | Month number, 1–12. |
| `month_name` | STRING | — | Month name. |
| `day` | INT64 | — | Day of month. |
| `day_name` | STRING | — | Weekday name. |
| `is_weekend` | BOOL | — | True for Saturday and Sunday. |

### 4.5 `dim_device` — Dimension · grain: one row per device combination · PK: `device_key`

**Business meaning.** What kind of device the visitor used (desktop, mobile, tablet), plus OS and browser.

**Example.** The Device slicer filters the whole page to mobile only, to see whether mobile visitors convert worse than desktop.

| Column | Type | Key | Description |
|---|---|---|---|
| `device_key` | STRING | PK | Hash of category, brand, operating system and browser. |
| `device_category` | STRING | — | `desktop`, `mobile` or `tablet`. Used by the Device slicer. |
| `mobile_brand_name` | STRING | — | Manufacturer. |
| `mobile_model_name` | STRING | — | Model. |
| `mobile_marketing_name` | STRING | — | Marketing name. |
| `operating_system` | STRING | — | OS name. |
| `operating_system_version` | STRING | — | OS version. Latest value seen for the key. |
| `language` | STRING | — | Language. Latest value seen for the key. |
| `is_limited_ad_tracking` | STRING | — | Limited ad tracking flag. |
| `browser` | STRING | — | Browser name. |
| `browser_version` | STRING | — | Browser version. Latest value seen for the key. |

### 4.6 `dim_geo` — Dimension · grain: one row per location combination · PK: `geo_key`

**Business meaning.** Where in the world the visitor was (continent, country, region, city).

**Example.** The Country slicer narrows the page to one market; one row exists per country/region/city combination.

| Column | Type | Key | Description |
|---|---|---|---|
| `geo_key` | STRING | PK | Hash of continent, country, region and city. |
| `continent` | STRING | — | Continent. |
| `sub_continent` | STRING | — | Sub-continent. Latest value seen for the key. |
| `country` | STRING | — | Country. Used by the Country slicer. |
| `region` | STRING | — | Region / state. |
| `city` | STRING | — | City. |
| `metro` | STRING | — | Metro area. Latest value seen for the key. |

### 4.7 `dim_traffic_source` — Dimension · grain: one row per first-touch combination · PK: `traffic_source_key`

**Business meaning.** **How the user was first acquired** (source, medium, campaign), and the channel group they fall into (Direct, Organic Search, Paid Search…).

**Example.** `google / organic / (none)` is a user who first arrived through a Google search result. They keep this value even if they return later via an email link.

**Watch out.** This is first-touch (user level), **not** the source of the current session.

| Column | Type | Key | Description |
|---|---|---|---|
| `traffic_source_key` | STRING | PK | Hash of medium, campaign and source. |
| `traffic_medium` | STRING | — | First-touch medium. |
| `traffic_campaign` | STRING | — | First-touch campaign. |
| `traffic_source` | STRING | — | First-touch source. Row field of the traffic-source table and bar charts. |
| `first_user_default_channel_group` | STRING | — | GA4-style default channel group (Direct, Organic Search, Paid Search, Referral, Email, Organic Social, …) derived in SQL from source/medium/campaign. An approximation of Google's rules. *Repo version only — see §6.* |

### 4.8 `dim_app_info` — Dimension · grain: one row per app id + version · PK: `app_info_key`

**Business meaning.** Which mobile app (and version) generated the event. Only used by app properties.

**Example.** `com.example.shop` version 3.2. For a website-only property the table is empty by design.

**Empty for web-only data** (including the sample dataset): `app_info_key` is NULL on every web event. It fills automatically for app properties.

| Column | Type | Key | Description |
|---|---|---|---|
| `app_info_key` | STRING | PK | Hash of app id and version. |
| `app_id` | STRING | — | App package / bundle id. |
| `app_version` | STRING | — | App version. |
| `install_store` | STRING | — | Install store. |
| `firebase_app_id` | STRING | — | Firebase app id. |
| `install_source` | STRING | — | Install source. |

### 4.9 `dim_item` — Dimension · grain: one row per product · PK: `item_key`

**Business meaning.** The product catalogue as seen in the events: one row per product with its latest name, brand, variant and category path.

**Example.** `item_key` GGOEAAAA… → "Google Tee Black", brand Google, category Apparel / Men's.

| Column | Type | Key | Description |
|---|---|---|---|
| `item_key` | STRING | PK | The product's `item_id`. |
| `item_name` | STRING | — | Name (most recent value seen). |
| `item_brand` | STRING | — | Brand (most recent). |
| `item_variant` | STRING | — | Variant (most recent). |
| `item_category` … `item_category5` | STRING (5 columns) | — | Category hierarchy, level 1 to 5 (most recent). |

### 4.10 `dim_user` — Dimension · grain: one row per user · PK: `user_key`

**Business meaning.** One row per anonymous visitor (browser/device), with the first and last day seen and the lifetime value GA4 reports.

**Example.** A user first seen on 3 Nov and last seen on 20 Jan is a returning user; one seen on a single day never came back.

**Watch out.** A user is a device, not a person. It is not used by the User Acquisition page, so its relationships are optional.

Recomputed on every refresh, so lifetime value and last-seen date are always current.

| Column | Type | Key | Description |
|---|---|---|---|
| `user_key` | STRING | PK | GA4 `user_pseudo_id`. |
| `user_id` | STRING | — | Your User-ID if sent (latest non-null). Usually NULL. |
| `first_touch_timestamp` | TIMESTAMP | — | Earliest `user_first_touch_timestamp` seen. |
| `first_seen_date` | DATE | — | First day in the **loaded** history (not before the export started). |
| `last_seen_date` | DATE | — | Last day in the loaded history. |
| `user_ltv_revenue` | FLOAT64 | — | Latest lifetime value reported. |
| `user_ltv_currency` | STRING | — | Currency of the lifetime value. |

### 4.11 `KPI Selector` — Parameter table (disconnected) · PK: `KPI Selector Order`

**Business meaning.** A small helper table behind the KPI buttons at the top of the page. It stores *which KPIs exist*, not data.

**Example.** Clicking the "ECVR" card selects order 3, and measures such as `KPI Value` switch to the ECVR formula, so the line chart and tables follow the click.

A **field parameter**: it powers the KPI button slicer and the line chart. 5 rows, no relationships.

| Column | Type | Key | Description |
|---|---|---|---|
| `KPI Selector` | Text | — | KPI display name (Total users, New users, Ecommerce purchases, ECVR, Purchase revenue). |
| `KPI Selector Fields` | Text | — | Internal reference to the measure the row stands for. |
| `KPI Selector Order` | Whole number | PK | 0–4. Measures such as `KPI Value` switch on this number. |

### 4.12 `#_Measures_` — Measure container

**Business meaning.** A tidy home for all measures, so they do not sit scattered across data tables. It has no data of its own.

No columns and no data; it only holds measures (§5).

---

## 5. Measures (in `#_Measures_`)

**Base KPIs** — these respond to every filter on the page, including the date slicer.

| Measure | Definition |
|---|---|
| `Total users` | Distinct `fact_events[user_key]`. |
| `New users` | Distinct users with a `first_visit` or `first_open` event. |
| `Sessions` | Rows of `fact_sessions`. |
| `Ecommerce purchases` | Count of events named `purchase`. |
| `Purchase revenue` | Sum of `fact_events[purchase_revenue_in_usd]`. |
| `ECVR` | `Ecommerce purchases` ÷ `Sessions`. |
| `% of Users`, `% New Users`, `% Revenue` | Share of the total across the rows shown (traffic sources). |

**Period comparison** — the comparison is the **same number of days immediately before** the date-slicer range.

| Measure | Definition |
|---|---|
| `First Data Date` | First day with data, ignoring all filters. |
| `Period Start` / `Period End` | First / last day selected in the date slicer (readable even inside the daily axis). |
| `Period Days` | Number of days in the selected range. |
| `Comparison Start` / `Comparison End` | The previous window: `Period Start − Period Days` to `Period Start − 1`. |
| `Comparison Caption` | Text "vs. previous period". |
| `Period Range Label`, `Comparison Range Label` | The two date ranges as readable text. |
| `… (Comparison)` ×5 | The KPI over the previous window (one each for Total users, New users, Ecommerce purchases, ECVR, Purchase revenue). Blank if that window starts before `First Data Date`. |
| `… Change %` ×5 | (current − previous) ÷ previous, with ▲/▼ formatting. |

**KPI selector layer** — switch on `KPI Selector` so one set of visuals serves all five KPIs.

| Measure | Definition |
|---|---|
| `KPI Value` | Selected KPI, current period. |
| `KPI Comparison`, `KPI Comparison Value` | Selected KPI, previous period (two equivalent measures). |
| `KPI Delta` | Selected KPI's `Change %`. |
| `KPI Share of Total` | Selected KPI's share across traffic sources (blank for ECVR). |
| `KPI Chart Title`, `KPI Table Title`, `KPI Table Subtitle` | Dynamic titles. |
| `KPI Card SVG`, `KPI Card SVG Selected` | KPI card images (normal / selected state). |
| `KPI Target Bar`, `KPI Target Line Bar SVG` | Bar-with-target-line images for the table: bar = current, dashed line = previous period. |
| `</> Slicer Filter` | Helper for the slicer styling. |

---

## 6. Where the loaded model differs from the repo SQL

| Object | Loaded Power BI model | Repo SQL | Fix |
|---|---|---|---|
| `fact_event_items` | 27 columns, **no** `date_key` / `event_timestamp` | 29 columns | Refresh/re-import the table; then add relationship 3. Until then items can't be filtered by date. |
| `dim_traffic_source` | 4 columns, **no** `first_user_default_channel_group` | 5 columns | Refresh/re-import after running `CALL build_models()` in BigQuery. |
| `dim_device`, `dim_geo` | Old copies with **duplicate keys** (3,497 rows for 119 keys; 986 rows for 977 keys at last check) | One row per key | Refresh in Desktop (Home → Refresh); then create relationships 6–9. |

---

## 7. Verify against the live model

Paste into Power BI Desktop → **DAX query view** (one at a time). These return what is *actually* in your file and settle every 🔍 above.

```dax
EVALUATE INFO.VIEW.TABLES()
```

```dax
EVALUATE INFO.VIEW.COLUMNS()
```

```dax
EVALUATE INFO.VIEW.RELATIONSHIPS()
```

```dax
EVALUATE INFO.VIEW.MEASURES()
```

Quick key-quality check (rows should equal distinct keys; a difference means the relationship cannot be created):

```dax
EVALUATE
ROW (
    "dim_device rows", COUNTROWS ( dim_device ),
    "dim_device keys", DISTINCTCOUNT ( dim_device[device_key] ),
    "dim_geo rows", COUNTROWS ( dim_geo ),
    "dim_geo keys", DISTINCTCOUNT ( dim_geo[geo_key] )
)
```

---

## 8. Design note: why `fact_events` has 66 columns

**Short answer.** `fact_events` is the *flattened GA4 event log*. Besides the event itself it carries (a) the keys to every dimension, (b) a **copy of the descriptive attributes of those dimensions**, and (c) the ecommerce, page and user fields that sit on each event. The dimension tables are rebuilt *from* these copies, which is why device, geo, app and traffic-source attributes are repeated on the fact.

**Is that appropriate?** It depends on the layer.

| Layer | Wide fact table? | Why |
|---|---|---|
| **BigQuery** (warehouse) | Fine, and normal | BigQuery is columnar: a query reads only the columns it names, so unused columns cost nothing. One wide event table is the usual way to model GA4. |
| **Power BI** (semantic model, Import mode) | **Not ideal** | Every imported column is stored, compressed and refreshed. Text columns with many distinct values (`event_id`, `page_location`, `page_referrer`, `transaction_id`, `user_key`) are the most expensive. A lean fact means a smaller file, faster refresh and a cleaner field list. |

There is also a usability risk: `fact_events[country]` sits next to `dim_geo[country]`. A slicer built on the fact copy filters only `fact_events`, not `fact_sessions`, and gives misleading numbers. The rule is: **always slice by the dimension table, never by the copy on the fact.**

So the instinct "fact tables should be lean in columns" is right **for the Power BI model**. The 66 columns are best kept in BigQuery and only a subset imported.

**The 66 columns by group, and what to import**

| Group | Columns | Examples | Import into Power BI? |
|---|---|---|---|
| Keys | 7 | `event_id`, `date_key`, `user_key`, `device_key`, `geo_key`, `traffic_source_key`, `app_info_key` | Keep `date_key`, `user_key`, `device_key`, `geo_key`, `traffic_source_key`. Drop `event_id` (millions of unique strings, not used by any measure) and `app_info_key` for web-only data. |
| Event and timing | 6 | `event_name`, `event_timestamp`, `event_value_in_usd`, `event_bundle_sequence_id` | Keep `event_name`. The rest only when a page needs them. |
| Ecommerce | 11 | `purchase_revenue_in_usd`, `transaction_id`, refund / shipping / tax values | Keep `purchase_revenue_in_usd`. Add the others when you build the Ecommerce page. |
| Page and session | 8 | `page_location`, `session_number`, `engagement_time_msec`, `session_engaged` | Add when you build Pages & Screens or Engagement pages. |
| **Copies of dimension attributes** | **24** (device 10, geo 6, app 5, traffic source 3) | `device_category`, `country`, `traffic_source`… | **Drop.** Use the dimension tables. |
| User and consent | 7 | `user_id`, `user_ltv_*`, consent flags | Drop (lifetime value is already in `dim_user`). |
| Stream and platform | 3 | `stream_id`, `platform`, `hostname` | Optional; `platform` / `hostname` help when one property has several sites. |

**What the current User Acquisition page actually uses from `fact_events`:** `date_key`, `user_key`, `event_name`, `purchase_revenue_in_usd`, plus `device_key`, `geo_key` and `traffic_source_key` for the relationships. A starter lean fact is therefore about **7 columns** instead of 66.

**How to slim it down (pick one)**
1. **In Power BI:** Power Query → *Choose Columns* on `fact_events`. Hiding columns is not enough, because hidden columns are still loaded.
2. **In BigQuery:** create a lean view and import that instead (keep the wide table for analysis and for rebuilding the dimensions):

```sql
CREATE OR REPLACE VIEW `<PROJECT_ID>.<DATASET>.fact_events_pbi` AS
SELECT
  date_key, event_name, user_key,
  device_key, geo_key, traffic_source_key,
  purchase_revenue_in_usd, transaction_id,
  engagement_time_msec, session_number
FROM `<PROJECT_ID>.<DATASET>.fact_events`;
```

**To measure the saving** before and after, use VertiPaq Analyzer (DAX Studio → *Advanced → View Metrics*). It lists the size of every column.

The same idea applies, on a smaller scale, to `fact_event_items`: its product name, brand, variant and five category columns also exist in `dim_item`, so a lean version would keep only `item_id`, `date_key`, `quantity` and the price/revenue columns.
