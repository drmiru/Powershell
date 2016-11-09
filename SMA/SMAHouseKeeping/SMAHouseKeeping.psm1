$SQLServerName="smadb"
$SQLDBName="sma"

Function Invoke-SQLCommand 
{

    param( 
       $Server,  
       $Database,  
       $Query,
       $UserName, 
       $Password
       )
 
    #If TSQL inputfile specified, use this as query string
    if ($Query -like "*.sql") 
    {
 	    $Query = Get-Content $Query
    }

 
    #If user name and password have been declared, use SQL authentication, otherwise use integrated SSPI
    if(($UserName) -and ($Password)) {
        $login = "User Id = $UserName; Password = $Password"
    } else {
        $login = "Integrated Security = True"
    }

    # Setup SQL Connection
    $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
    $SqlConnection.ConnectionString = "Server = $Server; Database = $database; $login"

    # Setup SQL Command
    $SqlCmd = New-Object System.Data.SqlClient.SqlCommand
    $SqlCmd.CommandText = $SqlQuery
    $SqlCmd.Connection = $SqlConnection

    $SqlCmd = New-Object System.Data.SqlClient.SqlCommand $Query, $SqlConnection

    #Perform the TSQL statement
    $SqlAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
    $SqlAdapter.SelectCommand = $SqlCmd
 
    $DataSet = New-Object System.Data.DataSet
    $SqlAdapter.Fill($DataSet) | Out-Null
    
    return $DataSet.Tables[0]
		
    #close the sql connection
    $SqlConnection.Close()		
}


Function Get-SMAJobAssignment
{
    param(
    [Parameter(mandatory=$true)]
    [ValidateSet("queued", "starting", "running", "completed", "stopped", "failed", "suspended", "stopping", "resuming")]
    [string]$JobState,

    [Parameter(mandatory=$false)]
    [string]$RunbookName
    )
    
    Switch ($JobState)
    {
        "queued"     {$JobStateID =  1}
        "starting"   {$JobStateID =  2}
        "running"    {$JobStateID =  3}
        "completed"  {$JobStateID =  4}
        "failed"     {$JobStateID =  5}
        "stopped"    {$JobStateID =  6}
        "suspended"  {$JobStateID =  8}
        "stopping"   {$JobStateID = 11}
        "resuming"   {$JobStateID = 11}
    }
    
    $JobAssignments = @()
    $WorkerQueues = Invoke-SQLCommand -Server $SQLServerName -Database $SQLDBName -Query "SELECT * FROM queues.deployment"
$jobcmd = @"
SELECT  Core.vwJobs.JobId, Core.vwJobs.JobStatusId, Core.vwJobs.JobStatus, Core.vwJobs.PartitionId, Core.vwJobs.CreationTime, Core.vwJobs.LastModifiedTime, 
        Core.vwRunbooks.RunbookName, 
        Core.vwRunbooks.RunbookId, Core.vwJobs.ErrorCount, Core.vwJobs.StartTime, Core.vwJobs.EndTime, Core.vwJobs.IsDraft
FROM    Core.Jobs LEFT OUTER JOIN
        Core.vwJobs ON Core.vwJobs.JobId = Core.Jobs.JobId LEFT OUTER JOIN
        Core.vwRunbooks ON Core.vwJobs.RunbookVersionId = Core.vwRunbooks.PublishedRunbookVersionId 
        OR Core.vwJobs.RunbookVersionId = Core.vwRunbooks.DraftRunbookVersionID
"@
    
    If ($RunbookName)
    {
        $QueriedJobs = Invoke-SQLCommand -Server $SQLServerName -Database $SQLDBName -Query "$jobcmd WHERE StatusID = '$JobStateID' AND RunbookName = '$RunbookName'"
    }
    Else
    {
        $QueriedJobs = Invoke-SQLCommand -Server $SQLServerName -Database $SQLDBName -Query "$jobcmd WHERE StatusID = '$JobStateID'"
    }
    
    Foreach ($qj in $QueriedJobs)
    {
        $jobqueueinfo = $WorkerQueues | ? {($qj.PartitionId -ge $_.LowKey) -and ($qj.PartitionId -le $_.HighKey)} 
        $jobinfo = New-Object -TypeName PSObject -Property @{
            WorkerName=$jobqueueinfo.ComputerName
            JobID=$qj.JobId
            RunbookId=$qj.RunbookID
            RunbookName=$qj.RunbookName
            CreationTime=$qj.CreationTime
            LastModifiedTime=$qj.LastModifiedTime
        }

        $JobAssignments += $jobinfo
    }

    $JobAssignments
}

Function Move-SMAJobQueue
{
    param(
    [Parameter(mandatory=$true)]
    [string]$SourceWorker,

    [Parameter(mandatory=$true)]
    [string]$TargetWorker,

    [Parameter(mandatory=$true)]
    [ValidateSet("queued", "starting", "running", "completed", "stopped", "failed", "suspended", "stopping", "resuming")]
    [string]$JobState,

    [Parameter(mandatory=$false)]
    [string]$RunbookName
    )

    Switch ($JobState)
    {
        "queued"     {$JobStateID =  1}
        "starting"   {$JobStateID =  2}
        "running"    {$JobStateID =  3}
        "completed"  {$JobStateID =  4}
        "failed"     {$JobStateID =  5}
        "stopped"    {$JobStateID =  6}
        "suspended"  {$JobStateID =  8}
        "stopping"   {$JobStateID = 11}
        "resuming"   {$JobStateID = 11}
    }

    $SourceWorkerInfo = Invoke-SQLCommand -Server $SQLServerName -Database $SQLDBName -Query "SELECT * FROM queues.deployment WHERE ComputerName = '$SourceWorker'"
    $TargetWorkerInfo = Invoke-SQLCommand -Server $SQLServerName -Database $SQLDBName -Query "SELECT * FROM queues.deployment WHERE ComputerName = '$TargetWorker'"
$jobcmd = @"
SELECT  Core.vwJobs.JobId, Core.vwJobs.JobStatusId, Core.vwJobs.JobStatus, Core.vwJobs.PartitionId, Core.vwJobs.CreationTime, Core.vwJobs.LastModifiedTime, 
        Core.vwRunbooks.RunbookName, 
        Core.vwRunbooks.RunbookId, Core.vwJobs.ErrorCount, Core.vwJobs.StartTime, Core.vwJobs.EndTime, Core.vwJobs.IsDraft
FROM    Core.Jobs LEFT OUTER JOIN
        Core.vwJobs ON Core.vwJobs.JobId = Core.Jobs.JobId LEFT OUTER JOIN
        Core.vwRunbooks ON Core.vwJobs.RunbookVersionId = Core.vwRunbooks.PublishedRunbookVersionId 
        OR Core.vwJobs.RunbookVersionId = Core.vwRunbooks.DraftRunbookVersionID
"@

    If ($RunbookName)
    {
        $JobsOnSource = Invoke-SQLCommand -Server $SQLServerName -Database $SQLDBName -Query "$jobcmd" | where {$_.PartitionId -ge $($SourceWorkerInfo.LowKey) -and $_.PartitionId -le $($SourceWorkerInfo.HighKey) -and $_.JobStatusID -eq $JobStateID -and $_.RunbookName -eq $RunbookName}
    }
    Else
    {
        $JobsOnSource = Invoke-SQLCommand -Server $SQLServerName -Database $SQLDBName -Query "$jobcmd" | where {$_.PartitionId -ge $($SourceWorkerInfo.LowKey) -and $_.PartitionId -le $($SourceWorkerInfo.HighKey) -and $_.JobStatusID -eq $JobStateID}
    }
    
    Write-Warning "The Following Jobs where found on the Source Worker matching the Status Filter: $JobState"
    Write-Output $JobsOnSource | Format-Table -AutoSize

    $Answer = Read-Host "Do you really want to move these Jobs to the Target Worker: $TargetWorker (Y/N)"
    If ($Answer -match 'Y')
    {
        Try
        {
            Foreach ($sJob in $JobsOnSource)
            {
                $NewPartitionID = Get-Random -Minimum $TargetWorkerInfo.LowKey -Maximum $TargetWorkerInfo.HighKey
                Write-Output "Moving Job: $($sJob.JobId) to Worker: $TargetWorker with new PartitionID: $NewPartitionID"
                Invoke-SQLCommand -Server $SQLServerName -Database $SQLDBName -Query "Update Core.Jobs SET PartitionID = $NewPartitionID WHERE JobID='$($sJob.JobId)'"
            }

            If ($RestartTargetService)
            {
                Invoke-Command $TargetWorker {Restart-Service rbsvc -Force}
            }
        }
        Catch
        {
            Write-Warning "Error Occured: $($_.Exception.Message)"
        }

    }
    Else
    {
        Write-Warning "Operation Aborted"
    }
}

Function Set-SMAJobState
{
    param(
    [Parameter(mandatory=$true)]
    [string]$JobID,

    [Parameter(mandatory=$true)]
    [ValidateSet("queued", "starting", "running", "completed", "stopped", "failed", "suspended", "stopping", "resuming")]
    [string]$JobState
    )

    Switch ($JobState)
    {
        "queued"     {$JobStateID =  1}
        "starting"   {$JobStateID =  2}
        "running"    {$JobStateID =  3}
        "completed"  {$JobStateID =  4}
        "failed"     {$JobStateID =  5}
        "stopped"    {$JobStateID =  6}
        "suspended"  {$JobStateID =  8}
        "stopping"   {$JobStateID = 11}
        "resuming"   {$JobStateID = 11}
    }

    Try
    {
        $JobsOnSource = Invoke-SQLCommand -Server $SQLServerName -Database $SQLDBName -Query "Update Core.Jobs SET StatusID = $JobStateID WHERE JobID='$JobID'"
    }
    Catch
    {
        Write-Warning "Error Occured: $($_.Exception.Message)"
    }
}

