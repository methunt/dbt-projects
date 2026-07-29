select
    farm_fingerprint('SYSTEM_A' || '-' || cast(order_id as string)) as OrderKey,
    order_id as OrderID,
    coalesce(farm_fingerprint('SYSTEM_A' || '-' || cast(customer_id as string)), -1) as CustomerKey,
    product_name as ProductName,
    product_category as ProductCategory,
    cast(order_date as date) as OrderDate,
    quantity as Quantity,
    unit_price as UnitPrice,
    round(quantity * unit_price, 2) as Amount,
    'SYSTEM_A' as SourceSystem,
    current_timestamp() as InsertionTimestamp
from {{ ref('system_a_sales_order') }}
