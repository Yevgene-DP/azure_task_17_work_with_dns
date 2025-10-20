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

Write-Host "Creating a resource group $resourceGroupName ..."
New-AzResourceGroup -Name $resourceGroupName -Location $location

Write-Host "Creating web network security group..."
$webHttpRule = New-AzNetworkSecurityRuleConfig -Name "web" -Description "Allow HTTP" `
   -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix `
   Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 80,443
$webNsg = New-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Location $location -Name `
   $webSubnetName -SecurityRules $webHttpRule

Write-Host "Creating mngSubnet network security group..."
$mngSshRule = New-AzNetworkSecurityRuleConfig -Name "ssh" -Description "Allow SSH" `
   -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix `
   Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 22
$mngNsg = New-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Location $location -Name `
   $mngSubnetName -SecurityRules $mngSshRule

Write-Host "Creating a virtual network ..."
$webSubnet = New-AzVirtualNetworkSubnetConfig -Name $webSubnetName -AddressPrefix $webSubnetIpRange -NetworkSecurityGroup $webNsg
$mngSubnet = New-AzVirtualNetworkSubnetConfig -Name $mngSubnetName -AddressPrefix $mngSubnetIpRange -NetworkSecurityGroup $mngNsg
$virtualNetwork = New-AzVirtualNetwork -Name $virtualNetworkName -ResourceGroupName $resourceGroupName -Location $location -AddressPrefix $vnetAddressPrefix -Subnet $webSubnet,$mngSubnet

# Create Private DNS Zone FIRST, before VMs
Write-Host "Creating Private DNS Zone: $privateDnsZoneName ..."
$privateDnsZone = New-AzPrivateDnsZone `
    -ResourceGroupName $resourceGroupName `
    -Name $privateDnsZoneName

# Link Private DNS Zone with Virtual Network with auto-registration
Write-Host "Linking Private DNS Zone with Virtual Network..."
$vnetLink = New-AzPrivateDnsVirtualNetworkLink `
    -ResourceGroupName $resourceGroupName `
    -ZoneName $privateDnsZoneName `
    -Name "${virtualNetworkName}-link" `
    -VirtualNetworkId $virtualNetwork.Id `
    -EnableRegistration

Write-Host "Creating a SSH key resource ..."
New-AzSshKey -Name $sshKeyName -ResourceGroupName $resourceGroupName -PublicKey $sshKeyPublicKey

Write-Host "Creating a web server VM ..."
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

Write-Host "Creating a public IP with Standard SKU..."
$publicIP = New-AzPublicIpAddress `
    -Name $jumpboxVmName `
    -ResourceGroupName $resourceGroupName `
    -Location $location `
    -Sku Standard `  # Changed from Basic to Standard
    -AllocationMethod Static `  # Changed to Static for Standard SKU
    -DomainNameLabel $dnsLabel

Write-Host "Creating a management VM ..."
# Create network interface with the public IP
$mngNic = New-AzNetworkInterface `
    -Name "${jumpboxVmName}-nic" `
    -ResourceGroupName $resourceGroupName `
    -Location $location `
    -SubnetId $virtualNetwork.Subnets[1].Id `  # management subnet
    -PublicIpAddressId $publicIP.Id

# Create the VM with the network interface
$vmConfig = New-AzVMConfig -VMName $jumpboxVmName -VMSize $vmSize
$vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux -ComputerName $jumpboxVmName -Credential (Get-Credential -Message "Enter admin credentials" -UserName "azureuser")
$vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $mngNic.Id
$vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName "Canonical" -Offer "0001-com-ubuntu-server-jammy" -Skus "22_04-lts-gen2" -Version "latest"
$vmConfig = Add-AzVMSshPublicKey -VM $vmConfig -KeyData $sshKeyPublicKey -Path "/home/azureuser/.ssh/authorized_keys"

New-AzVM -ResourceGroupName $resourceGroupName -Location $location -VM $vmConfig

# Wait for VMs to be fully provisioned and auto-registered in DNS
Write-Host "Waiting for VMs to be provisioned and auto-registered in DNS (60 seconds)..."
Start-Sleep -Seconds 60

# Create CNAME record - SIMPLE AND CORRECT METHOD
Write-Host "Creating CNAME record: todo -> $webVmName.$privateDnsZoneName"

$cnameParams = @{
    ResourceGroupName = $resourceGroupName
    ZoneName          = $privateDnsZoneName
    Name              = "todo"
    RecordType        = "CNAME"
    Ttl               = 3600
    Cname             = "$webVmName.$privateDnsZoneName"
}

New-AzPrivateDnsRecordSet @cnameParams

Write-Host "✅ CNAME record created successfully: todo.$privateDnsZoneName -> $webVmName.$privateDnsZoneName"

Write-Host "Private DNS configuration completed successfully!"
Write-Host "DNS Records created:"
Write-Host "  - Private DNS Zone: $privateDnsZoneName"
Write-Host "  - CNAME record: todo.$privateDnsZoneName -> $webVmName.$privateDnsZoneName"
Write-Host "  - Virtual Network Link: ${virtualNetworkName}-link (with auto-registration)"

# Display connection information
Write-Host "`nConnection Information:"
Write-Host "  - Web application URL: http://todo.$privateDnsZoneName:8080/"
Write-Host "  - Jumpbox public IP: $($publicIP.IpAddress)"
Write-Host "  - SSH to jumpbox: ssh azureuser@$($publicIP.IpAddress)"
Write-Host "  - From jumpbox, test web app: curl http://todo.$privateDnsZoneName:8080/"