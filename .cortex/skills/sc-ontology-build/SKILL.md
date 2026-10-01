---
name: sc-ontology-build
description: Build, validate and deploy the supply chain ontology hackathon project (raw data, conformed layer, semantic view, security, demo views, Streamlit app) into the SC_ONTOLOGY database. Use when asked to build, rebuild, verify, fix or deploy this project, or to run a single step of it.
---

# Supply chain ontology: build and deploy

This project lives in the current folder. Scripts must run in this order:

| Step | File | Role | What it does |
|---|---|---|---|
| 1 | 01_setup.sql | ACCOUNTADMIN | Warehouse, database, schemas, roles, Cortex grants |
| 2 | 02_raw_sources.sql | SC_ADMIN | Synthetic ERP, portal, TMS, WMS, IoT data |
| 3 | 03_governance_registry.sql | SC_ADMIN | Parameters, metric registry, golden answers, test cases |
| 4 | 04_conformed.sql | SC_ADMIN | Crosswalk, dimensions, governed fact tables |
| 5 | 05_semantic_view.sql | SC_ADMIN | Semantic view SUPPLY_CHAIN_ONTOLOGY + canonical scorecard |
| 6 | 06_security.sql | SC_ADMIN | Row access, masking, tags, grants |
| 7 | 07_demo.sql | SC_ADMIN, then persona roles | Legacy views, before/after view, role-switch proof |
| 8 | streamlit_app.py | SC_ADMIN | Deploy to SC_ONTOLOGY.APP |

## How to run each step

1. Read the whole file first. Execute its statements in order, one at a time, with the role the file sets.
2. After each file, report row counts or the output of the check queries at its end.
3. Stop and report if a statement fails. Do not skip ahead.

## Fixing errors

You may fix syntax and platform differences so the scripts run in this account. Examples: a clause name that changed, a function signature, a privilege keyword, semantic view DDL ordering. Explain every fix in one line and apply the same fix to the file on disk.

You must NOT change business meaning without asking the user first. That includes: metric formulas, tolerance windows, time anchors, what counts as due, unit or timezone conversion rules, the persona plant scopes, and the golden SQL. If a fix would change a number, ask.

Known points to verify in this account:
- `AI_SQL_GENERATION` and `AI_QUESTION_CATEGORIZATION` clauses in 05. If rejected, remove them from the DDL, re-run, and tell the user to paste the same text into the semantic view's custom instructions in Snowsight.
- `SEMANTIC_VIEW(...)` inside a view (V_CANONICAL_SCORECARD). If views cannot wrap it, create GOVERNED.CANONICAL_SCORECARD as a table populated by the same five queries instead, keep the same columns, and point 06 and 07 at it.
- `GRANT SELECT ON SEMANTIC VIEW` syntax in 06.
- Re-running 04 drops the policies from 06. Always re-run 06 after 04.

## Acceptance checks after step 7

Run these and show the results as a table:
- `SELECT * FROM SC_ONTOLOGY.GOVERNED.V_CANONICAL_SCORECARD;` returns 5 rows, no NULL values.
- `SELECT metric, source, ROUND(value*100,1) FROM SC_ONTOLOGY.GOVERNED.V_BEFORE_AFTER ORDER BY 1,2;` shows legacy values that differ from each other and from the canonical row.
- The scorecard queried as SC_PLANNING, SC_PROCUREMENT and SC_LOGISTICS returns identical values.
- As SC_LOGISTICS, `unit_price_usd` in CONFORMED.FCT_PO_LINE is NULL and only plants IN01 and GB01 are visible.
- For each row of GOVERNED.GOLDEN_ANSWER with non-NULL golden_sql, the golden SQL returns exactly one row.

## Deploying the Streamlit app

Preferred: if the `snow` CLI is installed, run `snow streamlit deploy --replace` from this folder using the same connection (snowflake.yml is provided). Otherwise create a stage in SC_ONTOLOGY.APP, PUT streamlit_app.py to it, and run `CREATE OR REPLACE STREAMLIT SC_ONTOLOGY.APP.SC_ONTOLOGY_APP FROM '@<stage>' MAIN_FILE = 'streamlit_app.py' QUERY_WAREHOUSE = SC_WH;` as SC_ADMIN. If neither works, tell the user to paste the file into Snowsight (Projects > Streamlit > new app in SC_ONTOLOGY.APP, warehouse SC_WH).

After deploy, give the user the app URL or the Snowsight path to it.
