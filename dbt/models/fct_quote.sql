-- Business question: can this quote be compared for the customer's search?
-- Output grain: one row per quote_id, including declined or unusable responses.
-- Flow: join the three sources -> assign one classification -> add comparison flags.
-- AVAILABLE means the modeled checks pass; it does not mean an insurer issued a policy.
-- Source assertions separately validate catalog/request structure and unique keys.

-- Step 1: bring together the response, what was requested and the product's terms.
-- Keep the original quote values so an incorrect response can still be investigated.
WITH joined AS (
    SELECT
        -- Retain original identifiers as well as proof that each reference matched.
        -- For example, q.plan_id can contain UNKNOWN while matched_plan_id is NULL.
        q.quote_id,
        q.request_id,
        q.plan_id,
        r.request_id AS matched_request_id,
        p.plan_id AS matched_plan_id,
        r.requested_at,
        q.quoted_at,
        q.valid_until,
        -- Read the run's comparison time from dbt vars rather than the system clock.
        -- TIMESTAMP_NTZ follows the project's Indian local wall-time convention.
        CAST('{{ var("as_of_timestamp") }}' AS TIMESTAMP_NTZ) AS as_of_timestamp,

        -- Search requirements: who needs cover, how much cover and their budget.
        r.city,
        r.state,
        r.oldest_age,
        r.adults,
        r.children,
        r.policy_type AS requested_policy_type,
        r.sum_insured_inr AS requested_cover_inr,
        r.annual_budget_inr,

        -- Catalog terms: use a separate cover alias to compare request, plan and quote.
        p.insurer_name,
        p.plan_name,
        p.policy_type,
        p.sum_insured_inr AS plan_cover_inr,
        p.min_entry_age,
        p.max_entry_age,
        p.max_adults,
        p.max_children,
        p.copay_pct,
        p.ped_wait_months,
        p.room_category,

        -- Response values stay unchanged; classification reports errors without fixing them.
        q.offer_status,
        q.currency,
        q.sum_insured_inr AS quoted_cover_inr,
        q.base_premium_inr,
        q.discount_inr,
        q.annual_premium_inr,

        -- Additional limits and provenance travel into the shortlist/publication too.
        -- These distinguish published catalog references from generated quote activity.
        p.max_entry_age_unlimited,
        p.max_members,
        p.product_uin,
        p.source_url,
        p.source_note,
        p.source_checked_on,
        p.catalog_origin,
        q.data_origin
    FROM {{ source('insurance', 'quotes') }} AS q
    -- LEFT JOINs preserve a quote even when its request or product cannot be found.
    -- An INNER JOIN would silently remove that quote before we could classify it.
    LEFT JOIN {{ source('insurance', 'requests') }} AS r
        ON q.request_id = r.request_id
    LEFT JOIN {{ source('insurance', 'plans') }} AS p
        ON q.plan_id = p.plan_id
),

-- Step 2: assign the first applicable reason, using the priority shown below.
-- A quote can have several issues. For example, an expired quote with a wrong
-- payable amount is INVALID_AMOUNT because the price check runs before expiry.
classified AS (
    SELECT
        *,
        CASE
            -- 1. Without both references, we cannot verify the quote against the search.
            WHEN matched_request_id IS NULL OR matched_plan_id IS NULL
                THEN 'INVALID_REFERENCE'

            -- 2. A declined response may have no price, so handle it before price checks.
            -- Only OFFERED responses can proceed; other or missing statuses are invalid.
            WHEN offer_status = 'DECLINED'
                THEN 'DECLINED'
            WHEN offer_status IS NULL OR offer_status <> 'OFFERED'
                THEN 'INVALID_STATUS'

            -- 3. Require a positive payable price and a valid base-minus-discount equation.
            -- Example: base 10000 - discount 500 must produce 9500, not 9600.
            WHEN base_premium_inr IS NULL
                OR discount_inr IS NULL
                OR annual_premium_inr IS NULL
                OR base_premium_inr <= 0
                OR discount_inr < 0
                OR discount_inr >= base_premium_inr
                OR annual_premium_inr <> base_premium_inr - discount_inr
                THEN 'INVALID_AMOUNT'

            -- 4. The comparison and budgets are in INR; no currency conversion is applied.
            WHEN currency IS NULL OR currency <> 'INR'
                THEN 'INVALID_CURRENCY'

            -- 5. All three cover amounts must agree. A cheaper quote for less cover
            -- must not appear as an equivalent response to the customer's search.
            WHEN quoted_cover_inr IS NULL
                OR quoted_cover_inr <> requested_cover_inr
                OR quoted_cover_inr <> plan_cover_inr
                THEN 'COVER_MISMATCH'

            -- 6. Check policy type, separate adult/child caps and the combined member cap.
            -- Example: 2 adults + 5 children fails a six-member limit even if each
            -- separate cap permits those counts.
            WHEN requested_policy_type <> policy_type
                OR adults > max_adults
                OR children > max_children
                OR adults + children > max_members
                THEN 'HOUSEHOLD_MISMATCH'

            -- 7. Entry-age boundaries are inclusive: age 65 passes a maximum of 65.
            -- Skip the upper bound only when the catalog explicitly marks it unlimited.
            -- A missing cap without that flag is rejected by the source-contract test.
            WHEN oldest_age < min_entry_age
                OR (NOT max_entry_age_unlimited AND oldest_age > max_entry_age)
                THEN 'AGE_INELIGIBLE'

            -- 8. Dates must form a possible sequence: search <= quote <= comparison time,
            -- with expiry after quote creation. Future-dated quotes are not yet usable.
            WHEN quoted_at IS NULL
                OR valid_until IS NULL
                OR quoted_at < requested_at
                OR quoted_at > as_of_timestamp
                OR valid_until <= quoted_at
                THEN 'INVALID_DATES'

            -- 9. An otherwise valid quote is expired at or after its valid_until time.
            -- The <= comparison is deliberate: equality must also produce EXPIRED.
            WHEN valid_until <= as_of_timestamp
                THEN 'EXPIRED'

            -- 10. None of the earlier exclusions applies to this response.
            ELSE 'AVAILABLE'
        END AS comparison_status
    FROM joined
)

-- Step 3: expose simple flags for reporting and the downstream Snowpark comparison.
SELECT
    *,
    -- Availability is derived from the classification, not calculated independently.
    comparison_status = 'AVAILABLE' AS is_available,
    -- Budget is a separate preference: a valid 9500 quote against a 9000 budget
    -- remains AVAILABLE, but within_budget is false. Excluded quotes are also false.
    (
        comparison_status = 'AVAILABLE'
        AND annual_premium_inr <= annual_budget_inr
    ) AS within_budget
FROM classified
