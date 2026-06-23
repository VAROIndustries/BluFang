#Requires -RunAsAdministrator
<#
.SYNOPSIS
    BluFang - Bluetooth Device Renamer & Inspector for Windows 11
.DESCRIPTION
    Rename Bluetooth device friendly names and view nerdy connection stats.
    Named after Harald Bluetooth, the Viking king who united Denmark and Norway
    — just like this tool unites you with your device names.
.NOTES
    Requires Administrator privileges (registry writes).
    Works with Windows PowerShell 5.1 and PowerShell 7+.
#>

# ─── Strict mode ───
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Lookup Tables ───

$Script:LmpVersionMap = @{
    0  = '1.0b'; 1 = '1.1'; 2 = '1.2'; 3 = '2.0'; 4 = '2.1+EDR'
    5  = '3.0+HS'; 6 = '4.0'; 7 = '4.1'; 8 = '4.2'; 9 = '5.0'
    10 = '5.1'; 11 = '5.2'; 12 = '5.3'; 13 = '5.4'; 14 = '6.0'
}

$Script:ManufacturerMap = @{
    2 = 'Intel'; 10 = 'Qualcomm'; 13 = 'Texas Instruments'; 15 = 'Broadcom'
    18 = 'Ericsson'; 29 = 'Qualcomm Technologies'; 57 = 'Harman'
    69 = 'Plantronics'; 76 = 'Apple'; 78 = 'Nokia'; 85 = 'Realtek'
    89 = 'Nordic Semiconductor'; 117 = 'Samsung'; 148 = 'Logitech'
    224 = 'Google'; 301 = 'Bose'; 343 = 'Sony'; 1046 = 'JBL'
    1177 = 'Jabra'; 1452 = 'Sennheiser'; 1520 = 'Samsung (Harman)'
}

$Script:MajorDeviceClassMap = @{
    0 = 'Miscellaneous'; 1 = 'Computer'; 2 = 'Phone'; 3 = 'LAN/Network'
    4 = 'Audio/Video'; 5 = 'Peripheral'; 6 = 'Imaging'; 7 = 'Wearable'
    8 = 'Toy'; 9 = 'Health'; 31 = 'Uncategorized'
}

$Script:MinorAudioMap = @{
    0 = 'Uncategorized'; 1 = 'Wearable Headset'; 2 = 'Hands-Free AG'
    4 = 'Microphone'; 5 = 'Loudspeaker'; 6 = 'Headphones'
    7 = 'Portable Audio'; 8 = 'Car Audio'; 9 = 'Set-Top Box'
    10 = 'Hi-Fi Audio'; 11 = 'VCR'; 12 = 'Video Camera'
    13 = 'Camcorder'; 14 = 'Video Monitor'; 15 = 'Video Display + Speaker'
}

$Script:MinorPeripheralMap = @{
    0 = 'Uncategorized'; 1 = 'Joystick'; 2 = 'Gamepad'
    3 = 'Remote Control'; 4 = 'Sensing Device'; 5 = 'Digitizer Tablet'
    6 = 'Card Reader'; 7 = 'Digital Pen'; 8 = 'Barcode Scanner'
}

# ─── UI Helpers ───

function Write-Banner {
    Clear-Host
    $banner = @"

    ____  __      ______
   / __ )/ /_  __/ ____/___ _____  ____ _
  / __  / / / / / /_  / __ ``/ __ \/ __ ``/
 / /_/ / / /_/ / __/ / /_/ / / / / /_/ /
/_____/_/\__,_/_/    \__,_/_/ /_/\__, /
                                /____/
"@
    Write-Host $banner -ForegroundColor Cyan
    Write-Host '  Bluetooth Device Renamer & Inspector' -ForegroundColor DarkCyan
    Write-Host '  Named for Harald Bluetooth — king, unifier, namer of things' -ForegroundColor DarkGray
    Write-Host ''
}

function Write-Separator {
    param([string]$Char = [char]0x2500, [int]$Width = 70, [ConsoleColor]$Color = 'DarkCyan')
    Write-Host ($Char * $Width) -ForegroundColor $Color
}

function Write-Field {
    param([string]$Label, [string]$Value, [ConsoleColor]$ValueColor = 'White', [int]$LabelWidth = 22)
    $pad = ' ' * [Math]::Max(0, $LabelWidth - $Label.Length)
    Write-Host "  $Label$pad" -ForegroundColor Gray -NoNewline
    Write-Host $Value -ForegroundColor $ValueColor
}

function Write-SectionHeader {
    param([string]$Title)
    Write-Host ''
    Write-Host "  $([char]0x25B6) $Title" -ForegroundColor Magenta
    Write-Host "  $([string]([char]0x2500) * 40)" -ForegroundColor DarkMagenta
}

function Format-MacAddress {
    param([string]$Mac)
    if ($Mac.Length -eq 12) {
        return ($Mac -replace '(.{2})', '$1:').TrimEnd(':').ToUpper()
    }
    return $Mac.ToUpper()
}

function Format-FileTime {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -lt 8) { return $null }
    $ft = [BitConverter]::ToInt64($Bytes, 0)
    if ($ft -le 0) { return $null }
    try { return [DateTime]::FromFileTimeUtc($ft).ToLocalTime() }
    catch { return $null }
}

function Format-TimeAgo {
    param([DateTime]$Time)
    $span = (Get-Date) - $Time
    if ($span.TotalMinutes -lt 1)  { return 'just now' }
    if ($span.TotalMinutes -lt 60) { return "$([int]$span.TotalMinutes)m ago" }
    if ($span.TotalHours -lt 24)   { return "$([int]$span.TotalHours)h ago" }
    if ($span.TotalDays -lt 30)    { return "$([int]$span.TotalDays)d ago" }
    return $Time.ToString('yyyy-MM-dd')
}

function Get-BatteryBar {
    param([int]$Percent)
    $filled = [Math]::Round($Percent / 10)
    $empty  = 10 - $filled
    $bar    = ([char]0x2588).ToString() * $filled + ([char]0x2591).ToString() * $empty
    $color  = if ($Percent -le 20) { 'Red' } elseif ($Percent -le 50) { 'Yellow' } else { 'Green' }
    return @{ Bar = $bar; Color = $color; Text = "$Percent%" }
}

# ─── Device Discovery ───

function Get-BTHPORTDevices {
    $basePath = 'HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices'
    if (-not (Test-Path $basePath)) { return @() }

    $devices = @()
    foreach ($key in Get-ChildItem $basePath -ErrorAction SilentlyContinue) {
        $mac = $key.PSChildName.ToUpper()
        $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
        if (-not $props) { continue }

        # Decode Name (REG_BINARY, UTF-8 null-terminated)
        $originalName = ''
        if ($props.PSObject.Properties['Name'] -and $props.Name -is [byte[]]) {
            $nameBytes = $props.Name
            $len = [Array]::IndexOf($nameBytes, [byte]0)
            if ($len -lt 0) { $len = $nameBytes.Length }
            if ($len -gt 0) { $originalName = [System.Text.Encoding]::UTF8.GetString($nameBytes, 0, $len) }
        }

        # Decode FriendlyName override
        $customName = ''
        if ($props.PSObject.Properties['FriendlyName'] -and $props.FriendlyName -is [byte[]]) {
            $fnBytes = $props.FriendlyName
            $len = [Array]::IndexOf($fnBytes, [byte]0)
            if ($len -lt 0) { $len = $fnBytes.Length }
            if ($len -gt 0) { $customName = [System.Text.Encoding]::UTF8.GetString($fnBytes, 0, $len) }
        }

        # LEName (indicates BLE support)
        $leName = ''
        if ($props.PSObject.Properties['LEName'] -and $props.LEName -is [byte[]]) {
            $leBytes = $props.LEName
            $len = [Array]::IndexOf($leBytes, [byte]0)
            if ($len -lt 0) { $len = $leBytes.Length }
            if ($len -gt 0) { $leName = [System.Text.Encoding]::UTF8.GetString($leBytes, 0, $len) }
        }

        # Timestamps
        $lastSeen = $null
        if ($props.PSObject.Properties['LastSeen'] -and $props.LastSeen -is [byte[]]) {
            $lastSeen = Format-FileTime $props.LastSeen
        }
        $lastConnected = $null
        if ($props.PSObject.Properties['LastConnected'] -and $props.LastConnected -is [byte[]]) {
            $lastConnected = Format-FileTime $props.LastConnected
        }

        $devices += [PSCustomObject]@{
            Mac             = $mac
            OriginalName    = $originalName
            CustomName      = $customName
            DisplayName     = if ($customName) { $customName } else { $originalName }
            LEName          = $leName
            HasBLE          = [bool]$leName -or ($props.PSObject.Properties['LEAddressType'] -ne $null)
            ManufacturerId  = if ($props.PSObject.Properties['ManufacturerId']) { $props.ManufacturerId } else { $null }
            LmpVersion      = if ($props.PSObject.Properties['LmpVersion']) { $props.LmpVersion } else { $null }
            LmpSubversion   = if ($props.PSObject.Properties['LmpSubversion']) { $props.LmpSubversion } else { $null }
            COD             = if ($props.PSObject.Properties['COD']) { $props.COD } else { $null }
            LEAppearance    = if ($props.PSObject.Properties['LEAppearance']) { $props.LEAppearance } else { $null }
            LEAddressType   = if ($props.PSObject.Properties['LEAddressType']) { $props.LEAddressType } else { $null }
            VID             = if ($props.PSObject.Properties['VID']) { $props.VID } else { $null }
            PID             = if ($props.PSObject.Properties['PID']) { $props.PID } else { $null }
            LastSeen        = $lastSeen
            LastConnected   = $lastConnected
            RegistryPath    = $key.PSPath
        }
    }
    return $devices
}

function Get-PnPBluetoothDevices {
    $pnpDevices = @()

    $allBT = Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match '^BTHENUM\\DEV_|^BTHLE\\DEV_' }

    foreach ($dev in $allBT) {
        $instId = $dev.InstanceId

        # Extract MAC from InstanceId
        $mac = ''
        if ($instId -match 'DEV_([0-9A-Fa-f]{12})') {
            $mac = $Matches[1].ToUpper()
        }
        if (-not $mac) { continue }

        # Get extended properties
        $allProps = Get-PnpDeviceProperty -InstanceId $instId -ErrorAction SilentlyContinue

        $friendlyName = ($allProps | Where-Object KeyName -eq 'DEVPKEY_Device_FriendlyName').Data
        $category     = ($allProps | Where-Object KeyName -eq 'DEVPKEY_DeviceContainer_Category').Data
        $containerId  = ($allProps | Where-Object KeyName -eq 'DEVPKEY_Device_ContainerId').Data

        # Battery
        $batteryProp  = $allProps | Where-Object KeyName -eq '{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 2'
        $chargingProp = $allProps | Where-Object KeyName -eq '{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 3'
        $batteryLevel = if ($batteryProp -and $batteryProp.Type -ne 'Empty') { $batteryProp.Data } else { $null }
        $isCharging   = if ($chargingProp -and $chargingProp.Type -ne 'Empty') { $chargingProp.Data } else { $null }

        # Formatted MAC
        $fmtMacProp = $allProps | Where-Object KeyName -eq '{A35996AB-11CF-4935-8B61-A6761081ECDF} 12'
        $formattedMac = if ($fmtMacProp -and $fmtMacProp.Type -ne 'Empty') { $fmtMacProp.Data } else { $null }

        $isBLE = $instId -match '^BTHLE\\'

        $pnpDevices += [PSCustomObject]@{
            InstanceId   = $instId
            Mac          = $mac
            FriendlyName = $friendlyName
            Category     = if ($category -is [string[]]) { $category -join ', ' } elseif ($category) { "$category" } else { '' }
            ContainerId  = $containerId
            BatteryLevel = $batteryLevel
            IsCharging   = $isCharging
            FormattedMac = $formattedMac
            IsBLE        = $isBLE
            Status       = $dev.Status
            PnPStatus    = $dev.Status
        }
    }
    return $pnpDevices
}

function Merge-DeviceLists {
    param($BTHPORTDevices, $PnPDevices)

    $merged = @()
    $pnpByMac = @{}

    # Group PnP entries by MAC, dedup by ContainerId
    foreach ($p in $PnPDevices) {
        if (-not $pnpByMac.ContainsKey($p.Mac)) {
            $pnpByMac[$p.Mac] = @()
        }
        $pnpByMac[$p.Mac] += $p
    }

    foreach ($bt in $BTHPORTDevices) {
        $pnpEntries = if ($pnpByMac.ContainsKey($bt.Mac)) { $pnpByMac[$bt.Mac] } else { @() }

        # Pick best PnP entry for display data (prefer one with battery or category)
        $bestPnp = $pnpEntries | Sort-Object { if ($_.BatteryLevel -ne $null) { 0 } else { 1 } } | Select-Object -First 1

        # Collect all PnP instance IDs (needed for renaming all registry entries)
        $allInstanceIds = $pnpEntries | ForEach-Object { $_.InstanceId }

        $category = ''
        if ($bestPnp -and $bestPnp.Category) { $category = $bestPnp.Category }

        $deviceType = Get-DeviceType -COD $bt.COD -Category $category -LEAppearance $bt.LEAppearance

        $merged += [PSCustomObject]@{
            Mac              = $bt.Mac
            DisplayName      = $bt.DisplayName
            OriginalName     = $bt.OriginalName
            CustomName       = $bt.CustomName
            IsRenamed        = [bool]$bt.CustomName
            DeviceType       = $deviceType
            Category         = $category
            ManufacturerId   = $bt.ManufacturerId
            Manufacturer     = if ($bt.ManufacturerId -and $Script:ManufacturerMap.ContainsKey([int]$bt.ManufacturerId)) { $Script:ManufacturerMap[[int]$bt.ManufacturerId] } else { $null }
            LmpVersion       = $bt.LmpVersion
            BluetoothVersion = if ($bt.LmpVersion -ne $null -and $Script:LmpVersionMap.ContainsKey([int]$bt.LmpVersion)) { $Script:LmpVersionMap[[int]$bt.LmpVersion] } else { $null }
            LmpSubversion    = $bt.LmpSubversion
            COD              = $bt.COD
            LEAppearance     = $bt.LEAppearance
            LEAddressType    = $bt.LEAddressType
            HasBLE           = $bt.HasBLE
            VID              = $bt.VID
            PID              = $bt.PID
            LastSeen         = $bt.LastSeen
            LastConnected    = $bt.LastConnected
            BatteryLevel     = if ($bestPnp) { $bestPnp.BatteryLevel } else { $null }
            IsCharging       = if ($bestPnp) { $bestPnp.IsCharging } else { $null }
            ConnectionStatus = 'Unknown'
            RSSI             = $null
            InPnP            = ($pnpEntries.Count -gt 0)
            AllInstanceIds   = $allInstanceIds
            RegistryPath     = $bt.RegistryPath
        }
    }
    return $merged
}

# ─── Device Type Classification ───

function Get-DeviceType {
    param($COD, [string]$Category, $LEAppearance)

    # Priority 1: PnP category
    if ($Category) {
        $cat = $Category.Split('.') | Select-Object -Last 1
        $catMap = @{
            'Headset' = 'Headset'; 'Headphones' = 'Headphones'; 'Speaker' = 'Speaker'
            'Keyboard' = 'Keyboard'; 'Mouse' = 'Mouse'; 'Gamepad' = 'Gamepad'
            'Phone' = 'Phone'; 'Computer' = 'Computer'; 'Laptop' = 'Laptop'
            'Printer' = 'Printer'; 'Camera' = 'Camera'; 'Watch' = 'Smartwatch'
            'Microphone' = 'Microphone'
        }
        foreach ($k in $catMap.Keys) {
            if ($cat -match $k) { return $catMap[$k] }
        }
        if ($Category -match 'Multimedia|Audio') { return 'Audio Device' }
        if ($Category -match 'Input') { return 'Input Device' }
    }

    # Priority 2: COD
    if ($COD) {
        $major = ($COD -shr 8) -band 0x1F
        $minor = ($COD -shr 2) -band 0x3F

        if ($major -eq 4) {
            if ($Script:MinorAudioMap.ContainsKey([int]$minor)) { return $Script:MinorAudioMap[[int]$minor] }
            return 'Audio Device'
        }
        if ($major -eq 5) {
            # Peripheral — check feel bits
            $feel = ($minor -shr 4) -band 0x03
            $sub  = $minor -band 0x0F
            if ($feel -eq 1) { return 'Keyboard' }
            if ($feel -eq 2) { return 'Mouse/Pointing' }
            if ($feel -eq 3) { return 'Combo Keyboard/Mouse' }
            if ($Script:MinorPeripheralMap.ContainsKey([int]$sub)) { return $Script:MinorPeripheralMap[[int]$sub] }
            return 'Peripheral'
        }
        if ($Script:MajorDeviceClassMap.ContainsKey([int]$major)) { return $Script:MajorDeviceClassMap[[int]$major] }
    }

    # Priority 3: BLE Appearance
    if ($LEAppearance) {
        $appCat = ($LEAppearance -shr 6) -band 0x3FF
        $appMap = @{
            1 = 'Phone'; 2 = 'Computer'; 3 = 'Watch'; 4 = 'Clock'
            5 = 'Display'; 15 = 'HID Device'; 17 = 'Running Sensor'
            18 = 'Cycling Sensor'; 49 = 'Pulse Oximeter'; 50 = 'Weight Scale'
        }
        if ($appMap.ContainsKey([int]$appCat)) { return $appMap[[int]$appCat] }
    }

    return 'Bluetooth Device'
}

# ─── Connection Status (WinRT via STA Runspace) ───

function Update-ConnectionStatus {
    param([PSCustomObject[]]$Devices)

    # Build list of MAC addresses as UInt64
    $macList = @()
    foreach ($d in $Devices) {
        $macList += @{ Mac = $d.Mac; HasBLE = $d.HasBLE }
    }

    $scriptBlock = {
        param($macList)
        $results = @{}

        # Load WinRT types
        try {
            [void][Windows.Devices.Bluetooth.BluetoothDevice, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
            [void][Windows.Devices.Bluetooth.BluetoothLEDevice, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
        } catch {
            # WinRT types may already be loaded or unavailable
        }

        # Helper to await WinRT async
        Add-Type -TypeDefinition @"
using System;
using System.Threading;
using Windows.Foundation;
public static class WinRTAwait {
    public static T Await<T>(IAsyncOperation<T> op) {
        var evt = new ManualResetEvent(false);
        op.Completed = delegate { evt.Set(); };
        if (op.Status == AsyncStatus.Started) { evt.WaitOne(3000); }
        if (op.Status == AsyncStatus.Completed) { return op.GetResults(); }
        return default(T);
    }
}
"@ -ReferencedAssemblies @(
            'System.Runtime.WindowsRuntime',
            [Windows.Devices.Bluetooth.BluetoothDevice].Assembly.Location
        ) -ErrorAction SilentlyContinue

        foreach ($entry in $macList) {
            $mac = $entry.Mac
            $macUInt64 = [Convert]::ToUInt64($mac, 16)
            $status = 'Unknown'

            try {
                if ($entry.HasBLE) {
                    $op = [Windows.Devices.Bluetooth.BluetoothLEDevice]::FromBluetoothAddressAsync($macUInt64)
                    $dev = [WinRTAwait]::Await($op)
                } else {
                    $op = [Windows.Devices.Bluetooth.BluetoothDevice]::FromBluetoothAddressAsync($macUInt64)
                    $dev = [WinRTAwait]::Await($op)
                }
                if ($dev) {
                    $status = $dev.ConnectionStatus.ToString()
                    $dev.Dispose()
                }
            } catch {
                $status = 'Unknown'
            }
            $results[$mac] = $status
        }
        return $results
    }

    # Run in STA runspace for WinRT compatibility
    try {
        $runspace = [RunspaceFactory]::CreateRunspace()
        $runspace.ApartmentState = 'STA'
        $runspace.ThreadOptions = 'ReuseThread'
        $runspace.Open()

        $ps = [PowerShell]::Create()
        $ps.Runspace = $runspace
        [void]$ps.AddScript($scriptBlock)
        [void]$ps.AddArgument($macList)

        $statusMap = $ps.Invoke()

        if ($ps.HadErrors) {
            foreach ($e in $ps.Streams.Error) { Write-Verbose "WinRT error: $e" }
        }

        $ps.Dispose()
        $runspace.Close()
        $runspace.Dispose()

        if ($statusMap -and $statusMap -is [hashtable]) {
            foreach ($d in $Devices) {
                if ($statusMap.ContainsKey($d.Mac)) {
                    $d.ConnectionStatus = $statusMap[$d.Mac]
                }
            }
        }
    } catch {
        Write-Verbose "WinRT connection check unavailable: $_"
        # Fall back to PnP status
    }

    return $Devices
}

# ─── RSSI Scanner (BLE only, on-demand) ───

function Get-BLERSSI {
    param([string]$TargetMac, [int]$ScanSeconds = 4)

    $scriptBlock = {
        param($targetMac, $scanSec)

        try {
            [void][Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
        } catch {}

        $rssiValues = [System.Collections.ArrayList]::new()
        $target = $targetMac.ToUpper() -replace ':', ''

        $watcher = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher]::new()
        $watcher.ScanningMode = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEScanningMode]::Active

        $handler = Register-ObjectEvent -InputObject $watcher -EventName Received -Action {
            $args_ = $Event.SourceEventArgs
            $advMac = $args_.BluetoothAddress.ToString('X12')
            if ($advMac -eq $target) {
                [void]$rssiValues.Add($args_.RawSignalStrengthInDBm)
            }
        }

        $watcher.Start()
        Start-Sleep -Seconds $scanSec
        $watcher.Stop()
        Unregister-Event -SourceIdentifier $handler.Name -ErrorAction SilentlyContinue

        if ($rssiValues.Count -gt 0) {
            $avg = ($rssiValues | Measure-Object -Average).Average
            return @{
                Current = $rssiValues[-1]
                Average = [Math]::Round($avg, 1)
                Min     = ($rssiValues | Measure-Object -Minimum).Minimum
                Max     = ($rssiValues | Measure-Object -Maximum).Maximum
                Samples = $rssiValues.Count
            }
        }
        return $null
    }

    Write-Host "  Scanning for BLE signal ($ScanSeconds seconds)..." -ForegroundColor Yellow -NoNewline

    try {
        $runspace = [RunspaceFactory]::CreateRunspace()
        $runspace.ApartmentState = 'STA'
        $runspace.ThreadOptions = 'ReuseThread'
        $runspace.Open()

        $ps = [PowerShell]::Create()
        $ps.Runspace = $runspace
        [void]$ps.AddScript($scriptBlock)
        [void]$ps.AddArgument($TargetMac)
        [void]$ps.AddArgument($ScanSeconds)

        $result = $ps.Invoke() | Select-Object -First 1

        $ps.Dispose()
        $runspace.Close()
        $runspace.Dispose()

        Write-Host "`r$(' ' * 60)`r" -NoNewline
        return $result
    } catch {
        Write-Host ''
        return $null
    }
}

# ─── Rename Functions ───

function Rename-BluetoothDevice {
    param([PSCustomObject]$Device, [string]$NewName)

    $mac = $Device.Mac.ToLower()
    $macUpper = $Device.Mac.ToUpper()

    # 1. BTHPORT — write as REG_BINARY (UTF-8 + null)
    $bthportPath = "HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices\$mac"
    if (Test-Path $bthportPath) {
        $nameBytes = [System.Text.Encoding]::UTF8.GetBytes($NewName + [char]0)
        Set-ItemProperty -Path $bthportPath -Name 'FriendlyName' -Value $nameBytes -Type Binary
    }

    # 2. BTHENUM — write as REG_SZ
    $btheNumBase = "HKLM:\SYSTEM\CurrentControlSet\Enum\BTHENUM"
    if (Test-Path $btheNumBase) {
        Get-ChildItem $btheNumBase -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match $macUpper -or $_.Name -match "DEV_$macUpper" } |
            ForEach-Object {
                $fnProp = Get-ItemProperty -Path $_.PSPath -Name 'FriendlyName' -ErrorAction SilentlyContinue
                if ($fnProp) {
                    Set-ItemProperty -Path $_.PSPath -Name 'FriendlyName' -Value $NewName -Type String
                }
            }
    }

    # 3. BTHLE — write as REG_SZ
    $bthLEBase = "HKLM:\SYSTEM\CurrentControlSet\Enum\BTHLE"
    if (Test-Path $bthLEBase) {
        Get-ChildItem $bthLEBase -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match $macUpper -or $_.PSChildName -match $mac -or $_.Name -match "DEV_" } |
            ForEach-Object {
                $fnProp = Get-ItemProperty -Path $_.PSPath -Name 'FriendlyName' -ErrorAction SilentlyContinue
                if ($fnProp) {
                    Set-ItemProperty -Path $_.PSPath -Name 'FriendlyName' -Value $NewName -Type String
                }
            }
    }
}

function Restore-BluetoothDeviceName {
    param([PSCustomObject]$Device)
    $originalName = $Device.OriginalName
    if (-not $originalName) {
        Write-Host '  No original name on record to restore.' -ForegroundColor Red
        return $false
    }

    $mac = $Device.Mac.ToLower()
    $bthportPath = "HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices\$mac"

    # Clear BTHPORT FriendlyName (set to single null byte = use device-reported name)
    if (Test-Path $bthportPath) {
        Set-ItemProperty -Path $bthportPath -Name 'FriendlyName' -Value ([byte[]](0)) -Type Binary
    }

    # Restore BTHENUM / BTHLE to original name
    Rename-BluetoothDevice -Device $Device -NewName $originalName

    # Re-clear BTHPORT so Windows uses the device name
    if (Test-Path $bthportPath) {
        Set-ItemProperty -Path $bthportPath -Name 'FriendlyName' -Value ([byte[]](0)) -Type Binary
    }

    return $true
}

# ─── Signal Strength Display ───

function Get-SignalBar {
    param([int]$RSSI)
    # RSSI ranges: -30 excellent, -50 good, -70 fair, -90 weak
    $quality = if ($RSSI -ge -40) { 5 }
               elseif ($RSSI -ge -55) { 4 }
               elseif ($RSSI -ge -70) { 3 }
               elseif ($RSSI -ge -85) { 2 }
               else { 1 }

    $bar = ([char]0x2588).ToString() * $quality + ([char]0x2591).ToString() * (5 - $quality)
    $color = switch ($quality) {
        5 { 'Green' }; 4 { 'Green' }; 3 { 'Yellow' }; 2 { 'Red' }; 1 { 'DarkRed' }
    }
    $label = switch ($quality) {
        5 { 'Excellent' }; 4 { 'Good' }; 3 { 'Fair' }; 2 { 'Weak' }; 1 { 'Very Weak' }
    }
    return @{ Bar = $bar; Color = $color; Label = $label; Quality = $quality }
}

# ─── Detail View ───

function Show-DeviceDetails {
    param([PSCustomObject]$Device)

    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host "  $([char]0x25C6) $(if ($Device.IsRenamed) { $Device.DisplayName } else { $Device.OriginalName })" -ForegroundColor Cyan
        if ($Device.IsRenamed) {
            Write-Host "    (originally: $($Device.OriginalName))" -ForegroundColor DarkGray
        }
        Write-Separator

        # ── Identity ──
        Write-SectionHeader 'IDENTITY'
        Write-Field 'Display Name' $Device.DisplayName 'White'
        if ($Device.IsRenamed) {
            Write-Field 'Original Name' $Device.OriginalName 'DarkGray'
        }
        Write-Field 'MAC Address' (Format-MacAddress $Device.Mac) 'Yellow'
        Write-Field 'Device Type' $Device.DeviceType 'Cyan'
        if ($Device.Category) {
            Write-Field 'PnP Category' $Device.Category 'DarkGray'
        }

        # ── Connection ──
        Write-SectionHeader 'CONNECTION'
        $statusColor = switch ($Device.ConnectionStatus) {
            'Connected'    { 'Green' }
            'Disconnected' { 'Yellow' }
            default        { 'DarkGray' }
        }
        Write-Field 'Status' $Device.ConnectionStatus $statusColor
        if ($Device.LastConnected) {
            Write-Field 'Last Connected' "$($Device.LastConnected.ToString('yyyy-MM-dd HH:mm:ss'))  ($(Format-TimeAgo $Device.LastConnected))" 'White'
        }
        if ($Device.LastSeen) {
            Write-Field 'Last Seen' "$($Device.LastSeen.ToString('yyyy-MM-dd HH:mm:ss'))  ($(Format-TimeAgo $Device.LastSeen))" 'DarkGray'
        }
        if (-not $Device.InPnP) {
            Write-Field 'PnP Status' 'Not registered (previously paired)' 'DarkGray'
        }

        # ── Hardware ──
        Write-SectionHeader 'HARDWARE'
        if ($Device.BluetoothVersion) {
            Write-Field 'Bluetooth Version' "v$($Device.BluetoothVersion) (LMP $($Device.LmpVersion))" 'White'
        }
        if ($Device.Manufacturer) {
            Write-Field 'Manufacturer' "$($Device.Manufacturer) (ID: $($Device.ManufacturerId))" 'White'
        } elseif ($Device.ManufacturerId) {
            Write-Field 'Manufacturer ID' "$($Device.ManufacturerId)" 'DarkGray'
        }
        if ($Device.COD) {
            $major = ($Device.COD -shr 8) -band 0x1F
            $minor = ($Device.COD -shr 2) -band 0x3F
            $codHex = '0x{0:X6}' -f $Device.COD
            $majorName = if ($Script:MajorDeviceClassMap.ContainsKey([int]$major)) { $Script:MajorDeviceClassMap[[int]$major] } else { 'Unknown' }
            Write-Field 'Class of Device' "$codHex  ($majorName, minor: $minor)" 'DarkGray'
        }
        if ($Device.HasBLE) {
            $addrType = if ($Device.LEAddressType -eq 0) { 'Public' } elseif ($Device.LEAddressType -eq 1) { 'Random' } else { 'Unknown' }
            Write-Field 'BLE Address Type' $addrType 'DarkGray'
        }
        if ($Device.VID -and $Device.PID) {
            Write-Field 'VID / PID' ('0x{0:X4} / 0x{1:X4}' -f $Device.VID, $Device.PID) 'DarkGray'
        }
        Write-Field 'Radio Type' $(if ($Device.HasBLE) { 'Bluetooth LE (or Dual-Mode)' } else { 'Classic Bluetooth' }) 'White'

        # ── Signal ──
        Write-SectionHeader 'SIGNAL'
        if ($Device.RSSI) {
            $sig = Get-SignalBar $Device.RSSI.Current
            Write-Host "  Signal Strength    " -ForegroundColor Gray -NoNewline
            Write-Host "$($sig.Bar)" -ForegroundColor $sig.Color -NoNewline
            Write-Host "  $($Device.RSSI.Current) dBm  ($($sig.Label))" -ForegroundColor $sig.Color
            Write-Field 'Average RSSI' "$($Device.RSSI.Average) dBm" 'DarkGray'
            Write-Field 'Range' "$($Device.RSSI.Min) to $($Device.RSSI.Max) dBm ($($Device.RSSI.Samples) samples)" 'DarkGray'
        } else {
            if ($Device.HasBLE) {
                Write-Field 'RSSI' 'Not scanned  [press S to scan]' 'DarkGray'
            } else {
                Write-Field 'RSSI' 'N/A (Classic BT only — no passive scanning)' 'DarkGray'
            }
        }

        # ── Power ──
        if ($Device.BatteryLevel -ne $null) {
            Write-SectionHeader 'POWER'
            $bat = Get-BatteryBar $Device.BatteryLevel
            Write-Host "  Battery Level      " -ForegroundColor Gray -NoNewline
            Write-Host "$($bat.Bar)" -ForegroundColor $bat.Color -NoNewline
            Write-Host "  $($bat.Text)" -ForegroundColor $bat.Color
            if ($Device.IsCharging -ne $null) {
                Write-Field 'Charging' $(if ($Device.IsCharging) { 'Yes' } else { 'No' }) $(if ($Device.IsCharging) { 'Green' } else { 'DarkGray' })
            }
        }

        # ── Footer ──
        Write-Host ''
        Write-Separator
        $options = @('[N]ame  = Rename')
        if ($Device.IsRenamed) { $options += '[O]riginal = Restore name' }
        if ($Device.HasBLE) { $options += '[S]ignal = Scan RSSI' }
        $options += '[B]ack'
        Write-Host "  $($options -join '    ')" -ForegroundColor DarkCyan
        Write-Host ''
        Write-Host '  > ' -ForegroundColor Cyan -NoNewline
        $input_ = Read-Host

        switch ($input_.ToUpper()) {
            'N' {
                Write-Host ''
                Write-Host '  Enter new name: ' -ForegroundColor Yellow -NoNewline
                $newName = Read-Host
                if ($newName -and $newName.Trim()) {
                    $newName = $newName.Trim()
                    $utf8Len = [System.Text.Encoding]::UTF8.GetByteCount($newName)
                    if ($utf8Len -gt 248) {
                        Write-Host "  Name too long ($utf8Len bytes). BT spec max is 248 bytes." -ForegroundColor Red
                        Start-Sleep -Seconds 2
                        continue
                    }
                    Write-Host ''
                    Write-Host "  $($Device.DisplayName)" -ForegroundColor DarkGray -NoNewline
                    Write-Host '  -->  ' -ForegroundColor DarkCyan -NoNewline
                    Write-Host $newName -ForegroundColor Green
                    Write-Host ''
                    Write-Host '  Confirm rename? [Y/n]: ' -ForegroundColor Yellow -NoNewline
                    $confirm = Read-Host
                    if ($confirm -ne 'n' -and $confirm -ne 'N') {
                        try {
                            Rename-BluetoothDevice -Device $Device -NewName $newName
                            $Device.DisplayName = $newName
                            $Device.CustomName = $newName
                            $Device.IsRenamed = $true
                            Write-Host ''
                            Write-Host '  Renamed successfully!' -ForegroundColor Green
                            Write-Host '  You may need to reconnect the device or restart Bluetooth.' -ForegroundColor DarkGray
                            Write-Host ''
                            Write-Host '  Restart Bluetooth service now? [y/N]: ' -ForegroundColor Yellow -NoNewline
                            $restart = Read-Host
                            if ($restart -eq 'y' -or $restart -eq 'Y') {
                                Write-Host '  Restarting Bluetooth service...' -ForegroundColor Yellow
                                Restart-Service bthserv -Force -ErrorAction SilentlyContinue
                                Start-Sleep -Seconds 2
                                Write-Host '  Done.' -ForegroundColor Green
                            }
                        } catch {
                            Write-Host "  Error: $_" -ForegroundColor Red
                        }
                        Start-Sleep -Seconds 2
                    }
                }
            }
            'O' {
                if ($Device.IsRenamed) {
                    Write-Host ''
                    Write-Host "  Restore to: $($Device.OriginalName)?" -ForegroundColor Yellow
                    Write-Host '  Confirm? [Y/n]: ' -ForegroundColor Yellow -NoNewline
                    $confirm = Read-Host
                    if ($confirm -ne 'n' -and $confirm -ne 'N') {
                        try {
                            if (Restore-BluetoothDeviceName -Device $Device) {
                                $Device.DisplayName = $Device.OriginalName
                                $Device.CustomName = ''
                                $Device.IsRenamed = $false
                                Write-Host '  Name restored.' -ForegroundColor Green
                            }
                        } catch {
                            Write-Host "  Error: $_" -ForegroundColor Red
                        }
                        Start-Sleep -Seconds 2
                    }
                }
            }
            'S' {
                if ($Device.HasBLE) {
                    $rssi = Get-BLERSSI -TargetMac $Device.Mac
                    if ($rssi) {
                        $Device.RSSI = $rssi
                    } else {
                        Write-Host '  No BLE advertisements detected. Is the device nearby and awake?' -ForegroundColor DarkGray
                        Start-Sleep -Seconds 2
                    }
                }
            }
            'B' { return }
            default { }
        }
    }
}

# ─── Main Menu ───

function Show-DeviceList {
    param([PSCustomObject[]]$Devices)

    Write-Host ''
    $col1 = 4; $col2 = 30; $col3 = 20; $col4 = 14; $col5 = 18; $col6 = 10

    # Header
    $hdr = '  {0,-3} {1,-28} {2,-18} {3,-12} {4,-16} {5}' -f '#', 'DEVICE', 'MAC ADDRESS', 'STATUS', 'TYPE', 'BATTERY'
    Write-Host $hdr -ForegroundColor DarkCyan
    Write-Separator -Width 95

    for ($i = 0; $i -lt $Devices.Count; $i++) {
        $d = $Devices[$i]
        $num = ($i + 1).ToString()
        $name = if ($d.DisplayName.Length -gt 26) { $d.DisplayName.Substring(0, 24) + '..' } else { $d.DisplayName }
        $mac = Format-MacAddress $d.Mac
        if ($mac.Length -gt 17) { $mac = $mac.Substring(0, 17) }
        $status = $d.ConnectionStatus
        $type = if ($d.DeviceType.Length -gt 14) { $d.DeviceType.Substring(0, 13) + '.' } else { $d.DeviceType }

        # Battery display
        $battery = ''
        if ($d.BatteryLevel -ne $null) {
            $battery = "$($d.BatteryLevel)%"
        }

        # Color by status
        $lineColor = switch ($d.ConnectionStatus) {
            'Connected'    { 'Green' }
            'Disconnected' { 'Yellow' }
            default        { if (-not $d.InPnP) { 'DarkGray' } else { 'Gray' } }
        }

        $line = '  {0,-3} {1,-28} {2,-18} {3,-12} {4,-16} ' -f $num, $name, $mac, $status, $type
        Write-Host $line -ForegroundColor $lineColor -NoNewline

        # Battery with color
        if ($d.BatteryLevel -ne $null) {
            $batColor = if ($d.BatteryLevel -le 20) { 'Red' } elseif ($d.BatteryLevel -le 50) { 'Yellow' } else { 'Green' }
            Write-Host $battery -ForegroundColor $batColor
        } else {
            Write-Host '-' -ForegroundColor DarkGray
        }
    }

    Write-Host ''
    Write-Separator -Width 95
}

function Start-BluFang {
    $firstRun = $true

    while ($true) {
        Write-Banner

        if ($firstRun) {
            Write-Host '  Discovering Bluetooth devices...' -ForegroundColor Yellow
            $firstRun = $false
        } else {
            Write-Host '  Refreshing...' -ForegroundColor Yellow
        }

        # Discovery
        $bthport = Get-BTHPORTDevices
        $pnp     = Get-PnPBluetoothDevices
        $devices = Merge-DeviceLists -BTHPORTDevices $bthport -PnPDevices $pnp

        if ($devices.Count -eq 0) {
            Write-Host ''
            Write-Host '  No Bluetooth devices found.' -ForegroundColor Red
            Write-Host '  Make sure Bluetooth is enabled and devices are paired.' -ForegroundColor DarkGray
            Write-Host ''
            Write-Host '  Press any key to exit...' -ForegroundColor DarkCyan
            [void][Console]::ReadKey($true)
            return
        }

        # Connection status check
        Write-Host "  Checking connection status for $($devices.Count) devices..." -ForegroundColor DarkGray
        $devices = Update-ConnectionStatus -Devices $devices

        # Sort: connected first, then by name
        $devices = $devices | Sort-Object @{Expression = { $_.ConnectionStatus -eq 'Connected' }; Descending = $true }, DisplayName

        # Redraw
        Write-Banner
        Show-DeviceList -Devices $devices
        Write-Host "  Enter device # for details   [R]efresh   [Q]uit" -ForegroundColor DarkCyan
        Write-Host ''
        Write-Host '  > ' -ForegroundColor Cyan -NoNewline
        $input_ = Read-Host

        if ($input_ -eq 'Q' -or $input_ -eq 'q') { return }
        if ($input_ -eq 'R' -or $input_ -eq 'r') { continue }

        # Try to parse as device number
        $num = 0
        if ([int]::TryParse($input_, [ref]$num) -and $num -ge 1 -and $num -le $devices.Count) {
            Show-DeviceDetails -Device $devices[$num - 1]
        }
    }
}

# ─── Entry Point ───

try {
    Start-BluFang
} catch {
    Write-Host ''
    Write-Host "  Fatal error: $_" -ForegroundColor Red
    Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor DarkRed
} finally {
    [Console]::ResetColor()
    Write-Host ''
}
