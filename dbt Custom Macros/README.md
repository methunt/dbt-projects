<div align="center">

# 🧩 dbt Custom Macros for BigQuery

### Two drop-in macros that stop dbt from paying to rewrite rows — and rows — that never changed.

![dbt](https://img.shields.io/badge/dbt-1.11-FF694B?style=for-the-badge&logo=dbt&logoColor=white)
![BigQuery](https://img.shields.io/badge/BigQuery-4285F4?style=for-the-badge&logo=googlecloud&logoColor=white)
![License](https://img.shields.io/badge/opt--in-per%20model-1DB954?style=for-the-badge)
![Type](https://img.shields.io/badge/SCD-Type%201-8A2BE2?style=for-the-badge)

</div>

---

## 🎯 What problem this solves

Run an incremental `merge` model in BigQuery every day, and dbt's default `MERGE` statement rewrites **every matched row on every run** — even the ones where nothing actually changed. On a wide table refreshed daily, that means you're paying to overwrite rows that carried no new information, over and over.

Separately, if you ever filter, join, or sort on a text column case-insensitively (`WHERE UPPER(status) = 'ACTIVE'`), you're wrapping every row in a function call before BigQuery can even use the value — which blocks it from using the column efficiently.

Both of these are dbt/BigQuery gaps, not model-design mistakes. There's no supported config flag for either one. These two macros close that gap by overriding the exact spot in dbt where the SQL gets generated.

| Without these macros | With these macros |
|---|---|
| Every matched row gets rewritten, every run, whether or not it changed | Only rows with a real change get rewritten — unchanged rows are left alone |
| Case-insensitive filters/joins pay for a function call on every row | The column itself is declared case-insensitive — no function call needed |
| No safe way to express either behaviour in stock dbt config | One flag in model `meta` config turns each one on |

---

## 📦 What's inside

| File | Overrides | Solves |
|---|---|---|
| [`macros/merge_when_changed.sql`](macros/merge_when_changed.sql) | `bigquery__get_merge_sql` | Skips the `UPDATE` for rows where nothing tracked changed |
| [`macros/bq_column_collation.sql`](macros/bq_column_collation.sql) | `bigquery__get_table_columns_and_constraints` | Makes a text column natively case-insensitive at the database level |

Neither macro changes behaviour for a model that doesn't explicitly opt in. Copy them into your project and every existing model keeps working exactly as before.

---

## 🔀 Macro 1 · Change-aware merge

Turns dbt's unconditional

```sql
WHEN MATCHED THEN UPDATE SET ...
```

into

```sql
WHEN MATCHED AND (<any tracked column actually differs>) THEN UPDATE SET ...
```

A row that matched but didn't change is left completely untouched — no rewrite, no wasted write.

**Turn it on** (custom keys live under `meta`, per dbt 1.11+):

```jinja
{{ config(
    materialized = 'incremental',
    incremental_strategy = 'merge',
    unique_key = ['EntityKey', 'RegionKey'],
    meta = {
        'merge_update_when_changed': true,
        'merge_change_columns': ['Status', 'OriginTag'],   -- optional, explicit list
    },
) }}
```

| Config key | Type | If you leave it out |
|---|---|---|
| `merge_update_when_changed` | boolean | `false` — behaves exactly like stock dbt |
| `merge_change_columns` | list | compares every column except the unique key and any excluded columns |
| `merge_change_exclude_columns` | list | defaults to `['insertion_timestamp']`, since a timestamp column always "changes" |

**What you get:** fewer bytes rewritten per run, an `insertion_timestamp` (or similar audit column) that actually means "last real change" instead of "last time this job ran."

---

## 🔤 Macro 2 · Native column collation

BigQuery lets you declare a column case-insensitive right in its type — `STRING COLLATE 'und:ci'` — but only at `CREATE TABLE` time, and dbt has no built-in way to add it. This macro splices the collation into the generated DDL for any column you name.

**Turn it on** (requires `contract: enforced` on the model — with no contract, dbt has no column list to attach collation to):

```yaml
# model .yml
config:
  contract:
    enforced: true
  meta:
    collation:
      - type: und:ci                    # case-insensitive
        columns: [CustomerName, OriginTag]
```

**What you get:** `WHERE CustomerName = 'acme'` matches `'ACME'` and `'Acme'` natively — no `UPPER()`/`LOWER()` wrapping needed on either side of a filter, join, or `ORDER BY`.

This also helps end users filtering the table from a downstream reporting tool — for example a Power BI report in DirectQuery mode. A slicer or filter on a collated column matches regardless of the casing the user types or the casing stored in the warehouse, without the report author having to wrap every filter card in a case-normalizing expression.

---

## ⚠️ Good to know before you use these

| | |
|---|---|
| **History isn't kept** | This is SCD Type 1 — the old value is gone once a row updates. Use a dbt snapshot if you need to see what a value used to be. |
| **Nothing gets deleted** | `MERGE` only inserts and updates. A row missing from the source is left in the target forever. |
| **Collation only applies on full rebuild** | Steady-state incremental runs only `MERGE` into the existing table, and `MERGE` can't change a column's collation. A collation change needs `dbt run --full-refresh` to actually take effect. |
| **Text columns only** | Collation only works on `STRING` columns. Naming any other column type raises a clear compile-time error. |
| **One matching row only** | BigQuery's `MERGE` still requires at most one source row per target row. If your model's grain allows duplicates on the key, dedupe upstream. |
| **BigQuery only** | Both macros hook into dbt-bigquery internals. They do nothing on Snowflake, Redshift, Postgres, or any other adapter. |
| **Case-only edits don't count as a change** | On a collated column, `'Acme'` becoming `'ACME'` isn't treated as a change, since the comparison itself is case-insensitive. Don't collate a column where exact casing matters. |

---

## ▶️ Install

```bash
cp macros/merge_when_changed.sql   your_project/macros/
cp macros/merge_when_changed.yml   your_project/macros/
cp macros/bq_column_collation.sql  your_project/macros/
```

Then opt in per model using the `meta` config shown above. Written and verified against `dbt-bigquery` 1.11.1 / `dbt-adapters` 1.22.8 — worth a quick re-check against those packages' merge/DDL macros after any adapter upgrade.
