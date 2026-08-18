# fetch-stt.ps1 - baixa whisper-cli + modelo Maximo (small) para stt\ (ao lado do editor).
# Uso:  powershell -ExecutionPolicy Bypass -File fetch-stt.ps1
# NOTA: manter 100% ASCII (mesmo motivo do build-installer.ps1).
#
# Nao baixa o pacote CUDA (~270 MB): continua sob demanda se o usuario ligar GPU.

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$ver = "v1.9.2"
$zipUrl = "https://github.com/ggml-org/whisper.cpp/releases/download/$ver/whisper-blas-bin-x64.zip"
$hf = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
$dest = Join-Path $PSScriptRoot "stt"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

function Get-IfMissing($url, $out) {
    if (Test-Path $out) {
        $n = (Get-Item $out).Length
        if ($n -gt 1MB) {
            Write-Host "  ja tem $out ($([int]($n/1MB)) MB)" -ForegroundColor DarkGray
            return
        }
    }
    Write-Host "  baixando $url" -ForegroundColor Cyan
    & curl.exe -L --fail --retry 3 --retry-delay 2 -o $out $url
    if ($LASTEXITCODE -ne 0) { throw "Falha no download: $url" }
}

Write-Host "[1/2] Motor Whisper (OpenBLAS)..." -ForegroundColor Cyan
$cli = Join-Path $dest "whisper-cli.exe"
if (-not (Test-Path $cli)) {
    $zip = Join-Path $dest "whisper-cpu.zip"
    Get-IfMissing $zipUrl $zip
    Write-Host "  extraindo..." -ForegroundColor Cyan
    & tar.exe -xf $zip -C $dest
    if ($LASTEXITCODE -ne 0) { throw "Falha ao extrair $zip" }
    Remove-Item $zip -ErrorAction SilentlyContinue
    $found = Get-ChildItem $dest -Recurse -Filter "whisper-cli.exe" | Select-Object -First 1
    if (-not $found) { throw "whisper-cli.exe nao veio no zip" }
    if ($found.DirectoryName -ne $dest) {
        Get-ChildItem $found.DirectoryName -File | ForEach-Object {
            Copy-Item $_.FullName -Destination $dest -Force
        }
    }
} else {
    Write-Host "  ja tem whisper-cli.exe" -ForegroundColor DarkGray
}

Write-Host "[2/2] Modelo Maximo (small, ~466 MB)..." -ForegroundColor Cyan
Get-IfMissing "$hf/ggml-small.bin" (Join-Path $dest "ggml-small.bin")

Write-Host "`nPronto: $dest" -ForegroundColor Green
Get-ChildItem $dest -File | ForEach-Object {
    Write-Host ("  {0,-22} {1,6} MB" -f $_.Name, [int]($_.Length/1MB))
}
