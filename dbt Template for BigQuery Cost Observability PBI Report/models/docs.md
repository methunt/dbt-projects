{% docs table_stg_customer %}
Conformed customer dimension for one source system: renamed to PascalCase and given a surrogate
key. One row per `CustomerID` in that system.
{% enddocs %}

{% docs table_stg_sales_order %}
Conformed sales-order fact for one source system: renamed to PascalCase, surrogate keys minted,
`Amount` derived. One row per `OrderID` in that system.
{% enddocs %}

{% docs table_dwh_customer %}
Cross-source customer dimension. Unions both systems' staging customers and keeps exactly one row
per `CustomerKey` (system_b wins over system_a on overlapping keys), plus a sentinel `-1` row for
unresolved foreign keys.
{% enddocs %}

{% docs table_dwh_sales_order %}
Cross-source sales-order fact. Plain union of both systems' staging orders -- rows are NOT
deduplicated here (an order observed in both systems is kept as two rows); the analytics layer
resolves which system's row is authoritative per customer.
{% enddocs %}

{% docs table_dim_customer %}
Published customer dimension. Thin pass-through of `dwh_customer`.
{% enddocs %}

{% docs table_fct_sales_order %}
Published sales-order fact. Enforces one source system per customer: each customer's rows are kept
only from that customer's *current* assigned system (per the SCD2 snapshot), so a customer's
history never mixes two systems' data at once.
{% enddocs %}

{% docs table_dim_customer_current_source %}
Current-only view over the `customer_source_history` SCD2 snapshot: one row per customer with
today's assigned source system.
{% enddocs %}

{% docs scd_customer_source_history %}
SCD2 history of which source system "owns" each customer's `CustomerKey`, tracked from
`dwh_customer.SourceSystem` (the system that won the cross-source dedup for that key at each
snapshot run).
{% enddocs %}

{% docs customer_key %}
Surrogate key for the customer, `FARM_FINGERPRINT(SourceSystem || '-' || CustomerID)`. Identical
across systems for the same natural ID, which is what lets the warehouse layer dedup cross-source.
{% enddocs %}

{% docs customer_id %}
Natural customer identifier as issued by the source system.
{% enddocs %}

{% docs customer_name %}
Customer's display name.
{% enddocs %}

{% docs customer_email %}
Customer's contact email address.
{% enddocs %}

{% docs customer_country %}
Customer's country.
{% enddocs %}

{% docs customer_signup_date %}
Date the customer first registered in the source system.
{% enddocs %}

{% docs source_system %}
Which upstream system this row came from (or, on the published fact, which system is currently
authoritative for the row's customer): `SYSTEM_A` or `SYSTEM_B`.
{% enddocs %}

{% docs current_source_system %}
The source system currently assigned to this customer, per the SCD2 snapshot.
{% enddocs %}

{% docs valid_from %}
Timestamp from which this source-system assignment became current.
{% enddocs %}

{% docs insertion_timestamp %}
Timestamp this row was written by the current model run.
{% enddocs %}

{% docs order_key %}
Surrogate key for the order, `FARM_FINGERPRINT(SourceSystem || '-' || OrderID)`.
{% enddocs %}

{% docs order_id %}
Natural order identifier as issued by the source system.
{% enddocs %}

{% docs order_customer_key %}
Foreign key to `CustomerKey`, wrapped in `COALESCE(..., -1)` so an order with no resolvable
customer points at the dimension's sentinel row instead of failing the join.
{% enddocs %}

{% docs product_name %}
Name of the product on the order line.
{% enddocs %}

{% docs product_category %}
Category of the product on the order line.
{% enddocs %}

{% docs order_date %}
Date the order was placed.
{% enddocs %}

{% docs order_quantity %}
Units ordered on the line.
{% enddocs %}

{% docs order_unit_price %}
Price per unit, in the source system's native currency.
{% enddocs %}

{% docs order_amount %}
`Quantity * UnitPrice`, rounded to 2 decimal places.
{% enddocs %}
