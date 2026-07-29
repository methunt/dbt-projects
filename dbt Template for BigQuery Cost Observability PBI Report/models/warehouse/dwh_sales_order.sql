-- Plain union, deliberately NOT deduplicated: an order observed in both source
-- systems is kept as two rows here. The analytics layer (fct_sales_order) picks
-- the row from each customer's *current* assigned system.
select OrderKey, OrderID, CustomerKey, ProductName, ProductCategory, OrderDate, Quantity, UnitPrice, Amount, SourceSystem
from {{ ref('stg_system_a_sales_order') }}

union all

select OrderKey, OrderID, CustomerKey, ProductName, ProductCategory, OrderDate, Quantity, UnitPrice, Amount, SourceSystem
from {{ ref('stg_system_b_sales_order') }}
