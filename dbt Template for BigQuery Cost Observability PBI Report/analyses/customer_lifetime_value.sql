-- Ad-hoc analysis, not built as a model: total spend and order count per customer,
-- joining the published dim/fact. Compile-inspectable via `dbt compile` without
-- creating a table/view -- useful for answering one-off business questions
-- straight from the star schema.
select
    c.CustomerKey,
    c.CustomerName,
    c.Country,
    c.SourceSystem,
    count(distinct f.OrderKey) as OrderCount,
    sum(f.Amount) as LifetimeSpend,
    max(f.OrderDate) as LastOrderDate
from {{ ref('dim_customer') }} as c
inner join {{ ref('fct_sales_order') }} as f
    on c.CustomerKey = f.CustomerKey
group by all
order by LifetimeSpend desc
