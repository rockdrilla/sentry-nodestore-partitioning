# sentry-nodestore-partitioning

Replace Sentry's single-table `nodestore_node` with a partitioned layout
that supports efficient data retention without `DELETE`-based purging.

Everything lives in the `nodestore` schema: tables (`data`, `ids`),
functions, procedures, and triggers.

## Problem

Sentry stores event payloads in `nodestore_node` — a single large table with
no partitioning. Deleting old data requires row-by-row `DELETE` statements
that bloat indexes and generate WAL. At scale, retention becomes the
bottleneck.

## Solution

Two new tables in the `nodestore` schema replace the monolith:

| Table | Partitioned by | Purpose |
|---|---|---|
| `nodestore.data` | `RANGE (timestamp)` — daily | Event payloads. Drop a whole day in milliseconds. |
| `nodestore.ids` | `LIST (left(id, 1))` — 16 hex partitions | Set of all known event IDs. Enables efficient cleanup when partitions are dropped. |

After migration, `nodestore_node` becomes a **view** over `nodestore.data` with
`INSTEAD OF` triggers — Sentry continues to read and write transparently.

## Architecture

```
Sentry application
      │
      V
public.nodestore_node (VIEW)
      │ INSTEAD OF triggers (in nodestore schema)
      |
      |- INSERT --> nodestore.ids   (hex-validated id lookup)
      │             nodestore.data  (base64-decoded payload, timestamp defaults to NOW())
      |
      |- UPDATE --> nodestore.data  (data only when actually changed; id + timestamp immutable)
      |
      \- DELETE --> (no-op — retention handles cleanup)
```

### Partitions

| Parent | Child naming | Count |
|---|---|---|
| `nodestore.data` | `nodestore.data_part_YYYY_MM_DD` | ~91 active (configurable) |
| `nodestore.ids` | `nodestore.ids_part_0` … `ids_part_f` | 16 |

### Indexes

| Table | Index | Type | Purpose |
|---|---|---|---|
| `nodestore.data` | `data_id_btree` | B-tree on `(id)` | Point lookups by event ID |
| `nodestore.data` | `data_ts_brin` | BRIN on `(timestamp)` | Timestamp range scans |
| `nodestore.ids` | per-partition `_idx` | UNIQUE B-tree on `(id)` | Fast lookups + uniqueness |

No PK on either table — `(id)` btree + `(timestamp)` brin is sufficient for
all query patterns.

## How retention works

For each partition older than `retention_days` (default 90):

1. **Detach** — `ALTER TABLE DETACH PARTITION` unlinks from `nodestore.data`.
   Writes continue uninterrupted on the parent.
2. **Batch-delete IDs** — scan the detached partition's `id` values in batches
   (100K records by default), delete matching rows from `nodestore.ids`. Each batch commits
   independently.
3. **Drop** — `DROP TABLE` removes the detached partition. No WAL from
   row-by-row `DELETE`s.

Each step is timed and logged (`[timing]` notices).

## Files

Three-digit prefixes group files by operational phase.

### 0xx — Before migration (DDL + procedure creation)

Safe to run at any time. No data changes.

| File | What |
|---|---|
| `001-create-tables.sql` | Creates `nodestore` schema, `data` + `ids` tables, indexes, 16 "hex" partitions for `ids` table |
| `002-fn-triggers.sql` | INSERT/UPDATE/DELETE trigger functions |
| `011-fn-create-partitions.sql` | Procedure: create daily partitions for a date range |
| `012-fn-create-partitions-daily.sql` | Wrapper: creates yesterday through next 7 days |
| `021-fn-delete-partitions.sql` | **Core retention:** detach, batch-delete IDs, drop. Default 90 days, 100K batch size |
| `022-fn-delete-partitions-daily.sql` | Wrapper: `CALL nodestore.delete_old_partitions(90)` |
| `031-fn-recreate-unique-ids.sql` | **Maintenance mode only.** Truncates `nodestore.ids` and repopulates from all `data` partitions |
| `041-fn-copy-data.sql` | Procedure: copy `nodestore_node` → `nodestore.data` + `nodestore.ids` in batches. Idempotent |

### 1xx — Migration (maintenance mode — no clients, no writes)

| File | What |
|---|---|
| `101-create-partitions.sql` | Create partitions for the migration range: 90 days back to 30 days forward |
| `111-copy-data.sql` | Execute the copy. Safety-gated — edit file before running |
| `121-swap-table-with-view.sql` | Rename `nodestore_node` → `OLD_nodestore_node`, create view + triggers. **Point of no return** |

### 2xx — Post-migration

| File | What |
|---|---|
| `201-remove-old-table.sql` | Drop `OLD_nodestore_node` + obsolete `copy_data_to_real` procedure. Safety-gated |
| `211-pg-cron-create-partitions-daily.sql` | Schedule partition creation via pg_cron: daily at 23:30 |
| `212-pg-cron-delete-partitions-daily.sql` | Schedule retention via pg_cron: daily at 00:05 |

## Migration steps

### Phase 1: Prepare (safe, no data changes)

```
001-create-tables.sql
002-fn-triggers.sql
011-fn-create-partitions.sql
012-fn-create-partitions-daily.sql  — adjust if required by your setup
021-fn-delete-partitions.sql
022-fn-delete-partitions-daily.sql  — adjust if required by your setup
031-fn-recreate-unique-ids.sql
041-fn-copy-data.sql
```

### Phase 2: Execute (maintenance mode required)

```
101-create-partitions.sql     — edit date range, then run
111-copy-data.sql             — edit file first (safety gate)
121-swap-table-with-view.sql
```

### Phase 3: Finalize

```
201-remove-old-table.sql                 — edit file first (safety gate); point of no return!
211-pg-cron-create-partitions-daily.sql
212-pg-cron-delete-partitions-daily.sql
```

After phase 3, the system runs autonomously: partitions are created daily at
23:30 and old ones (90+ days) are dropped at 00:05.

## Design notes

- **All new entities are stored in `nodestore` schema.**
- **No PK on either table.** `(id)` btree + `(timestamp)` brin covers all query
  patterns with less overhead than a composite PK btree.
- **No `ON CONFLICT`.** Sentry guarantees unique `(id, timestamp)` at the
  application level. The per-partition `UNIQUE INDEX` on `nodestore.ids` is a
  DB-level safety net.
- **`DETACH PARTITION` without `CONCURRENTLY`.** PostgreSQL prohibits
  `CONCURRENTLY` inside procedures. The plain detach takes `ACCESS EXCLUSIVE`
  — acceptable at 00:05.
- **Data-change guard.** The update trigger skips the UPDATE entirely when
  `OLD."data" IS NOT DISTINCT FROM NEW."data"` — no btree probe, no heap
  write, no WAL for no-op updates.
- **Timestamp defaults.** Insert trigger uses `COALESCE(NEW."timestamp", NOW())`
  if the application sends a NULL timestamp.
- **DELETE is no-op.** Sentry sends bulk DELETEs (`id = ANY(ARRAY[...])`).
  The trigger silently consumes them; actual data removal is handled by the
  retention cron (partition drops).
- **`ids` partitioned by hex prefix.** 16 partitions (`ids_part_0` … `ids_part_f`)
  spread ~181M IDs across independent btrees. Partition pruning during DELETE
  avoids scanning the full set.
- **Idempotent copy.** The `NOT EXISTS` anti-join against `nodestore.ids` makes
  the copy procedure safe to re-run with overlapping date ranges.
