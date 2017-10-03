<#
.Synopsis
   Initiates S2D Repair Jobs after Cluster Node Reboot

.DESCRIPTION
   Initiates S2D Repair Jobs after Cluster Node Reboot in case jobs are stuck in suspended mode
   Script has to be run using a scheduled task "at system startup"

.EXAMPLE
   .\Start-Vdiskrepair.ps1

.NOTES
    Date: 22.09.2017   
    Authors: Michael Rueefli aka drmiru (www.miru.ch)
    Version: 1.0 (stable)

    History:
    Version: 1.0.0.1 (changed calculation for destination node, as random does not work well with only a few amount of nodes)
#>


[CmdletBinding(
PositionalBinding=$false,
HelpUri = 'http://www.itnetX.ch/')]
    
param(   
    [Parameter(Mandatory=$false)]
    [String]$LogFilePath="C:\Scripts\Logs",
    
    [Parameter(Mandatory=$false)]
    [Int]$MaxLogSizeInKB = 10240    
)

#region Globals
$ErrorActionPreference = "stop"
$LogFileName = 'vdiskRepair.log'
$LogFile = Join-Path $LogFilePath $LogFileName
    
#Create Logfolder if not present
If (!(Test-Path LogFilePath))
{
    New-Item -path $LogFilePath -ItemType Directory -Force
}   
#endregion Globals
    
#region functions
function New-LogEntry
{
    #Full credits for this adapted function to: Russ Slaten (MSFT)
    param (
    [Parameter(Mandatory=$true)]
    [string]$message,
    
    [Parameter(Mandatory=$true)]
    [string]$component,
    
    [Parameter(Mandatory=$true)]
    [ValidateSet('Info','Warning','Verbose','Error')]
    [string]$type 
    )
    
    Try
    {
        if (($type -eq "Verbose") -and ($VerbosePreference -eq "Continue"))
        {
        $toLog = "{0} `$$<{1}><{2} {3}><thread={4}>" -f ($type + ":" + $message), ($ScriptName + ":" + $component), (Get-Date -Format "MM-dd-yyyy"), (Get-Date -Format "HH:mm:ss.ffffff"), $pid
        $toLog | Out-File -Append -Encoding UTF8 -FilePath ("filesystem::{0}" -f $LogFile)
        }
        Else
        {
        $toLog = "{0} `$$<{1}><{2} {3}><thread={4}>" -f ($type + ":" + $message), ($ScriptName + ":" + $component), (Get-Date -Format "MM-dd-yyyy"), (Get-Date -Format "HH:mm:ss.ffffff"), $pid
        $toLog | Out-File -Append -Encoding UTF8 -FilePath ("filesystem::{0}" -f $LogFile)
        }
    
        if ((Get-Item $LogFile).Length/1KB -gt $MaxLogSizeInKB)
        {
        $log = $LogFile
        Remove-Item ($log.Replace(".log", ".lo_")) -ErrorAction Ignore
        Rename-Item $LogFile ($log.Replace(".log", ".lo_")) -Force -ErrorAction Ignore
        }
    }
    Catch
    {
    Write-Warning "Could not log to File: $($_.InvocationInfo.myCommand.Name): $($_.Exception.Message)"
    }
} 

#region main

#Wait for Cluster Node to be up again
While ((get-clusternode -Name $ENV:COMPUTERNAME).State -ne 'up')
{
    New-LogEntry -message "Waiting for Cluster Node to come online or to be resumed" -component "(Main)" -type Info	
    Start-Sleep -Seconds 10
}

#Find disks not healthy and start repair immediately
New-LogEntry -message "Searching disks not healthy and start repair immediately" -component "(Main)" -type Info
$vdisksnothealthy = Get-virtualdisk | where {$_.OperationalStatus -match 'Incomplete' -or $_.OperationalStatus -match 'Degraded'}

If (!$vdisksnothealthy)
{
    New-LogEntry -message "No virtual disks to repair found" -component "(Main)" -type Info
}
Else
{
    New-LogEntry -message "Resuming Storage Maintenance Mode" -component "(Main)" -type Info
    Repair-ClusterStorageSpacesDirect -DisableStorageMaintenanceMode -Confirm:$false
    
    Foreach ($vd in $vdisksnothealthy)
    {
        $csv = $vd | Get-ClusterSharedVolume
        $ClusterNodes = Get-Clusternode
        $CSV2NodeMapping =@()
        Foreach ($n in $ClusterNodes)
        {
           $nobj = New-Object -TypeName PSObject -Property @{
                NodeName = $n.Name
                CSVCount = ($n | Get-ClusterSharedVolume).Count
           }
           $CSV2NodeMapping += $nobj
           
        }
        $NewOwnerNode = (($CSV2NodeMapping | Sort CSVCount) | Where-Object {$_.NodeName -ne $ENV:COMPUTERNAME})[0].NodeName
        New-LogEntry -message "Initiating CSV Ownership change vor Volume: $($csv.name)" -component "(Main)" -type Info
        Move-ClusterSharedVolume -name $csv.name -Node $NewOwnerNode
    }
}
New-LogEntry -message "Done. Please execute: Get-StorageJob to check progress" -component "(Main)" -type Info
#endregion main