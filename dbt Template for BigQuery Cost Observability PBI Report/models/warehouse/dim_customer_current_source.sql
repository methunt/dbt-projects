-- Current-only view over the customer_source_history SCD2 snapshot: one row per
-- customer with the source system currently authoritative for it.
select
    CustomerKey,
    CustomerID,
    SourceSystem as CurrentSourceSystem,
    dbt_valid_from as ValidFrom
from {{ ref('customer_source_history') }}
where dbt_valid_to is null
