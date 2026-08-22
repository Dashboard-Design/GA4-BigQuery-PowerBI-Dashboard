# GA4 → BigQuery → Power BI: Marketing Analytics Dashboard

A free, fully documented Power BI dashboard built on GA4 export data —
covering the entire pipeline, not just the report.

![dashboard preview](Assets/screenshots/overview.png)

## What this is
- A working Power BI report built on Google's public GA4 sample dataset
- The full data pipeline: GA4 → BigQuery export → transformation → Power BI
- Setup docs for every stage, including the part most guides skip:
  scheduling the pipeline to refresh on its own

## Architecture
GA4 property → BigQuery export (free, native) → scheduled transformation
→ Power BI semantic model (Import mode) → dashboard
*(see Docs/semantic-model-diagram.png)*

## Get started
1. [Link GA4 to BigQuery](Docs/01_link_ga4_to_bigquery.md)
2. [Run the transformation pipeline](Docs/02_transformation_pipeline.md)
3. [Connect Power BI](Docs/03_connect_powerbi.md)

## Built with
Power BI · BigQuery · SQL

## More from Dashboard-Design
[Power-BI-Design-Files](link) · [Power-BI-UDF-Library](link)

---
Want a more advanced version with anomaly detection and cohort analysis?
Check out the premium version on [BIBB](https://bibb.pro).
