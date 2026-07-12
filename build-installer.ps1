# build-installer.ps1 - recompila o editor em release e gera o instalador.
# Uso:  powershell -ExecutionPolicy Bypass -File build-installer.ps1
# Saida: dist\Output\OdinVideoEditor-Setup.exe
# NOTA: manter este arquivo 100% ASCII! O PowerShell 5.1 le .ps1 sem BOM como ANSI e o
# travessao U+2014 vira uma aspa curva (byte 0x94) que FECHA strings no meio (erro de parse).
#
# Pre-requisitos (uma vez):
#   - Odin no PATH
#   - Inno Setup 6.3+  (winget install JRSoftware.InnoSetup)
#   - dist\ffmpeg.exe e dist\ffprobe.exe presentes (build GPL win64 com nvenc/nvdec/x264/vorbis)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

Write-Host "[1/4] Compilando o recurso do icone (icon.rc -> icon.res)..." -ForegroundColor Cyan
$rc = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\rc.exe" -ErrorAction SilentlyContinue |
      Sort-Object FullName | Select-Object -Last 1
if (-not $rc) { throw "rc.exe (Windows SDK) nao encontrado." }
& $rc.FullName /nologo /fo icon.res icon.rc
if ($LASTEXITCODE -ne 0) { throw "Falha ao compilar icon.rc." }

Write-Host "[2/4] Compilando editor.exe (release, sem console, com icone)..." -ForegroundColor Cyan
odin build . -out:editor.exe -subsystem:windows -o:speed -extra-linker-flags:"icon.res"
if ($LASTEXITCODE -ne 0) { throw "Falha ao compilar o editor." }

# ffmpeg empacotado precisa existir
foreach ($f in @("dist\ffmpeg.exe", "dist\ffprobe.exe")) {
    if (-not (Test-Path $f)) { throw "Faltando $f - copie um build GPL win64 do ffmpeg para dist\." }
}

Write-Host "[3/4] Localizando o Inno Setup (ISCC.exe)..." -ForegroundColor Cyan
$iscc = @(
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw "ISCC.exe nao encontrado. Instale: winget install JRSoftware.InnoSetup" }

Write-Host "[4/4] Compilando o instalador..." -ForegroundColor Cyan
& $iscc setup.iss
if ($LASTEXITCODE -ne 0) { throw "Falha ao compilar o instalador." }

Write-Host "`nPronto: dist\Output\OdinVideoEditor-Setup.exe" -ForegroundColor Green
