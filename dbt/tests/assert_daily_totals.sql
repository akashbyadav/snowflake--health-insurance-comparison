-- ASSERT: every insurer/day summary accounts for exactly its fact rows.
-- PASS: zero rows. FAIL: a missing, extra, duplicated or incorrect aggregate is returned.
WITH expected AS (
    SELECT
        CAST(quoted_at AS DATE) AS quote_date,
        COALESCE(insurer_name, 'UNKNOWN_PLAN') AS insurer_name,
        COUNT(*) AS response_count,
        COUNT(CASE WHEN is_available THEN 1 END) AS available_count,
        COUNT(
            CASE
                WHEN comparison_status LIKE 'INVALID_%' OR comparison_status = 'COVER_MISMATCH'
                THEN 1
            END
        ) AS review_count,
        CAST(AVG(CASE WHEN is_available THEN annual_premium_inr END) AS DECIMAL(18, 2)) AS average_available_premium_inr
    FROM {{ ref('fct_quote') }}
    GROUP BY
        CAST(quoted_at AS DATE),
        COALESCE(insurer_name, 'UNKNOWN_PLAN')
)
SELECT
    COALESCE(e.insurer_name, m.insurer_name) AS insurer_name,
    COALESCE(e.quote_date, m.quote_date) AS quote_date
FROM expected AS e
FULL OUTER JOIN {{ ref('mart_insurer_daily') }} AS m
    ON e.quote_date = m.quote_date AND e.insurer_name = m.insurer_name
WHERE
    e.insurer_name IS NULL
    OR m.insurer_name IS NULL
    OR e.response_count IS DISTINCT FROM m.response_count
    OR e.available_count IS DISTINCT FROM m.available_count
    OR e.review_count IS DISTINCT FROM m.review_count
    OR e.average_available_premium_inr IS DISTINCT FROM m.average_available_premium_inr
UNION ALL
SELECT
    insurer_name,
    quote_date
FROM {{ ref('mart_insurer_daily') }}
GROUP BY
    insurer_name,
    quote_date
HAVING
    COUNT(*) <> 1
