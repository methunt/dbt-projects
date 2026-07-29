{{
    config(
        materialized='incremental',
        unique_key='OrderKey',
        incremental_strategy='merge',
        on_schema_change='fail',
        post_hook="{{ source_repair(this, ref('dwh_sales_order')) }}"
    )
}}

-- depends_on: {{ ref('dwh_sales_order') }}
-- The post_hook above refs dwh_sales_order too (for the repair reload), but hook
-- refs aren't reliably captured as DAG edges -- this comment pins the dependency
-- explicitly. Keep it in sync with macros/source_repair.sql.
-- One source system per customer: only the row from each customer's *current*
-- assigned system (dim_customer_current_source) is kept, so a customer's order
-- history never mixes two systems' data at once. Customers absent from the SCD
-- current view (e.g. never snapshotted) are dropped by design.
select
    d.OrderKey,
    d.OrderID,
    d.CustomerKey,
    d.ProductName,
    d.ProductCategory,
    d.OrderDate,
    d.Quantity,
    d.UnitPrice,
    d.Amount,
    c.CurrentSourceSystem as SourceSystem,
    current_timestamp() as InsertionTimestamp
from {{ ref('dwh_sales_order') }} as d
inner join {{ ref('dim_customer_current_source') }} as c
    on d.CustomerKey = c.CustomerKey
   and d.SourceSystem = c.CurrentSourceSystem
