-- Purpose: independently verify the Snowpark output before consumer publication.
-- ASSERT: every fact is retained, available price ranks are deterministic, unavailable
-- rows have no rank, and the trade-off flag agrees with a separate SQL dominance check.
-- PASS: this view has zero rows. FAIL: quote_id/reason explains a publication blocker.

USE ROLE HC_ENGINEER;
USE WAREHOUSE HC_WH;
USE DATABASE HC_DEMO;
USE SCHEMA APP;


CREATE OR REPLACE VIEW SHORTLIST_VIOLATIONS AS
WITH expected_rank AS (
    SELECT
        quote_id,
        ROW_NUMBER() OVER (PARTITION BY request_id ORDER BY annual_premium_inr, quote_id) AS price_rank,
        annual_premium_inr - MIN(annual_premium_inr) OVER (PARTITION BY request_id) AS above_lowest_inr
    FROM FCT_QUOTE
    WHERE
        is_available
), dominated AS (
    SELECT DISTINCT
        a.quote_id
    FROM FCT_QUOTE AS a
    JOIN FCT_QUOTE AS b
        ON a.request_id = b.request_id
        AND a.room_category = b.room_category
        AND b.annual_premium_inr <= a.annual_premium_inr
        AND b.copay_pct <= a.copay_pct
        AND b.ped_wait_months <= a.ped_wait_months
        AND (
            b.annual_premium_inr < a.annual_premium_inr
            OR b.copay_pct < a.copay_pct
            OR b.ped_wait_months < a.ped_wait_months
        )
    WHERE
        a.is_available AND b.is_available
)
SELECT
    COALESCE(f.quote_id, s.quote_id) AS quote_id,
    'SOURCE_OR_RANK_MISMATCH' AS reason
FROM FCT_QUOTE AS f
FULL OUTER JOIN QUOTE_SHORTLIST AS s
    ON f.quote_id = s.quote_id
LEFT JOIN expected_rank AS r
    ON f.quote_id = r.quote_id
LEFT JOIN dominated AS d
    ON f.quote_id = d.quote_id
WHERE
    f.quote_id IS NULL
    OR s.quote_id IS NULL
    OR s.price_rank IS DISTINCT FROM r.price_rank
    OR s.above_lowest_inr IS DISTINCT FROM r.above_lowest_inr
    OR s.is_tradeoff_option IS DISTINCT FROM (
        f.is_available AND d.quote_id IS NULL
    )
UNION ALL
SELECT
    quote_id,
    'DUPLICATE_QUOTE'
FROM QUOTE_SHORTLIST
GROUP BY
    quote_id
HAVING
    COUNT(*) <> 1;
