USE DBA_Data
GO

ALTER PROC DeploymentFileMoves
AS
BEGIN

/***********************************************************************************************************************************************

-- Author: William Bratz
--
-- Create Date: 10-03-2017
--
-- Description: Moves files out of the deployment folder dependant on deployment results. 
--		      This is called by a master proc and is part of the auto deployment proces
--
-- Original Requester/Owner: 
--
-- Changelog: 

***********************************************************************************************************************************************/

    DECLARE  @sourcePath VARCHAR(1000) = (SELECT SourcePath FROM secure.DeploymentValues WHERE ID = (SELECT MAX(ID) FROM secure.deploymentValues))
		  , @approvedPath VARCHAR(1000) = (SELECT ApprovedPath FROM secure.DeploymentValues WHERE ID = (SELECT MAX(ID) FROM secure.deploymentValues))
		  , @failedPath VARCHAR(1000) = (SELECT FailedPath FROM secure.DeploymentValues WHERE ID = (SELECT MAX(ID) FROM secure.deploymentValues))
		  , @move VARCHAR(8000)
		  , @scriptName VARCHAR(512)
		  , @scriptResult VARCHAR(50)
		  , @rolledBack BIT
            , @id INT

    DECLARE @LatestDeployments TABLE (ScriptName VARCHAR(512), Result VARCHAR(30), RolledBack BIT, ID INT)

--=====================================================================
-- Find most recent deployment
--=====================================================================

    ;WITH CTE AS (SELECT MAX(RunTime) LastRun FROM dbo.DeploymentResults)

    INSERT INTO @LatestDeployments (ScriptName
						    , Result
						    , RolledBack
						    , ID)
    SELECT IIF(dr.RollbackScriptName IS NULL, dr.SqlFileName, dr.RollbackScriptName) -- hard to explain, but ensures rollback script is removed 
		 , dr.ResultOutput
		 , dr.RolledBack
		 , dr.ID
    FROM dbo.DeploymentResults dr
    WHERE EXISTS (SELECT 1 FROM CTE WHERE LastRun = dr.Runtime)

--=====================================================================
-- Loop through results list and move the files according to result
--=====================================================================

    WHILE (SELECT COUNT(*) FROM @LatestDeployments) > 0
    BEGIN
    
	   SELECT TOP 1
			  @scriptName = ScriptName
			, @scriptResult = Result
			, @rolledBack = RolledBack
			, @id = ID
	   FROM @LatestDeployments

	   DELETE FROM @LatestDeployments
	   WHERE ScriptName = @scriptName
		    AND Result = @scriptResult
		    AND RolledBack = @rolledBack
		    AND ID = @id

--===================================================================================
-- If the deployment was successful and not rolled back move to successful folder
--===================================================================================
	   IF (@scriptResult IN ('SUCCEEDED')) AND (@rolledBack = 0) 
	   BEGIN

		  SET @move = 'MOVE "' +@sourcePath+ '\'+@scriptName+'" ' + '"'+@approvedPath+'"'
		  EXEC master.dbo.xp_cmdshell @move , no_output

	   END

--=====================================================================
-- Everything else goes into the failed folder
--=====================================================================

	   ELSE
	   BEGIN

		  SET @move = 'MOVE "' +@sourcePath+ '\'+@scriptName+'" ' + '"'+@failedPath+'"'
		  EXEC master.dbo.xp_cmdshell @move , no_output

	   END

    END

END
