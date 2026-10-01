-- =====================================================================
-- 02_raw_sources.sql
-- Simulated source systems, with the messiness real supply chains have:
--   * ERP (SAP-style cryptic columns), supplier portal, TMS, WMS, IoT gate readers
--   * 5 suppliers exist under two ERP vendor codes (duplicate payee records),
--     and every supplier has a different ID again in the supplier portal
--   * Supplier-confirmed dates live in the portal, not the ERP
--   * Goods-receipt posting lags physical arrival (IoT gate-in) by 0-3 days
--   * Mexico plant has no RFID gate readers; ~5% of reads are missing elsewhere
--   * TMS records some Japan/UK shipments in BOX (10 EA), ERP is in EA
--   * TMS ship timestamps are plant-local, POD timestamps are UTC
--   * PO prices and freight are in local currency (INR, JPY, GBP, USD)
-- Data is deterministic (hash-based) and anchored to CURRENT_DATE so
-- "last quarter" always has data. Runtime on XS: about a minute.
-- =====================================================================
USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
USE DATABASE SC_ONTOLOGY;
USE SCHEMA RAW;

-- ---------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE ERP_PLANT COMMENT = 'ERP plant master (T001W-like) plus site config' AS
SELECT column1::STRING AS werks, column2::STRING AS plant_name, column3::STRING AS city,
       column4::STRING AS country_code, column5::STRING AS region, column6::STRING AS time_zone,
       column7::STRING AS local_currency, column8::NUMBER(10,4) AS handling_usd_per_kg,
       column9::BOOLEAN AS has_rfid_gate
FROM VALUES
  ('IN01', 'Chennai Assembly',        'Chennai',        'IN', 'APAC',     'Asia/Kolkata',        'INR', 0.06, TRUE),
  ('JP01', 'Oppama Assembly',         'Yokosuka',       'JP', 'APAC',     'Asia/Tokyo',          'JPY', 0.12, TRUE),
  ('GB01', 'Sunderland Assembly',     'Sunderland',     'GB', 'AMIEO',    'Europe/London',       'GBP', 0.10, TRUE),
  ('US01', 'Smyrna Assembly',         'Smyrna',         'US', 'AMERICAS', 'America/Chicago',     'USD', 0.11, TRUE),
  ('MX01', 'Aguascalientes Assembly', 'Aguascalientes', 'MX', 'AMERICAS', 'America/Mexico_City', 'USD', 0.05, FALSE);

CREATE OR REPLACE TABLE FX_RATE_MONTHLY COMMENT = 'Treasury monthly average rates, USD per 1 unit of currency' AS
WITH m AS (
  SELECT DATEADD('month', 1 - ROW_NUMBER() OVER (ORDER BY SEQ4()), DATE_TRUNC('month', CURRENT_DATE())) AS month_start
  FROM TABLE(GENERATOR(ROWCOUNT => 20))
), c AS (
  SELECT column1::STRING AS currency, column2::FLOAT AS base_usd
  FROM VALUES ('USD', 1.0), ('INR', 0.0119), ('JPY', 0.0068), ('GBP', 1.27), ('EUR', 1.08)
)
SELECT m.month_start, c.currency,
       ROUND(c.base_usd * IFF(c.currency = 'USD', 1, 1 + (MOD(ABS(HASH(m.month_start, c.currency)), 61) - 30) / 1000), 6)::NUMBER(18,6) AS usd_per_unit
FROM m CROSS JOIN c;

CREATE OR REPLACE TABLE ERP_VENDOR_MASTER COMMENT = 'ERP vendor master (LFA1-like). Contains duplicate payee records.' AS
WITH g AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n FROM TABLE(GENERATOR(ROWCOUNT => 40))),
b AS (
  SELECT n,
    ARRAY_CONSTRUCT('Apex','Sakura','Delta','Nova','Orion','Vertex','Kaveri','Summit','Midland','Pioneer')[MOD(n,10)]::STRING
      || ' ' || ARRAY_CONSTRUCT('Components','Castings','Electronics','Plastics','Steel','Seating','Glass','Rubber')[MOD(n,8)]::STRING AS nm,
    ARRAY_CONSTRUCT('IN','JP','CN','DE','US','MX','GB','TH')[MOD(n*3,8)]::STRING AS land1,
    IFF(MOD(n,4) = 0, 'TIER_2', 'TIER_1') AS zz_tier,
    'TAX' || LPAD(MOD(n*7919, 1000000), 7, '0') AS stcd1
  FROM g
)
SELECT 'V1' || LPAD(n,4,'0') AS lifnr, nm || ' Ltd' AS name1, land1, stcd1, 'PRIMARY' AS ktokk, zz_tier FROM b
UNION ALL
SELECT 'V9' || LPAD(n,4,'0'), nm || ' Ltd - Pay Addr 2', land1, stcd1, 'ALT_PAYEE', zz_tier FROM b WHERE n IN (3,7,11,19,23);

CREATE OR REPLACE TABLE PORTAL_VENDOR COMMENT = 'Supplier collaboration portal vendor list (own IDs, no ERP key)' AS
SELECT 'PV-' || LPAD(1000 + TO_NUMBER(SUBSTR(lifnr,3)) * 13, 5, '0') AS portal_vendor_id,
       UPPER(REPLACE(name1, ' Ltd', '')) AS vendor_display_name,
       stcd1 AS tax_registration,
       'ACTIVE' AS onboarding_status
FROM ERP_VENDOR_MASTER WHERE ktokk = 'PRIMARY';

CREATE OR REPLACE TABLE ERP_MATERIAL_MASTER COMMENT = 'ERP material master (MARA/MBEW-like)' AS
WITH g AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n FROM TABLE(GENERATOR(ROWCOUNT => 200))),
b AS (SELECT n, MOD(n,5) AS ci, MOD(FLOOR(n/5),3) AS ki FROM g)
SELECT 'M' || LPAD(n,6,'0') AS matnr,
  ARRAY_CONSTRUCT(
    ARRAY_CONSTRUCT('Wiring Harness','ECU','Battery Module'),
    ARRAY_CONSTRUCT('Transmission Parts','Engine Castings','Exhaust'),
    ARRAY_CONSTRUCT('Stampings','Glass','Fasteners'),
    ARRAY_CONSTRUCT('Seating','Trim','HVAC Module'),
    ARRAY_CONSTRUCT('Brakes','Suspension','Wheels and Tyres'))[ci][ki]::STRING || ' Assy ' || LPAD(n,4,'0') AS maktx,
  ARRAY_CONSTRUCT('Electrical','Powertrain','Body','Interior','Chassis')[ci]::STRING AS zz_commodity,
  ARRAY_CONSTRUCT(
    ARRAY_CONSTRUCT('Wiring Harness','ECU','Battery Module'),
    ARRAY_CONSTRUCT('Transmission Parts','Engine Castings','Exhaust'),
    ARRAY_CONSTRUCT('Stampings','Glass','Fasteners'),
    ARRAY_CONSTRUCT('Seating','Trim','HVAC Module'),
    ARRAY_CONSTRUCT('Brakes','Suspension','Wheels and Tyres'))[ci][ki]::STRING AS zz_category,
  ROUND(5 + MOD(ABS(HASH(n,'cost')), 49500) / 100, 2)::NUMBER(18,4) AS stprs_usd,
  ROUND(0.2 + MOD(ABS(HASH(n,'wt')), 2500) / 100, 2)::NUMBER(18,3) AS brgew_kg,
  10 AS pack_qty,
  'EA' AS meins
FROM b;

CREATE OR REPLACE TABLE ERP_CUSTOMER_MASTER COMMENT = 'ERP customer master (KNA1-like)' AS
WITH g AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n FROM TABLE(GENERATOR(ROWCOUNT => 80)))
SELECT 'C' || LPAD(n,6,'0') AS kunnr,
  ARRAY_CONSTRUCT('Metro','Coastal','Highway','Capital','Harbour','Summit','Central','Riverside')[MOD(n,8)]::STRING || ' ' ||
  ARRAY_CONSTRUCT('Motors','Auto Group','Fleet Services','Mobility','Dealership','Vehicle Distributors','Car Care','Autohaus','Automotive','Traders')[MOD(n,10)]::STRING
    || IFF(n > 40, ' II', '') AS name1,
  ARRAY_CONSTRUCT('IN','JP','GB','US','MX','DE','AE','AU')[MOD(n*5,8)]::STRING AS land1,
  ARRAY_CONSTRUCT('Dealer','Fleet','Export Distributor','Aftersales Service')[MOD(n*3,4)]::STRING AS kdgrp
FROM g;

CREATE OR REPLACE TABLE TMS_CARRIER COMMENT = 'Transport management system carrier list' AS
SELECT column1::STRING AS carrier_code, column2::STRING AS carrier_name, column3::STRING AS transport_mode
FROM VALUES ('BDL','BlueDart Logistics','Road'), ('TCI','TCI Express','Road'), ('VRL','VRL Logistics','Road'),
            ('DHL','DHL Supply Chain','Road'), ('YMT','Yamato Transport','Road'), ('KWE','Kintetsu World Express','Air'),
            ('DBS','DB Schenker','Road'), ('XPO','XPO Logistics','Road');

CREATE OR REPLACE TABLE TRADE_DUTY_RATE COMMENT = 'Customs duty % by origin, destination and commodity' AS
SELECT o.c AS origin_country, d.country_code AS dest_country, cm.c AS commodity,
       IFF(o.c = d.country_code, 0, (MOD(ABS(HASH(o.c, d.country_code, cm.c)), 96) + 25) / 10)::NUMBER(6,2) AS duty_pct
FROM (SELECT column1::STRING AS c FROM VALUES ('IN'),('JP'),('CN'),('DE'),('US'),('MX'),('GB'),('TH')) o
CROSS JOIN ERP_PLANT d
CROSS JOIN (SELECT column1::STRING AS c FROM VALUES ('Electrical'),('Powertrain'),('Body'),('Interior'),('Chassis')) cm;

-- ---------------------------------------------------------------------
-- Inbound: purchase orders, supplier confirmations, receipts, gate reads
-- ---------------------------------------------------------------------
CREATE OR REPLACE TRANSIENT TABLE SIM_PO AS
WITH g AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n FROM TABLE(GENERATOR(ROWCOUNT => 12000))),
hdr AS (
  SELECT n, CEIL(n/4) AS po_seq, MOD(n-1,4) + 1 AS item_no,
         MOD(ABS(HASH(CEIL(n/4),'sup')), 40) + 1 AS s,
         MOD(ABS(HASH(CEIL(n/4),'plant')), 100) AS plant_b,
         MOD(ABS(HASH(CEIL(n/4),'alt')), 100) AS alt_b,
         DATEADD('day', -(20 + MOD(ABS(HASH(CEIL(n/4),'podate')), 380)), CURRENT_DATE()) AS po_date
  FROM g
),
ln AS (
  SELECT h.*,
    MOD(23 * (s - 1), 40) AS r,                      -- picks a material whose preferred supplier is s
    MOD(ABS(HASH(n,'matk')), 5) AS k,
    (MOD(ABS(HASH(n,'qty')), 95) + 5) * 10 AS order_qty,
    MOD(ABS(HASH(n,'lead')), 47) + 14 AS lead_days,
    MOD(ABS(HASH(n,'px')), 21) - 10 AS px_var_pct,
    MOD(ABS(HASH(n,'conf')), 100) AS conf_b,
    MOD(ABS(HASH(n,'shift')), 10) - 2 AS conf_shift,
    MOD(ABS(HASH(n,'ot')), 100) AS ot_b,
    MOD(ABS(HASH(n,'early')), 5) - 3 AS ontime_offset,
    MOD(ABS(HASH(n,'late')), 18) + 3 AS late_offset,
    MOD(ABS(HASH(n,'part')), 100) AS partial_b,
    MOD(ABS(HASH(n,'pq')), 31) AS partial_pct_add,
    MOD(ABS(HASH(n,'gap')), 12) + 4 AS second_gap,
    MOD(ABS(HASH(n,'grlag1')), 4) AS gr_lag1,
    MOD(ABS(HASH(n,'grlag2')), 4) AS gr_lag2,
    MOD(ABS(HASH(n,'hr')), 15) + 6 AS gate_hr,
    MOD(ABS(HASH(n,'mi')), 60) AS gate_mi,
    MOD(ABS(HASH(n,'iotdrop')), 100) AS iot_drop_b
  FROM hdr h
)
SELECT
  ln.*,
  '45' || LPAD(po_seq, 8, '0') AS po_number,
  item_no * 10 AS po_item,
  IFF(s IN (3,7,11,19,23) AND alt_b < 35, 'V9', 'V1') || LPAD(s, 4, '0') AS lifnr,
  'M' || LPAD(IFF(r = 0, 40 * (k + 1), r + 40 * k), 6, '0') AS matnr,
  CASE WHEN plant_b < 30 THEN 'IN01' WHEN plant_b < 50 THEN 'JP01' WHEN plant_b < 68 THEN 'GB01'
       WHEN plant_b < 86 THEN 'US01' ELSE 'MX01' END AS werks,
  DATEADD('day', lead_days, po_date) AS requested_date,
  conf_b < 90 AS is_confirmed,
  DATEADD('day', lead_days + conf_shift, po_date) AS confirmed_date
FROM ln;

CREATE OR REPLACE TRANSIENT TABLE SIM_PO2 AS
SELECT p.*, pl.local_currency, pl.time_zone, pl.has_rfid_gate, m.stprs_usd, m.brgew_kg,
  (p.ot_b < 68 + MOD(p.s * 17, 30)) AS will_be_on_time,     -- supplier-level reliability 68-97%
  (p.partial_b < 8) AS is_partial,
  DATEADD('day',
          IFF(p.ot_b < 68 + MOD(p.s * 17, 30), p.ontime_offset, p.late_offset),
          IFF(p.is_confirmed, p.confirmed_date, p.requested_date)) AS arrival1_date
FROM SIM_PO p
JOIN ERP_PLANT pl ON pl.werks = p.werks
JOIN ERP_MATERIAL_MASTER m ON m.matnr = p.matnr;

CREATE OR REPLACE TABLE ERP_PO_ITEM COMMENT = 'ERP purchase order items (EKPO-like). Quantities in EA, prices in plant currency.' AS
SELECT p.po_number AS ebeln, p.po_item AS ebelp, p.lifnr, p.matnr, p.werks,
       p.order_qty::NUMBER(18,3) AS menge, 'EA' AS meins,
       ROUND(p.stprs_usd * (1 + p.px_var_pct / 100) / fx.usd_per_unit, 2)::NUMBER(18,4) AS netpr,
       p.local_currency AS waers, p.po_date AS bedat, p.requested_date AS eindt
FROM SIM_PO2 p
JOIN FX_RATE_MONTHLY fx ON fx.currency = p.local_currency AND fx.month_start = DATE_TRUNC('month', p.po_date);

CREATE OR REPLACE TABLE PORTAL_PO_CONFIRMATION COMMENT = 'Supplier-confirmed delivery dates from the supplier portal (not in ERP)' AS
SELECT pv.portal_vendor_id, p.po_number AS po_ref, p.po_item AS line_ref,
       p.confirmed_date AS confirmed_delivery_date,
       DATEADD('day', 2, p.po_date)::TIMESTAMP_NTZ AS confirmed_at
FROM SIM_PO2 p
JOIN ERP_VENDOR_MASTER v ON v.lifnr = 'V1' || LPAD(p.s, 4, '0')
JOIN PORTAL_VENDOR pv ON pv.tax_registration = v.stcd1
WHERE p.is_confirmed;

CREATE OR REPLACE TRANSIENT TABLE SIM_RECEIPT AS
WITH r AS (
  SELECT po_number, po_item, 1 AS receipt_seq,
         IFF(is_partial, FLOOR(order_qty * (60 + partial_pct_add) / 1000) * 10, order_qty) AS qty,
         arrival1_date AS arrival_date, gr_lag1 AS gr_lag, gate_hr, gate_mi, werks, time_zone, has_rfid_gate, iot_drop_b
  FROM SIM_PO2
  UNION ALL
  SELECT po_number, po_item, 2,
         order_qty - FLOOR(order_qty * (60 + partial_pct_add) / 1000) * 10,
         DATEADD('day', second_gap, arrival1_date), gr_lag2, gate_hr, gate_mi, werks, time_zone, has_rfid_gate, iot_drop_b
  FROM SIM_PO2 WHERE is_partial
)
SELECT r.*, DATEADD('day', gr_lag, arrival_date) AS gr_posting_date
FROM r
WHERE qty > 0 AND DATEADD('day', gr_lag, arrival_date) <= DATEADD('day', -1, CURRENT_DATE());

CREATE OR REPLACE TABLE ERP_GOODS_RECEIPT COMMENT = 'ERP goods receipts (MSEG 101-like). Posting date lags physical arrival.' AS
SELECT '50' || LPAD(ROW_NUMBER() OVER (ORDER BY po_number, po_item, receipt_seq), 8, '0') AS mblnr,
       po_number AS ebeln, po_item AS ebelp, receipt_seq,
       gr_posting_date AS budat, qty::NUMBER(18,3) AS menge, 'EA' AS meins
FROM SIM_RECEIPT;

CREATE OR REPLACE TABLE IOT_GATE_EVENT COMMENT = 'RFID gate-in reads at plant gates (UTC). No readers at MX01; some reads missing.' AS
SELECT 'EV' || LPAD(ROW_NUMBER() OVER (ORDER BY po_number, po_item, receipt_seq), 9, '0') AS event_id,
       werks AS site_code,
       'RFID-' || werks || '-G' || (MOD(gate_hr, 3) + 1) AS reader_id,
       'GATE_IN' AS event_type,
       po_number || '-' || po_item || '-' || receipt_seq AS asn_ref,
       CONVERT_TIMEZONE(time_zone, 'UTC',
         TIMESTAMP_NTZ_FROM_PARTS(arrival_date, TIME_FROM_PARTS(gate_hr, gate_mi, 0))) AS event_ts_utc
FROM SIM_RECEIPT
WHERE has_rfid_gate AND iot_drop_b >= 5;

CREATE OR REPLACE TABLE TMS_INBOUND_FREIGHT COMMENT = 'Inbound freight invoices per PO (header level, USD)' AS
SELECT 'FI' || LPAD(ROW_NUMBER() OVER (ORDER BY p.po_number), 8, '0') AS freight_invoice_no,
       p.po_number AS po_ref,
       ROUND(SUM(p.order_qty * p.brgew_kg) * IFF(MAX(v.land1) = MAX(pl.country_code), 0.18, 0.85), 2)::NUMBER(18,2) AS freight_amount,
       'USD' AS currency, 'FCA' AS incoterm
FROM SIM_PO2 p
JOIN ERP_VENDOR_MASTER v ON v.lifnr = 'V1' || LPAD(p.s, 4, '0')
JOIN ERP_PLANT pl ON pl.werks = p.werks
WHERE p.po_number IN (SELECT DISTINCT po_number FROM SIM_RECEIPT)
GROUP BY p.po_number;

-- ---------------------------------------------------------------------
-- Outbound: sales orders and shipments
-- ---------------------------------------------------------------------
CREATE OR REPLACE TRANSIENT TABLE SIM_CARRIER_PROFILE AS
SELECT column1::STRING AS carrier_code, column2::NUMBER AS late_pct, column3::STRING AS mode
FROM VALUES ('BDL',6,'Road'), ('TCI',17,'Road'), ('VRL',12,'Road'), ('DHL',8,'Road'),
            ('YMT',5,'Road'), ('KWE',4,'Air'), ('DBS',9,'Road'), ('XPO',13,'Road');

CREATE OR REPLACE TRANSIENT TABLE SIM_SO AS
WITH g AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n FROM TABLE(GENERATOR(ROWCOUNT => 15000))),
x AS (
  SELECT n,
    CEIL(n/3) AS so_seq, MOD(n-1,3) + 1 AS item_no,
    MOD(ABS(HASH(CEIL(n/3),'cust')), 80) + 1 AS c,
    MOD(ABS(HASH(CEIL(n/3),'plant')), 100) AS plant_b,
    DATEADD('day', -(3 + MOD(ABS(HASH(CEIL(n/3),'odate')), 480)), CURRENT_DATE()) AS order_date,
    MOD(ABS(HASH(n,'mat')), 200) + 1 AS mat_n,
    (MOD(ABS(HASH(n,'qty')), 30) + 1) * 10 AS order_qty,
    5 + MOD(ABS(HASH(n,'commit')), 17) AS commit_days,
    MOD(ABS(HASH(n,'sc')), 100) AS sc_b,
    MOD(ABS(HASH(n,'car')), 4) AS car_i,
    MOD(ABS(HASH(n,'dl')), 100) AS dl_b,
    MOD(ABS(HASH(n,'dly')), 6) + 3 AS delay_days,
    MOD(ABS(HASH(n,'tr')), 3) + 1 AS road_transit_days,
    MOD(ABS(HASH(n,'slack')), 3) AS slack_days,
    MOD(ABS(HASH(n,'frac')), 31) AS frac_add,
    MOD(ABS(HASH(n,'bo')), 16) + 5 AS backorder_days,
    MOD(ABS(HASH(n,'gap2')), 10) + 3 AS gap2_days,
    MOD(ABS(HASH(n,'shr')), 16) + 8 AS ship_hr,
    MOD(ABS(HASH(n,'box')), 100) AS box_b
  FROM g
),
y AS (
  SELECT x.*,
    CASE WHEN plant_b < 30 THEN 'IN01' WHEN plant_b < 50 THEN 'JP01' WHEN plant_b < 68 THEN 'GB01'
         WHEN plant_b < 86 THEN 'US01' ELSE 'MX01' END AS werks
  FROM x
)
SELECT y.*,
  '10' || LPAD(so_seq, 8, '0') AS vbeln,
  item_no * 10 AS posnr,
  'C' || LPAD(c, 6, '0') AS kunnr,
  'M' || LPAD(mat_n, 6, '0') AS matnr,
  DATEADD('day', commit_days, order_date) AS commit_date,
  (CASE werks
     WHEN 'IN01' THEN ARRAY_CONSTRUCT('BDL','TCI','VRL','DHL')[car_i]
     WHEN 'JP01' THEN ARRAY_CONSTRUCT('YMT','KWE','DHL','DBS')[car_i]
     WHEN 'GB01' THEN ARRAY_CONSTRUCT('DHL','DBS','XPO','KWE')[car_i]
     ELSE ARRAY_CONSTRUCT('XPO','DHL','DBS','KWE')[car_i] END)::STRING AS carrier_code
FROM y;

-- Shipment legs. Scenarios: A full on time (83%), B short-shipped (4%),
-- C partial + late balance (7%), D back-ordered and shipped late (6%)
CREATE OR REPLACE TRANSIENT TABLE SIM_SHIPMENT AS
WITH base AS (
  SELECT s.*, cp.late_pct, cp.mode, pl.time_zone, pl.local_currency, m.brgew_kg, m.pack_qty,
         IFF(cp.mode = 'Air', 1, s.road_transit_days) AS transit_days,
         IFF(s.dl_b < cp.late_pct, s.delay_days, 0) AS delivery_delay
  FROM SIM_SO s
  JOIN SIM_CARRIER_PROFILE cp ON cp.carrier_code = s.carrier_code
  JOIN ERP_PLANT pl ON pl.werks = s.werks
  JOIN ERP_MATERIAL_MASTER m ON m.matnr = s.matnr
),
legs AS (
  SELECT base.*, 1 AS leg, order_qty AS qty,
         DATEADD('day', -(transit_days + slack_days), commit_date) AS ship_date
  FROM base WHERE sc_b >= 17
  UNION ALL
  SELECT base.*, 1, FLOOR(order_qty * (70 + MOD(frac_add, 21)) / 1000) * 10,
         DATEADD('day', -(transit_days + slack_days), commit_date)
  FROM base WHERE sc_b BETWEEN 13 AND 16
  UNION ALL
  SELECT base.*, 1, FLOOR(order_qty * (50 + frac_add) / 1000) * 10,
         DATEADD('day', -slack_days, commit_date)
  FROM base WHERE sc_b BETWEEN 6 AND 12
  UNION ALL
  SELECT base.*, 2, order_qty - FLOOR(order_qty * (50 + frac_add) / 1000) * 10,
         DATEADD('day', gap2_days, commit_date)
  FROM base WHERE sc_b BETWEEN 6 AND 12
  UNION ALL
  SELECT base.*, 1, order_qty, DATEADD('day', backorder_days, commit_date)
  FROM base WHERE sc_b < 6
)
SELECT legs.*, DATEADD('day', transit_days + delivery_delay, ship_date) AS delivery_date
FROM legs
WHERE qty > 0 AND ship_date <= DATEADD('day', -1, CURRENT_DATE());

CREATE OR REPLACE TABLE TMS_SHIPMENT COMMENT = 'TMS outbound shipments. Ship time is plant-local, POD time is UTC, some qty in BOX.' AS
SELECT 'SH' || LPAD(ROW_NUMBER() OVER (ORDER BY s.vbeln, s.posnr, s.leg), 9, '0') AS shipment_id,
       s.vbeln AS order_ref, s.posnr AS order_line_ref, s.carrier_code, s.werks AS origin_site,
       TIMESTAMP_NTZ_FROM_PARTS(s.ship_date, TIME_FROM_PARTS(s.ship_hr, 15, 0)) AS ship_ts_local,
       IFF(s.delivery_date <= DATEADD('day', -1, CURRENT_DATE()),
           CONVERT_TIMEZONE(s.time_zone, 'UTC', TIMESTAMP_NTZ_FROM_PARTS(s.delivery_date, TIME_FROM_PARTS(10, 30, 0))),
           NULL) AS delivered_ts_utc,
       IFF(s.werks IN ('JP01','GB01') AND s.box_b < 30, s.qty / s.pack_qty, s.qty)::NUMBER(18,3) AS qty_shipped,
       IFF(s.werks IN ('JP01','GB01') AND s.box_b < 30, 'BOX', 'EA') AS qty_uom,
       ROUND(s.qty * s.brgew_kg, 2)::NUMBER(18,2) AS gross_weight_kg,
       ROUND(s.qty * s.brgew_kg * IFF(s.mode = 'Air', 2.10, 0.35) / fx.usd_per_unit, 2)::NUMBER(18,2) AS freight_amount,
       s.local_currency AS freight_currency,
       IFF(s.delivery_date <= DATEADD('day', -1, CURRENT_DATE()), 'POD_RECEIVED', 'IN_TRANSIT') AS pod_status
FROM SIM_SHIPMENT s
JOIN FX_RATE_MONTHLY fx ON fx.currency = s.local_currency AND fx.month_start = DATE_TRUNC('month', s.ship_date);

CREATE OR REPLACE TABLE ERP_SO_ITEM COMMENT = 'ERP sales order items (VBAP/VBEP-like). edatu = committed date, gi_qty = goods issued to date.' AS
SELECT s.vbeln, s.posnr, s.kunnr, s.matnr, s.werks,
       s.order_qty::NUMBER(18,3) AS kwmeng, 'EA' AS vrkme,
       ROUND(m.stprs_usd * 1.35, 2)::NUMBER(18,4) AS netpr_usd,
       s.order_date AS audat, s.commit_date AS edatu,
       COALESCE(g.gi_qty, 0)::NUMBER(18,3) AS gi_qty
FROM SIM_SO s
JOIN ERP_MATERIAL_MASTER m ON m.matnr = s.matnr
LEFT JOIN (SELECT vbeln, posnr, SUM(qty) AS gi_qty FROM SIM_SHIPMENT GROUP BY vbeln, posnr) g
  ON g.vbeln = s.vbeln AND g.posnr = s.posnr;

-- ---------------------------------------------------------------------
-- Inventory: month-end WMS snapshots (12 months)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE WMS_INVENTORY_SNAPSHOT COMMENT = 'WMS month-end stock snapshot per site and SKU, in EA' AS
WITH months AS (
  SELECT LAST_DAY(DATEADD('month', -ROW_NUMBER() OVER (ORDER BY SEQ4()), CURRENT_DATE())) AS snapshot_date
  FROM TABLE(GENERATOR(ROWCOUNT => 12))
),
demand AS (
  SELECT werks, matnr, SUM(qty) / 480 AS avg_daily_units FROM SIM_SHIPMENT GROUP BY werks, matnr
)
SELECT m.snapshot_date, d.werks AS site_code, d.matnr AS sku,
  (CEIL(d.avg_daily_units * (10 + MOD(ABS(HASH(d.werks, d.matnr)), 50))
        * (70 + MOD(ABS(HASH(d.werks, d.matnr, m.snapshot_date)), 61)) / 100 / 10) * 10
   + IFF(MOD(ABS(HASH(d.werks, d.matnr, 'slow')), 100) < 3, 2000, 0))::NUMBER(18,3) AS on_hand_qty,
  (CEIL(d.avg_daily_units * (10 + MOD(ABS(HASH(d.werks, d.matnr, 'it', m.snapshot_date)), 31)) / 10 / 10) * 10)::NUMBER(18,3) AS in_transit_qty,
  'EA' AS uom
FROM months m CROSS JOIN demand d;

-- Clean up simulation scaffolding
DROP TABLE IF EXISTS SIM_PO;
DROP TABLE IF EXISTS SIM_PO2;
DROP TABLE IF EXISTS SIM_RECEIPT;
DROP TABLE IF EXISTS SIM_SO;
DROP TABLE IF EXISTS SIM_SHIPMENT;
DROP TABLE IF EXISTS SIM_CARRIER_PROFILE;

-- Sanity check
SELECT 'ERP_PO_ITEM' AS t, COUNT(*) AS n FROM ERP_PO_ITEM UNION ALL
SELECT 'ERP_GOODS_RECEIPT', COUNT(*) FROM ERP_GOODS_RECEIPT UNION ALL
SELECT 'IOT_GATE_EVENT', COUNT(*) FROM IOT_GATE_EVENT UNION ALL
SELECT 'ERP_SO_ITEM', COUNT(*) FROM ERP_SO_ITEM UNION ALL
SELECT 'TMS_SHIPMENT', COUNT(*) FROM TMS_SHIPMENT UNION ALL
SELECT 'WMS_INVENTORY_SNAPSHOT', COUNT(*) FROM WMS_INVENTORY_SNAPSHOT;
