{#
    source_repair(fact_relation, dwh_fact)

    Minimal self-repair post-hook enforcing "one source system per customer" on
    fct_sales_order. The model's own SELECT already applies each customer's *current*
    system assignment (from dim_customer_current_source) to every row it just
    merged; this hook additionally repairs any ALREADY-MERGED rows left over from
    a customer's *previous* system assignment (e.g. a customer's snapshot-tracked
    SourceSystem flips from SYSTEM_A to SYSTEM_B between runs) that an incremental
    merge on OrderKey wouldn't otherwise revisit.

    Detection is mismatch-driven: any fact row whose SourceSystem no longer matches
    the customer's current SCD assignment is deleted and reloaded from the raw
    dual-source warehouse fact (dwh_fact), joined back to the *current* assignment.

    Safety guard: skipped entirely when the current-assignment view has zero rows
    (e.g. snapshot not yet run) -- otherwise every customer would look "switched"
    and the delete would empty the fact with nothing to reinsert.

    This is a deliberately simplified version of the pattern for template purposes:
    no incremental date-window scoping, no transaction/rollback wrapping. A
    production version would add both once the fact is time-partitioned.
#}
{% macro source_repair(fact_relation, dwh_fact) %}
{% if execute and is_incremental() %}
    {% set repair_sql %}
    declare current_count int64 default 0;
    declare switched_count int64 default 0;

    set current_count = (
        select count(*) from {{ ref('dim_customer_current_source') }}
    );

    if current_count > 0 then

        create temp table switched_customers as
        select distinct f.CustomerKey
        from {{ fact_relation }} as f
        left join {{ ref('dim_customer_current_source') }} as c
            on f.CustomerKey = c.CustomerKey
        where c.CustomerKey is null
           or f.SourceSystem != c.CurrentSourceSystem;

        set switched_count = (select count(*) from switched_customers);

        if switched_count > 0 then
            delete from {{ fact_relation }}
            where CustomerKey in (select CustomerKey from switched_customers);

            insert into {{ fact_relation }}
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
            from {{ dwh_fact }} as d
            inner join {{ ref('dim_customer_current_source') }} as c
                on d.CustomerKey = c.CustomerKey
               and d.SourceSystem = c.CurrentSourceSystem
            where d.CustomerKey in (select CustomerKey from switched_customers);
        end if;
    end if;

    select current_count, switched_count;
    {% endset %}

    {% set results = run_query(repair_sql) %}
    {% set row = results.rows[0] if results and results.rows | length > 0 else none %}
    {% if row is not none %}
        {% if row[0] | int == 0 %}
            {% do exceptions.warn("SOURCE_REPAIR: " ~ fact_relation ~ " - SKIPPED: dim_customer_current_source has no current rows; run `dbt snapshot` first.") %}
        {% elif row[1] | int > 0 %}
            {{ log("SOURCE_REPAIR: " ~ fact_relation ~ " - " ~ row[1] ~ " customers repaired to their current source system", info=True) }}
        {% else %}
            {{ log("SOURCE_REPAIR: " ~ fact_relation ~ " - no switched customers, nothing to repair", info=True) }}
        {% endif %}
    {% endif %}
{% endif %}
{{ return('') }}
{% endmacro %}
