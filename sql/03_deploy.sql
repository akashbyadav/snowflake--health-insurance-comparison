-- Purpose: create the native dbt project and Snowpark procedure from uploaded files.
-- Follow the exact stage-directory upload map in RUNBOOK.md before running this file.
-- Execute in a SQL worksheet while no load/pipeline/deployment is running.
USE ROLE HC_ENGINEER;
USE WAREHOUSE HC_WH;
USE DATABASE HC_DEMO;
USE SCHEMA APP;

-- Pause future scheduled runs before replacing code. In Query History, wait for
-- any existing run to finish; perform deployment with one operator at a time.
ALTER TASK IF EXISTS DAILY_COMPARISON SUSPEND;

-- Copy the uploaded dbt directory into a native project object. The committed
-- profiles.yml already selects the native target; no credential file is generated.
-- AUTO_COMPILE is false because the first complete build is gated in RUN_PIPELINE.
CREATE OR REPLACE DBT PROJECT COMPARISON_DBT
    FROM '@HC_DEMO.APP.CODE/dbt'
    DBT_VERSION = '1.9.4'
    DEFAULT_TARGET = 'native'
    AUTO_COMPILE = FALSE;

-- Import the Python module directly from the stage: no ZIP or client-side packaging.
-- Snowflake installs the pinned packages for its Python runtime and supplies session
-- to shortlist.run. Caller rights preserve the project's selected execution role.
-- Snowpark 1.30.0 imports pkg_resources. Pin setuptools to a compatible version:
-- unpinned setuptools can resolve to 82+ where that module has been removed.
CREATE OR REPLACE PROCEDURE HC_DEMO.APP.BUILD_SHORTLIST()
RETURNS NUMBER(38,0)
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
ARTIFACT_REPOSITORY = snowflake.snowpark.pypi_shared_repository
PACKAGES = (
    'snowflake-snowpark-python==1.30.0',
    'setuptools==70.3.0'
)
HANDLER = 'shortlist.run'
IMPORTS = ('@HC_DEMO.APP.CODE/snowpark/shortlist.py')
EXECUTE AS CALLER;

-- Next execute sql/05_pipeline.sql in the worksheet. The output-check script is
-- uploaded to CODE/sql/04_output_checks.sql and executed by that pipeline at runtime,
-- after FCT_QUOTE and QUOTE_SHORTLIST exist; do not execute it ahead of those tables.
