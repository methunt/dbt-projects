select
    farm_fingerprint('SYSTEM_B' || '-' || cast(customer_id as string)) as CustomerKey,
    customer_id as CustomerID,
    customer_name as CustomerName,
    email as Email,
    country as Country,
    cast(signup_date as date) as SignupDate,
    'SYSTEM_B' as SourceSystem,
    current_timestamp() as InsertionTimestamp
from {{ ref('system_b_customer') }}
