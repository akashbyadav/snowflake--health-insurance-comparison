-- ASSERT: availability and budget flags agree with the classified status and actual price.
-- PASS: zero rows. FAIL: each returned quote has inconsistent consumer-facing flags.
SELECT
    quote_id
FROM {{ ref('fct_quote') }}
WHERE
    is_available IS DISTINCT FROM (
        comparison_status = 'AVAILABLE'
    )
    OR within_budget IS DISTINCT FROM (
        comparison_status = 'AVAILABLE' AND annual_premium_inr <= annual_budget_inr
    )
