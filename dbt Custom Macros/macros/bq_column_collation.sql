{#
    bigquery__get_table_columns_and_constraints — adds COLLATE to the contract column list.

    WHY THIS EXISTS
    ---------------
    BigQuery can declare per-column COLLATION only at CREATE time, and only as part of the
    column's type (`Col STRING COLLATE 'und:ci' NOT NULL`). dbt cannot express it: the column
    DDL for a contract-enforced model comes from `BigQueryAdapter.render_raw_columns_constraints`,
    a Python @available classmethod, so there is no Jinja seam inside it. (`bigquery__format_column`
    looks like one but is only used by the contract's assert_columns_equivalent comparison, never
    for DDL. Nor can collation ride along in the YAML `data_type`: the contract round-trips that
    type through `cast(null as <type>)`, which rejects a collation specifier.)

    WHY THIS MACRO, AND NOTHING ELSE
    --------------------------------
    This is the smallest override that buys collation. `bigquery__create_table_as` builds its
    contract column list by calling `get_table_columns_and_constraints()`, which is DISPATCHED,
    and dbt-bigquery ships no `bigquery__` implementation -- so defining one is a pure ADDITION,
    not a shadow. Stock `create_table_as` is untouched, and everything it does keeps working as
    shipped: python models, time-ingestion partitioning, iceberg, table options,
    get_select_subquery, partition_by / cluster_by, and the whole dbt-native constraint path
    (`not_null` from column `constraints:`, `primary key (...) not enforced` from model-level
    `constraints:` -- BigQuery's adapter already renders both).

    Collation is the only thing dbt cannot express, so it is the only thing overridden here -- and
    it works on any materialization that creates a table, `incremental` included.

    USAGE
    -----
        # model .yml
        config:
          meta:
            collation:
              - type: und:ci                    # case-insensitive
                columns: [CustomerName, OriginTag]

    Requires `contract: enforced` (project-wide here): without a contract dbt emits no column list,
    so there is nothing to attach collation to. Models with no `meta.collation` are untouched.

    CREATE-TIME ONLY -- THE THING TO REMEMBER
    -----------------------------------------
    On an incremental model, create_table_as runs against the TARGET only on first build, on
    --full-refresh, and when swapping a view for a table (dbt-bigquery
    materializations/incremental.sql lines 106 / 113 / 123). Steady-state runs call it for the
    TEMP relation only (line 140) and touch the target with MERGE alone -- and a MERGE cannot
    alter a column's collation. Therefore:

        editing meta.collation does NOTHING until that model is run --full-refresh.

    Same is true of partition_by, cluster_by and constraints. Collation IS applied to the temp
    relation too, since it is recreated every run -- useful, because it keeps both sides of the
    MERGE collation-matched, so the `DEST.Col != SOURCE.Col` change comparison in
    merge_when_changed.sql cannot fail on a collation mismatch.

    LIMITS
    ------
    - STRING columns only; a collation entry on another type, or naming a column the model does
      not declare, raises at compile time.
    - A PK column is NOT implicitly NOT NULL. BigQuery requires primary-key columns to be NOT NULL,
      so declare `constraints: - type: not_null` on them.
    - Mirrors the shape of `table_columns_and_constraints()` (dbt-adapters global_project,
      relations/column/columns_spec_ddl.sql) only when collation is requested -- otherwise it
      delegates there verbatim. Re-check on upgrade; written against dbt-adapters 1.22.8 /
      dbt-bigquery 1.11.1.
#}
{% macro bigquery__get_table_columns_and_constraints() -%}

    {#-- meta.collation: [{type: <collation>, columns: [...]}, ...] -> {col_lower: collation} --#}
    {%- set wanted = {} -%}
    {%- for entry in config.meta_get('collation', []) -%}
        {%- if entry is not mapping or not entry.get('type') -%}
            {%- do exceptions.raise_compiler_error(
                "Each config.meta.collation entry needs a 'type' and a 'columns' list (model '" ~ model.name ~ "')."
            ) -%}
        {%- endif -%}
        {%- for col in (entry.get('columns') or []) -%}
            {%- do wanted.update({col | trim | lower: entry.get('type') | trim}) -%}
        {%- endfor -%}
    {%- endfor -%}

    {#-- No collation intent: emit exactly what dbt would have emitted. --#}
    {%- if wanted | length == 0 -%}
        {{- return(table_columns_and_constraints()) -}}
    {%- endif -%}

    {%- set column_ddl = adapter.render_raw_columns_constraints(raw_columns=model['columns']) -%}
    {%- set model_ddl = adapter.render_raw_model_constraints(raw_constraints=model['constraints']) -%}

    {#-- Each rendered definition is `<name> <type>[ <constraints>]`. Splice the collation in
         after the type: BigQuery treats the specifier as part of the TYPE, so it has to
         precede NOT NULL. Match on the name, not the position. --#}
    {%- set collated = [] -%}
    {%- set seen = [] -%}
    {%- for definition in column_ddl -%}
        {%- set parts = definition.split(' ', 2) -%}
        {%- set collation = wanted.get(parts[0] | replace('`', '') | lower) -%}
        {%- if collation is none -%}
            {%- do collated.append(definition) -%}
        {%- elif parts | length < 2 or parts[1] | lower != 'string' -%}
            {%- do exceptions.raise_compiler_error(
                "config.meta.collation is only valid on STRING columns, but " ~ definition
                ~ " in model '" ~ model.name ~ "' is not one."
            ) -%}
        {%- else -%}
            {%- do seen.append(parts[0] | replace('`', '') | lower) -%}
            {%- do collated.append(
                parts[0] ~ ' ' ~ parts[1] ~ " collate '" ~ collation | replace("'", "''") ~ "'"
                ~ (' ' ~ parts[2] if parts | length > 2 else '')
            ) -%}
        {%- endif -%}
    {%- endfor -%}

    {%- for col in wanted -%}
        {%- if col not in seen -%}
            {%- do exceptions.raise_compiler_error(
                "config.meta.collation names column '" ~ col ~ "', which model '" ~ model.name
                ~ "' does not declare in YAML."
            ) -%}
        {%- endif -%}
    {%- endfor -%}

    {#-- Same shape as table_columns_and_constraints(). --#}
    (
    {% for c in collated -%}
      {{ c }}{{ "," if not loop.last or model_ddl }}
    {% endfor %}
    {% for c in model_ddl -%}
        {{ c }}{{ "," if not loop.last }}
    {% endfor -%}
    )
{%- endmacro %}
