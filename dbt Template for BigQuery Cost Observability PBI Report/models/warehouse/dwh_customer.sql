with deduped as (
    {{ union_source_dim('customer', 'CustomerKey', ['CustomerKey', 'CustomerID', 'CustomerName', 'Email', 'Country', 'SignupDate']) }}
),

null_row as (
    select
        -1 as CustomerKey,
        -1 as CustomerID,
        'UNKNOWN' as CustomerName,
        'UNKNOWN' as Email,
        'UNKNOWN' as Country,
        cast(null as date) as SignupDate,
        cast(null as string) as SourceSystem
)

select
    *,
    current_timestamp() as InsertionTimestamp
from (
    select * from deduped
    union all
    select * from null_row
)
