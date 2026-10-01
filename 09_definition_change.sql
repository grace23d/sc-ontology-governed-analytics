-- =====================================================================
-- 09_definition_change.sql
-- Governed, live definition changes.
--   * METRIC_PARAMETER gains allowed ranges
--   * METRIC_CHANGE_LOG records who changed what, why, old vs new value,
--     version bump, and the certified scorecard before and after
--   * SP_APPLY_METRIC_RULES re-applies every rule- and date-dependent
--     column in the conformed facts from METRIC_PARAMETER, in place
--     (UPDATE, not CREATE OR REPLACE, so security policies stay attached)
--   * SP_CHANGE_METRIC_PARAMETER is the only way to change a rule
-- Run as SC_ADMIN after 08. Run each statement on its own.
-- =====================================================================
USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
USE SCHEMA SC_ONTOLOGY.GOVERNED;

-- ---------------------------------------------------------------------
-- Allowed ranges for each parameter
-- ---------------------------------------------------------------------
ALTER TABLE SC_ONTOLOGY.GOVERNED.METRIC_PARAMETER ADD COLUMN IF NOT EXISTS min_value NUMBER(18,4);
ALTER TABLE SC_ONTOLOGY.GOVERNED.METRIC_PARAMETER ADD COLUMN IF NOT EXISTS max_value NUMBER(18,4);
ALTER TABLE SC_ONTOLOGY.GOVERNED.METRIC_PARAMETER ADD COLUMN IF NOT EXISTS whole_number BOOLEAN;

UPDATE SC_ONTOLOGY.GOVERNED.METRIC_PARAMETER
SET min_value = CASE param_name
                  WHEN 'SUPPLIER_OTD_EARLY_TOLERANCE_DAYS' THEN 0
                  WHEN 'SUPPLIER_OTD_LATE_TOLERANCE_DAYS'  THEN 0
                  WHEN 'DOI_COGS_WINDOW_DAYS'              THEN 30
                  WHEN 'INSURANCE_RATE_PCT'                THEN 0 END,
    max_value = CASE param_name
                  WHEN 'SUPPLIER_OTD_EARLY_TOLERANCE_DAYS' THEN 10
                  WHEN 'SUPPLIER_OTD_LATE_TOLERANCE_DAYS'  THEN 10
                  WHEN 'DOI_COGS_WINDOW_DAYS'              THEN 365
                  WHEN 'INSURANCE_RATE_PCT'                THEN 5 END,
    whole_number = (param_name LIKE '%_DAYS');

-- ---------------------------------------------------------------------
-- Change log (kept across rebuilds)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS SC_ONTOLOGY.GOVERNED.METRIC_CHANGE_LOG (
  change_id          STRING,
  changed_at         TIMESTAMP_NTZ,
  changed_by         STRING,
  param_name         STRING,
  metric_id          STRING,
  old_value          NUMBER(18,4),
  new_value          NUMBER(18,4),
  old_version        STRING,
  new_version        STRING,
  reason             STRING,
  scorecard_before   VARIANT,
  scorecard_after    VARIANT
);

-- ---------------------------------------------------------------------
-- Re-apply rules in place
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SC_ONTOLOGY.GOVERNED.SP_APPLY_METRIC_RULES()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  early_tol  INTEGER;
  late_tol   INTEGER;
  ins_rate   FLOAT;
  doi_window INTEGER;
  po_rows    INTEGER DEFAULT 0;
  so_rows    INTEGER DEFAULT 0;
  inv_rows   INTEGER DEFAULT 0;
BEGIN
  -- Only SC_ADMIN sees every plant; any other role would update a subset
  IF (CURRENT_ROLE() <> 'SC_ADMIN') THEN
    RETURN 'Refused: call this as SC_ADMIN (current role is ' || CURRENT_ROLE() || ').';
  END IF;

  SELECT MAX(IFF(param_name = 'SUPPLIER_OTD_EARLY_TOLERANCE_DAYS', param_value, NULL))::INTEGER,
         MAX(IFF(param_name = 'SUPPLIER_OTD_LATE_TOLERANCE_DAYS',  param_value, NULL))::INTEGER,
         MAX(IFF(param_name = 'INSURANCE_RATE_PCT',                param_value, NULL))::FLOAT,
         MAX(IFF(param_name = 'DOI_COGS_WINDOW_DAYS',              param_value, NULL))::INTEGER
    INTO :early_tol, :late_tol, :ins_rate, :doi_window
  FROM SC_ONTOLOGY.GOVERNED.METRIC_PARAMETER;

  -- Supplier OTD flags and landed cost
  UPDATE SC_ONTOLOGY.CONFORMED.FCT_PO_LINE
  SET is_due            = (DATEADD('day', :late_tol, confirmed_date) < CURRENT_DATE()),
      due_line_flag     = IFF(DATEADD('day', :late_tol, confirmed_date) < CURRENT_DATE(), 1, 0),
      on_time_line_flag = IFF(DATEADD('day', :late_tol, confirmed_date) < CURRENT_DATE()
                              AND full_receipt_date IS NOT NULL
                              AND full_receipt_date BETWEEN DATEADD('day', 0 - :early_tol, confirmed_date)
                                                        AND DATEADD('day', :late_tol, confirmed_date), 1, 0),
      delivery_status   = CASE
                            WHEN NOT (DATEADD('day', :late_tol, confirmed_date) < CURRENT_DATE()) THEN 'NOT_YET_DUE'
                            WHEN full_receipt_date IS NOT NULL
                             AND full_receipt_date BETWEEN DATEADD('day', 0 - :early_tol, confirmed_date)
                                                       AND DATEADD('day', :late_tol, confirmed_date) THEN 'ON_TIME'
                            WHEN full_receipt_date IS NULL THEN 'OPEN_OVERDUE'
                            WHEN full_receipt_date < DATEADD('day', 0 - :early_tol, confirmed_date) THEN 'EARLY'
                            ELSE 'LATE' END,
      insurance_usd     = ROUND(goods_value_usd * :ins_rate / 100, 2),
      landed_cost_usd   = goods_value_usd + freight_usd + duty_usd
                          + ROUND(goods_value_usd * :ins_rate / 100, 2) + handling_usd;
  po_rows := SQLROWCOUNT;

  -- Order-line "due" status depends on today's date
  UPDATE SC_ONTOLOGY.CONFORMED.FCT_ORDER_LINE
  SET is_due                       = (commit_date < CURRENT_DATE()),
      due_line_flag                = IFF(commit_date < CURRENT_DATE(), 1, 0),
      due_order_qty_ea             = IFF(commit_date < CURRENT_DATE(), order_qty_ea, 0),
      due_shipped_by_commit_qty_ea = IFF(commit_date < CURRENT_DATE(), LEAST(shipped_by_commit_qty_ea, order_qty_ea), 0),
      due_line_filled_flag         = IFF(commit_date < CURRENT_DATE() AND shipped_by_commit_qty_ea >= order_qty_ea, 1, 0),
      due_line_on_time_flag        = IFF(commit_date < CURRENT_DATE() AND delivered_by_commit_qty_ea >= order_qty_ea, 1, 0),
      line_status                  = CASE
                                       WHEN NOT (commit_date < CURRENT_DATE()) THEN 'NOT_YET_DUE'
                                       WHEN delivered_by_commit_qty_ea >= order_qty_ea THEN 'DELIVERED_ON_TIME'
                                       WHEN shipped_qty_ea = 0 THEN 'NOT_SHIPPED'
                                       WHEN shipped_qty_ea < order_qty_ea THEN 'SHORT_OR_PARTIAL'
                                       ELSE 'DELIVERED_LATE' END;
  so_rows := SQLROWCOUNT;

  -- Days-of-inventory COGS window
  UPDATE SC_ONTOLOGY.CONFORMED.FCT_INVENTORY_POSITION t
  SET cogs_window_usd    = c.cogs,
      avg_daily_cogs_usd = ROUND(c.cogs / :doi_window, 4)
  FROM (
    SELECT i.inventory_position_id, COALESCE(SUM(f.cogs_usd), 0) AS cogs
    FROM SC_ONTOLOGY.CONFORMED.FCT_INVENTORY_POSITION i
    LEFT JOIN SC_ONTOLOGY.CONFORMED.FCT_SHIPMENT f
      ON f.plant_id = i.plant_id AND f.part_id = i.part_id
     AND f.ship_date >  DATEADD('day', 0 - :doi_window, i.snapshot_date)
     AND f.ship_date <= i.snapshot_date
    GROUP BY i.inventory_position_id
  ) c
  WHERE t.inventory_position_id = c.inventory_position_id;
  inv_rows := SQLROWCOUNT;

  RETURN 'Rules applied (early ' || early_tol || ', late ' || late_tol || ', insurance ' || ins_rate
         || '%, DOI window ' || doi_window || ' days): ' || po_rows || ' PO lines, '
         || so_rows || ' order lines, ' || inv_rows || ' inventory positions updated.';
END;
$$;

-- ---------------------------------------------------------------------
-- The only way to change a rule
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SC_ONTOLOGY.GOVERNED.SP_CHANGE_METRIC_PARAMETER(
  P_PARAM_NAME VARCHAR, P_NEW_VALUE FLOAT, P_REASON VARCHAR, P_CHANGED_BY VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  v_found       INTEGER;
  v_old_value   FLOAT;
  v_old_version VARCHAR;
  v_new_version VARCHAR;
  v_metric      VARCHAR;
  v_lo          FLOAT;
  v_hi          FLOAT;
  v_whole       BOOLEAN;
  v_before_sc   VARIANT;
  v_after_sc    VARIANT;
  v_change_id   VARCHAR;
  v_apply_msg   VARCHAR;
  v_early_now   INTEGER;
  v_late_now    INTEGER;
BEGIN
  IF (CURRENT_ROLE() <> 'SC_ADMIN') THEN
    RETURN OBJECT_CONSTRUCT('status', 'REFUSED', 'message', 'Only the data steward role SC_ADMIN can change a certified definition.');
  END IF;
  IF (P_REASON IS NULL OR LENGTH(TRIM(P_REASON)) < 5) THEN
    RETURN OBJECT_CONSTRUCT('status', 'REFUSED', 'message', 'A reason is required for every definition change.');
  END IF;

  SELECT COUNT(*) INTO :v_found FROM SC_ONTOLOGY.GOVERNED.METRIC_PARAMETER WHERE param_name = :P_PARAM_NAME;
  IF (v_found = 0) THEN
    RETURN OBJECT_CONSTRUCT('status', 'REFUSED', 'message', 'Unknown parameter ' || P_PARAM_NAME);
  END IF;

  SELECT param_value, version, used_by, min_value, max_value, whole_number
    INTO :v_old_value, :v_old_version, :v_metric, :v_lo, :v_hi, :v_whole
  FROM SC_ONTOLOGY.GOVERNED.METRIC_PARAMETER WHERE param_name = :P_PARAM_NAME;

  IF (P_NEW_VALUE < v_lo OR P_NEW_VALUE > v_hi) THEN
    RETURN OBJECT_CONSTRUCT('status', 'REFUSED',
      'message', P_PARAM_NAME || ' must be between ' || v_lo || ' and ' || v_hi);
  END IF;
  IF (v_whole AND P_NEW_VALUE <> ROUND(P_NEW_VALUE)) THEN
    RETURN OBJECT_CONSTRUCT('status', 'REFUSED', 'message', P_PARAM_NAME || ' must be a whole number of days');
  END IF;
  IF (P_NEW_VALUE = v_old_value) THEN
    RETURN OBJECT_CONSTRUCT('status', 'NO_CHANGE', 'message', 'The new value equals the current value.');
  END IF;

  v_before_sc := (SELECT OBJECT_AGG(metric_id, value::VARIANT) FROM SC_ONTOLOGY.GOVERNED.V_CANONICAL_SCORECARD);
  v_new_version := SPLIT_PART(v_old_version, '.', 1) || '.' || (SPLIT_PART(v_old_version, '.', 2)::INTEGER + 1)::VARCHAR;

  UPDATE SC_ONTOLOGY.GOVERNED.METRIC_PARAMETER
  SET param_value = :P_NEW_VALUE, version = :v_new_version, updated_at = CURRENT_TIMESTAMP()
  WHERE param_name = :P_PARAM_NAME;

  -- Bump the version of every certified metric the parameter feeds
  UPDATE SC_ONTOLOGY.GOVERNED.METRIC_REGISTRY
  SET version = SPLIT_PART(version, '.', 1) || '.' || (SPLIT_PART(version, '.', 2)::INTEGER + 1)::VARCHAR
  WHERE metric_id = :v_metric
     OR (:v_metric = 'total_landed_cost_usd' AND metric_id = 'landed_cost_per_unit_usd');

  -- Keep the human-readable supplier OTD window in step with the parameters
  SELECT MAX(IFF(param_name = 'SUPPLIER_OTD_EARLY_TOLERANCE_DAYS', param_value, NULL))::INTEGER,
         MAX(IFF(param_name = 'SUPPLIER_OTD_LATE_TOLERANCE_DAYS',  param_value, NULL))::INTEGER
    INTO :v_early_now, :v_late_now
  FROM SC_ONTOLOGY.GOVERNED.METRIC_PARAMETER;
  UPDATE SC_ONTOLOGY.GOVERNED.METRIC_REGISTRY
  SET inclusions_exclusions = REGEXP_REPLACE(inclusions_exclusions, 'Window -[0-9]+/[+][0-9]+ days',
                                             'Window -' || :v_early_now || '/+' || :v_late_now || ' days')
  WHERE metric_id = 'supplier_otd';

  CALL SC_ONTOLOGY.GOVERNED.SP_APPLY_METRIC_RULES();
  v_apply_msg := (SELECT $1 FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));

  v_after_sc := (SELECT OBJECT_AGG(metric_id, value::VARIANT) FROM SC_ONTOLOGY.GOVERNED.V_CANONICAL_SCORECARD);
  v_change_id := UUID_STRING();

  INSERT INTO SC_ONTOLOGY.GOVERNED.METRIC_CHANGE_LOG
  SELECT :v_change_id, CURRENT_TIMESTAMP(), COALESCE(:P_CHANGED_BY, CURRENT_USER()), :P_PARAM_NAME, :v_metric,
         :v_old_value, :P_NEW_VALUE, :v_old_version, :v_new_version, :P_REASON, :v_before_sc, :v_after_sc;

  RETURN OBJECT_CONSTRUCT('status', 'APPLIED', 'change_id', v_change_id, 'param_name', P_PARAM_NAME,
                          'metric_id', v_metric, 'old_value', v_old_value, 'new_value', P_NEW_VALUE,
                          'old_version', v_old_version, 'new_version', v_new_version,
                          'apply_result', v_apply_msg, 'before', v_before_sc, 'after', v_after_sc);
END;
$$;

-- ---------------------------------------------------------------------
-- First run: re-apply the current rules. Values should match the
-- scorecard you had before, apart from lines that became due since
-- the conformed layer was built (the procedure uses today's date).
-- ---------------------------------------------------------------------
SELECT metric_id, value FROM SC_ONTOLOGY.GOVERNED.V_CANONICAL_SCORECARD ORDER BY metric_id;
CALL SC_ONTOLOGY.GOVERNED.SP_APPLY_METRIC_RULES();
SELECT metric_id, value FROM SC_ONTOLOGY.GOVERNED.V_CANONICAL_SCORECARD ORDER BY metric_id;

-- ---------------------------------------------------------------------
-- Demo (run in the app's Governance tab, or here):
--   CALL SC_ONTOLOGY.GOVERNED.SP_CHANGE_METRIC_PARAMETER(
--     'SUPPLIER_OTD_LATE_TOLERANCE_DAYS', 3, 'Procurement: align with new supplier contract terms', NULL);
--   SELECT * FROM SC_ONTOLOGY.GOVERNED.METRIC_CHANGE_LOG ORDER BY changed_at DESC;
--   -- revert
--   CALL SC_ONTOLOGY.GOVERNED.SP_CHANGE_METRIC_PARAMETER(
--     'SUPPLIER_OTD_LATE_TOLERANCE_DAYS', 2, 'Revert after demo', NULL);
-- ---------------------------------------------------------------------
