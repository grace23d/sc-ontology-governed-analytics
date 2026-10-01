-- =====================================================================
-- 04_conformed.sql
-- Turns raw source data into ontology entities: one golden record per
-- supplier, conformed dimensions, and fact tables where every business
-- rule (UoM, timezone, FX, tolerance, "not yet due") is applied once.
-- NOTE: CREATE OR REPLACE drops row access / masking policies.
--       Re-run 06_security.sql after re-running this script.
-- =====================================================================
USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
USE DATABASE SC_ONTOLOGY;
USE SCHEMA CONFORMED;

-- Governed parameters (single source: GOVERNED.METRIC_PARAMETER)
SET early_tol  = (SELECT param_value FROM GOVERNED.METRIC_PARAMETER WHERE param_name = 'SUPPLIER_OTD_EARLY_TOLERANCE_DAYS');
SET late_tol   = (SELECT param_value FROM GOVERNED.METRIC_PARAMETER WHERE param_name = 'SUPPLIER_OTD_LATE_TOLERANCE_DAYS');
SET doi_window = (SELECT param_value FROM GOVERNED.METRIC_PARAMETER WHERE param_name = 'DOI_COGS_WINDOW_DAYS');
SET ins_rate   = (SELECT param_value FROM GOVERNED.METRIC_PARAMETER WHERE param_name = 'INSURANCE_RATE_PCT');

-- ---------------------------------------------------------------------
-- Master-data crosswalk and dimensions
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE XREF_SUPPLIER COMMENT = 'Crosswalk: every source identifier maps to exactly one golden supplier_id' AS
SELECT 'ERP' AS source_system, e.lifnr AS source_key, e.name1 AS source_name,
       'SUP-' || SUBSTR(pr.lifnr, 3) AS supplier_id,
       IFF(e.ktokk = 'PRIMARY', 'ERP_PRIMARY_RECORD', 'ERP_DUPLICATE_SAME_TAX_ID') AS match_rule
FROM RAW.ERP_VENDOR_MASTER e
JOIN RAW.ERP_VENDOR_MASTER pr ON pr.stcd1 = e.stcd1 AND pr.ktokk = 'PRIMARY'
UNION ALL
SELECT 'SUPPLIER_PORTAL', pv.portal_vendor_id, pv.vendor_display_name,
       'SUP-' || SUBSTR(pr.lifnr, 3), 'TAX_ID_MATCH'
FROM RAW.PORTAL_VENDOR pv
JOIN RAW.ERP_VENDOR_MASTER pr ON pr.stcd1 = pv.tax_registration AND pr.ktokk = 'PRIMARY';

CREATE OR REPLACE TABLE DIM_SUPPLIER COMMENT = 'Golden supplier record' AS
SELECT 'SUP-' || SUBSTR(v.lifnr, 3) AS supplier_id,
       v.name1 AS supplier_name, v.land1 AS supplier_country, v.zz_tier AS supplier_tier, v.stcd1 AS tax_id,
       COALESCE(x.cnt, 0) AS source_record_count
FROM RAW.ERP_VENDOR_MASTER v
LEFT JOIN (SELECT supplier_id, COUNT(*) AS cnt FROM XREF_SUPPLIER GROUP BY supplier_id) x
  ON x.supplier_id = 'SUP-' || SUBSTR(v.lifnr, 3)
WHERE v.ktokk = 'PRIMARY';

CREATE OR REPLACE TABLE DIM_PART COMMENT = 'Part / material with commodity > category hierarchy' AS
SELECT matnr AS part_id, maktx AS part_name, zz_commodity AS commodity, zz_category AS part_category,
       stprs_usd AS std_cost_usd, brgew_kg AS unit_weight_kg, pack_qty, meins AS base_uom
FROM RAW.ERP_MATERIAL_MASTER;

CREATE OR REPLACE TABLE DIM_PLANT COMMENT = 'Plant with region > country > plant hierarchy' AS
SELECT werks AS plant_id, plant_name, city AS plant_city, country_code AS plant_country, region AS plant_region,
       time_zone, local_currency, handling_usd_per_kg
FROM RAW.ERP_PLANT;

CREATE OR REPLACE TABLE DIM_CUSTOMER AS
SELECT kunnr AS customer_id, name1 AS customer_name, land1 AS customer_country, kdgrp AS customer_segment
FROM RAW.ERP_CUSTOMER_MASTER;

CREATE OR REPLACE TABLE DIM_CARRIER AS
SELECT carrier_code AS carrier_id, carrier_name, transport_mode
FROM RAW.TMS_CARRIER;

-- ---------------------------------------------------------------------
-- FCT_SHIPMENT: one row per outbound shipment leg, quantities in EA,
-- timestamps normalised, freight in USD
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE FCT_SHIPMENT COMMENT = 'Outbound shipment legs, conformed' AS
SELECT
  s.shipment_id,
  s.order_ref || '-' || LPAD(s.order_line_ref, 6, '0') AS order_line_id,
  so.kunnr AS customer_id, so.matnr AS part_id, so.werks AS plant_id, s.carrier_code AS carrier_id,
  IFF(s.qty_uom = 'BOX', s.qty_shipped * p.pack_qty, s.qty_shipped)::NUMBER(18,3) AS shipped_qty_ea,
  s.qty_uom AS source_uom,
  s.ship_ts_local,
  CONVERT_TIMEZONE(pl.time_zone, 'UTC', s.ship_ts_local) AS ship_ts_utc,
  TO_DATE(s.ship_ts_local) AS ship_date,
  DATE_TRUNC('month', TO_DATE(s.ship_ts_local)) AS ship_month,
  s.delivered_ts_utc,
  TO_DATE(CONVERT_TIMEZONE('UTC', pl.time_zone, s.delivered_ts_utc)) AS delivery_date,
  ROUND(DATEDIFF('hour', CONVERT_TIMEZONE(pl.time_zone, 'UTC', s.ship_ts_local), s.delivered_ts_utc) / 24.0, 2) AS transit_days,
  s.gross_weight_kg,
  ROUND(s.freight_amount * fx.usd_per_unit, 2)::NUMBER(18,2) AS freight_cost_usd,
  ROUND(IFF(s.qty_uom = 'BOX', s.qty_shipped * p.pack_qty, s.qty_shipped) * p.std_cost_usd, 2)::NUMBER(18,2) AS cogs_usd,
  IFF(s.delivered_ts_utc IS NULL, 'IN_TRANSIT', 'DELIVERED') AS shipment_status
FROM RAW.TMS_SHIPMENT s
JOIN RAW.ERP_SO_ITEM so ON so.vbeln = s.order_ref AND so.posnr = s.order_line_ref
JOIN DIM_PART p   ON p.part_id = so.matnr
JOIN DIM_PLANT pl ON pl.plant_id = so.werks
JOIN RAW.FX_RATE_MONTHLY fx ON fx.currency = s.freight_currency AND fx.month_start = DATE_TRUNC('month', TO_DATE(s.ship_ts_local));

-- ---------------------------------------------------------------------
-- FCT_ORDER_LINE: one row per sales order line with fill / OTD facts
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE FCT_ORDER_LINE COMMENT = 'Customer order lines with governed fill-rate and OTD facts' AS
WITH so AS (
  SELECT vbeln || '-' || LPAD(posnr, 6, '0') AS order_line_id,
         vbeln, kunnr, matnr, werks, kwmeng, netpr_usd, audat, edatu
  FROM RAW.ERP_SO_ITEM
),
agg AS (
  SELECT so.order_line_id,
         COALESCE(SUM(f.shipped_qty_ea), 0) AS shipped_qty_ea,
         COALESCE(SUM(IFF(f.ship_date <= so.edatu, f.shipped_qty_ea, 0)), 0) AS shipped_by_commit_qty_ea,
         COALESCE(SUM(IFF(f.delivery_date <= so.edatu, f.shipped_qty_ea, 0)), 0) AS delivered_by_commit_qty_ea,
         MIN_BY(f.carrier_id, f.ship_ts_local) AS primary_carrier_id
  FROM so
  LEFT JOIN FCT_SHIPMENT f ON f.order_line_id = so.order_line_id
  GROUP BY so.order_line_id
),
base AS (
  SELECT so.*, a.shipped_qty_ea, a.shipped_by_commit_qty_ea, a.delivered_by_commit_qty_ea, a.primary_carrier_id,
         (so.edatu < CURRENT_DATE()) AS is_due
  FROM so JOIN agg a ON a.order_line_id = so.order_line_id
)
SELECT
  order_line_id,
  vbeln AS sales_order_number,
  kunnr AS customer_id, matnr AS part_id, werks AS plant_id, primary_carrier_id,
  audat AS order_date,
  edatu AS commit_date,
  DATE_TRUNC('month', edatu) AS commit_month,
  YEAR(edatu) || '-Q' || QUARTER(edatu) AS commit_quarter,
  'FY' || YEAR(DATEADD('month', -3, edatu)) || '-Q' || QUARTER(DATEADD('month', -3, edatu)) AS commit_fiscal_quarter,
  kwmeng AS order_qty_ea,
  shipped_qty_ea, shipped_by_commit_qty_ea, delivered_by_commit_qty_ea,
  is_due,
  IFF(is_due, 1, 0) AS due_line_flag,
  IFF(is_due, kwmeng, 0) AS due_order_qty_ea,
  IFF(is_due, LEAST(shipped_by_commit_qty_ea, kwmeng), 0) AS due_shipped_by_commit_qty_ea,
  IFF(is_due AND shipped_by_commit_qty_ea >= kwmeng, 1, 0) AS due_line_filled_flag,
  IFF(is_due AND delivered_by_commit_qty_ea >= kwmeng, 1, 0) AS due_line_on_time_flag,
  ROUND(kwmeng * netpr_usd, 2)::NUMBER(18,2) AS order_value_usd,
  CASE WHEN NOT is_due THEN 'NOT_YET_DUE'
       WHEN delivered_by_commit_qty_ea >= kwmeng THEN 'DELIVERED_ON_TIME'
       WHEN shipped_qty_ea = 0 THEN 'NOT_SHIPPED'
       WHEN shipped_qty_ea < kwmeng THEN 'SHORT_OR_PARTIAL'
       ELSE 'DELIVERED_LATE' END AS line_status
FROM base;

-- ---------------------------------------------------------------------
-- FCT_PO_LINE: one row per PO line with supplier OTD and landed cost
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE FCT_PO_LINE COMMENT = 'Purchase order lines with governed supplier OTD and landed cost' AS
WITH po AS (
  SELECT i.ebeln, i.ebelp, i.lifnr, i.matnr, i.werks, i.menge, i.netpr, i.waers, i.bedat, i.eindt,
         i.ebeln || '-' || LPAD(i.ebelp, 5, '0') AS po_line_id,
         x.supplier_id, s.supplier_country, pl.time_zone, pl.plant_country, pl.handling_usd_per_kg,
         p.unit_weight_kg, p.commodity
  FROM RAW.ERP_PO_ITEM i
  JOIN XREF_SUPPLIER x ON x.source_system = 'ERP' AND x.source_key = i.lifnr
  JOIN DIM_SUPPLIER s  ON s.supplier_id = x.supplier_id
  JOIN DIM_PLANT pl    ON pl.plant_id = i.werks
  JOIN DIM_PART p      ON p.part_id = i.matnr
),
conf AS (   -- latest supplier confirmation wins
  SELECT po_ref, line_ref, MAX_BY(confirmed_delivery_date, confirmed_at) AS confirmed_delivery_date
  FROM RAW.PORTAL_PO_CONFIRMATION
  GROUP BY po_ref, line_ref
),
rcpt AS (   -- arrival = IoT gate-in (plant local date), else GR posting date
  SELECT gr.ebeln, gr.ebelp, gr.receipt_seq, gr.menge AS gr_qty,
         COALESCE(TO_DATE(CONVERT_TIMEZONE('UTC', po.time_zone, iot.event_ts_utc)), gr.budat) AS arrival_date,
         IFF(iot.event_id IS NULL, 'ERP_GR_POSTING', 'IOT_GATE_IN') AS arrival_source
  FROM RAW.ERP_GOODS_RECEIPT gr
  JOIN po ON po.ebeln = gr.ebeln AND po.ebelp = gr.ebelp
  LEFT JOIN RAW.IOT_GATE_EVENT iot
    ON iot.asn_ref = gr.ebeln || '-' || gr.ebelp || '-' || gr.receipt_seq AND iot.event_type = 'GATE_IN'
),
rcpt_cum AS (
  SELECT r.*,
         SUM(gr_qty) OVER (PARTITION BY ebeln, ebelp ORDER BY arrival_date, receipt_seq
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cum_qty
  FROM rcpt r
),
rcv AS (
  SELECT c.ebeln, c.ebelp,
         SUM(c.gr_qty) AS received_qty_ea,
         MIN(c.arrival_date) AS first_arrival_date,
         MAX(c.arrival_date) AS last_arrival_date,
         MIN(IFF(c.cum_qty >= p.menge, c.arrival_date, NULL)) AS full_receipt_date,
         COUNT(*) AS receipt_count,
         CASE WHEN COUNT_IF(c.arrival_source = 'IOT_GATE_IN') = COUNT(*) THEN 'IOT_GATE_IN'
              WHEN COUNT_IF(c.arrival_source = 'IOT_GATE_IN') = 0 THEN 'ERP_GR_POSTING'
              ELSE 'MIXED' END AS arrival_source
  FROM rcpt_cum c
  JOIN po p ON p.ebeln = c.ebeln AND p.ebelp = c.ebelp
  GROUP BY c.ebeln, c.ebelp
),
fr AS (
  SELECT f.po_ref, SUM(f.freight_amount * fx.usd_per_unit) AS po_freight_usd
  FROM RAW.TMS_INBOUND_FREIGHT f
  JOIN RAW.FX_RATE_MONTHLY fx ON fx.currency = f.currency AND fx.month_start = DATE_TRUNC('month', CURRENT_DATE())
  GROUP BY f.po_ref
),
wt AS (SELECT ebeln, SUM(menge * unit_weight_kg) AS po_weight_kg FROM po GROUP BY ebeln),
base AS (
  SELECT po.*,
         COALESCE(c.confirmed_delivery_date, po.eindt) AS confirmed_date,
         IFF(c.confirmed_delivery_date IS NULL, 'REQUESTED_DATE_FALLBACK', 'SUPPLIER_PORTAL') AS confirmed_date_source,
         ROUND(po.netpr * fxp.usd_per_unit, 4) AS price_usd,
         COALESCE(r.received_qty_ea, 0) AS received_qty,
         r.first_arrival_date, r.last_arrival_date, r.full_receipt_date,
         COALESCE(r.receipt_count, 0) AS receipt_count, r.arrival_source,
         COALESCE(fr.po_freight_usd, 0) * (po.menge * po.unit_weight_kg) / NULLIF(wt.po_weight_kg, 0) AS freight_alloc_usd,
         COALESCE(d.duty_pct, 0) AS duty_pct
  FROM po
  LEFT JOIN conf c ON c.po_ref = po.ebeln AND c.line_ref = po.ebelp
  JOIN RAW.FX_RATE_MONTHLY fxp ON fxp.currency = po.waers AND fxp.month_start = DATE_TRUNC('month', po.bedat)
  LEFT JOIN rcv r ON r.ebeln = po.ebeln AND r.ebelp = po.ebelp
  LEFT JOIN fr ON fr.po_ref = po.ebeln
  LEFT JOIN wt ON wt.ebeln = po.ebeln
  LEFT JOIN RAW.TRADE_DUTY_RATE d
    ON d.origin_country = po.supplier_country AND d.dest_country = po.plant_country AND d.commodity = po.commodity
),
flags AS (
  SELECT b.*,
    (DATEADD('day', $late_tol, b.confirmed_date) < CURRENT_DATE()) AS due,
    (b.full_receipt_date IS NOT NULL
      AND b.full_receipt_date BETWEEN DATEADD('day', -$early_tol, b.confirmed_date)
                                  AND DATEADD('day',  $late_tol, b.confirmed_date)) AS within_window,
    ROUND(b.received_qty * b.price_usd, 2) AS goods_usd,
    ROUND(IFF(b.received_qty > 0, COALESCE(b.freight_alloc_usd, 0), 0), 2) AS freight_part,
    ROUND(b.received_qty * b.unit_weight_kg * b.handling_usd_per_kg, 2) AS handling_part
  FROM base b
),
costs AS (
  SELECT f.*,
    ROUND(f.goods_usd * f.duty_pct / 100, 2) AS duty_part,
    ROUND(f.goods_usd * $ins_rate / 100, 2) AS insurance_part
  FROM flags f
)
SELECT
  po_line_id,
  ebeln AS po_number, ebelp AS po_item,
  supplier_id, lifnr AS source_vendor_code,
  matnr AS part_id, werks AS plant_id,
  menge AS order_qty_ea,
  netpr::NUMBER(38,4) AS unit_price_local,
  waers AS currency,
  price_usd::NUMBER(38,4) AS unit_price_usd,
  bedat AS po_date,
  eindt AS requested_date,
  confirmed_date,
  confirmed_date_source,
  DATE_TRUNC('month', confirmed_date) AS confirmed_month,
  YEAR(confirmed_date) || '-Q' || QUARTER(confirmed_date) AS confirmed_quarter,
  'FY' || YEAR(DATEADD('month', -3, confirmed_date)) || '-Q' || QUARTER(DATEADD('month', -3, confirmed_date)) AS confirmed_fiscal_quarter,
  received_qty AS received_qty_ea,
  first_arrival_date,
  last_arrival_date AS receipt_date,
  YEAR(last_arrival_date) || '-Q' || QUARTER(last_arrival_date) AS receipt_quarter,
  full_receipt_date,
  receipt_count,
  arrival_source,
  DATEDIFF('day', confirmed_date, full_receipt_date) AS days_late,
  due AS is_due,
  IFF(due, 1, 0) AS due_line_flag,
  IFF(due AND within_window, 1, 0) AS on_time_line_flag,
  CASE WHEN NOT due THEN 'NOT_YET_DUE'
       WHEN within_window THEN 'ON_TIME'
       WHEN full_receipt_date IS NULL THEN 'OPEN_OVERDUE'
       WHEN full_receipt_date < DATEADD('day', -$early_tol, confirmed_date) THEN 'EARLY'
       ELSE 'LATE' END AS delivery_status,
  goods_usd::NUMBER(18,2) AS goods_value_usd,
  freight_part::NUMBER(18,2) AS freight_usd,
  duty_part::NUMBER(18,2) AS duty_usd,
  insurance_part::NUMBER(18,2) AS insurance_usd,
  handling_part::NUMBER(18,2) AS handling_usd,
  (goods_usd + freight_part + duty_part + insurance_part + handling_part)::NUMBER(18,2) AS landed_cost_usd
FROM costs;

-- ---------------------------------------------------------------------
-- FCT_INVENTORY_POSITION: month-end stock with trailing COGS for DOI
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE FCT_INVENTORY_POSITION COMMENT = 'Month-end inventory position with trailing-window COGS' AS
WITH inv AS (
  SELECT s.snapshot_date, s.site_code AS plant_id, s.sku AS part_id,
         s.on_hand_qty, s.in_transit_qty, p.std_cost_usd
  FROM RAW.WMS_INVENTORY_SNAPSHOT s
  JOIN DIM_PART p ON p.part_id = s.sku
),
cogs AS (
  SELECT i.snapshot_date, i.plant_id, i.part_id, COALESCE(SUM(f.cogs_usd), 0) AS cogs_window_usd
  FROM inv i
  LEFT JOIN FCT_SHIPMENT f
    ON f.plant_id = i.plant_id AND f.part_id = i.part_id
   AND f.ship_date >  DATEADD('day', -$doi_window, i.snapshot_date)
   AND f.ship_date <= i.snapshot_date
  GROUP BY i.snapshot_date, i.plant_id, i.part_id
)
SELECT
  i.snapshot_date || '|' || i.plant_id || '|' || i.part_id AS inventory_position_id,
  i.snapshot_date,
  DATE_TRUNC('month', i.snapshot_date) AS snapshot_month,
  i.plant_id, i.part_id,
  i.on_hand_qty AS on_hand_qty_ea,
  i.in_transit_qty AS in_transit_qty_ea,
  ROUND(i.on_hand_qty * i.std_cost_usd, 2)::NUMBER(18,2) AS inventory_value_usd,
  ROUND(i.in_transit_qty * i.std_cost_usd, 2)::NUMBER(18,2) AS in_transit_value_usd,
  c.cogs_window_usd::NUMBER(18,2) AS cogs_window_usd,
  ROUND(c.cogs_window_usd / $doi_window, 4)::NUMBER(18,4) AS avg_daily_cogs_usd,
  (i.snapshot_date = MAX(i.snapshot_date) OVER ()) AS is_latest_snapshot
FROM inv i
JOIN cogs c ON c.snapshot_date = i.snapshot_date AND c.plant_id = i.plant_id AND c.part_id = i.part_id;

-- Sanity checks
SELECT 'suppliers with >1 source id' AS check_name, COUNT(*) AS n FROM DIM_SUPPLIER WHERE source_record_count > 2
UNION ALL SELECT 'po lines unmapped to golden supplier',
  (SELECT COUNT(*) FROM RAW.ERP_PO_ITEM) - (SELECT COUNT(*) FROM FCT_PO_LINE)
UNION ALL SELECT 'order lines', COUNT(*) FROM FCT_ORDER_LINE
UNION ALL SELECT 'BOX shipments converted', COUNT(*) FROM FCT_SHIPMENT WHERE source_uom = 'BOX';
