#Requires -Version 5.1

<#
.SYNOPSIS
Installs a WSL-based Docker CE and Portainer workstation without Docker Desktop.
.DESCRIPTION
Run from a regular PowerShell session belonging to the intended Windows user.
Enabling missing Windows WSL components may require administrator assistance.
The current user must have write access to the project directory for launcher creation.
Restarts all WSL distributions when .wslconfig changes. No containers or existing
Portainer data are deleted. Network and Docker checks run during installation.
.PARAMETER CorporateCaCertificatePath
Optional PEM-encoded corporate root CA certificate to trust inside Ubuntu.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$DistributionName = 'corpo_friendly_docker_ubuntu',

    [string]$ProxyUrl = 'http://127.0.0.1:9000',

    [ValidateNotNullOrEmpty()]
    [string]$NoProxy = 'localhost,127.0.0.1',

    [string]$CorporateCaCertificatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:WslPath = Join-Path $env:SystemRoot 'System32\wsl.exe'

function ConvertTo-BashLiteral {
    param([AllowEmptyString()][string]$Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function Invoke-Wsl {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$InputScript,
        [switch]$CaptureOutput,
        [switch]$ReturnResult
    )

    # All arguments are fixed switches or the validated distribution name.
    foreach ($argument in $Arguments) {
        if ($argument -match '[\s"]') {
            throw "Unsupported WSL argument: $argument"
        }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:WslPath
    $startInfo.Arguments = $Arguments -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    $startInfo.EnvironmentVariables['WSL_UTF8'] = '1'

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'Could not start wsl.exe.'
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($InputScript) {
            $process.StandardInput.Write($InputScript.Replace("`r`n", "`n") + "`n")
        }
        $process.StandardInput.Close()
        $stdout = $stdoutTask.GetAwaiter().GetResult().Replace("`0", '')
        $stderr = $stderrTask.GetAwaiter().GetResult().Replace("`0", '')
        $process.WaitForExit()

        if ($ReturnResult) {
            return [pscustomobject]@{
                ExitCode = $process.ExitCode
                Output = $stdout
                ErrorOutput = $stderr
            }
        }
        if ($process.ExitCode -ne 0) {
            throw "wsl.exe $($Arguments -join ' ') failed (exit $($process.ExitCode)).`n$stdout`n$stderr"
        }
        if ($stderr.Trim()) {
            Write-Warning $stderr.Trim()
        }
        if ($CaptureOutput) {
            return $stdout
        }
        if ($stdout.Trim()) {
            Write-Host $stdout.TrimEnd()
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-UbuntuBootstrap {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('configure-systemd', 'verify-systemd', 'configure-proxy', 'install-docker', 'configure-docker', 'deploy-portainer')]
        [string]$Phase
    )

    $inputScript = "set -Eeuo pipefail`n"
    $inputScript += 'WORKSPACE_PROXY_URL=' + (ConvertTo-BashLiteral $ProxyUrl) + "`n"
    $inputScript += 'WORKSPACE_NO_PROXY=' + (ConvertTo-BashLiteral $NoProxy) + "`n"
    $inputScript += 'WORKSPACE_CORPORATE_CA=' + (ConvertTo-BashLiteral $certificate) + "`n"
    $inputScript += $bootstrapContent
    Invoke-Wsl -Arguments @('-d', $DistributionName, '-u', 'root', '--', 'bash', '-s', '--', $Phase) `
        -InputScript $inputScript
}

function Test-WslNamedInstallSupport {
    param([Parameter(Mandatory)][string]$HelpOutput)

    $installSection = [regex]::Match(
        $HelpOutput,
        '(?ms)^[ \t]{4}--install\b.*?(?=^[ \t]{4}--[a-z]|\z)'
    )
    return $installSection.Success -and
        $installSection.Value -match '(?m)^[ \t]{8,}--name\b'
}

function Get-WslDistributionVersion {
    param(
        [Parameter(Mandatory)][string]$ListOutput,
        [Parameter(Mandatory)][string]$Name
    )

    $pattern = '(?m)^[ \t]*\*?[ \t]*' + [regex]::Escape($Name) +
        '[ \t]+[^\r\n]*?[ \t]+(?<version>[12])[ \t]*\r?$'
    $match = [regex]::Match($ListOutput, $pattern)
    if (-not $match.Success) {
        throw "Cannot determine WSL version of '$Name' from wsl --list --verbose."
    }
    return [int]$match.Groups['version'].Value
}

function Set-IniValue {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][System.Collections.Generic.List[string]]$Lines,
        [string]$Section,
        [string]$Key,
        [string]$Value
    )

    $sectionStart = -1
    $sectionEnd = $Lines.Count
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^\s*\[([^\]]+)\]\s*(?:[#;].*)?$') {
            if ($sectionStart -ge 0) {
                $sectionEnd = $index
                break
            }
            if ($Matches[1] -ieq $Section) {
                $sectionStart = $index
            }
        }
    }

    if ($sectionStart -lt 0) {
        if ($Lines.Count -gt 0 -and $Lines[$Lines.Count - 1] -ne '') {
            $Lines.Add('')
        }
        $Lines.Add("[$Section]")
        $Lines.Add("$Key=$Value")
        return
    }

    $found = $false
    for ($index = $sectionStart + 1; $index -lt $sectionEnd; $index++) {
        if ($Lines[$index] -match "^\s*$([regex]::Escape($Key))\s*=") {
            if ($found) {
                $Lines.RemoveAt($index)
                $index--
                $sectionEnd--
            }
            else {
                $Lines[$index] = "$Key=$Value"
                $found = $true
            }
        }
    }
    if (-not $found) {
        $Lines.Insert($sectionEnd, "$Key=$Value")
    }
}

$proxyUri = $null
if ($ProxyUrl -match '[\r\n]' -or
    -not [Uri]::TryCreate($ProxyUrl, [UriKind]::Absolute, [ref]$proxyUri) -or
    $proxyUri.Scheme -notin @('http', 'https') -or -not $proxyUri.Host -or
    $proxyUri.UserInfo -or $proxyUri.Query -or $proxyUri.Fragment -or
    $proxyUri.AbsolutePath -ne '/') {
    throw 'ProxyUrl must be an HTTP(S) proxy URL without credentials, query, fragment, or path.'
}
if ($NoProxy -match '[\r\n]') {
    throw 'NoProxy must be a single line.'
}
if (-not (Test-Path -LiteralPath $script:WslPath -PathType Leaf)) {
    throw 'wsl.exe is unavailable. Enable/install WSL, restart Windows if requested, then rerun this script.'
}

$certificate = ''
if ($CorporateCaCertificatePath) {
    $certificate = Get-Content -LiteralPath $CorporateCaCertificatePath -Raw
    if ($certificate -notmatch '-----BEGIN CERTIFICATE-----' -or
        $certificate -notmatch '-----END CERTIFICATE-----') {
        throw 'CorporateCaCertificatePath must contain a PEM-encoded CA certificate.'
    }
}

$bootstrapPath = Join-Path $PSScriptRoot 'bootstrap.sh'
if (-not (Test-Path -LiteralPath $bootstrapPath -PathType Leaf)) {
    throw "Required bootstrap not found: $bootstrapPath. Keep bootstrap.sh next to this installer."
}
$bootstrapContent = [IO.File]::ReadAllText($bootstrapPath)
if ([string]::IsNullOrWhiteSpace($bootstrapContent)) {
    throw "Required bootstrap is empty: $bootstrapPath."
}

Write-Host '[1/8] Configuring WSL networking...'
$wslConfigPath = Join-Path $env:USERPROFILE '.wslconfig'
$originalConfig = ''
if (Test-Path -LiteralPath $wslConfigPath) {
    $originalConfig = [IO.File]::ReadAllText($wslConfigPath)
}
$lines = New-Object 'System.Collections.Generic.List[string]'
if ($originalConfig.Length -gt 0) {
    $lines.AddRange([string[]]($originalConfig.TrimEnd("`r", "`n") -split '\r?\n'))
}
Set-IniValue -Lines $lines -Section 'wsl2' -Key 'networkingMode' -Value 'mirrored'
Set-IniValue -Lines $lines -Section 'wsl2' -Key 'autoProxy' -Value 'true'
Set-IniValue -Lines $lines -Section 'wsl2' -Key 'dnsTunneling' -Value 'true'
Set-IniValue -Lines $lines -Section 'experimental' -Key 'hostAddressLoopback' -Value 'true'
$newConfig = ($lines -join "`r`n") + "`r`n"
$networkingChanged = $newConfig -cne $originalConfig
if ($networkingChanged) {
    if (Test-Path -LiteralPath $wslConfigPath) {
        $backupPath = "$wslConfigPath.backup-$([Guid]::NewGuid().ToString('N'))"
        Copy-Item -LiteralPath $wslConfigPath -Destination $backupPath
        Write-Host "Previous WSL configuration saved to $backupPath"
    }
    [IO.File]::WriteAllText($wslConfigPath, $newConfig, (New-Object System.Text.UTF8Encoding($false)))
    Write-Warning 'Applying networking changes: all running WSL distributions will stop.'
    Invoke-Wsl -Arguments @('--shutdown')
}

Write-Host "[2/8] Ensuring Ubuntu 24.04 is installed as '$DistributionName'..."
$listResult = Invoke-Wsl -Arguments @('--list', '--quiet') -ReturnResult
$needsInstallation = $true
if ($listResult.ExitCode -eq 0) {
    $installedNames = @($listResult.Output -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $needsInstallation = $installedNames -notcontains $DistributionName
}
else {
    Write-Warning "WSL could not list distributions (exit $($listResult.ExitCode)). Attempting WSL/Ubuntu installation.`n$($listResult.Output)`n$($listResult.ErrorOutput)"
}
if ($needsInstallation) {
    $installArguments = @('--install', '--distribution', 'Ubuntu-24.04', '--no-launch')
    if ($DistributionName -ne 'Ubuntu-24.04') {
        $wslHelp = Invoke-Wsl -Arguments @('--help') -ReturnResult
        if ($wslHelp.ExitCode -notin @(0, -1)) {
            throw "Could not read WSL help (exit $($wslHelp.ExitCode)).`n$($wslHelp.Output)`n$($wslHelp.ErrorOutput)"
        }
        if (-not (Test-WslNamedInstallSupport -HelpOutput $wslHelp.Output)) {
            throw "This WSL version does not support named installations. Run wsl --update, then rerun, or use -DistributionName Ubuntu-24.04."
        }
        $installArguments += @('--name', $DistributionName)
    }
    Invoke-Wsl -Arguments $installArguments
    $distributions = Invoke-Wsl -Arguments @('--list', '--quiet') -CaptureOutput
    $installedNames = @($distributions -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($installedNames -notcontains $DistributionName) {
        throw "Ubuntu is not registered as '$DistributionName' yet. Restart Windows if WSL requested it, then rerun this installer."
    }
}
$distributionList = Invoke-Wsl -Arguments @('--list', '--verbose') -CaptureOutput
$wslVersion = Get-WslDistributionVersion -ListOutput $distributionList -Name $DistributionName
if ($wslVersion -eq 1) {
    Invoke-Wsl -Arguments @('--set-version', $DistributionName, '2')
}

Write-Host '[3/8] Enabling systemd...'
Invoke-UbuntuBootstrap -Phase 'configure-systemd'
Invoke-Wsl -Arguments @('--terminate', $DistributionName)
Invoke-UbuntuBootstrap -Phase 'verify-systemd'

Write-Host '[4/8] Configuring Linux and sudo proxies...'
Invoke-UbuntuBootstrap -Phase 'configure-proxy'

Write-Host '[5/8] Installing Docker CE from the official Docker repository...'
Invoke-UbuntuBootstrap -Phase 'install-docker'

Write-Host '[6/8] Configuring Docker service proxy and validating Docker pulls...'
Invoke-UbuntuBootstrap -Phase 'configure-docker'

Write-Host '[7/8] Deploying Portainer CE...'
Invoke-UbuntuBootstrap -Phase 'deploy-portainer'

Write-Host '[8/8] Creating the Windows Chrome launcher and updating the user PATH...'
$launcherDirectory = $PSScriptRoot
$launcherPath = Join-Path $launcherDirectory 'Start-DockerUI.ps1'
$launcher = @'
#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$distribution = '__DISTRIBUTION__'
$url = 'http://127.0.0.1:9002'
$wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
$keepaliveLock = '/run/portainer-workspace-keepalive.lock'

Write-Host "Starting or keeping WSL distribution '$distribution' active..."
$keepalive = Start-Process -FilePath $wsl -ArgumentList @(
    '-d', $distribution, '-u', 'root', '--',
    'flock', '-w', '15', $keepaliveLock, 'sleep', 'infinity'
) -WindowStyle Hidden -PassThru

$keepaliveReady = $false
for ($attempt = 0; $attempt -lt 15; $attempt++) {
    & $wsl -d $distribution -u root -- flock -n -E 42 $keepaliveLock true
    if ($LASTEXITCODE -eq 42) {
        $keepaliveReady = $true
        break
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to verify WSL keepalive for '$distribution' (exit $LASTEXITCODE)."
    }
    if ($keepalive.HasExited) {
        throw "WSL keepalive exited before acquiring its lock (exit $($keepalive.ExitCode))."
    }
    Start-Sleep -Seconds 1
}
if (-not $keepaliveReady) {
    if (-not $keepalive.HasExited) {
        Stop-Process -Id $keepalive.Id
    }
    throw "WSL keepalive did not start for '$distribution'."
}

Write-Host "WSL is active. Waiting for Portainer at $url..."
$deadline = [DateTime]::UtcNow.AddSeconds(120)
$ready = $false
$lastError = ''
while ([DateTime]::UtcNow -lt $deadline) {
    $response = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create("$url/api/status")
        $request.Proxy = $null
        $request.Timeout = 2000
        $response = $request.GetResponse()
        $ready = ([int]$response.StatusCode -eq 200)
    }
    catch [System.Net.WebException] {
        $lastError = $_.Exception.Message
        if ($_.Exception.Response) {
            $_.Exception.Response.Close()
        }
    }
    finally {
        if ($response) {
            $response.Close()
        }
    }
    if ($ready) {
        break
    }
    Start-Sleep -Seconds 2
}
if (-not $ready) {
    throw "Portainer is not ready at $url. Check Docker/Portainer in WSL. If initial setup timed out, restart the portainer container. Last HTTP error: $lastError"
}

$chromeCandidates = @()
$command = Get-Command chrome.exe -CommandType Application -ErrorAction SilentlyContinue
if ($command) {
    $chromeCandidates += $command.Source
}
foreach ($key in @(
    'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
    'Registry::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
    'Registry::HKEY_LOCAL_MACHINE\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
)) {
    if (Test-Path -LiteralPath $key) {
        $chromeCandidates += (Get-Item -LiteralPath $key).GetValue('')
    }
}
foreach ($base in @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if ($base) {
        $chromeCandidates += Join-Path $base 'Google\Chrome\Application\chrome.exe'
    }
}
$chrome = $chromeCandidates |
    Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
    Select-Object -First 1
if (-not $chrome) {
    throw "Google Chrome was not found. Install Chrome, or open $url manually."
}
Write-Host "Portainer is ready. Opening Chrome at $url..."
Start-Process -FilePath $chrome -ArgumentList @('--new-window', "--app=$url")
Write-Host "To stop only this WSL distribution and its containers: wsl --terminate $distribution"
'@
$launcher = $launcher.Replace('__DISTRIBUTION__', $DistributionName)
if (Test-Path -LiteralPath $launcherPath) {
    if ([IO.File]::ReadAllText($launcherPath) -cne $launcher) {
        Copy-Item -LiteralPath $launcherPath -Destination "$launcherPath.backup-$([Guid]::NewGuid().ToString('N'))"
    }
}
[IO.File]::WriteAllText($launcherPath, $launcher, (New-Object System.Text.UTF8Encoding($false)))

$environmentKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
try {
    $userPath = [string]$environmentKey.GetValue(
        'Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
    )
    $pathEntries = @($userPath -split ';' | Where-Object { $_ })
    if (@($pathEntries | Where-Object { $_.Trim().TrimEnd('\') -ieq $launcherDirectory }).Count -eq 0) {
        $updatedPath = (@($pathEntries) + $launcherDirectory) -join ';'
        $environmentKey.SetValue('Path', $updatedPath, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    }
}
finally {
    $environmentKey.Dispose()
}
if (@($env:Path -split ';' | Where-Object { $_.Trim().TrimEnd('\') -ieq $launcherDirectory }).Count -eq 0) {
    $env:Path += ";$launcherDirectory"
}

Write-Host ''
Write-Host 'Installation complete: http://localhost:9002'
Write-Host "Launcher: $launcherPath"
Write-Host 'Run Start-DockerUI.ps1 to open Chrome and complete Portainer administrator setup promptly.'
Write-Host 'The user PATH is saved. Restart your terminal (or sign out/in if necessary) to refresh it.'
Write-Host 'No Windows execution policy was changed.'
