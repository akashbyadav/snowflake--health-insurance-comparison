# Manual Snowflake setup and execution

Use **Snowsight in your browser** for every step. Upload the supplied files through Snowsight and execute SQL in a Snowflake worksheet. The delivered CSVs are already complete and are the only data used by this project.

Follow the numbered setup and execution steps in order. Step 14 is optional teardown, only for retiring the deployment. A checkpoint states what must be true before you continue. The only Python file retained, `snowpark/shortlist.py`, is a module for a Snowflake stored procedure; upload it as code rather than executing it yourself.

## Part 1 — Prepare the Snowflake environment and upload files

### 1. Confirm access and open a SQL worksheet

Sign in to the intended Snowflake development account. Create a SQL worksheet in Snowsight and keep it open for this setup.

You need:

- An administrator able to run `sql/01_setup.sql` as `ACCOUNTADMIN`.
- An operator user who will receive role `HC_ENGINEER` and run the remaining steps.
- Native dbt Projects on Snowflake supporting the pinned dbt version `1.9.4`.
- Python 3.11 stored procedures with `snowflake-snowpark-python==1.30.0` and `setuptools==70.3.0` allowed by account policy. Deployment uses Snowflake's shared PyPI artifact repository.

The project reserves `HC_DEMO`, `HC_WH` and `HC_ENGINEER`. `HC_DEMO` is its development database; setup transfers its ownership to `HC_ENGINEER`. Confirm that these names belong to this project before continuing. Compute and storage incur Snowflake charges.

**If this project is already deployed:** suspend `HC_DEMO.APP.DAILY_COMPARISON`, wait for active work to finish in Query History before changing objects or uploaded code. Perform deployment with one operator at a time. Suspension does not cancel an existing execution.

**Checkpoint:** you are in the intended account and have the administrator/operator access needed for setup.

### 2. Create the database objects

Open [sql/01_setup.sql](sql/01_setup.sql), copy the entire file into the SQL worksheet and execute **all statements in order**. Do not execute only the statement under the cursor. Stop on any error.

The script creates:

| Object | Purpose |
| --- | --- |
| `HC_ENGINEER` | Project role, assigned to the setup user |
| `HC_WH` | X-Small warehouse with a 60-second idle auto-suspend |
| `HC_DEMO.RAW` | Source tables and input stage |
| `HC_DEMO.APP` | Models, procedures, code stage and operational controls |
| `RAW.INPUT_FILES` | Stage for the three supplied CSVs |
| `APP.CODE` | Stage for dbt files, the Snowpark module and output-check SQL |
| `RAW.SOURCE_CSV` | CSV parsing rules matching the delivered column order |
| `RAW.PLANS`, `RAW.REQUESTS`, `RAW.QUOTES` | Typed source tables |
| `RAW.FILE_CONTROLS` | Verified row counts and load timestamps |
| `APP.PIPELINE_RUNS` | Pipeline execution history |

If another user will operate the project, the administrator must grant the role to that user. Replace `YOUR_OPERATOR_USER` with the actual Snowflake user object identifier:

```sql
USE ROLE ACCOUNTADMIN;
GRANT ROLE HC_ENGINEER TO USER YOUR_OPERATOR_USER;
```

Use a double-quoted identifier if that user was created with case-sensitive or special characters.

**Checkpoint:** all setup statements succeed and the operator can select `HC_ENGINEER`. If reusing the preceding project version, the setup removes the obsolete checksum column from `RAW.FILE_CONTROLS`; the supplied CSV table schemas are unchanged.

### 3. Set worksheet context and check the runtime

Run this block as the operator. Repeat it whenever you open another project worksheet:

```sql
USE ROLE HC_ENGINEER;
USE WAREHOUSE HC_WH;
USE DATABASE HC_DEMO;
USE SCHEMA APP;

SELECT CURRENT_ROLE(), CURRENT_WAREHOUSE(), CURRENT_DATABASE(), CURRENT_SCHEMA();
SHOW TABLES IN SCHEMA HC_DEMO.RAW;
SHOW STAGES IN DATABASE HC_DEMO;
```

**Checkpoint:** the context is `HC_ENGINEER / HC_WH / HC_DEMO / APP`; RAW contains four tables; the two stages exist.

The procedure uses `snowflake.snowpark.pypi_shared_repository`. Its dependencies are resolved when the procedure is created in step 7; the Anaconda package inventory does not verify this PyPI environment. If repository access is restricted, the administrator can grant it explicitly:

```sql
USE ROLE ACCOUNTADMIN;
GRANT DATABASE ROLE SNOWFLAKE.PYPI_REPOSITORY_USER TO ROLE HC_ENGINEER;
USE ROLE HC_ENGINEER;
```

Resolve account package restrictions or unsupported dbt versions before deployment. See [Snowflake's PyPI package access requirements](https://docs.snowflake.com/en/developer-guide/udf/python/udf-python-packages).

The supplied `dbt/profiles.yml` already targets these Snowflake objects. Its `account: session` and `user: session` are placeholders; native dbt uses the active Snowflake execution context. No profile values need to be replaced for this account. See [native dbt configuration requirements](https://docs.snowflake.com/en/user-guide/data-engineering/dbt-projects-on-snowflake-limitations).

### 4. Upload the three CSVs to the input stage

In Snowsight:

1. Select **Ingestion → Add Data → Load files into a Stage**.
2. Select `plans.csv`, `requests.csv` and `quotes.csv` from the supplied `data/` folder.
3. Choose database `HC_DEMO`, schema `RAW`, stage `INPUT_FILES`.
4. Leave the stage path empty so the files are placed at the stage root.
5. Upload the files without changing their names or contents.

Use **stage upload**, not the table-loading wizard. The next SQL step creates the validated load. Snowsight supports stage uploads up to 250 MB per file; all supplied files are below that limit. [Snowflake stage-upload instructions](https://docs.snowflake.com/en/user-guide/data-load-local-file-system-stage-ui)

Verify in the SQL worksheet:

```sql
LIST @HC_DEMO.RAW.INPUT_FILES;
```

**Checkpoint:** the stage contains these exact paths:

```text
@HC_DEMO.RAW.INPUT_FILES/plans.csv
@HC_DEMO.RAW.INPUT_FILES/requests.csv
@HC_DEMO.RAW.INPUT_FILES/quotes.csv
```

The loader selects those exact filenames. If you uploaded into an extra `data/` folder, upload again at the root before continuing. Old files under other paths are not selected.

`data/manifest.json` is reference metadata, not a load input. Do not upload it. Its fingerprints describe the supplied files; this workflow validates typed content, row counts and keys rather than recomputing file-byte hashes.

### 5. Load and verify the source tables

Copy all of [sql/02_load_data.sql](sql/02_load_data.sql) into the worksheet and execute the whole file in the same worksheet session.

The script suspends future task runs, copies into temporary typed tables, and checks the exact row counts and unique non-null IDs. Before executing it, suspend the task if already deployed and wait for any active pipeline run to finish in Query History. It then replaces the three source tables and their controls together in one transaction. A load failure leaves the previous source delivery intact.

**Checkpoint:** the anonymous block returns:

```text
LOADED: 30 plans, 100000 requests, 500000 quotes. Task remains suspended.
```

Verify:

```sql
SELECT 'PLANS' AS source_name, COUNT(*) AS row_count FROM RAW.PLANS
UNION ALL
SELECT 'REQUESTS', COUNT(*) FROM RAW.REQUESTS
UNION ALL
SELECT 'QUOTES', COUNT(*) FROM RAW.QUOTES;

SELECT file_name, row_count, loaded_at
FROM RAW.FILE_CONTROLS
ORDER BY file_name;
```

**Checkpoint:** counts are `30`, `100000` and `500000`; controls contain three rows with matching counts. Repeating the load replaces the delivery rather than appending duplicates. It does not build models or change the published comparison.

### 6. Upload the dbt, Snowpark and assertion files

Use the same Snowsight **Load files into a Stage** dialog, now selecting database `HC_DEMO`, schema `APP`, stage `CODE`. Upload the following groups separately and enter the exact stage path shown for each group:

| Supplied files to select | Path inside `APP.CODE` | File count |
| --- | --- | ---: |
| `dbt/dbt_project.yml`, `dbt/profiles.yml` | `dbt` | 2 |
| All files directly inside `dbt/models/` | `dbt/models` | 6 |
| All SQL files directly inside `dbt/tests/` | `dbt/tests` | 6 |
| `snowpark/shortlist.py` | `snowpark` | 1 |
| `sql/04_output_checks.sql` | `sql` | 1 |

For example, selecting `dbt_project.yml` with stage path `dbt` must produce `@HC_DEMO.APP.CODE/dbt/dbt_project.yml`. Do not flatten the model/test folders or add a second project-root folder. Upload the Python file directly, without creating an archive.

Verify the paths:

```sql
LIST @HC_DEMO.APP.CODE/dbt/;
LIST @HC_DEMO.APP.CODE/snowpark/;
LIST @HC_DEMO.APP.CODE/sql/;
```

The required layout is:

```text
@HC_DEMO.APP.CODE/
├── dbt/
│   ├── dbt_project.yml
│   ├── profiles.yml
│   ├── models/
│   │   ├── fct_quote.sql
│   │   ├── mart_request_comparison.sql
│   │   ├── mart_insurer_daily.sql
│   │   ├── schema.yml
│   │   ├── sources.yml
│   │   └── unit_tests.yml
│   └── tests/
│       ├── assert_source_preserved.sql
│       ├── assert_source_contracts.sql
│       ├── assert_available_quotes.sql
│       ├── assert_comparison_flags.sql
│       ├── assert_request_totals.sql
│       └── assert_daily_totals.sql
├── snowpark/
│   └── shortlist.py
└── sql/
    └── 04_output_checks.sql
```

**Checkpoint:** all 16 required files are present with these names and paths. Keep the task suspended while uploading or replacing code. The other SQL files are executed from worksheets, not uploaded. `04_output_checks.sql` is uploaded now and executed by the pipeline after its referenced tables exist.

## Part 2 — Deploy, execute and operate the pipeline in Snowflake

### 7. Create the native dbt project and Snowpark procedure

Confirm there is no active load or pipeline and no other operator deploying code. Execute all of [sql/03_deploy.sql](sql/03_deploy.sql) in the worksheet; stop on any error.

This creates:

- `APP.COMPARISON_DBT`, copied from the uploaded `APP.CODE/dbt` directory and pinned to dbt `1.9.4`.
- `APP.BUILD_SHORTLIST()`, a Python stored procedure that imports `shortlist.py` and executes it inside Snowflake.

Verify:

```sql
SHOW DBT PROJECTS IN SCHEMA HC_DEMO.APP;
SHOW PROCEDURES LIKE 'BUILD_SHORTLIST' IN SCHEMA HC_DEMO.APP;
```

The procedure pins `setuptools==70.3.0` because Snowpark 1.30.0 imports `pkg_resources`. Do not replace this pin with bare `setuptools`: that module was removed in setuptools 82. [Setuptools removal notice](https://setuptools.pypa.io/en/latest/deprecated/pkg_resources.html)

**Checkpoint:** both objects exist. Creation does not yet build the comparison tables. The code stage is a supported source for [CREATE DBT PROJECT](https://docs.snowflake.com/en/sql-reference/sql/create-dbt-project); procedure code can be imported directly from a staged Python file using [CREATE PROCEDURE](https://docs.snowflake.com/en/sql-reference/sql/create-procedure).

### 8. Create the orchestration procedure and suspended task

Execute all of [sql/05_pipeline.sql](sql/05_pipeline.sql) in the worksheet. Do not execute `04_output_checks.sql` manually at this point.

Verify:

```sql
SHOW PROCEDURES LIKE 'RUN_PIPELINE' IN SCHEMA HC_DEMO.APP;
SHOW TASKS IN SCHEMA HC_DEMO.APP;
```

**Checkpoint:** `RUN_PIPELINE` exists and `DAILY_COMPARISON` is suspended. The pipeline will run native dbt, call Snowpark, install/check the assertion view, then publish the successful result. It requires a warehouse-backed task and caller-rights execution for native dbt. [Snowflake execution requirements](https://docs.snowflake.com/en/user-guide/data-engineering/dbt-projects-on-snowflake-limitations)

### 9. Run the first complete pipeline

Before a manual run, suspend the task if it has been resumed and wait for any active run or load to finish in Query History. Run one operation at a time; simultaneous manual runs are not prevented by the scripts.

In the worksheet with the step 3 context:

```sql
-- Use this fixed time to reproduce the supplied data's documented business examples.
CALL HC_DEMO.APP.RUN_PIPELINE('2026-09-20 12:00:00'::TIMESTAMP_NTZ);
```

Wait for completion. The returned string is the run ID.

```sql
SELECT run_id, as_of_timestamp, status, started_at, finished_at, error_message
FROM HC_DEMO.APP.PIPELINE_RUNS
ORDER BY started_at DESC
LIMIT 10;
```

**Checkpoint:** that run ID has `SUCCEEDED` status. The run executes three models, 24 dbt data tests, three dbt unit tests, the Snowpark procedure and independent output assertions. Unit fixtures pin their own timestamp, so their expectations remain stable when the pipeline time changes.

A successful run publishes all 500,000 responses, including excluded quotes and their reasons. On a first-run failure, the published table may be absent or empty. On later failures, the last successful published rows remain available. Intermediate models/marts can reflect an unsuccessful attempt; consumers should read `PUBLISHED_QUOTES`.

### 10. Verify the published results

Run these queries in the worksheet:

```sql
-- Both values must be 500000.
SELECT COUNT(*) AS row_count, COUNT(DISTINCT quote_id) AS distinct_quotes
FROM HC_DEMO.APP.PUBLISHED_QUOTES;

-- Zero rows may violate the publication rules.
SELECT COUNT(*) AS violation_count
FROM HC_DEMO.APP.SHORTLIST_VIOLATIONS;

SELECT comparison_status, COUNT(*) AS quote_count
FROM HC_DEMO.APP.PUBLISHED_QUOTES
GROUP BY comparison_status
ORDER BY comparison_status;
```

**Checkpoint:** 500,000 rows, 500,000 unique IDs, zero violations, and these counts at the fixed initial time:

| Classification | Rows |
| --- | ---: |
| AGE_INELIGIBLE | 57,282 |
| AVAILABLE | 137,861 |
| COVER_MISMATCH | 2,484 |
| DECLINED | 14,881 |
| EXPIRED | 264,157 |
| HOUSEHOLD_MISMATCH | 15,846 |
| INVALID_AMOUNT | 5,032 |
| INVALID_REFERENCE | 2,457 |
| **Total** | **500,000** |

Inspect the opening search:

```sql
SELECT
    quote_id,
    insurer_name,
    annual_premium_inr,
    comparison_status,
    within_budget,
    price_rank,
    above_lowest_inr,
    is_tradeoff_option,
    product_uin,
    data_origin
FROM HC_DEMO.APP.PUBLISHED_QUOTES
WHERE request_id = 'REQ-000001'
ORDER BY price_rank;
```

**Checkpoint:** five available responses with populated product UINs and `GENERATED_SCENARIO` activity origin:

| Quote ID | Generated premium | Rank | Above lowest | Within budget | Trade-off option |
| --- | ---: | ---: | ---: | --- | --- |
| QTE-0000001 | 12,595 | 1 | 0 | true | true |
| QTE-0000002 | 12,785 | 2 | 190 | true | false |
| QTE-0000003 | 14,245 | 3 | 1,650 | true | false |
| QTE-0000005 | 14,316 | 4 | 1,721 | true | true |
| QTE-0000004 | 17,402 | 5 | 4,807 | false | true |

**Initial setup is complete when these checks pass.** Premiums and outcomes are generated scenarios; the trade-off flag does not recommend an actual insurance purchase.

### 11. Optional: change the comparison time or enable a schedule

To evaluate the same data after its quote-validity windows end:

```sql
CALL HC_DEMO.APP.RUN_PIPELINE('2026-09-27 12:00:00'::TIMESTAMP_NTZ);
```

**Checkpoint:** the run succeeds, retains 500,000 rows, and has no available quotes. Otherwise usable offers have expired. The timestamp is Indian local wall time and must be on or after the latest search. Call the step 9 timestamp again to restore the initial comparison snapshot.

To enable the existing daily task after a successful manual run:

```sql
-- Runs at 06:00 Asia/Kolkata using the actual current comparison time.
ALTER TASK HC_DEMO.APP.DAILY_COMPARISON RESUME;
SHOW TASKS IN SCHEMA HC_DEMO.APP;
```

**Checkpoint:** task state is `started`. The task runs inside Snowflake on `HC_WH`; no browser session needs to remain open. It reevaluates the existing delivery and does not add new searches. Once the finite offers expire, scheduled runs will continue to show no available offers.

Inspect executions after a scheduled time:

```sql
SELECT name, scheduled_time, completed_time, state, error_message
FROM TABLE(HC_DEMO.INFORMATION_SCHEMA.TASK_HISTORY(
    TASK_NAME => 'DAILY_COMPARISON',
    RESULT_LIMIT => 20
))
ORDER BY scheduled_time DESC;
```

Pause scheduling when finished or before uploading/deploying code:

```sql
ALTER TASK HC_DEMO.APP.DAILY_COMPARISON SUSPEND;
SHOW TASKS IN SCHEMA HC_DEMO.APP;
```

**Checkpoint:** task state is `suspended`. Wait for any existing run to finish before maintenance. The task has a one-hour timeout and suspends after three consecutive failures.

### 12. Change code and redeploy

1. Suspend the task and wait for active operations to finish in Query History. Allow only one deployment operator.
2. Upload the changed files to the same stage paths from step 6. Replace existing staged files; if a file was removed from the project, remove its old staged copy from that specific project path too.
3. Repeat step 7 to replace the native dbt project and Snowpark procedure, then step 8 to replace orchestration and leave the task suspended.
4. Repeat steps 9–10. Resume scheduling only after a successful run and verification.

No data reload is needed for code-only changes. Perform loading, manual runs, uploads and deployment sequentially; the scripts do not prevent simultaneous manual operations. `CREATE OR REPLACE DBT PROJECT` replaces the native object and may reset its own history; `APP.PIPELINE_RUNS` remains separate.

### 13. Diagnose failures and recover abandoned work

Open **Query History** in Snowsight for the failing execution. For a dbt error, inspect the child `EXECUTE DBT PROJECT` query and its dbt output. Record the run ID, query ID and error text before retrying.

| Symptom | Action |
| --- | --- |
| Role or object access denied | Check account, worksheet context and the operator's `HC_ENGINEER` grant from steps 1–3. |
| File not found / zero rows copied | Use `LIST` to compare the uploaded paths with steps 4 and 6. Files are case-sensitive; the loader expects the original `.csv` names at the root. |
| CSV conversion or count/key failure | Upload the original complete CSV files again. Run all of `02_load_data.sql` in one session; do not bypass the check or change expected counts. |
| Native dbt cannot find a model/profile | Verify the `CODE/dbt` hierarchy and all 14 dbt files, then repeat steps 7–9. |
| Package or dbt runtime unavailable | Resolve account support/policy with the administrator. Do not change one pinned runtime in isolation. |
| dbt data test fails | Inspect its stored failing rows under `HC_DEMO.APP_DBT_TEST__AUDIT`; fix the cause and redeploy changed code. |
| dbt unit test fails | Compare its fixture output with `expect` in `unit_tests.yml`; verify all three timestamp overrides were uploaded. |
| `ModuleNotFoundError: No module named pkg_resources` | Recreate only `BUILD_SHORTLIST` using the pinned setuptools package in `03_deploy.sql`; follow the recovery steps below. |
| Snowpark handler/import failure | Verify `CODE/snowpark/shortlist.py`, the pinned package and the error in the `BUILD_SHORTLIST` child query. |
| Output assertion fails | Inspect `APP.SHORTLIST_VIOLATIONS` if available; never manually publish unchecked rows. |
| No available quotes | Check the comparison time; this is expected after the supplied offers expire. |

**Recover from the missing `pkg_resources` module:**

1. Suspend the task and wait for any active load or pipeline execution to finish in Query History.
2. In a worksheet with the step 3 context, execute only the `CREATE OR REPLACE PROCEDURE HC_DEMO.APP.BUILD_SHORTLIST()` statement from `sql/03_deploy.sql`. It includes both exact package pins and the existing staged Python import. There is no need to recreate the dbt project or upload the unchanged CSVs/module.
3. Rerun the pipeline at the same comparison time that failed, for example:

```sql
CALL HC_DEMO.APP.RUN_PIPELINE('2026-09-27 12:00:00'::TIMESTAMP_NTZ);

SELECT run_id, status, error_message
FROM HC_DEMO.APP.PIPELINE_RUNS
ORDER BY started_at DESC
LIMIT 5;
```

4. Confirm the new run is `SUCCEEDED` and the publication checks from step 10 pass. At September 27, zero available quotes is expected. Resume scheduling only if required.

Editing the repository SQL does not change an existing Snowflake procedure. The CREATE statement must be executed again to resolve and install the pinned dependencies.

Ordinary pipeline failures after a run record is created record `FAILED`. A terminated session can leave a `RUNNING` history row even though execution has stopped. That row is execution history and does not prevent a new run.

To correct a stale history row, first suspend scheduling and confirm in Query History that its execution has ended. Copy its `run_id` from `APP.PIPELINE_RUNS`. With the step 3 worksheet context, replace `ABANDONED_RUN_ID` and execute:

```sql
-- Correct only the confirmed stopped run; preserve all other execution history.
UPDATE PIPELINE_RUNS
SET status = 'FAILED',
    finished_at = CURRENT_TIMESTAMP(),
    error_message = 'Operator confirmed that execution ended before status was recorded.'
WHERE run_id = 'ABANDONED_RUN_ID'
    AND status = 'RUNNING';
```

**Checkpoint:** the selected history row is `FAILED`. Repeat the interrupted load or deployment step if needed, then run and verify the pipeline before resuming the task. The Snowflake execution checkpoints must be verified in your target account; the supplied files alone do not establish a successful cloud deployment.

### 14. Remove the deployment when finished (optional)

Use [sql/99_cleanup.sql](sql/99_cleanup.sql) only when you want to delete this project's Snowflake deployment. Do not include it in the normal setup sequence or upload it to a stage.

1. Confirm that you are in the intended account and that `HC_DEMO`, `HC_WH` and `HC_ENGINEER` are still dedicated to this project. Everything inside `HC_DEMO` will be removed, including anything added after setup.
2. Finish or cancel other manual loads, deployments and pipeline calls in Snowsight Query History. Have one operator perform cleanup and start no new project work.
3. Open a SQL worksheet with administrator access. Paste the entire contents of `sql/99_cleanup.sql` and run all statements in order. The script switches to `ACCOUNTADMIN`; no project database or warehouse selection is required.
4. Inspect the statement results. The script suspends the daily task if present, requests cancellation of its current run, drops the dedicated warehouse, drops the database with all its contents, and drops the project role. Database removal includes both stages and their uploaded CSV/code files, the native dbt project and versions, procedures, task, tables, views, file format and dbt test audit schema. Role removal also removes its grants to users and roles.
5. Check the three final `SHOW` results. There must be no row named exactly `HC_DEMO`, `HC_WH` or `HC_ENGINEER` in the corresponding result. Underscores are wildcards in `LIKE`, so unrelated names may appear.

If a statement fails, stop and resolve that error before continuing. DDL changes are not rolled back as a group. The script handles missing project resources, so rerun it after correcting the error, even if earlier cleanup statements succeeded.

Local repository files, user accounts and shared Snowflake package resources remain available. Account query history is retained. Dropped database/table data remains subject to Snowflake's retention rules; this script does not immediately purge retained storage. Files in dropped internal stages cannot be recovered through Time Travel. See Snowflake's [DROP DATABASE](https://docs.snowflake.com/en/sql-reference/sql/drop-database) and [DROP STAGE](https://docs.snowflake.com/en/sql-reference/sql/drop-stage) documentation.

**Checkpoint:** all three project resources are absent from the final results. To build the project again, start at step 1 and upload the supplied local files again.
