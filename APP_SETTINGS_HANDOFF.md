# App settings — DB handoff (migration 032)

What `032_app_settings.sql` creates, and the contract the application should
build against. Implements `ACID_CALCULATOR_SETTINGS_DB_SPEC.md`, with **one
deliberate change from that spec: history is kept.**

---

## The one thing to know: this table is APPEND-ONLY

The spec proposed `setting_key` as the primary key with an upsert, justified by
*"The limits keep only the current value plus `updated_by` and `updated_at`"*.
That justification was out of date — migration 028 made
`qc.measurement_threshold` append-only. **This table now follows the same shape,
so the two behave identically.**

* A setting is **never updated or deleted**. Each change **appends a row**.
* The **current value of a key is the row with the highest `app_setting_id`**.
* `qc.vw_app_setting` collapses the table to the current values — one row per
  key, which is what the app reads.
* The whole trail is in `qc.app_setting`.

"Latest" is ordered by **`app_setting_id`**, never by `updated_at`: IDENTITY is
strictly monotonic, while two writes in the same second would tie on
`DATETIME2(0)`.

This also closes the gap the spec's own rationale left open. *"A dose everyone
followed last week cannot be explained if the target has since moved"* needs the
**old** value — an upsert would have discarded it.

---

## 1. The table

```sql
qc.app_setting
    app_setting_id  int IDENTITY  PRIMARY KEY   -- version ordering; highest wins
    setting_key     nvarchar(64)  NOT NULL      -- NOT unique: one row per version
    setting_value   nvarchar(200) NOT NULL      -- text; the app parses it
    updated_at      datetime2(0)  NOT NULL      -- default, Norway local time
    updated_by      nvarchar(100) NOT NULL
    row_version     rowversion    NOT NULL      -- feeds the change watermark
```

Index: `IX_app_setting_latest (setting_key, app_setting_id DESC)`.

There is deliberately **no unique constraint on `setting_key`** — several rows
per key is the entire point.

Seeded with today's defaults, `updated_by = '032_seed'`:

```
acid_calculator.target_ph     '4.1'
acid_calculator.window_days   '30'
```

The seed is `NOT EXISTS`-guarded per key, so re-running the migration never adds
a second "initial" version and never resurrects a default over a value somebody
has since set.

**Values are text on purpose.** A decimal and an integer today, possibly neither
tomorrow. The app parses and validates (target pH 3.0–7.0; window 7/14/30/60/90)
and falls back to its defaults when a value will not parse. The database stores
text and does not police the ranges.

---

## 2. Read: current values

```sql
qc.vw_app_setting
    [Setting]      setting_key
    [Value]        setting_value
    [Updated at]   updated_at
    [Updated by]   updated_by
    row_version    row_version
```

One row per key — the newest version. Two rows today, so no filtering is needed;
read the whole view.

`row_version` is on the view because the app passes it back on a write, exactly
as it does for a measurement threshold.

---

## 3. Read: history

Query the table directly — `SELECT ON SCHEMA::[qc]` already covers it:

```sql
SELECT app_setting_id, setting_value, updated_at, updated_by
FROM qc.app_setting
WHERE setting_key = 'acid_calculator.target_ph'
ORDER BY app_setting_id DESC;      -- newest first
```

Same pattern as the measurement limits' history read.

---

## 4. Write

```sql
qc.usp_app_setting_set
    @setting_key          nvarchar(64),
    @setting_value        nvarchar(200),
    @updated_by           nvarchar(100),
    @expected_row_version binary(8) = NULL
```

Appends a new version. **The signature is unchanged from the spec** — only the
implementation differs (append, not upsert), so nothing on the app side has to
change shape to adopt it.

`@expected_row_version` is **optional**: `NULL` means *no check*, so the app can
adopt this before it starts round-tripping the version. When supplied, it is
compared against the **current** row; if a newer version has been appended since
the caller read it, that is a stale write.

```sql
EXEC qc.usp_app_setting_set
     @setting_key = 'acid_calculator.target_ph',
     @setting_value = '4.3',
     @updated_by = 'AB',
     @expected_row_version = 0x...;   -- from vw_app_setting; omit to skip the check
```

### Error codes

| Code | Meaning |
|---|---|
| **50009** | `@expected_row_version` does not match the current row — stale write; refresh and tell the operator somebody else changed it. Same code `usp_measurement_threshold_update` raises. |
| **50010** | a required value is empty: `@setting_key`, `@setting_value` or `@updated_by` |

No new numbers were invented. The app matches on the code, not the message.

---

## 5. Change watermark

`qc.vw_change_watermark` gains one entity, bringing it from 16 to 17:

```
app_setting
```

`row_count` counts **every version**, which is exactly what is wanted — it moves
whenever any setting changes. So a target changed on one machine reaches every
other within the normal polling interval, and each reprices its doses without a
restart.

---

## 6. Permissions

`EXECUTE` on `qc.usp_app_setting_set` for `production_data_manager_role`. The
view needs no grant — `SELECT ON SCHEMA::[qc]` covers it (migration 002).

---

## 7. What the application does

1. Read both keys from `qc.vw_app_setting` at startup and on every `app_setting`
   watermark change.
2. Keep the current defaults — **4.1** and **30 days** — whenever the table
   cannot be read, a key is missing, or a value will not parse. The calculator
   must never be left with nothing to say because a setting is unavailable.
3. Ask for a name when saving and pass it as `@updated_by`, as the limits window
   already does.
4. Stop reading and writing `config/acid_calculator.json`. The file can be
   deleted from any machine that has one.
5. Optionally show a setting's history from `qc.app_setting` — that is now
   possible, and was the point of keeping it.

---

## 8. Still open

* **Is the target genuinely plant-wide?** 032 assumes one target for vats 28, 29
  and 30 together, which is what the app does today. Dotted keys mean a per-vat
  target (`acid_calculator.target_ph.vat_28`) needs **no schema change** — only a
  Settings window with three fields. No such key exists and the app should not
  look for one.

---

## Deployment

`032` **requires `031`** — its watermark reads `qc.vat_dump_log`, and a guard
stops the migration with a clear message otherwise.

| Environment | Needs |
|---|---|
| `dataloggingTest` | whatever is outstanding, then 032 |
| `dataloggingDev` (production) | at 030 → run **031**, then **032** |

Verify:

```sql
SELECT * FROM qc.vw_app_setting;          -- 2 rows: 4.1 and 30
SELECT entity, row_count FROM qc.vw_change_watermark WHERE entity = 'app_setting';

-- the append-only proof: change one, then look at both
EXEC qc.usp_app_setting_set @setting_key='acid_calculator.target_ph',
     @setting_value='4.3', @updated_by='test';
SELECT * FROM qc.vw_app_setting;          -- still 2 rows, target now 4.3
SELECT * FROM qc.app_setting ORDER BY app_setting_id;   -- 3 rows: 4.1 kept
```
