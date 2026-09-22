#!/usr/bin/env python3
"""
export_plate_from_prod.py  --  READ-ONLY export of the plate bath data (Vat 28/29/30)
from a datalogging database, for re-loading into another environment.

PHASE 1 of the plate backfill plan:
    1. (this script) export plate_bath_log + plate_bath_measurement from PRODUCTION
    2. load the missing rows into dataloggingTest (separate script)
    3. integrate the cobalt CSVs (absorbance + re-typing)

It is also the DIAGNOSTIC that answers the open question in PLATE_COBALT_DB_SPEC.md
("Production may be further ahead; I have no access and cannot check"): the summary
it prints compares each vat's row count and date range, so you can see at a glance
whether prod actually holds the ~44 log rows that dataloggingTest is missing.

STRICTLY READ-ONLY
------------------
This script issues SELECT statements only -- no INSERT/UPDATE/DELETE/DDL anywhere,
and it never commits. Safe to point at production. Credentials are typed at the
prompt (password hidden), never stored; use the read-only login.

IDs ARE EXPORTED ONLY AS A REMAPPING KEY
----------------------------------------
plate_bath_log.id is written as `src_log_id`, and each measurement carries the same
`src_log_id`. The loader MUST insert log rows with fresh IDENTITY values and
re-point the measurements via that key -- the target database has its own ids and
copying the source's would collide or mis-attach readings.

PRECISION CAVEAT
----------------
If the source has not had migration 025 applied, its `measurement` column is still
DECIMAL(8,2) and the exported values are ALREADY ROUNDED (Cl- 1.44661 -> 1.45).
This export can recover missing ROWS, not lost precision.

Output: two CSVs in ./export/ (UTF-8, empty field = NULL), plus a printed summary.

Requires:  pip install pyodbc  +  the "ODBC Driver 18 for SQL Server".
"""

import csv
import os
import sys

import db_common as db

SCHEMA = "qc"
VATS = ("Vat. 28", "Vat. 29", "Vat. 30")
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "export")

LOG_CSV = "plate_bath_log_export.csv"
MEAS_CSV = "plate_bath_measurement_export.csv"


def has_column(cur, table, column):
    """created_at only exists where migration 017 has been applied."""
    cur.execute(
        "SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS "
        "WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND COLUMN_NAME = ?;",
        SCHEMA, table, column)
    return cur.fetchone() is not None


def fetch_logs(cur, with_created_at):
    """Plate log rows for vats 28/29/30. The vat NAME travels with the row so the
    loader never has to assume vat ids match between databases."""
    created = ", l.[created_at]" if with_created_at else ", CAST(NULL AS DATETIME2(0)) AS [created_at]"
    cur.execute(
        f"SELECT l.[id] AS src_log_id, v.[name] AS vat, l.[date], "
        f"       l.[measured_by], l.[notes]{created} "
        f"FROM [{SCHEMA}].[plate_bath_log] l "
        f"JOIN [{SCHEMA}].[vat] v ON v.[id] = l.[vat_id] "
        f"WHERE v.[name] IN (?, ?, ?) "
        f"ORDER BY v.[name], l.[date], l.[id];",
        *VATS)
    return cur.fetchall()


def fetch_measurements(cur):
    """Every reading belonging to those log rows, keyed by src_log_id."""
    cur.execute(
        f"SELECT m.[plate_bath_log_id] AS src_log_id, m.[measurement_number], "
        f"       m.[measurement], m.[measurement_type] "
        f"FROM [{SCHEMA}].[plate_bath_measurement] m "
        f"JOIN [{SCHEMA}].[plate_bath_log] l ON l.[id] = m.[plate_bath_log_id] "
        f"JOIN [{SCHEMA}].[vat] v ON v.[id] = l.[vat_id] "
        f"WHERE v.[name] IN (?, ?, ?) "
        f"ORDER BY m.[plate_bath_log_id], m.[measurement_type], m.[measurement_number];",
        *VATS)
    return cur.fetchall()


def write_csv(path, header, rows):
    with open(path, "w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(header)
        for r in rows:
            # None -> empty field, matching the repo's "empty means NULL" convention.
            w.writerow(["" if v is None else v for v in r])


def summarise(logs, meas):
    """Per-vat counts + date range, and the measurement_type spread. This is the
    answer to 'is production ahead of test?'."""
    by_vat = {}
    for r in logs:
        d = by_vat.setdefault(r.vat, {"n": 0, "min": None, "max": None})
        d["n"] += 1
        if d["min"] is None or r.date < d["min"]:
            d["min"] = r.date
        if d["max"] is None or r.date > d["max"]:
            d["max"] = r.date

    print("\n--- plate_bath_log by vat ---")
    print(f"  {'vat':<9} {'rows':>5}   {'earliest':<12} {'latest':<12}   test has")
    # dataloggingTest state as of the original handoff load, for comparison.
    test_state = {"Vat. 28": (61, "2026-07-15"), "Vat. 29": (87, "2026-06-03"),
                  "Vat. 30": (85, "2026-06-03")}
    for vat in VATS:
        d = by_vat.get(vat)
        tn, td = test_state[vat]
        if not d:
            print(f"  {vat:<9} {0:>5}   (none found)")
            continue
        delta = d["n"] - tn
        verdict = f"{delta:+} vs test" if delta else "same as test"
        print(f"  {vat:<9} {d['n']:>5}   {str(d['min']):<12} {str(d['max']):<12}   "
              f"{tn} (to {td})   {verdict}")

    types = {}
    for m in meas:
        types[m.measurement_type] = types.get(m.measurement_type, 0) + 1
    print("\n--- measurement_type spread ---")
    for t, n in sorted(types.items()):
        print(f"  {t:<28} {n:>5}")
    if "Ni Absorbance_445nm" in types:
        print("  NOTE: source already carries absorbance rows.")
    if "Ni2+ + Co2+ Titration_ml" in types:
        print("  NOTE: source already has the re-typed Ni+Co label (025 applied there).")


def main():
    env, database = db.choose_environment("Export plate data FROM")
    print(f"\nREAD-ONLY export from {database}. No data will be modified.")
    server, user, pwd = db.prompt_connection()

    conn = db.connect(database, server, user, pwd)
    cur = conn.cursor()
    db.verify_database(cur, database)

    try:
        with_created = has_column(cur, "plate_bath_log", "created_at")
        if not with_created:
            print("  ! plate_bath_log has no created_at (migration 017 not applied "
                  "there) -- exporting it as empty/NULL.")

        logs = fetch_logs(cur, with_created)
        meas = fetch_measurements(cur)
    finally:
        # Never committed: this connection only ever ran SELECTs.
        conn.close()

    if not logs:
        sys.exit("No plate log rows found for Vat. 28/29/30 -- nothing exported.")

    os.makedirs(OUT_DIR, exist_ok=True)
    write_csv(os.path.join(OUT_DIR, LOG_CSV),
              ["src_log_id", "vat", "date", "measured_by", "notes", "created_at"], logs)
    write_csv(os.path.join(OUT_DIR, MEAS_CSV),
              ["src_log_id", "measurement_number", "measurement", "measurement_type"], meas)

    summarise(logs, meas)
    print(f"\nWrote {len(logs)} log rows  -> {os.path.join('export', LOG_CSV)}")
    print(f"Wrote {len(meas)} measurements -> {os.path.join('export', MEAS_CSV)}")
    print("\nNext: review the summary above to confirm the source is ahead of test, "
          "then load the missing rows into dataloggingTest.")


if __name__ == "__main__":
    main()
