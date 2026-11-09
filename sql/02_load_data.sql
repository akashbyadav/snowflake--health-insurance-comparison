-- Purpose: load the fixed, supplied CSV delivery from the Snowsight upload stage.
-- Prerequisite: upload plans.csv, requests.csv and quotes.csv to the root of
-- HC_DEMO.RAW.INPUT_FILES, keeping their exact names and original CSV contents.
-- Run this WHOLE file in one worksheet session. Do not run its statements piecemeal.
USE ROLE HC_ENGINEER;
USE WAREHOUSE HC_WH;
USE DATABASE HC_DEMO;
USE SCHEMA APP;

-- Pause future scheduled runs before loading. In Query History, wait for any
-- existing pipeline run to finish before executing this file. Run one operation at a time.
ALTER TASK IF EXISTS DAILY_COMPARISON SUSPEND;

-- Temporary tables have the same column order and types as the final raw tables.
-- Their DDL runs before the replacement transaction so it cannot commit partial data.
CREATE OR REPLACE TEMPORARY TABLE INCOMING_PLANS LIKE RAW.PLANS;
CREATE OR REPLACE TEMPORARY TABLE INCOMING_REQUESTS LIKE RAW.REQUESTS;
CREATE OR REPLACE TEMPORARY TABLE INCOMING_QUOTES LIKE RAW.QUOTES;

EXECUTE IMMEDIATE $$
DECLARE
    bad INTEGER;
    invalid_delivery EXCEPTION (-20005, 'Expected 30 plans, 100000 requests and 500000 quotes with unique non-null keys. Raw data was not replaced.');
BEGIN
    -- Exact filenames prevent old or unrelated uploads from entering this delivery.
    -- FORCE supports repeating the same load; empty incoming tables avoid duplicates.
    -- A malformed field/type aborts the COPY instead of silently skipping its row.
    COPY INTO INCOMING_PLANS
    FROM @HC_DEMO.RAW.INPUT_FILES
    FILES = ('plans.csv')
    FILE_FORMAT = (FORMAT_NAME = HC_DEMO.RAW.SOURCE_CSV)
    FORCE = TRUE
    ON_ERROR = ABORT_STATEMENT;

    COPY INTO INCOMING_REQUESTS
    FROM @HC_DEMO.RAW.INPUT_FILES
    FILES = ('requests.csv')
    FILE_FORMAT = (FORMAT_NAME = HC_DEMO.RAW.SOURCE_CSV)
    FORCE = TRUE
    ON_ERROR = ABORT_STATEMENT;

    COPY INTO INCOMING_QUOTES
    FROM @HC_DEMO.RAW.INPUT_FILES
    FILES = ('quotes.csv')
    FILE_FORMAT = (FORMAT_NAME = HC_DEMO.RAW.SOURCE_CSV)
    FORCE = TRUE
    ON_ERROR = ABORT_STATEMENT;

    -- The supplied delivery is fixed. COUNT(DISTINCT key) also detects NULL keys,
    -- because NULL does not contribute to the distinct count.
    SELECT COUNT(*)
    INTO :bad
    FROM (
        SELECT COUNT(*) AS row_count, COUNT(DISTINCT plan_id) AS key_count, 30 AS expected_rows
        FROM INCOMING_PLANS
        UNION ALL
        SELECT COUNT(*), COUNT(DISTINCT request_id), 100000
        FROM INCOMING_REQUESTS
        UNION ALL
        SELECT COUNT(*), COUNT(DISTINCT quote_id), 500000
        FROM INCOMING_QUOTES
    ) AS counts
    WHERE row_count <> expected_rows OR key_count <> expected_rows;
    IF (bad != 0) THEN
        RAISE invalid_delivery;
    END IF;

    -- Replace the whole delivery together. A failure rolls back all three sources
    -- and their controls. This does not alter the last published comparison.
    BEGIN TRANSACTION;
    DELETE FROM RAW.PLANS;
    INSERT INTO RAW.PLANS SELECT * FROM INCOMING_PLANS;
    DELETE FROM RAW.REQUESTS;
    INSERT INTO RAW.REQUESTS SELECT * FROM INCOMING_REQUESTS;
    DELETE FROM RAW.QUOTES;
    INSERT INTO RAW.QUOTES SELECT * FROM INCOMING_QUOTES;
    DELETE FROM RAW.FILE_CONTROLS;
    INSERT INTO RAW.FILE_CONTROLS (file_name, row_count, loaded_at)
    VALUES
        ('plans.csv', 30, CURRENT_TIMESTAMP()),
        ('requests.csv', 100000, CURRENT_TIMESTAMP()),
        ('quotes.csv', 500000, CURRENT_TIMESTAMP());

    COMMIT;
    RETURN 'LOADED: 30 plans, 100000 requests, 500000 quotes. Task remains suspended.';
EXCEPTION
    WHEN OTHER THEN
        -- Undo a partial source replacement, then report the original failure.
        -- Before replacement starts, there is no active transaction to undo.
        ROLLBACK;
        RAISE;
END;
$$;
