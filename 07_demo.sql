-- =====================================================================
-- 07_demo.sql
-- Part A builds the "before" state: each team's legacy logic, straight
-- off raw tables, for Chennai last quarter. They disagree.
-- Part B proves the "after" state: every persona role gets the same
-- governed number, while seeing different plants and price columns.
-- =====================================================================
USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
USE DATABASE SC_ONTOLOGY;

-- ---------------------------------------------------------------------
-- Part A: legacy logic per team
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW LEGACY.V_FILL_RATE_BY_TEAM AS
WITH lq AS (
  SELECT DATE_TRUNC('quarter', DATEADD('quarter', -1, CURRENT_DATE())) AS q_start,
         DATE_TRUNC('quarter', CURRENT_DATE()) AS q_end
),
pod AS (
  SELECT s.order_ref, s.order_line_ref,
         SUM(IFF(TO_DATE(s.delivered_ts_utc) <= so.edatu, s.qty_shipped, 0)) AS pod_qty_by_commit
  FROM RAW.TMS_SHIPMENT s
  JOIN RAW.ERP_SO_ITEM so ON so.vbeln = s.order_ref AND so.posnr = s.order_line_ref
  GROUP BY s.order_ref, s.order_line_ref
)
SELECT 'Unit fill rate' AS metric, 'Planning (legacy)' AS source,
       'ERP goods-issue qty / ordered qty; lines chosen by ORDER date; lateness ignored' AS logic,
       (SUM(so.gi_qty) / NULLIF(SUM(so.kwmeng), 0))::FLOAT AS value
FROM RAW.ERP_SO_ITEM so CROSS JOIN lq
WHERE so.werks = 'IN01' AND so.audat >= lq.q_start AND so.audat < lq.q_end
UNION ALL
SELECT 'Unit fill rate', 'Logistics (legacy)',
       'Units with proof of delivery (UTC date) by commit date / ordered qty; TMS quantities as recorded',
       (SUM(COALESCE(p.pod_qty_by_commit, 0)) / NULLIF(SUM(so.kwmeng), 0))::FLOAT
FROM RAW.ERP_SO_ITEM so CROSS JOIN lq
LEFT JOIN pod p ON p.order_ref = so.vbeln AND p.order_line_ref = so.posnr
WHERE so.werks = 'IN01' AND so.edatu >= lq.q_start AND so.edatu < lq.q_end
UNION ALL
SELECT 'Unit fill rate', 'Procurement / S&OP deck (legacy)',
       'Share of order LINES fully shipped at any time (a line count labelled as fill rate)',
       (COUNT_IF(so.gi_qty >= so.kwmeng) / NULLIF(COUNT(*), 0))::FLOAT
FROM RAW.ERP_SO_ITEM so CROSS JOIN lq
WHERE so.werks = 'IN01' AND so.edatu >= lq.q_start AND so.edatu < lq.q_end;

CREATE OR REPLACE VIEW LEGACY.V_SUPPLIER_OTD_BY_TEAM AS
WITH lq AS (
  SELECT DATE_TRUNC('quarter', DATEADD('quarter', -1, CURRENT_DATE())) AS q_start,
         DATE_TRUNC('quarter', CURRENT_DATE()) AS q_end
),
conf AS (
  SELECT po_ref, line_ref, MAX_BY(confirmed_delivery_date, confirmed_at) AS confirmed_date
  FROM RAW.PORTAL_PO_CONFIRMATION GROUP BY po_ref, line_ref
),
gate AS (
  SELECT SPLIT_PART(asn_ref, '-', 1) AS ebeln, TO_NUMBER(SPLIT_PART(asn_ref, '-', 2)) AS ebelp,
         MIN(event_ts_utc) AS first_gate_utc
  FROM RAW.IOT_GATE_EVENT GROUP BY 1, 2
),
gr1 AS (SELECT ebeln, ebelp, MIN(budat) AS first_gr FROM RAW.ERP_GOODS_RECEIPT GROUP BY ebeln, ebelp)
SELECT 'Supplier OTD' AS metric, 'Procurement (legacy)' AS source,
       'Each goods-receipt document posted within 3 days of the REQUESTED date; partial receipts scored separately' AS logic,
       (COUNT_IF(gr.budat <= DATEADD('day', 3, po.eindt)) / NULLIF(COUNT(*), 0))::FLOAT AS value
FROM RAW.ERP_GOODS_RECEIPT gr
JOIN RAW.ERP_PO_ITEM po ON po.ebeln = gr.ebeln AND po.ebelp = gr.ebelp
CROSS JOIN lq
WHERE po.werks = 'IN01' AND po.eindt >= lq.q_start AND po.eindt < lq.q_end
UNION ALL
SELECT 'Supplier OTD', 'Logistics (legacy)',
       'First RFID gate-in (UTC date) on or before the confirmed date, zero tolerance; lines without a gate read dropped',
       (COUNT_IF(TO_DATE(g.first_gate_utc) <= c.confirmed_date) / NULLIF(COUNT(*), 0))::FLOAT
FROM RAW.ERP_PO_ITEM po
JOIN conf c ON c.po_ref = po.ebeln AND c.line_ref = po.ebelp
JOIN gate g ON g.ebeln = po.ebeln AND g.ebelp = po.ebelp
CROSS JOIN lq
WHERE po.werks = 'IN01' AND c.confirmed_date >= lq.q_start AND c.confirmed_date < lq.q_end
UNION ALL
SELECT 'Supplier OTD', 'Planning (legacy)',
       'First receipt within 5 days of confirmed (or requested) date; lines chosen by PO date',
       (COUNT_IF(g1.first_gr <= DATEADD('day', 5, COALESCE(c.confirmed_date, po.eindt))) / NULLIF(COUNT(*), 0))::FLOAT
FROM RAW.ERP_PO_ITEM po
LEFT JOIN conf c ON c.po_ref = po.ebeln AND c.line_ref = po.ebelp
JOIN gr1 g1 ON g1.ebeln = po.ebeln AND g1.ebelp = po.ebelp
CROSS JOIN lq
WHERE po.werks = 'IN01' AND po.bedat >= lq.q_start AND po.bedat < lq.q_end;

CREATE OR REPLACE VIEW GOVERNED.V_BEFORE_AFTER AS
SELECT metric, source, logic, value FROM LEGACY.V_FILL_RATE_BY_TEAM
UNION ALL
SELECT metric, source, logic, value FROM LEGACY.V_SUPPLIER_OTD_BY_TEAM
UNION ALL
SELECT IFF(metric_id = 'unit_fill_rate', 'Unit fill rate', 'Supplier OTD'),
       'Canonical (every persona)',
       'Certified semantic view metric ' || metric_id,
       value
FROM GOVERNED.V_CANONICAL_SCORECARD
WHERE metric_id IN ('unit_fill_rate', 'supplier_otd');

-- The before/after table for the pitch
SELECT metric, source, ROUND(value * 100, 1) AS pct, logic
FROM GOVERNED.V_BEFORE_AFTER
ORDER BY metric, source;

-- ---------------------------------------------------------------------
-- Part B: switch roles, same answer
-- (Run statement by statement in a worksheet, or ask CoCo to run each
--  block with the named role.)
-- ---------------------------------------------------------------------
USE ROLE SC_PLANNING;    USE WAREHOUSE SC_WH;
SELECT CURRENT_ROLE() AS persona, metric_id, ROUND(value, 4) AS value FROM SC_ONTOLOGY.GOVERNED.V_CANONICAL_SCORECARD;

USE ROLE SC_PROCUREMENT; USE WAREHOUSE SC_WH;
SELECT CURRENT_ROLE() AS persona, metric_id, ROUND(value, 4) AS value FROM SC_ONTOLOGY.GOVERNED.V_CANONICAL_SCORECARD;

USE ROLE SC_LOGISTICS;   USE WAREHOUSE SC_WH;
SELECT CURRENT_ROLE() AS persona, metric_id, ROUND(value, 4) AS value FROM SC_ONTOLOGY.GOVERNED.V_CANONICAL_SCORECARD;

-- Same definition, different entitlement
USE ROLE SC_LOGISTICS;
SELECT plant_id, COUNT(*) AS po_lines_visible FROM SC_ONTOLOGY.CONFORMED.FCT_PO_LINE GROUP BY plant_id ORDER BY plant_id;
SELECT po_line_id, unit_price_usd, landed_cost_usd FROM SC_ONTOLOGY.CONFORMED.FCT_PO_LINE WHERE plant_id = 'IN01' LIMIT 5;  -- price masked

USE ROLE SC_PROCUREMENT;
SELECT plant_id, COUNT(*) AS po_lines_visible FROM SC_ONTOLOGY.CONFORMED.FCT_PO_LINE GROUP BY plant_id ORDER BY plant_id;
SELECT po_line_id, unit_price_usd, landed_cost_usd FROM SC_ONTOLOGY.CONFORMED.FCT_PO_LINE WHERE plant_id = 'IN01' LIMIT 5;  -- price visible

USE ROLE SC_ADMIN;
