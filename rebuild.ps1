# Rebuild csound.node with cmake-js on Windows (Csound 7 only; CsoundAC composition is wasm).
#
# Usage:
#   .\rebuild.ps1 [-DNAME=value ...] [extra cmake-js arguments...]
#
# Optional env:
#   CSOUND_ROOT, NW_RUNTIME, NW_RUNTIME_VERSION

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

$UserCmakeDefs = @()
$Passthrough = @()

function Add-CmakeDef([string]$Name, [string]$Value) {
    $script:UserCmakeDefs += "--CD${Name}=${Value}"
}

for ($i = 0; $i -lt $args.Count; $i++) {
    $arg = $args[$i]
    if ($arg -eq "-D") {
        if ($i + 1 -ge $args.Count) {
            throw "rebuild.ps1: missing argument after -D"
        }
        $pair = $args[++$i]
        if ($pair -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            Add-CmakeDef $Matches[1] $Matches[2]
        } else {
            throw "rebuild.ps1: expected NAME=value after -D, got: $pair"
        }
    } elseif ($arg -match '^-D([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
        Add-CmakeDef $Matches[1] $Matches[2]
    } elseif ($arg -match '^--define=(.+)$') {
        $pair = $Matches[1]
        if ($pair -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            Add-CmakeDef $Matches[1] $Matches[2]
        } else {
            $Passthrough += $arg
        }
    } else {
        $Passthrough += $arg
    }
}

$NativeDir = Join-Path $Root "native"
if (Test-Path (Join-Path $NativeDir "package.json")) {
    if (-not (Test-Path (Join-Path $NativeDir "node_modules\node-addon-api"))) {
        Push-Location $NativeDir
        npm install --no-audit --no-fund
        Pop-Location
    }
    Push-Location $NativeDir
    $env:NODE_ADDON_API_INCLUDE = node -e "const p=require('path'); const n=require('node-addon-api'); process.stdout.write(p.resolve(process.cwd(), n.include_dir));"
    Pop-Location
} elseif (Get-Command node -ErrorAction SilentlyContinue) {
    $napi = node -e "try{const p=require('path');const n=require('node-addon-api');process.stdout.write(p.resolve(process.cwd(),n.include_dir));}catch(e){}" 2>$null
    if ($napi) {
        $env:NODE_ADDON_API_INCLUDE = $napi
    }
}

if (-not $env:NODE_ADDON_API_INCLUDE) {
    throw @"
Could not resolve node-addon-api include path.
Add native/package.json and run (cd native; npm install), or install node-addon-api globally.
"@
}

$CmakeExtras = @()

if ($env:CSOUND_ROOT) {
    $CmakeExtras += "--CDCSOUND_ROOT_HINT=$($env:CSOUND_ROOT)"
    Write-Host "Using CSOUND_ROOT=$($env:CSOUND_ROOT)"
}

if ($UserCmakeDefs.Count -gt 0) {
    $CmakeExtras += $UserCmakeDefs
}

Write-Host "NODE_ADDON_API_INCLUDE=$($env:NODE_ADDON_API_INCLUDE)"
Write-Host "Running cmake-js rebuild..." -ForegroundColor Cyan

$CmakeJsArgs = @("rebuild")
if ($env:NW_RUNTIME) {
    $CmakeJsArgs += @("--runtime", $env:NW_RUNTIME)
}
if ($env:NW_RUNTIME_VERSION) {
    $CmakeJsArgs += @("--runtime-version", $env:NW_RUNTIME_VERSION)
}
$CmakeJsArgs += $CmakeExtras
$CmakeJsArgs += $Passthrough

if (Get-Command cmake-js -ErrorAction SilentlyContinue) {
    & cmake-js @CmakeJsArgs
} else {
    & npx --yes cmake-js @CmakeJsArgs
}

exit $LASTEXITCODE
