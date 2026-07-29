{% snapshot customer_source_history %}
{{
    config(
        unique_key='CustomerKey',
        strategy='check',
        check_cols=['SourceSystem'],
    )
}}

select
    CustomerKey,
    CustomerID,
    SourceSystem
from {{ ref('dwh_customer') }}
where CustomerKey != -1

{% endsnapshot %}
