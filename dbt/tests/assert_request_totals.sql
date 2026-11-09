-- ASSERT: each request summary agrees with its actual available quote rows.
-- PASS: zero rows. FAIL: a missing, extra or inconsistent summary is returned.
WITH expected AS (
    SELECT
        r.request_id,
        COUNT(q.quote_id) AS quote_count,
        COUNT(CASE WHEN q.is_available THEN 1 END) AS available_count,
        COUNT(CASE WHEN q.within_budget THEN 1 END) AS within_budget_count,
        COUNT(CASE WHEN q.comparison_status = 'EXPIRED' THEN 1 END) AS expired_count,
        COUNT(CASE WHEN q.comparison_status = 'DECLINED' THEN 1 END) AS declined_count,
        MIN(CASE WHEN q.is_available THEN q.annual_premium_inr END) AS lowest_premium_inr,
        MAX(CASE WHEN q.is_available THEN q.annual_premium_inr END) AS highest_premium_inr
    FROM {{ source('insurance', 'requests') }} AS r
    LEFT JOIN {{ ref('fct_quote') }} AS q
        ON r.request_id = q.request_id
    GROUP BY
        r.request_id
)
SELECT
    COALESCE(e.request_id, m.request_id) AS request_id
FROM expected AS e
FULL OUTER JOIN {{ ref('mart_request_comparison') }} AS m
    ON e.request_id = m.request_id
WHERE
    e.request_id IS NULL
    OR m.request_id IS NULL
    OR e.quote_count IS DISTINCT FROM m.quote_count
    OR e.available_count IS DISTINCT FROM m.available_count
    OR e.within_budget_count IS DISTINCT FROM m.within_budget_count
    OR e.expired_count IS DISTINCT FROM m.expired_count
    OR e.declined_count IS DISTINCT FROM m.declined_count
    OR e.lowest_premium_inr IS DISTINCT FROM m.lowest_premium_inr
    OR e.highest_premium_inr IS DISTINCT FROM m.highest_premium_inr
