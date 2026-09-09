<#
  release.ps1 — ปล่อยเฟิร์มแวร์ OTA ของผำ-เนสท์ ด้วยคำสั่งเดียว
  ใช้: .\release.ps1 -Notes "สรุปสิ่งที่เปลี่ยน" [-NoBuild] [-NoPush]

  ขั้นตอน: อ่าน FW_VERSION จาก config.h -> build (pio run) -> คัดลอก firmware.bin
           -> เขียน firmware.json -> git commit -> git push
  รองรับ Windows PowerShell 5.1 (ไม่ใช้ &&, ไม่ใช้ ternary)

  -ForceVersion N : สำหรับทดสอบสคริปต์เท่านั้น ข้ามการอ่าน config.h และใช้เลข N แทน
                    ห้ามใช้ตอนปล่อยจริง เพราะเลขใน manifest จะไม่ตรงกับเฟิร์มแวร์
#>
[CmdletBinding()]
param(
  [string]$Notes = '',
  [switch]$NoBuild,
  [switch]$NoPush,
  [int]$ForceVersion = 0
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

# ---------- ค่าคงที่ ----------
$RepoDir      = $PSScriptRoot
$FwDir        = 'C:\PhamNest\Firmware_PhamNest'
$ConfigH      = Join-Path $FwDir 'src\config.h'
$Pio          = 'C:\Users\User\.platformio\penv\Scripts\pio.exe'
$BinSrc       = Join-Path $FwDir '.pio\build\waveshare-esp32s3-relay-6ch\firmware.bin'
$BinDst       = Join-Path $RepoDir 'firmware.bin'
$ManifestPath = Join-Path $RepoDir 'firmware.json'
$RepoName     = 'phamnest-firmware'
$Placeholder  = '<USER>'

function Fail([string]$msg) {
  Write-Host ''
  Write-Host "[ผิดพลาด] $msg" -ForegroundColor Red
  exit 1
}
function Step([string]$msg) { Write-Host ''; Write-Host "==> $msg" -ForegroundColor Cyan }
function Warn([string]$msg) { Write-Host "[เตือน] $msg" -ForegroundColor Yellow }

# ---------- ตรวจพารามิเตอร์ ----------
if ([string]::IsNullOrWhiteSpace($Notes)) {
  Fail 'ต้องระบุ -Notes "สรุปสิ่งที่เปลี่ยนในเวอร์ชันนี้" ทุกครั้ง'
}
$Notes = $Notes.Trim() -replace '[\r\n]+', ' '

# ---------- 1. อ่านเลขเวอร์ชันจาก config.h ----------
Step 'อ่านเลขเวอร์ชันเฟิร์มแวร์'
if ($ForceVersion -gt 0) {
  Warn "ใช้ -ForceVersion $ForceVersion (โหมดทดสอบสคริปต์เท่านั้น ไม่ได้อ่าน config.h)"
  $FwVersion    = [int]$ForceVersion
  $FwVersionStr = "$ForceVersion.0.0"
} else {
  if (-not (Test-Path $ConfigH)) { Fail "ไม่พบไฟล์ $ConfigH" }
  $cfg = [System.IO.File]::ReadAllText($ConfigH, [System.Text.Encoding]::UTF8)
  $mVer = [regex]::Match($cfg, '(?m)^\s*#define\s+FW_VERSION\s+(\d+)\s*$')
  $mStr = [regex]::Match($cfg, '(?m)^\s*#define\s+FW_VERSION_STR\s+"([^"]+)"')
  if (-not $mVer.Success) { Fail "หา #define FW_VERSION <เลขจำนวนเต็ม> ใน config.h ไม่เจอ" }
  if (-not $mStr.Success) { Fail "หา #define FW_VERSION_STR `"x.y.z`" ใน config.h ไม่เจอ" }
  $FwVersion    = [int]$mVer.Groups[1].Value
  $FwVersionStr = $mStr.Groups[1].Value
}
Write-Host "    FW_VERSION = $FwVersion   FW_VERSION_STR = $FwVersionStr"

# ---------- 2. ตรวจ manifest เดิม กันลืม bump เวอร์ชัน ----------
Step 'ตรวจ firmware.json เดิม'
$oldVersion = 0
$oldUrl     = ''
if (Test-Path $ManifestPath) {
  try {
    $old = Get-Content -Path $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $oldVersion = [int]$old.version
    $oldUrl     = [string]$old.url
  } catch {
    Warn 'อ่าน firmware.json เดิมไม่ได้ จะถือว่าเวอร์ชันเดิม = 0'
  }
}
Write-Host "    เวอร์ชันใน manifest ปัจจุบัน = $oldVersion"

# ---------- 3. หา GitHub user/repo จาก git remote ----------
Step 'ตรวจ git remote'
$GitUser   = $Placeholder
$GitRepo   = $RepoName
$hasRemote = $false
$remotes = @(git -C $RepoDir remote)
if ($remotes -contains 'origin') {
  $remoteUrl = [string](git -C $RepoDir remote get-url origin | Select-Object -First 1)
  $mR = [regex]::Match($remoteUrl, 'github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?/?$')
  if ($mR.Success) {
    $GitUser   = $mR.Groups[1].Value
    $GitRepo   = $mR.Groups[2].Value
    $hasRemote = $true
    Write-Host "    origin = $remoteUrl  ->  user=$GitUser repo=$GitRepo"
  } else {
    Warn "remote origin ($remoteUrl) ไม่ใช่รูปแบบ GitHub ที่รู้จัก จะใช้ $Placeholder ไปก่อน"
  }
} else {
  Warn "ยังไม่ได้ตั้ง git remote 'origin' — จะเขียน URL เป็น $Placeholder ไปก่อน และ push ไม่ได้"
  Warn "ตั้งได้ด้วย: git remote add origin https://github.com/<ชื่อผู้ใช้>/$RepoName.git"
}
$RawBase    = "https://raw.githubusercontent.com/$GitUser/$GitRepo/main"
$RawBinUrl  = "$RawBase/firmware.bin"
$RawJsonUrl = "$RawBase/firmware.json"

# ---------- 4. กันปล่อยซ้ำเวอร์ชันเดิม ----------
# ข้อยกเว้นเดียว: manifest ยังเป็น <USER> (สถานะเริ่มต้น) แต่ตอนนี้มี remote จริงแล้ว
# และเลขเวอร์ชันเท่ากัน -> อนุญาตให้รันเพื่อแก้ URL ให้ถูกโดยไม่ต้อง bump
$isPlaceholderFix = ($oldUrl -like "*$Placeholder*") -and $hasRemote -and ($oldVersion -eq $FwVersion)
if (($oldVersion -ge $FwVersion) -and (-not $isPlaceholderFix)) {
  Fail ("เวอร์ชันใน config.h ($FwVersion) ไม่มากกว่าเวอร์ชันใน firmware.json ($oldVersion) " +
        "— ต้องเพิ่มเลข FW_VERSION ใน config.h ก่อน ไม่งั้นบอร์ดจะไม่อัปเดต")
}
if ($isPlaceholderFix) {
  Warn "manifest ยังเป็น $Placeholder อยู่ — จะเขียน URL จริงให้ในเวอร์ชันเดิม ($FwVersion) โดยไม่ bump"
}

# ---------- 5. Build ----------
if ($NoBuild) {
  Step 'ข้ามการ build (-NoBuild) ใช้ firmware.bin ที่มีอยู่'
} else {
  Step "build เฟิร์มแวร์ด้วย PlatformIO ($FwDir)"
  if (-not (Test-Path $Pio)) { Fail "ไม่พบ pio.exe ที่ $Pio" }
  Push-Location $FwDir
  $buildOut = @()
  $buildExit = 1
  try {
    $ErrorActionPreference = 'Continue'
    & $Pio run | Tee-Object -Variable buildOut | Out-Host
    $buildExit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = 'Stop'
    Pop-Location
  }
  if ($buildExit -ne 0) { Fail "build ไม่ผ่าน (exit code $buildExit) — ยกเลิกการปล่อยเวอร์ชัน" }
  Write-Host ''
  Write-Host '    สรุปการใช้หน่วยความจำ:' -ForegroundColor Green
  $summary = @($buildOut | Where-Object { "$_" -match '^\s*(RAM|Flash):' })
  if ($summary.Count -eq 0) {
    Warn 'ไม่พบบรรทัดสรุป RAM/Flash ในผลลัพธ์ build'
  } else {
    foreach ($line in $summary) { Write-Host "    $line" -ForegroundColor Green }
  }
}

# ---------- 6. คัดลอก firmware.bin ----------
Step 'คัดลอก firmware.bin เข้ารีโป'
if (-not (Test-Path $BinSrc)) { Fail "ไม่พบไฟล์ build: $BinSrc (ลองรันโดยไม่ใส่ -NoBuild)" }
Copy-Item -Path $BinSrc -Destination $BinDst -Force
$binInfo = Get-Item $BinDst
$binKB = [math]::Round($binInfo.Length / 1024, 1)
Write-Host ("    firmware.bin = {0:N0} ไบต์ ({1} KB)  build เมื่อ {2}" -f $binInfo.Length, $binKB, (Get-Item $BinSrc).LastWriteTime)

# ---------- 7. เขียน firmware.json (UTF-8 ไม่มี BOM — BOM จะทำให้ตัวแยก JSON บนบอร์ดพัง) ----------
Step 'เขียน firmware.json'
$notesFull = "v$FwVersionStr - $Notes"
$notesJson = $notesFull.Replace('\', '\\').Replace('"', '\"')
$json = "{`n" +
        "  `"version`": $FwVersion,`n" +
        "  `"url`": `"$RawBinUrl`",`n" +
        "  `"notes`": `"$notesJson`"`n" +
        "}`n"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($ManifestPath, $json, $utf8NoBom)
Write-Host $json

# ---------- 8. git commit / push ----------
Step 'git commit'
$commitMsg = "release v$FwVersionStr (fw $FwVersion): $Notes"
git -C $RepoDir add -A
if ($LASTEXITCODE -ne 0) { Fail 'git add ไม่สำเร็จ' }
git -C $RepoDir commit -m $commitMsg
if ($LASTEXITCODE -ne 0) { Fail 'git commit ไม่สำเร็จ (อาจไม่มีอะไรเปลี่ยนแปลง)' }

if ($NoPush) {
  Step 'ข้ามการ push (-NoPush) — commit อยู่ในเครื่องแล้ว push เองทีหลังด้วย: git push origin main'
} elseif (-not $hasRemote) {
  Warn 'ไม่มี remote origin จึง push ไม่ได้ — commit อยู่ในเครื่องแล้ว ตั้ง remote แล้วรัน git push -u origin main'
} else {
  Step "git push origin main -> $GitUser/$GitRepo"
  git -C $RepoDir push origin main
  if ($LASTEXITCODE -ne 0) { Fail 'git push ไม่สำเร็จ — ตรวจสิทธิ์/อินเทอร์เน็ต แล้วรัน git push origin main เอง' }
}

# ---------- 9. สรุป ----------
Write-Host ''
Write-Host "ปล่อยเวอร์ชัน v$FwVersionStr (fw $FwVersion) เรียบร้อย" -ForegroundColor Green
Write-Host "  manifest : $RawJsonUrl"
Write-Host "  firmware : $RawBinUrl"
Write-Host "บอร์ดจะดึงอัปเดตเองภายใน 6 ชม. หรือกด 'ตรวจอัปเดตเดี๋ยวนี้' ในหน้าเว็บ" -ForegroundColor Green
exit 0
