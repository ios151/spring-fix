# repack.ps1 — regenerate clean spring IPA then inject spring_fix.dylib
# Run from D:\javascript\xosex\spring_fix after placing spring_fix.dylib here

$payloadDir = "D:\javascript\xosex\spring\Payload"
$cleanIpa   = "D:\javascript\xosex\spring_patched_v2.ipa"
$finalIpa   = "D:\javascript\xosex\spring_final.ipa"
$dylib      = "D:\javascript\xosex\spring_fix\spring_fix.dylib"
$ipapatch   = "C:\Users\pc\Downloads\Telegram Desktop\surge\ipapatch\ipapatch.exe"

# Step 1: repack Payload into clean IPA
if (Test-Path $cleanIpa) { Remove-Item $cleanIpa }
Add-Type -AssemblyName System.IO.Compression.FileSystem

$zip = [System.IO.Compression.ZipFile]::Open($cleanIpa, 'Create')
Get-ChildItem -LiteralPath $payloadDir -Recurse -File | ForEach-Object {
    $rel = ("Payload/" + $_.FullName.Substring($payloadDir.Length + 1)).Replace("\", "/")
    try {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $rel, 'Optimal') | Out-Null
    } catch {
        Write-Host "SKIP: $($_.FullName) — $($_.Exception.Message)"
    }
}
$zip.Dispose()
Write-Host "Created: $cleanIpa"

# Step 2: inject spring_fix.dylib
& $ipapatch --input $cleanIpa --dylib $dylib --output $finalIpa --noconfirm
Write-Host "Final IPA: $finalIpa"
