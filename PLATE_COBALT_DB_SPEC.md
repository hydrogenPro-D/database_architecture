# Plate baths: cobalt split and Spectroquant nickel test

Database work needed for three new tables added to the Plate28, Plate29 and
Plate30 sheets of "Weekly Result Scheme Plating Line 1.xlsx".

For whoever writes the migration SQL. The application side (extraction, config,
GUI) is handled separately, and the input CSVs already exist. Everything below
was verified against the workbook and against `dataloggingTest` on 2026-09-15.

## What changed in the process

Cobalt was introduced into each plating bath on a different date:

| Vat | Cobalt from |
|---|---|
| 28 | 15.07.2026 |
| 29 | 14.08.2026 |
| 30 | 18.08.2026 |

The existing Ni²⁺ titration uses EDTA, which complexes both metals. So:

* **Before that vat's date**, the titration is nickel. Unchanged, already correct
  in the database.
* **From that date onward**, the identical measurement is really nickel + cobalt.
  The millilitres did not change, only what they mean.
* A **new Spectroquant 1.14785 photometric test** measures nickel alone, as three
  absorbance readings at 445 nm. This is the only new raw input.
* **Cobalt is the difference** between the two, never measured directly.

Confirmed numerically: the existing conversion factor 2.935 is exactly
`0.05 × 58.693`, and on Plate28 the new Ni+Co table reproduces the existing Ni²⁺
Mean column to six decimal places. Same number, two routes.

## Input: four CSVs in `migration_data/plate_cobalt/`

Produced by `src/data_access/scripts/04_export_plate_cobalt_tables.py`, which
derives them from the plate CSVs written by `03_export_weekly_result_scheme_to_csv.py`.
Regenerate with those two scripts, do not hand edit.

| File | Rows | Contents |
|---|---|---|
| `plate_old_nickel.csv` | 191 | Ni²⁺ titration ml **before** the cutover. Real nickel. |
| `plate_nickel_cobalt.csv` | 43 | The same titration ml **from** the cutover. Really Ni+Co. |
| `plate_new_nickel.csv` | 42 | Spectroquant absorbance, three readings. New raw input. |
| `plate_cobalt.csv` | 42 | Derived `Co2+ [mol/L]` and `Co2+ [g/L]`. **Reference only, do not store.** |

Per vat: old nickel 55/69/67, the other three 28/6/9 and 27/6/9.

### The join key

Every file starts with `Vat` and `Seq`. **`Seq` is a 1-based position within that
vat**, matching the order of rows in the sheet.

**Use `(Vat, Seq)`, not `(Vat, Date)`.** A bath can be sampled several times in
one day: vat 28 has four rows on 13.08.2026, two of them deliberately spiked
calibration samples, plus pairs on 14.08 and 25.08. `(Vat, Date)` and even
`(Vat, Date, Name)` are both non-unique. Verified: `(Vat, Seq)` is unique in all
four files, `old_nickel` and `nickel_cobalt` never share a key, and the
`new_nickel` keys are a strict subset of `nickel_cobalt`.

`plate_old_nickel.csv` alone has no duplicate dates, so the duplication only
begins in the cobalt era.

### What is derived and must not be stored

`plate_cobalt.csv` exists so a migration can be checked, not loaded. The
application computes all of it from the stored raw values:

```
mg/L Ni     = (absorbance - 0.003) / 0.216466
mol/L       = mg/L / (58.693 * 1000)
Ni mean     = average of the three mol/L values
Ni g/L      = Ni mean * 58.693 * 10000       (10000 = fixed dilution factor)
Ni+Co mol/L = 0.05 * titration_ml            (per titration, then averaged)
Co mol/L    = Ni+Co mean - (Ni mean * 10000)
Co g/L      = Co mol/L * 58.93
```

Reaction and tolerance limits are likewise application config, not database rows.
Noted here only so they are not mistaken for data: the cobalt limits differ per
vat, with vat 28 on nominal 4 at ±15% and ±20%, and vats 29 and 30 still on a
fixed 5/3 and 5.5/2.5.

## Change 1: measurement precision. Do this first

`qc.plate_bath_measurement.measurement` is **`decimal(8,2)`**, which cannot hold
this data, and is **already silently rounding existing values**.

Measured across all plate data:

| Column | Decimals needed | Example |
|---|---|---|
| Cl⁻ Titration 2nd | **5** | 1.44661 |
| Cl⁻ Titration 1st | 4 | 1.5652 |
| Boric Acid Titration | 4 | 11.2786 |
| Ni Absorbance | 3 | 0.677 |
| pH, Ni²⁺ and ThioUrea titrations | 2 | 10.14 |

Largest value in any measurement column is 27.17, so only the scale is a problem,
not the range. **Recommended `decimal(10,5)`.** Please check whether
`strike_bath_measurement`, `cleaner_bath_measurement` and
`activator_bath_measurement` share the type and need the same change.

This cannot recover precision already lost in rows stored under `decimal(8,2)`.
Re-importing those rows is a separate decision, listed at the end.

## Change 2: measurement types

`qc.plate_bath_measurement` is already an EAV table (`measurement_type`,
`measurement_number`, `measurement`), so **no new table and no new column**.
Existing types:

```
pH | Ni2+ Titration_ml | Cl- Titration_ml | ThioUrea Titration_ml | Boric Acid Titration_ml
```

Two changes:

**Add** `Ni Absorbance_445nm`, with `measurement_number` 1, 2 **and 3**. This is
the first type with three measurements per log row rather than two, so please
check nothing assumes a pair, in particular any pivot inside the views and any
constraint on `measurement_number`.

**Re-type** the existing `Ni2+ Titration_ml` rows that fall on or after their
vat's cutover to `Ni2+ + Co2+ Titration_ml`. The 43 rows in
`plate_nickel_cobalt.csv` identify exactly which. The values do not change, only
the label. Rows in `plate_old_nickel.csv` stay as they are.

Do not add a type for cobalt or for any g/L value.

## Change 3: the views

`qc.vw_plate_bath_28`, `_29` and `_30` each need three more columns, named
exactly as the application expects:

```
[Ni Absorbance 445nm 1st], [Ni Absorbance 445nm 2nd], [Ni Absorbance 445nm 3rd]
```

Place them after `[Boric Acid Titration 2nd (ml)]` and before `[Notes]`, nullable,
since most historical rows have none.

If the views select the Ni²⁺ titration by a literal `measurement_type`, they must
now accept both labels so pre-cutover and post-cutover rows still land in the
same column.

Do not change the existing `ORDER BY`, or the `plate_bath_log_id` and `Row added`
columns. The application maps table rows back to ids by position, so a change in
ordering makes edits hit the wrong row.

## Change 4: the procedures

`qc.usp_plate_bath_insert` takes `@date`, `@vat`, `@measured_by`, `@notes` and a
single `@measurements nvarchar` payload, so **the signature probably needs no
change**. The application drives it from a declarative list of
`(column, measurement_type, measurement_number)` triples and simply gains three
more entries.

Please confirm the payload parser accepts an unknown `measurement_type` and a
`measurement_number` of 3. I could not check this: the login I have lacks
`VIEW DEFINITION`, so `OBJECT_DEFINITION` returns `NULL`.

Same for `usp_plate_bath_update`, which must delete and reinsert absorbance rows
like any other type, and must not drop them when a row is edited without them.

## Change 5: backfill

In `dataloggingTest` the latest plate rows are 22.07.2026 for vat 28 and
15.07.2026 for vats 29 and 30, while the sheet runs to 10.09.2026. Most of the 42
absorbance rows therefore have **no log row to attach to** in that database.
Production may be further ahead; I have no access and cannot check.

So per vat the order is:

1. Insert missing plate log rows and their existing measurements from
   `data/weekly_result_scheme_plate*.csv`.
2. Re-type the 43 rows listed in `plate_nickel_cobalt.csv`.
3. Insert the absorbance measurements for the 42 rows in `plate_new_nickel.csv`.

Because dates repeat, resolve `Seq` to a log id by ordering that vat's rows by
date and then by insertion order, and confirm the resulting count per vat matches
the table above before committing.

## Verification

```sql
-- 42 rows, 126 values: 27/6/9 for vats 28/29/30
SELECT v.name, COUNT(DISTINCT m.plate_bath_log_id) AS rows_with_absorbance, COUNT(*) AS values
FROM qc.plate_bath_measurement m
JOIN qc.plate_bath_log l ON l.id = m.plate_bath_log_id
JOIN qc.vat v ON v.id = l.vat_id
WHERE m.measurement_type = 'Ni Absorbance_445nm'
GROUP BY v.name ORDER BY 1;

-- every absorbance row must carry all three readings
SELECT plate_bath_log_id, COUNT(*) FROM qc.plate_bath_measurement
WHERE measurement_type = 'Ni Absorbance_445nm'
GROUP BY plate_bath_log_id HAVING COUNT(*) <> 3;          -- expect zero rows

-- no absorbance without a Ni+Co titration on the same log row
SELECT m.plate_bath_log_id FROM qc.plate_bath_measurement m
WHERE m.measurement_type = 'Ni Absorbance_445nm'
  AND NOT EXISTS (SELECT 1 FROM qc.plate_bath_measurement t
                  WHERE t.plate_bath_log_id = m.plate_bath_log_id
                    AND t.measurement_type = 'Ni2+ + Co2+ Titration_ml');   -- expect zero rows

-- no log row may carry both labels
SELECT plate_bath_log_id FROM qc.plate_bath_measurement
WHERE measurement_type IN ('Ni2+ Titration_ml', 'Ni2+ + Co2+ Titration_ml')
GROUP BY plate_bath_log_id HAVING COUNT(DISTINCT measurement_type) > 1;     -- expect zero rows

-- precision survived
SELECT TOP 5 measurement FROM qc.plate_bath_measurement
WHERE measurement_type = 'Ni Absorbance_445nm';           -- expect values like 0.67700
```

Spot checks against the sheet, the first absorbance row of each vat:

| Vat | Date | Absorbance |
|---|---|---|
| 28 | 15.07.2026 | 0.677, 0.689, 0.687 |
| 29 | 14.08.2026 | 0.677, 0.673, 0.674 |
| 30 | 18.08.2026 | 0.690, 0.692, 0.689 |

`plate_cobalt.csv` gives the expected derived result for every one of those rows,
so the application output can be checked against it after the migration.

## Decisions still open

1. Re-import existing rows to recover precision lost under `decimal(8,2)`, or
   accept the history as it stands?
2. Does production already hold the rows missing from test, so only the
   absorbance and the re-typing are needed there?
3. Vat 28 has two spiked calibration samples on 13.08.2026, marked
   "Julia (spiked)" and "Tamas (spiked)" in the Name column. They are test
   samples, not bath measurements. Should they be imported at all, and if so
   should they be flagged so plots and averages can exclude them?
