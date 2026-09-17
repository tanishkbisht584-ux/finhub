-- 023 (2026-09-17): fill ROE / ROCE that the rows already hold the parts for.
-- fund_audit flagged ratios.missing on 1,691 of 2,467 quoted symbols:
--   * kaggle annual rows never received "ROE %" (15,719 rows / 1,761 symbols;
--     the mapping landed on 75 rows). Screener's ROE is PAT / AVERAGE net worth:
--     measured against the 75 stored values, p50 0.28 / p90 0.5 pt (year-end
--     net worth is ~1 pt off). First FY of a symbol falls back to year-end.
--   * yahoo_ts annual rows carry no roce when Yahoo serves no CurrentLiabilities
--     (691 non-lender rows / 361 symbols). Capital employed = net worth +
--     borrowings: p50 1.3 / p90 8 pt vs the CL form — the same fallback
--     fundamentals._ratios now applies to new rows. Lender rows (bank layout,
--     the identity holds only with interest as a cost) get no ROCE, as on the
--     page and in fund_audit.is_lender_row.
-- updated_at is left alone: nothing reads it on annual rows.

with k as (
  select symbol, period,
         (data->>'net_profit')::numeric as np,
         coalesce((data->>'equity_cap')::numeric, 0) + coalesce((data->>'reserves')::numeric, 0) as nw,
         lag(coalesce((data->>'equity_cap')::numeric, 0) + coalesce((data->>'reserves')::numeric, 0))
           over (partition by symbol order by period) as pnw
  from fundamentals
  where kind = 'annual' and data->>'src' = 'kaggle')
update fundamentals f
   set data = f.data || jsonb_build_object('roe',
         round(k.np / (case when coalesce(k.pnw, 0) > 0 then (k.nw + k.pnw) / 2 else k.nw end) * 100, 1))
  from k
 where f.symbol = k.symbol and f.kind = 'annual' and f.period = k.period
   and f.data->'roe' is null and k.np is not null and k.nw > 0;

update fundamentals
   set data = data || jsonb_build_object('roce', round(
         ((data->>'pbt')::numeric + abs(coalesce((data->>'interest')::numeric, 0)))
         / (coalesce((data->>'equity_cap')::numeric, 0) + coalesce((data->>'reserves')::numeric, 0)
            + coalesce((data->>'borrowings')::numeric, 0)) * 100, 1))
 where kind = 'annual' and data->>'src' = 'yahoo_ts'
   and data->'roce' is null and data->'pbt' is not null
   and coalesce((data->>'equity_cap')::numeric, 0) + coalesce((data->>'reserves')::numeric, 0)
       + coalesce((data->>'borrowings')::numeric, 0) > 0
   and not (  -- lender: sales ≈ expenses + op_profit + interest, but not without interest
        data->'sales' is not null and data->'expenses' is not null and data->'op_profit' is not null
        and coalesce((data->>'interest')::numeric, 0) <> 0
        and abs((data->>'expenses')::numeric + (data->>'op_profit')::numeric - (data->>'sales')::numeric)
            > 0.02 * abs((data->>'sales')::numeric)
        and abs((data->>'expenses')::numeric + (data->>'op_profit')::numeric + (data->>'interest')::numeric
                - (data->>'sales')::numeric) <= 0.02 * abs((data->>'sales')::numeric));
