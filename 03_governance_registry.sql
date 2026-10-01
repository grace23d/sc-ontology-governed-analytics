-- =====================================================================
-- 03_governance_registry.sql
-- The "shared definitions" layer: metric parameters, the certified metric
-- registry, golden answers and persona test cases for the consistency
-- harness, plus run history and an audit log.
-- =====================================================================
USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
USE SCHEMA SC_ONTOLOGY.GOVERNED;

-- ---------------------------------------------------------------------
-- Tunable parameters. The conformed layer reads these at build time,
-- so a definition change is a governed, versioned change in one place.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE METRIC_PARAMETER (
  param_name   STRING,
  param_value  NUMBER(18,4),
  unit         STRING,
  used_by      STRING,
  description  STRING,
  version      STRING,
  updated_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO METRIC_PARAMETER (param_name, param_value, unit, used_by, description, version) VALUES
  ('SUPPLIER_OTD_EARLY_TOLERANCE_DAYS', 3,   'days', 'supplier_otd', 'Full quantity arriving up to N days before the confirmed date counts as on time', '1.2'),
  ('SUPPLIER_OTD_LATE_TOLERANCE_DAYS',  2,   'days', 'supplier_otd', 'Full quantity arriving up to N days after the confirmed date counts as on time', '1.2'),
  ('DOI_COGS_WINDOW_DAYS',              90,  'days', 'days_of_inventory', 'Trailing window for average daily COGS', '1.0'),
  ('INSURANCE_RATE_PCT',                0.5, '% of goods value', 'total_landed_cost_usd', 'Cargo insurance applied to goods value', '1.1');

-- ---------------------------------------------------------------------
-- Certified metric registry (human-readable contract for each metric)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE METRIC_REGISTRY (
  metric_id               STRING,
  display_name            STRING,
  semantic_metric         STRING,
  business_definition     STRING,
  formula                 STRING,
  grain                   STRING,
  anchor_date             STRING,
  inclusions_exclusions   STRING,
  owner                   STRING,
  version                 STRING,
  status                  STRING,
  synonyms                STRING,
  not_to_be_confused_with STRING,
  effective_from          DATE
);

INSERT INTO METRIC_REGISTRY VALUES
('supplier_otd', 'Supplier on-time delivery', 'po_lines.supplier_otd',
 'Share of due PO lines where the full ordered quantity physically arrived within the tolerance window around the supplier-confirmed date.',
 'on-time due PO lines / due PO lines',
 'PO line', 'po_lines.confirmed_date',
 'Arrival = IoT gate-in, else ERP goods-receipt date. Confirmed date from supplier portal, else requested date. Window -3/+2 days. Partial quantity in window = late. Open lines past due = late. Lines not yet due excluded.',
 'Procurement Excellence', '1.2', 'CERTIFIED',
 'supplier OTD, inbound OTD, vendor OTD, vendor on-time, supplier delivery performance',
 'customer_otd (outbound), OTIF', '2026-04-01'),

('customer_otd', 'Customer on-time delivery', 'order_lines.customer_otd',
 'Share of due customer order lines where the full ordered quantity was delivered (proof of delivery) on or before the committed date.',
 'due order lines delivered in full by commit date / due order lines',
 'Sales order line', 'order_lines.commit_date',
 'Delivery date = POD timestamp converted to plant local time. Quantities converted to EA. Lines not yet due excluded.',
 'Customer Supply and Logistics', '1.1', 'CERTIFIED',
 'customer OTD, outbound OTD, delivery to promise, DTP',
 'supplier_otd (inbound), unit_fill_rate', '2026-04-01'),

('unit_fill_rate', 'Unit fill rate', 'order_lines.unit_fill_rate',
 'Units shipped on or before the committed date as a share of units ordered on due lines. The default meaning of fill rate.',
 'sum(min(shipped by commit, ordered)) / sum(ordered), due lines only',
 'Sales order line', 'order_lines.commit_date',
 'Ship date in plant local time. BOX converted to EA. Over-shipment capped at ordered quantity.',
 'S&OP Planning', '2.0', 'CERTIFIED',
 'fill rate, unit fill, case fill',
 'line_fill_rate, customer_otd', '2026-04-01'),

('line_fill_rate', 'Line fill rate', 'order_lines.line_fill_rate',
 'Share of due order lines shipped complete on or before the committed date.',
 'due lines fully shipped by commit / due lines',
 'Sales order line', 'order_lines.commit_date',
 'Same shipping rules as unit fill rate.',
 'S&OP Planning', '1.0', 'CERTIFIED',
 'line fill, order line fill',
 'unit_fill_rate', '2026-04-01'),

('days_of_inventory', 'Days of inventory', 'inventory.days_of_inventory',
 'On-hand inventory value at standard cost divided by average daily COGS over the trailing 90 days.',
 'sum(on-hand value) / sum(90-day COGS / 90)',
 'Plant x part x month-end snapshot', 'inventory.snapshot_date',
 'In-transit stock excluded. Latest snapshot when no date given. COGS = shipped EA x standard cost.',
 'Finance Controlling', '1.0', 'CERTIFIED',
 'DOI, days of supply, days on hand, inventory days, days of stock',
 'weeks of cover based on forecast', '2026-04-01'),

('total_landed_cost_usd', 'Total landed cost (USD)', 'po_lines.total_landed_cost_usd',
 'Full cost of received material: goods value plus inbound freight, duty, insurance and plant handling.',
 'goods + freight (allocated by weight) + duty + insurance + handling',
 'PO line', 'po_lines.receipt_date',
 'Prices converted at monthly FX of PO month. Freight invoice allocated to PO lines by weight. Duty by origin, destination, commodity.',
 'Finance Controlling', '1.1', 'CERTIFIED',
 'landed cost, all-in cost, total cost of acquisition',
 'purchase price, standard cost', '2026-04-01'),

('landed_cost_per_unit_usd', 'Landed cost per unit (USD)', 'po_lines.landed_cost_per_unit_usd',
 'Total landed cost divided by received units.',
 'total landed cost / received units',
 'PO line', 'po_lines.receipt_date',
 'Same components as total landed cost.',
 'Finance Controlling', '1.1', 'CERTIFIED',
 'unit landed cost, landed cost per piece',
 'unit price', '2026-04-01');

-- ---------------------------------------------------------------------
-- Golden answers: the single correct value per metric and scope,
-- computed straight from the semantic view.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE GOLDEN_ANSWER (
  golden_id         STRING,
  metric_id         STRING,
  scope_description STRING,
  golden_sql        STRING
);

INSERT INTO GOLDEN_ANSWER VALUES
('G_SOTD', 'supplier_otd', 'Chennai plant, last completed calendar quarter',
 $$SELECT * FROM SEMANTIC_VIEW(SC_ONTOLOGY.GOVERNED.SUPPLY_CHAIN_ONTOLOGY
     METRICS po_lines.supplier_otd
     WHERE plants.plant_city = 'Chennai'
       AND po_lines.confirmed_date >= DATE_TRUNC('quarter', DATEADD('quarter', -1, CURRENT_DATE()))
       AND po_lines.confirmed_date <  DATE_TRUNC('quarter', CURRENT_DATE()))$$),
('G_COTD', 'customer_otd', 'Chennai plant, last completed calendar quarter',
 $$SELECT * FROM SEMANTIC_VIEW(SC_ONTOLOGY.GOVERNED.SUPPLY_CHAIN_ONTOLOGY
     METRICS order_lines.customer_otd
     WHERE plants.plant_city = 'Chennai'
       AND order_lines.commit_date >= DATE_TRUNC('quarter', DATEADD('quarter', -1, CURRENT_DATE()))
       AND order_lines.commit_date <  DATE_TRUNC('quarter', CURRENT_DATE()))$$),
('G_UFR', 'unit_fill_rate', 'Chennai plant, last completed calendar quarter',
 $$SELECT * FROM SEMANTIC_VIEW(SC_ONTOLOGY.GOVERNED.SUPPLY_CHAIN_ONTOLOGY
     METRICS order_lines.unit_fill_rate
     WHERE plants.plant_city = 'Chennai'
       AND order_lines.commit_date >= DATE_TRUNC('quarter', DATEADD('quarter', -1, CURRENT_DATE()))
       AND order_lines.commit_date <  DATE_TRUNC('quarter', CURRENT_DATE()))$$),
('G_DOI', 'days_of_inventory', 'Chennai plant, latest month-end snapshot',
 $$SELECT * FROM SEMANTIC_VIEW(SC_ONTOLOGY.GOVERNED.SUPPLY_CHAIN_ONTOLOGY
     METRICS inventory.days_of_inventory
     WHERE plants.plant_city = 'Chennai' AND inventory.is_latest_snapshot = TRUE)$$),
('G_LC', 'total_landed_cost_usd', 'Chennai plant, receipts in last completed calendar quarter',
 $$SELECT * FROM SEMANTIC_VIEW(SC_ONTOLOGY.GOVERNED.SUPPLY_CHAIN_ONTOLOGY
     METRICS po_lines.total_landed_cost_usd
     WHERE plants.plant_city = 'Chennai'
       AND po_lines.receipt_date >= DATE_TRUNC('quarter', DATEADD('quarter', -1, CURRENT_DATE()))
       AND po_lines.receipt_date <  DATE_TRUNC('quarter', CURRENT_DATE()))$$),
('G_CLARIFY', NULL, 'Ambiguous question: the layer must ask, not guess', NULL);

-- ---------------------------------------------------------------------
-- Persona test cases: same metric, each team's own vocabulary
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE CONSISTENCY_TEST_CASE (
  test_id           STRING,
  golden_id         STRING,
  persona           STRING,
  question          STRING,
  expected_behavior STRING   -- ANSWER or CLARIFY
);

INSERT INTO CONSISTENCY_TEST_CASE VALUES
('T01','G_SOTD','PROCUREMENT','What was supplier on-time delivery for the Chennai plant last quarter?','ANSWER'),
('T02','G_SOTD','PROCUREMENT','Vendor OTD at Chennai for last quarter','ANSWER'),
('T03','G_SOTD','PLANNING','What percentage of purchase order lines arrived on time at Chennai last quarter?','ANSWER'),
('T04','G_SOTD','PLANNING','How reliable were inbound supplier deliveries into Chennai last quarter?','ANSWER'),
('T05','G_SOTD','LOGISTICS','Inbound on-time delivery rate at Chennai last quarter','ANSWER'),
('T06','G_SOTD','LOGISTICS','Chennai inbound OTD, previous quarter','ANSWER'),
('T07','G_COTD','LOGISTICS','Customer on-time delivery for Chennai last quarter','ANSWER'),
('T08','G_COTD','LOGISTICS','Outbound OTD from the Chennai plant last quarter','ANSWER'),
('T09','G_COTD','PLANNING','What share of customer order lines from Chennai were delivered by the committed date last quarter?','ANSWER'),
('T10','G_COTD','PROCUREMENT','Customer OTD Chennai last quarter','ANSWER'),
('T11','G_UFR','PLANNING','What was our fill rate at Chennai last quarter?','ANSWER'),
('T12','G_UFR','PLANNING','Unit fill rate for Chennai last quarter','ANSWER'),
('T13','G_UFR','LOGISTICS','What share of ordered units did Chennai ship by the commit date last quarter?','ANSWER'),
('T14','G_UFR','PROCUREMENT','Chennai fill rate previous quarter','ANSWER'),
('T15','G_DOI','PLANNING','Days of inventory at Chennai as of the latest snapshot','ANSWER'),
('T16','G_DOI','PROCUREMENT','How many days of stock are we holding at Chennai right now?','ANSWER'),
('T17','G_DOI','LOGISTICS','Current DOI for the Chennai plant','ANSWER'),
('T18','G_LC','PROCUREMENT','Total landed cost of parts received at Chennai last quarter','ANSWER'),
('T19','G_LC','PLANNING','What did inbound material cost us all-in at Chennai last quarter, in USD?','ANSWER'),
('T20','G_LC','LOGISTICS','Landed cost for Chennai receipts last quarter','ANSWER'),
('T21','G_CLARIFY','PLANNING','What was OTD at Chennai last quarter?','CLARIFY'),
('T22','G_CLARIFY','LOGISTICS','How did on-time delivery look for Chennai last quarter?','CLARIFY');

-- ---------------------------------------------------------------------
-- Run history and audit (kept across rebuilds)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS CONSISTENCY_TEST_RUN (
  run_id              STRING,
  run_ts              TIMESTAMP_NTZ,
  test_id             STRING,
  persona             STRING,
  golden_id           STRING,
  metric_id           STRING,
  question            STRING,
  expected_behavior   STRING,
  expected_value      FLOAT,
  returned_value      FLOAT,
  status              STRING,
  detail              STRING,
  verified_query_used STRING,
  generated_sql       STRING
);

CREATE TABLE IF NOT EXISTS QUERY_AUDIT_LOG (
  logged_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  app_user            STRING DEFAULT CURRENT_USER(),
  persona             STRING,
  question            STRING,
  generated_sql       STRING,
  metrics_resolved    STRING,
  verified_query_used STRING,
  analyst_request_id  STRING,
  outcome             STRING
);
