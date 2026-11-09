-- Business question: for each insurer and quote day, how many responses are usable
-- at the selected comparison time, and which responses need source-data review?
-- Output grain: one row per (quote_date, insurer_name).
-- These generated responses cannot establish real insurer service quality or prices.
-- Premiums describe competing offers, not purchases or revenue.
SELECT
    -- Group by the response's creation day, not the search day or pipeline run day.
    -- Availability still reflects the run's comparison time, so reruns can change it.
    CAST(quoted_at AS DATE) AS quote_date,

    -- Preserve responses whose plan did not resolve; do not guess their insurer.
    COALESCE(insurer_name, 'UNKNOWN_PLAN') AS insurer_name,

    -- Every fact row is a response, including declined, expired and invalid quotes.
    COUNT(*) AS response_count,
    SUM(CASE WHEN is_available THEN 1 ELSE 0 END) AS available_count,

    -- Count malformed responses and inconsistent cover as review items. Ordinary
    -- expiry, decline, age and household exclusions are outside this review metric.
    -- Each quote contributes at most once because FCT_QUOTE assigns one primary reason.
    SUM(
        CASE
            WHEN comparison_status LIKE 'INVALID_%' OR comparison_status = 'COVER_MISMATCH'
            THEN 1
            ELSE 0
        END
    ) AS review_count,

    -- Average only available prices, including those above the customer's budget.
    -- NULL inputs are ignored; no available offers means NULL rather than a zero price.
    -- Round the reported mean to two decimal places for an INR amount.
    CAST(AVG(CASE WHEN is_available THEN annual_premium_inr END) AS DECIMAL(18, 2)) AS average_available_premium_inr
FROM {{ ref('fct_quote') }}
-- Repeat the same day and insurer expressions to keep one row for each reporting group.
GROUP BY
    CAST(quoted_at AS DATE),
    COALESCE(insurer_name, 'UNKNOWN_PLAN')
