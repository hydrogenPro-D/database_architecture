#!/usr/bin/env python3
"""
sync_plate_test_from_prod.py  --  replace dataloggingTest's plate bath data
(Vat 28/29/30) with the export produced by export_plate_from_prod.py.

PHASE 2 of the plate backfill plan:
    1. export_plate_from_prod.py   -- READ-ONLY pull from production
    2. (this script)               -- wipe + reload TEST from that export
    3. integrate the cobalt CSVs   -- absorbance + Co split

DESTRUCTIVE -- AND ONLY EVER ON TEST
------------------------------------
This DELETES every plate_bath_measurement / plate_bath_log row for Vat 28/29/30
in the target database, then reloads them from ./export/. It therefore HARD
REFUSES to run against any database in db_common.PROD_DATABASES -- there is no
override prompt, because "wipe the plate tables" is never a thing to do on
production. You also have to type the row count to confirm.

IDS ARE REMAPPED, NOT COPIED
----------------------------
The export's `src_log_id` is production's identity value. Log rows are inserted
here WITHOUT it, letting TEST assign fresh ids, and each measurement is re-pointed
through an in-memory {src_log_id -> new test id} map. Copying prod ids would
collide with (or mis-attach to) rows test assigns itself.

WHAT IS PRESERVED
-----------------
  - vat is matched BY NAME, so the two databases need not share vat ids.
  - created_at is carried over verbatim, NULLs included (only ~36 of 270 rows
    have one). This keeps the app's "Row added" / edit-window behaviour identical
    to production instead of stamping everything as created today.
  - row_version is NOT copied (ROWVERSION is auto-generated); the change
    watermark will simply bump once, and the app reloads the tab.

PRECISION CAVEAT
----------------
Production is still on DECIMAL(8,2), so the exported values are already rounded
(Cl- 1.44661 -> 1.45). This restores missing ROWS, not lost precision -- that
needs a re-import from the weekly result scheme workbook.

AFTER THE RELOAD
----------------
Prod rows all still carry the pre-cobalt label 'Ni2+ Titration_ml', so step 3
re-applies migration 025's re-type (same idempotent UPDATE). Expected: 74 rows.

Requires:  pip install pyodbc  +  the "ODBC Driver 18 for SQL Server".
"""

import csv
import os
import sys

import db_common as db

SCHEMA = "qc"
EXPORT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "export")
LOG_CSV = os.path.join(EXPORT_DIR, "plate_bath_log_export.csv")
MEAS_CSV = os.path.join(EXPORT_DIR, "plate_bath_measurement_export.csv")

VATS = ("Vat. 28", "Vat. 29", "Vat. 30")

# Per-vat cobalt cutover (PLATE_COBALT_DB_SPEC.md). Same boundaries migration 025
# uses; re-applied here because the reloaded prod rows carry the old label.
CUTOVER = {"Vat. 28": "2026-07-15", "Vat. 29": "2026-08-14", "Vat. 30": "2026-08-18"}


def read_export():
    for p in (LOG_CSV, MEAS_CSV):
        if not os.path.exists(p):
            sys.exit(f"Missing {p}\n  Run export_plate_from_prod.py first.")
    with open(LOG_CSV, encoding="utf-8-sig", newline="") as fh:
        logs = list(csv.DictReader(fh))
    with open(MEAS_CSV, encoding="utf-8-sig", newline="") as fh:
        meas = list(csv.DictReader(fh))
    if not logs:
        sys.exit("Export contains no log rows -- nothing to load.")
    bad = sorted({r["vat"] for r in logs} - set(VATS))
    if bad:
        sys.exit(f"Export contains unexpected vats: {bad}")
    known = {r["src_log_id"] for r in logs}
    orphan = [m for m in meas if m["src_log_id"] not in known]
    if orphan:
        sys.exit(f"{len(orphan)} measurement rows reference an unknown src_log_id.")
    return logs, meas


def n(v):
    """Empty CSV field -> NULL (repo-wide convention)."""
    return None if v is None or v.strip() == "" else v


def vat_ids(cur):
    cur.execute(f"SELECT [name], [id] FROM [{SCHEMA}].[vat] WHERE [name] IN (?, ?, ?);", *VATS)
    m = {r[0]: r[1] for r in cur.fetchall()}
    missing = [v for v in VATS if v not in m]
    if missing:
        sys.exit(f"Target database has no vat row for: {missing}")
    return m


def current_counts(cur):
    cur.execute(
        f"SELECT v.[name], COUNT(*) FROM [{SCHEMA}].[plate_bath_log] l "
        f"JOIN [{SCHEMA}].[vat] v ON v.[id] = l.[vat_id] "
        f"WHERE v.[name] IN (?, ?, ?) GROUP BY v.[name] ORDER BY v.[name];", *VATS)
    return cur.fetchall()


def main():
    logs, meas = read_export()

    env, database = db.choose_environment("WIPE AND RELOAD plate data in")
    if database in db.PROD_DATABASES:
        sys.exit(f"Refusing to run: {database} is PRODUCTION. This script deletes "
                 f"plate rows and is only ever for a test database.")

    server, user, pwd = db.prompt_connection()
    conn = db.connect(database, server, user, pwd)
    cur = conn.cursor()
    db.verify_database(cur, database)

    before = current_counts(cur)
    total_before = sum(r[1] for r in before)
    print(f"\nTarget: {database}")
    print("  current plate log rows:", ", ".join(f"{r[0]}={r[1]}" for r in before) or "(none)")
    print(f"  about to DELETE {total_before} log rows (and all their measurements),")
    print(f"  then INSERT {len(logs)} log rows + {len(meas)} measurements from ./export/.")

    typed = input(f"\nType the number {total_before} to confirm the wipe: ").strip()
    if typed != str(total_before):
        sys.exit("Did not match. Aborting -- nothing was changed.")

    vmap = vat_ids(cur)
    try:
        # ---- 1. wipe (children first: FK) --------------------------------
        cur.execute(
            f"DELETE m FROM [{SCHEMA}].[plate_bath_measurement] m "
            f"JOIN [{SCHEMA}].[plate_bath_log] l ON l.[id] = m.[plate_bath_log_id] "
            f"JOIN [{SCHEMA}].[vat] v ON v.[id] = l.[vat_id] "
            f"WHERE v.[name] IN (?, ?, ?);", *VATS)
        del_m = cur.rowcount
        cur.execute(
            f"DELETE l FROM [{SCHEMA}].[plate_bath_log] l "
            f"JOIN [{SCHEMA}].[vat] v ON v.[id] = l.[vat_id] "
            f"WHERE v.[name] IN (?, ?, ?);", *VATS)
        del_l = cur.rowcount
        print(f"\n  deleted {del_l} log rows, {del_m} measurements")

        # ---- 2. reload, remapping ids ------------------------------------
        # created_at is written explicitly (NULL included) so the column DEFAULT
        # does NOT stamp these historical rows as created today.
        ins_log = (f"INSERT INTO [{SCHEMA}].[plate_bath_log] "
                   f"([date], [vat_id], [measured_by], [notes], [created_at]) "
                   f"OUTPUT INSERTED.[id] VALUES (?, ?, ?, ?, ?);")
        idmap = {}
        for r in logs:
            cur.execute(ins_log, n(r["date"]), vmap[r["vat"]],
                        n(r["measured_by"]), n(r["notes"]), n(r["created_at"]))
            idmap[r["src_log_id"]] = cur.fetchone()[0]
        print(f"  inserted {len(idmap)} log rows")

        ins_m = (f"INSERT INTO [{SCHEMA}].[plate_bath_measurement] "
                 f"([plate_bath_log_id], [measurement_number], [measurement], [measurement_type]) "
                 f"VALUES (?, ?, ?, ?);")
        cur.fast_executemany = True
        cur.executemany(ins_m, [(idmap[m["src_log_id"]], n(m["measurement_number"]),
                                 n(m["measurement"]), n(m["measurement_type"])) for m in meas])
        print(f"  inserted {len(meas)} measurements")

        # ---- 3. re-apply the cobalt re-type (migration 025 step 2) --------
        cur.execute(
            f"UPDATE m SET m.[measurement_type] = N'Ni2+ + Co2+ Titration_ml' "
            f"FROM [{SCHEMA}].[plate_bath_measurement] m "
            f"JOIN [{SCHEMA}].[plate_bath_log] l ON l.[id] = m.[plate_bath_log_id] "
            f"JOIN [{SCHEMA}].[vat] v ON v.[id] = l.[vat_id] "
            f"WHERE m.[measurement_type] = N'Ni2+ Titration_ml' "
            f"  AND ((v.[name] = ? AND l.[date] >= ?) "
            f"    OR (v.[name] = ? AND l.[date] >= ?) "
            f"    OR (v.[name] = ? AND l.[date] >= ?));",
            "Vat. 28", CUTOVER["Vat. 28"], "Vat. 29", CUTOVER["Vat. 29"],
            "Vat. 30", CUTOVER["Vat. 30"])
        print(f"  re-typed {cur.rowcount} rows to 'Ni2+ + Co2+ Titration_ml' (expected 74)")

        conn.commit()
    except Exception as exc:
        conn.rollback()
        sys.exit(f"\nFAILED: {exc}\n  Rolled back -- the database is unchanged.")
    finally:
        conn.close()

    print(f"\nDone. {database} now mirrors the production plate data.")
    print("Next: supply the weekly result scheme plate CSV to fill the 10 sessions "
          "production is missing, then attach the cobalt absorbance readings.")


if __name__ == "__main__":
    main()
