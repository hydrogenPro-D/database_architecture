# Vat dumping history — DB handoff (migration 031)

What migration `031_vat_dump_history.sql` creates, and the exact contract the
application should build against. Implements `VAT_DUMP_HISTORY_DB_SPEC.md`.

Nothing on the plate bath tables or views changed. This log is independent of
them and only shares the vat naming.

---

## Status

| Environment | State |
|---|---|
| `dataloggingTest` | run 031 |
| `dataloggingDev` (production) | **not applied** — at 030; needs 031 |

Check with:

```sql
SELECT name, type_desc FROM sys.objects WHERE name LIKE '%vat_dump%';
-- expect 1 table, 4 views, 3 procedures
```

---

## 1. The table (the app never touches it directly)

```sql
qc.vat_dump_log
    vat_dump_log_id  int IDENTITY  PRIMARY KEY
    vat_id           int           NOT NULL   -- FK -> qc.vat(id)
    dumped_at        datetime2(0)  NOT NULL   -- the day AND time of the dump, one value
    initials         varchar(16)   NULL
    comment          nvarchar(500) NULL
    created_at       datetime2(0)  NOT NULL   -- "Row added", set on insert, never updated
    row_version      rowversion    NOT NULL   -- feeds the change watermark
```

Index: `IX_vat_dump_log_vat_dumped_at (vat_id, dumped_at DESC)`.

`row_version` was not in the spec's column list but is required: the watermark
entities below are built from `MAX(row_version)`, and without it the tabs would
never auto-refresh.

**The vat is a foreign key**, but **the procedures take the vat by NAME**
(`'Vat. 28'`) and resolve it themselves — the app never holds a vat id, exactly
as with `usp_plate_bath_insert @vat=?`.

---

## 2. Read: one view per tab

`qc.vw_vat_dump_28`, `qc.vw_vat_dump_29`, `qc.vw_vat_dump_30`

| # | Column | Type |
|---|---|---|
| 1 | `vat_dump_log_id` | int |
| 2 | `[Row added]` | datetime2 |
| 3 | `[Time of dump]` | datetime2 |
| 4 | `[Initials]` | varchar(16) |
| 5 | `[Comment]` | nvarchar(500) |

* **The id is column 1.** The app maps a table row back to its id by position
  (`ORDER BY [Time of dump], 1`), so an edit or delete would otherwise hit the
  wrong row.
* Both timestamps come back as real `datetime2`, not pre-formatted text — the app
  formats them `dd.MM.yyyy HH:mm` and needs them sortable.
* **The vat is the filter, not a column.** Each view returns one vat's rows only;
  the app does no client-side filtering.

---

## 3. Read: last dump per vat

```sql
qc.vw_vat_dump_latest
    vat        -- v.name, e.g. 'Vat. 28'
    last_dump  -- datetime2, MAX(dumped_at) for that vat
```

Three values for the acid calculator to read on every data load, instead of
pulling three logs it does not otherwise need.

A vat that has never been dumped is **absent from this view** (not a NULL row).
`recently_dumped()` should treat absent and NULL identically as "not recently
dumped".

---

## 4. Write: the three procedures

```sql
qc.usp_vat_dump_insert
    @vat          nvarchar(255),   -- 'Vat. 28' | 'Vat. 29' | 'Vat. 30'
    @time_of_dump datetime2,
    @initials     varchar(16)   = NULL,
    @comment      nvarchar(500) = NULL
-- returns the new id as a one-row, one-column result set: cursor.fetchone()[0]

qc.usp_vat_dump_update
    @vat_dump_log_id int,
    @vat             nvarchar(255),
    @time_of_dump    datetime2,
    @initials        varchar(16)   = NULL,
    @comment         nvarchar(500) = NULL

qc.usp_vat_dump_delete
    @vat_dump_log_id int
```

`created_at` is stamped on insert by a column default (Norway local time) and is
**never changed by an update**.

### Example

```sql
EXEC qc.usp_vat_dump_insert
     @vat = 'Vat. 28', @time_of_dump = '2026-10-15 22:10',
     @initials = 'AB', @comment = 'full dump, refilled same day';
-- -> vat_dump_log_id
```

### Edit window

`_update` and `_delete` refuse a row whose **`created_at`** is older than
yesterday — judged on when the row was *created*, never on `dumped_at`. A dump
entered today for a date last week is still a row created today, so the app will
offer the edit and the procedure will allow it.

Because `created_at` is `NOT NULL` here, there is no permanently-locked
pre-feature history as there is on the measurement logs: every row is editable
for its first two days and read-only afterwards.

### Error codes

| Code | Meaning |
|---|---|
| 50001 | `@time_of_dump` is required |
| 50002 | no row with that `vat_dump_log_id` |
| 50003 | only rows created today or yesterday can be **deleted** |
| 50004 | only rows created today or yesterday can be **edited** |
| 50005 | unknown vat name |

Note: the spec quoted the message as *"Only entries from today or yesterday can
be edited."* That is the pre-018 wording; the procedures use the current house
wording, *"Only rows created today or yesterday can be edited."* The **codes are
unchanged**, and the app maps on codes.

---

## 5. Change watermark

`qc.vw_change_watermark` gains three entities, bringing it from 13 to 16:

```
vat_dump_28
vat_dump_29
vat_dump_30
```

Each counts and versions only that vat's rows, so a dump recorded on one machine
appears on the others within the normal polling interval, and the acid calculator
reprices as soon as it does.

```sql
SELECT entity, max_row_version, row_count
FROM qc.vw_change_watermark WHERE entity LIKE 'vat_dump%';
```

---

## 6. Permissions

`EXECUTE` on the three procedures is granted to `production_data_manager_role`.
The four views need no grant — migration 002 granted `SELECT ON SCHEMA::[qc]`.

**A correction to the spec:** section 6 asked that the login have "no rights on
`qc.vat_dump_log` directly", on the grounds that "every other table is reached
only through its procedures". That is not how this database is set up. The role
has had `SELECT` on *every* table in the `qc` schema since 002, `ph_log` and
`plate_bath_log` included. Reads are routed through views by **convention**, not
by permission; what is genuinely proc-only is **writes** — no table has
`INSERT`/`UPDATE`/`DELETE` granted to the role anywhere.

So `vat_dump_log` is readable exactly like every other table. Making it the one
exception would need an explicit

```sql
DENY SELECT ON OBJECT::[qc].[vat_dump_log] TO [production_data_manager_role];
```

which is deliberately **not** done. Ask if it is genuinely wanted.

---

## 7. What the application still has to do

The database side is complete. The error

```
'DbManager' object has no attribute 'save_vat_dump_data'
```

is app-side: `DbManager` has no method for this yet. It needs, at minimum:

1. **`save_vat_dump_data(...)`** → `EXEC qc.usp_vat_dump_insert`, returning
   `cursor.fetchone()[0]` as the new id.
2. **update / delete** → `usp_vat_dump_update` / `usp_vat_dump_delete`, mapping
   50003 and 50004 to the existing "only today or yesterday" message and 50002 /
   50005 to the usual not-found / unknown-vat handling.
3. **load** → `SELECT * FROM qc.vw_vat_dump_28` (or `_29` / `_30`), ordered
   `[Time of dump]`, then column 1.
4. **`recently_dumped()`** → read `qc.vw_vat_dump_latest`; absent vat means never
   dumped.
5. **polling** → add `vat_dump_28/29/30` to the entities it watches.

Method names are entirely the app's choice — the database imposes only the
procedure and view names above.
