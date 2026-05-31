$mod = "vas_turret_behavior_resurrected"
$pkg = Join-Path $PSScriptRoot "packages\$mod"
$ts  = Get-Date -Format "dd-MM-yyyy_HHmmss"
$zip = Join-Path $PSScriptRoot "packages\${mod}_${ts}.zip"

if (Test-Path $pkg) { Remove-Item -Recurse -Force $pkg }
New-Item -ItemType Directory -Force $pkg | Out-Null

Copy-Item -Force "$PSScriptRoot\content.xml"         "$pkg\content.xml"
Copy-Item -Force "$PSScriptRoot\turret_behavior.lua" "$pkg\turret_behavior.lua"
Copy-Item -Recurse -Force "$PSScriptRoot\md"         "$pkg\md"
Copy-Item -Recurse -Force "$PSScriptRoot\t"          "$pkg\t"

Compress-Archive -Path "$pkg" -DestinationPath $zip -CompressionLevel Optimal

Write-Host "Packed: $zip"
