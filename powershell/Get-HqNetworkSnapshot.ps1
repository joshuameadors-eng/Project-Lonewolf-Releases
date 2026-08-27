#Requires -Version 5.1
# ASCII-only. Live NIC snapshot for the launcher HQ guard (SSID + IPv4 + gateways).
$ErrorActionPreference = 'SilentlyContinue'
$ssid = ''
try {
    $out = [string](& netsh.exe wlan show interfaces 2>&1 | Out-String)
    foreach ($line in ($out -split "`r?`n")) {
        $t = [string]$line
        if ($t -match '(?i)^\s*BSSID\s*:') { continue }
        if ($t -match '(?i)^\s*SSID\s*:\s*(.+)$') {
            $ssid = ([string]$Matches[1]).Trim()
            if (-not [string]::IsNullOrWhiteSpace($ssid)) { break }
        }
    }
} catch {}

$ips = New-Object System.Collections.Generic.List[string]
$gws = New-Object System.Collections.Generic.List[string]
try {
    foreach ($cfg in @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=TRUE' -ErrorAction SilentlyContinue)) {
        foreach ($addr in @($cfg.IPAddress)) {
            $s = [string]$addr
            if ($s -match '^\d+\.\d+\.\d+\.\d+$') { [void]$ips.Add($s) }
        }
        foreach ($gw in @($cfg.DefaultIPGateway)) {
            $s = [string]$gw
            if ($s -match '^\d+\.\d+\.\d+\.\d+$') { [void]$gws.Add($s) }
        }
    }
} catch {}

@{
    ssid = $ssid
    ipv4 = @($ips)
    gateways = @($gws)
} | ConvertTo-Json -Compress
