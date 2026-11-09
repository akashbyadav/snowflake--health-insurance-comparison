-- Purpose: create the isolated project workspace and its dedicated runtime role.
-- Run as an administrator. Reserve HC_DEMO, HC_ENGINEER and HC_WH for this project.
USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS HC_ENGINEER;
GRANT ROLE HC_ENGINEER TO ROLE SYSADMIN;
-- Give the current setup operator the role before switching into it below.
SET health_setup_user = CURRENT_USER();
GRANT ROLE HC_ENGINEER TO USER IDENTIFIER($health_setup_user);
CREATE WAREHOUSE IF NOT EXISTS HC_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE;
GRANT USAGE ON WAREHOUSE HC_WH TO ROLE HC_ENGINEER;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE HC_ENGINEER;

CREATE DATABASE IF NOT EXISTS HC_DEMO;
GRANT OWNERSHIP ON DATABASE HC_DEMO TO ROLE HC_ENGINEER COPY CURRENT GRANTS;

-- Everything below belongs to the runtime role, including objects created by dbt.
USE ROLE HC_ENGINEER;
USE WAREHOUSE HC_WH;
USE DATABASE HC_DEMO;
CREATE SCHEMA IF NOT EXISTS RAW;
CREATE SCHEMA IF NOT EXISTS APP;
CREATE STAGE IF NOT EXISTS RAW.INPUT_FILES;
CREATE STAGE IF NOT EXISTS APP.CODE ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');
CREATE FILE FORMAT IF NOT EXISTS RAW.SOURCE_CSV
    TYPE = CSV
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    EMPTY_FIELD_AS_NULL = TRUE
    NULL_IF = ('')
    ERROR_ON_COLUMN_COUNT_MISMATCH = TRUE;

-- Grain: one sourced product configuration at a household type and coverage amount.
CREATE TABLE IF NOT EXISTS RAW.PLANS (
    plan_id VARCHAR,
    insurer_name VARCHAR,
    plan_name VARCHAR,
    policy_type VARCHAR,
    sum_insured_inr DECIMAL(12, 0),
    min_entry_age INT,
    max_entry_age INT,
    max_adults INT,
    max_children INT,
    copay_pct DECIMAL(5, 2),
    ped_wait_months INT,
    room_category VARCHAR,
    max_entry_age_unlimited BOOLEAN,
    max_members INT,
    product_uin VARCHAR,
    source_url VARCHAR,
    source_note VARCHAR,
    source_checked_on DATE,
    catalog_origin VARCHAR
);

-- Grain: one synthetic search. No names, phone numbers or real customer identifiers.
CREATE TABLE IF NOT EXISTS RAW.REQUESTS (
    request_id VARCHAR,
    requested_at TIMESTAMP_NTZ,
    city VARCHAR,
    state VARCHAR,
    oldest_age INT,
    adults INT,
    children INT,
    policy_type VARCHAR,
    sum_insured_inr DECIMAL(12, 0),
    annual_budget_inr DECIMAL(12, 2),
    data_origin VARCHAR
);

-- Grain: one synthetic insurer response. A declined quote may have no premium.
-- Deliberately inconsistent source rows are preserved for business classification.
CREATE TABLE IF NOT EXISTS RAW.QUOTES (
    quote_id VARCHAR,
    request_id VARCHAR,
    plan_id VARCHAR,
    quoted_at TIMESTAMP_NTZ,
    valid_until TIMESTAMP_NTZ,
    offer_status VARCHAR,
    currency VARCHAR,
    sum_insured_inr DECIMAL(12, 0),
    base_premium_inr DECIMAL(12, 2),
    discount_inr DECIMAL(12, 2),
    annual_premium_inr DECIMAL(12, 2),
    data_origin VARCHAR
);

-- Grain: one supplied CSV, recording its verified row count and load timestamp.
-- File-byte fingerprints remain in manifest.json; SQL loading does not verify those hashes.
CREATE TABLE IF NOT EXISTS RAW.FILE_CONTROLS (
    file_name VARCHAR,
    row_count INT,
    loaded_at TIMESTAMP_LTZ
);

-- Grain: one attempted run. This is execution history, not generated business data.
CREATE TABLE IF NOT EXISTS APP.PIPELINE_RUNS (
    run_id VARCHAR,
    as_of_timestamp TIMESTAMP_NTZ,
    started_at TIMESTAMP_LTZ,
    finished_at TIMESTAMP_LTZ,
    status VARCHAR,
    error_message VARCHAR
);
