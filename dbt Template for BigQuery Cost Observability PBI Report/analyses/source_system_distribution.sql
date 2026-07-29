-- Ad-hoc analysis: how many customers and how much order volume each source
-- system is currently authoritative for, per dim_customer_current_source. Useful
-- for sanity-checking the union_source_dim priority and the source_repair hook
-- (a sudden shift here after a snapshot run means customers switched systems).
select
    c.CurrentSourceSystem,
    count(distinct c.CustomerKey) as CustomerCount,
    count(distinct f.OrderKey) as OrderCount,
    sum(f.Amount) as TotalAmount
from {{ ref('dim_customer_current_source') }} as c
left join {{ ref('fct_sales_order') }} as f
    on c.CustomerKey = f.CustomerKey
group by all
order by CustomerCount desc
