#!/usr/bin/env python3
"""
load_plate_cobalt_data.py  --  finish the plate cobalt migration (PLATE_COBALT_DB_SPEC.md
change 5) straight from the weekly result scheme workbook.

PHASE 3 of the plate backfill plan:
    1. export_plate_from_prod.py      -- READ-ONLY pull from production
    2. sync_plate_test_from_prod.py   -- wipe + reload TEST from that export
    3. (this script)                  -- insert the rows only the workbook has,
                                         then attach the Ni absorbance readings

WHAT IT DOES
------------
  A. Reads Plate28/29/30 from the workbook (raw columns only; every "Calculation"
     / "Limits" column is derived and deliberately NOT stored).
  B. Matches each workbook row against the LIVE database and inserts the ones that
     are missing, with all their measurements.
  C. Inserts the three Ni Absorbance_445nm readings (measurement_number 1, 2, 3)
     for every workbook row that has them and does not have them in the DB yet.

Both B and C are RE-RUNNABLE: matching is redone against the live database each
time, and absorbance is only inserted where it is absent. Running twice inserts
nothing the second time.

MATCHING (learned the hard way -- see the analysis in the migration notes)
-------------------------------------------------------------------------
Rows are matched to the DB in three passes, strongest key first:
    1. the Ni titration pair (1st, 2nd)   -- verified unique, zero ambiguity
    2. date + name
    3. date alone, and ONLY for workbook rows that carry no Ni values
Neither `Seq` (ordinal position) nor date alone is safe on its own: the workbook
and the database disagree on some dates, and several bath samples share a date.
The Ni pair is compared ROUNDED TO 2 dp because rows loaded before migration 025
were stored as DECIMAL(8,2).

SPIKED CALIBRATION SAMPLES
--------------------------
Vat 28 / 2026-08-13 has two deliberately spiked calibration samples
("Julia (spiked)", "Tamas (spiked)"). They are test samples, not bath
measurements, and there is no column to flag them with, so they would silently
distort plots and averages. INCLUDE_SPIKED is therefore False by default -- flip
it to True to load them anyway.

created_at is written as NULL: these are historical rows, so they stay locked and
show a blank "Row added", exactly like the rest of the back-loaded history.

Run migration 025 FIRST -- it widens measurement to DECIMAL(10,5). Without it the
full-precision values (1.0525, 0.8736, 5.1748 ...) are silently rounded to 2 dp.

Requires:  pip install pyodbc openpyxl  +  the "ODBC Driver 18 for SQL Server".
"""

import os
import sys
from decimal import Decimal, ROUND_HALF_UP

import db_common as db

try:
    import openpyxl
except ImportError:
    sys.exit("openpyxl is not installed.  Run:  pip install openpyxl")

SCHEMA = "qc"
WORKBOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "export", "Weekly Result Scheme Plating Line 1.xlsx")

# Sheet -> vat name. All three sheets share one layout.
SHEETS = [("Plate28", "Vat. 28"), ("Plate29", "Vat. 29"), ("Plate30", "Vat. 30")]
FIRST_DATA_ROW = 8

# 1-based column indexes of the RAW (stored) values. Everything else on the sheet
# is a calculation or a limit and must not be stored.
C_DATE, C_NAME = 2, 3
RAW = [                       # (col_1st, col_2nd, measurement_type)
    (5, 6, "pH"),
    (14, 15, "Ni2+ Titration_ml"),        # re-labelled per cutover, see ni_type()
    (25, 26, "Cl- Titration_ml"),
    (36, 37, "ThioUrea Titration_ml"),
    (47, 48, "Boric Acid Titration_ml"),
]
ABS_COLS = (64, 65, 66)                   # BL/BM/BN -- absorbance 1st/2nd/3rd
ABS_TYPE = "Ni Absorbance_445nm"
NI_OLD, NI_NEW = "Ni2+ Titration_ml", "Ni2+ + Co2+ Titration_ml"

# Per-vat cobalt cutover: from this date the same EDTA titration means Ni+Co.
CUTOVER = {"Vat. 28": "2026-07-15", "Vat. 29": "2026-08-14", "Vat. 30": "2026-08-18"}

# The two spiked calibration samples -- see the docstring.
INCLUDE_SPIKED = False
SPIKED_MARKER = "(spiked)"


def q(v, places):
    if v is None:
        return None
    return Decimal(str(v)).quantize(Decimal("1." + "0" * places), rounding=ROUND_HALF_UP)


def ni_type(vat, date):
    """Same rule migration 025 applies: on/after the vat's cutover the titration
    is nickel + cobalt, and only the LABEL differs."""
    return NI_NEW if date >= CUTOVER[vat] else NI_OLD


def read_workbook():
    """-> [{vat, row, date, name, values:[(type, number, value)], absorbance:[v1,v2,v3]}]"""
    if not os.path.exists(WORKBOOK):
        sys.exit(f"Workbook not found:\n  {WORKBOOK}")
    wb = openpyxl.load_workbook(WORKBOOK, data_only=True, read_only=True)
    out = []
    for sheet, vat in SHEETS:
        if sheet not in wb.sheetnames:
            sys.exit(f"Workbook has no sheet named {sheet!r}.")
        ws = wb[sheet]
        for i, r in enumerate(ws.iter_rows(min_row=FIRST_DATA_ROW, max_col=max(ABS_COLS),
                                           values_only=True), start=FIRST_DATA_ROW):
            date = _date(r[C_DATE - 1])
            if not date:
                continue
            name = r[C_NAME - 1]
            name = str(name).strip() if name is not None else None

            values = []
            for c1, c2, mtype in RAW:
                t = ni_type(vat, date) if mtype == NI_OLD else mtype
                for num, col in ((1, c1), (2, c2)):
                    v = _num(r[col - 1])
                    if v is not None:
                        values.append((t, num, q(v, 5)))
            absorb = [_num(r[c - 1]) for c in ABS_COLS]
            out.append({"vat": vat, "row": i, "date": date, "name": name,
                        "values": values,
                        "absorbance": [q(a, 5) for a in absorb] if absorb[0] is not None else None})
    return out


def _num(v):
    return float(v) if isinstance(v, (int, float)) else None


def _date(v):
    import datetime
    if isinstance(v, (datetime.datetime, datetime.date)):
        return v.strftime("%Y-%m-%d")
    if isinstance(v, str):
        for f in ("%d.%m.%Y", "%Y-%m-%d"):
            try:
                return datetime.datetime.strptime(v.strip(), f).strftime("%Y-%m-%d")
            except ValueError:
                pass
    return None


def load_db_rows(cur):
    """Live DB state: one entry per plate log row, with its Ni pair (either label,
    since 025 re-types post-cutover rows) and whether absorbance already exists."""
    cur.execute(
        f"SELECT l.[id], v.[name], CONVERT(char(10), l.[date], 23), l.[measured_by] "
        f"FROM [{SCHEMA}].[plate_bath_log] l JOIN [{SCHEMA}].[vat] v ON v.[id] = l.[vat_id] "
        f"WHERE v.[name] IN ('Vat. 28','Vat. 29','Vat. 30');")
    rows = {r[0]: {"id": r[0], "vat": r[1], "date": r[2],
                   "name": (r[3] or "").strip(), "ni": {}, "has_abs": False} for r in cur.fetchall()}
    cur.execute(
        f"SELECT m.[plate_bath_log_id], m.[measurement_type], m.[measurement_number], m.[measurement] "
        f"FROM [{SCHEMA}].[plate_bath_measurement] m "
        f"WHERE m.[measurement_type] IN (?, ?, ?);", NI_OLD, NI_NEW, ABS_TYPE)
    for log_id, mtype, num, val in cur.fetchall():
        if log_id not in rows:
            continue
        if mtype == ABS_TYPE:
            rows[log_id]["has_abs"] = True
        else:
            rows[log_id]["ni"][num] = q(val, 2)
    return list(rows.values())


def match(wb_rows, db_rows):
    """Three passes, strongest key first. -> (pairs {wb row -> db row}, missing[])"""
    pairs, missing = {}, []
    for _, vat in SHEETS:
        pool = [d for d in db_rows if d["vat"] == vat]
        todo = [w for w in wb_rows if w["vat"] == vat]

        def ni_of(w):
            d = {n: v for t, n, v in w["values"] if t in (NI_OLD, NI_NEW)}
            return (q(d.get(1), 2), q(d.get(2), 2))

        for w in list(todo):                                   # 1. Ni pair
            key = ni_of(w)
            if key == (None, None):
                continue
            hit = next((p for p in pool if (p["ni"].get(1), p["ni"].get(2)) == key), None)
            if hit:
                pairs[id(w)] = hit; pool.remove(hit); todo.remove(w)
        for w in list(todo):                                   # 2. date + name
            hit = next((p for p in pool if p["date"] == w["date"]
                        and p["name"] == (w["name"] or "")), None)
            if hit:
                pairs[id(w)] = hit; pool.remove(hit); todo.remove(w)
        for w in list(todo):                                   # 3. date, only if no Ni
            if ni_of(w) != (None, None):
                continue
            hit = next((p for p in pool if p["date"] == w["date"]), None)
            if hit:
                pairs[id(w)] = hit; pool.remove(hit); todo.remove(w)
        missing.extend(todo)
    return pairs, missing


def main():
    wb_rows = read_workbook()
    print(f"Workbook: {len(wb_rows)} data rows across Plate28/29/30")

    skipped = []
    if not INCLUDE_SPIKED:
        keep = []
        for w in wb_rows:
            (skipped if SPIKED_MARKER in (w["name"] or "").lower() else keep).append(w)
        wb_rows = keep
        for w in skipped:
            print(f"  skipping spiked calibration sample: {w['vat']} row {w['row']} "
                  f"{w['date']} {w['name']}")

    env, database = db.choose_environment("Load plate cobalt data into")
    if database in db.PROD_DATABASES:
        db.confirm_production(database)
    server, user, pwd = db.prompt_connection()
    conn = db.connect(database, server, user, pwd)
    cur = conn.cursor()
    db.verify_database(cur, database)

    cur.execute(f"SELECT [precision], [scale] FROM sys.columns "
                f"WHERE object_id = OBJECT_ID(N'[{SCHEMA}].[plate_bath_measurement]') "
                f"AND name = N'measurement';")
    prec = cur.fetchone()
    if prec and (prec[0], prec[1]) != (10, 5):
        sys.exit(f"plate_bath_measurement.measurement is DECIMAL{tuple(prec)}, expected (10,5).\n"
                 f"  Run migration 025 first or the values will be silently rounded.")

    cur.execute(f"SELECT [name], [id] FROM [{SCHEMA}].[vat] WHERE [name] IN ('Vat. 28','Vat. 29','Vat. 30');")
    vmap = {r[0]: r[1] for r in cur.fetchall()}

    db_rows = load_db_rows(cur)
    pairs, missing = match(wb_rows, db_rows)
    print(f"\nLive DB has {len(db_rows)} plate log rows; "
          f"{len(pairs)} workbook rows matched, {len(missing)} missing.")
    for w in missing:
        print(f"  MISSING -> {w['vat']} xlsx row {w['row']} {w['date']} {w['name']} "
              f"({len(w['values'])} readings)")

    need_abs = [w for w in wb_rows if w["absorbance"]
                and (w in missing or not pairs[id(w)]["has_abs"])]
    print(f"\nAbsorbance to insert: {len(need_abs)} rows x 3 readings")
    if not missing and not need_abs:
        conn.close()
        sys.exit("Nothing to do -- database already up to date.")

    if input("\nProceed? (type 'yes'): ").strip().lower() != "yes":
        conn.close()
        sys.exit("Not confirmed. Aborting.")

    ins_log = (f"INSERT INTO [{SCHEMA}].[plate_bath_log] "
               f"([date], [vat_id], [measured_by], [notes], [created_at]) "
               f"OUTPUT INSERTED.[id] VALUES (?, ?, ?, NULL, NULL);")
    ins_m = (f"INSERT INTO [{SCHEMA}].[plate_bath_measurement] "
             f"([plate_bath_log_id], [measurement_number], [measurement], [measurement_type]) "
             f"VALUES (?, ?, ?, ?);")
    n_log = n_val = n_abs = 0
    try:
        for w in missing:                       # A. the rows only the workbook has
            cur.execute(ins_log, w["date"], vmap[w["vat"]], w["name"])
            new_id = cur.fetchone()[0]
            n_log += 1
            for mtype, num, val in w["values"]:
                cur.execute(ins_m, new_id, num, val, mtype)
                n_val += 1
            w["_new_id"] = new_id

        for w in need_abs:                      # B. the absorbance readings
            log_id = w.get("_new_id") or pairs[id(w)]["id"]
            for num, val in enumerate(w["absorbance"], start=1):
                if val is None:
                    continue
                cur.execute(ins_m, log_id, num, val, ABS_TYPE)
                n_abs += 1
        conn.commit()
    except Exception as exc:
        conn.rollback()
        sys.exit(f"\nFAILED: {exc}\n  Rolled back -- nothing was written.")
    finally:
        conn.close()

    print(f"\nDone. Inserted {n_log} log rows, {n_val} measurements, "
          f"{n_abs} absorbance readings into {database}.")
    if skipped:
        print(f"Skipped {len(skipped)} spiked calibration sample(s) "
              f"(set INCLUDE_SPIKED = True to load them).")


if __name__ == "__main__":
    main()
