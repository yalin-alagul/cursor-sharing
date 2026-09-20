$ErrorActionPreference = "Stop"
Write-Host "Wi-Fi adapter and Wi-Fi Direct capability"
netsh wlan show drivers | Select-String -Pattern "Wireless Display Supported|Hosted network supported|Radio types supported|Driver"
Write-Host "`nIPv4 addresses on this computer"
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" } | Format-Table InterfaceAlias,IPAddress,PrefixLength
Write-Host "`nAfter the direct link is established, test the Mac listener with:"
Write-Host "Test-NetConnection <mac-ip> -Port 24800"
