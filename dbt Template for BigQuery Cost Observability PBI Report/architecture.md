# Architecture

This project exists to be a runnable dbt project for the companion
[Bigquery & Dbt Cost Observability](https://github.com/methunt/PowerBi/tree/main/Bigquery%20&%20Dbt%20Cost%20Observability)
Power BI project to point at (see the README's Companion section for how the two are wired). This
document is the layer-by-layer map of *this* repo: merging two upstream systems into a single
dimension, tracking which system "owns" each customer over time with an SCD2 snapshot, self-healing
a downstream fact when that ownership changes, and a custom materialization that bakes column-level
collation/NOT NULL/PRIMARY KEY into `CREATE TABLE` DDL — the run behaviour that gives the
observability project something real to graph.

There is no real source system here — `seeds/` stands in for two upstream systems
(`system_a`, `system_b`) that would normally be `source()` tables.

## Layers

```
seeds/system_a_customer.csv      seeds/system_b_customer.csv
seeds/system_a_sales_order.csv   seeds/system_b_sales_order.csv
        │                               │
        ▼                               ▼
 staging/  stg_system_a_*          stg_system_b_*      (bq_table_collation tables;
                                                         PascalCase, surrogate keys minted)
        └───────────────┬───────────────┘
                        ▼
          warehouse/  dwh_customer   (union_source_dim: one row per CustomerKey,
                                       system_b wins over system_a on overlap)
                      dwh_sales_order (plain union, NOT deduped -- both systems'
                                       rows kept, resolved downstream)
                        │
                        ▼
          snapshots/  customer_source_history  (SCD2 on dwh_customer.SourceSystem)
          warehouse/  dim_customer_current_source  (current-only view over the snapshot)
                        │
                        ▼
          analytics/  dim_customer            (thin pass-through)
                      fct_sales_order          (INNER JOINs dwh_sales_order to
                                                 dim_customer_current_source on
                                                 CustomerKey + SourceSystem --
                                                 keeps one system per customer;
                                                 source_repair post-hook fixes
                                                 already-merged rows when a
                                                 customer's system changes)
```

## The patterns, and why they're here

**Cross-source dedup (`macros/union_source_dim.sql`)** — both systems can describe the same
customer. Rather than pick a winner in every model that needs a customer, one macro unions the
staging dims and keeps exactly one row per key via `QUALIFY ROW_NUMBER() ... = 1`, with an explicit,
documented priority (`system_b` > `system_a`). Any dimension merging N sources can reuse this by
parameterizing entity name, key column, and output columns.

**SCD2 ownership + self-repair (`snapshots/customer_source_history.sql`,
`models/warehouse/dim_customer_current_source.sql`, `macros/source_repair.sql`)** — a customer's
"current" system can change between runs (e.g. migrated from `system_a` to `system_b`). The
snapshot tracks that history; the current-only view exposes today's assignment; `fct_sales_order`'s
own SELECT already applies today's assignment to rows it just merged, but rows merged on a *previous*
run under the customer's *old* assignment need fixing too — that's what the `source_repair` post-hook
does: detect mismatches, delete, and reload from the raw dual-source fact. This is a deliberately
simplified version of the pattern (no incremental time-window scoping, no explicit
transaction/rollback) — a production version would add both once the fact is time-partitioned.

**Custom materialization (`macros/materializations/bq_table_collation.sql`)** — dbt's native `table`
materialization can't declare column collation or a `PRIMARY KEY` at create time on BigQuery. This
materialization reads `config.meta.collation` / `config.meta.constraints` off the model YAML and
renders them straight into the `CREATE OR REPLACE TABLE (...) AS (SELECT ...)` DDL, validating that
the YAML column order matches the model's actual SELECT output (the generated column list binds
positionally, so a silent mismatch would mis-attribute constraints to the wrong column).

**Contracts + docs everywhere** — every model column has a `data_type` and a `description` sourced
from `models/docs.md` via `{{ doc(...) }}`, and constraints are declared per-model depending on
materialization (`config.meta.constraints` on `bq_table_collation` models, native
`constraints: [{type: not_null}]` on `fct_sales_order`, the one plain incremental model).

## Cost-observability instrumentation

This is the part that exists purely for the companion Power BI project, layered on top of the four
patterns above:

- **`packages.yml`** pins [`brooklyn-data/dbt_artifacts`](https://github.com/brooklyn-data/dbt_artifacts);
  `dbt_project.yml` aliases all 34 of its objects to `dbtmeta_*` and gates its `on-run-end` upload
  hook behind the `enable_dbt_artifacts` var (off by default until the bootstrap run has created the
  tables — see the README's Companion section for the exact sequence).
- **`macros/query_comment.sql`** stamps every query this project submits with `app`/`project`/`env`/
  `resource_type`/`model_name` BigQuery job labels (wired via `query-comment: {job-label: true}` in
  `dbt_project.yml`). It deliberately carries no run identifier of its own — dbt-bigquery already
  labels every job with `dbt_invocation_id`, which is what lets a job issued from *inside* the
  `source_repair` post-hook (not a dbt node, so invisible to `dbt_artifacts`) still be joined back to
  its run via `INFORMATION_SCHEMA.JOBS`.
- **`analyses/`** — two ad-hoc, compile-only queries (`customer_lifetime_value.sql`,
  `source_system_distribution.sql`) that exercise the star schema without adding anything to the
  build, for when you want to check the seed data by hand.

## What this is *not*

This is a template, not a runnable production pipeline: no real sources, no partitioning strategy
tuned for scale, no row-level security, no metadata-mapping round-trip. It exists to show the four
patterns above end-to-end in isolation, instrumented just enough to feed the companion Power BI
project.
