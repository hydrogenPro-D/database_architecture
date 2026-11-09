#!/usr/bin/env python3
"""
load_data.py  --  load the 21 QC CSVs into the qc.* tables (interactive).

DESIGN (per requirements)
-------------------------
- Interactive, no command-line flags: a tiny text menu picks the environment.
- Loading into dev (PRODUCTION) triggers a LOUD, typed confirmation wall.
- Credentials are TYPED at the prompt (password hidden), never read from env
  vars or stored. The login must have INSERT rights on the qc tables (an
  owner/admin -- the qc_data_manager_user is read-only by design).
- Refuses to load if ANY target table already has rows (no accidental dupes /
  primary-key clashes).
- Preserves the CSV ids via SET IDENTITY_INSERT, and turns empty CSV fields into
  real NULLs. Loads parents-before-children so foreign keys are satisfied.

Reuses schema/order/paths from generate_mssql.py and the connection/prompt
helpers from db_common.py, so it can't drift from the DDL or the runner.

Requires:  pip install pyodbc   +   the "ODBC Driver 18 for SQL Server".
"""

import csv
import sys

import pyodbc

import db_common as db
from generate_mssql import LOAD_ORDER, SCHEMA, qualify, csv_path

CHAR_TYPES = {"char", "nchar", "varchar", "nvarchar", "text", "ntext"}


def get_column_meta(cur, table):
    """(name, data_type, char_max_len) per column in ordinal order, so we map
    CSV columns positionally (sidestepping header-vs-column name mismatches like
    'TU (g/electrode)') and can pin bind sizes."""
    cur.execute(
        "SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH "
        "FROM INFORMATION_SCHEMA.COLUMNS "
        "WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION;",
        SCHEMA, table)
    return cur.fetchall()


def input_sizes(meta):
    """Pin every parameter to a wide nvarchar of a definite size, so pyodbc's
    fast_executemany doesn't guess buffer widths from the first row (the cause of
    'String data, right truncation'). Values go in as strings; SQL Server converts
    them to each column's real type on insert."""
    sizes = []
    for m in meta:
        if m.DATA_TYPE in CHAR_TYPES:
            n = m.CHARACTER_MAXIMUM_LENGTH
            size = 4000 if (n is None or n < 0) else n   # n < 0 == nvarchar(max)
        else:
            size = 64                                     # numbers/dates as text
        sizes.append((pyodbc.SQL_WVARCHAR, size, 0))
    return sizes


def rowcount(cur, table):
    cur.execute(f"SELECT COUNT(*) FROM {qualify(table)};")
    return cur.fetchone()[0]


def load_table(cur, table):
    meta = get_column_meta(cur, table)
    if not meta:
        raise RuntimeError(f"{qualify(table)} does not exist -- run migrations first.")
    # Drop ROWVERSION columns (data_type 'timestamp'): they're auto-generated and
    # can never be inserted, and the CSVs don't carry them (see migration 013).
    meta = [m for m in meta if m.DATA_TYPE != "timestamp"]
    cols = [m.COLUMN_NAME for m in meta]

    with open(csv_path(table), "r", encoding="utf-8-sig", newline="") as fh:
        reader = csv.reader(fh)
        header = next(reader)
        if len(header) != len(cols):
            raise RuntimeError(
                f"{table}: CSV has {len(header)} columns, table has {len(cols)}.")
        rows = [tuple(None if v == "" else v for v in row) for row in reader]

    if not rows:
        print(f"  {table}: 0 rows (skipped)")
        return 0

    collist = ", ".join(f"[{c}]" for c in cols)
    placeholders = ", ".join("?" * len(cols))
    sql = f"INSERT INTO {qualify(table)} ({collist}) VALUES ({placeholders});"

    cur.execute(f"SET IDENTITY_INSERT {qualify(table)} ON;")
    cur.fast_executemany = True
    cur.setinputsizes(input_sizes(meta))
    cur.executemany(sql, rows)
    cur.execute(f"SET IDENTITY_INSERT {qualify(table)} OFF;")
    print(f"  {table}: {len(rows)} rows")
    return len(rows)


def main():
    env, database = db.choose_environment("Load QC data into")
    if database in db.PROD_DATABASES:
        db.confirm_production(database)
    server, user, pwd = db.prompt_connection()

    conn = db.connect(database, server, user, pwd)
    cur = conn.cursor()
    db.verify_database(cur, database)

    # Refuse if any target table already holds data.
    non_empty = [t for t in LOAD_ORDER if rowcount(cur, t) > 0]
    if non_empty:
        sys.exit("Refusing to load -- these tables already have rows:\n  "
                 + ", ".join(non_empty))

    print(f"\nLoading {len(LOAD_ORDER)} tables into {database} ...")
    total = 0
    try:
        for table in LOAD_ORDER:          # parents before children
            total += load_table(cur, table)
        conn.commit()
    except Exception as exc:
        conn.rollback()
        sys.exit(f"\nFAILED: {exc}\n  Rolled back -- nothing was loaded.")
    finally:
        conn.close()

    print(f"\nDone. Loaded {total} rows into {database}.")


if __name__ == "__main__":
    main()
