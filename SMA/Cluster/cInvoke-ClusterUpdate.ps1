
Workflow cInvoke-ClusterUpdate
{
    param(
        [Parameter(Mandatory=$true)]
        [string]$ClusterName,

        [Parameter(Mandatory=$false)]
        [boolean]$RequireAllNodesOnline=$true

    )

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

    Function cCheck-StorageHealth
    {
        param(
            [Parameter(Mandatory=$true)]
            [string]$NodeName
        )

            #Checking if S2D / SOFS
            $StorageSubSystemPresent = Get-StorageSubSystem -FriendlyName "Clustered Windows Storage*" -CimSession $NodeName -ErrorAction SilentlyContinue
            If ($StorageSubSystemPresent)
            {
                #Check Health of Storage Subsystem, Pools and Drives
                $SubSysHealth = $StorageSubSystemPresent.HealthStatus
                $StoragePools = Get-StoragePool -IsPrimordial $false
                If ($StoragePools)
                {
                    Write-verbose "Storage Pools found:"
                    Write-verbose $StoragePools

                    #Check Storage Pool Health
                    $StoragePoolnotHealthy = $StoragePools | Where-Object {$_.HealthStatus -ne 'Healthy'}
                    If ($StoragePoolnotHealthy)
                    {
                        Throw "At least one Storage Pool is not in a healthy state, aborting"
                    }

                    #Check Virtual Disk Health
                    $virtualDisksnotHealthy = $StoragePools | Get-VirtualDisk | Where-Object {$_.HealthStatus -ne 'Healthy'}
                    If ($virtualDisksnotHealthy)
                    {
                        Write-Verbose "$virtualDisksnotHealthy"
                        Throw "At least one virtual Disk is not in a healthy state, aborting"
                    }
                }

            }
            else {
                Write-Verbose "No Storage SubSystem present. Cluster is not used for storage "
            } 
            return $true
    
    }

    #Check Storage Health
    cCheck-StorageHealth -NodeName ($ClusterNodeObjects)[0].Name

    #Building Cluster Progress Table
    $NodeProgress = @{}
    $NodeProgress = InlineScript {
        $NodeProgress = $USING:NodeProgress
        $ClusterNodeObjects = $USING:ClusterNodeObjects
        Foreach ($n in $ClusterNodeObjects)
        {
            $NodeProgress.Add("$($n.Name)","Not Started")
        }
        return $NodeProgress
    }
    $NodeProgress
    
}