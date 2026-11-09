-- Run this whole file in a SQL worksheet after 03_deploy.sql.
-- Manual deployment requires a suspended task and no other operator changing code.
USE ROLE HC_ENGINEER;
USE WAREHOUSE HC_WH;
USE DATABASE HC_DEMO;
USE SCHEMA APP;

-- Purpose: run native dbt, Snowpark and output assertions before publishing one snapshot.
-- Caller rights are required by EXECUTE DBT PROJECT. Run one operation at a time:
-- suspend scheduling and wait for active work before a manual run or source load.
CREATE OR REPLACE PROCEDURE RUN_PIPELINE(AS_OF_TIME TIMESTAMP_NTZ)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    run_key VARCHAR DEFAULT UUID_STRING();
    args VARCHAR;
    command VARCHAR;
    dbt_query_id VARCHAR;
    dbt_success BOOLEAN;
    bad INTEGER;
    last_request TIMESTAMP_NTZ;
    dbt_failed EXCEPTION (-20004, 'dbt build failed; inspect the EXECUTE DBT PROJECT result.');
    invalid_time EXCEPTION (-20002, 'Snapshot time must be on or after the latest request.');
    invalid_output EXCEPTION (-20003, 'Shortlist assertions failed; inspect SHORTLIST_VIOLATIONS.');
BEGIN
    -- Validate the snapshot time before recording a run or building any models.
    SELECT MAX(requested_at)
    INTO :last_request
    FROM HC_DEMO.RAW.REQUESTS;
    IF (AS_OF_TIME IS NULL OR last_request IS NULL OR AS_OF_TIME < last_request) THEN
        RAISE invalid_time;
    END IF;
    INSERT INTO PIPELINE_RUNS
    VALUES (:run_key, :AS_OF_TIME, CURRENT_TIMESTAMP(), NULL, 'RUNNING', NULL);

    -- The timestamp is formatted by Snowflake, not interpolated from untrusted SQL text.
    args := 'build --target native --vars ' || CHR(39)
        || TO_JSON(OBJECT_CONSTRUCT('as_of_timestamp', TO_CHAR(AS_OF_TIME, 'YYYY-MM-DD HH24:MI:SS')))
        || CHR(39);
    command := 'EXECUTE DBT PROJECT COMPARISON_DBT ARGS='
        || CHR(39) || REPLACE(args, CHR(39), CHR(39) || CHR(39)) || CHR(39);
    EXECUTE IMMEDIATE :command;
    dbt_query_id := SQLID;
    -- Native dbt exposes success in its first result column. Require explicit TRUE
    -- as well as catching SQL exceptions; failed tests must block publication.
    SELECT TRY_TO_BOOLEAN($1::VARCHAR)
    INTO :dbt_success
    FROM TABLE(RESULT_SCAN(:dbt_query_id));
    IF (NOT COALESCE(dbt_success, FALSE)) THEN
        RAISE dbt_failed;
    END IF;

    -- Snowpark operates only after dbt data tests and fixture-based unit tests pass.
    CALL BUILD_SHORTLIST();
    -- The view is installed here because its referenced tables do not exist on first deployment.
    EXECUTE IMMEDIATE FROM @HC_DEMO.APP.CODE/sql/04_output_checks.sql;
    SELECT COUNT(*)
    INTO :bad
    FROM SHORTLIST_VIOLATIONS;
    IF (bad != 0) THEN
        RAISE invalid_output;
    END IF;

    -- The view already checks keys in both directions. Compare every fact column too.
    SELECT COUNT(*)
    INTO :bad
    FROM (
        SELECT * FROM FCT_QUOTE
        MINUS
        SELECT * EXCLUDE (price_rank, above_lowest_inr, is_tradeoff_option)
        FROM QUOTE_SHORTLIST
    );
    IF (bad != 0) THEN
        RAISE invalid_output;
    END IF;

    -- Build the stable publication schema once, then replace its rows transactionally.
    -- No DDL runs inside the publication transaction. All consumer queries use this table.
    CREATE TABLE IF NOT EXISTS PUBLISHED_QUOTES LIKE QUOTE_SHORTLIST;
    BEGIN TRANSACTION;
    DELETE FROM PUBLISHED_QUOTES;
    -- Name target columns explicitly so an additive upgrade cannot shift values.
    INSERT INTO PUBLISHED_QUOTES (
        quote_id,
        request_id,
        plan_id,
        matched_request_id,
        matched_plan_id,
        requested_at,
        quoted_at,
        valid_until,
        as_of_timestamp,
        city,
        state,
        oldest_age,
        adults,
        children,
        requested_policy_type,
        requested_cover_inr,
        annual_budget_inr,
        insurer_name,
        plan_name,
        policy_type,
        plan_cover_inr,
        min_entry_age,
        max_entry_age,
        max_adults,
        max_children,
        copay_pct,
        ped_wait_months,
        room_category,
        offer_status,
        currency,
        quoted_cover_inr,
        base_premium_inr,
        discount_inr,
        annual_premium_inr,
        max_entry_age_unlimited,
        max_members,
        product_uin,
        source_url,
        source_note,
        source_checked_on,
        catalog_origin,
        data_origin,
        comparison_status,
        is_available,
        within_budget,
        price_rank,
        above_lowest_inr,
        is_tradeoff_option
    )
    SELECT * FROM QUOTE_SHORTLIST;
    UPDATE PIPELINE_RUNS
    SET status = 'SUCCEEDED',
        finished_at = CURRENT_TIMESTAMP()
    WHERE run_id = :run_key;
    COMMIT;
    RETURN run_key;
EXCEPTION
    WHEN OTHER THEN
        -- Undo an incomplete publication so the previous snapshot stays available.
        -- Before publication starts, there is no active transaction to undo.
        ROLLBACK;

        -- Record the failure for this run only. Invalid snapshot inputs are rejected
        -- before a run row exists, so this UPDATE correctly affects zero rows then.
        UPDATE PIPELINE_RUNS
        SET status = 'FAILED',
            finished_at = CURRENT_TIMESTAMP(),
            error_message = :SQLERRM
        WHERE run_id = :run_key;
        RAISE;
END;
$$;

-- A warehouse-backed task is required for native dbt; creation leaves it suspended.
-- Daily processing ages the fixed set of quotes; it does not invent new searches.
CREATE OR REPLACE TASK DAILY_COMPARISON
    WAREHOUSE = HC_WH
    SCHEDULE = 'USING CRON 0 6 * * * Asia/Kolkata'
    SUSPEND_TASK_AFTER_NUM_FAILURES = 3
    USER_TASK_TIMEOUT_MS = 3600000
AS
    CALL RUN_PIPELINE(CONVERT_TIMEZONE('Asia/Kolkata', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ);
