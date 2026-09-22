#!/usr/bin/env python3
"""
db_common.py  --  shared interactive prompts + Azure SQL connection helpers.

Used by load_data.py (and any future tool) so it picks an environment, confirms
production, gathers typed credentials, and connects the exact same way.

Requires:  pip install pyodbc   +   the "ODBC Driver 18 for SQL Server".
"""

import getpass
import sys

try:
    import pyodbc
except ImportError:
    sys.exit("pyodbc is not installed.  Run:  pip install pyodbc")

ODBC_DRIVER = "ODBC Driver 18 for SQL Server"

# (env key, database). Same server; the database differs per environment.
ENVIRONMENTS = [("test", "dataloggingTest"), ("dev", "dataloggingDev")]
PROD_DATABASES = {"dataloggingDev"}            # dev is production


def choose_environment(action):
    """Tiny text menu. `action` is a verb phrase, e.g. 'Apply migrations to'."""
    print(f"{action} which environment?\n")
    for i, (env, db) in enumerate(ENVIRONMENTS, start=1):
        tag = "   <-- PRODUCTION" if db in PROD_DATABASES else ""
        print(f"  {i}) {env:<5} -> {db}{tag}")
    print()
    while True:
        choice = input(f"Enter choice [1-{len(ENVIRONMENTS)}]: ").strip()
        if choice.isdigit() and 1 <= int(choice) <= len(ENVIRONMENTS):
            return ENVIRONMENTS[int(choice) - 1]
        print("  Invalid choice, try again.")


def confirm_production(database):
    """Loud, typed confirmation wall before touching a production database."""
    bar = "=" * 64
    print("\n" + bar)
    print(f"  WARNING: {database} is the PRODUCTION database.")
    print(bar)
    typed = input(f"Type the database name '{database}' to proceed: ").strip()
    if typed != database:
        sys.exit("Name did not match. Aborting.")
    if input("Are you ABSOLUTELY sure? (type 'yes'): ").strip().lower() != "yes":
        sys.exit("Not confirmed. Aborting.")


def prompt_connection():
    """Typed credentials (password hidden). Never read from env / never stored."""
    print()
    server = input("Server (e.g. myserver.database.windows.net): ").strip()
    user = input("SQL username: ").strip()
    pwd = getpass.getpass("Password: ")
    if not server or not user or not pwd:
        sys.exit("Server, username and password are all required.")
    return server, user, pwd


def connect(database, server, user, pwd):
    conn_str = (
        f"DRIVER={{{ODBC_DRIVER}}};"
        f"SERVER=tcp:{server},1433;"
        f"DATABASE={database};"
        f"UID={user};PWD={pwd};"
        f"Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"
    )
    return pyodbc.connect(conn_str, autocommit=False)


def verify_database(cur, expected):
    """Belt-and-braces: confirm the connection really landed on `expected`."""
    cur.execute("SELECT DB_NAME();")
    actual = cur.fetchone()[0]
    if actual != expected:
        sys.exit(f"Connected to {actual!r}, expected {expected!r} -- aborting.")
