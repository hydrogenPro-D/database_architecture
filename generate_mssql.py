#!/usr/bin/env python3
"""
generate_mssql.py  --  drawdb export  ->  MSSQL create_test_database.sql

WHY THIS EXISTS
---------------
The schema is designed visually on drawdb.com and exported as SQL. That export
is "cool but not perfect" for MSSQL, so a fixed set of corrections must be
re-applied every time the diagram is re-exported. Doing that by hand is not
reproducible. This script encodes the corrections AS CODE: re-export from
drawdb anytime, run this script, and you always get the same corrected,
load-ready SQL -- never hand-edit the output.

WHAT IT DOES
------------
1. Picks the NEWEST *.sql in DRAWDB_DIR (re-exports get new timestamped names,
   so we never hard-code a filename).
2. Re-types numeric columns from the ACTUAL CSV data:
      - all values integer            -> INT
      - any value has decimals        -> DECIMAL(precision, scale) sized to fit
   This fixes two drawdb problems at once:
      - bare `DECIMAL` in MSSQL means DECIMAL(18,0) = ZERO decimals (truncates
        e.g. ph_value -0.19 -> 0),
      - and `135.0` text failing to bulk-load into an INT column.
3. DATETIME -> DATETIME2.
4. Applies nullability overrides (see NULLABILITY_OVERRIDES).
5. Keeps all foreign keys (inline on their column when INLINE_FOREIGN_KEYS).
6. Emits one script shaped by the CONFIG block. Defaults target Azure SQL: a
   schema-qualified, idempotent migration (DB_NAME guard + IF OBJECT_ID(...) IS
   NULL CREATE, no drops, no BULK INSERT). Flip INCLUDE_TEARDOWN / DATABASE_NAME
   / EMIT_LOAD_SECTION for a destructive local rebuild instead.

USAGE
-----
    python generate_mssql.py

Requires Python 3.8+. No third-party packages.
"""

import csv
import glob
import os
import re
import sys

# --------------------------------------------------------------------------
# CONFIG  -- the only place you edit for future changes
# --------------------------------------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))
DRAWDB_DIR = os.path.join(HERE, "Draw DB")          # where drawdb exports land
CSV_DIR    = os.path.join(HERE, "db_tables")         # the 21 load-ready CSVs
OUTPUT_SQL = os.path.join(HERE, "sql", "migrations", "004_create_qc_tables.sql")

# Schema the tables live in. None -> unqualified (dbo).
SCHEMA = "qc"

# Databases this migration is allowed to run against (DB_NAME guard at the top
# of the generated script). Azure SQL Database has no USE, so this is how we
# stop the script hitting the wrong database (e.g. master).
ALLOWED_DATABASES = ["dataloggingDev", "dataloggingTest"]

# Azure SQL Database can't CREATE DATABASE/USE inline, and loads via load_data.py
# (BULK INSERT can't read local files on Azure), so both are off here.
DATABASE_NAME = None                 # set to a name to emit CREATE DATABASE / USE
EMIT_LOAD_SECTION = False            # False -> DDL only, no BULK INSERT

# False -> idempotent CREATE (IF OBJECT_ID(...) IS NULL): never drops data. This
#          is mandatory for a migration, especially since dev == prod.
# True  -> DROP TABLE IF EXISTS then recreate (destructive; local rebuild only).
INCLUDE_TEARDOWN = False

# True  -> foreign keys live inline on their column (REFERENCES ...); tables are
#          created parents-first so the references resolve. Cleaner to read.
# False -> drawdb's order-independent style: plain CREATE TABLEs followed by a
#          separate block of ALTER TABLE ... ADD FOREIGN KEY statements.
INLINE_FOREIGN_KEYS = True

# Extra precision digits added on the integer side of every DECIMAL, so data
# that grows slightly larger than today still fits without a re-run.
DECIMAL_HEADROOM = 4

# Cap on decimal places. Some CSV values carry floating-point division noise
# (e.g. 0.436666666666667), which would otherwise blow the scale up to 15.
# Values with more decimals than this are ROUNDED on load (SQL Server rounds
# string->decimal, it does not error). Raise it if a column needs real precision.
MAX_SCALE = 6

# Force a column's nullability regardless of what drawdb emitted.
#   (table, column): True  -> nullable
#   (table, column): False -> NOT NULL
NULLABILITY_OVERRIDES = {
    ("electrode_production_tracking", "chemical_addition_log_id"): True,
}

# Manual escape hatch: force an exact type, bypassing the CSV auto-scan.
#   (table, column): "DECIMAL(10,4)"
TYPE_OVERRIDES = {}

# Force a fixed number of decimal places on a column while STILL auto-sizing the
# integer part from the data. Values with more decimals than this round on load.
SCALE_OVERRIDES = {
    ("cleaner_bath_measurement", "measurement"): 2,
    ("activator_bath_measurement", "measurement"): 2,
    ("strike_bath_measurement", "measurement"): 2,
    ("plate_bath_measurement", "measurement"): 2,
}

# Parents before children -- BULK INSERT load order (from DB_HANDOFF.md sec 9).
LOAD_ORDER = [
    "vat", "chemical", "electrode_chemical_dosage",
    "chemical_addition_log", "chemical_addition_log_vat", "chemical_addition",
    "electrode_production_tracking", "electrode_production_vat",
    "ph_log", "ph_log_vat", "ph_measurement",
    "conductivity_log", "conductivity_vat_log",
    "cleaner_bath_log", "cleaner_bath_measurement",
    "activator_bath_log", "activator_bath_measurement",
    "strike_bath_log", "strike_bath_measurement",
    "plate_bath_log", "plate_bath_measurement",
]

NUMERIC_TYPES = {"INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT",
                 "DECIMAL", "NUMERIC", "FLOAT", "REAL", "MONEY", "SMALLMONEY"}

INT_RE = re.compile(r"^-?\d+$")
DEC_RE = re.compile(r"^-?\d*\.\d+$")


# --------------------------------------------------------------------------
# CSV scanning
# --------------------------------------------------------------------------
def csv_path(table):
    return os.path.join(CSV_DIR, table + ".csv")


def scan_column_values(table, col_index):
    """Return non-empty raw string values for the column at the given ordinal
    position. We match by POSITION, not header name: drawdb renames some columns
    (e.g. 'TU (g/electrode)' -> tu_dose_g_per_electrode), but the CSV columns are
    in the same order as the table columns (same way load_data.py maps them)."""
    path = csv_path(table)
    if not os.path.exists(path):
        return None  # no CSV -> caller keeps a safe default
    with open(path, "r", encoding="utf-8-sig", newline="") as fh:
        reader = csv.reader(fh)
        header = next(reader, None)
        if header is None or col_index is None or col_index >= len(header):
            return None
        values = []
        for row in reader:
            if col_index < len(row):
                v = row[col_index].strip()
                if v != "":
                    values.append(v)
        return values


def decide_numeric_type(table, column, col_index):
    """Choose INT or DECIMAL(p,s) by looking at the real CSV values."""
    values = scan_column_values(table, col_index)
    if not values:
        return "INT"  # empty or missing -> safe integer default

    all_int = True
    max_int_digits = 1
    max_scale = 0
    for v in values:
        if INT_RE.match(v):
            digits = len(v.lstrip("-"))
            max_int_digits = max(max_int_digits, digits)
        elif DEC_RE.match(v):
            all_int = False
            int_part, frac_part = v.lstrip("-").split(".")
            max_int_digits = max(max_int_digits, len(int_part) or 1)
            max_scale = max(max_scale, len(frac_part))
        else:
            # Unexpected non-numeric token: fall back to FLOAT rather than
            # silently truncating, and shout about it.
            print(f"  ! {table}.{column}: non-numeric value {v!r} -> FLOAT")
            return "FLOAT"

    forced_scale = SCALE_OVERRIDES.get((table, column))

    if all_int and forced_scale is None:
        return "INT"

    if forced_scale is not None:
        if max_scale > forced_scale:
            print(f"  ~ {table}.{column}: scale {max_scale} forced to "
                  f"{forced_scale} (values will round on load)")
        max_scale = forced_scale
    elif max_scale > MAX_SCALE:
        print(f"  ~ {table}.{column}: scale {max_scale} capped to {MAX_SCALE} "
              f"(values will round on load)")
        max_scale = MAX_SCALE

    precision = max_int_digits + max_scale + DECIMAL_HEADROOM
    precision = min(precision, 38)          # MSSQL hard cap
    precision = max(precision, max_scale + 1)
    return f"DECIMAL({precision},{max_scale})"


# --------------------------------------------------------------------------
# SQL parsing / rewriting
# --------------------------------------------------------------------------
COL_RE = re.compile(r"^\[(?P<col>\w+)\]\s+(?P<rest>.+)$")
TYPE_TOKEN_RE = re.compile(r"^(?P<type>\w+(?:\(\d+\))?)")


def qualify(table):
    """[schema].[table] when a schema is configured, else [table]."""
    return f"[{SCHEMA}].[{table}]" if SCHEMA else f"[{table}]"


def rewrite_column(table, line, make_pk=False, fks=None, col_index=None):
    """Rewrite a single column definition line; return (col_name, new_line).

    If make_pk is True this column carries the (single-column) primary key
    inline, e.g. `[id] INT IDENTITY PRIMARY KEY`. PRIMARY KEY already implies
    NOT NULL + UNIQUE, so those redundant keywords are dropped.

    If fks is given and this column has a foreign key, a `REFERENCES ...` clause
    is appended inline.
    """
    stripped = line.strip().rstrip(",").strip()
    m = COL_RE.match(stripped)
    if not m:
        return None, line  # not a column line (e.g. blank)

    col = m.group("col")
    rest = m.group("rest")
    rest_up = rest.upper()

    is_identity = "IDENTITY" in rest_up
    is_unique = "UNIQUE" in rest_up
    not_null = "NOT NULL" in rest_up

    base = TYPE_TOKEN_RE.match(rest).group("type")
    base_up = base.upper()

    # --- decide the new type ---
    if (table, col) in TYPE_OVERRIDES:
        new_type = TYPE_OVERRIDES[(table, col)]
    elif is_identity:
        new_type = "INT"                       # surrogate keys stay INT IDENTITY
    elif base_up in NUMERIC_TYPES:
        new_type = decide_numeric_type(table, col, col_index)
    elif base_up == "DATETIME":
        new_type = "DATETIME2"
    else:
        new_type = base                        # DATE / TIME / NVARCHAR(...) etc.

    # --- decide nullability ---
    if (table, col) in NULLABILITY_OVERRIDES:
        not_null = not NULLABILITY_OVERRIDES[(table, col)]

    parts = [f"[{col}]", new_type]
    if make_pk:
        # PRIMARY KEY implies NOT NULL + UNIQUE; emit only IDENTITY + PK.
        if is_identity:
            parts.append("IDENTITY")
        parts.append("PRIMARY KEY")
    else:
        if not_null:
            parts.append("NOT NULL")
        if is_identity:
            parts.append("IDENTITY")
        if is_unique:
            parts.append("UNIQUE")

    if fks and (table, col) in fks:
        ref_table, ref_col = fks[(table, col)]
        parts.append(f"REFERENCES {qualify(ref_table)}([{ref_col}])")

    return col, "\t" + " ".join(parts)


def parse_pk_columns(body):
    """Return the list of columns named in a table-level PRIMARY KEY(...) line."""
    for raw in body.split("\n"):
        s = raw.strip().rstrip(",").strip()
        if s.upper().startswith("PRIMARY KEY") and "(" in s:
            inside = s[s.index("(") + 1: s.rindex(")")]
            return [c.strip().strip("[]") for c in inside.split(",")]
    return []


def parse_foreign_keys(sql_text):
    """Map (child_table, child_col) -> (parent_table, parent_col) from the
    drawdb ALTER TABLE ... ADD FOREIGN KEY statements."""
    fk_re = re.compile(
        r"ALTER TABLE \[(\w+)\]\s+ADD FOREIGN KEY\(\[(\w+)\]\)\s+"
        r"REFERENCES \[(\w+)\]\(\[(\w+)\]\)",
        re.DOTALL,
    )
    fks = {}
    for child, col, parent, pcol in fk_re.findall(sql_text):
        fks[(child, col)] = (parent, pcol)
    return fks


def rewrite_create_table(table, body, fks=None):
    # A single-column PK is collapsed inline onto its column; composite PKs keep
    # the table-level PRIMARY KEY(...) line (the only valid form for them).
    pk_cols = parse_pk_columns(body)
    inline_pk_col = pk_cols[0] if len(pk_cols) == 1 else None

    out_lines = []
    report = []
    col_index = 0  # ordinal position, matched against the CSV columns by order
    for raw in body.split("\n"):
        s = raw.strip()
        if not s:
            continue
        if s.rstrip(",").upper().startswith("PRIMARY KEY"):
            if inline_pk_col is not None:
                continue  # collapsed onto the column; drop the trailing line
            out_lines.append("\t" + s.rstrip(","))
            continue
        m = COL_RE.match(s.rstrip(",").strip())
        make_pk = bool(m and inline_pk_col and m.group("col") == inline_pk_col)
        col, new_line = rewrite_column(table, raw, make_pk, fks, col_index)
        col_index += 1
        out_lines.append(new_line)
        if col:
            old = raw.strip().rstrip(",")
            new = new_line.strip()
            if old != new:
                report.append((col, old, new))
    block = f"CREATE TABLE {qualify(table)} (\n" + ",\n".join(out_lines) + "\n);"
    return block, report


def parse_and_rewrite(sql_text):
    sql_text = sql_text.replace("\r\n", "\n")
    fks = parse_foreign_keys(sql_text)
    inline = fks if INLINE_FOREIGN_KEYS else None

    create_re = re.compile(
        r"CREATE TABLE \[(?P<name>\w+)\] \((?P<body>.*?)\n\);", re.DOTALL
    )
    blocks = []  # list of (table_name, block) so we can reorder later
    full_report = {}
    for m in create_re.finditer(sql_text):
        table = m.group("name")
        block, report = rewrite_create_table(table, m.group("body"), inline)
        blocks.append((table, block))
        if report:
            full_report[table] = report

    # The order-independent FK section, kept verbatim for the non-inline mode.
    alter_idx = sql_text.find("ALTER TABLE")
    fk_section = sql_text[alter_idx:].strip() if alter_idx != -1 else ""
    return blocks, fk_section, full_report


# --------------------------------------------------------------------------
# Output assembly
# --------------------------------------------------------------------------
def bulk_insert_stmt(table):
    path = os.path.abspath(csv_path(table))
    return (
        f"BULK INSERT [{table}]\n"
        f"FROM '{path}'\n"
        f"WITH (\n"
        f"    FORMAT = 'CSV',\n"
        f"    FIRSTROW = 2,\n"
        f"    FIELDTERMINATOR = ',',\n"
        f"    ROWTERMINATOR = '0x0d0a',\n"
        f"    CODEPAGE = '65001',\n"
        f"    KEEPIDENTITY,\n"
        f"    KEEPNULLS,\n"
        f"    TABLOCK\n"
        f");\nGO\n"
    )


def header_lines(source_name):
    return [
        "/* =====================================================================",
        f" * {os.path.basename(OUTPUT_SQL)}  --  GENERATED FILE, DO NOT EDIT BY HAND",
        " * Produced by generate_mssql.py from the drawdb export:",
        f" *     {source_name}",
        " * Re-run:  python generate_mssql.py",
        " * ===================================================================== */",
        "",
    ]


def ordered_tables(blocks):
    # Parents-first so inline REFERENCES resolve.
    block_map = dict(blocks)
    ordered = [t for t in LOAD_ORDER if t in block_map]
    ordered += [t for t, _ in blocks if t not in LOAD_ORDER]
    return block_map, ordered


def build_migration(blocks, source_name):
    """Azure migration: ONE batch (no GO), so a single guard THROW aborts the
    whole script -- SSMS runs GO-separated batches independently and would
    otherwise continue past a failed guard. Idempotent + self-recording."""
    block_map, ordered = ordered_tables(blocks)
    fname = os.path.basename(OUTPUT_SQL)
    out = header_lines(source_name)

    out.append("/* Single batch on purpose: SSMS runs each GO-batch independently,")
    out.append(" * so a guard in its own batch would NOT stop later batches. With one")
    out.append(" * batch, the THROW below aborts everything. */")
    if ALLOWED_DATABASES:
        allowed = ", ".join(f"N'{d}'" for d in ALLOWED_DATABASES)
        out.append(f"IF DB_NAME() NOT IN ({allowed})")
        out.append("    THROW 50000, N'Refusing to run: not an allowed database.', 1;")
    out.append("IF OBJECT_ID(N'[qc].[schema_migrations]', N'U') IS NULL")
    out.append("    THROW 50000, N'Run 001 first (creates the qc schema + ledger).', 1;")
    out.append("")

    out.append("/* ---- tables (idempotent; parents first for inline FKs) ---- */")
    for table in ordered:
        out.append(f"IF OBJECT_ID(N'{qualify(table)}', N'U') IS NULL")
        out.append(block_map[table])
    out.append("")

    out.append("/* ---- self-record into the migration ledger ---- */")
    out.append(f"IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations] "
               f"WHERE filename = N'{fname}')")
    out.append(f"    INSERT INTO [qc].[schema_migrations] (filename) "
               f"VALUES (N'{fname}');")
    out.append("GO")
    return "\n".join(out).rstrip() + "\n"


def build_local_rebuild(blocks, fk_section, source_name):
    """Destructive local rebuild (INCLUDE_TEARDOWN): DROP + CREATE + optional FK
    section + optional BULK INSERT, GO-separated. For a throwaway local SQL
    Server only -- never Azure / never prod."""
    block_map, ordered = ordered_tables(blocks)
    out = header_lines(source_name)

    if DATABASE_NAME:
        out.append(f"IF DB_ID('{DATABASE_NAME}') IS NULL CREATE DATABASE [{DATABASE_NAME}];")
        out.append("GO")
        out.append(f"USE [{DATABASE_NAME}];")
        out.append("GO\n")

    out.append("/* ---- teardown (children first so FKs drop cleanly) ---- */")
    for table in reversed(LOAD_ORDER):
        out.append(f"DROP TABLE IF EXISTS {qualify(table)};")
    out.append("GO\n")

    out.append("/* ---- tables ---- */")
    for table in ordered:
        out.append(block_map[table])
        out.append("GO")
    out.append("")

    if not INLINE_FOREIGN_KEYS and fk_section:
        out.append("/* ---- foreign keys ---- */")
        out.append(fk_section)
        out.append("")

    if EMIT_LOAD_SECTION:
        out.append("/* ---- data load (dependency order; empty field = NULL) ---- */")
        for table in LOAD_ORDER:
            out.append(bulk_insert_stmt(table))

    return "\n".join(out).rstrip() + "\n"


def build_output(blocks, fk_section, source_name):
    if INCLUDE_TEARDOWN:
        return build_local_rebuild(blocks, fk_section, source_name)
    return build_migration(blocks, source_name)


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
def main():
    candidates = glob.glob(os.path.join(DRAWDB_DIR, "*.sql"))
    if not candidates:
        sys.exit(f"No .sql export found in {DRAWDB_DIR!r}")
    source = max(candidates, key=os.path.getmtime)
    print(f"Source export : {os.path.basename(source)}")

    with open(source, "r", encoding="utf-8") as fh:
        sql_text = fh.read()

    blocks, fk_section, report = parse_and_rewrite(sql_text)

    print(f"Tables        : {len(blocks)}")
    print("Type / null changes vs drawdb:")
    if not report:
        print("  (none)")
    for table in LOAD_ORDER:
        for col, old, new in report.get(table, []):
            print(f"  {table}.{col}")
            print(f"      - {old}")
            print(f"      + {new}")

    output = build_output(blocks, fk_section, os.path.basename(source))
    with open(OUTPUT_SQL, "w", encoding="utf-8") as fh:
        fh.write(output)
    print(f"\nWrote         : {os.path.basename(OUTPUT_SQL)}")


if __name__ == "__main__":
    main()
