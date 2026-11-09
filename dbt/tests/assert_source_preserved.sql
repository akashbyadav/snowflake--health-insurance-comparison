-- ASSERT: every source quote survives exactly once with its original premium fields.
-- PASS: zero rows. FAIL: returned quote IDs were lost, added or changed by transformation.
-- NULL-safe comparisons allow declined responses to retain their missing premiums.
SELECT
    COALESCE(s.quote_id, f.quote_id) AS quote_id
FROM {{ source('insurance', 'quotes') }} AS s
FULL OUTER JOIN {{ ref('fct_quote') }} AS f
    ON s.quote_id = f.quote_id
WHERE
    s.quote_id IS NULL
    OR f.quote_id IS NULL
    OR s.request_id IS DISTINCT FROM f.request_id
    OR s.plan_id IS DISTINCT FROM f.plan_id
    OR s.quoted_at IS DISTINCT FROM f.quoted_at
    OR s.valid_until IS DISTINCT FROM f.valid_until
    OR s.offer_status IS DISTINCT FROM f.offer_status
    OR s.currency IS DISTINCT FROM f.currency
    OR s.sum_insured_inr IS DISTINCT FROM f.quoted_cover_inr
    OR s.base_premium_inr IS DISTINCT FROM f.base_premium_inr
    OR s.discount_inr IS DISTINCT FROM f.discount_inr
    OR s.annual_premium_inr IS DISTINCT FROM f.annual_premium_inr
    OR s.data_origin IS DISTINCT FROM f.data_origin
