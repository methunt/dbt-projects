{% macro _bq_get_meta_list(key_name) %}
  {# Read config.meta.<key_name> as a list. Returns [] if missing or wrong type. #}
  {% set config_meta = config.get('meta', {}) %}
  {% if config_meta is not mapping %}
    {{ return([]) }}
  {% endif %}
  {% set raw = config_meta.get(key_name) %}
  {% if raw is none %}
    {{ return([]) }}
  {% endif %}
  {% if raw is not sequence or raw is string %}
    {{ exceptions.raise_compiler_error(
      "config.meta." ~ key_name ~ " must be a list in model '" ~ model.name ~ "'."
    ) }}
  {% endif %}
  {{ return(raw) }}
{% endmacro %}


{% macro _bq_normalize_collation(raw_value) %}
  {# Normalize collation aliases. #}
  {% set v = (raw_value or '') | trim %}
  {{ return(v) }}
{% endmacro %}


{% macro _bq_quote_cols(col_list) %}
  {# Backtick-quote and comma-join a list of column names. #}
  {% set out = [] %}
  {% for c in col_list %}
    {% do out.append(adapter.quote(c)) %}
  {% endfor %}
  {{ return(out | join(', ')) }}
{% endmacro %}


{% macro _bq_parse_collation() %}
  {# Parse config.meta.collation list into a {col_name: collation_value} map.
     YAML form:
       collation:
         - type: und:ci
           columns: [Col1, Col2]
         - type: binary
           columns: [Col3]
  #}
  {% set out = {} %}
  {% for entry in _bq_get_meta_list('collation') %}
    {% if entry is not mapping %}
      {{ exceptions.raise_compiler_error(
        "Each config.meta.collation entry must be a mapping with 'type' and 'columns' in model '" ~ model.name ~ "'."
      ) }}
    {% endif %}
    {% set coll_type = (entry.get('type') or '') | trim %}
    {% if coll_type == '' %}
      {{ exceptions.raise_compiler_error(
        "config.meta.collation entry is missing 'type' in model '" ~ model.name ~ "'."
      ) }}
    {% endif %}
    {% set normalized = _bq_normalize_collation(coll_type) %}
    {% for col in (entry.get('columns') or []) %}
      {% set cc = (col or '') | trim %}
      {% if cc != '' %}
        {% do out.update({cc: normalized}) %}
      {% endif %}
    {% endfor %}
  {% endfor %}
  {{ return(out) }}
{% endmacro %}


{% macro _bq_parse_primary_key() %}
  {# Parse primary_key from config.meta.constraints list.
     YAML form:
       constraints:
         - type: primary_key
           columns: [ColA, ColB]
     Returns a flat list of column names. Only one primary_key entry is allowed.
  #}
  {% set pk_cols = [] %}
  {% set seen = [] %}
  {% for entry in _bq_get_meta_list('constraints') %}
    {% if entry is mapping and (entry.get('type') or '') | trim | lower == 'primary_key' %}
      {% if seen | length > 0 %}
        {{ exceptions.raise_compiler_error(
          "Only one primary_key constraint entry is allowed in model '" ~ model.name ~ "'."
        ) }}
      {% endif %}
      {% do seen.append(1) %}
      {% for col in (entry.get('columns') or []) %}
        {% set cc = (col or '') | trim %}
        {% if cc != '' %}
          {% do pk_cols.append(cc) %}
        {% endif %}
      {% endfor %}
    {% endif %}
  {% endfor %}
  {{ return(pk_cols) }}
{% endmacro %}


{% macro _bq_parse_not_null() %}
  {# Parse not_null from config.meta.constraints list.
     YAML form:
       constraints:
         - type: not_null
           columns: [ColA, ColB]
     Returns a deduplicated list of column names.
  #}
  {% set not_null_cols = [] %}
  {% set not_null_aliases = ['not_null', 'notnull', 'notnullable'] %}
  {% for entry in _bq_get_meta_list('constraints') %}
    {% if entry is mapping and (entry.get('type') or '') | trim | lower in not_null_aliases %}
      {% for col in (entry.get('columns') or []) %}
        {% set cc = (col or '') | trim %}
        {% if cc != '' and cc not in not_null_cols %}
          {% do not_null_cols.append(cc) %}
        {% endif %}
      {% endfor %}
    {% endif %}
  {% endfor %}
  {{ return(not_null_cols) }}
{% endmacro %}


{% macro _bq_infer_column_types(select_columns) %}
  {# Build a {name: data_type} map from dry-run column metadata. #}
  {% set out = {} %}
  {% for col in select_columns %}
    {% do out.update({col.name: col.data_type}) %}
  {% endfor %}
  {{ return(out) }}
{% endmacro %}


{% macro _bq_assert_column_order(yaml_columns, select_columns) %}
  {# The CTAS below binds the explicit column list to the SELECT output
     POSITIONALLY: if YAML order diverges from the model's SELECT order,
     BigQuery attaches names/types/collation/NOT NULL to the wrong columns
     without raising an error. Fail the build instead. #}
  {% set yaml_names = yaml_columns.keys() | list %}
  {% set select_names = select_columns | map(attribute='name') | list %}

  {% if yaml_names | length != select_names | length %}
    {{ exceptions.raise_compiler_error(
      "Model '" ~ model.name ~ "': YAML declares " ~ (yaml_names | length)
      ~ " columns but the model SELECT returns " ~ (select_names | length)
      ~ ". YAML: [" ~ (yaml_names | join(', ')) ~ "] / SELECT: ["
      ~ (select_names | join(', ')) ~ "]. The explicit CTAS column list binds"
      ~ " positionally, so the YAML columns must match the SELECT exactly."
    ) }}
  {% endif %}

  {% for i in range(yaml_names | length) %}
    {% if yaml_names[i] | lower != select_names[i] | lower %}
      {{ exceptions.raise_compiler_error(
        "Model '" ~ model.name ~ "': column order mismatch at position " ~ (i + 1)
        ~ " - YAML declares '" ~ yaml_names[i] ~ "' but the model SELECT returns '"
        ~ select_names[i] ~ "'. The explicit CTAS column list binds positionally,"
        ~ " so reorder the YAML columns (or the SELECT) to match."
      ) }}
    {% endif %}
  {% endfor %}
{% endmacro %}


{% macro _bq_render_column_definition(col_name, col_def, collation_map, not_null_cols, pk_cols, inferred_types) %}
  {# Build a single column DDL fragment: `name` type [COLLATE 'x'] [NOT NULL] #}
  {% set yaml_type = (col_def.get('data_type') or '') | trim %}
  {% set inferred_type = (inferred_types.get(col_name) or '') | trim %}
  {% set data_type = yaml_type if yaml_type != '' else inferred_type %}

  {% if data_type == '' %}
    {{ return(none) }}
  {% endif %}

  {% set parts = [adapter.quote(col_name), data_type] %}

  {% set collation = collation_map.get(col_name) %}
  {% if collation is not none and collation != '' %}
    {% if data_type | lower != 'string' %}
      {{ exceptions.raise_compiler_error(
        "Collation applied to non-STRING column '" ~ col_name ~ "' in model '" ~ model.name ~ "'."
      ) }}
    {% endif %}
    {% do parts.append("collate '" ~ (collation | replace("'", "''")) ~ "'") %}
  {% endif %}

  {% if col_name in not_null_cols or col_name in pk_cols %}
    {% do parts.append('not null') %}
  {% endif %}

  {{ return(parts | join(' ')) }}
{% endmacro %}


{% macro _bq_build_pk_constraint(pk_cols) %}
  {# Build PRIMARY KEY (...) NOT ENFORCED DDL, or none if no columns. #}
  {% if pk_cols | length == 0 %}
    {{ return(none) }}
  {% endif %}
  {{ return("primary key (" ~ _bq_quote_cols(pk_cols) ~ ") not enforced") }}
{% endmacro %}


{% materialization bq_table_collation, adapter='bigquery' %}
  {# BigQuery table materialization with create-time collation, NOT NULL, and PRIMARY KEY. #}

  {% set target_relation = this.incorporate(type='table') %}
  {% set existing_relation = load_cached_relation(target_relation) %}
  {% set raw_partition_by = config.get('partition_by', none) %}
  {% set partition_config = adapter.parse_partition_by(raw_partition_by) %}
  {% set raw_cluster_by = config.get('cluster_by', none) %}

  {% if existing_relation is not none and existing_relation.type != 'table' %}
    {% do adapter.drop_relation(existing_relation) %}
  {% endif %}

  {% if partition_config is not none and partition_config.time_ingestion_partitioning %}
    {{ exceptions.raise_compiler_error(
      "config(partition_by) with time_ingestion_partitioning is not supported by materialization 'bq_table_collation' for model '" ~ model.name ~ "'."
    ) }}
  {% endif %}

  {{ run_hooks(pre_hooks) }}

  {% set yaml_columns = model['columns'] if model['columns'] else {} %}
  {% set collation_map  = _bq_parse_collation() %}
  {% set pk_cols        = _bq_parse_primary_key() %}
  {% set not_null_cols  = _bq_parse_not_null() %}

  {% set has_meta = (collation_map | length) > 0
                    or (pk_cols | length) > 0
                    or (not_null_cols | length) > 0 %}

  {% if has_meta and yaml_columns | length == 0 %}
    {{ exceptions.raise_compiler_error(
      "Model '" ~ model.name ~ "' uses config.meta but has no YAML columns defined."
    ) }}
  {% endif %}

  {# Validate all referenced column names exist in YAML. #}
  {% for col_name in collation_map.keys() %}
    {% if yaml_columns.get(col_name) is none %}
      {{ exceptions.raise_compiler_error(
        "config.meta.collation references column '" ~ col_name ~ "' not found in YAML columns for model '" ~ model.name ~ "'."
      ) }}
    {% endif %}
  {% endfor %}

  {% for col_name in pk_cols %}
    {% if yaml_columns.get(col_name) is none %}
      {{ exceptions.raise_compiler_error(
        "config.meta.constraints primary_key references column '" ~ col_name ~ "' not found in YAML columns for model '" ~ model.name ~ "'."
      ) }}
    {% endif %}
  {% endfor %}

  {% for col_name in not_null_cols %}
    {% if yaml_columns.get(col_name) is none %}
      {{ exceptions.raise_compiler_error(
        "config.meta.constraints not_null references column '" ~ col_name ~ "' not found in YAML columns for model '" ~ model.name ~ "'."
      ) }}
    {% endif %}
  {% endfor %}

  {% if has_meta %}
    {#
        Column ORDER and TYPES come from the SELECT's schema, never from its rows.

        adapter.get_columns_in_select_sql() EXECUTES the SQL it is given, and BigQuery bills the
        full scan even though no rows are consumed -- so passing the bare `sql` would make every
        model on this materialization scan twice per build: once for this probe, once for the
        CTAS below.

        Wrapping in `where 1 = 0` returns the identical schema -- `select *` preserves column
        order -- for ~0 bytes billed. Keep the newline before the closing paren: a compiled model
        can end in a line comment, which would otherwise swallow it.
    #}
    {% set probe_sql = "select * from (\n" ~ sql ~ "\n) as __dbt_collation_probe where 1 = 0" %}
    {% set select_columns = adapter.get_columns_in_select_sql(probe_sql) %}
    {% do _bq_assert_column_order(yaml_columns, select_columns) %}
    {% set inferred_types = _bq_infer_column_types(select_columns) %}
    {% set col_defs = [] %}

    {% for col_name, col_def in yaml_columns.items() %}
      {% set rendered = _bq_render_column_definition(col_name, col_def, collation_map, not_null_cols, pk_cols, inferred_types) %}
      {% if rendered is none %}
        {{ exceptions.raise_compiler_error(
          "Could not resolve data_type for column '" ~ col_name ~ "' in model '" ~ model.name ~ "'. Add data_type in YAML columns."
        ) }}
      {% endif %}
      {% do col_defs.append(rendered) %}
    {% endfor %}

    {% set pk_constraint = _bq_build_pk_constraint(pk_cols) %}
    {% set all_defs = col_defs + ([pk_constraint] if pk_constraint is not none else []) %}

    {# BigQuery supports COLLATE and PRIMARY KEY inside CREATE TABLE ... AS (SELECT ...). #}
    {% call statement('main') %}
create or replace table {{ target_relation }}
  (
        {{ all_defs | join(',\n        ') }}
  )
  {{ partition_by(partition_config) }}
  {{ cluster_by(raw_cluster_by) }}
  as (
{{ sql }}
)
    {% endcall %}

  {% else %}
    {% call statement('main') %}
create or replace table {{ target_relation }}
{{ partition_by(partition_config) }}
{{ cluster_by(raw_cluster_by) }}
as (
{{ sql }}
)
    {% endcall %}
  {% endif %}

  {% do persist_docs(target_relation, model) %}
  {{ run_hooks(post_hooks) }}

  {{ return({'relations': [target_relation]}) }}
{% endmaterialization %}
