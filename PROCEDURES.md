# qc Stored Procedures — App Integration Guide

How the application reads and writes Plating-Line QC data. **Reads** come from the
`qc.vw_*` views; **writes** go *only* through the `qc.usp_*` stored procedures
below (the app's DB login has no direct table access — `SELECT` on the `qc`
schema + `EXECUTE` on these procs, nothing else).

There are **8 event types**, each with `insert` / `update` / `delete`.

---

## 1. Connecting

- Driver: **ODBC Driver 18 for SQL Server**; Azure SQL (`Encrypt=yes`).
- Log in as a user that is a member of **`qc_data_manager_role`** (or an admin).
- One database per connection (`dataloggingTest` or `dataloggingDev`); there is no `USE`.

```python
import pyodbc, json
conn = pyodbc.connect(
    "DRIVER={ODBC Driver 18 for SQL Server};"
    "SERVER=tcp:<server>.database.windows.net,1433;DATABASE=dataloggingTest;"
    "UID=<user>;PWD=<pwd>;Encrypt=yes;TrustServerCertificate=no;",
    autocommit=False)
```

---

## 2. Rules that apply to ALL procedures

- **Singular fields are scalar params; anything that is a list is one JSON param**
  (`@vats` or `@measurements`), built with `json.dumps(...)`.
- **`insert` returns the new id** as a one-row result set → `cur.fetchone()[0]`.
  `update` and `delete` return nothing.
- **`update` REPLACES children.** Always send the **complete current state** of the
  wide row, not a delta — the proc deletes all child rows and rebuilds them from
  what you pass.
- **Edit/delete lock:** for the 7 event entities (pH, adding-chemicals, conductivity,
  4 baths) `update`/`delete` only work when the row was **created today or yesterday**
  — based on **`Row added`** (`created_at`), *not* the entered `Date` (server-side,
  Norwegian time). A blank `Row added` (pre-feature history) is locked. `insert` is
  never locked. *(Production tracking still locks on its `date`.)*
- **`Row added`:** every event view returns a `Row added` column (the row's real
  creation timestamp; blank for old history). Show it first, format `dd.MM.yyyy HH:mm`,
  and drive editability off it. Order rows with `ORDER BY [Date], [id]` — the views are
  unordered and `[Date]` stays a real date so past-dated rows sort into place.
- **Vats are passed by name** exactly: `'Vat. 17'`, `'Vat. 28'`, … (note the dot + space).
- **`chemical_id`** values come from `SELECT id, name FROM qc.chemical;`.
- Each proc runs in its own transaction; on any error it rolls back and raises —
  catch `pyodbc.Error` and show `err.args[1]` (the message) to the user.
- Commit yourself after a successful call (`conn.commit()`), since `autocommit=False`.

### Error codes (the `THROW` messages)

| # | Meaning |
|---|---|
| 50001 | Date is required |
| 50002 | `<entity>` id not found |
| 50003 | Only rows **created** today or yesterday can be **deleted** (event entities: by `Row added`) |
| 50004 | Only rows **created** today or yesterday can be **edited** (event entities: by `Row added`) |
| 50005 | Unknown vat in payload (message includes the bad name) |
| 50006 | Payload is not valid JSON |
| 50007 | Measured by is required (baths) |

### A reusable helper

```python
def call_insert(cur, sql, *params):
    """EXEC an insert proc and return the new id; caller commits."""
    return cur.execute(sql, *params).fetchone()[0]
```

---

## 3. pH Control  → `qc.usp_ph_control_*`

**Scalar:** `@date` (required), `@initials`, `@time_of_measurement`,
`@sample_taken_time`, `@time_when_added`, `@notes`.
**JSON `@vats`** — one entry per vat; an optional single pH-adjust chemical + a list of readings:

```jsonc
[ { "vat": "Vat. 28", "chemical_id": 1, "amount": 2.0,
    "readings": [ {"measurement_number": 1, "ph_value": 4.47},
                  {"measurement_number": 2, "ph_value": 4.45} ] },
  { "vat": "Vat. 31", "readings": [ {"measurement_number": 1, "ph_value": -0.19} ] } ]
```

```python
vats = [ {"vat":"Vat. 28","chemical_id":1,"amount":2.0,
          "readings":[{"measurement_number":1,"ph_value":4.47},
                      {"measurement_number":2,"ph_value":4.45}]},
         {"vat":"Vat. 31","readings":[{"measurement_number":1,"ph_value":-0.19}]} ]

new_id = call_insert(cur,
    "EXEC qc.usp_ph_control_insert @date=?, @initials=?, @time_of_measurement=?, "
    "@sample_taken_time=?, @time_when_added=?, @notes=?, @vats=?",
    "2026-06-25", "CM", "08:00:00", None, "07:30:00", None, json.dumps(vats))
conn.commit()

# update: same params, with @ph_log_id first
cur.execute("EXEC qc.usp_ph_control_update @ph_log_id=?, @date=?, @vats=?",
            new_id, "2026-06-25", json.dumps(vats)); conn.commit()

# delete
cur.execute("EXEC qc.usp_ph_control_delete @ph_log_id=?", new_id); conn.commit()
```

---

## 4. Adding Chemicals  → `qc.usp_adding_chemicals_*`

**Scalar:** `@date` (required), `@added_by`, `@time_when_added`, `@notes`.
**JSON `@vats`** — per vat: optional `water_level` (only 28/29/30/31) + a list of chemicals (`concentration` optional, HCl only):

```jsonc
[ { "vat": "Vat. 28", "water_level": 5,
    "chemicals": [ {"chemical_id": 1, "amount": 2.025},
                   {"chemical_id": 2, "amount": 0.795} ] },
  { "vat": "Vat. 31",
    "chemicals": [ {"chemical_id": 9, "amount": 1.5, "concentration": 30} ] } ]
```

```python
new_id = call_insert(cur,
    "EXEC qc.usp_adding_chemicals_insert @date=?, @added_by=?, @time_when_added=?, @notes=?, @vats=?",
    "2026-06-25", "CM", "07:30:00", None, json.dumps(vats))
conn.commit()
# update: @chemical_addition_log_id first, then the same params
# delete: EXEC qc.usp_adding_chemicals_delete @chemical_addition_log_id=?
```

---

## 5. Production Tracking  → `qc.usp_production_tracking_*`

**Scalar:** `@shift`, `@date` (required), `@tu_dose`, `@ba_dose`, `@co_dose`
(cobalt sulphate g/electrode, optional), `@chemical_addition_log_id` (provenance, optional).
**JSON `@vats`** — per plating vat; `prod_electrodes_sum` required, `prod_electrodes_shift` optional (may be negative):

```jsonc
[ {"vat":"Vat. 28","prod_electrodes_sum":1200,"prod_electrodes_shift":40},
  {"vat":"Vat. 30","prod_electrodes_sum":1000,"prod_electrodes_shift":-2} ]
```

```python
new_id = call_insert(cur,
    "EXEC qc.usp_production_tracking_insert @shift=?, @date=?, @tu_dose=?, @ba_dose=?, @co_dose=?, "
    "@chemical_addition_log_id=?, @vats=?",
    "Night", "2026-06-25", 135.0, 53.0, None, None, json.dumps(vats))
conn.commit()
# update: @electrode_production_tracking_id first, then the same params
# delete: EXEC qc.usp_production_tracking_delete @electrode_production_tracking_id=?
```

---

## 6. Conductivity  → `qc.usp_conductivity_*`

**Scalar:** `@date` (required), `@logged_by`, `@observation`.
**JSON `@vats`** — per rinse reading; `vat`, `stage`, `rinse_number` + `conductivity`.
`stage` is `Cathodic` / `Activation` / `Plating` / `Strike`; it's what splits
`Vat. 25` between its legacy Plating readings and the new **Strike Rinse 1 - pos.25**
column. Pivot is by vat (+stage for Vat. 25), so send the physical `vat` and its `stage`:

```jsonc
[ {"vat":"Vat. 14","stage":"Cathodic","rinse_number":1,"conductivity":3680},
  {"vat":"Vat. 25","stage":"Strike",  "rinse_number":1,"conductivity":730},
  {"vat":"Vat. 24","stage":"Plating", "rinse_number":1,"conductivity":361} ]
```

```python
new_id = call_insert(cur,
    "EXEC qc.usp_conductivity_insert @date=?, @logged_by=?, @observation=?, @vats=?",
    "2026-06-25", "CM", None, json.dumps(vats))
conn.commit()
# update: @conductivity_log_id first, then the same params
# delete: EXEC qc.usp_conductivity_delete @conductivity_log_id=?
```

---

## 7. Baths — Cleaner / Activator / Strike / Plate

Four identical proc sets; pick the one for the tab. **All take `@vat`.**

| Bath | Procs | `@vat` |
|---|---|---|
| Cleaner | `qc.usp_cleaner_bath_*` | `'Vat. 17'` |
| Activator | `qc.usp_activator_bath_*` | `'Vat. 18'` |
| Strike | `qc.usp_strike_bath_*` | `'Vat. 31'` |
| Plate | `qc.usp_plate_bath_*` | `'Vat. 28'` / `'Vat. 29'` / `'Vat. 30'` |

**Scalar:** `@date` (required), `@vat` (required), `@measured_by` (required), `@notes`.
**JSON `@measurements`** — flat list discriminated by `measurement_type` + `measurement_number`:

```jsonc
[ {"measurement_type":"pH","measurement_number":1,"measurement":4.58},
  {"measurement_type":"pH","measurement_number":2,"measurement":4.60},
  {"measurement_type":"Ni2+ Titration_ml","measurement_number":1,"measurement":10.14} ]
```

```python
new_id = call_insert(cur,
    "EXEC qc.usp_plate_bath_insert @date=?, @vat=?, @measured_by=?, @notes=?, @measurements=?",
    "2026-06-25", "Vat. 28", "CM", None, json.dumps(measurements))
conn.commit()
# update: @<bath>_bath_log_id first, then the same params
#   e.g. EXEC qc.usp_plate_bath_update @plate_bath_log_id=?, @date=?, @vat=?, @measured_by=?, @measurements=?
# delete: EXEC qc.usp_<bath>_bath_delete @<bath>_bath_log_id=?
```

### Allowed `measurement_type` values (must match exactly)

| Bath | `measurement_type` (each with `measurement_number` 1 and 2) |
|---|---|
| Cleaner | `pH`, `Titration step 1`, `Titration step 2`, `Schloetter protocol` |
| Activator | `pH`, `Decasel5 Titration_ml`, `Nickel Titration_ml` |
| Strike | `pH`, `Ni2+ Titration_ml`, `Cl- Titration_ml`, `HCl+ Titration_ml` |
| Plate | `pH`, `Ni2+ Titration_ml`, `Cl- Titration_ml`, `ThioUrea Titration_ml`, `Boric Acid Titration_ml` |

---

## 8. Editing flow (important)

To edit an existing wide row:
1. Read it from the view (e.g. `qc.vw_ph_control WHERE ph_log_id = ?`).
2. Let the user change fields.
3. Call the **`update`** proc with the **full** row + its id — every child you want
   to keep must be in the payload, because update rebuilds children from scratch.

The view's `…_id` column (e.g. `ph_log_id`, `chemical_addition_log_id`,
`plate_bath_log_id`) is the id you pass to `update`/`delete`.

> Note: the view's chemical cells are display labels (e.g. `"2 L NaOH"`). For
> writes you send **structured** values (`chemical_id` + `amount`), not the label —
> keep the underlying ids in the app's edit state.

---

## 9. Dosage-rate change log  → `qc.usp_electrode_chemical_dosage_insert`

The Production Tracking adjustment calculator logs every TU/BA/cobalt dosing-rate
change. **Append-only** — no update/delete proc; a mistake is fixed with a new row.

**Scalar:** `@date` (`DATETIME2` — full timestamp of the change), `@name`,
`@tu_value` (int), `@ba_value` (int), `@co_value` (int, optional). Returns the new `id`.

```python
new_id = call_insert(cur,
    "EXEC qc.usp_electrode_chemical_dosage_insert @date=?, @name=?, @tu_value=?, @ba_value=?, @co_value=?",
    datetime.now(), "Csenger", 135, 40, None)
conn.commit()
```

**Read** it back from `qc.vw_electrode_chemical_dosage` (splits the timestamp into
separate `date` + `time` columns): `SELECT … ORDER BY [date], [time], id`.

## 10. Change polling  → `qc.vw_change_watermark`

Poll this one view (not the pivot views) every few seconds to learn which tab
changed. One row per tab, `entity` is a stable key:

```sql
SELECT entity, max_row_version, row_count FROM qc.vw_change_watermark;
```

`max_row_version` (BIGINT, 0 when empty) rises on any insert/edit; `row_count`
falls on delete. If **either** changed since your last poll, reload that tab.
`entity` keys: `ph_control`, `adding_chemicals`, `production_tracking`,
`conductivity`, `cleaner`, `activator`, `strike`, `plate_28`, `plate_29`,
`plate_30`, `chemical_change_log`.
