-- ASSERT: a displayed quote matches the request, catalog, dates and price arithmetic.
-- PASS: zero rows. FAIL: each returned quote must not be shown as available.
-- All checks are explicit so a NULL cannot silently make a predicate pass.
SELECT
    quote_id,
    comparison_status
FROM {{ ref('fct_quote') }}
WHERE
    is_available
    AND (
        matched_request_id IS NULL
        OR matched_plan_id IS NULL
        OR data_origin IS DISTINCT FROM 'GENERATED_SCENARIO'
        OR offer_status IS NULL
        OR offer_status <> 'OFFERED'
        OR currency IS NULL
        OR currency <> 'INR'
        OR annual_premium_inr IS NULL
        OR annual_premium_inr <= 0
        OR base_premium_inr IS NULL
        OR discount_inr IS NULL
        OR discount_inr < 0
        OR discount_inr >= base_premium_inr
        OR annual_premium_inr <> base_premium_inr - discount_inr
        OR quoted_cover_inr IS NULL
        OR quoted_cover_inr <> requested_cover_inr
        OR quoted_cover_inr <> plan_cover_inr
        OR oldest_age IS NULL
        OR oldest_age < min_entry_age
        OR max_entry_age_unlimited IS NULL
        OR (NOT max_entry_age_unlimited AND max_entry_age IS NULL)
        OR (NOT max_entry_age_unlimited AND oldest_age > max_entry_age)
        OR requested_policy_type <> policy_type
        OR adults > max_adults
        OR children > max_children
        OR max_members IS NULL
        OR adults + children > max_members
        OR quoted_at IS NULL
        OR quoted_at < requested_at
        OR quoted_at > as_of_timestamp
        OR valid_until IS NULL
        OR valid_until <= as_of_timestamp
    )
