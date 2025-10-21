$location = "uksouth"
$resourceGroupName = "mate-azure-task-17"

$virtualNetworkName = "todoapp"
$vnetAddressPrefix = "10.20.30.0/24"
$webSubnetName = "webservers"
$webSubnetIpRange = "10.20.30.0/26"
$mngSubnetName = "management"
$mngSubnetIpRange = "10.20.30.128/26"

$sshKeyName = "linuxboxsshkey"
$sshKeyPublicKey = Get-Content "~/.ssh/id_rsa.pub"

$vmImage = "Ubuntu2204"
$vmSize = "Standard_B1s"
$webVmName = "webserver"
$jumpboxVmName = "jumpbox"
$dnsLabel = "matetask" + (Get-Random -Count 1)

$privateDnsZoneName = "or.nottodo"

try {
    Write-Host "=== Azure DNS Zone Deployment ==="

    Write-Host "Creating a resource group $resourceGroupName ..."
    $resourceGroup = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
    if (-not $resourceGroup) {
        $resourceGroup = New-AzResourceGroup -Name $resourceGroupName -Location $location
        Write-Host "✅ Resource group created"
    } else {
        Write-Host "ℹ️ Resource group already exists"
    }

    Write-Host "Creating web network security group..."
    $webNsg = Get-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Name $webSubnetName -ErrorAction SilentlyContinue
    if (-not $webNsg) {
        $webHttpRule = New-AzNetworkSecurityRuleConfig -Name "web" -Description "Allow HTTP" `
           -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix `
           Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 80,443
        $webNsg = New-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Location $location -Name `
           $webSubnetName -SecurityRules $webHttpRule
        Write-Host "✅ Web NSG created"
    } else {
        Write-Host "ℹ️ Web NSG already exists"
    }

    Write-Host "Creating management network security group..."
    $mngNsg = Get-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Name $mngSubnetName -ErrorAction SilentlyContinue
    if (-not $mngNsg) {
        $mngSshRule = New-AzNetworkSecurityRuleConfig -Name "ssh" -Description "Allow SSH" `
           -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix `
           Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 22
        $mngNsg = New-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Location $location -Name `
           $mngSubnetName -SecurityRules $mngSshRule
        Write-Host "✅ Management NSG created"
    } else {
        Write-Host "ℹ️ Management NSG already exists"
    }

    Write-Host "Creating a virtual network ..."
    $virtualNetwork = Get-AzVirtualNetwork -Name $virtualNetworkName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
    if (-not $virtualNetwork) {
        $webSubnet = New-AzVirtualNetworkSubnetConfig -Name $webSubnetName -AddressPrefix $webSubnetIpRange -NetworkSecurityGroup $webNsg
        $mngSubnet = New-AzVirtualNetworkSubnetConfig -Name $mngSubnetName -AddressPrefix $mngSubnetIpRange -NetworkSecurityGroup $mngNsg
        $virtualNetwork = New-AzVirtualNetwork -Name $virtualNetworkName -ResourceGroupName $resourceGroupName -Location $location -AddressPrefix $vnetAddressPrefix -Subnet $webSubnet,$mngSubnet
        Write-Host "✅ Virtual network created"
    } else {
        Write-Host "ℹ️ Virtual network already exists"
    }

    # Create Private DNS Zone with idempotency
    Write-Host "Creating Private DNS Zone: $privateDnsZoneName ..."
    $privateDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $resourceGroupName -Name $privateDnsZoneName -ErrorAction SilentlyContinue
    if (-not $privateDnsZone) {
        $privateDnsZone = New-AzPrivateDnsZone `
            -ResourceGroupName $resourceGroupName `
            -Name $privateDnsZoneName
        Write-Host "✅ Private DNS Zone created"
    } else {
        Write-Host "ℹ️ Private DNS Zone already exists"
    }

    # Link Private DNS Zone with Virtual Network with auto-registration and idempotency
    Write-Host "Linking Private DNS Zone with Virtual Network..."
    $vnetLinkName = "${virtualNetworkName}-link"
    $vnetLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $resourceGroupName -ZoneName $privateDnsZoneName -Name $vnetLinkName -ErrorAction SilentlyContinue
    if (-not $vnetLink) {
        $vnetLink = New-AzPrivateDnsVirtualNetworkLink `
            -ResourceGroupName $resourceGroupName `
            -ZoneName $privateDnsZoneName `
            -Name $vnetLinkName `
            -VirtualNetworkId $virtualNetwork.Id `
            -EnableRegistration:$true
        Write-Host "✅ VNet link created with auto-registration"
    } else {
        Write-Host "ℹ️ VNet link already exists"
    }

    Write-Host "Creating a SSH key resource ..."
    $sshKey = Get-AzSshKey -Name $sshKeyName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
    if (-not $sshKey) {
        New-AzSshKey -Name $sshKeyName -ResourceGroupName $resourceGroupName -PublicKey $sshKeyPublicKey
        Write-Host "✅ SSH key created"
    } else {
        Write-Host "ℹ️ SSH key already exists"
    }

    Write-Host "Creating a web server VM ..."
    $webVm = Get-AzVM -ResourceGroupName $resourceGroupName -Name $webVmName -ErrorAction SilentlyContinue
    if (-not $webVm) {
        New-AzVm `
        -ResourceGroupName $resourceGroupName `
        -Name $webVmName `
        -Location $location `
        -image $vmImage `
        -size $vmSize `
        -SubnetName $webSubnetName `
        -VirtualNetworkName $virtualNetworkName `
        -SshKeyName $sshKeyName 
        
        $Params = @{
            ResourceGroupName  = $resourceGroupName
            VMName             = $webVmName
            Name               = 'CustomScript'
            Publisher          = 'Microsoft.Azure.Extensions'
            ExtensionType      = 'CustomScript'
            TypeHandlerVersion = '2.1'
            Settings          = @{fileUris = @('https://raw.githubusercontent.com/mate-academy/azure_task_17_work_with_dns/main/install-app.sh'); commandToExecute = './install-app.sh'}
         }
        Set-AzVMExtension @Params
        Write-Host "✅ Web server VM created"
    } else {
        Write-Host "ℹ️ Web server VM already exists"
    }

    Write-Host "Creating a public IP with Standard SKU..."
    $publicIP = Get-AzPublicIpAddress -Name $jumpboxVmName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
    if (-not $publicIP) {
        $publicIP = New-AzPublicIpAddress `
            -Name $jumpboxVmName `
            -ResourceGroupName $resourceGroupName `
            -Location $location `
            -Sku Standard `
            -AllocationMethod Static `
            -DomainNameLabel $dnsLabel
        Write-Host "✅ Public IP created"
    } else {
        Write-Host "ℹ️ Public IP already exists"
    }

    Write-Host "Creating a management VM ..."
    $jumpboxVm = Get-AzVM -ResourceGroupName $resourceGroupName -Name $jumpboxVmName -ErrorAction SilentlyContinue
    if (-not $jumpboxVm) {
        New-AzVm `
        -ResourceGroupName $resourceGroupName `
        -Name $jumpboxVmName `
        -Location $location `
        -image $vmImage `
        -size $vmSize `
        -SubnetName $mngSubnetName `
        -VirtualNetworkName $virtualNetworkName `
        -SshKeyName $sshKeyName `
        -PublicIpAddressName $jumpboxVmName
        Write-Host "✅ Management VM created"
    } else {
        Write-Host "ℹ️ Management VM already exists"
    }

    # Wait for VMs to be fully provisioned and auto-registered in DNS
    Write-Host "Waiting for VMs to be provisioned and auto-registered in DNS (90 seconds)..."
    Start-Sleep -Seconds 90

    # Wait for web server A record to be auto-registered
    Write-Host "Checking for web server A record auto-registration..."
    $webServerARecord = $null
    $maxAttempts = 10
    $attempt = 1
    
    while (-not $webServerARecord -and $attempt -le $maxAttempts) {
        Write-Host "Attempt $attempt to find A record for $webVmName..."
        $webServerARecord = Get-AzPrivateDnsRecordSet -ResourceGroupName $resourceGroupName -ZoneName $privateDnsZoneName -RecordType A -Name $webVmName -ErrorAction SilentlyContinue
        if (-not $webServerARecord) {
            Start-Sleep -Seconds 15
            $attempt++
        }
    }

    if ($webServerARecord) {
        Write-Host "✅ Web server A record found: $webVmName.$privateDnsZoneName -> $($webServerARecord.Records[0].Ipv4Address)"
    } else {
        Write-Host "⚠️ Web server A record not found after $maxAttempts attempts. Continuing anyway..."
    }

    # Create CNAME record with idempotency
    Write-Host "Creating CNAME record: todo -> $webVmName.$privateDnsZoneName"
    $cnameRecord = Get-AzPrivateDnsRecordSet -ResourceGroupName $resourceGroupName -ZoneName $privateDnsZoneName -RecordType CNAME -Name "todo" -ErrorAction SilentlyContinue

    if ($cnameRecord) {
        Write-Host "ℹ️ CNAME record already exists. Updating..."
        # Remove existing CNAME records
        $cnameRecord.Records.Clear()
        # Add new CNAME record
        Add-AzPrivateDnsRecordConfig -RecordSet $cnameRecord -Cname "$webVmName.$privateDnsZoneName"
        Set-AzPrivateDnsRecordSet -RecordSet $cnameRecord
    } else {
        Write-Host "Creating new CNAME record using step-by-step method..."
        
        # Create empty record set
        $recordSet = New-AzPrivateDnsRecordSet `
            -ResourceGroupName $resourceGroupName `
            -ZoneName $privateDnsZoneName `
            -Name "todo" `
            -RecordType "CNAME" `
            -Ttl 3600
        
        # Add CNAME record to the record set
        Add-AzPrivateDnsRecordConfig -RecordSet $recordSet -Cname "$webVmName.$privateDnsZoneName"
        
        # Save the record set
        Set-AzPrivateDnsRecordSet -RecordSet $recordSet
    }

    # Verify the CNAME record was created
    $verifyCname = Get-AzPrivateDnsRecordSet -ResourceGroupName $resourceGroupName -ZoneName $privateDnsZoneName -RecordType CNAME -Name "todo" -ErrorAction SilentlyContinue
    if ($verifyCname -and $verifyCname.Records) {
        Write-Host "✅ CNAME record successfully created: todo.$privateDnsZoneName -> $($verifyCname.Records[0].Cname)"
    } else {
        Write-Host "❌ CNAME record creation failed"
        throw "CNAME record creation failed"
    }

    Write-Host "`n🎉 Private DNS configuration completed successfully!"
    Write-Host "📋 DNS Records created:"
    Write-Host "  - Private DNS Zone: $privateDnsZoneName"
    Write-Host "  - CNAME record: todo.$privateDnsZoneName -> $webVmName.$privateDnsZoneName"
    Write-Host "  - Virtual Network Link: $vnetLinkName (with auto-registration)"

    # Display connection information
    Write-Host "`n🔗 Connection Information:"
    Write-Host "  - Web application URL: http://todo.$privateDnsZoneName:8080/"
    Write-Host "  - Jumpbox public IP: $($publicIP.IpAddress)"
    Write-Host "  - SSH to jumpbox: ssh azureuser@$($publicIP.IpAddress)"
    Write-Host "  - From jumpbox, test web app: curl http://todo.$privateDnsZoneName:8080/"

}
catch {
    Write-Error "❌ Deployment failed: $($_.Exception.Message)"
    Write-Host "Stack trace: $($_.ScriptStackTrace)"
    exit 1
}