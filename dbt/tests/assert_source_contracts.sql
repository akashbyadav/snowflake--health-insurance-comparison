-- ASSERT: source catalog/searches obey their contracts and loaded counts agree.
-- PASS: zero rows. FAIL: entity/key identifies malformed reference data or an incomplete load.
-- Quote defects are handled by classification; invalid reference-table structure is fatal.
SELECT
    'PLAN' AS entity,
    plan_id AS key
FROM {{ source('insurance', 'plans') }}
WHERE
    insurer_name IS NULL
    OR NOT policy_type IN ('INDIVIDUAL', 'FAMILY_FLOATER')
    OR policy_type IS NULL
    OR sum_insured_inr IS NULL
    OR sum_insured_inr <= 0
    OR min_entry_age IS NULL
    -- NULL is permitted only for a documented unlimited adult entry age.
    OR max_entry_age_unlimited IS NULL
    OR (NOT max_entry_age_unlimited AND max_entry_age IS NULL)
    OR (max_entry_age_unlimited AND max_entry_age IS NOT NULL)
    OR min_entry_age > max_entry_age
    OR max_adults IS NULL
    OR max_adults < 1
    OR max_children IS NULL
    OR max_children < 0
    OR max_members IS NULL
    OR max_members < 1
    OR max_members < max_adults
    OR max_members < max_children
    OR product_uin IS NULL
    OR source_url IS NULL
    OR source_url NOT LIKE 'https://%'
    OR source_note IS NULL
    OR source_checked_on IS NULL
    OR catalog_origin IS DISTINCT FROM 'PUBLISHED_REFERENCE'
    OR copay_pct IS NULL
    OR copay_pct < 0
    OR copay_pct > 100
    OR ped_wait_months IS NULL
    OR ped_wait_months < 0
    OR room_category IS NULL
UNION ALL
SELECT
    'REQUEST',
    request_id
FROM {{ source('insurance', 'requests') }}
WHERE
    data_origin IS DISTINCT FROM 'GENERATED_SCENARIO'
    OR requested_at IS NULL
    OR city IS NULL
    OR state IS NULL
    OR oldest_age IS NULL
    OR oldest_age < 18
    OR oldest_age > 100
    OR policy_type IS NULL
    OR NOT policy_type IN ('INDIVIDUAL', 'FAMILY_FLOATER')
    OR adults IS NULL
    OR adults < 1
    OR children IS NULL
    OR children < 0
    OR sum_insured_inr IS NULL
    OR sum_insured_inr <= 0
    OR annual_budget_inr IS NULL
    OR annual_budget_inr <= 0
    OR (
        policy_type = 'INDIVIDUAL' AND (
            adults <> 1 OR children <> 0
        )
    )
UNION ALL
-- Generated response provenance must travel with every quote, including excluded ones.
SELECT
    'QUOTE',
    quote_id
FROM {{ source('insurance', 'quotes') }}
WHERE data_origin IS DISTINCT FROM 'GENERATED_SCENARIO'
UNION ALL
SELECT
    'FILE',
    expected.file_name
FROM (
    SELECT
        'plans.csv' AS file_name,
        COUNT(*) AS actual_rows
    FROM {{ source('insurance', 'plans') }}
    UNION ALL
    SELECT
        'requests.csv',
        COUNT(*)
    FROM {{ source('insurance', 'requests') }}
    UNION ALL
    SELECT
        'quotes.csv',
        COUNT(*)
    FROM {{ source('insurance', 'quotes') }}
) AS expected
LEFT JOIN {{ source('insurance', 'file_controls') }} AS c
    ON expected.file_name = c.file_name
WHERE
    c.file_name IS NULL OR c.row_count IS NULL OR expected.actual_rows <> c.row_count
