param (
    [string]$ResourceGroup = "disktest2_group",
    [string]$VmName = "disktest2",
    [string]$OutputPath = "disks.csv"
)

# The PowerShell script that will run inside the VM
$inlineScript = @'
$tempDisk = Get-Volume | Where-Object { $_.FileSystemLabel -eq "Temporary Storage" }
$allDisks = Get-Disk | ForEach-Object {
    $disk = $_
    $diskNumber = $disk.Number
    $lun = [int]($disk.Location -replace ".*LUN\s*", "")
    Get-Partition -DiskNumber $disk.Number | ForEach-Object {
        $vol = Get-Volume -Partition $_
        if ($tempDisk) {
            $isDataDisk = if ($diskNumber -ge 2) { "true" } else { "false" }
        } else {
            $isDataDisk = if ($diskNumber -ge 1) { "true" } else { "false" }
        }

        [PSCustomObject]@{
            DriveLetter = $vol.DriveLetter
            DiskNumber  = $diskNumber
            LUN         = $lun
            SizeGB      = [math]::Round($vol.Size / 1GB, 2)
            FileSystem  = $vol.FileSystem
            IsDataDisk  = $isDataDisk
        }
    }
}

$allDisks = $allDisks | ConvertTo-Csv -NoTypeInformation | Out-String
Write-Output $allDisks
'@

Write-Host "🔍 Running script inside VM: $VmName..."
$response = az vm run-command invoke `
    --resource-group $ResourceGroup `
    --name $VmName `
    --command-id RunPowerShellScript `
    --scripts "$inlineScript" `
    --output json | ConvertFrom-Json

# Extract stdout
$csvRaw = $response.value[0].message -split "`r`n" | Where-Object { $_ -match ',' -and $_ -notmatch '^#' }
$allDisks = $csvRaw | ConvertFrom-Csv

Write-Host "📦 Found $($allDisks.Count) Volume(s) in VM..."

# Get Azure disk info from VM object
$vm = Get-AzVM -Name $VmName -ResourceGroupName $ResourceGroup
$azureDisks = $vm.StorageProfile.DataDisks | ForEach-Object {
    [PSCustomObject]@{
        AzureDiskName = $_.Name
        LUN           = $_.Lun
    }
}
$osDiskName = $vm.StorageProfile.OsDisk.Name

# Merge and tag each disk
$mergedList = foreach ($localDisk in $allDisks) {
    $diskNumber = [int]$localDisk.DiskNumber
    $isDataDisk = $localDisk.IsDataDisk

    if ($isDataDisk -eq 'true') {
        $lun = [int]$localDisk.LUN
        $azureMatch = $azureDisks | Where-Object { $_.LUN -eq $lun }
        $azureDiskName = if ($azureMatch) { $azureMatch.AzureDiskName } else { "Not Matched" }
        $diskType = "Data"
    }
    elseif ($diskNumber -eq 0) {
        $azureDiskName = $osDiskName
        $diskType = "OS"
    }
    else {
        $azureDiskName = "N/A"
        $diskType = "Temp"
    }

    [PSCustomObject]@{
        DriveLetter     = $localDisk.DriveLetter
        DiskNumber      = $localDisk.DiskNumber
        LUN             = $localDisk.LUN
        SizeGB          = $localDisk.SizeGB
        FileSystem      = $localDisk.FileSystem
        IsDataDisk      = $localDisk.IsDataDisk
        DiskType        = $diskType
        AzureDiskName   = $azureDiskName
    }
}

# Output and export
Write-Host "💾 Exporting merged result to $OutputPath..."
$mergedList | Format-Table -AutoSize
$mergedList | Export-Csv -Path $OutputPath -NoTypeInformation

Write-Host "✅ Done. Merged disk list saved to $OutputPath"
