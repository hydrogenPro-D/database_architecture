/* =====================================================================
 * 024_grant_read_dbo.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: grant READ-ONLY (SELECT) on the [dbo] schema to the data-manager role
 *         -- and NOTHING else. Covers all current and future objects in dbo.
 *         The app user (db_production_data_manager_user) receives this through
 *         its membership in the role, exactly like its qc-schema read (002).
 * Safe to re-run (idempotent -- GRANT is a no-op if already held). Records
 *         itself in the ledger. Run 001-002 (role) and 019 (rename) first.
 *
 * WHY THE ROLE, NOT THE USER DIRECTLY: the user's read access is modeled entirely
 * through [production_data_manager_role] (002 granted SELECT ON SCHEMA::qc to the
 * role, 003 added the user to it). Granting dbo-read to the role keeps that single
 * mechanism. To grant the USER principal directly instead, swap the grantee below
 * for [db_production_data_manager_user].
 *
 * READ ONLY: SELECT only. No INSERT/UPDATE/DELETE/EXECUTE/ALTER is granted here.
 *
 * Single batch on purpose (see 001 for why).
 * ===================================================================== */

IF DB_NAME() NOT IN (N'dataloggingDev', N'dataloggingTest')
    THROW 50000, N'Refusing to run: not a datalogging database.', 1;
IF OBJECT_ID(N'[qc].[schema_migrations]', N'U') IS NULL
    THROW 50000, N'Run 001 first (creates the qc schema + ledger).', 1;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals
               WHERE name = N'production_data_manager_role' AND type = 'R')
    THROW 50000, N'Role [production_data_manager_role] missing -- run 002 + 019 first.', 1;

-- Read-only on everything in the dbo schema (current and future objects).
GRANT SELECT ON SCHEMA::[dbo] TO [production_data_manager_role];

IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'024_grant_read_dbo.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'024_grant_read_dbo.sql');
GO
