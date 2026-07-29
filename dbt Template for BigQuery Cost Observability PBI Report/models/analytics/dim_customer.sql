select
    CustomerKey,
    CustomerID,
    CustomerName,
    Email,
    Country,
    SignupDate,
    SourceSystem,
    current_timestamp() as InsertionTimestamp
from {{ ref('dwh_customer') }}
