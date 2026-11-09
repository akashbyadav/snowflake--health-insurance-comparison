-- Business question: how many usable options does each search have, and at what prices?
-- Output grain: one row per request_id, including searches with no responses.
-- Use FCT_QUOTE's existing decisions so reporting follows the same eligibility rules.
-- Counts describe responses, not purchased policies; premiums are not sales revenue.
SELECT
    -- Keep the search context beside the aggregates so the result is understandable.
    r.request_id,
    r.city,
    r.policy_type,
    r.sum_insured_inr,

    -- Count quote IDs, not joined rows. A request with no response produces one
    -- LEFT JOIN row with NULL quote fields; COUNT(q.quote_id) correctly returns zero.
    COUNT(q.quote_id) AS quote_count,

    -- A quote contributes 1 only when its flag is true; false/NULL contributes zero.
    -- Within-budget options are a subset of available options, not a separate category.
    SUM(CASE WHEN q.is_available THEN 1 ELSE 0 END) AS available_count,
    SUM(CASE WHEN q.within_budget THEN 1 ELSE 0 END) AS within_budget_count,

    -- These two counts explain common exclusions. Other exclusion reasons still
    -- count toward quote_count, so the displayed categories need not sum to that total.
    SUM(CASE WHEN q.comparison_status = 'EXPIRED' THEN 1 ELSE 0 END) AS expired_count,
    SUM(CASE WHEN q.comparison_status = 'DECLINED' THEN 1 ELSE 0 END) AS declined_count,

    -- CASE returns NULL for unusable quotes, which MIN/MAX ignore. The price range
    -- includes available offers above budget; it remains NULL when none are available.
    MIN(CASE WHEN q.is_available THEN q.annual_premium_inr END) AS lowest_premium_inr,
    MAX(CASE WHEN q.is_available THEN q.annual_premium_inr END) AS highest_premium_inr
FROM {{ source('insurance', 'requests') }} AS r
-- Start from searches rather than responses so an unanswered search is retained.
LEFT JOIN {{ ref('fct_quote') }} AS q
    ON r.request_id = q.request_id
-- Aggregate every response for the same search; keep its descriptive fields in the key.
GROUP BY
    r.request_id,
    r.city,
    r.policy_type,
    r.sum_insured_inr
