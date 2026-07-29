-- Singular test: fct_sales_order must never carry a row whose SourceSystem
-- disagrees with the customer's current SCD assignment. A non-empty result
-- means the source_repair post-hook missed something.
select f.OrderKey, f.CustomerKey, f.SourceSystem, c.CurrentSourceSystem
from {{ ref('fct_sales_order') }} as f
inner join {{ ref('dim_customer_current_source') }} as c
    on f.CustomerKey = c.CustomerKey
where f.SourceSystem != c.CurrentSourceSystem
