/* =====================================================================
 * 012_add_view_indexes.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: covering nonclustered indexes on the child foreign-key columns the
 *         qc.vw_* views join on. Each view scans a parent log and LEFT JOINs its
 *         child rows on an (until now) unindexed FK, then pivots with
 *         MAX(CASE..) + GROUP BY parent.id -> a full child scan + hash join.
 *         These indexes turn that into an ordered seek/merge + stream aggregate,
 *         and INCLUDE exactly the columns each view reads so the base table is
 *         never touched (covering). Read-optimization only; changes no data.
 *
 * Idempotent (IF NOT EXISTS over sys.indexes). Append-only: 004 stays frozen.
 * Single batch on purpose (CREATE INDEX needs no leading batch) so the THROW
 * guard aborts everything on the wrong database. Run 001 + 004 first.
 * ===================================================================== */

IF DB_NAME() NOT IN (N'dataloggingDev', N'dataloggingTest')
    THROW 50000, N'Refusing to run: not a datalogging database.', 1;
IF OBJECT_ID(N'[qc].[schema_migrations]', N'U') IS NULL
    THROW 50000, N'Run 001 first (creates the qc schema + ledger).', 1;

/* ---- pH Control (vw_ph_control) ------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_ph_log_vat_ph_log_id'
                 AND object_id = OBJECT_ID(N'[qc].[ph_log_vat]'))
    CREATE NONCLUSTERED INDEX [IX_ph_log_vat_ph_log_id]
        ON [qc].[ph_log_vat] ([ph_log_id])
        INCLUDE ([vat_id], [chemical_id], [chemical_amount], [chemical_addition_time]);

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_ph_measurement_ph_log_vat_id'
                 AND object_id = OBJECT_ID(N'[qc].[ph_measurement]'))
    CREATE NONCLUSTERED INDEX [IX_ph_measurement_ph_log_vat_id]
        ON [qc].[ph_measurement] ([ph_log_vat_id])
        INCLUDE ([measurement_number], [ph_value]);

/* ---- Adding Chemicals (vw_adding_chemicals) ------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_chemical_addition_log_vat_log_id'
                 AND object_id = OBJECT_ID(N'[qc].[chemical_addition_log_vat]'))
    CREATE NONCLUSTERED INDEX [IX_chemical_addition_log_vat_log_id]
        ON [qc].[chemical_addition_log_vat] ([chemical_addition_log_id])
        INCLUDE ([vat_id], [water_level_reduction]);

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_chemical_addition_log_vat_id'
                 AND object_id = OBJECT_ID(N'[qc].[chemical_addition]'))
    CREATE NONCLUSTERED INDEX [IX_chemical_addition_log_vat_id]
        ON [qc].[chemical_addition] ([chemical_addition_log_vat_id])
        INCLUDE ([chemical_id], [chemical_amount], [concentration]);

/* ---- Production Tracking (vw_production_tracking) -------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_electrode_production_vat_tracking_id'
                 AND object_id = OBJECT_ID(N'[qc].[electrode_production_vat]'))
    CREATE NONCLUSTERED INDEX [IX_electrode_production_vat_tracking_id]
        ON [qc].[electrode_production_vat] ([electrode_production_tracking_id])
        INCLUDE ([vat_id], [prod_electrodes_sum], [prod_electrodes_shift]);

/* ---- Conductivity (vw_conductivity) --------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_conductivity_vat_log_log_id'
                 AND object_id = OBJECT_ID(N'[qc].[conductivity_vat_log]'))
    CREATE NONCLUSTERED INDEX [IX_conductivity_vat_log_log_id]
        ON [qc].[conductivity_vat_log] ([conductivity_log_id])
        INCLUDE ([vat_id], [conductivity]);

/* ---- Bath measurements (vw_cleaner/activator/strike/plate_bath_*) ---- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_cleaner_bath_measurement_log_id'
                 AND object_id = OBJECT_ID(N'[qc].[cleaner_bath_measurement]'))
    CREATE NONCLUSTERED INDEX [IX_cleaner_bath_measurement_log_id]
        ON [qc].[cleaner_bath_measurement] ([cleaner_bath_log_id])
        INCLUDE ([measurement_number], [measurement], [measurement_type]);

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_activator_bath_measurement_log_id'
                 AND object_id = OBJECT_ID(N'[qc].[activator_bath_measurement]'))
    CREATE NONCLUSTERED INDEX [IX_activator_bath_measurement_log_id]
        ON [qc].[activator_bath_measurement] ([activator_bath_log_id])
        INCLUDE ([measurement_number], [measurement], [measurement_type]);

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_strike_bath_measurement_log_id'
                 AND object_id = OBJECT_ID(N'[qc].[strike_bath_measurement]'))
    CREATE NONCLUSTERED INDEX [IX_strike_bath_measurement_log_id]
        ON [qc].[strike_bath_measurement] ([strike_bath_log_id])
        INCLUDE ([measurement_number], [measurement], [measurement_type]);

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_plate_bath_measurement_log_id'
                 AND object_id = OBJECT_ID(N'[qc].[plate_bath_measurement]'))
    CREATE NONCLUSTERED INDEX [IX_plate_bath_measurement_log_id]
        ON [qc].[plate_bath_measurement] ([plate_bath_log_id])
        INCLUDE ([measurement_number], [measurement], [measurement_type]);

/* ---- Plate log vat filter (vw_plate_bath_28/29/30 WHERE v.name) ----- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_plate_bath_log_vat_id'
                 AND object_id = OBJECT_ID(N'[qc].[plate_bath_log]'))
    CREATE NONCLUSTERED INDEX [IX_plate_bath_log_vat_id]
        ON [qc].[plate_bath_log] ([vat_id])
        INCLUDE ([date], [measured_by], [notes]);

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'012_add_view_indexes.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'012_add_view_indexes.sql');
