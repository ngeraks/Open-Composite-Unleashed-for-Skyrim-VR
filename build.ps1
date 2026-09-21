<#
    Open Composite Unleashed for Skyrim VR - build and package script.

    Usage:
        Edit the Configuration block below, then edit the call list at
        the very bottom of this file to enable or disable stages.

    Must be run from a Visual Studio Developer PowerShell with x64 C++
    tools available, and from the repository root.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ===========================================================================
# Configuration - edit these to taste
# ===========================================================================

# Build configuration: 'Release' or 'Debug'.
$Script:Config = 'Release'

# CMake generator. Change if your Visual Studio version differs.
$Script:Generator = 'Visual Studio 18 2026'

# Architecture. Skyrim VR is x64.
$Script:Arch = 'x64'

# vcpkg triplet for the SKSE plugin.
$Script:VcpkgTriplet = 'x64-windows-static-md'

# Where the assembled mod package goes, relative to the repo root.
$Script:OutputDir = 'out/OCU-package'

$Script:DeployTarget = 'D:\MGO-rc3-install\mods\ocu'

# Runtime build: enable developer DAPA recording controls?
$Script:DapaCapture = $false

# ===========================================================================
# Derived paths - do not edit
# ===========================================================================

$Script:RepoRoot     = $PSScriptRoot
$Script:RuntimeDir   = Join-Path $RepoRoot 'OpenCompositeSkyrimVR'
$Script:PluginDir    = Join-Path $RepoRoot 'OpenCompositeInput- Skyrim SKSE\OpenCompositeInput'
$Script:Configurator = Join-Path $RepoRoot 'OpenCompositeSkyrimVR\OC Unleashed Configurator\OpenCompositeConfigurator.csproj'
$Script:KeyboardStu  = Join-Path $RepoRoot 'OpenCompositeSkyrimVR\OCU Keyboard Studio\OCUKeyboardStudio.csproj'

$Script:RuntimeBuild = Join-Path $RuntimeDir 'build'
$Script:PluginBuild  = Join-Path $PluginDir  'build\vs-release'
$Script:ToolsOut     = Join-Path $RepoRoot   'out'
$Script:PackageRoot  = Join-Path $RepoRoot   $OutputDir

# ===========================================================================
# Logging helpers
# ===========================================================================

function Write-Stage {
    param([string]$Message)
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}

function Write-Ok    { param([string]$m) Write-Host "  [ok]   $m" -ForegroundColor Green }
function Write-Warn2 { param([string]$m) Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Write-Err2  { param([string]$m) Write-Host "  [err]  $m" -ForegroundColor Red }
function Write-Info  { param([string]$m) Write-Host "  [info] $m" -ForegroundColor Gray }

function Invoke-Checked {
    param(
        [string]$Command,
        [string[]]$Arguments,
        [string]$What
    )
    Write-Info "$Command $($Arguments -join ' ')"
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$What failed with exit code $LASTEXITCODE"
    }
}

function Test-FileExists {
    param([string]$Path, [string]$Purpose)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Err2 "Missing: $Path"
        if ($Purpose) { Write-Err2 "  ($Purpose)" }
        return $false
    }
    return $true
}

function Test-DirExists {
    param([string]$Path, [string]$Purpose)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Write-Err2 "Missing directory: $Path"
        if ($Purpose) { Write-Err2 "  ($Purpose)" }
        return $false
    }
    return $true
}

# ===========================================================================
# Stage 0 - Preflight
# ===========================================================================

function Test-Preflight {
    Write-Stage 'Preflight checks'

    $missingCritical = $false

    # Working directory must be the repo root.
    if (-not (Test-Path -LiteralPath $RuntimeDir -PathType Container)) {
        Write-Err2 "Script must be run from the repository root."
        Write-Err2 "Expected to find: $RuntimeDir"
        return $false
    }

    # Required executables.
    foreach ($exe in 'cmake','dotnet') {
        $cmd = Get-Command $exe -ErrorAction SilentlyContinue
        if (-not $cmd) {
            Write-Err2 "Required tool not found on PATH: $exe"
            $missingCritical = $true
        } else {
            Write-Ok "$exe found: $($cmd.Source)"
        }
    }

    # Python is invoked during runtime header/stub generation.
    if (-not (Get-Command 'python' -ErrorAction SilentlyContinue)) {
        Write-Warn2 "python not found on PATH. The runtime build invokes Python for header and stub generation."
    }

    # C++ toolchain.
    if (-not (Get-Command 'cl.exe' -ErrorAction SilentlyContinue)) {
        Write-Err2 "cl.exe not found on PATH. Run this script from a Visual Studio Developer PowerShell."
        $missingCritical = $true
    } else {
        Write-Ok "MSVC toolchain available: $((Get-Command cl.exe).Source)"
    }

    # CMake generator check (best effort).
    $cmakeGen = & cmake --help 2>$null | Select-String -SimpleMatch $Generator
    if (-not $cmakeGen) {
        Write-Warn2 "CMake does not list generator '$Generator'."
        Write-Warn2 "If configure fails, install that Visual Studio version or edit `$Script:Generator."
    }

    if ($missingCritical) {
        return $false
    }
    return $true
}


function Fetch-Nvapi{
    # --- 1. NVAPI x64 import library ---
    # NVIDIA publishes this in their public nvapi repo (MIT-licensed).
    $nvapiDir   = Join-Path $RuntimeDir 'libs\nvapi\amd64'
    $nvapiTarget = Join-Path $nvapiDir 'nvapi64.lib'
    foreach ($d in @($nvapiDir)) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
    if (Test-Path -LiteralPath $nvapiTarget -PathType Leaf) {
        Write-Ok 'nvapi64.lib already present.'
    } else {
        $nvapiUrl = 'https://raw.githubusercontent.com/NVIDIA/nvapi/main/amd64/nvapi64.lib'
        Write-Info "Downloading nvapi64.lib"
        try {
            Invoke-WebRequest -Uri $nvapiUrl -OutFile $nvapiTarget -UseBasicParsing
        } catch {
            throw "Failed to download nvapi64.lib from $nvapiUrl - $_"
        }
        if (-not (Test-FileExists -Path $nvapiTarget -Purpose 'NVAPI x64 import library')) {
            throw 'NVAPI download produced no file.'
        }
        Write-Ok 'nvapi64.lib downloaded.'
    }
}

function Fetch-Vulcan {
    # ---  Vulkan loader import libraries ---
    # The LunarG SDK installer is large and system-wide. Instead we
    # regenerate vulkan-1.lib from the canonical loader.def published
    # by Khronos, using MSVC's lib.exe (already on PATH in a Developer
    # PowerShell). The generated import library links against the
    # system-provided vulkan-1.dll at runtime.
    $vkLibDir   = Join-Path $RuntimeDir 'libs\vulkan\Lib'
    $vkLib32Dir = Join-Path $RuntimeDir 'libs\vulkan\Lib32'
    $vkIncDir   = Join-Path $RuntimeDir 'libs\vulkan\Include'
    foreach ($d in @($vkIncDir, $vkLibDir, $vkLib32Dir)) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
    $vkX64 = Join-Path $vkLibDir   'vulkan-1.lib'
    $vkX86 = Join-Path $vkLib32Dir 'vulkan-1.lib'

    $needX64 = -not (Test-Path -LiteralPath $vkX64 -PathType Leaf)
    $needX86 = -not (Test-Path -LiteralPath $vkX86 -PathType Leaf)

    if (-not $needX64 -and -not $needX86) {
        Write-Ok 'vulkan-1.lib already present (x64 and x86).'
    } else {
        $libExe = (Get-Command 'lib.exe' -ErrorAction SilentlyContinue).Source
        if (-not $libExe) {
            throw 'lib.exe not found. Run this script from a Visual Studio Developer PowerShell.'
        }

        # Download the .def once.
        # $defUrl  = 'https://raw.githubusercontent.com/KhronosGroup/Vulkan-Loader/main/loader/loader.def'
        $defUrl = 'https://raw.githubusercontent.com/KhronosGroup/Vulkan-Loader/main/loader/vulkan-1.def'
        # $defFile = Join-Path $env:TEMP 'vulkan-loader.def'
        $defFile = Join-Path $env:TEMP 'vulkan-1.def'

        Write-Info 'Downloading Vulkan loader.def'
        try {
            Invoke-WebRequest -Uri $defUrl -OutFile $defFile -UseBasicParsing
        } catch {
            throw "Failed to download loader.def from $defUrl - $_"
        }

        if ($needX64) {
            Write-Info 'Generating vulkan-1.lib (x64)'
            & $libExe /nologo "/def:$defFile" "/out:$vkX64" '/machine:x64'
            if ($LASTEXITCODE -ne 0) { throw 'lib.exe failed for x64 Vulkan import library.' }
            Write-Ok 'vulkan-1.lib (x64) generated.'
        }

        if ($needX86) {
            Write-Info 'Generating vulkan-1.lib (x86)'
            & $libExe /nologo "/def:$defFile" "/out:$vkX86" '/machine:x86'
            if ($LASTEXITCODE -ne 0) { throw 'lib.exe failed for x86 Vulkan import library.' }
            Write-Ok 'vulkan-1.lib (x86) generated.'
        }
    }

    # -----------------------------------------------------------------------
    # 3. Vulkan headers
    #
    # The Khronos Vulkan-Headers repo splits headers across several
    # top-level folders: vulkan/, vk_video/, and a few others. Copy the
    # whole include/ tree rather than just vulkan/, or vulkan_core.h
    # will fail to find its vk_video/ includes.
    # -----------------------------------------------------------------------

    $vkHeader = Join-Path $vkIncDir 'vulkan\vulkan.h'
    Write-Info 'Fetching Vulkan headers from KhronosGroup/Vulkan-Headers'
    $headersZip  = Join-Path $env:TEMP 'vulkan-headers.zip'
    $headersUrl  = 'https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/heads/main.zip'
    $extractRoot = Join-Path $env:TEMP 'vulkan-headers-extract'

    try {
        Invoke-WebRequest -Uri $headersUrl -OutFile $headersZip -UseBasicParsing
    } catch {
        throw "Failed to download Vulkan headers - $_"
    }

    if (Test-Path -LiteralPath $extractRoot) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force
    }
    Expand-Archive -LiteralPath $headersZip -DestinationPath $extractRoot -Force

    $srcInclude = Join-Path $extractRoot 'Vulkan-Headers-main\include'
    if (-not (Test-Path -LiteralPath $srcInclude -PathType Container)) {
        throw 'Unexpected Vulkan-Headers archive layout.'
    }

    if (-not (Test-Path -LiteralPath $vkIncDir)) {
        New-Item -ItemType Directory -Path $vkIncDir -Force | Out-Null
    }

    # Copy every top-level folder from the archive's include/ into
    # the destination, overwriting anything already there.
    Get-ChildItem -LiteralPath $srcInclude -Directory | ForEach-Object {
        $dest = Join-Path $vkIncDir $_.Name
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Recurse -Force
        Write-Ok "Vulkan headers: $($_.Name)/"
    }
}

function Fetch-Dotnet {
    # Already have a compatible SDK on PATH?
    $minMajor = 9
    $dotnet = Get-Command 'dotnet' -ErrorAction SilentlyContinue
    if ($dotnet) {
        $sdks = & dotnet --list-sdks 2>$null
        foreach ($line in $sdks) {
            if ($line -match '^(\d+)\.' -and [int]$Matches[1] -ge $minMajor) {
                Write-Ok "Compatible .NET SDK: $line"
                return
            }
        }
        Write-Warn2 "dotnet is on PATH but no SDK >= $minMajor.x was found."
    } else {
        Write-Warn2 'dotnet not found on PATH.'
    }

    # Local install directory used by the dotnet-install script.
    $installDir = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet'

    # If we previously installed locally, pick it up.
    $localDotnet = Join-Path $installDir 'dotnet.exe'
    if (Test-Path -LiteralPath $localDotnet -PathType Leaf) {
        $localSdks = & $localDotnet --list-sdks 2>$null
        foreach ($line in $localSdks) {
            if ($line -match '^(\d+)\.' -and [int]$Matches[1] -ge $minMajor) {
                $env:DOTNET_ROOT = $installDir
                $env:PATH = "$installDir;$env:PATH"
                Write-Ok "Using local .NET SDK: $line"
                return
            }
        }
    }

    # Otherwise, fetch and run Microsoft's dotnet-install script.
    Write-Info "Installing .NET SDK $minMajor.0 to $installDir"

    $scriptPath = Join-Path $env:TEMP 'dotnet-install.ps1'
    $scriptUrl  = 'https://dot.net/v1/dotnet-install.ps1'

    try {
        Invoke-WebRequest -Uri $scriptUrl -OutFile $scriptPath -UseBasicParsing
    } catch {
        throw "Failed to download dotnet-install.ps1 from $scriptUrl - $_"
    }

    & powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath `
        -Channel "$minMajor.0" `
        -InstallDir $installDir

    if ($LASTEXITCODE -ne 0) {
        throw "dotnet-install.ps1 failed with exit code $LASTEXITCODE."
    }

    if (-not (Test-Path -LiteralPath $localDotnet -PathType Leaf)) {
        throw "dotnet-install.ps1 reported success but $localDotnet is missing."
    }

    # Pick up the new install for this session.
    $env:DOTNET_ROOT = $installDir
    $env:PATH = "$installDir;$env:PATH"
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $dotnetDir = "$env:LOCALAPPDATA\Microsoft\dotnet"
    if ($userPath -notlike "*$dotnetDir*") {
        [Environment]::SetEnvironmentVariable('PATH', "$dotnetDir;$userPath", 'User')
    }
    $installed = & $localDotnet --list-sdks 2>$null
    Write-Ok ".NET SDK installed. Available SDKs:"
    foreach ($line in $installed) {
        Write-Info "  $line"
    }
}

# ===========================================================================
# Stage 0d - Fetch CommonLibSSE-NG (SKSE plugin dependency)
# ===========================================================================
# ===========================================================================
# Stage 0c - Fetch vcpkg (SKSE plugin dependency)
# ===========================================================================

function Fetch-Vcpkg {

    $vcpkgDir = Join-Path $RuntimeDir 'libs\vcpkg'

    # Already valid via environment variable?
    if ($env:VCPKG_ROOT -and (Test-Path -LiteralPath (Join-Path $env:VCPKG_ROOT 'vcpkg.exe') -PathType Leaf)) {
        Write-Ok "VCPKG_ROOT already set: $env:VCPKG_ROOT"
        return
    }

    $vcpkgExe = Join-Path $vcpkgDir 'vcpkg.exe'

    if (Test-Path -LiteralPath $vcpkgExe -PathType Leaf) {
        Write-Ok "vcpkg already present at $vcpkgDir"
    } else {
        if (Test-Path -LiteralPath $vcpkgDir) {
            throw "Directory exists but vcpkg.exe is missing: $vcpkgDir - remove it and re-run."
        }
        if (-not (Test-Path -LiteralPath $depsDir)) {
            New-Item -ItemType Directory -Path $depsDir -Force | Out-Null
        }

        Write-Info "Cloning vcpkg to $vcpkgDir"
        git clone --depth 1 'https://github.com/microsoft/vcpkg.git' $vcpkgDir
        if ($LASTEXITCODE -ne 0) { throw 'Failed to clone vcpkg.' }
        Write-Ok 'vcpkg cloned.'
    }

    if (-not (Test-Path -LiteralPath $vcpkgExe -PathType Leaf)) {
        Write-Info 'Bootstrapping vcpkg'
        $bootstrap = Join-Path $vcpkgDir 'bootstrap-vcpkg.bat'
        if (-not (Test-Path -LiteralPath $bootstrap -PathType Leaf)) {
            throw "bootstrap-vcpkg.bat not found at $bootstrap."
        }
        & cmd /c "`"$bootstrap`" -disableMetrics"
        if ($LASTEXITCODE -ne 0) { throw 'vcpkg bootstrap failed.' }
    }

    if (-not (Test-Path -LiteralPath $vcpkgExe -PathType Leaf)) {
        throw "vcpkg.exe missing after bootstrap: $vcpkgExe"
    }

    $env:VCPKG_ROOT = $vcpkgDir
    Write-Ok "VCPKG_ROOT = $vcpkgDir"
}
function Add-VcpkgBaseline {
    param([string]$VcpkgDir)
    # Point at the bundled vcpkg
    $env:VCPKG_ROOT = 'C:\Program Files\Microsoft Visual Studio\18\Community\VC\vcpkg'

    # Run from the plugin directory
    cd "OpenCompositeInput- Skyrim SKSE\OpenCompositeInput"

    # Let vcpkg write the baseline for you
    & "$env:VCPKG_ROOT\vcpkg.exe" x-update-baseline --add-initial-baseline

    $pluginManifestDir = Join-Path $RepoRoot 'OpenCompositeInput- Skyrim SKSE\OpenCompositeInput'
    $manifestPath      = Join-Path $pluginManifestDir 'vcpkg.json'

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Write-Warn2 "No vcpkg.json found at $pluginManifestDir - skipping baseline."
        return
    }

    # If a baseline already exists (either in vcpkg.json or in
    # vcpkg-configuration.json), there's nothing to do.
    $manifestJson = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifestJson.'builtin-baseline') {
        Write-Ok 'builtin-baseline already present in vcpkg.json.'
        return
    }

    $configPath = Join-Path $pluginManifestDir 'vcpkg-configuration.json'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        Write-Ok 'vcpkg-configuration.json already present in plugin directory.'
        return
    }

    $vcpkgExe = Join-Path $VcpkgDir 'vcpkg.exe'
    if (-not (Test-Path -LiteralPath $vcpkgExe -PathType Leaf)) {
        throw "vcpkg.exe not found at $vcpkgExe"
    }

    Write-Info 'Adding builtin-baseline via vcpkg x-update-baseline'

    Push-Location $pluginManifestDir
    try {
        & $vcpkgExe x-update-baseline --add-initial-baseline
        if ($LASTEXITCODE -ne 0) {
            throw "vcpkg x-update-baseline failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }

    # Re-read to confirm.
    $manifestJson = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if (-not $manifestJson.'builtin-baseline') {
        throw 'vcpkg x-update-baseline reported success but no baseline was written.'
    }
    Write-Ok "builtin-baseline = $($manifestJson.'builtin-baseline')"
}
# ===========================================================================
# Stage 0d - Fetch CommonLibSSE-NG (SKSE plugin dependency)
# ===========================================================================

function Fetch-CommonLibSSE {
    $env:VCPKG_CMAKE_VS_GENERATOR = 'Visual Studio 18 2026'
    $clDir = Join-Path $RuntimeDir 'libs\CommonLibSSE-NG'
    # Already valid via environment variable?
    if ($env:COMMONLIBSSE_ROOT) {
        $clCmake = Join-Path $env:COMMONLIBSSE_ROOT 'CMakeLists.txt'
        if (Test-Path -LiteralPath $clCmake -PathType Leaf) {
            Write-Ok "COMMONLIBSSE_ROOT already set: $env:COMMONLIBSSE_ROOT"
           return
        }
        Write-Warn2 "COMMONLIBSSE_ROOT is set but does not look valid: $env:COMMONLIBSSE_ROOT"
    }

    $clCmake = Join-Path $clDir 'CMakeLists.txt'

    if (-not (Test-Path -LiteralPath $clCmake -PathType Leaf)) {
        if (Test-Path -LiteralPath $clDir) {
            throw "Directory exists but CMakeLists.txt is missing: $clDir - remove it and re-run."
        }

        Write-Info "Cloning CommonLibSSE-NG to $clDir"
        git clone --recursive 'https://github.com/alandtse/CommonLibSSE-NG.git' $clDir
        if ($LASTEXITCODE -ne 0) { throw 'Failed to clone CommonLibSSE-NG.' }
        Write-Ok 'CommonLibSSE-NG cloned.'
    } else {
        Write-Ok "CommonLibSSE-NG already present at $clDir"
    }

    $required = @(
        'CMakeLists.txt',
        'cmake\CommonLibSSE.cmake',
        'extern\openvr'
    )
    $missing = @()
    foreach ($item in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $clDir $item))) {
            $missing += $item
        }
    }

    if ($missing.Count -gt 0) {
        Write-Warn2 "CommonLibSSE-NG tree incomplete. Missing: $($missing -join ', ')"
        Write-Warn2 'Attempting git submodule update --init --recursive...'
        Push-Location $clDir
        try {
            git submodule update --init --recursive
            if ($LASTEXITCODE -ne 0) { throw 'git submodule update failed.' }
        } finally {
            Pop-Location
        }

        foreach ($item in $required) {
            if (-not (Test-Path -LiteralPath (Join-Path $clDir $item))) {
                throw "CommonLibSSE-NG still missing '$item' after submodule update."
            }
        }
        Write-Ok 'Submodules populated.'
    }

    git checkout v4.7.1
    git submodule update --init --recursive

    $env:COMMONLIBSSE_ROOT = $clDir
    Write-Ok "COMMONLIBSSE_ROOT = $clDir"
}
# ===========================================================================
# Stage 0b - Fetch vendor dependencies
# ===========================================================================
function Fetch-Dependencies {
    Write-Stage 'Fetching vendor SDK dependencies'
    # Fetch-Nvapi
    # Fetch-Vulcan
    # Fetch-Dotnet
    ### Fetch-Vcpkg #just use preinstalled and addbaseline if you like
    # Add-VcpkgBaseline 
    Fetch-CommonLibSSE 
    Write-Ok 'All vendor dependencies ready.'
}

# ===========================================================================
# Stage 1 - Runtime
# ===========================================================================

function Build-Runtime {
    Write-Stage "Building runtime ($Generator, $Arch, $Config)"

    # Vendor import libraries are not tracked in Git and must be supplied.
    $vendorLibs = @(
        @{ Path = Join-Path $RuntimeDir 'libs\nvapi\amd64\nvapi64.lib';
           Note = 'NVIDIA NVAPI x64 import library' },
        @{ Path = Join-Path $RuntimeDir 'libs\vulkan\Lib\vulkan-1.lib';
           Note = 'Vulkan loader x64 import library' },
        @{ Path = Join-Path $RuntimeDir 'libs\vulkan\Lib32\vulkan-1.lib';
           Note = 'Vulkan loader x86 import library' }
    )
    $vendorOk = $true
    foreach ($v in $vendorLibs) {
        if (-not (Test-FileExists -Path $v.Path -Purpose $v.Note)) {
            $vendorOk = $false
        }
    }
    if (-not $vendorOk) {
        throw 'Vendor SDK import libraries must be supplied before configuring the runtime. See the build documentation for their source SDKs.'
    }
    Write-Ok 'All vendor import libraries present.'

    $dapa = if ($DapaCapture) { 'ON' } else { 'OFF' }
    if ($DapaCapture) {
        Write-Warn2 'OCU_DAPA_CAPTURE=ON - this build includes developer recording controls.'
    }

    Invoke-Checked -Command 'cmake' -What 'Runtime configure' -Arguments @(
        '-S', $RuntimeDir,
        '-B', $RuntimeBuild,
        '-G', $Generator,
        '-A', $Arch,
        "-DOCU_DAPA_CAPTURE=$dapa"
    )

    Invoke-Checked -Command 'cmake' -What 'Runtime build' -Arguments @(
        '--build', $RuntimeBuild,
        '--config', $Config,
        '--target', 'OCOVR',
        '--parallel'
    )

    $vrclient = Join-Path $RuntimeBuild "bin\$Config\vrclient_x64.dll"
    if (-not (Test-FileExists -Path $vrclient -Purpose 'runtime DLL')) {
        throw "Runtime build reported success but $vrclient is missing."
    }
    Write-Ok "Runtime: $vrclient"
}

# ===========================================================================
# Stage 2 - SKSE plugin
# ===========================================================================

function Build-Plugin {
    Write-Stage "Building SKSE plugin ($Generator, $Arch, $Config)"
    $env:VCPKG_CMAKE_VS_GENERATOR = 'Visual Studio 18 2026'
    $env:CMAKE_GENERATOR = 'Visual Studio 18 2026'
    $env:VCPKG_KEEP_ENV_VARS = 'CMAKE_GENERATOR'
    if (-not $env:VCPKG_ROOT) {
        throw 'VCPKG_ROOT is not set. Required for the SKSE plugin build.'
    }
    if (-not (Test-DirExists -Path $env:VCPKG_ROOT -Purpose 'vcpkg checkout')) {
        throw "VCPKG_ROOT does not point at a directory: $env:VCPKG_ROOT"
    }

    if (-not $env:COMMONLIBSSE_ROOT) {
        throw 'COMMONLIBSSE_ROOT is not set. Required for the SKSE plugin build.'
    }
    if (-not (Test-DirExists -Path $env:COMMONLIBSSE_ROOT -Purpose 'CommonLibSSE-NG/CommonLibVR source tree')) {
        throw "COMMONLIBSSE_ROOT does not point at a directory: $env:COMMONLIBSSE_ROOT"
    }
    if (-not (Test-FileExists -Path (Join-Path $env:COMMONLIBSSE_ROOT 'CMakeLists.txt') -Purpose 'CommonLibSSE CMakeLists.txt')) {
        throw 'COMMONLIBSSE_ROOT does not look like a CommonLibSSE source tree.'
    }
    if (-not (Test-FileExists -Path (Join-Path $env:COMMONLIBSSE_ROOT 'cmake\CommonLibSSE.cmake') -Purpose 'CommonLibSSE.cmake glue file')) {
        throw 'COMMONLIBSSE_ROOT is missing cmake\CommonLibSSE.cmake.'
    }

    $vcpkgToolchain = Join-Path $env:VCPKG_ROOT 'scripts\buildsystems\vcpkg.cmake'

    Invoke-Checked -Command 'cmake' -What 'Plugin configure' -Arguments @(
        '-S', $PluginDir,
        '-B', $PluginBuild,
        '-G', $Generator,
        '-A', $Arch,
        "-DCMAKE_TOOLCHAIN_FILE=$vcpkgToolchain",
        "-DCOMMONLIBSSE_ROOT=$env:COMMONLIBSSE_ROOT",
        "-DVCPKG_TARGET_TRIPLET=$VcpkgTriplet",
        "-DVCPKG_HOST_TRIPLET=$VcpkgTriplet"
    )

    Invoke-Checked -Command 'cmake' -What 'Plugin build' -Arguments @(
        '--build', $PluginBuild,
        '--config', $Config,
        '--target', 'OpenCompositeInput',
        '--parallel'
    )

    $pluginDll = Join-Path $PluginBuild "$Config\OpenCompositeInput.dll"
    if (-not (Test-FileExists -Path $pluginDll -Purpose 'plugin DLL')) {
        throw "Plugin build reported success but $pluginDll is missing."
    }
    Write-Ok "Plugin: $pluginDll"
}

# ===========================================================================
# Stage 3 - Desktop tools
# ===========================================================================

function Publish-Tools {
    Write-Stage 'Publishing desktop tools (.NET, self-contained win-x64)'

    $configuratorOut = Join-Path $ToolsOut 'Configurator'
    $keyboardOut     = Join-Path $ToolsOut 'KeyboardStudio'
    $env:DOTNET_ROOT = "$env:LOCALAPPDATA\Microsoft\dotnet"
    $env:PATH = "$env:DOTNET_ROOT;$env:PATH"
    dotnet --list-sdks

    Invoke-Checked -Command 'dotnet' -What 'Configurator publish' -Arguments @(
        'publish', $Configurator,
        '-c', $Config,
        '-r', 'win-x64',
        '--self-contained', 'true',
        '-o', $configuratorOut
    )

    Invoke-Checked -Command 'dotnet' -What 'Keyboard Studio publish' -Arguments @(
        'publish', $KeyboardStu,
        '-c', $Config,
        '-r', 'win-x64',
        '--self-contained', 'true',
        '-o', $keyboardOut
    )

    Write-Ok "Configurator:    $configuratorOut"
    Write-Ok "Keyboard Studio: $keyboardOut"
}

# ===========================================================================
# Stage 4 - Assemble mod package
# ===========================================================================
function Package-Mod {
    Write-Stage "Assembling mod package at $PackageRoot"

    $OfficialPackageRoot = Join-Path $RepoRoot 'ocu_old'
    if (-not (Test-Path -LiteralPath $OfficialPackageRoot)) {
        throw "Official package base not found at $OfficialPackageRoot. Set `$Script:OfficialPackageRoot to an extracted OCU archive."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $OfficialPackageRoot 'root'))) {
        throw "Base package looks wrong - no 'root' folder under $OfficialPackageRoot."
    }

    # Preserve user config across repackages.
    $savedIni = $null
    $iniPath  = Join-Path $PackageRoot 'root\opencomposite.ini'
    if (Test-Path -LiteralPath $iniPath -PathType Leaf) {
        $savedIni = Get-Content -LiteralPath $iniPath -Raw
        Write-Warn2 'Preserving existing root\opencomposite.ini.'
    }

    # Wipe and re-seed from the official base.
    if (Test-Path -LiteralPath $PackageRoot) {
        Remove-Item -LiteralPath $PackageRoot -Recurse -Force
    }
    Copy-Item -LiteralPath $OfficialPackageRoot -Destination $PackageRoot -Recurse -Force
    Write-Ok "Base copied from $OfficialPackageRoot"

    # -----------------------------------------------------------------------
    # Overlay built binaries.
    # -----------------------------------------------------------------------

    # Runtime: built vrclient_x64.dll -> root/openvr_api.dll
    $vrclient = Join-Path $RuntimeBuild "bin\$Config\vrclient_x64.dll"
    if (Test-Path -LiteralPath $vrclient) {
        Copy-Item -LiteralPath $vrclient -Destination (Join-Path $PackageRoot 'root\openvr_api.dll') -Force
        Write-Ok 'root/openvr_api.dll (rebuilt)'
    } else {
        Write-Warn2 "Runtime DLL not found at $vrclient - keeping base version."
    }

    # SKSE plugin
    $pluginDll = Join-Path $PluginBuild "$Config\OpenCompositeInput.dll"
    if (Test-Path -LiteralPath $pluginDll) {
        Copy-Item -LiteralPath $pluginDll -Destination (Join-Path $PackageRoot 'SKSE\Plugins\OpenCompositeInput.dll') -Force
        Write-Ok 'SKSE/Plugins/OpenCompositeInput.dll (rebuilt)'
    } else {
        Write-Warn2 "Plugin DLL not found at $pluginDll - keeping base version."
    }

    # Configurator: EXE plus its native dependencies. All published files
    # land at the top level of the package.
    $cfgOut = Join-Path $ToolsOut 'Configurator'
    if (Test-Path -LiteralPath $cfgOut) {
        # Replace EXE
        $cfgExe = Join-Path $cfgOut 'OC Unleashed Configurator for Skyrim VR.exe'
        if (Test-Path -LiteralPath $cfgExe) {
            Copy-Item -LiteralPath $cfgExe -Destination (Join-Path $PackageRoot 'OC Unleashed Configurator for Skyrim VR.exe') -Force
            Write-Ok 'OC Unleashed Configurator for Skyrim VR.exe (rebuilt)'
        }

        # Replace native DLLs that ship alongside the EXE
        foreach ($dll in 'libmediapipe.dll','OpenCvSharpExtern.dll',
                         'opencv_videoio_ffmpeg4100_64.dll','opencv_world3410.dll') {
            $src = Join-Path $cfgOut $dll
            if (Test-Path -LiteralPath $src) {
                Copy-Item -LiteralPath $src -Destination (Join-Path $PackageRoot $dll) -Force
                Write-Ok "$dll (rebuilt)"
            }
        }

        # Replace BodyTracking subtree (model files, ui.json, README)
        $btSrc = Join-Path $cfgOut 'BodyTracking'
        if (Test-Path -LiteralPath $btSrc) {
            $btDst = Join-Path $PackageRoot 'BodyTracking'
            if (Test-Path -LiteralPath $btDst) {
                Remove-Item -LiteralPath $btDst -Recurse -Force
            }
            Copy-Item -LiteralPath $btSrc -Destination $btDst -Recurse -Force
            Write-Ok 'BodyTracking/ (rebuilt)'
        }
    } else {
        Write-Warn2 "Configurator output not found at $cfgOut - keeping base version."
    }

    # Keyboard Studio: whole folder, includes Assets/ and Stock Designs/
    $kbSrc = Join-Path $ToolsOut 'KeyboardStudio'
    if (Test-Path -LiteralPath $kbSrc) {
        $kbDst = Join-Path $PackageRoot 'OCU Keyboard Studio'
        if (Test-Path -LiteralPath $kbDst) {
            Remove-Item -LiteralPath $kbDst -Recurse -Force
        }
        Copy-Item -LiteralPath $kbSrc -Destination $kbDst -Recurse -Force
        Write-Ok 'OCU Keyboard Studio/ (rebuilt)'
    } else {
        Write-Warn2 "Keyboard Studio output not found at $kbSrc - keeping base version."
    }

    # Restore preserved ini.
    if ($savedIni -ne $null) {
        Set-Content -LiteralPath $iniPath -Value $savedIni -NoNewline
        Write-Ok 'Restored existing root\opencomposite.ini'
    }

    Write-Ok "Package root: $PackageRoot"
}

# ===========================================================================
# Stage 5 - Deploy to MO2 and launch
# ===========================================================================
function Deploy-Mod {
    Write-Stage "Deploying package to $DeployTarget"

    if (-not (Test-Path -LiteralPath $PackageRoot)) {
        throw "Package root not found at $PackageRoot. Run Package-Mod first."
    }

    if (-not (Test-Path -LiteralPath $DeployTarget)) {
        Write-Warn2 "Deploy target does not exist: $DeployTarget"
        Write-Info 'Creating it.'
        New-Item -ItemType Directory -Path $DeployTarget -Force | Out-Null
    }

    $exeName = 'OC Unleashed Configurator for Skyrim VR'
    $exeNameExe = 'OC Unleashed Configurator for Skyrim VR.exe'
    $running = Get-Process -Name $exeName -ErrorAction SilentlyContinue
    if ($running) {
        Write-Info "Stopping running Configurator (PID $($running.Id -join ', '))"
        $running | Stop-Process -Force
        # Give the OS a moment to release the file handle.
        Start-Sleep 5
        Write-Ok 'Configurator stopped.'
    }

    Get-ChildItem -LiteralPath $PackageRoot -Force |
        Copy-Item -Destination $DeployTarget -Recurse -Force
    Write-Ok "Deployed to $DeployTarget"

    # Launch the Configurator.
    $exe = Join-Path $DeployTarget $exeNameExe
    if (Test-Path -LiteralPath $exe) {
        Write-Info "Launching: $exe"
        Start-Process -FilePath $exe -WorkingDirectory $DeployTarget
        Write-Ok 'Configurator launched.'
    } else {
        Write-Warn2 "Configurator not found at $exe - skipping launch."
    }
}

function Clean-Build {
    Remove-Item -Recurse -Force "OpenCompositeSkyrimVR\build"
    Remove-Item -Recurse -Force "OpenCompositeInput- Skyrim SKSE\OpenCompositeInput\build"
    Remove-Item -Recurse -Force "out"
}

# Clean-Build
# Test-Preflight
#TODO Fetch-OfficialOCU
Fetch-Dependencies
Build-Runtime
Build-Plugin
Publish-Tools
Package-Mod
Deploy-Mod
