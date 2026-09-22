/* =====================================================================
 * reset_qc_tables_TEST_ONLY.sql   --   DESTRUCTIVE. TEST DATABASE ONLY.
 *
 * Drops all 21 qc.* tables so the corrected 004_create_qc_tables.sql can
 * recreate them from scratch. Use this to rebuild the test schema after a
 * generator change. It does NOT touch the qc schema, role, user, or the
 * schema_migrations ledger.
 *
 * Hard-guarded to dataloggingTest: it THROWs on any other database, so it can
 * never run against production (dataloggingDev). Single batch on purpose, so the
 * guard aborts everything.
 *
 * After running this:  re-run 004_create_qc_tables.sql, then load_data.py.
 * ===================================================================== */

IF DB_NAME() <> N'dataloggingTest'
    THROW 50000, N'Refusing to run: this drops tables and is for dataloggingTest only.', 1;

-- Children before parents so inline foreign keys don't block the drops.
DROP TABLE IF EXISTS [qc].[plate_bath_measurement];
DROP TABLE IF EXISTS [qc].[plate_bath_log];
DROP TABLE IF EXISTS [qc].[strike_bath_measurement];
DROP TABLE IF EXISTS [qc].[strike_bath_log];
DROP TABLE IF EXISTS [qc].[activator_bath_measurement];
DROP TABLE IF EXISTS [qc].[activator_bath_log];
DROP TABLE IF EXISTS [qc].[cleaner_bath_measurement];
DROP TABLE IF EXISTS [qc].[cleaner_bath_log];
DROP TABLE IF EXISTS [qc].[conductivity_vat_log];
DROP TABLE IF EXISTS [qc].[conductivity_log];
DROP TABLE IF EXISTS [qc].[ph_measurement];
DROP TABLE IF EXISTS [qc].[ph_log_vat];
DROP TABLE IF EXISTS [qc].[ph_log];
DROP TABLE IF EXISTS [qc].[electrode_production_vat];
DROP TABLE IF EXISTS [qc].[electrode_production_tracking];
DROP TABLE IF EXISTS [qc].[chemical_addition];
DROP TABLE IF EXISTS [qc].[chemical_addition_log_vat];
DROP TABLE IF EXISTS [qc].[chemical_addition_log];
DROP TABLE IF EXISTS [qc].[electrode_chemical_dosage];
DROP TABLE IF EXISTS [qc].[chemical];
DROP TABLE IF EXISTS [qc].[vat];
GO
