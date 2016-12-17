[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [boolean]$RequireAllNodesOnline=$true,

    [Parameter(Mandatory=$false)]
    [int]$BootTimeOutSeconds=900,

    [Parameter(Mandatory=$false)]
    [bool]$SkipUpdates=$false,

    [Parameter(Mandatory=$false)]
    [String]$NodePreScript,

    [Parameter(Mandatory=$false)]
    [String]$NodePostScript,

    [Parameter(Mandatory=$false)]
    [String]$GlobalPreScript,

    [Parameter(Mandatory=$false)]
    [String]$GlobalPostScript
)

#Error handler
$ErrorActionPreference = "stop"

If ($GlobalPreScript)
{
    Try
    {
        Invoke-Item $GlobalPreScript
    }
    Catch
    {
        Write-Warning "Error executing Global Prescript: $GlobalPreScript"
    }
}


#Get Clusternodes
$ClusterNodeObjects = Get-ClusterNode -Cluster $ClusterName
$NodeCount = $ClusterNodeObjects.count

#Search for nodes not ready
$ClusterNodesNotReady = $ClusterNodeObjects | where {$_.State -ne 'up'}
If ($ClusterNodesNotReady -and $RequireAllNodesOnline -eq $true)
{
    throw "Not all Nodes seem to be online, aborting"
}
ElseIf ($ClusterNodesNotReady -and $RequireAllNodesOnline -eq $false)
{
    Write-Verbose "Not all nodes online, but we will continue"
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
            $SubSysHealth = $StorageSubSystem.HealthStatus
            If ($SubSysHealth -ne 'Healthy')
            {
                $SubSysNotHealthy = $true
                Write-Verbose "Storage Subsystem is not in a healthy state"
            }
            
            
            $StoragePools = $StorageSubSystem | Get-StoragePool -IsPrimordial $false
            If ($StoragePools)
            {
                Write-verbose "Storage Pools present"

                #Check Storage Pool Health
                $StoragePoolnotHealthy = $StoragePools | Where-Object {$_.HealthStatus -ne 'Healthy'}
                If ($StoragePoolnotHealthy)
                {
                    Write-Verbose "At least one Storage Pool is not in a healthy state"                    
                }

                #Check Virtual Disk Health
                $virtualDisksnotHealthy = $StoragePools | Get-VirtualDisk | Where-Object {$_.HealthStatus -ne 'Healthy'}
                If ($virtualDisksnotHealthy)
                {
                    Write-Verbose "$virtualDisksnotHealthy"
                    Write-Verbose "At least one virtual Disk is not in a healthy state"
                }
            }
        }
        else {
            Write-Output "No Clustered Storage SubSystem present. Skipping Storage Health Test"
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
    $sess = New-CimInstance -Namespace root/Microsoft/Windows/WindowsUpdate -ClassName MSFT_WUOperationsSession -CimSession $ServerName
    $scanResults = Invoke-CimMethod -InputObject $sess -MethodName ScanForUpdates -Arguments @{SearchCriteria="IsInstalled=0";OnlineScan=$true}

    #display available Updates
    If ($scanResults)
    {
        Write-Output "Required Updates found:"
        $scanResults.Updates | Select Title,KBArticleID

            #Install Updates
            If ($InstallRequired)
            {
                If (($scanResults.Updates).count -gt 0)
                {
    
                    Write-Output "Installing Updates"
                    $scanResults = Invoke-CimMethod -InputObject $sess -MethodName ApplyApplicableUpdates
                }
                Else
                {
                    Write-Warning "No applicaple Updates found"
                }
            }
    }

}

#region ####### Main routine #######

#Check Storage Health
$StorageHealth = Test-StorageHealth -NodeName ($ClusterNodeObjects)[0].Name
If ($StorageHealth -eq $false)
{
    write-verbose "Storage Subsystem present, but currently not in a healthy state. Aborting!"
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
    #update Node State
    $NodeProgress.Set_Item("$nodename", "started")
    
    #Suspending node
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
        Suspend-ClusterNode -Name $NodeName -Cluster $ClusterName -drain
    }
    Catch
    {
        Write-Error "Unable to suspend Node: $NodeName . Aborting now!"
        $NodeProgress
        throw $_.Exception.Message
    }

    #starting update process
    If ($SkipUpdates -ne $true)
    {
        Write-Output "Invoking WU Run on Node: $NodeName"
        Invoke-WSUSUpdate -ServerName $NodeName -InstallRequired $true
    }

    #Restart Node if required
    If (Test-PendingReboot -NodeName $NodeName)
    {
        Write-Output "Restarting Node: $NodeName"
        Restart-Computer -ComputerName $NodeName -Protocol WSMan -Wait -For PowerShell -Timeout $BootTimeOutSeconds
    }

    #Test if node is up again
    If ((Get-ClusterNode -Name $NodeName -Cluster $ClusterName).State -eq 'paused')
    {
        Write-Output "Resuming Node: $NodeName"
        Resume-ClusterNode -Name $NodeName -Cluster $ClusterName
        #update Node State

        $StorageSubSystem = Get-StorageSubSystem -FriendlyName "Clustered Windows Storage*" -CimSession $NodeName -ErrorAction SilentlyContinue
            If ($StorageSubSystem)
            {
            Write-Output "Testing Storage Health"
            While ((Test-StorageHealth -NodeName $NodeName) -ne $true)
            {
                Write-Output "Storage is currently rebuilding or not n a healthy state, retry in 60 seconds"
                Start-Sleep -Seconds 60
            }
            Write-Output "Storage Looks healthy now, sleeping for 30 seconds before continuing.."
            Start-Sleep -Seconds 30
        }
        
        $NodeProgress.Set_Item("$nodename", "completed")   
    }
    else 
    {
        #update Node State
        $NodeProgress.Set_Item("$NodeName", "failed")
        Write-Error "Update process for Node: $NodeName has failed. Check logfile for more information"
    }
    
}
    
Write-Output "Cluster Update successfully completed"
$NodeProgress
#endregion