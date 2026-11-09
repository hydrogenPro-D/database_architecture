CREATE TABLE [ph_log] (
	[id] INTEGER NOT NULL IDENTITY UNIQUE,
	[date] DATE NOT NULL,
	[sample_taken_time] TIME,
	[time_of_measurement] TIME,
	[measured_by] NVARCHAR(255),
	[notes] NVARCHAR(255),
	PRIMARY KEY([id])
);
GO

CREATE TABLE [ph_log_vat] (
	[id] INTEGER NOT NULL IDENTITY UNIQUE,
	[vat_id] INTEGER NOT NULL,
	[ph_log_id] INTEGER NOT NULL,
	[chemical_id] INTEGER,
	[chemical_amount] DECIMAL,
	[chemical_addition_time] TIME,
	PRIMARY KEY([id])
);
GO

CREATE TABLE [ph_measurement] (
	[id] INTEGER NOT NULL IDENTITY UNIQUE,
	[ph_log_vat_id] INTEGER NOT NULL,
	[measurement_number] INTEGER NOT NULL,
	[ph_value] DECIMAL NOT NULL,
	PRIMARY KEY([id])
);
GO

CREATE TABLE [vat] (
	[id] INTEGER NOT NULL IDENTITY UNIQUE,
	[name] NVARCHAR(255) NOT NULL UNIQUE,
	[type] NVARCHAR(255) NOT NULL,
	PRIMARY KEY([id])
);
GO

CREATE TABLE [chemical] (
	[id] INTEGER NOT NULL IDENTITY UNIQUE,
	[name] NVARCHAR(255) NOT NULL UNIQUE,
	[unit] NVARCHAR(255) NOT NULL,
	PRIMARY KEY([id])
);
GO

CREATE TABLE [chemical_addition_log] (
	[id] INTEGER NOT NULL IDENTITY UNIQUE,
	[date] DATE NOT NULL,
	[time_when_added] TIME,
	[added_by] NVARCHAR(255),
	[notes] NVARCHAR(255),
	PRIMARY KEY([id])
);
GO

CREATE TABLE [chemical_addition_log_vat] (
	[id] INTEGER NOT NULL IDENTITY UNIQUE,
	[vat_id] INTEGER NOT NULL,
	[chemical_addition_log_id] INTEGER NOT NULL,
	[water_level_reduction] INTEGER,
	PRIMARY KEY([id])
);
GO

CREATE TABLE [chemical_addition] (
	[id] INTEGER NOT NULL IDENTITY UNIQUE,
	[chemical_addition_log_vat_id] INTEGER NOT NULL,
	[chemical_id] INTEGER NOT NULL,
	[chemical_amount] DECIMAL NOT NULL,
	[concentration] DECIMAL,
	PRIMARY KEY([id])
);
GO

CREATE TABLE [electrode_production_tracking] (
	[id] INTEGER NOT NULL IDENTITY UNIQUE,
	[chemical_addition_log_id] INTEGER NOT NULL,
	[shift] NVARCHAR(255),
	[date] DATE,
	[tu_dose_g_per_electrode] INTEGER,
	[ba_dose_g_per_electrode] INTEGER,
	PRIMARY KEY([id])
);
GO

CREATE TABLE [electrode_production_vat] (
	[id] INTEGER NOT NULL IDENTITY UNIQUE,
	[electrode_production_tracking_id] INTEGER NOT NULL,
	[vat_id] INTEGER NOT NULL,
	[prod_electrodes_sum] INTEGER NOT NULL,
	[prod_electrodes_shift] INTEGER,
	PRIMARY KEY([id])
);
GO

CREATE TABLE [electrode_chemical_dosage] (
	[id] INTEGER NOT NULL IDENTITY UNIQUE,
	[date] DATETIME NOT NULL,
	[name] NVARCHAR(255) NOT NULL,
	[tu_value] INTEGER NOT NULL,
	[ba_value] INTEGER NOT NULL,
	PRIMARY KEY([id])
);
GO

CREATE TABLE [conductivity_log] (
	[id] INTEGER NOT NULL IDENTITY UNIQUE,
	[date] DATE NOT NULL,
	[logged_by] NVARCHAR(255),
	[observation] NVARCHAR(255),
	PRIMARY KEY([id])
);
GO

CREATE TABLE [conductivity_vat_log] (
	[id] INTEGER NOT NULL IDENTITY UNIQUE,
	[conductivity_log_id] INTEGER NOT NULL,
	[vat_id] INTEGER NOT NULL,
	[rinse_number] INTEGER NOT NULL,
	[conductivity] DECIMAL NOT NULL,
	PRIMARY KEY([id])
);
GO

CREATE TABLE [cleaner_bath_log] (
	[id] INTEGER NOT NULL IDENTITY UNIQUE,
	[date] DATE NOT NULL,
	[vat_id] INTEGER NOT NULL,
	[measured_by] NVARCHAR(255) NOT NULL,
	[notes] NVARCHAR(255),
	PRIMARY KEY([id])
);
GO

CREATE TABLE [cleaner_bath_measurement] (
	[id] INTEGER NOT NULL IDENTITY UNIQUE,
	[cleaner_bath_log_id] INTEGER NOT NULL,
	[measurement_number] INTEGER NOT NULL,
	[measurement] DECIMAL NOT NULL,
	[measurement_type] NVARCHAR(255) NOT NULL,
	PRIMARY KEY([id])
);
GO

CREATE TABLE [activator_bath_log] (
	[id] INTEGER NOT NULL IDENTITY UNIQUE,
	[date] DATE NOT NULL,
	[vat_id] INTEGER NOT NULL,
	[measured_by] NVARCHAR(255) NOT NULL,
	[notes] NVARCHAR(255),
	PRIMARY KEY([id])
);
GO

CREATE TABLE [activator_bath_measurement] (
	[id] INTEGER NOT NULL IDENTITY UNIQUE,
	[activator_bath_log_id] INTEGER NOT NULL,
	[measurement_number] INTEGER NOT NULL,
	[measurement] DECIMAL NOT NULL,
	[measurement_type] NVARCHAR(255) NOT NULL,
	PRIMARY KEY([id])
);
GO

CREATE TABLE [strike_bath_log] (
	[id] INTEGER NOT NULL IDENTITY UNIQUE,
	[date] DATE NOT NULL,
	[vat_id] INTEGER NOT NULL,
	[measured_by] NVARCHAR(255) NOT NULL,
	[notes] NVARCHAR(255),
	PRIMARY KEY([id])
);
GO

CREATE TABLE [strike_bath_measurement] (
	[id] INTEGER NOT NULL IDENTITY UNIQUE,
	[strike_bath_log_id] INTEGER NOT NULL,
	[measurement_number] INTEGER NOT NULL,
	[measurement] DECIMAL NOT NULL,
	[measurement_type] NVARCHAR(255) NOT NULL,
	PRIMARY KEY([id])
);
GO

CREATE TABLE [plate_bath_log] (
	[id] INTEGER NOT NULL IDENTITY UNIQUE,
	[date] DATE NOT NULL,
	[vat_id] INTEGER NOT NULL,
	[measured_by] NVARCHAR(255) NOT NULL,
	[notes] NVARCHAR(255),
	PRIMARY KEY([id])
);
GO

CREATE TABLE [plate_bath_measurement] (
	[id] INTEGER NOT NULL IDENTITY UNIQUE,
	[plate_bath_log_id] INTEGER NOT NULL,
	[measurement_number] INTEGER NOT NULL,
	[measurement] DECIMAL NOT NULL,
	[measurement_type] NVARCHAR(255) NOT NULL,
	PRIMARY KEY([id])
);
GO


ALTER TABLE [ph_log_vat]
ADD FOREIGN KEY([ph_log_id])
REFERENCES [ph_log]([id])
ON UPDATE NO ACTION ON DELETE NO ACTION;
GO
ALTER TABLE [ph_measurement]
ADD FOREIGN KEY([ph_log_vat_id])
REFERENCES [ph_log_vat]([id])
ON UPDATE NO ACTION ON DELETE NO ACTION;
GO
ALTER TABLE [ph_log_vat]
ADD FOREIGN KEY([vat_id])
REFERENCES [vat]([id])
ON UPDATE NO ACTION ON DELETE NO ACTION;
GO
ALTER TABLE [ph_log_vat]
ADD FOREIGN KEY([chemical_id])
REFERENCES [chemical]([id])
ON UPDATE NO ACTION ON DELETE NO ACTION;
GO
ALTER TABLE [chemical_addition_log_vat]
ADD FOREIGN KEY([vat_id])
REFERENCES [vat]([id])
ON UPDATE NO ACTION ON DELETE NO ACTION;
GO
ALTER TABLE [chemical_addition_log_vat]
ADD FOREIGN KEY([chemical_addition_log_id])
REFERENCES [chemical_addition_log]([id])
ON UPDATE NO ACTION ON DELETE NO ACTION;
GO
ALTER TABLE [chemical_addition]
ADD FOREIGN KEY([chemical_addition_log_vat_id])
REFERENCES [chemical_addition_log_vat]([id])
ON UPDATE NO ACTION ON DELETE NO ACTION;
GO
ALTER TABLE [chemical_addition]
ADD FOREIGN KEY([chemical_id])
REFERENCES [chemical]([id])
ON UPDATE NO ACTION ON DELETE NO ACTION;
GO
ALTER TABLE [electrode_production_vat]
ADD FOREIGN KEY([electrode_production_tracking_id])
REFERENCES [electrode_production_tracking]([id])
ON UPDATE NO ACTION ON DELETE NO ACTION;
GO
ALTER TABLE [electrode_production_vat]
ADD FOREIGN KEY([vat_id])
REFERENCES [vat]([id])
ON UPDATE NO ACTION ON DELETE NO ACTION;
GO
ALTER TABLE [electrode_production_tracking]
ADD FOREIGN KEY([chemical_addition_log_id])
REFERENCES [chemical_addition_log]([id])
ON UPDATE NO ACTION ON DELETE NO ACTION;
GO
ALTER TABLE [conductivity_vat_log]
ADD FOREIGN KEY([vat_id])
REFERENCES [vat]([id])
ON UPDATE NO ACTION ON DELETE NO ACTION;
GO
ALTER TABLE [conductivity_vat_log]
ADD FOREIGN KEY([conductivity_log_id])
REFERENCES [conductivity_log]([id])
ON UPDATE NO ACTION ON DELETE NO ACTION;
GO
ALTER TABLE [cleaner_bath_measurement]
ADD FOREIGN KEY([cleaner_bath_log_id])
REFERENCES [cleaner_bath_log]([id])
ON UPDATE NO ACTION ON DELETE NO ACTION;
GO
ALTER TABLE [activator_bath_measurement]
ADD FOREIGN KEY([activator_bath_log_id])
REFERENCES [activator_bath_log]([id])
ON UPDATE NO ACTION ON DELETE NO ACTION;
GO
ALTER TABLE [strike_bath_measurement]
ADD FOREIGN KEY([strike_bath_log_id])
REFERENCES [strike_bath_log]([id])
ON UPDATE NO ACTION ON DELETE NO ACTION;
GO
ALTER TABLE [plate_bath_log]
ADD FOREIGN KEY([vat_id])
REFERENCES [vat]([id])
ON UPDATE NO ACTION ON DELETE NO ACTION;
GO
ALTER TABLE [strike_bath_log]
ADD FOREIGN KEY([vat_id])
REFERENCES [vat]([id])
ON UPDATE NO ACTION ON DELETE NO ACTION;
GO
ALTER TABLE [activator_bath_log]
ADD FOREIGN KEY([vat_id])
REFERENCES [vat]([id])
ON UPDATE NO ACTION ON DELETE NO ACTION;
GO
ALTER TABLE [cleaner_bath_log]
ADD FOREIGN KEY([vat_id])
REFERENCES [vat]([id])
ON UPDATE NO ACTION ON DELETE NO ACTION;
GO
ALTER TABLE [plate_bath_measurement]
ADD FOREIGN KEY([plate_bath_log_id])
REFERENCES [plate_bath_log]([id])
ON UPDATE NO ACTION ON DELETE NO ACTION;
GO