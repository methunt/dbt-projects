{#
    bigquery__get_merge_sql — override of dbt's MERGE renderer.

    WHY THIS EXISTS
    ---------------
    dbt's built-in merge emits an unconditional `WHEN MATCHED THEN UPDATE SET ...`, so
    every matched row is rewritten on every run even when nothing about it changed. With
    `insertion_timestamp = CURRENT_TIMESTAMP()` in the model that makes the column
    meaningless: it records "last run", not "last change". This override adds

        WHEN MATCHED AND (<any tracked column differs>) THEN UPDATE SET ...

    so unchanged rows are left completely untouched (their insertion_timestamp is
    preserved), changed rows are updated in place (and DO get a fresh
    insertion_timestamp, since it stays in the UPDATE SET list), and new rows are
    inserted. This is SCD type 1 -- no history is retained. For real history use a
    snapshot instead.

    WHY AN OVERRIDE AND NOT A CUSTOM STRATEGY
    -----------------------------------------
    dbt-bigquery's `dbt_bigquery_validate_get_incremental_strategy` hard-fails on any
    `incremental_strategy` outside ('merge', 'insert_overwrite', 'microbatch'), so the
    documented custom-strategy hook (`get_incremental_<name>_sql`) is unavailable on this
    adapter. `incremental_predicates` is NOT an alternative: those land in the merge ON
    clause, so an unchanged row stops matching and gets INSERTed, duplicating the key.
    Overriding the renderer is the only seam. dbt-bigquery ships no
    `bigquery__get_merge_sql`, so this macro is a pure addition rather than a
    reimplementation of adapter code -- but it DOES mirror `default__get_merge_sql`, so
    re-check it against dbt-adapters on upgrade (written against dbt-adapters 1.22.8 /
    dbt-bigquery 1.11.1).

    USAGE (opt-in per model -- models that don't set the flag keep stock dbt behaviour)
    ---------------------------------------------------------------------------------
    These are CUSTOM config keys, so as of dbt 1.11 they must live under `meta` -- a
    top-level custom key raises CustomKeyInConfigDeprecation. Put them wherever the model's
    other meta lives (macro `config()` for the macro-driven staging dims, the `.yml`
    `config: meta:` block for the published dims, which already carry `meta.collation`):

        config(
            materialized='incremental',
            incremental_strategy='merge',
            unique_key=['EntityKey', 'RegionKey'],
            meta={
                'merge_update_when_changed': true,
                'merge_change_columns': ['Status', 'OriginTag'],
            },
        )

    Keys read (from `meta` only, via config.meta_get -- dbt raises
    CustomKeyInConfigDeprecation if one is declared at the top level of config() instead):
      merge_update_when_changed  bool  -- false/absent: delegate to default__get_merge_sql.
      merge_change_columns       list  -- explicit columns to compare. Default: every
                                          dest column except the unique_key and
                                          merge_change_exclude_columns.
      merge_change_exclude_columns list -- columns ignored when detecting change.
                                          Default ['insertion_timestamp'] -- it is
                                          CURRENT_TIMESTAMP() and would always differ,
                                          making the condition always true.

    NOTES / LIMITS
    --------------
    - Comparison is NULL-safe -- `a != b OR (a IS NULL AND b IS NOT NULL) OR (a IS NOT NULL
      AND b IS NULL)`, mirroring dbt's snapshot check strategy. NOT `IS DISTINCT FROM`:
      BigQuery rejects that operator on a collated column ("Function '$is_distinct_from'
      with collation 'und:ci' is not supported"), and these models collate strings. Bare
      `!=` alone would be wrong -- it yields NULL when either side is NULL, so the row would
      be silently skipped. STRUCT/ARRAY/JSON columns are not comparable either way; list
      those under merge_change_exclude_columns if ever added.
    - On a `und:ci` column the `!=` is collation-aware, so a change of CASE ONLY
      ('Acme' -> 'ACME') does not count as a change and the stored value keeps its original
      casing. That follows from the column being declared case-insensitive; if the exact
      casing matters for a column, don't collate it.
    - BigQuery still requires at most one source row per target row. If the model's grain
      is not 1:1 on the unique_key the MERGE fails with "UPDATE/MERGE must match at most
      one source row for each target row" -- dedup in the model, not here.
    - Rows that disappear upstream are never deleted; MERGE only inserts and updates.
    - `on_schema_change` needs nothing from this macro: the incremental materialization
      resolves it (ALTERing the target) BEFORE calling the merge renderer, so an appended
      column is already present in dest_columns and flows into the INSERT list and -- when
      merge_change_columns is left unset -- into the comparison too. But with an EXPLICIT
      merge_change_columns, an appended column is deliberately NOT compared: existing rows
      are only back-filled if a listed column also changed. Add the new column to the list
      if it should drive updates. Conversely, `sync_all_columns` dropping a column named in
      merge_change_columns raises a compiler error rather than silently comparing nothing.
#}
{% macro bigquery__get_merge_sql(target, source, unique_key, dest_columns, incremental_predicates=none) -%}

    {%- if not config.meta_get('merge_update_when_changed', false) -%}
        {{- return(default__get_merge_sql(target, source, unique_key, dest_columns, incremental_predicates)) -}}
    {%- endif -%}

    {%- if not unique_key -%}
        {%- do exceptions.raise_compiler_error(
            "merge_update_when_changed requires a unique_key: with no key nothing can match, so there is no UPDATE branch to make conditional."
        ) -%}
    {%- endif -%}

    {%- set change_columns = _merge_change_columns(unique_key, dest_columns) -%}
    {%- if change_columns | length == 0 -%}
        {%- do exceptions.raise_compiler_error(
            "merge_update_when_changed resolved to zero comparable columns for " ~ target
            ~ ". Every non-key column is excluded, so no change could ever be detected."
        ) -%}
    {%- endif -%}

    {%- set predicates = [] if incremental_predicates is none else [] + incremental_predicates -%}
    {%- set dest_cols_csv = get_quoted_csv(dest_columns | map(attribute="name")) -%}
    {%- set update_columns = get_merge_update_columns(
            config.get('merge_update_columns'), config.get('merge_exclude_columns'), dest_columns
    ) -%}
    {%- set sql_header = config.get('sql_header', none) -%}

    {#-- Key match, mirroring default__get_merge_sql (list or single column). --#}
    {%- if unique_key is sequence and unique_key is not mapping and unique_key is not string -%}
        {%- for key in unique_key -%}
            {%- do predicates.append('DBT_INTERNAL_SOURCE.' ~ key ~ ' = DBT_INTERNAL_DEST.' ~ key) -%}
        {%- endfor -%}
    {%- else -%}
        {%- do predicates.append('DBT_INTERNAL_SOURCE.' ~ unique_key ~ ' = DBT_INTERNAL_DEST.' ~ unique_key) -%}
    {%- endif -%}

    {#-- NULL-safe inequality, spelled out rather than `IS DISTINCT FROM`: BigQuery has no
         collated implementation of that operator ("Function '$is_distinct_from' with
         collation 'und:ci' is not supported"), and these models do collate string columns.
         This is the same three-part form dbt's own snapshot check strategy uses
         (global_project/macros/materializations/snapshots/strategies.sql). --#}
    {%- set change_predicates = [] -%}
    {%- for col in change_columns -%}
        {%- set dest = 'DBT_INTERNAL_DEST.' ~ col -%}
        {%- set src = 'DBT_INTERNAL_SOURCE.' ~ col -%}
        {%- do change_predicates.append(
            '(' ~ dest ~ ' != ' ~ src
            ~ ' or ((' ~ dest ~ ' is null) and not (' ~ src ~ ' is null))'
            ~ ' or ((not ' ~ dest ~ ' is null) and (' ~ src ~ ' is null)))'
        ) -%}
    {%- endfor -%}

    {{ sql_header if sql_header is not none }}

    merge into {{ target }} as DBT_INTERNAL_DEST
        using {{ source }} as DBT_INTERNAL_SOURCE
        on {{ "(" ~ predicates | join(") and (") ~ ")" }}

    {#-- The whole point of this override: matched-but-unchanged rows fall through
         untouched, so their insertion_timestamp survives. --#}
    when matched and (
        {{ change_predicates | join('\n        or ') }}
    ) then update set
        {% for column_name in update_columns -%}
            {{ column_name }} = DBT_INTERNAL_SOURCE.{{ column_name }}
            {%- if not loop.last %}, {% endif %}
        {%- endfor %}

    when not matched then insert
        ({{ dest_cols_csv }})
    values
        ({{ dest_cols_csv }})

{%- endmacro %}


{#
    _merge_change_columns(unique_key, dest_columns)

    Resolves which columns decide "did this row change" for
    bigquery__get_merge_sql's `WHEN MATCHED AND (...)` clause.

    Explicit `merge_change_columns` wins (validated against dest_columns so a typo or a
    renamed column fails at compile time instead of silently never detecting a change).
    Otherwise: all dest columns minus the unique_key minus merge_change_exclude_columns
    (default ['insertion_timestamp']). Matching is case-insensitive because BigQuery
    column names are, while the config is hand-written.
#}
{% macro _merge_change_columns(unique_key, dest_columns) -%}

    {%- set dest_names = dest_columns | map(attribute='name') | list -%}
    {%- set dest_names_upper = dest_names | map('upper') | list -%}

    {%- set explicit = config.meta_get('merge_change_columns') -%}
    {%- if explicit -%}
        {%- for col in explicit -%}
            {%- if col | upper not in dest_names_upper -%}
                {%- do exceptions.raise_compiler_error(
                    "merge_change_columns lists '" ~ col ~ "', which is not a column of this model. Available: " ~ dest_names | join(', ')
                ) -%}
            {%- endif -%}
        {%- endfor -%}
        {%- do return(explicit) -%}
    {%- endif -%}

    {%- set key_cols = unique_key if (unique_key is sequence and unique_key is not mapping and unique_key is not string) else [unique_key] -%}
    {%- set excluded_upper = (
            key_cols + config.meta_get('merge_change_exclude_columns', ['insertion_timestamp'])
    ) | map('upper') | list -%}

    {%- set resolved = [] -%}
    {%- for col in dest_names -%}
        {%- if col | upper not in excluded_upper -%}
            {%- do resolved.append(col) -%}
        {%- endif -%}
    {%- endfor -%}

    {%- do return(resolved) -%}

{%- endmacro %}
