{#
    union_source_dim(entity, key_col, cols)

    Generic cross-source union + de-duplication for the warehouse dimension layer.
    Unions the per-source staging dims (stg_system_a_<entity>, stg_system_b_<entity>), then keeps
    exactly ONE row per key (staging dims are 1:1 per key per system):
      - if the key exists in system_b, the system_b row wins (source priority system_b > system_a);
      - otherwise the system_a row is used.

    This priority is an arbitrary, documented choice for this template -- swap the CASE order (and
    the `instances` list order) to change which source wins on overlapping keys.

    Parameters:
        entity   - entity suffix shared by the stg models (e.g. 'customer').
        key_col  - de-dup grain: the surrogate key column.
        cols     - ordered list of output columns (must exist in both stg models, SourceSystem
                   excluded -- it is synthesised here).
#}
{% macro union_source_dim(entity, key_col, cols) %}
{%- set instances = [('system_b', 'SYSTEM_B'), ('system_a', 'SYSTEM_A')] -%}
select
    {{ cols | join(', ') }}
    , SourceSystem
from (
    {%- for inst, sys in instances %}
    select
        {{ cols | join(', ') }}
        , '{{ sys }}' as SourceSystem
    from {{ ref('stg_' ~ inst ~ '_' ~ entity) }}
    {%- if not loop.last %}
    union all
    {%- endif %}
    {%- endfor %}
)
qualify row_number() over (
    partition by {{ key_col }}
    order by case SourceSystem when 'SYSTEM_B' then 0 when 'SYSTEM_A' then 1 end
) = 1
{% endmacro %}
