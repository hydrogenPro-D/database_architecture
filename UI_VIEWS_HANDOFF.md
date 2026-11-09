# Plating Line 1 QC — UI Rows → Database Views Handoff

This document explains **how each row shown in the app's UI maps back to the
normalized database tables**, so you can write SQL `CREATE VIEW` statements that
re-assemble the wide "one line per record" rows the user sees.

It is the companion to the schema handoff (`DB_HANDOFF.md`, which describes the
21 normalized tables). Read this one for the **denormalized shape** each view
must produce and the join/pivot logic to get there.

Target engine: **Microsoft SQL Server (T-SQL)**.

---

## 0. The core idea

Every UI tab shows a **wide row**: one calendar event (a measurement session, an
addition event, a production shift, a weekly conductivity round) with many
columns. The database stores each wide row **normalized into 2–3 tables**:

```
   <event/log>   (one row per UI row — the date, who, notes, times)
     └─ <…_vat / …_log_vat>   (one row per vat involved in that event)
          └─ <…_measurement / …_addition>   (one row per individual reading/chemical)
```

So a view must **collapse the child rows back up into the parent row**, turning
*rows* (per vat, per reading) back into *columns* (per vat, per reading slot).

### The one technique you need: conditional-aggregation pivot

The measurement/addition children carry a **discriminator** — a `vat_id`, a
`measurement_type`, a `measurement_number`, or a combination. Each distinct
discriminator value becomes one wide column:

```sql
MAX(CASE WHEN <discriminator matches> THEN <value column> END) AS "<wide column>"
```

Grouped by the parent log id, this rebuilds one wide row per event. Because at
most one child row exists per (parent, discriminator) combination, `MAX` just
picks that single value (use `MIN`/`MAX` interchangeably). Missing child rows
naturally yield `NULL` — which is exactly what the UI shows as an empty cell.

### Pivot on `vat.name`, not `vat_id`

The surrogate `vat_id` integers are an internal detail. Every pivot below keys
on the stable natural name in `vat.name` (`'Vat. 28'`, `'Vat. 14'`, …). Join
the child to `vat` and discriminate on `vat.name`.

---

## 1. Scope — what the views reconstruct (and what they don't)

**In scope:** every column the user *entered or measured* — the persisted raw
values. These are what the database stores.

**Out of scope:** the UI also shows many **derived columns** — means, `[g/L]`
concentration conversions, `[H+]`, Decasel/Schloetter results, and the
reaction/tolerance limit columns. **None of these are in the database.** They are
computed at display time in the app from constants in `config/config.json`
(conversion factors, multipliers, limits). Do **not** try to source them from a
table — they aren't there. A view reconstructs the *inputs*; the app derives the
rest. (If they're ever wanted in SQL, they'd be computed columns using the
config constants, which is a separate exercise.)

NULL / formatting conventions (same as `DB_HANDOFF.md`): empty cell = `NULL`;
dates are `DATE`; bare clock fields are `TIME`; decimals use `.`; conductivity
and measurements are `DECIMAL`/`FLOAT`.

---

## 2. pH Control  → view `vw_ph_control`

**UI tab:** "pH Control". One row = one pH measurement session.

**Wide columns shown:** `Date`, `Initials`, `pH Vat. 28 1 meas.`,
`pH Vat. 28 2 meas.`, `pH Vat. 29 1 meas.`, `pH Vat. 29 2 meas.`,
`pH Vat. 30 1 meas.`, `pH Vat. 30 2 meas.`, `pH Vat. 31 - Strike`,
`Time of measurement`, `Sample taken time`, `Time when added`,
`Added to vat.28 (L)`, `Added to vat.29 (L)`, `Added to vat.30 (L)`,
`Added to vat.31 (kg)`, `Notes`.

**Source tables:** `ph_log` (session) → `ph_log_vat` (per vat) → `ph_measurement`
(per reading).

**Mapping:**

| Wide column | Source |
|---|---|
| `Date` | `ph_log.date` |
| `Initials` | `ph_log.measured_by` |
| `Time of measurement` | `ph_log.time_of_measurement` |
| `Sample taken time` | `ph_log.sample_taken_time` |
| `Notes` | `ph_log.notes` |
| `pH Vat. 28 1 meas.` | `ph_measurement.ph_value` where vat = `'Vat. 28'`, `measurement_number = 1` |
| `pH Vat. 28 2 meas.` | … vat `'Vat. 28'`, `measurement_number = 2` |
| `pH Vat. 29 1/2 meas.` | … vat `'Vat. 29'`, number 1 / 2 |
| `pH Vat. 30 1/2 meas.` | … vat `'Vat. 30'`, number 1 / 2 |
| `pH Vat. 31 - Strike` | … vat `'Vat. 31'`, `measurement_number = 1` (strike has a single reading) |
| `Added to vat.28 (L)` | `ph_log_vat.chemical_amount` where vat = `'Vat. 28'` (the pH-adjust chemical dosed that session; optionally `JOIN chemical` for its name) |
| `Added to vat.29/30/31` | `ph_log_vat.chemical_amount` where vat = `'Vat. 29'` / `'Vat. 30'` / `'Vat. 31'` |
| `Time when added` | `ph_log_vat.chemical_addition_time` (same across a session — take any non-NULL, e.g. `MAX`) |

**Pivot path:** the pH readings come from `ph_measurement` (two joins deep), while
the chemical addition comes from `ph_log_vat` (one join deep). Aggregate both
grouped by `ph_log.id`.

> **Note on the "Added to…" cells.** In the original sheet these were free text
> like `"2 L NaOH"`. The DB split that into `chemical_id` + `chemical_amount`. The
> view can expose just the numeric `chemical_amount` (matching the `(L)`/`(kg)`
> header), or rebuild the full label as
> `CONCAT(chemical_amount, ' ', chemical.unit, ' ', chemical.name)`. (Header unit
> note: Vat 31 is labeled `(kg)` in the UI; pick whichever the consuming side
> expects.)

**Worked example:**

```sql
CREATE VIEW vw_ph_control AS
SELECT
    l.id                                          AS ph_log_id,
    l.date                                        AS [Date],
    l.measured_by                                 AS [Initials],
    MAX(CASE WHEN v.name = 'Vat. 28' AND m.measurement_number = 1 THEN m.ph_value END) AS [pH Vat. 28 1 meas.],
    MAX(CASE WHEN v.name = 'Vat. 28' AND m.measurement_number = 2 THEN m.ph_value END) AS [pH Vat. 28 2 meas.],
    MAX(CASE WHEN v.name = 'Vat. 29' AND m.measurement_number = 1 THEN m.ph_value END) AS [pH Vat. 29 1 meas.],
    MAX(CASE WHEN v.name = 'Vat. 29' AND m.measurement_number = 2 THEN m.ph_value END) AS [pH Vat. 29 2 meas.],
    MAX(CASE WHEN v.name = 'Vat. 30' AND m.measurement_number = 1 THEN m.ph_value END) AS [pH Vat. 30 1 meas.],
    MAX(CASE WHEN v.name = 'Vat. 30' AND m.measurement_number = 2 THEN m.ph_value END) AS [pH Vat. 30 2 meas.],
    MAX(CASE WHEN v.name = 'Vat. 31' AND m.measurement_number = 1 THEN m.ph_value END) AS [pH Vat. 31 - Strike],
    MAX(CASE WHEN v.name = 'Vat. 28' THEN lv.chemical_amount END)         AS [Added to vat.28 (L)],
    MAX(CASE WHEN v.name = 'Vat. 29' THEN lv.chemical_amount END)         AS [Added to vat.29 (L)],
    MAX(CASE WHEN v.name = 'Vat. 30' THEN lv.chemical_amount END)         AS [Added to vat.30 (L)],
    MAX(CASE WHEN v.name = 'Vat. 31' THEN lv.chemical_amount END)         AS [Added to vat.31 (kg)],
    l.time_of_measurement                         AS [Time of measurement],
    l.sample_taken_time                           AS [Sample taken time],
    MAX(lv.chemical_addition_time)                AS [Time when added],
    l.notes                                       AS [Notes]
FROM ph_log l
LEFT JOIN ph_log_vat lv     ON lv.ph_log_id = l.id
LEFT JOIN vat v             ON v.id = lv.vat_id
LEFT JOIN ph_measurement m  ON m.ph_log_vat_id = lv.id
GROUP BY l.id, l.date, l.measured_by, l.time_of_measurement,
         l.sample_taken_time, l.notes;
```

---

## 3. Adding Chemicals  → view `vw_adding_chemicals`

**UI tab:** "Chemicals". One row = one chemical-addition event.

**Wide columns shown:** `Date`, `Initials`, `Vat. 17 (Cathodic) (kg)`,
`Vat. 18 (Activation ) (kg)`, `Vat. 28 (Plating 1) (kg)`,
`Vat. 28 (Plating 1) Water Level Reduction (cm)`, `Vat. 29 (Plating 2) (kg)`,
`Vat. 29 … Water Level Reduction (cm)`, `Vat. 30 (Plating 3) (kg)`,
`Vat. 30 … Water Level Reduction (cm)`, `Vat. 31 (Strike) (kg)`,
`Vat. 31 … Water Level Reduction (cm)`, `Time when added`, `Notes`.

**Source tables:** `chemical_addition_log` (event) → `chemical_addition_log_vat`
(per vat; holds `water_level_reduction`) → `chemical_addition` (per chemical;
holds `chemical_id`, `chemical_amount`, `concentration`).

⚠️ The FK column on the middle table is **`chemical_additions_log_id`** (plural
"additions") → `chemical_addition_log.id`.

**Mapping:**

| Wide column | Source |
|---|---|
| `Date` | `chemical_addition_log.date` |
| `Initials` | `chemical_addition_log.added_by` |
| `Time when added` | `chemical_addition_log.time_when_added` |
| `Notes` | `chemical_addition_log.notes` |
| `Vat. 17 (Cathodic) (kg)` | the chemicals dosed to vat `'Vat. 17'` this event |
| `Vat. 18 (Activation ) (kg)` | chemicals dosed to `'Vat. 18'` |
| `Vat. 28/29/30/31 … (kg)` | chemicals dosed to `'Vat. 28'` / `'Vat. 29'` / `'Vat. 30'` / `'Vat. 31'` |
| `Vat. 28/29/30/31 … Water Level Reduction (cm)` | `chemical_addition_log_vat.water_level_reduction` for that vat (Vat 17 & 18 have **no** water-level column) |

> **Reconstructing a `(kg)` cell.** The original cell concatenated several
> chemicals: `"2.025 kg TU 0.795 kg BA"`. The DB split it into one
> `chemical_addition` row per chemical. To rebuild the displayed string, join
> `chemical` for the name/unit and **`STRING_AGG`** the parts per vat:
> ```sql
> STRING_AGG(
>     CONCAT(ca.chemical_amount, ' ', ch.unit, ' ', ch.name,
>            CASE WHEN ca.concentration IS NOT NULL
>                 THEN CONCAT(' ', ca.concentration, '%') END),
>     ' ')
> ```
> Only `HCl` rows carry a `concentration` (e.g. `30`); for all others it's NULL.
> Alternatively, expose the normalized parts instead of the concatenated string —
> your call depending on what consumes the view.

Because there are **two child grains** (water level on `…_log_vat`, chemicals on
`…_addition`), assemble the per-vat `STRING_AGG` of chemicals in a subquery /
CTE first, then pivot both that and `water_level_reduction` grouped by the log
id. (Aggregating across both grains in one flat `GROUP BY` would multiply the
water-level value by the chemical count — fold the chemicals to one string per
(log, vat) **before** joining.)

---

## 4. Production Tracking  → view `vw_production_tracking`

**UI tab:** "Production Tracking". One row = one production shift. (The UI derives
two views — cumulative "all electrodes produced" and "this shift" — from the
same row; both numbers are stored.)

**Wide columns shown:** `Shift`, `Date`, `Vat 28`, `Vat 29`, `Vat 30`
(cumulative counters), plus per-shift `Vat 28 (shift)`, `Vat 29 (shift)`,
`Vat 30 (shift)`, and the rate columns `TU (g/electrode)`, `BA (g/electrode)`.

**Source tables:** `electrode_production_tracking` (the shift) →
`electrode_production_vat` (per plating vat: `prod_electrodes_sum` cumulative,
`prod_electrodes_shift` per-shift).

**Mapping:**

| Wide column | Source |
|---|---|
| `Shift` | `electrode_production_tracking.shift` |
| `Date` | `electrode_production_tracking.date` |
| `TU (g/electrode)` | `electrode_production_tracking.[TU (g/electrode)]` |
| `BA (g/electrode)` | `electrode_production_tracking.[BA (g/electrode)]` |
| `Vat 28` (cumulative) | `electrode_production_vat.prod_electrodes_sum` where vat = `'Vat. 28'` |
| `Vat 29` / `Vat 30` (cumulative) | `prod_electrodes_sum` where vat = `'Vat. 29'` / `'Vat. 30'` |
| `Vat 28 (shift)` | `electrode_production_vat.prod_electrodes_shift` where vat = `'Vat. 28'` |
| `Vat 29 (shift)` / `Vat 30 (shift)` | `prod_electrodes_shift` where vat = `'Vat. 29'` / `'Vat. 30'` |

Straight pivot of `electrode_production_vat` on `vat.name` (three plating vats),
grouped by the tracking id. (The `chemical_addition_log_id` FK on the tracking
row is provenance — not shown in this UI table.)

---

## 5. Conductivity  → view `vw_conductivity`

**UI tab:** "Conductivity". One row = one weekly conductivity round.

**Wide columns shown** (in this order): `Date`, `Name`,
`Cathodic Rinse 1 - pos.14 (µS/cm)`, `Cathodic Rinse 2 - pos.13 (µS/cm)`,
`Cathodic Rinse 3 - pos.12 (µS/cm)`, `Activation Rinse 1 - pos.19 (µS/cm)`,
`Activation Rinse 2 - pos.20 (µS/cm)`, `Plating Rinse 1 - pos.25 (µS/cm)`,
`Plating Rinse 2 - pos.24 (µS/cm)`, `Plating Rinse 3 - pos.23 (µS/cm)`,
`Plating Rinse 4 - pos.22 (µS/cm)`, `Plating Rinse 5 - pos.21 (µS/cm)`,
`Additional observations`.

**Source tables:** `conductivity_log` (round) → `conductivity_vat_log` (per
non-empty reading: `vat_id`, `rinse_number`, `conductivity`).

**Mapping:**

| Wide column | Source — `conductivity_vat_log.conductivity` where vat = … |
|---|---|
| `Date` | `conductivity_log.date` |
| `Name` | `conductivity_log.logged_by` |
| `Additional observations` | `conductivity_log.observation` |
| `Cathodic Rinse 1 - pos.14` | vat `'Vat. 14'` |
| `Cathodic Rinse 2 - pos.13` | vat `'Vat. 13'` |
| `Cathodic Rinse 3 - pos.12` | vat `'Vat. 12'` |
| `Activation Rinse 1 - pos.19` | vat `'Vat. 19'` |
| `Activation Rinse 2 - pos.20` | vat `'Vat. 20'` |
| `Plating Rinse 1 - pos.25` | vat `'Vat. 25'` |
| `Plating Rinse 2 - pos.24` | vat `'Vat. 24'` |
| `Plating Rinse 3 - pos.23` | vat `'Vat. 23'` |
| `Plating Rinse 4 - pos.22` | vat `'Vat. 22'` |
| `Plating Rinse 5 - pos.21` | vat `'Vat. 21'` |

Each UI column corresponds to **one specific rinse vat** (the position number in
the header *is* the vat). Pivot `conductivity_vat_log` on `vat.name`, grouped by
the log id. `rinse_number` is also stored (cascade order) but isn't needed for
the pivot — the vat identifies the column.

> **Units:** stored canonically in **µS/cm**. The UI has a µS/cm ↔ mS/cm display
> toggle (`mS/cm = µS/cm ÷ 1000`) — that's display-only; the view returns the
> stored µS/cm value.

---

## 6. Bath views — Cleaner / Activator / Strike / Plate

The four bath tabs share **one structure**: `<bath>_bath_log` (the session) →
`<bath>_bath_measurement` (one row per non-empty reading, discriminated by
`measurement_type` + `measurement_number ∈ {1,2}`).

**Common columns:** `Date` ← `…_log.date`, `Name` ← `…_log.measured_by`,
`Notes` ← `…_log.notes`. (`…_log.vat_id` identifies the bath.)

**Common pivot:** for each `(measurement_type, measurement_number)` pair, emit one
wide column:
```sql
MAX(CASE WHEN measurement_type = '<type>' AND measurement_number = <n>
         THEN measurement END) AS "<wide column>"
```
grouped by `…_log.id`. The exact pairs per bath are below (these are the
*entered* columns; the `[g/L]`, `Mean`, limits etc. are **derived app-side** —
see §1, not in the DB).

### 6a. Cleaner  → `vw_cleaner_bath` (single bath: `'Vat. 17'`)
| Wide column | `measurement_type` | `measurement_number` |
|---|---|---|
| `pH 1st` | `pH` | 1 |
| `pH 2nd` | `pH` | 2 |
| `Titration step 1 measurement 1` | `Titration step 1` | 1 |
| `Titration step 1 measurement 2` | `Titration step 1` | 2 |
| `Titration step 2 measurement 1` | `Titration step 2` | 1 |
| `Titration step 2 measurement 2` | `Titration step 2` | 2 |
| `Schloetter protocol 1` | `Schloetter protocol` | 1 |
| `Schloetter protocol 2` | `Schloetter protocol` | 2 |

### 6b. Activator  → `vw_activator_bath` (single bath: `'Vat. 18'`)
| Wide column | `measurement_type` | `measurement_number` |
|---|---|---|
| `pH 1st` / `pH 2nd` | `pH` | 1 / 2 |
| `Decasel5 Titration 1st (ml)` / `2nd (ml)` | `Decasel5 Titration_ml` | 1 / 2 |
| `Nickel Titration 1st (ml)` / `2nd (ml)` | `Nickel Titration_ml` | 1 / 2 |

### 6c. Strike  → `vw_strike_bath` (single bath: `'Vat. 31'`)
| Wide column | `measurement_type` | `measurement_number` |
|---|---|---|
| `pH 1st` / `pH 2nd` | `pH` | 1 / 2 |
| `Ni2+ Titration 1st (ml)` / `2nd (ml)` | `Ni2+ Titration_ml` | 1 / 2 |
| `Cl- Titration 1st (ml)` / `2nd (ml)` | `Cl- Titration_ml` | 1 / 2 |
| `HCl+ Titration 1st (ml)` / `2nd (ml)` | `HCl+ Titration_ml` | 1 / 2 |

### 6d. Plate  → `vw_plate_bath` (three baths: `'Vat. 28'`, `'Vat. 29'`, `'Vat. 30'`)
| Wide column | `measurement_type` | `measurement_number` |
|---|---|---|
| `pH 1st` / `pH 2nd` | `pH` | 1 / 2 |
| `Ni2+ Titration 1st (ml)` / `2nd (ml)` | `Ni2+ Titration_ml` | 1 / 2 |
| `Cl- Titration 1st (ml)` / `2nd (ml)` | `Cl- Titration_ml` | 1 / 2 |
| `ThioUrea Titration 1st (ml)` / `2nd (ml)` | `ThioUrea Titration_ml` | 1 / 2 |
| `Boric Acid Titration 1st (ml)` / `2nd (ml)` | `Boric Acid Titration_ml` | 1 / 2 |

> **Plate is three baths in one pair of tables**, distinguished by `vat_id`. The
> app shows a separate tab per plate (28/29/30). So either (a) add `vat_id` /
> `vat.name` as a column and `GROUP BY` it too (one view, a bath-identifying
> column), or (b) make three views each filtering `WHERE v.name = 'Vat. 28'`
> etc. The single-bath baths (cleaner/activator/strike) always resolve to their
> one vat.

**Worked example (Cleaner — the template for all four):**

```sql
CREATE VIEW vw_cleaner_bath AS
SELECT
    l.id                                                                 AS cleaner_bath_log_id,
    l.date                                                               AS [Date],
    l.measured_by                                                        AS [Name],
    MAX(CASE WHEN m.measurement_type='pH'                AND m.measurement_number=1 THEN m.measurement END) AS [pH 1st],
    MAX(CASE WHEN m.measurement_type='pH'                AND m.measurement_number=2 THEN m.measurement END) AS [pH 2nd],
    MAX(CASE WHEN m.measurement_type='Titration step 1'  AND m.measurement_number=1 THEN m.measurement END) AS [Titration step 1 measurement 1],
    MAX(CASE WHEN m.measurement_type='Titration step 1'  AND m.measurement_number=2 THEN m.measurement END) AS [Titration step 1 measurement 2],
    MAX(CASE WHEN m.measurement_type='Titration step 2'  AND m.measurement_number=1 THEN m.measurement END) AS [Titration step 2 measurement 1],
    MAX(CASE WHEN m.measurement_type='Titration step 2'  AND m.measurement_number=2 THEN m.measurement END) AS [Titration step 2 measurement 2],
    MAX(CASE WHEN m.measurement_type='Schloetter protocol' AND m.measurement_number=1 THEN m.measurement END) AS [Schloetter protocol 1],
    MAX(CASE WHEN m.measurement_type='Schloetter protocol' AND m.measurement_number=2 THEN m.measurement END) AS [Schloetter protocol 2],
    l.notes                                                              AS [Notes]
FROM cleaner_bath_log l
LEFT JOIN cleaner_bath_measurement m ON m.cleaner_bath_log_id = l.id
GROUP BY l.id, l.date, l.measured_by, l.notes;
```

Activator / Strike / Plate are the same shape with their measurement-type rows
swapped in from the tables above (and Plate adding the `vat.name` split).

---

## 7. Quick reference — view ↔ tables

| View | Parent (log) | Child grain(s) | Pivot discriminator |
|---|---|---|---|
| `vw_ph_control` | `ph_log` | `ph_log_vat`, `ph_measurement` | `vat.name` × `measurement_number` (readings); `vat.name` (additions) |
| `vw_adding_chemicals` | `chemical_addition_log` | `chemical_addition_log_vat`, `chemical_addition` | `vat.name` (string-agg chemicals; water level) |
| `vw_production_tracking` | `electrode_production_tracking` | `electrode_production_vat` | `vat.name` (sum + shift counters) |
| `vw_conductivity` | `conductivity_log` | `conductivity_vat_log` | `vat.name` |
| `vw_cleaner_bath` | `cleaner_bath_log` | `cleaner_bath_measurement` | `measurement_type` × `measurement_number` |
| `vw_activator_bath` | `activator_bath_log` | `activator_bath_measurement` | `measurement_type` × `measurement_number` |
| `vw_strike_bath` | `strike_bath_log` | `strike_bath_measurement` | `measurement_type` × `measurement_number` |
| `vw_plate_bath` | `plate_bath_log` | `plate_bath_measurement` | `vat.name` + `measurement_type` × `measurement_number` |

**General reminders for whoever writes the views:**
- Pivot on `vat.name`, group by the parent log id, and use `LEFT JOIN` so a
  session with a missing reading still produces a row (empty cell = `NULL`).
- Quote the wide column aliases with `[...]` — they contain spaces, dots,
  parentheses and symbols (`µ`, `+`, `-`).
- Reconstruct **persisted columns only**; means / `[g/L]` / `[H+]` / limits are
  computed in the app from `config.json` and are not in the database.
- Where one event has two child grains (pH additions+readings; chemicals
  water-level+chemicals), fold each grain to one row per (log, vat) **before**
  combining, so you don't fan-out-multiply values.
