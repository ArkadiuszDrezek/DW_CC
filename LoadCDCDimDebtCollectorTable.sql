USE [DW_CC]
GO
/****** Object:  StoredProcedure [dbo].[LoadCDCDimDebtCollectorTable]    Script Date: 2023-04-21 22:55:51 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


ALTER procedure [dbo].[LoadCDCDimDebtCollectorTable]
as

--Insert/Update data into staging table
insert into [staging].[DimDebtCollector]
([us_id], [Name], [Surname], [DateFrom])
select top 1 with ties
DebtCollector_US_ID as us_id, 
DebtCollector_Name as [Name], DebtCollector_Surname as [Surname], 
DebtCollector_DateFrom as [DateFrom] 

from staging.TempData
where not exists (
select 1 from [staging].[DimDebtCollector]
where [staging].[DimDebtCollector].us_id = staging.TempData.DebtCollector_US_ID
)
order by row_number() over (partition by DebtCollector_US_ID order by DebtCollector_DateFrom desc)

update [staging].[DimDebtCollector]
set 
[Name] = DebtCollector_Name,
[Surname] = DebtCollector_Surname
from [staging].[DimDebtCollector]
join staging.TempData on [staging].[DimDebtCollector].us_id=staging.TempData.DebtCollector_US_ID
where DebtCollector_Name <> [Name] or DebtCollector_Surname <> Surname

--Wait for CDC to capture data
WAITFOR DELAY '00:00:10'

--Get all changes for the capture instance from last ETL process
DECLARE @capture_instance sysname = 'staging_DimDebtCollector';

DECLARE	@from_lsn binary(10) = isnull((select last_processed_lsn from staging.cdc_lsn_tracking),sys.fn_cdc_get_min_lsn(@capture_instance)),
		@to_lsn binary(10) = sys.fn_cdc_get_max_lsn();

DECLARE @us_id_ordinal INT = sys.fn_cdc_get_column_ordinal(@capture_instance, 'us_id'),
		@name_no_ordinal INT = sys.fn_cdc_get_column_ordinal(@capture_instance, 'name'),
		@surname_no_ordinal INT = sys.fn_cdc_get_column_ordinal(@capture_instance, 'surname'),
		@datefrom_no_ordinal INT = sys.fn_cdc_get_column_ordinal(@capture_instance, 'datefrom')

drop table if exists #PrepareCDCData
SELECT 
	[__$start_lsn],
	[__$seqval],
	[__$operation],
	CASE [__$operation] 
		WHEN 1 THEN 'Delete'
		WHEN 2 THEN 'INSERT'
		WHEN 3 THEN 'Update From Value'
		WHEN 4 THEN 'Update To Value'
	END AS [operation],
	[__$update_mask],
	us_id,
	name,
	surname,
	datefrom,
	sys.fn_cdc_is_bit_set ( @us_id_ordinal, [__$update_mask] ) AS us_id_changed,
	sys.fn_cdc_is_bit_set ( @name_no_ordinal, [__$update_mask] ) AS name_changed,
	sys.fn_cdc_is_bit_set ( @surname_no_ordinal, [__$update_mask] ) AS surname_changed,
	sys.fn_cdc_is_bit_set ( @datefrom_no_ordinal, [__$update_mask] ) AS datefrom_changed

	into #PrepareCDCData

FROM cdc.fn_cdc_get_all_changes_staging_DimDebtCollector (@from_lsn, @to_lsn, N'all')
where [__$operation] in (2,4)

--INSERT
--Insert rows for new DebtCollectors
insert into DW_CC.core.DimDebtCollector
([us_id], [Name], [Surname], [DateFrom], [DateTo])
select [us_id], [Name], [Surname], GETDATE(), null from #PrepareCDCData
where [__$operation] = 2 and not exists (
select 1 from DW_CC.core.DimDebtCollector where #PrepareCDCData.us_id=DW_CC.core.DimDebtCollector.us_id
)

--UPDATE
--Set end date for expired records
update DW_CC.core.DimDebtCollector
set DateTo = GETDATE()
from DW_CC.core.DimDebtCollector
join #PrepareCDCData on DW_CC.core.DimDebtCollector.us_id=#PrepareCDCData.us_id
where DateTo is null and #PrepareCDCData.[__$operation] = 4
and (DW_CC.core.DimDebtCollector.Name <> #PrepareCDCData.Name or DW_CC.core.DimDebtCollector.Surname <> #PrepareCDCData.Surname)

--Insert records with new values
insert into DW_CC.core.DimDebtCollector
([us_id], [Name], [Surname], [DateFrom], [DateTo])
select [us_id], [Name], [Surname], GETDATE(), null from #PrepareCDCData
where #PrepareCDCData.[__$operation] = 4 and not exists (
select 1 from DW_CC.core.DimDebtCollector
where DW_CC.core.DimDebtCollector.Name = #PrepareCDCData.Name and DW_CC.core.DimDebtCollector.Surname = #PrepareCDCData.Surname and DW_CC.core.DimDebtCollector.DateTo is null
)

--Update last_processed_lsn
EXECUTE dbo.GetCDCProcessingRange @capture_instance = N'staging_DimDebtCollector', @from_lsn = @from_lsn OUTPUT, @to_lsn = @to_lsn OUTPUT;

UPDATE staging.cdc_lsn_tracking
SET last_processed_lsn = @to_lsn
WHERE capture_instance = N'staging_DimDebtCollector';
