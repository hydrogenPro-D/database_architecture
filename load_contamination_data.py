#!/usr/bin/env python3
"""
load_contamination_data.py  --  seed qc.contamination_log + qc.contamination_measurement
from the WIDE contamination CSV (one-off, interactive).

WHY A SEPARATE LOADER (vs load_data.py)
---------------------------------------
load_data.py positionally bulk-loads the 21 handoff CSVs, each of which already
matches its table 1:1 and carries explicit surrogate ids. Contamination is
different on three counts, so it needs its own script:

  1. The source CSV is WIDE  -- one row per sampling date, with the 20
     'Pos.xx <Metal>' columns -- but the DB is NORMALIZED (a log row that fans
     out to many (vat, metal, value) measurement rows). So we UNPIVOT the wide
     cells into child rows, rather than load column-for-column.
  2. The CSV has NO ids. IDENTITY auto-assigns; we do NOT use IDENTITY_INSERT.
  3. Readings stay TEXT, verbatim ('<2', '<0.01', 'N/A'); never coerced. A '*'
     means "no data" -> no measurement row (the view yields NULL for that cell).

created_at
----------
Seeded as NULL on purpose: these are HISTORICAL rows, so -- exactly like the
pre-existing history in migration 017 -- they should be LOCKED (outside the
today/yesterday edit window) and show a blank "Row added". That is why we insert
directly instead of calling usp_contamination_insert (whose DEFAULT would stamp
every seeded row "created today"). Set SEED_CREATED_AT to a literal timestamp
string if you'd rather date them.

SAFETY (same posture as load_data.py)
-------------------------------------
- Interactive: pick the environment; loading dev (PRODUCTION) hits the typed
  confirmation wall. Credentials are typed, never stored.
- Refuses to run if either contamination table already has rows.
- One transaction: any error rolls the whole load back.
- Needs a login with INSERT rights on the qc tables (an owner/admin -- the
  data-manager user is proc-only by design).

Run migration 022 first (creates the tables).
Requires:  pip install pyodbc  +  the "ODBC Driver 18 for SQL Server".
"""

import csv
import os
import sys
from datetime import datetime

import db_common as db

SCHEMA = "qc"
LOG_TABLE = f"[{SCHEMA}].[contamination_log]"
MEAS_TABLE = f"[{SCHEMA}].[contamination_measurement]"

# Wide source CSV (produced by the app's data/ETL Pipeline/contamination_ETL.py).
# It is NOT part of this repo; point this at your copy, or type a path when asked.
CSV_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "data", "contamination_log.csv")

# v1 covers Plating Line 1 only (the CSV carries no line column). The R&D Plating
# Line later = a second run with LINE = 'R&D Plating Line' and its own CSV.
LINE = "Plating Line 1"

# Historical seed -> NULL keeps these rows locked + blank "Row added" (migration
# 017 convention). Set to e.g. '2026-08-11 09:00:00' to date/unlock them instead.
SEED_CREATED_AT = None

# The five metals whose columns we unpivot; anything else is treated as metadata.
METALS = {"Cr", "Cu", "Fe", "Zn", "Pb"}

# Cell values that mean "no data" -> no measurement row (the view then yields NULL).
# '*' was confirmed to mean no data. Real censored readings ('<2', '<0.01') stay.
NO_DATA_TOKENS = {"*"}

# Header cells that are NOT measurement columns (matched case-insensitively).
META_HEADERS = {"sampling date", "sample taken by", "line", "id", "row added", ""}

# The CSV dates are Norwegian DD.MM.YYYY; SQL Server's DATE wants ISO. We parse to
# ISO before insert. First format that matches wins (day-first, so no m/d ambiguity).
DATE_FORMATS = ("%d.%m.%Y", "%d.%m.%y", "%Y-%m-%d", "%d/%m/%Y")


def normalize_date(raw, lineno):
    """'01.10.2025' -> '2025-10-01'. Exits (before any DB write) on an unparseable
    value so a bad date can't be silently dropped."""
    s = raw.strip()
    for fmt in DATE_FORMATS:
        try:
            return datetime.strptime(s, fmt).strftime("%Y-%m-%d")
        except ValueError:
            continue
    sys.exit(f"  row {lineno}: unrecognised date {raw!r} "
             f"(expected one of: {', '.join(DATE_FORMATS)}).")


def resolve_csv_path():
    """Use CSV_PATH if it exists, else prompt (the CSV lives in the app repo)."""
    if os.path.exists(CSV_PATH):
        return CSV_PATH
    print(f"CSV not found at:\n  {CSV_PATH}")
    typed = input("Type the path to contamination_log.csv: ").strip().strip('"')
    if not typed or not os.path.exists(typed):
        sys.exit("No readable CSV at that path. Aborting.")
    return typed


def classify_measurement(header_cell):
    """'Pos.28 Cr' -> ('Pos.28', 'Cr'); metadata / unknown -> None."""
    h = header_cell.strip()
    if h.lower() in META_HEADERS:
        return None
    parts = h.rsplit(" ", 1)          # vat may contain no space; metal is last token
    if len(parts) == 2 and parts[1] in METALS:
        return parts[0].strip(), parts[1]
    return None


def find_col(header, name):
    """Index of the column whose header equals `name` (case-insensitive), or None."""
    for i, h in enumerate(header):
        if h.strip().lower() == name:
            return i
    return None


def parse_header(header):
    """Return (date_idx, taker_idx, [(col_idx, vat, metal), ...]). Exits on a
    missing Sampling date column, and reports anything it could not classify."""
    date_idx = find_col(header, "sampling date")
    if date_idx is None:
        sys.exit("CSV has no 'Sampling date' column. Headers seen:\n  "
                 + ", ".join(h.strip() for h in header))
    taker_idx = find_col(header, "sample taken by")   # optional (may be absent)

    measures, ignored = [], []
    for i, cell in enumerate(header):
        if i in (date_idx, taker_idx):
            continue
        vm = classify_measurement(cell)
        if vm:
            measures.append((i, vm[0], vm[1]))
        elif cell.strip().lower() not in META_HEADERS:
            ignored.append(cell.strip())

    if not measures:
        sys.exit("No 'Pos.xx <Metal>' measurement columns detected in the CSV.")

    vats = sorted({vat for _, vat, _ in measures})
    print(f"  Sampling date : column {date_idx}")
    print(f"  Sample taken by: {'column ' + str(taker_idx) if taker_idx is not None else '(absent -> NULL)'}")
    print(f"  Measurement cols: {len(measures)}  (vats: {', '.join(vats)})")
    if ignored:
        print(f"  ! ignored (not metadata, not Pos.xx <Metal>): {', '.join(ignored)}")
    return date_idx, taker_idx, measures


def read_wide_csv(path):
    """Yield (sampling_date, sample_taken_by, [(vat, metal, value), ...]) per row.
    Empty cells become no measurement (one row per NON-empty reading)."""
    with open(path, "r", encoding="utf-8-sig", newline="") as fh:
        reader = csv.reader(fh)
        header = next(reader, None)
        if header is None:
            sys.exit("CSV is empty.")
        date_idx, taker_idx, measures = parse_header(header)

        for lineno, row in enumerate(reader, start=2):
            if not any(c.strip() for c in row):
                continue                                   # blank line
            raw_date = row[date_idx].strip() if date_idx < len(row) else ""
            if not raw_date:
                print(f"  ! row {lineno}: blank Sampling date -> skipped")
                continue
            sampling_date = normalize_date(raw_date, lineno)
            taker = None
            if taker_idx is not None and taker_idx < len(row):
                taker = row[taker_idx].strip() or None

            readings = []
            for col_idx, vat, metal in measures:
                if col_idx < len(row):
                    val = row[col_idx].strip()
                    if val != "" and val not in NO_DATA_TOKENS:   # '*'/blank -> NULL
                        readings.append((vat, metal, val))
            yield sampling_date, taker, readings


def rowcount(cur, table):
    cur.execute(f"SELECT COUNT(*) FROM {table};")
    return cur.fetchone()[0]


def main():
    path = resolve_csv_path()
    print(f"\nSource CSV: {path}")

    env, database = db.choose_environment("Load contamination data into")
    if database in db.PROD_DATABASES:
        db.confirm_production(database)
    server, user, pwd = db.prompt_connection()

    conn = db.connect(database, server, user, pwd)
    cur = conn.cursor()
    db.verify_database(cur, database)

    # Tables must exist (migration 022) and be empty (no accidental dupes).
    if cur.tables(table="contamination_log", schema=SCHEMA).fetchone() is None:
        sys.exit("qc.contamination_log does not exist -- run migration 022 first.")
    non_empty = [t for t in ("contamination_log", "contamination_measurement")
                 if rowcount(cur, f"[{SCHEMA}].[{t}]") > 0]
    if non_empty:
        sys.exit("Refusing to load -- these tables already have rows:\n  "
                 + ", ".join(non_empty))

    print(f"\nReading + unpivoting {os.path.basename(path)} ...")
    rows = list(read_wide_csv(path))
    if not rows:
        sys.exit("Nothing to load (no data rows).")

    insert_log = (f"INSERT INTO {LOG_TABLE} (line, sampling_date, sample_taken_by, created_at) "
                  f"OUTPUT INSERTED.id VALUES (?, ?, ?, ?);")
    insert_meas = (f"INSERT INTO {MEAS_TABLE} (contamination_log_id, vat, metal, value) "
                   f"VALUES (?, ?, ?, ?);")

    logs = meas = 0
    try:
        for sampling_date, taker, readings in rows:
            cur.execute(insert_log, LINE, sampling_date, taker, SEED_CREATED_AT)
            log_id = cur.fetchone()[0]
            logs += 1
            if readings:
                cur.executemany(insert_meas,
                                [(log_id, vat, metal, val) for vat, metal, val in readings])
                meas += len(readings)
        conn.commit()
    except Exception as exc:
        conn.rollback()
        sys.exit(f"\nFAILED: {exc}\n  Rolled back -- nothing was loaded.")
    finally:
        conn.close()

    print(f"\nDone. Loaded {logs} log rows + {meas} measurements into {database}.")


if __name__ == "__main__":
    main()
