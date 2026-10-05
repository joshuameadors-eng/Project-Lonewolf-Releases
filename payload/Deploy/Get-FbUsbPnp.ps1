$ErrorActionPreference = 'Continue'
Write-Output '--- disk drives ---'
Get-CimInstance Win32_DiskDrive | Format-List Index, InterfaceType, Model, PNPDeviceID, Size, Status
Write-Output '--- usb / qualcomm / unknown / problem devices ---'
Get-CimInstance Win32_PnPEntity | Where-Object {
    $_.Name -like '*USB*' -or
    $_.Name -like '*Qualcomm*' -or
    $_.Name -like '*Unknown*' -or
    $_.PNPDeviceID -like '*QCOM*' -or
    $_.PNPDeviceID -like '*USB*' -or
    $_.ConfigManagerErrorCode -ne 0
} | ForEach-Object {
    '{0} | {1} | err={2} | {3}' -f $_.Name, $_.PNPDeviceID, $_.ConfigManagerErrorCode, $_.Status
}
