# Plating Line 1 QC — Database Load Handoff

This document describes a set of **21 clean, load-ready CSV files** produced by an
ETL pipeline from a plating-line Quality-Control application. Your job (in the new
repo) is to write the **MSSQL schema (DDL) and the load scripts** that ingest these
CSVs. This file is everything you need — you do not need the source app.

The CSVs are normalized, referentially consistent fact/dimension tables. Every
table already has **explicit integer surrogate `id`s** (contiguous `1..N`) and all
foreign keys are pre-resolved and verified (0 broken references at handoff).

---

## 1. CSV conventions (apply to ALL files)

- **Encoding:** UTF-8, comma-delimited, first row is the header, `"`-quoted where needed.
- **Primary keys:** the `id` column is an explicit surrogate key, **contiguous `1..N`** per file.
  → Define `id` as `INT IDENTITY` and **load with `SET IDENTITY_INSERT <table> ON`** to preserve the ids the FKs rely on.
- **NULLs:** an **empty field means NULL** (not empty string / not 0). This matters for nullable FKs, optional times, and optional text. Configure your bulk loader to treat `''` as NULL.
- **Dates:** ISO `YYYY-MM-DD` → `DATE`.
- **Times of day** (`sample_taken_time`, `time_of_measurement`, `chemical_addition_time`, `time_when_added`): bare `HH:MM:SS`. These are clock times with **no date**. Prefer the **`TIME`** type. (If you use `DATETIME2`, a bare time loads as `1900-01-01 HH:MM:SS`.)
- **Full timestamps:** `electrode_chemical_dosage.date` is a real `YYYY-MM-DD HH:MM:SS` → `DATETIME2`.
- **Decimals:** always use `.` as the separator (comma decimals were normalized away). Numeric measurement/amount/conductivity values can have decimals (and negatives, e.g. strike pH `-0.19`) → use `DECIMAL`/`FLOAT`, not `INT`.
- **Text:** names/notes/types fit `NVARCHAR(255)`.

---

## 2. Dimensions / reference tables

### `vat.csv` — 16 rows · `id, name, type`
Physical tanks on the line. `name` is unique (`"Vat. <number>"`); `type` is one of:
`cleaner`, `activation`, `plating`, `strike` (the 6 process baths, ids 1–6) and
`cleaner rinse`, `activation rinse`, `plating rinse` (10 rinse tanks, ids 7–16).
The number in the name is the physical position (process baths 17/18/28/29/30/31;
rinse tanks 12/13/14/19/20/21/22/23/24/25).

### `chemical.csv` — 9 rows · `id, name, unit`
Chemical catalog. `name` unique (e.g. `NiCl2*6H2O`, `TU`, `BA`, `NaOH`, `H2SO4`, `HCl`,
`Slotoclean EL DCG`, `Slotoclean Decasel 5`). `unit` is `kg` or `L`.

### `electrode_chemical_dosage.csv` — 2 rows · `id, date, name, tu_value, ba_value`
The TU/BA **per-electrode dosing rates** over time and who set them. `date` is a full
`DATETIME2`. `tu_value`/`ba_value` are g/electrode (`INT`). Standalone (no FKs).

---

## 3. pH control (3 tables)

One measurement session fans out to the vats measured, each with 1–2 pH readings.

### `ph_log.csv` — 588 · `id, date, sample_taken_time, time_of_measurement, measured_by, notes`
`date` NOT NULL. Times are bare `HH:MM:SS` (nullable). `measured_by`, `notes` nullable.

### `ph_log_vat.csv` — 1763 · `id, vat_id, ph_log_id, chemical_id, chemical_amount, chemical_addition_time`
One row per vat involved in a session. `chemical_id`/`chemical_amount`/`chemical_addition_time`
are **nullable** (filled only when a pH-adjust chemical was added that session).

### `ph_measurement.csv` — 2591 · `id, ph_log_vat_id, measurement_number, ph_value`
One row per reading. `measurement_number` ∈ {1,2}; `ph_value` `DECIMAL` (can be negative for strike).

---

## 4. Chemical additions (3 tables)

Chemicals added to vats (manual additions + auto-calculated TU/BA dosing).

### `chemical_addition_log.csv` — 411 · `id, date, time_when_added, added_by, notes`
`date` NOT NULL. `time_when_added` bare time (nullable). `added_by`, `notes` nullable.

### `chemical_addition_log_vat.csv` — 1075 · `id, vat_id, chemical_additions_log_id, water_level_reduction`
⚠️ FK column is **`chemical_additions_log_id`** (note the plural "additions") → `chemical_addition_log.id`.
`water_level_reduction` is cm (`INT`, nullable).

### `chemical_addition.csv` — 2105 · `id, chemical_addition_log_vat_id, chemical_id, chemical_amount, concentration`
One row per chemical in a cell. `chemical_amount` `DECIMAL`. `concentration` is **nullable** —
only HCl rows carry it (value `30`, i.e. 30% HCl); everything else is NULL.

---

## 5. Electrode production (2 tables)

Per-shift electrode counts and the chemical dosing each shift triggered.

### `electrode_production_tracking.csv` — 336 · `id, chemical_addition_log_id, shift, date, TU (g/electrode), BA (g/electrode)`
- `chemical_addition_log_id` → `chemical_addition_log.id`, **NULLABLE** (a shift that produced
  zero electrodes dosed nothing → NULL; all dosing shifts are matched).
- `shift` **NULLABLE** (normalized labels: `Night`, `Day`, `Evening`, `12h Day`, `Night/Day`, `Downtime`).
- `date` nullable; rate columns `INT`. Column names contain spaces/parens — quote them as identifiers.

### `electrode_production_vat.csv` — 1008 · `id, electrode_production_tracking_id, vat_id, prod_electrodes_sum, prod_electrodes_shift`
Three rows per tracking row (Vat 28/29/30). `prod_electrodes_sum` (cumulative, NOT NULL `INT`),
`prod_electrodes_shift` (per-shift, nullable `INT`, can rarely be negative — a known source typo).

---

## 6. Conductivity (2 tables)

Weekly rinse-tank conductivity. **Note:** this was simplified from the original 3-level
design to 2 levels — each rinse tank is its own vat, so the per-reading table holds the
reading directly (there is **no** `conductivity_vat_rinse` and **no** `position` column).

### `conductivity_log.csv` — 43 · `id, date, logged_by, observation`
`date` NOT NULL. `logged_by`, `observation` nullable.

### `conductivity_vat_log.csv` — 382 · `id, conductivity_log_id, vat_id, rinse_number, conductivity`
One row per non-empty rinse reading. `vat_id` → a **rinse** vat (ids 7–16). `rinse_number` is the
cascade order (`INT`, NOT derivable from position — keep it). `conductivity` is **`DECIMAL`** (µS/cm; has decimals).

---

## 7. Bath measurements (4 baths × 2 tables = 8 tables)

`cleaner`, `activator`, `strike`, `plate` all share one structure. The **plate** tables
cover all three plate baths (Vat 28/29/30), distinguished by `vat_id`.

### `<bath>_bath_log.csv` · `id, date, vat_id, measured_by, notes`
`date` NOT NULL, `vat_id` → `vat.id`, `measured_by` **NOT NULL**, `notes` nullable.
Row counts: cleaner 74 (Vat 17), activator 66 (Vat 18), strike 86 (Vat 31), plate 236 (Vat 28/29/30).

### `<bath>_bath_measurement.csv` · `id, <bath>_bath_log_id, measurement_number, measurement, measurement_type`
One row per non-empty reading. `measurement_number` ∈ {1,2}; `measurement` `DECIMAL`;
`measurement_type` `NVARCHAR`. Row counts: cleaner 323, activator 334, strike 443, plate 1933.

`measurement_type` values by bath:
- **cleaner:** `pH`, `Titration step 1`, `Titration step 2`, `Schloetter protocol`
- **activator:** `pH`, `Decasel5 Titration_ml`, `Nickel Titration_ml`
- **strike:** `pH`, `Ni2+ Titration_ml`, `Cl- Titration_ml`, `HCl+ Titration_ml`
- **plate:** `pH`, `Ni2+ Titration_ml`, `Cl- Titration_ml`, `ThioUrea Titration_ml`, `Boric Acid Titration_ml`

---

## 8. Foreign keys (complete list)

```
ph_log_vat.ph_log_id                       -> ph_log.id
ph_log_vat.vat_id                          -> vat.id
ph_log_vat.chemical_id                     -> chemical.id            (nullable)
ph_measurement.ph_log_vat_id               -> ph_log_vat.id

chemical_addition_log_vat.chemical_additions_log_id -> chemical_addition_log.id
chemical_addition_log_vat.vat_id           -> vat.id
chemical_addition.chemical_addition_log_vat_id      -> chemical_addition_log_vat.id
chemical_addition.chemical_id              -> chemical.id

electrode_production_tracking.chemical_addition_log_id -> chemical_addition_log.id (nullable)
electrode_production_vat.electrode_production_tracking_id -> electrode_production_tracking.id
electrode_production_vat.vat_id            -> vat.id

conductivity_vat_log.conductivity_log_id   -> conductivity_log.id
conductivity_vat_log.vat_id                -> vat.id

cleaner_bath_measurement.cleaner_bath_log_id     -> cleaner_bath_log.id
activator_bath_measurement.activator_bath_log_id -> activator_bath_log.id
strike_bath_measurement.strike_bath_log_id       -> strike_bath_log.id
plate_bath_measurement.plate_bath_log_id         -> plate_bath_log.id
cleaner_bath_log.vat_id / activator_bath_log.vat_id / strike_bath_log.vat_id / plate_bath_log.vat_id -> vat.id
```

## 9. Recommended load order (parents before children)

1. `vat`, `chemical`, `electrode_chemical_dosage`
2. `chemical_addition_log` → `chemical_addition_log_vat` → `chemical_addition`
3. `electrode_production_tracking` (FKs to `chemical_addition_log`) → `electrode_production_vat`
4. `ph_log` → `ph_log_vat` → `ph_measurement`
5. `conductivity_log` → `conductivity_vat_log`
6. each `<bath>_bath_log` → `<bath>_bath_measurement`

(Load every table with `SET IDENTITY_INSERT … ON`.)

## 10. Schema deltas already decided (vs. the original Draw DB plan)

If you're regenerating DDL, bake these in — the CSVs already reflect them:
- `conductivity`: **DECIMAL**, not INTEGER.
- `chemical_addition.concentration`: added (nullable, for HCl %).
- `electrode_production_tracking.chemical_addition_log_id` and `.shift`: **nullable**.
- Conductivity collapsed to 2 tables (`conductivity_log` + `conductivity_vat_log`); `conductivity_vat_rinse` and the `position` column were dropped.
- `vat` table got the 10 rinse tanks (ids 7–16) added.
