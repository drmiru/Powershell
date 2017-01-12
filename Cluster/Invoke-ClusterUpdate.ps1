<#
.Synopsis
   Updates a Failover Cluster using Windows Update Client

.DESCRIPTION
   Performs an orchestrated Windows Update of a Windows Failover Cluster.
   Also supports Nano Server, as it only uses local Clustering CMDLETs and WMI classes available to Nano Server

   Prerequisites:
   -WinRM Access to all Cluster Nodes
   -WMI Access to Cluster
   -Windows Update Client configured -> for Nano Server see: http://www.miru.ch/deploy-packages-and-windows-updates-to-nano-servers/
   -Failover Clustering CMDLETs installed on coordinating machine (where you execute the script)

.EXAMPLE
   .\Invoke-ClusterUpdate.ps1 -ClusterName S2DCL01

.EXAMPLE
   .\Invoke-ClusterUpdate.ps1 -ClusterName S2DCL01 -verbose

.EXAMPLE
   .\Invoke-ClusterUpdate.ps1 -ClusterName S2DCL01 -NodePreScript C:\Scripts\CAUPre.ps1 -NodePostScript C:\Scripts\CAUPost.ps1 -GlobalPreScript E:\Scripts\ClusterUpdate-Pre-Script.ps1 -GlobalPostScript E:\Scripts\ClusterUpdate-Post-Script.ps1

.PARAMETER ClusterName
   Name of Cluster

.PARAMETER BootTimeOutSeconds
   Number of seconds to tolerate for a node reboot

.PARAMETER NodePreScript
   Name and path of a Script, which is executed first on each node locally
   (has to exist there of course)

.PARAMETER NodePostScript
   Name and path of a Script, which is executed after update on each node locally
   (has to exist there of course)

.PARAMETER GlobalPreScript
   Name and path of a Script, which is executed first, once, on coordinating machine
   (has to exist there of course)

.PARAMETER GlobalPostScript
   Name and path of a Script, which is executed after completion, once, on coordinating machine
   (has to exist there of course)

.PARAMETER LogFile
   Name and path of the Log File

.PARAMETER MaxLogSizeInKB
   Size in KB for the Log, before a new is created

.NOTES
    History
    --------------------------------------------------
    Version: 1.0.3
    Date: 11.01.2017 
    Changes: 
        -Added fix for KB3213986 where Cluster Service is not started automatically on initial boot
        -Fixed issue where Test-StorageHealth does not return true if no subsystem is present
        -Fixed error if pre-/post script variables where empty
        -Fixed Error, when no storage pools are present

    Authors: Michael Rueefli aka drmiru (www.miru.ch)
    Version: 1.0 (stable)
#>

[CmdletBinding(
PositionalBinding=$false,
HelpUri = 'http://www.miru.ch/')]

param(
    [Parameter(Mandatory=$true)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [int]$BootTimeOutSeconds=900,
    
    [Parameter(Mandatory=$false)]
    [String]$NodePreScript,

    [Parameter(Mandatory=$false)]
    [String]$NodePostScript,

    [Parameter(Mandatory=$false)]
    [String]$GlobalPreScript,

    [Parameter(Mandatory=$false)]
    [String]$GlobalPostScript,

    [Parameter(Mandatory=$false)]
    [String]$LogFile="C:\Windows\Logs\ClusterUpdate.log",

    [Parameter(Mandatory=$false)]
    [Int]$MaxLogSizeInKB = 10240
)

#region Globals
$ErrorActionPreference = "stop"
$Global:ScriptName = $MyInvocation.MyCommand.name
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

Function Test-StorageHealth
{
    param(
        [Parameter(Mandatory=$true)]
        [string]$NodeName
    )

        #Checking if S2D / SOFS
        $StorageSubSystem = Get-StorageSubSystem -FriendlyName "Clustered Windows Storage*" -CimSession $NodeName -ErrorAction SilentlyContinue
        If ($StorageSubSystem)
        {
            #Check Health of Storage Subsystem, Pools and Drives
            New-LogEntry -message ("Clustered Storage Subsystem Found on Node: $NodeName") -component "Test-StorageHealth()" -type Verbose
            $SubSysHealth = $StorageSubSystem.HealthStatus
            If ($SubSysHealth -ne 'Healthy')
            {
                $SubSysNotHealthy = $true
                New-LogEntry -message ("Storage Subsystem is not in a healthy state") -component "Test-StorageHealth()" -type Verbose
                Write-Verbose "Storage Subsystem is not in a healthy state"
            }
            
            
            $StoragePools = $StorageSubSystem | Get-StoragePool -IsPrimordial $false -ErrorAction SilentlyContinue
            If ($StoragePools)
            {
                Write-verbose "Storage Pools present"
                New-LogEntry -message ("Storage Pools present") -component "Test-StorageHealth()" -type Verbose

                #Check Storage Pool Health
                $StoragePoolnotHealthy = $StoragePools | Where-Object {$_.HealthStatus -ne 'Healthy'}
                If ($StoragePoolnotHealthy)
                {
                    New-LogEntry -message ("At least one Storage Pool is not in a healthy state") -component "Test-StorageHealth()" -type Verbose
                    Write-Verbose "At least one Storage Pool is not in a healthy state"                    
                }

                #Check Virtual Disk Health
                $virtualDisksnotHealthy = $StoragePools | Get-VirtualDisk -ErrorAction SilentlyContinue | Where-Object {$_.HealthStatus -ne 'Healthy'}
                If ($virtualDisksnotHealthy)
                {
                    New-LogEntry -message ("At least one virtual Disk is not in a healthy state") -component "Test-StorageHealth()" -type Verbose
                    Write-Verbose "At least one virtual Disk is not in a healthy state"
                }
            }
        }
        else {
            New-LogEntry -message ("No Clustered Storage SubSystem present. Skipping Storage Health Test") -component "Test-StorageHealth()" -type Info
            Write-Output "No Clustered Storage SubSystem present. Skipping Storage Health Test"
            return $true
        } 

        If ($StoragePoolnotHealthy -or $virtualDisksnotHealthy -or ($SubSysNotHealthy -eq $true))
        {
            return $false
        }
        Else
        {
            return $true
        }
}

Function Test-PendingReboot
{
     param(
     [Parameter(mandatory=$true)]
     [string]$NodeName
     )

     $RebootRequired = Invoke-Command -ComputerName $NodeName -ScriptBlock {
         If (Get-ChildItem "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending" -EA Ignore) 
         { 
            return $true 
         }
         Elseif (Get-Item "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired" -EA Ignore)
         { 
            return $true
         }
         Elseif (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -EA Ignore) 
         { 
            return $true 
         }
         Else
         {
            return $false
         }
     }
 
    New-LogEntry -message ("RebootRequired: $RebootRequired") -component "Test-PendingReboot()" -type Info
    Return $RebootRequired
}

Function Invoke-WSUSUpdate
{
    param(
    [Parameter(mandatory=$true)]
    [string]$ServerName,

    [Parameter(mandatory=$false)]
    [bool]$InstallRequired=$false
    )


    #Search Updates
    Try
    {
        $sess = New-CimInstance -Namespace root/Microsoft/Windows/WindowsUpdate -ClassName MSFT_WUOperationsSession -CimSession $ServerName
        $scanResults = Invoke-CimMethod -InputObject $sess -MethodName ScanForUpdates -Arguments @{SearchCriteria="IsInstalled=0";OnlineScan=$true}
    }
    Catch
    {
        New-LogEntry -message ("$($_.InvocationInfo.myCommand.Name): $($_.Exception.Message)") -component "Invoke-WSUSUpdate()" -type Info
        Write-Warning "$($_.InvocationInfo.myCommand.Name): $($_.Exception.Message)"
    }

    #display available Updates
    If ($scanResults.Updates.count -gt 0)
    {
        New-LogEntry -message ("Required Updates found:") -component "Invoke-WSUSUpdate()" -type Info
        $scanResults.Updates | Foreach {New-LogEntry -message ("$($_.KBArticleID) , $($_.Title)") -component "Invoke-WSUSUpdate()" -type Info}
        Write-Output "Required Updates found:"
        $scanResults.Updates | Select Title,KBArticleID

            #Install Updates
            If ($InstallRequired)
            {
                If (($scanResults.Updates).count -gt 0)
                {
    
                    New-LogEntry -message ("Installing Updates") -component "Invoke-WSUSUpdate()" -type Info
                    Write-Output "Installing Updates"
                    Try
                    {
                        $scanResults = Invoke-CimMethod -InputObject $sess -MethodName ApplyApplicableUpdates
                    }
                    Catch
                    {
                        New-LogEntry -message ("$($_.InvocationInfo.myCommand.Name): $($_.Exception.Message)") -component "Invoke-WSUSUpdate()" -type Info
                        Write-Warning "$($_.InvocationInfo.myCommand.Name): $($_.Exception.Message)"
                    }
                }
                Else
                {
                    New-LogEntry -message ("No applicaple Updates found") -component "Invoke-WSUSUpdate()" -type Info
                    Write-Output "No applicaple Updates found"
                }
            }
    }

}
#endregion functions

#region main()

#Checking CMDLETs
If (!(Get-WindowsFeature RSAT-Clustering-PowerShell))
{
    New-LogEntry -message ("Failover Clustering Module not present, install it first 'Add-WindowsFeature RSAT-Clustering-PowerShell'") -component "PreProcessing()" -type Error
    Write-Error "Failover Clustering Module not present, install it first 'Add-WindowsFeature RSAT-Clustering-PowerShell'"
}

New-LogEntry -message ("Cluster Update Started") -component "PreProcessing()" -type Info
If ($GlobalPreScript)
{
    Try
    {
        New-LogEntry -message ("Invoking Global Prescript: $GlobalPreScript") -component "PreProcessing()" -type Info
        Start-Process Powershell.exe -ArgumentList "-command $GlobalPreScript" -NoNewWindow -Wait
    }
    Catch
    {
        Write-Warning "Error executing Global Prescript: $GlobalPreScript"
    }
}


#Get Clusternodes
New-LogEntry -message ("Getting Cluster Nodes of Cluster: $ClusterName") -component "Main()" -type Info
Try
{
    $ClusterNodeObjects = Get-ClusterNode -Cluster $ClusterName
}
Catch
{
    New-LogEntry -message ("Error while getting Clusternodes from Cluster: $ClusterName : $($_.InvocationInfo.myCommand.Name): $($_.Exception.Message)") -component "Main()" -type Error
    throw "Error while getting Clusternodes from Cluster: $ClusterName : $($_.InvocationInfo.myCommand.Name): $($_.Exception.Message)"
}

$NodeCount = $ClusterNodeObjects.count
New-LogEntry -message ("Nodes found: $NodeCount") -component "Main()" -type Info

#Trying to connect to each Node using CIM
Foreach ($node in $ClusterNodeObjects)
{
    Try
    {
        $s = New-CimSession -ComputerName $node.name
        New-LogEntry -message ("Successfully Connected to Node: $($Node.Name) via CIM") -component "Main()" -type Info
        Write-Verbose "Successfully Connected to Node: $($Node.Name)"
    }
    Catch
    {
        New-LogEntry -message ("Error connecting Node: $($Node.Name) via CIM : $($_.InvocationInfo.myCommand.Name): $($_.Exception.Message)") -component "Main()" -type Error
        throw "Error connecting to Node: $($Node.Name) via CIM : $($_.InvocationInfo.myCommand.Name): $($_.Exception.Message)"
    } 
    Finally
    {
        If ($s)
        {
            $s | Remove-CimSession
        }
    }  
}

#Search for nodes not ready
New-LogEntry -message ("Searching For Nodes not up") -component "Main()" -type Info
$ClusterNodesNotReady = $ClusterNodeObjects | where {$_.State -ne 'up'}
If ($ClusterNodesNotReady)
{
    New-LogEntry -message ("Found $($ClusterNodesNotReady.Count) nodes not in UP state, aborting") -component "Main()" -type Error
    throw "Not all Nodes seem to be online, aborting"
}


#Check Storage Health
$StorageHealth = Test-StorageHealth -NodeName ($ClusterNodeObjects)[0].Name
If ($StorageHealth -eq $false)
{
    New-LogEntry -message ("Clustered Storage Subsystem present, but currently not in a healthy state. Aborting!") -component "Test-StorageHealth()" -type Error
    write-Warning "Storage Subsystem present, but currently not in a healthy state. Aborting!"
    throw "Storage Subsystem present, but currently not in a healthy state. Aborting!"
}

#Building Cluster Progress Table
$NodeProgress = @{}
Foreach ($n in $ClusterNodeObjects)
{
    $NodeProgress.Add("$($n.Name)","Not Started")
}
Write-Output $NodeProgress

Foreach ($node in $ClusterNodeObjects)
{
    $NodeName = $node.name

    If ($NodePreScript)
    {
        #Executing Node-PreScript
        New-LogEntry -message ("Starting Node Pre-Script $NodePreScript on node: $NodeName") -component "Main()" -type Info
        Write-Verbose "Starting Node Pre-Script $NodePreScript on node: $NodeName"
        Invoke-Command -ComputerName $NodeName -ScriptBlock {
            Start-Process Powershell.exe -ArgumentList "-command $USING:NodePreScript" -NoNewWindow -Wait
        }
    }
    
    
    #update Node State
    New-LogEntry -message ("Processing with Node: $NodeName") -component "Main()" -type Info
    $NodeProgress.Set_Item("$nodename", "started")
    
    #Suspending node
    New-LogEntry -message ("Simulating to suspend Node: $NodeName") -component "Main()" -type Info
    Write-Output "Trying if we can suspend the node first"
    $draincount = 0
    While ($draincount -lt 5 -and $drainresult -eq $false)
    {
        try
        {
            Suspend-ClusterNode -Name $NodeName -Cluster $ClusterName -drain -WhatIf
            $drainresult = $true
        }
        Catch
        {
           New-LogEntry -message ("Suspending Node: $NodeName not possible yet, waiting 5 Seconds for next retry") -component "Main()" -type Warning
           Write-Warning "Suspending Node: $NodeName not possible yet, waiting 5 Seconds for next retry..."
        }
        Finally
        {
            $draincount += 1
            Start-Sleep -Seconds 5
        }
    }

    write-output "suspending Node: $NodeName"
    Try
    {
        New-LogEntry -message ("Suspending Node: $NodeName , drain roles") -component "Main()" -type Info
        Suspend-ClusterNode -Name $NodeName -Cluster $ClusterName -drain
    }
    Catch
    {
        New-LogEntry -message ("Unable to suspend Node: $NodeName . Aborting now!") -component "Main()" -type Error
        Write-Error "Unable to suspend Node: $NodeName . Aborting now!"
        $NodeProgress
        throw $_.Exception.Message
    }

    #starting update process
    New-LogEntry -message ("Invoking WU Run on Node: $NodeName") -component "Main()" -type Info
    Write-Output "Invoking WU Run on Node: $NodeName"
    Invoke-WSUSUpdate -ServerName $NodeName -InstallRequired $true
    

    #Restart Node if required
    If (Test-PendingReboot -NodeName $NodeName)
    {
        New-LogEntry -message ("Node: $NodeName has a pending reboot entry, initiating restart") -component "Main()" -type Info
        Write-Output "Restarting Node: $NodeName"
        Restart-Computer -ComputerName $NodeName -Protocol WSMan -Wait -For PowerShell -Timeout $BootTimeOutSeconds
    }

    #region ---- Fix for KB3213986 where Cluster Service is not started after first reboot
    Invoke-Command -ComputerName $NodeName -ScriptBlock {
        If ((get-service ClusSvc -ErrorAction Ignore).Status -eq 'stopped')
        {
            New-LogEntry -message ("Starting Cluster Service on Node: $NodeName (fix for KB3213986)") -component "Main()" -type Info
            Write-Output "Starting Cluster Service on Node: $NodeName (fix for KB3213986)"
            Start-Service ClusSvc
            Start-Sleep -Seconds 10
        }
    }
    #endregion ---- fix for KB3213986

    #Test if node is up again
    If ((Get-ClusterNode -Name $NodeName -Cluster $ClusterName).State -eq 'paused')
    {
        New-LogEntry -message ("Resuming Node: $NodeName") -component "Main()" -type Info
        Write-Output "Resuming Node: $NodeName"
        Resume-ClusterNode -Name $NodeName -Cluster $ClusterName
        #update Node State

        $StorageSubSystem = Get-StorageSubSystem -FriendlyName "Clustered Windows Storage*" -CimSession $NodeName -ErrorAction SilentlyContinue
        If ($StorageSubSystem)
        {
            New-LogEntry -message ("Testing Storage Health") -component "Main()" -type Info
            Write-Output "Testing Storage Health"
            While ((Test-StorageHealth -NodeName $NodeName) -ne $true)
            {
                New-LogEntry -message ("Storage is currently rebuilding or not n a healthy state, retry in 60 seconds") -component "Main()" -type Warning
                Write-Output "Storage is currently rebuilding or not n a healthy state, retry in 60 seconds"
                Start-Sleep -Seconds 60
            }
            New-LogEntry -message ("Storage Looks healthy now, sleeping for 30 seconds before continuing") -component "Main()" -type Info
            Write-Output "Storage Looks healthy now, sleeping for 30 seconds before continuing.."
            Start-Sleep -Seconds 30
        }
        
        New-LogEntry -message ("Node: $NodeName Completed") -component "Main()" -type Info
        $NodeProgress.Set_Item("$nodename", "completed")   

    }
    else 
    {
        #update Node State
        $NodeProgress.Set_Item("$NodeName", "failed")
        New-LogEntry -message ("Update process for Node: $NodeName has failed, Node did not come up again!") -component "Main()" -type Error
        Write-Error "Update process for Node: $NodeName has failed. Check logfile for more information"
    }

    #Start Node Post-Script
    If ($NodePostScript)
    {
        New-LogEntry -message ("Starting Node Post-Script $NodePostScript on node: $NodeName") -component "Main()" -type Info
        Write-Verbose "Starting Node Post-Script $NodePostScript on node: $NodeName"
        Invoke-Command -ComputerName $NodeName -ScriptBlock {
            Start-Process Powershell.exe -ArgumentList "-command $Using:NodePostScript" -NoNewWindow -Wait
        }
    }
    
}

#Start Global Post-Script
If ($GlobalPostScript)
{
    New-LogEntry -message ("Starting Global Post-Script $GlobalPostScript") -component "Main()" -type Info
    Write-Verbose "Starting Node Post-Script $GlobalPostScript"
    Start-Process Powershell.exe -ArgumentList "-command $GlobalPostScript" -NoNewWindow -Wait
}


New-LogEntry -message ("Cluster Update successfully completed") -component "Main()" -type Info    
Write-Output "Cluster Update successfully completed"
$NodeProgress
#endregion