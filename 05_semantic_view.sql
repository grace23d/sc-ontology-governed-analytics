-- =====================================================================
-- 05_semantic_view.sql
-- The ontology as a governed Snowflake Semantic View.
-- Entities = logical tables, relationships = ontology edges,
-- metrics = the certified definitions from GOVERNED.METRIC_REGISTRY.
-- If your account rejects AI_SQL_GENERATION / AI_QUESTION_CATEGORIZATION,
-- remove those two clauses and paste the same text into Snowsight
-- (AI & ML > Cortex Analyst > this semantic view > custom instructions).
-- =====================================================================
USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
USE SCHEMA SC_ONTOLOGY.GOVERNED;

CREATE OR REPLACE SEMANTIC VIEW SC_ONTOLOGY.GOVERNED.SUPPLY_CHAIN_ONTOLOGY

  TABLES (
    suppliers AS SC_ONTOLOGY.CONFORMED.DIM_SUPPLIER
      PRIMARY KEY (supplier_id)
      WITH SYNONYMS = ('vendors', 'vendor', 'sources of supply')
      COMMENT = 'Golden supplier record. One row per real supplier after matching ERP vendor codes and supplier portal IDs by tax ID.',
    parts AS SC_ONTOLOGY.CONFORMED.DIM_PART
      PRIMARY KEY (part_id)
      WITH SYNONYMS = ('materials', 'components', 'SKUs', 'items')
      COMMENT = 'Parts with a commodity > category hierarchy and standard cost.',
    plants AS SC_ONTOLOGY.CONFORMED.DIM_PLANT
      PRIMARY KEY (plant_id)
      WITH SYNONYMS = ('sites', 'factories', 'locations', 'facilities')
      COMMENT = 'Manufacturing plants with a region > country > plant hierarchy.',
    customers AS SC_ONTOLOGY.CONFORMED.DIM_CUSTOMER
      PRIMARY KEY (customer_id)
      WITH SYNONYMS = ('dealers', 'buyers', 'accounts')
      COMMENT = 'Customers who place sales orders.',
    carriers AS SC_ONTOLOGY.CONFORMED.DIM_CARRIER
      PRIMARY KEY (carrier_id)
      WITH SYNONYMS = ('transporters', 'logistics providers', '3PLs', 'shipping partners')
      COMMENT = 'Outbound transport carriers.',
    po_lines AS SC_ONTOLOGY.CONFORMED.FCT_PO_LINE
      PRIMARY KEY (po_line_id)
      WITH SYNONYMS = ('purchase order lines', 'inbound receipts', 'supplier deliveries', 'POs')
      COMMENT = 'Inbound purchase order lines. Home of supplier OTD and landed cost.',
    order_lines AS SC_ONTOLOGY.CONFORMED.FCT_ORDER_LINE
      PRIMARY KEY (order_line_id)
      WITH SYNONYMS = ('sales order lines', 'customer orders', 'demand lines')
      COMMENT = 'Customer sales order lines. Home of customer OTD and fill rates.',
    shipments AS SC_ONTOLOGY.CONFORMED.FCT_SHIPMENT
      PRIMARY KEY (shipment_id)
      WITH SYNONYMS = ('outbound shipments', 'consignments', 'dispatches')
      COMMENT = 'Outbound shipment legs with freight and transit time.',
    inventory AS SC_ONTOLOGY.CONFORMED.FCT_INVENTORY_POSITION
      PRIMARY KEY (inventory_position_id)
      WITH SYNONYMS = ('stock', 'inventory position', 'on hand')
      COMMENT = 'Month-end inventory by plant and part. Home of days of inventory.'
  )

  RELATIONSHIPS (
    po_to_supplier       AS po_lines (supplier_id)           REFERENCES suppliers,
    po_to_part           AS po_lines (part_id)               REFERENCES parts,
    po_to_plant          AS po_lines (plant_id)              REFERENCES plants,
    order_to_customer    AS order_lines (customer_id)        REFERENCES customers,
    order_to_part        AS order_lines (part_id)            REFERENCES parts,
    order_to_plant       AS order_lines (plant_id)           REFERENCES plants,
    order_to_carrier     AS order_lines (primary_carrier_id) REFERENCES carriers,
    shipment_to_customer AS shipments (customer_id)          REFERENCES customers,
    shipment_to_part     AS shipments (part_id)              REFERENCES parts,
    shipment_to_plant    AS shipments (plant_id)             REFERENCES plants,
    shipment_to_carrier  AS shipments (carrier_id)           REFERENCES carriers,
    inventory_to_part    AS inventory (part_id)              REFERENCES parts,
    inventory_to_plant   AS inventory (plant_id)             REFERENCES plants
  )

  FACTS (
    po_lines.po_order_qty_ea          AS order_qty_ea,
    po_lines.po_received_qty_ea       AS received_qty_ea,
    po_lines.po_due_line_flag         AS due_line_flag       COMMENT = '1 when the PO line is past confirmed date + late tolerance',
    po_lines.po_on_time_line_flag     AS on_time_line_flag   COMMENT = '1 when a due PO line was received in full within the tolerance window',
    po_lines.po_days_late             AS days_late           COMMENT = 'Full receipt date minus confirmed date; negative = early',
    po_lines.po_unit_price_usd        AS unit_price_usd,
    po_lines.po_goods_value_usd       AS goods_value_usd,
    po_lines.po_freight_usd           AS freight_usd,
    po_lines.po_duty_usd              AS duty_usd,
    po_lines.po_insurance_usd         AS insurance_usd,
    po_lines.po_handling_usd          AS handling_usd,
    po_lines.po_landed_cost_usd       AS landed_cost_usd,
    order_lines.so_order_qty_ea       AS order_qty_ea,
    order_lines.so_due_line_flag      AS due_line_flag,
    order_lines.so_due_order_qty_ea   AS due_order_qty_ea,
    order_lines.so_due_shipped_by_commit_qty_ea AS due_shipped_by_commit_qty_ea,
    order_lines.so_due_line_filled_flag   AS due_line_filled_flag,
    order_lines.so_due_line_on_time_flag  AS due_line_on_time_flag,
    order_lines.so_order_value_usd    AS order_value_usd,
    shipments.shp_shipped_qty_ea      AS shipped_qty_ea,
    shipments.shp_freight_cost_usd    AS freight_cost_usd,
    shipments.shp_transit_days        AS transit_days,
    shipments.shp_gross_weight_kg     AS gross_weight_kg,
    inventory.inv_on_hand_qty_ea      AS on_hand_qty_ea,
    inventory.inv_value_usd           AS inventory_value_usd,
    inventory.inv_in_transit_value_usd AS in_transit_value_usd,
    inventory.inv_avg_daily_cogs_usd  AS avg_daily_cogs_usd
  )

  DIMENSIONS (
    suppliers.supplier_name    AS supplier_name    WITH SYNONYMS = ('vendor name'),
    suppliers.supplier_country AS supplier_country WITH SYNONYMS = ('origin country', 'vendor country'),
    suppliers.supplier_tier    AS supplier_tier    WITH SYNONYMS = ('tier'),

    parts.part_id       AS part_id       WITH SYNONYMS = ('material number', 'part number', 'SKU'),
    parts.part_name     AS part_name     WITH SYNONYMS = ('material description'),
    parts.commodity     AS commodity     WITH SYNONYMS = ('commodity group', 'spend category'),
    parts.part_category AS part_category WITH SYNONYMS = ('category', 'product family'),

    plants.plant_id      AS plant_id      WITH SYNONYMS = ('plant code', 'site code'),
    plants.plant_name    AS plant_name    WITH SYNONYMS = ('plant', 'factory name'),
    plants.plant_city    AS plant_city    WITH SYNONYMS = ('city', 'location')
      COMMENT = 'Use this to filter plants by city, for example Chennai',
    plants.plant_country AS plant_country WITH SYNONYMS = ('country'),
    plants.plant_region  AS plant_region  WITH SYNONYMS = ('region'),

    customers.customer_name    AS customer_name    WITH SYNONYMS = ('dealer name', 'account name'),
    customers.customer_country AS customer_country,
    customers.customer_segment AS customer_segment WITH SYNONYMS = ('channel', 'customer type'),

    carriers.carrier_name   AS carrier_name   WITH SYNONYMS = ('transporter', 'logistics provider'),
    carriers.transport_mode AS transport_mode WITH SYNONYMS = ('mode'),

    po_lines.po_number        AS po_number     WITH SYNONYMS = ('purchase order number'),
    po_lines.po_date          AS po_date       WITH SYNONYMS = ('order placed date'),
    po_lines.confirmed_date   AS confirmed_date
      WITH SYNONYMS = ('supplier confirmed date', 'promised date', 'inbound due date')
      COMMENT = 'Time anchor for supplier_otd',
    po_lines.confirmed_month  AS confirmed_month,
    po_lines.confirmed_quarter AS confirmed_quarter COMMENT = 'Calendar quarter label YYYY-Qn',
    po_lines.confirmed_fiscal_quarter AS confirmed_fiscal_quarter COMMENT = 'Fiscal quarter label, fiscal year starts in April',
    po_lines.receipt_date     AS receipt_date
      WITH SYNONYMS = ('received date', 'arrival date')
      COMMENT = 'Time anchor for landed cost. Date the last receipt arrived.',
    po_lines.receipt_quarter  AS receipt_quarter,
    po_lines.delivery_status  AS delivery_status
      COMMENT = 'ON_TIME, LATE, EARLY, OPEN_OVERDUE, NOT_YET_DUE',
    po_lines.arrival_source   AS arrival_source
      COMMENT = 'Lineage: IOT_GATE_IN, ERP_GR_POSTING or MIXED',
    po_lines.confirmed_date_source AS confirmed_date_source,

    order_lines.sales_order_number AS sales_order_number,
    order_lines.order_date   AS order_date,
    order_lines.commit_date  AS commit_date
      WITH SYNONYMS = ('committed date', 'promise date', 'customer due date')
      COMMENT = 'Time anchor for customer_otd, unit_fill_rate and line_fill_rate',
    order_lines.commit_month AS commit_month,
    order_lines.commit_quarter AS commit_quarter COMMENT = 'Calendar quarter label YYYY-Qn',
    order_lines.commit_fiscal_quarter AS commit_fiscal_quarter COMMENT = 'Fiscal quarter label, fiscal year starts in April',
    order_lines.line_status  AS line_status,

    shipments.ship_date       AS ship_date      WITH SYNONYMS = ('dispatch date'),
    shipments.ship_month      AS ship_month,
    shipments.delivery_date   AS delivery_date  WITH SYNONYMS = ('POD date'),
    shipments.shipment_status AS shipment_status,

    inventory.snapshot_date      AS snapshot_date      COMMENT = 'Month-end snapshot date. Time anchor for days_of_inventory.',
    inventory.snapshot_month     AS snapshot_month,
    inventory.is_latest_snapshot AS is_latest_snapshot COMMENT = 'TRUE for the most recent snapshot; use when no date is given'
  )

  METRICS (
    po_lines.supplier_otd AS SUM(po_lines.po_on_time_line_flag) / NULLIF(SUM(po_lines.po_due_line_flag), 0)
      WITH SYNONYMS = ('supplier on-time delivery', 'inbound OTD', 'vendor OTD', 'vendor on-time delivery', 'supplier delivery performance')
      COMMENT = 'CERTIFIED v1.2, owner Procurement Excellence. Due PO lines received in full within -3/+2 days of supplier-confirmed date / due PO lines. Ratio 0-1.',
    po_lines.due_po_lines AS SUM(po_lines.po_due_line_flag)
      COMMENT = 'Denominator of supplier_otd',
    po_lines.avg_days_late AS AVG(po_lines.po_days_late)
      COMMENT = 'Average days between confirmed date and full receipt; negative = early',
    po_lines.total_landed_cost_usd AS SUM(po_lines.po_landed_cost_usd)
      WITH SYNONYMS = ('landed cost', 'all-in cost', 'total cost of acquisition')
      COMMENT = 'CERTIFIED v1.1, owner Finance Controlling. Goods + allocated freight + duty + insurance + handling, USD.',
    po_lines.landed_cost_per_unit_usd AS SUM(po_lines.po_landed_cost_usd) / NULLIF(SUM(po_lines.po_received_qty_ea), 0)
      WITH SYNONYMS = ('unit landed cost')
      COMMENT = 'CERTIFIED v1.1. Total landed cost / received units.',
    po_lines.total_goods_value_usd AS SUM(po_lines.po_goods_value_usd)
      WITH SYNONYMS = ('purchase value', 'spend'),

    order_lines.customer_otd AS SUM(order_lines.so_due_line_on_time_flag) / NULLIF(SUM(order_lines.so_due_line_flag), 0)
      WITH SYNONYMS = ('customer on-time delivery', 'outbound OTD', 'delivery to promise')
      COMMENT = 'CERTIFIED v1.1, owner Customer Supply and Logistics. Due order lines delivered in full by commit date / due order lines. Ratio 0-1.',
    order_lines.unit_fill_rate AS SUM(order_lines.so_due_shipped_by_commit_qty_ea) / NULLIF(SUM(order_lines.so_due_order_qty_ea), 0)
      WITH SYNONYMS = ('fill rate', 'unit fill')
      COMMENT = 'CERTIFIED v2.0, owner S&OP Planning. Units shipped by commit date / units ordered, due lines only. Default meaning of fill rate. Ratio 0-1.',
    order_lines.line_fill_rate AS SUM(order_lines.so_due_line_filled_flag) / NULLIF(SUM(order_lines.so_due_line_flag), 0)
      WITH SYNONYMS = ('line fill')
      COMMENT = 'CERTIFIED v1.0. Due lines shipped complete by commit date / due lines. Ratio 0-1.',
    order_lines.ordered_units AS SUM(order_lines.so_order_qty_ea),
    order_lines.total_order_value_usd AS SUM(order_lines.so_order_value_usd)
      WITH SYNONYMS = ('sales value', 'order intake'),

    shipments.total_outbound_freight_usd AS SUM(shipments.shp_freight_cost_usd)
      WITH SYNONYMS = ('freight cost', 'transport cost'),
    shipments.avg_transit_days AS AVG(shipments.shp_transit_days)
      WITH SYNONYMS = ('transit time', 'lead time in transit'),
    shipments.shipped_units AS SUM(shipments.shp_shipped_qty_ea),

    inventory.days_of_inventory AS SUM(inventory.inv_value_usd) / NULLIF(SUM(inventory.inv_avg_daily_cogs_usd), 0)
      WITH SYNONYMS = ('DOI', 'days of supply', 'days on hand', 'inventory days', 'days of stock')
      COMMENT = 'CERTIFIED v1.0, owner Finance Controlling. On-hand value at standard cost / average daily COGS over trailing 90 days. Excludes in-transit.',
    inventory.total_inventory_value_usd AS SUM(inventory.inv_value_usd)
      WITH SYNONYMS = ('stock value', 'inventory value')
      COMMENT = 'Point-in-time; filter to one snapshot date'
  )

  COMMENT = 'Supply chain ontology: Supplier > Part > Plant > Shipment > Order > Customer. Certified metrics only. Owner SC_ADMIN.'

  AI_SQL_GENERATION 'Rules for this governed supply chain layer. 1) Always use the certified metrics in this view; never recompute on-time delivery, fill rate, days of inventory or landed cost from facts. 2) supplier_otd, customer_otd, unit_fill_rate and line_fill_rate are ratios between 0 and 1; return them unrounded and never multiply by 100. 3) Time anchors: filter supplier_otd by po_lines.confirmed_date; customer_otd, unit_fill_rate and line_fill_rate by order_lines.commit_date; total_landed_cost_usd and landed_cost_per_unit_usd by po_lines.receipt_date; days_of_inventory and total_inventory_value_usd by inventory.snapshot_date. 4) When no date is given for days_of_inventory or total_inventory_value_usd, filter inventory.is_latest_snapshot = TRUE. 5) Quarter means calendar quarter. Last quarter or previous quarter means the most recently completed calendar quarter: anchor date >= DATE_TRUNC(quarter, DATEADD(quarter, -1, CURRENT_DATE())) and anchor date < DATE_TRUNC(quarter, CURRENT_DATE()). Use fiscal quarter dimensions only if the user says fiscal; the fiscal year starts in April. 6) Filter locations with plants.plant_city, for example Chennai. 7) Fill rate with no qualifier means unit_fill_rate. 8) When the question asks for one number for one scope, return a single row containing only that metric.'

  AI_QUESTION_CATEGORIZATION 'If a question asks about OTD, on-time delivery or delivery performance without saying whether it is inbound from suppliers or vendors, or outbound to customers, do not generate SQL. Ask the user whether they mean supplier OTD (inbound) or customer OTD (outbound). Politely decline questions unrelated to supply chain operations.';

-- ---------------------------------------------------------------------
-- Checks
-- ---------------------------------------------------------------------
SHOW SEMANTIC VIEWS IN SCHEMA SC_ONTOLOGY.GOVERNED;
DESCRIBE SEMANTIC VIEW SC_ONTOLOGY.GOVERNED.SUPPLY_CHAIN_ONTOLOGY;

SELECT * FROM SEMANTIC_VIEW(SC_ONTOLOGY.GOVERNED.SUPPLY_CHAIN_ONTOLOGY
  DIMENSIONS plants.plant_name
  METRICS po_lines.supplier_otd, po_lines.total_landed_cost_usd)
ORDER BY plant_name;

SELECT * FROM SEMANTIC_VIEW(SC_ONTOLOGY.GOVERNED.SUPPLY_CHAIN_ONTOLOGY
  DIMENSIONS plants.plant_name
  METRICS order_lines.customer_otd, order_lines.unit_fill_rate, order_lines.line_fill_rate)
ORDER BY plant_name;

SELECT * FROM SEMANTIC_VIEW(SC_ONTOLOGY.GOVERNED.SUPPLY_CHAIN_ONTOLOGY
  DIMENSIONS plants.plant_name
  METRICS inventory.days_of_inventory
  WHERE inventory.is_latest_snapshot = TRUE)
ORDER BY plant_name;

-- ---------------------------------------------------------------------
-- Canonical scorecard: the one answer every persona should get
-- (Chennai, last completed calendar quarter / latest snapshot)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW SC_ONTOLOGY.GOVERNED.V_CANONICAL_SCORECARD AS
SELECT 'supplier_otd' AS metric_id, 'Supplier on-time delivery' AS display_name,
       'Chennai, last quarter' AS scope, supplier_otd::FLOAT AS value
FROM SEMANTIC_VIEW(SC_ONTOLOGY.GOVERNED.SUPPLY_CHAIN_ONTOLOGY
  METRICS po_lines.supplier_otd
  WHERE plants.plant_city = 'Chennai'
    AND po_lines.confirmed_date >= DATE_TRUNC('quarter', DATEADD('quarter', -1, CURRENT_DATE()))
    AND po_lines.confirmed_date <  DATE_TRUNC('quarter', CURRENT_DATE()))
UNION ALL
SELECT 'customer_otd', 'Customer on-time delivery', 'Chennai, last quarter', customer_otd::FLOAT
FROM SEMANTIC_VIEW(SC_ONTOLOGY.GOVERNED.SUPPLY_CHAIN_ONTOLOGY
  METRICS order_lines.customer_otd
  WHERE plants.plant_city = 'Chennai'
    AND order_lines.commit_date >= DATE_TRUNC('quarter', DATEADD('quarter', -1, CURRENT_DATE()))
    AND order_lines.commit_date <  DATE_TRUNC('quarter', CURRENT_DATE()))
UNION ALL
SELECT 'unit_fill_rate', 'Unit fill rate', 'Chennai, last quarter', unit_fill_rate::FLOAT
FROM SEMANTIC_VIEW(SC_ONTOLOGY.GOVERNED.SUPPLY_CHAIN_ONTOLOGY
  METRICS order_lines.unit_fill_rate
  WHERE plants.plant_city = 'Chennai'
    AND order_lines.commit_date >= DATE_TRUNC('quarter', DATEADD('quarter', -1, CURRENT_DATE()))
    AND order_lines.commit_date <  DATE_TRUNC('quarter', CURRENT_DATE()))
UNION ALL
SELECT 'days_of_inventory', 'Days of inventory', 'Chennai, latest snapshot', days_of_inventory::FLOAT
FROM SEMANTIC_VIEW(SC_ONTOLOGY.GOVERNED.SUPPLY_CHAIN_ONTOLOGY
  METRICS inventory.days_of_inventory
  WHERE plants.plant_city = 'Chennai' AND inventory.is_latest_snapshot = TRUE)
UNION ALL
SELECT 'total_landed_cost_usd', 'Total landed cost (USD)', 'Chennai, last quarter receipts', total_landed_cost_usd::FLOAT
FROM SEMANTIC_VIEW(SC_ONTOLOGY.GOVERNED.SUPPLY_CHAIN_ONTOLOGY
  METRICS po_lines.total_landed_cost_usd
  WHERE plants.plant_city = 'Chennai'
    AND po_lines.receipt_date >= DATE_TRUNC('quarter', DATEADD('quarter', -1, CURRENT_DATE()))
    AND po_lines.receipt_date <  DATE_TRUNC('quarter', CURRENT_DATE()));

SELECT * FROM SC_ONTOLOGY.GOVERNED.V_CANONICAL_SCORECARD;
