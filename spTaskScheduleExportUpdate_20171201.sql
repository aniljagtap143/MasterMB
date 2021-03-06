USE [MBBidSheet]
GO
/****** Object:  StoredProcedure [dbo].[spTaskScheduleExport]    Script Date: 12/1/2017 8:04:30 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER procedure [dbo].[spTaskScheduleExport]
(
    @JobNumber      varchar(10), --115238
	@TaskSchedule	 udtTaskScheduleExport readonly,
	@UserName		 varchar(200),  --MISSIONBELL\JENISEM
	@WODescription varchar(100)	
)
as
begin
	set nocount on;
    begin try
        begin transaction transTaskScheduleExport

		truncate table TaskExportScheduleDetails_Testing

		DECLARE @bTaskExists as bit
		DECLARE @lTaskNumber as Int
		DECLARE @position as Int
		DECLARE @lJobNumber as int
		DECLARE @JobCount as Int
		DECLARE @lLatestTask as Int
		DECLARE @lEmployeeCode int
		DECLARE @tblJobDeptWO_sysId int
		DECLARE @body_email varchar(1000)

		--declarations for cursor
		DECLARE @lJobDeptWOCode as Int
		DECLARE @datDateIssued as DateTime
		DECLARE @datDateProjected as DateTime
		DECLARE @sWorkOrderHoursBudget as real
		DECLARE @UsernameNew as varchar(30)
		--SET @UserName = 'missionbell\jenisem'
		--added by JM on 9/2/2016 for BSA Sprint 18 req
		--DECLARE @WOSource as varchar(4)
		--SET @WOSource = 'BSA'

		--updated by JM on 6/25/16 - moved this to the top of the procedure
		--Re-assign Username and retrieve MB Database EmployeeCode
		SET @position = CHARINDEX('\', @Username)
		--updated by JM on 12/1/17 - needed to increase length of username
		SET @UserName = RTRIM(SUBSTRING(@Username, (@position +1), 20))
		SET @UsernameNew = @UserName
		SET @lEmployeeCode = (SELECT txtCode
			FROM MBData2005.dbo.tblUserId
			WHERE (txtUser = @UserName)
			GROUP BY txtCode)

		--Get count for # of records in tblJob to ensure no duplicates have been created 
		SET @JobCount = (SELECT Count(*) FROM MBData2005.dbo.tblJob WHERE txtJobNumber = @JobNumber)

		--In Rare case there is more then 1 record with the jobnumber then import into an error handeling table and then email Admin.
		IF @JobCount = 1
		BEGIN
			SET @lTaskNumber = (SELECT TaskNo FROM @TaskSchedule GROUP BY TaskNo)

			--Retrieve Jobnumber based upon Job# passed from Bid Sheet App 
			SET @lJobNumber = (SELECT lJobNumber FROM MBData2005.dbo.tblJob WHERE txtJobNumber = @JobNumber)

			IF @lTaskNumber = 99 -- or if task# already exisits for that job - updated by JM on 5/31/2016
			BEGIN
				SET @lLatestTask = (SELECT MAX(lTaskNumber) FROM MBData2005.dbo.tblJobDeptWO WHERE lJobNumber = @lJobNumber)
			END			

			--check if the task already exisits.  If Tasks Does Not Exist, import as a new task
			--if task exists, delete existing task and re-import.
			SET @bTaskExists = (SELECT COUNT(*) FROM MBData2005.dbo.tblJobDeptWO INNER JOIN MBData2005.dbo.tblJob ON tblJobDeptWO.lJobNumber = tblJob.lJobNumber 
				WHERE txtJobNumber = @JobNumber AND lTaskNumber = @lTaskNumber)

			--Insert as New with Hold Status
			If @bTaskExists IS NULL OR @bTaskExists = 0
			BEGIN
				--updated by JM on 10/10/16 by adding wOSource column during insert
				--Insert data into tblJobDeptwo table
				INSERT INTO MBData2005.dbo.tblJobDeptWO (lJobNumber, txtDepartmentCode, txtDeptWOStatusCode, lTaskNumber, lWorkOrderNumber
					, txtWorkOrderDescription, sWorkOrderHoursBudget, datDateProjected, datDateIssued, datDateCreated, lFacilityCode, bApproved, WOStatus
					, FirstWODescription, Heads_BidApp, WOSource)
				SELECT @lJobNumber, DepartmentCode, 'H', @lTaskNumber, dl.lWONumber, @WODescription
					, JobWOHours, EndDate, StartDate, GetDate(), 1, 1, 0, @WODescription, Heads, 'BSA'
				FROM @TaskSchedule TS
					LEFT OUTER JOIN MBData2005.dbo.tblDepartmentList dl ON TS.DepartmentCode =dl.txtDepartmentCode
				--updated by JM on 5/31/16 - only import non 0 lines
				WHERE TS.JobWOHours > 0

				UPDATE MBData2005.dbo.tblJobDeptWO SET lJobDeptWOCode = sysid WHERE lJobDeptWOCode = 0
        
				--updated by JM on 11/17/16 - should be checking for current task # imported and not task 1
				--Import Into tblJobDeptTask table for Kronos
				IF NOT EXISTS (SELECT Count(*) tblJobDeptTask FROM MBData2005.dbo.tblJobDeptTask WHERE lJobNumber = @lJobNumber AND lTaskNumber = @lTaskNumber)
				BEGIN
					INSERT INTO MBData2005.dbo.tblJobDeptTask (lJobNumber, lTaskNumber, TaskStatus, datTaskCreatedDate) VALUES (@lJobNumber, @lTaskNumber, 1, GETDate())		
				END
				ELSE
				BEGIN
					UPDATE MBData2005.dbo.tblJobDeptTask SET TaskStatus = 1, datTaskStatusUpdatedDate = GETDATE() WHERE lJobNumber = @lJobNumber AND lTaskNumber = @lTaskNumber
				END

				--Update Job Status in tblJob for new Task
				UPDATE MBData2005.dbo.tblJob SET JobStatus = 1, datStatusUpdatedDate = GETDATE() WHERE lJobNumber = @lJobNumber
               
	             --insert new record into tblaudit
				INSERT INTO MBData2005.dbo.tblWOAudit (lEmployeeCode, tblJobDeptWO_sysId, txtAction, datDateTimeStamp, sBeforeHours, sAfterHours, datBeforeIssuedDate
					, datAfterIssuedDate, datBeforeProjectedDate, datAfterProjectedDate, txtBeforeWOStatus, txtAfterWOStatus, sBeforeFacility, sAfterFacility)
				SELECT  @lEmployeeCode, sysid, 'N', GETDATE(), 0, sWorkOrderHoursBudget, datDateIssued, datDateIssued, datDateProjected, datDateProjected, '', 'H', 0, 0
				FROM MBData2005.dbo.tblJobDeptWO 
				WHERE lJobNumber = @lJobNumber AND lTaskNumber = @lTaskNumber                  
				--EXEC s_WO_AddWOAudit @lEmployeeCode, @tblJobDeptWO_sysId, 'N', 0, @sWorkOrderHoursBudget,'', @datDateIssued, '', @datDateProjected, '', 'H'                
				
				--If @bApproved = 1 - All WO's imported from bid sheet need to be reivewed and approved

				--updated by JM on 10/7/16 - added additional fetch after statement is executed. and then removed
				BEGIN
					-- insert into queued if the WO has not been approved
					--loop through new set of records so entire queue and setting of workweek process does not have to be redone
					--BEGIN TRANSACTION
					DECLARE WOCheck cursor local fast_forward for
						
					SELECT lJobDeptWOCode, datDateIssued, datDateProjected, sWorkOrderHoursBudget
					FROM MBData2005.dbo.tblJobDeptWO
					WHERE lJobNumber = @lJobNumber AND lTaskNumber = @lTaskNumber

					open WOCheck
					while 1=1
					BEGIN
						fetch next from WOCheck into @lJobDeptWOCode, @datDateIssued, @datDateProjected, @sWorkOrderHoursBudget

						if @@FETCH_STATUS <> 0
						begin
							break
						end

						EXEC MBData2005.dbo.s_WOQ_CheckWOBeforeMove @lJobDeptWOCode, @UsernameNew, @datDateIssued, @datDateProjected, @sWorkOrderHoursBudget, 'New WO', 0
						--fetch next from WOCheck into @lJobDeptWOCode, @datDateIssued, @datDateProjected, @sWorkOrderHoursBudget
					END
					close WOCheck
					deallocate WOCheck

					--ROLLBACK TRANSACTION
				END	
			END
			ELSE
			BEGIN
				--Task exists 
				--Delete records from tblWOAudit
				DELETE tblWOAudit FROM MBData2005.dbo.tblWOAudit INNER JOIN MBData2005.dbo.tblJobDeptWO ON tblWOAudit.tblJobDeptWO_sysId = tblJobDeptWO.lJobDeptWOCode
				WHERE tblJobDeptWO.lJobNumber = @lJobNumber AND tblJobDeptWO.lTaskNumber = @lTaskNumber

				--delete existing task number
				DELETE FROM MBData2005.dbo.tblJobDeptWO WHERE lJobNumber = @lJobNumber AND lTaskNumber = @lTaskNumber

				--updated by JM on 10/10/16 by adding wOSource column during insert
				--import new data
				INSERT INTO MBData2005.dbo.tblJobDeptWO (lJobNumber, txtDepartmentCode, txtDeptWOStatusCode, lTaskNumber, lWorkOrderNumber
					, txtWorkOrderDescription, sWorkOrderHoursBudget, datDateProjected, datDateIssued, datDateCreated, lFacilityCode, bApproved, WOStatus
					, FirstWODescription, Heads_BidApp, WOSource)
				SELECT @lJobNumber, DepartmentCode, 'H', @lTaskNumber, dl.lWONumber, @WODescription
					, JobWOHours, EndDate, StartDate, GetDate(), 1, 1, 0, @WODescription, Heads, 'BSA'
				FROM @TaskSchedule TS
					LEFT OUTER JOIN MBData2005.dbo.tblDepartmentList dl ON TS.DepartmentCode =dl.txtDepartmentCode
				--updated by JM on 5/31/16 - only import non 0 lines
				WHERE TS.JobWOHours > 0

				UPDATE MBData2005.dbo.tblJobDeptWO SET lJobDeptWOCode = sysid WHERE lJobDeptWOCode = 0

				--update kronos fields/table
				UPDATE MBData2005.dbo.tblJobDeptTask 
				SET TaskStatus = 1
					, datTaskCreatedDate = GETDate()
				WHERE lJobNumber = @lJobNumber AND lTaskNumber = @lTaskNumber		
				
				--update Job Status for Kronos
				UPDATE MBData2005.dbo.tblJob 
				SET JobStatus = 1
					, datStatusUpdatedDate = GETDATE() 
				WHERE lJobNumber = @lJobNumber

				--update audit trail
				INSERT INTO MBData2005.dbo.tblWOAudit (lEmployeeCode, tblJobDeptWO_sysId, txtAction, datDateTimeStamp, sBeforeHours, sAfterHours, datBeforeIssuedDate
					, datAfterIssuedDate, datBeforeProjectedDate, datAfterProjectedDate, txtBeforeWOStatus, txtAfterWOStatus, sBeforeFacility, sAfterFacility)
				SELECT  @lEmployeeCode, sysid, 'N', GETDATE(), 0, sWorkOrderHoursBudget, datDateIssued, datDateIssued, datDateProjected, datDateProjected, '', 'H', 0, 0
				FROM MBData2005.dbo.tblJobDeptWO 
				WHERE lJobNumber = @lJobNumber AND lTaskNumber = @lTaskNumber

				--If @bApproved = 1 - All WO's imported from bid sheet need to be reivewed and approved

				--updated by JM on 10/7/16 - added additional fetch after statement is executed. and then removed
				BEGIN
				--BEGIN TRANSACTION
					-- insert into queued if the WO has not been approved
					--loop through new set of records so entire queue and setting of workweek process does not have to be redone
					DECLARE WOCheck cursor local fast_forward for

					SELECT lJobDeptWOCode, datDateIssued, datDateProjected, sWorkOrderHoursBudget
					FROM MBData2005.dbo.tblJobDeptWO
					WHERE lJobNumber = @lJobNumber AND lTaskNumber = @lTaskNumber

					open WOCheck
					while 1=1
					BEGIN
						fetch next from WOCheck into @lJobDeptWOCode, @datDateIssued, @datDateProjected, @sWorkOrderHoursBudget

						if @@FETCH_STATUS <> 0
						begin
							break
						end

						EXEC MBData2005.dbo.s_WOQ_CheckWOBeforeMove @lJobDeptWOCode, @usernameNew, @datDateIssued, @datDateProjected, @sWorkOrderHoursBudget, 'New WO', 0
						--fetch next from WOCheck into @lJobDeptWOCode, @datDateIssued, @datDateProjected, @sWorkOrderHoursBudget
					END
					close WOCheck
					deallocate WOCheck
					--ROLLBACK TRANSACTION
				END	
			END
		END
		ELSE
		BEGIN
			--insert into error table
			INSERT INTO tblTaskImportErrors (DeptCode, WODescription, TaskNo, Heads, StartDate, EndDate, JobWOHours, Username) 
			SELECT DepartmentCode, @WODescription, TaskNo, Heads, StartDate, EndDate, JobWOHours, @Username FROM @TaskSchedule

			--send email to PC/PM and support to inform them error happened with importing schedule
			--added by Jm on 6/2/2016
			SET @body_email = 'Pleae check tblTaskImportErrors table. ' + @username + ' attempted to export a bid schedule and an error occurred.';

			EXEC msdb.dbo.sp_send_dbmail
				@recipients='jenisem@missionbell.com',
				@subject = 'Error during Task Export',
				@body = @body_email,
				@body_format = 'HTML';
		END
        
        commit transaction transTaskScheduleExport
	end try
	begin catch
		rollback transaction transTaskScheduleExport
		-- re-throw the original SQL Server error
		exec spRethrowError
	end catch
end
