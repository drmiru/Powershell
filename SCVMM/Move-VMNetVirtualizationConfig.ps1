Function Move-VMNetVirtualizationConfig
{
    <#
    .Synopsis
    Move-VMNetVirtualizationConfig

    .DESCRIPTION
    Moves a virtual network (GRE) with its NAT/VPN configuration to another gateway device

    .PARAMETER VMNetworkName
    Name of the VMNetwork to be moved

    .PARAMETER NewGatewayName
    Name of the new HNV gateway device in VMM where the VMNetwork should be moved to

    .PARAMETER StaticIPPoolName
    Name of the IP Pool in VMM used for public IP Addresses (frontend)

    .EXAMPLE
    Move-VMNetVirtualizationConfig -VMNetworkName TenantVMNet91 -NewGatewayName GREGW02 -StaticIPPoolName GRE_PublicPool_01

    .NOTES
    Author: Michael Rueefli
    Version: 1.0 (stable)
    #>
    
    [CmdletBinding()]
    Param(
    [Parameter(mandatory=$true)]
    [string]$VMNetworkName,

    [Parameter(mandatory=$true)]
    [string]$NewGatewayName,

    [Parameter(mandatory=$true)]
    [string]$StaticIPPoolName
    )

    Write-Output "Gathering Information"
    #Get VM network
    $VMnet = Get-SCVMNetwork | ? {$_.name -match $VMNetworkName}
    If (!$VMnet)
    {
        Write-Warning "No Gateway Device found matching name: $VMNetworkName , aborting"
        break
    }
    Write-Verbose "VM Network: $VMNet"

    #Get old GW
    $OldVMnetGW = Get-SCVMNetworkGateway -VMNetwork $VMNet
    If (!$OldVMnetGW)
    {
        Write-Warning "VM Network: $VMNetworkName , seems not to be a virtualized VMNetwork, aborting"
        break
    }
    Write-Verbose "Existing VM GW: $OldVMnetGW"

    #Get NAT Connection
    $VMNatConnections = Get-SCNATConnection -VMNetworkGateway $OldVMnetGW
    Write-Verbose "Nat Connections: $VMNatConnections"

    #Get NAT Rules
    $VMNatRules = Foreach ($natcon in $VMNatConnections)
    {
        Get-SCNatRule -NATConnection $natcon
    }
    Write-Verbose "Nat Rules: $VMNatRules"

    #Get Default External IP
    $DefaultExtIPs = (($VMNatRules | Where-Object {$_.ExternalPort -eq 0}).ExternalIPAddress)

    #Get S2S VPN Connections
    $VPNConnections = Get-SCVPNConnection -VMNetworkGateway $OldVMnetGW -ErrorAction SilentlyContinue
    $NetworkRoutes = Get-SCNetworkRoute -Gateway $OldVMnetGW
    
    #Get New GW
    $NewNetGWSvc = Get-SCNetworkGateway -Name $NewGatewayName
    If (!$NewNetGWSvc)
    {
        Write-Warning "No Gateway Device found matching name: $NewGatewayName , aborting"
        break
    }

    #Remove current configuration
    Write-Output "Removing current NAT/VPN Configuration"
    If ($VPNConnections)
    {
        $null = $VPNConnections | Remove-SCVPNConnection -Force
    }
    $null = $VMNatConnections | Remove-SCNATConnection -Force
    $null = $OldVMnetGW | Remove-SCVMNetworkGateway -Force

    #Add new Gateway
    Write-Output "Re-Adding configuration to GW: $NewGatewayName"
    $NewVMnetGW = Add-SCVMNetworkGateway -VMNetwork $VMnet -NetworkGateway $NewNetGWSvc -Name $OldVMnetGW.Name

    #Configure New NAT Connections on Target Gateway
    Write-Verbose "Adding NAT Connections"
    $IPPool = Get-SCStaticIPAddressPool | ? {$_.name -eq $StaticIPPoolName }
    $NewVMNatConnections = @()
    Foreach ($DefIPObj in $DefaultExtIPs)
    {
        $NewDefaultNatCon = Add-SCNATConnection -VMNetworkGateway $NewVMnetGW -ExternalIPPool $IPPool -ExternalIPAddress $DefIPObj
        $NewVMNatConnections += $NewDefaultNatCon
    }

    #Add NAT Rules
    Write-Verbose "Adding custom NAT rules"
    $VMCustomNATRules = $VMNatRules | Where-Object {$_.ExternalPort -ne 0}
    Foreach ($ruleobj in $VMCustomNATRules)
    {
        $newNatRule = Add-SCNATRule -NATConnection ($NewVMNatConnections | Where-Object {$_.Rules.ExternalIPAddress -eq $ruleobj.ExternalIPAddress}) -Name $ruleobj.Name -InternalIPAddress $ruleobj.InternalIPAddress `
        -InternalPort $ruleobj.InternalPort -ExternalPort $ruleobj.ExternalPort -Protocol $ruleobj.Protocol
    }

    #Migrate VPN Connections
    If ($VPNConnections)
    {
        Write-Verbose "Adding VPN connections"
        Foreach ($vpnconn in $VPNConnections)
        {
            $newVPNConn = Add-SCVPNConnection -Name $vpnconn.Name -VMNetworkGateway $NewVMnetGW -TargetIPv4VPNAddress $VPNConnections.TargetVPNIPv4Address `
            -EncryptionMethod $vpnconn.EncryptionMethod -PFSGroup $vpnconn.PFSGroup -Secret $vpnconn.Secret -Protocol $vpnconn.Protocol

            #Add Routes
            Write-Verbose "Adding network routes"
            Foreach ($routeobj in $NetworkRoutes)
            {
                $NewNetRoute = Add-SCNetworkRoute -IPSubnet $routeobj.IPSubnet -VPNConnection $newVPNConn -VMNetworkGateway $NewVMnetGW
            }
        }
        
    }
}
