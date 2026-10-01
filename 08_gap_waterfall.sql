-- =====================================================================
-- 08_gap_waterfall.sql
-- Explains the gap between a team's legacy number and the certified
-- number, one ontology rule at a time (Chennai, last completed quarter).
--   Supplier OTD: Procurement legacy -> certified supplier_otd
--   Unit fill rate: Planning legacy  -> certified unit_fill_rate
-- Each step applies ONE more rule on top of the previous step. The last
-- step is computed exactly the way the semantic view metric is, so it
-- must equal V_CANONICAL_SCORECARD (checked at the end).
-- Run as SC_ADMIN after 07_demo.sql.
-- =====================================================================
USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
USE DATABASE SC_ONTOLOGY;

CREATE OR REPLACE VIEW SC_ONTOLOGY.GOVERNED.V_GAP_WATERFALL
  COMMENT = 'Legacy-to-certified gap, one ontology rule per step (Chennai, last quarter)'
AS
WITH lq AS (
  SELECT DATE_TRUNC('quarter', DATEADD('quarter', -1, CURRENT_DATE())) AS q_start,
         DATE_TRUNC('quarter', CURRENT_DATE()) AS q_end
),
prm AS (
  SELECT MAX(IFF(param_name = 'SUPPLIER_OTD_EARLY_TOLERANCE_DAYS', param_value, NULL))::INT AS early_tol,
         MAX(IFF(param_name = 'SUPPLIER_OTD_LATE_TOLERANCE_DAYS',  param_value, NULL))::INT AS late_tol
  FROM SC_ONTOLOGY.GOVERNED.METRIC_PARAMETER
),
-- ---------------- Supplier OTD building blocks ----------------
po AS (
  SELECT i.ebeln, i.ebelp, i.menge, i.eindt,
         f.confirmed_date, f.full_receipt_date AS full_arrival_date,
         f.due_line_flag, f.on_time_line_flag
  FROM SC_ONTOLOGY.RAW.ERP_PO_ITEM i
  JOIN SC_ONTOLOGY.CONFORMED.FCT_PO_LINE f
    ON f.po_number = i.ebeln AND f.po_item = i.ebelp
  WHERE i.werks = 'IN01'
),
gr_cum AS (
  SELECT g.ebeln, g.ebelp, g.budat,
         SUM(g.menge) OVER (PARTITION BY g.ebeln, g.ebelp ORDER BY g.budat, g.receipt_seq
                            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cum_qty
  FROM SC_ONTOLOGY.RAW.ERP_GOODS_RECEIPT g
),
gr_full AS (   -- date the full quantity was posted in the ERP
  SELECT c.ebeln, c.ebelp, MIN(IFF(c.cum_qty >= p.menge, c.budat, NULL)) AS full_gr_date
  FROM gr_cum c
  JOIN po p ON p.ebeln = c.ebeln AND p.ebelp = c.ebelp
  GROUP BY c.ebeln, c.ebelp
),
line AS (
  SELECT p.*, g.full_gr_date
  FROM po p LEFT JOIN gr_full g ON g.ebeln = p.ebeln AND g.ebelp = p.ebelp
),
sotd AS (
  SELECT 'Supplier OTD' AS metric, 0 AS step_no,
         'Procurement legacy' AS step_label,
         'Starting point: each goods-receipt document, posted within 3 days of the requested date' AS rule_applied,
         value
  FROM SC_ONTOLOGY.LEGACY.V_SUPPLIER_OTD_BY_TEAM
  WHERE source = 'Procurement (legacy)'
  UNION ALL
  SELECT 'Supplier OTD', 1, 'Score PO lines, full quantity only',
         'Each PO line counts once and is on time only when its full quantity has arrived; partial deliveries and unreceived lines count as late',
         (COUNT_IF(l.full_gr_date <= DATEADD('day', 3, l.eindt)) / NULLIF(COUNT(*), 0))::FLOAT
  FROM line l, lq
  WHERE l.eindt >= lq.q_start AND l.eindt < lq.q_end
  UNION ALL
  SELECT 'Supplier OTD', 2, 'Use the supplier-confirmed date',
         'Measure against the date the supplier confirmed in the portal, not the buyer''s requested date',
         (COUNT_IF(l.full_gr_date <= DATEADD('day', 3, l.confirmed_date)) / NULLIF(COUNT(*), 0))::FLOAT
  FROM line l, lq
  WHERE l.confirmed_date >= lq.q_start AND l.confirmed_date < lq.q_end
  UNION ALL
  SELECT 'Supplier OTD', 3, 'Use physical arrival (IoT gate-in)',
         'Use the RFID gate-in date in plant time; fall back to the goods-receipt posting only when there is no gate read',
         (COUNT_IF(l.full_arrival_date <= DATEADD('day', 3, l.confirmed_date)) / NULLIF(COUNT(*), 0))::FLOAT
  FROM line l, lq
  WHERE l.confirmed_date >= lq.q_start AND l.confirmed_date < lq.q_end
  UNION ALL
  SELECT 'Supplier OTD', 4, 'Apply the governed window',
         'Apply the governed window (-' || MAX(prm.early_tol) || ' / +' || MAX(prm.late_tol)
           || ' days) and count only lines that are due',
         (SUM(l.on_time_line_flag) / NULLIF(SUM(l.due_line_flag), 0))::FLOAT
  FROM line l, lq, prm
  WHERE l.confirmed_date >= lq.q_start AND l.confirmed_date < lq.q_end
),
-- ---------------- Unit fill rate ----------------
ufr AS (
  SELECT 'Unit fill rate' AS metric, 0 AS step_no,
         'Planning legacy' AS step_label,
         'Starting point: ERP goods-issue quantity / ordered quantity, lines chosen by order date, lateness ignored' AS rule_applied,
         value
  FROM SC_ONTOLOGY.LEGACY.V_FILL_RATE_BY_TEAM
  WHERE source = 'Planning (legacy)'
  UNION ALL
  SELECT 'Unit fill rate', 1, 'Select lines by committed date',
         'A quarter''s fill rate covers the orders promised in that quarter, not the orders placed in it',
         (SUM(so.gi_qty) / NULLIF(SUM(so.kwmeng), 0))::FLOAT
  FROM SC_ONTOLOGY.RAW.ERP_SO_ITEM so, lq
  WHERE so.werks = 'IN01' AND so.edatu >= lq.q_start AND so.edatu < lq.q_end
  UNION ALL
  SELECT 'Unit fill rate', 2, 'Count only units shipped by the committed date',
         'Units shipped late do not fill the order; shipped quantity is in units (boxes converted), plant-local date, capped at the ordered quantity',
         (SUM(LEAST(o.shipped_by_commit_qty_ea, o.order_qty_ea)) / NULLIF(SUM(o.order_qty_ea), 0))::FLOAT
  FROM SC_ONTOLOGY.CONFORMED.FCT_ORDER_LINE o, lq
  WHERE o.plant_id = 'IN01' AND o.commit_date >= lq.q_start AND o.commit_date < lq.q_end
  UNION ALL
  SELECT 'Unit fill rate', 3, 'Count due lines only',
         'Count only lines that are due (commit date in the past)',
         (SUM(o.due_shipped_by_commit_qty_ea) / NULLIF(SUM(o.due_order_qty_ea), 0))::FLOAT
  FROM SC_ONTOLOGY.CONFORMED.FCT_ORDER_LINE o, lq
  WHERE o.plant_id = 'IN01' AND o.commit_date >= lq.q_start AND o.commit_date < lq.q_end
)
SELECT s.metric, s.step_no, s.step_label, s.rule_applied, s.value,
       s.value - LAG(s.value) OVER (PARTITION BY s.metric ORDER BY s.step_no) AS delta,
       s.step_no = MAX(s.step_no) OVER (PARTITION BY s.metric) AS is_certified
FROM (SELECT * FROM sotd UNION ALL SELECT * FROM ufr) s;

-- ---------------------------------------------------------------------
-- Checks
-- ---------------------------------------------------------------------
SELECT metric, step_no, step_label, ROUND(value * 100, 1) AS pct, ROUND(delta * 100, 1) AS delta_pts
FROM SC_ONTOLOGY.GOVERNED.V_GAP_WATERFALL
ORDER BY metric, step_no;

-- The last step of each waterfall must equal the certified scorecard value
SELECT w.metric, w.value AS waterfall_end, c.value AS certified,
       IFF(ABS(w.value - c.value) < 0.00001, 'PASS', 'FAIL') AS status
FROM SC_ONTOLOGY.GOVERNED.V_GAP_WATERFALL w
JOIN SC_ONTOLOGY.GOVERNED.V_CANONICAL_SCORECARD c
  ON c.metric_id = IFF(w.metric = 'Supplier OTD', 'supplier_otd', 'unit_fill_rate')
WHERE w.is_certified;
