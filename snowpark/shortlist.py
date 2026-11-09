"""Build an explainable price/terms shortlist with Snowpark DataFrame operations.

This is a transparent comparison rule, not an insurance recommendation model.
A quote is dominated only when another available quote for the same search and
room category is no worse on premium, copay and waiting period, and better on
at least one. Equal offers remain valid alternatives; price ties use quote_id.
"""

from snowflake.snowpark import Window
from snowflake.snowpark.functions import coalesce, col, lit, min as minimum, row_number


def build_shortlist(facts):
    """Return every input row with price rank and an explicit trade-off flag.

    All joins and windows execute on Snowflake warehouse compute. There is no
    collection of the 500,000-row table into a Python list or pandas DataFrame.
    """
    available = facts.filter(col("IS_AVAILABLE"))
    candidates = available.select(
        col("QUOTE_ID").alias("CANDIDATE_ID"),
        col("REQUEST_ID").alias("CANDIDATE_REQUEST"),
        col("ROOM_CATEGORY").alias("CANDIDATE_ROOM"),
        col("ANNUAL_PREMIUM_INR").alias("CANDIDATE_PREMIUM"),
        col("COPAY_PCT").alias("CANDIDATE_COPAY"),
        col("PED_WAIT_MONTHS").alias("CANDIDATE_WAIT"),
    )
    alternatives = available.select(
        col("REQUEST_ID").alias("OTHER_REQUEST"),
        col("ROOM_CATEGORY").alias("OTHER_ROOM"),
        col("ANNUAL_PREMIUM_INR").alias("OTHER_PREMIUM"),
        col("COPAY_PCT").alias("OTHER_COPAY"),
        col("PED_WAIT_MONTHS").alias("OTHER_WAIT"),
    )
    # A lower premium alone must not dominate a quote with better coverage terms.
    same_comparison = (col("CANDIDATE_REQUEST") == col("OTHER_REQUEST")) & (
        col("CANDIDATE_ROOM") == col("OTHER_ROOM")
    )
    no_worse = (
        (col("OTHER_PREMIUM") <= col("CANDIDATE_PREMIUM"))
        & (col("OTHER_COPAY") <= col("CANDIDATE_COPAY"))
        & (col("OTHER_WAIT") <= col("CANDIDATE_WAIT"))
    )
    strictly_better = (
        (col("OTHER_PREMIUM") < col("CANDIDATE_PREMIUM"))
        | (col("OTHER_COPAY") < col("CANDIDATE_COPAY"))
        | (col("OTHER_WAIT") < col("CANDIDATE_WAIT"))
    )
    dominated = (
        candidates.join(
            alternatives, same_comparison & no_worse & strictly_better, "inner"
        )
        .select("CANDIDATE_ID")
        .distinct()
    )

    # Rank only available quotes. An expired or declined offer cannot become cheapest.
    price_order = Window.partition_by("REQUEST_ID").order_by(
        "ANNUAL_PREMIUM_INR", "QUOTE_ID"
    )
    request_group = Window.partition_by("REQUEST_ID")
    ranked = available.join(
        dominated, col("QUOTE_ID") == col("CANDIDATE_ID"), "left"
    ).select(
        col("QUOTE_ID"),
        row_number().over(price_order).alias("PRICE_RANK"),
        (
            col("ANNUAL_PREMIUM_INR")
            - minimum("ANNUAL_PREMIUM_INR").over(request_group).cast("decimal(12,2)")
        ).alias("ABOVE_LOWEST_INR"),
        col("CANDIDATE_ID").is_null().alias("IS_TRADEOFF_OPTION"),
    )
    # Restore excluded source rows for audit; they receive no rank and no shortlist flag.
    return facts.join(ranked, ["QUOTE_ID"], "left").with_column(
        "IS_TRADEOFF_OPTION", coalesce(col("IS_TRADEOFF_OPTION"), lit(False))
    )


def run(session):
    """Materialize a complete candidate output; publication happens only after checks."""
    result = build_shortlist(session.table("FCT_QUOTE"))
    result.write.mode("overwrite").save_as_table("QUOTE_SHORTLIST")
    return session.table("QUOTE_SHORTLIST").count()
