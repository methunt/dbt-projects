{#
        query_comment(node)

        Emitted as both the SQL query comment and (via `job-label: true` in
        dbt_project.yml) as BigQuery job labels. This is what lets the companion
        BigQuery & Dbt Cost Observability Power BI project attribute every job back
        to the model/resource that issued it, straight from
        INFORMATION_SCHEMA.JOBS.labels -- no dependency on dbt_artifacts alone.

        Deliberately does NOT emit a run identifier: dbt-bigquery already stamps every
        job it submits with a `dbt_invocation_id` label of its own, equal to
        dbtmeta_fct_dbt__invocations.command_invocation_id. That covers EVERY job a run
        fires -- including jobs issued from inside post-hooks via run_query
        (source_repair) and from run-operation, neither of which is a dbt node and
        neither of which dbt_artifacts records -- so run-level attribution needs
        nothing from this macro. Use `dbt_invocation_id`, not a label added here.

        Keeping a run id out of the comment also preserves BigQuery's result cache,
        which requires byte-identical query text INCLUDING comments: a per-run id would
        make every repeated SELECT (i.e. every test) a cache miss for no benefit.
#}
{% macro query_comment(node) %}
    {%- set comment_dict = {} -%}
    {#- Resolved defensively: the query-comment Jinja context is narrower than the model
        context, and an undefined name here would fail EVERY query in the run, not just
        one model. If the fallback ever shows up in the labels, that is the signal the
        name is unavailable in this context -- fix it here, don't chase it in BigQuery. -#}
    {%- set dbt_project = project_name if project_name is defined else 'unknown_project' -%}
    {%- do comment_dict.update(
        app='dbt',
        project = dbt_project,
        env = target.name
    ) -%}
    {%- if node is not none -%}
      {%- do comment_dict.update(
          resource_type = node.resource_type,
          model_name = node.name
      ) -%}
      {%- do comment_dict.update(node.config.get("labels", {})) -%}
    {% else %}
      {%- do comment_dict.update(node_id='internal') -%}
    {%- endif -%}
    {% do return(tojson(comment_dict)) %}
{% endmacro %}
