USE [DW_CC]
GO
/****** Object:  StoredProcedure [dbo].[GetCDCProcessingRange]    Script Date: 2023-04-21 22:12:31 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER PROCEDURE [dbo].[GetCDCProcessingRange] (@capture_instance sysname, @from_lsn binary(10) OUTPUT, @to_lsn binary(10) OUTPUT)
AS
BEGIN
	-- Validate that the capture_instance exists and raise an error if not
	IF NOT EXISTS (SELECT * FROM cdc.change_tables WHERE capture_instance = @capture_instance)
	BEGIN
		RAISERROR('The specified capture_instance is valid for the current cdc_configuration', 16, 1);
		RETURN;
	END

	-- Check if the capture instance exists in the tracking table and insert it if not
	IF NOT EXISTS (SELECT capture_instance FROM staging.cdc_lsn_tracking WHERE capture_instance = @capture_instance)
	BEGIN
		INSERT INTO staging.cdc_lsn_tracking (capture_instance) VALUES (@capture_instance);
	END

	-- Get the current min LSN for the capture instance
	SELECT	@from_lsn =  ISNULL(last_processed_lsn, sys.fn_cdc_get_min_lsn(@capture_instance)),
			-- Decrement the max lsn to limit our processing range
			@to_lsn =  sys.fn_cdc_decrement_lsn(sys.fn_cdc_get_max_lsn())
	FROM staging.cdc_lsn_tracking
	WHERE capture_instance = @capture_instance;



END
