/* =====================================================================
 * 004_create_qc_tables.sql  --  GENERATED FILE, DO NOT EDIT BY HAND
 * Produced by generate_mssql.py from the drawdb export:
 *     pH & Plating QC Schema_2026-06-23T07_43_57.863Z.sql
 * Re-run:  python generate_mssql.py
 * ===================================================================== */

/* Single batch on purpose: SSMS runs each GO-batch independently,
 * so a guard in its own batch would NOT stop later batches. With one
 * batch, the THROW below aborts everything. */
IF DB_NAME() NOT IN (N'dataloggingDev', N'dataloggingTest')
    THROW 50000, N'Refusing to run: not an allowed database.', 1;
IF OBJECT_ID(N'[qc].[schema_migrations]', N'U') IS NULL
    THROW 50000, N'Run 001 first (creates the qc schema + ledger).', 1;

/* ---- tables (idempotent; parents first for inline FKs) ---- */
IF OBJECT_ID(N'[qc].[vat]', N'U') IS NULL
CREATE TABLE [qc].[vat] (
	[id] INT IDENTITY PRIMARY KEY,
	[name] NVARCHAR(255) NOT NULL UNIQUE,
	[type] NVARCHAR(255) NOT NULL
);
IF OBJECT_ID(N'[qc].[chemical]', N'U') IS NULL
CREATE TABLE [qc].[chemical] (
	[id] INT IDENTITY PRIMARY KEY,
	[name] NVARCHAR(255) NOT NULL UNIQUE,
	[unit] NVARCHAR(255) NOT NULL
);
IF OBJECT_ID(N'[qc].[electrode_chemical_dosage]', N'U') IS NULL
CREATE TABLE [qc].[electrode_chemical_dosage] (
	[id] INT IDENTITY PRIMARY KEY,
	[date] DATETIME2 NOT NULL,
	[name] NVARCHAR(255) NOT NULL,
	[tu_value] INT NOT NULL,
	[ba_value] INT NOT NULL
);
IF OBJECT_ID(N'[qc].[chemical_addition_log]', N'U') IS NULL
CREATE TABLE [qc].[chemical_addition_log] (
	[id] INT IDENTITY PRIMARY KEY,
	[date] DATE NOT NULL,
	[time_when_added] TIME,
	[added_by] NVARCHAR(255),
	[notes] NVARCHAR(255)
);
IF OBJECT_ID(N'[qc].[chemical_addition_log_vat]', N'U') IS NULL
CREATE TABLE [qc].[chemical_addition_log_vat] (
	[id] INT IDENTITY PRIMARY KEY,
	[vat_id] INT NOT NULL REFERENCES [qc].[vat]([id]),
	[chemical_addition_log_id] INT NOT NULL REFERENCES [qc].[chemical_addition_log]([id]),
	[water_level_reduction] INT
);
IF OBJECT_ID(N'[qc].[chemical_addition]', N'U') IS NULL
CREATE TABLE [qc].[chemical_addition] (
	[id] INT IDENTITY PRIMARY KEY,
	[chemical_addition_log_vat_id] INT NOT NULL REFERENCES [qc].[chemical_addition_log_vat]([id]),
	[chemical_id] INT NOT NULL REFERENCES [qc].[chemical]([id]),
	[chemical_amount] DECIMAL(10,3) NOT NULL,
	[concentration] INT
);
IF OBJECT_ID(N'[qc].[electrode_production_tracking]', N'U') IS NULL
CREATE TABLE [qc].[electrode_production_tracking] (
	[id] INT IDENTITY PRIMARY KEY,
	[chemical_addition_log_id] INT REFERENCES [qc].[chemical_addition_log]([id]),
	[shift] NVARCHAR(255),
	[date] DATE,
	[tu_dose_g_per_electrode] DECIMAL(8,1),
	[ba_dose_g_per_electrode] DECIMAL(7,1)
);
IF OBJECT_ID(N'[qc].[electrode_production_vat]', N'U') IS NULL
CREATE TABLE [qc].[electrode_production_vat] (
	[id] INT IDENTITY PRIMARY KEY,
	[electrode_production_tracking_id] INT NOT NULL REFERENCES [qc].[electrode_production_tracking]([id]),
	[vat_id] INT NOT NULL REFERENCES [qc].[vat]([id]),
	[prod_electrodes_sum] INT NOT NULL,
	[prod_electrodes_shift] INT
);
IF OBJECT_ID(N'[qc].[ph_log]', N'U') IS NULL
CREATE TABLE [qc].[ph_log] (
	[id] INT IDENTITY PRIMARY KEY,
	[date] DATE NOT NULL,
	[sample_taken_time] TIME,
	[time_of_measurement] TIME,
	[measured_by] NVARCHAR(255),
	[notes] NVARCHAR(255)
);
IF OBJECT_ID(N'[qc].[ph_log_vat]', N'U') IS NULL
CREATE TABLE [qc].[ph_log_vat] (
	[id] INT IDENTITY PRIMARY KEY,
	[vat_id] INT NOT NULL REFERENCES [qc].[vat]([id]),
	[ph_log_id] INT NOT NULL REFERENCES [qc].[ph_log]([id]),
	[chemical_id] INT REFERENCES [qc].[chemical]([id]),
	[chemical_amount] DECIMAL(8,2),
	[chemical_addition_time] TIME
);
IF OBJECT_ID(N'[qc].[ph_measurement]', N'U') IS NULL
CREATE TABLE [qc].[ph_measurement] (
	[id] INT IDENTITY PRIMARY KEY,
	[ph_log_vat_id] INT NOT NULL REFERENCES [qc].[ph_log_vat]([id]),
	[measurement_number] INT NOT NULL,
	[ph_value] DECIMAL(7,2) NOT NULL
);
IF OBJECT_ID(N'[qc].[conductivity_log]', N'U') IS NULL
CREATE TABLE [qc].[conductivity_log] (
	[id] INT IDENTITY PRIMARY KEY,
	[date] DATE NOT NULL,
	[logged_by] NVARCHAR(255),
	[observation] NVARCHAR(255)
);
IF OBJECT_ID(N'[qc].[conductivity_vat_log]', N'U') IS NULL
CREATE TABLE [qc].[conductivity_vat_log] (
	[id] INT IDENTITY PRIMARY KEY,
	[conductivity_log_id] INT NOT NULL REFERENCES [qc].[conductivity_log]([id]),
	[vat_id] INT NOT NULL REFERENCES [qc].[vat]([id]),
	[rinse_number] INT NOT NULL,
	[conductivity] DECIMAL(11,1) NOT NULL
);
IF OBJECT_ID(N'[qc].[cleaner_bath_log]', N'U') IS NULL
CREATE TABLE [qc].[cleaner_bath_log] (
	[id] INT IDENTITY PRIMARY KEY,
	[date] DATE NOT NULL,
	[vat_id] INT NOT NULL REFERENCES [qc].[vat]([id]),
	[measured_by] NVARCHAR(255) NOT NULL,
	[notes] NVARCHAR(255)
);
IF OBJECT_ID(N'[qc].[cleaner_bath_measurement]', N'U') IS NULL
CREATE TABLE [qc].[cleaner_bath_measurement] (
	[id] INT IDENTITY PRIMARY KEY,
	[cleaner_bath_log_id] INT NOT NULL REFERENCES [qc].[cleaner_bath_log]([id]),
	[measurement_number] INT NOT NULL,
	[measurement] DECIMAL(8,2) NOT NULL,
	[measurement_type] NVARCHAR(255) NOT NULL
);
IF OBJECT_ID(N'[qc].[activator_bath_log]', N'U') IS NULL
CREATE TABLE [qc].[activator_bath_log] (
	[id] INT IDENTITY PRIMARY KEY,
	[date] DATE NOT NULL,
	[vat_id] INT NOT NULL REFERENCES [qc].[vat]([id]),
	[measured_by] NVARCHAR(255) NOT NULL,
	[notes] NVARCHAR(255)
);
IF OBJECT_ID(N'[qc].[activator_bath_measurement]', N'U') IS NULL
CREATE TABLE [qc].[activator_bath_measurement] (
	[id] INT IDENTITY PRIMARY KEY,
	[activator_bath_log_id] INT NOT NULL REFERENCES [qc].[activator_bath_log]([id]),
	[measurement_number] INT NOT NULL,
	[measurement] DECIMAL(8,2) NOT NULL,
	[measurement_type] NVARCHAR(255) NOT NULL
);
IF OBJECT_ID(N'[qc].[strike_bath_log]', N'U') IS NULL
CREATE TABLE [qc].[strike_bath_log] (
	[id] INT IDENTITY PRIMARY KEY,
	[date] DATE NOT NULL,
	[vat_id] INT NOT NULL REFERENCES [qc].[vat]([id]),
	[measured_by] NVARCHAR(255) NOT NULL,
	[notes] NVARCHAR(255)
);
IF OBJECT_ID(N'[qc].[strike_bath_measurement]', N'U') IS NULL
CREATE TABLE [qc].[strike_bath_measurement] (
	[id] INT IDENTITY PRIMARY KEY,
	[strike_bath_log_id] INT NOT NULL REFERENCES [qc].[strike_bath_log]([id]),
	[measurement_number] INT NOT NULL,
	[measurement] DECIMAL(8,2) NOT NULL,
	[measurement_type] NVARCHAR(255) NOT NULL
);
IF OBJECT_ID(N'[qc].[plate_bath_log]', N'U') IS NULL
CREATE TABLE [qc].[plate_bath_log] (
	[id] INT IDENTITY PRIMARY KEY,
	[date] DATE NOT NULL,
	[vat_id] INT NOT NULL REFERENCES [qc].[vat]([id]),
	[measured_by] NVARCHAR(255) NOT NULL,
	[notes] NVARCHAR(255)
);
IF OBJECT_ID(N'[qc].[plate_bath_measurement]', N'U') IS NULL
CREATE TABLE [qc].[plate_bath_measurement] (
	[id] INT IDENTITY PRIMARY KEY,
	[plate_bath_log_id] INT NOT NULL REFERENCES [qc].[plate_bath_log]([id]),
	[measurement_number] INT NOT NULL,
	[measurement] DECIMAL(8,2) NOT NULL,
	[measurement_type] NVARCHAR(255) NOT NULL
);

/* ---- self-record into the migration ledger ---- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations] WHERE filename = N'004_create_qc_tables.sql')
    INSERT INTO [qc].[schema_migrations] (filename) VALUES (N'004_create_qc_tables.sql');
GO
