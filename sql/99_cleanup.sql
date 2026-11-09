-- Remove the complete health insurance comparison deployment from Snowflake.
-- Run this entire file in a Snowsight SQL worksheet only when retiring the project.
-- It deletes HC_DEMO (including all data and uploaded code), HC_WH and HC_ENGINEER.
-- These names must still be dedicated to this project: anything added to HC_DEMO
-- since setup is also removed. Local repository files are not affected.
--
-- Before running: finish or cancel other manual loads, deployments and pipeline
-- calls in Query History. Have one operator perform cleanup and start no new work.
-- If a statement fails, stop, resolve its error, then rerun this file. Cleanup is
-- not transactional; previously successful DROP statements are not rolled back.

-- Use the setup administrator, not the role that will itself be deleted.
-- No USE DATABASE / USE WAREHOUSE is needed, so a partially removed deployment
-- does not prevent the remaining resources from being cleaned up.
USE ROLE ACCOUNTADMIN;

-- 1. Stop future scheduled runs and request cancellation of the current task run.
-- Account-level discovery works even when HC_DEMO or APP no longer exists.
-- SHOW uses SQL LIKE patterns; exact field comparisons below prevent an underscore
-- wildcard from selecting a similarly named task in a different project.
EXECUTE IMMEDIATE $$
DECLARE
    project_tasks RESULTSET;
BEGIN
    project_tasks := (
        EXECUTE IMMEDIATE 'SHOW TASKS LIKE ''DAILY_COMPARISON'' IN ACCOUNT'
    );

    FOR task_record IN project_tasks DO
        IF (
            task_record."database_name" = 'HC_DEMO'
            AND task_record."schema_name" = 'APP'
            AND task_record."name" = 'DAILY_COMPARISON'
        ) THEN
            EXECUTE IMMEDIATE 'ALTER TASK HC_DEMO.APP.DAILY_COMPARISON SUSPEND';

            -- Suspension alone does not cancel a run already in progress.
            -- Cancellation is asynchronous; the warehouse is also removed below.
            EXECUTE IMMEDIATE
                'SELECT SYSTEM$USER_TASK_CANCEL_ONGOING_EXECUTIONS(''HC_DEMO.APP.DAILY_COMPARISON'')';
        END IF;
    END FOR;
END;
$$;

-- 2. Remove the dedicated compute resource before dropping its data objects.
-- DROP WAREHOUSE also aborts queries still being processed on this warehouse.
-- The remaining DROP and SHOW statements do not need a running warehouse.
DROP WAREHOUSE IF EXISTS HC_WH;

-- 3. Remove the database and every contained object in one operation.
-- CASCADE covers all schemas, including RAW, APP and dbt's test audit schema:
--   * RAW.INPUT_FILES and APP.CODE stages, including their uploaded files;
--   * APP.COMPARISON_DBT, including its deployed dbt project versions;
--   * APP.DAILY_COMPARISON, BUILD_SHORTLIST() and RUN_PIPELINE(TIMESTAMP_NTZ);
--   * source tables, dbt models, shortlist/publication tables, assertion view,
--     failed-test tables, operational controls and the SOURCE_CSV file format.
-- Individual DROP statements are unnecessary and could miss dbt-created objects.
-- Snowflake retention rules still apply to dropped database/table data. This is
-- not an immediate storage purge; files in dropped internal stages are not
-- recoverable through Time Travel.
DROP DATABASE IF EXISTS HC_DEMO CASCADE;

-- 4. Remove the project role after its owned database objects are gone.
-- Dropping a role revokes its grants, including grants to users and SYSADMIN,
-- account EXECUTE TASK and any PyPI repository database-role membership.
-- Shared Snowflake roles, repositories and the operator user are not dropped.
DROP ROLE IF EXISTS HC_ENGINEER;

-- 5. Verify that the three project resources are no longer active.
-- Expect no row with the exact name HC_DEMO, HC_WH or HC_ENGINEER respectively.
-- LIKE treats underscores as wildcards, so similarly named unrelated resources
-- can appear in these read-only results. Account query history remains available.
SHOW DATABASES LIKE 'HC_DEMO';
SHOW WAREHOUSES LIKE 'HC_WH';
SHOW ROLES LIKE 'HC_ENGINEER';
