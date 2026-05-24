# ==========================================# =================================TO)
# ==========================================
$User                   = "DAVillenaH"
$ApiToken               = "6230519d06fd777ff91904e60ebfd8e02d33c0047d7d42715c678fd25e67"
$DefaultKanboardBaseUrl = "https://kam.energysapiens.net.ar"
# ==========================================

<#
================================================================================
KANBOARD CLI v4.3.2 - PRO (management/ structure + SAFE PUSH + HASH GUARD)
--------------------------------------------------------------------------------
Estructura requerida:
management/
 ├── configuration/
 │     └── config.json
 ├── log/
 │     ├── cli.log
 │     └── cli.transcript.log
 ├── backlog/
       └── *.md

Reglas:
- No duplicar TitleOriginal/Title => solo Title
- No duplicar timestamps => LastPull es el timestamp del hash remoto
- Guard: si hash remoto actual != hash guardado => NO pisar; merge delta; conflicto; esperar
- Conflicto = "==== Cambios agregados ====="
- Nunca tocar time_estimated; solo time_spent

Placeholder Project inexistente:
- Mostrar “Ese proyecto no existe, desea crearlo? [0] No [1] Yes”
- Leer 0/1 pero NO ejecutar nada.

Fixes:
- NO usar .Count directamente en resultados del API (usar Get-ObjCount)
- Evitar doble getMyProjects al inicio (solo 1 vez en arranque)
================================================================================
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CliVersion = "4.3.2"
$Endpoint   = "$DefaultKanboardBaseUrl/jsonrpc.php"

$Global:CliLastErrorMessage = $null
$Global:LastConflictSummary = @()
$Global:LogPath             = $null
$Global:TranscriptPath      = $null
$Global:CachedProjects      = @()   # cache para evitar doble getMyProjects en startup

# -------------------------
# Output helpers
# -------------------------
function Write-Ok   { param([string]$m) Write-Host $m -ForegroundColor Green }
function Write-Api  { param([string]$m) Write-Host $m -ForegroundColor Cyan }
function Write-Warn { param([string]$m) Write-Host $m -ForegroundColor Yellow }
function Write-Fail { param([string]$m) Write-Host $m -ForegroundColor Red }

# -------------------------
# Safe array + safe count
# -------------------------
function As-Array {
    param([AllowNull()]$Obj)
    if ($null -eq $Obj) { return @() }
    return @($Obj)
}
function Get-ObjCount {
    param([AllowNull()]$Obj)
    if ($null -eq $Obj) { return 0 }

    if ($Obj -is [System.Collections.IDictionary]) { return $Obj.Keys.Count }
    if ($Obj -is [System.Array]) { return $Obj.Count }

    if ($Obj -is [System.Collections.IEnumerable] -and $Obj -isnot [string]) {
        return (@($Obj)).Count
    }

    return 1
}

# -------------------------
# Basic utils
# -------------------------
function Has-Prop {
    param([Parameter(Mandatory)]$Obj, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Obj) { return $false }
    return ($Obj.PSObject.Properties.Name -contains $Name)
}
function Is-NullOrWhiteSpace {
    param([AllowNull()][string]$Value)
    return [string]::IsNullOrWhiteSpace($Value)
}
function Read-Int {
    param([Parameter(Mandatory)][string]$Prompt)
    while ($true) {
        $v = (Read-Host $Prompt).Trim()
        if ($v -match '^\d+$') { return [int]$v }
        Write-Warn "Valor inválido. Debe ser numérico."
    }
}
function ConvertTo-DoubleSafe {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return 0.0 }
    $s = [string]$Value
    if (Is-NullOrWhiteSpace $s) { return 0.0 }
    $norm = $s -replace ',','.'
    $out = 0.0
    if ([double]::TryParse($norm, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$out)) { return $out }
    return 0.0
}
function Get-Sha1 {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )
    if ($null -eq $Text) { $Text = "" }
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hashBytes = $sha1.ComputeHash($bytes)
        return ([BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
    } finally { $sha1.Dispose() }
}
function Ensure-Hashtable {
    param([AllowNull()]$Obj)
    if ($null -eq $Obj) { return @{} }
    if ($Obj -is [hashtable]) { return $Obj }
    if ($Obj -is [System.Collections.IDictionary]) {
        $ht = @{}
        foreach ($k in $Obj.Keys) { $ht["$k"] = $Obj[$k] }
        return $ht
    }
    $ht2 = @{}
    foreach ($p in $Obj.PSObject.Properties) { $ht2[$p.Name] = $p.Value }
    return $ht2
}
function Normalize-DescriptionForHash {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return "" }
    $lines = $Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    return ($lines -join "`n").Trim()
}

# -------------------------
# Paths (management structure)
# -------------------------
function Get-GitRoot {
    $root = $null
    try {
        $git = Get-Command git -ErrorAction SilentlyContinue
        if ($git) { $root = (& $git.Source rev-parse --show-toplevel 2>$null).Trim() }
    } catch { $root = $null }
    if (Is-NullOrWhiteSpace $root) { $root = (Get-Location).Path }
    return $root
}
function Get-Paths {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $mg = Join-Path $RepoRoot "management"
    $cfgDir = Join-Path $mg "configuration"
    $logDir = Join-Path $mg "log"
    $backlogDir = Join-Path $mg "backlog"
    [PSCustomObject]@{
        RepoRoot     = $RepoRoot
        Management   = $mg
        ConfigDir    = $cfgDir
        LogDir       = $logDir
        BacklogDir   = $backlogDir
        ConfigJson   = (Join-Path $cfgDir "config.json")
        LogFile      = (Join-Path $logDir "cli.log")
        Transcript   = (Join-Path $logDir "cli.transcript.log")
    }
}
function Ensure-Directories {
    param($Paths)
    New-Item -ItemType Directory -Path $Paths.ConfigDir  -Force | Out-Null
    New-Item -ItemType Directory -Path $Paths.LogDir     -Force | Out-Null
    New-Item -ItemType Directory -Path $Paths.BacklogDir -Force | Out-Null
}

# -------------------------
# Logging
# -------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO","WARN","ERROR","API","DEBUG")][string]$Level = "INFO"
    )
    if (Is-NullOrWhiteSpace $Global:LogPath) { return }
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $Global:LogPath -Value ("[{0}] [{1}] {2}" -f $ts, $Level, $Message) -Encoding UTF8
}
function Start-Logging {
    param($Paths)
    $Global:LogPath = $Paths.LogFile
    $Global:TranscriptPath = $Paths.Transcript

    if (-not (Test-Path $Global:LogPath)) { New-Item -ItemType File -Path $Global:LogPath -Force | Out-Null }
    Write-Log -Level "INFO" -Message ("=== START KANBOARD CLI v{0} ===" -f $CliVersion)

    try {
        Start-Transcript -Path $Global:TranscriptPath -Force | Out-Null
        Write-Log -Level "INFO" -Message ("Transcript started: {0}" -f $Global:TranscriptPath)
    } catch {
        Write-Log -Level "WARN" -Message ("Could not start transcript: {0}" -f $_.Exception.Message)
    }
}
function Stop-Logging {
    try { Stop-Transcript | Out-Null } catch { }
    Write-Log -Level "INFO" -Message ("=== END KANBOARD CLI v{0} ===" -f $CliVersion)
}

# -------------------------
# UI
# -------------------------
function Show-Header {
    param($Paths,$ConfigObject)
    Clear-Host
    Write-Host ("=== KANBOARD CLI v{0} ===" -f $CliVersion) -ForegroundColor Green
    Write-Host ("RepoRoot: {0}" -f $Paths.RepoRoot) -ForegroundColor DarkGray
    Write-Host ("API:      {0}" -f $Endpoint) -ForegroundColor DarkGray
    Write-Host ("Project:  {0}" -f $ConfigObject.ProjectId) -ForegroundColor DarkGray
    Write-Host ("Config:   {0}" -f $Paths.ConfigJson) -ForegroundColor DarkGray

    if (-not (Is-NullOrWhiteSpace $Global:CliLastErrorMessage)) {
        Write-Host ""
        Write-Host ("LAST ERROR: {0}" -f $Global:CliLastErrorMessage) -ForegroundColor Red
    }

    if ((Get-ObjCount $Global:LastConflictSummary) -gt 0) {
        Write-Host ""
        Write-Host ("⚠ Conflictos pendientes: {0}" -f (Get-ObjCount $Global:LastConflictSummary)) -ForegroundColor Yellow
    }

    Write-Host ""
}
function Show-Menu {
    Write-Host "1) PULL    - Delta-merge + update TasksConfig (guarda hash remoto)"
    Write-Host "2) PUSH    - SAFE PUSH (PULL + check + ENTER + GUARD + PUSH)"
    Write-Host "3) PROJECT - Change ProjectId"
    Write-Host "0) EXIT"
    Write-Host ""
    return (Read-Host "Option").Trim()
}

# -------------------------
# Kanboard JSON-RPC
# -------------------------
function Get-AuthHeaders {
    $pair   = "$User`:$ApiToken"
    $bytes  = [System.Text.Encoding]::ASCII.GetBytes($pair)
    $base64 = [Convert]::ToBase64String($bytes)
    return @{ Authorization="Basic $base64"; "Content-Type"="application/json"; Accept="application/json" }
}
function Invoke-Kanboard {
    param([Parameter(Mandatory)][string]$Method, [hashtable]$Params = @{})
    Write-Log -Level "API" -Message ("CALL {0} params={1}" -f $Method, (($Params | ConvertTo-Json -Depth 8 -Compress)))
    Write-Api ("Kanboard → {0}" -f $Method)
    $headers = Get-AuthHeaders
    $body = @{ jsonrpc="2.0"; method=$Method; id=1; params=$Params } | ConvertTo-Json -Depth 12
    $resp = Invoke-RestMethod -Uri $Endpoint -Method Post -Headers $headers -Body $body
    if ($resp -and (Has-Prop $resp "error") -and $resp.error) { throw ("Kanboard error: {0}" -f $resp.error.message) }
    return $resp.result
}
function Assert-Kanboard { [void](Invoke-Kanboard -Method "getVersion") }
function Get-Projects   { Invoke-Kanboard -Method "getMyProjects" }
function Get-TaskById   { param([int]$TaskId) Invoke-Kanboard -Method "getTask" -Params @{ task_id=$TaskId } }

# -------------------------
# Config
# -------------------------
function Load-Config {
    param($Paths)
    if (Test-Path $Paths.ConfigJson) { return Get-Content $Paths.ConfigJson -Raw -Encoding UTF8 | ConvertFrom-Json }
    return $null
}
function Save-Config {
    param($Paths,$ConfigObject)
    $json = $ConfigObject | ConvertTo-Json -Depth 20
    Set-Content -Path $Paths.ConfigJson -Value $json -Encoding UTF8
}
function Ensure-ConfigOrBootstrap {
    param($Paths)

    $cfg = Load-Config -Paths $Paths
    if ($null -ne $cfg) {
        if (-not (Has-Prop $cfg "KanboardUrl")) { $cfg | Add-Member -NotePropertyName "KanboardUrl" -NotePropertyValue $DefaultKanboardBaseUrl -Force }
        $cfg.KanboardUrl = $DefaultKanboardBaseUrl

        if (-not (Has-Prop $cfg "ProjectId")) { $cfg | Add-Member -NotePropertyName "ProjectId" -NotePropertyValue 0 -Force }

        if (-not (Has-Prop $cfg "TasksConfig") -or $null -eq $cfg.TasksConfig) {
            $cfg | Add-Member -NotePropertyName "TasksConfig" -NotePropertyValue (@{}) -Force
        }
        $cfg.TasksConfig = Ensure-Hashtable $cfg.TasksConfig

        Save-Config -Paths $Paths -ConfigObject $cfg
        return $cfg
    }

    # bootstrap: usamos cache de proyectos (NO volvemos a llamar getMyProjects aquí)
    $projects = As-Array $Global:CachedProjects
    if ((Get-ObjCount $projects) -gt 0) {
        Write-Ok "✅ Proyectos disponibles:"
        foreach ($p in $projects) { Write-Host (" - [{0}] {1}" -f $p.id, $p.name) -ForegroundColor Green }
    }

    $SelectedProjectId = Read-Int "Ingresá el ID del proyecto"
    $cfgObj = [PSCustomObject]@{
        KanboardUrl = $DefaultKanboardBaseUrl
        ProjectId   = $SelectedProjectId
        TasksConfig = @{}
    }
    Save-Config -Paths $Paths -ConfigObject $cfgObj
    return $cfgObj
}

# -------------------------
# Project change (placeholder no existente)
# -------------------------
function Change-Project {
    param($Paths,$ConfigObject)

    $projects = As-Array (Get-Projects)
    Write-Ok "Projects:"
    foreach ($p in $projects) { Write-Host (" - [{0}] {1}" -f $p.id, $p.name) -ForegroundColor Green }

    $newProjectId = Read-Int "Enter Project ID"
    $match = $projects | Where-Object { [int]$_.id -eq $newProjectId } | Select-Object -First 1

    if (-not $match) {
        Write-Warn "Ese proyecto no existe, desea crearlo?"
        Write-Host "[0] No" -ForegroundColor Yellow
        Write-Host "[1] Yes" -ForegroundColor Yellow
        Read-Host "Seleccione 0/1 (PLACEHOLDER - no hace nada)" | Out-Null
        return $ConfigObject
    }

    $ConfigObject.ProjectId = $newProjectId
    Save-Config -Paths $Paths -ConfigObject $ConfigObject
    Write-Ok "ProjectId actualizado."
    return $ConfigObject
}

# -------------------------
# backlog file naming (pinned)
# -------------------------
function Normalize-TitleToFileName {
    param([string]$Title)
    $t = ($Title ?? "").Trim()
    if (Is-NullOrWhiteSpace $t) { $t = "Task" }
    $t = $t -replace '\s+', '_'
    $t = $t -replace '[\\/:*?"<>|]', ''
    $t = $t -replace '_{2,}', '_'
    $t = $t.Trim('_')
    if (Is-NullOrWhiteSpace $t) { $t = "Task" }
    return "$t.md"
}
function Get-TaskMdPathForTask {
    param($Paths,$ConfigObject,[int]$TaskId,[string]$Title)

    $ConfigObject.TasksConfig = Ensure-Hashtable $ConfigObject.TasksConfig
    $tid = "$TaskId"

    if ($ConfigObject.TasksConfig.ContainsKey($tid)) {
        $entry = $ConfigObject.TasksConfig[$tid]
        if ($null -ne $entry -and (Has-Prop $entry "FileName")) {
            $fn = [string]$entry.FileName
            if (-not (Is-NullOrWhiteSpace $fn)) { return (Join-Path $Paths.BacklogDir $fn) }
        }
    }

    $baseName = Normalize-TitleToFileName -Title $Title
    $chosenName = $baseName

    $used = @{}
    foreach ($k in $ConfigObject.TasksConfig.Keys) {
        $e = $ConfigObject.TasksConfig[$k]
        if ($null -ne $e -and (Has-Prop $e "FileName")) { $used[[string]$e.FileName] = $true }
    }
    if ($used.ContainsKey($chosenName)) {
        $nameNoExt = [IO.Path]::GetFileNameWithoutExtension($baseName)
        $chosenName = ("{0}__ID_{1}.md" -f $nameNoExt, $TaskId)
    }

    return (Join-Path $Paths.BacklogDir $chosenName)
}

# -------------------------
# Delta merge
# -------------------------
function Strip-ConflictBlocks {
    param([string]$Content)
    if ($null -eq $Content) { return "" }
    $marker = "==== Cambios agregados ====="
    $endMarker = "==== Fin cambios agregados ====="
    $pattern = [regex]::Escape($marker) + ".*?" + [regex]::Escape($endMarker)
    return ([regex]::Replace($Content, $pattern, "", [System.Text.RegularExpressions.RegexOptions]::Singleline)).Trim()
}
function Compute-RemoteDeltaLines {
    param([string]$LocalContent, [string]$RemoteContent)

    $localBase = Strip-ConflictBlocks -Content $LocalContent

    $localSet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($line in ($localBase -split "`r?`n")) {
        $n = $line.Trim()
        if ($n.Length -eq 0) { continue }
        [void]$localSet.Add($n)
    }

    $delta = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($RemoteContent -split "`r?`n")) {
        $n = $line.Trim()
        if ($n.Length -eq 0) { continue }
        if (-not $localSet.Contains($n)) {
            [void]$delta.Add($n)
            [void]$localSet.Add($n)
        }
    }

    return $delta.ToArray()
}
function Merge-RemoteDeltaIntoLocalMd {
    param([string]$LocalContent, [string]$RemoteContent)

    $deltaLines = Compute-RemoteDeltaLines -LocalContent $LocalContent -RemoteContent $RemoteContent
    if ((Get-ObjCount $deltaLines) -eq 0) { return $LocalContent }

    $deltaText = ($deltaLines -join "`n")
    $deltaHash = Get-Sha1 -Text (Normalize-DescriptionForHash -Text $deltaText)

    if ($LocalContent -like ("*hash={0}*" -f $deltaHash)) { return $LocalContent }

    $marker = "==== Cambios agregados ====="
    $endMarker = "==== Fin cambios agregados ====="
    $ts = (Get-Date).ToString("s")

    $block = @(
        "",
        $marker,
        ("(REMOTE SNAPSHOT {0} | hash={1})" -f $ts, $deltaHash),
        $deltaText,
        $endMarker,
        ""
    )
    return ($LocalContent.TrimEnd() + "`n" + ($block -join "`n"))
}

# -------------------------
# Conflicts
# -------------------------
function Get-ConflictSummary {
    param($Paths,$ConfigObject)

    $marker = "==== Cambios agregados ====="
    $ConfigObject.TasksConfig = Ensure-Hashtable $ConfigObject.TasksConfig

    $out = @()
    foreach ($tid in $ConfigObject.TasksConfig.Keys) {
        $entry = $ConfigObject.TasksConfig[$tid]
        if ($null -eq $entry) { continue }

        $fileName = if (Has-Prop $entry "FileName") { [string]$entry.FileName } else { "" }
        if (Is-NullOrWhiteSpace $fileName) { continue }

        $path = Join-Path $Paths.BacklogDir $fileName
        if (-not (Test-Path $path)) { continue }

        $content = Get-Content $path -Raw -Encoding UTF8
        if ($null -eq $content) { continue }

        $count = ([regex]::Matches($content, [regex]::Escape($marker))).Count
        if ($count -gt 0) {
            $title = if (Has-Prop $entry "Title") { [string]$entry.Title } else { "" }
            $out += [PSCustomObject]@{ TaskId=[int]$tid; Title=$title; FileName=$fileName; Blocks=$count }
        }
    }
    return $out
}
function Print-ConflictSummary {
    param($Summary)
    foreach ($c in (As-Array $Summary | Sort-Object Blocks -Descending)) {
        Write-Host ("⚠ Task {0} '{1}' tiene conflictos pendientes ({2} bloques) [Archivo: {3}]" -f $c.TaskId, $c.Title, $c.Blocks, $c.FileName) -ForegroundColor Yellow
    }
}
function Wait-UntilConflictsResolved {
    param($Paths,$ConfigObject)
    while ($true) {
        $pending = As-Array (Get-ConflictSummary -Paths $Paths -ConfigObject $ConfigObject)
        $Global:LastConflictSummary = $pending

        if ((Get-ObjCount $pending) -eq 0) { Write-Ok "✅ No hay conflictos pendientes. Continuando..."; return }

        Write-Host ""
        Write-Fail "⚠ Tienes cambios en backlog/*.md sin resolver:"
        Print-ConflictSummary -Summary $pending
        Write-Host ""
        Read-Host "Cuando lo resuelvas oprimes ENTER" | Out-Null
    }
}

# -------------------------
# PULL
# -------------------------
function Pull-TasksToMd {
    param($Paths,$ConfigObject)

    $ProjectId = [int]$ConfigObject.ProjectId
    Write-Ok ("PULL: Downloading tasks for Project #{0} ..." -f $ProjectId)
    Write-Log -Level "INFO" -Message ("PULL started ProjectId={0}" -f $ProjectId)

    $tasksRaw = Invoke-Kanboard -Method "getAllTasks" -Params @{ project_id = $ProjectId }
    $tasks = As-Array $tasksRaw

    if ((Get-ObjCount $tasks) -eq 0) { Write-Warn "No tasks found."; return }

    $ConfigObject.TasksConfig = Ensure-Hashtable $ConfigObject.TasksConfig
    $nowIso = (Get-Date).ToString("s")

    foreach ($t in $tasks) {
        $taskId = [int]$t.id
        $title  = [string]$t.title

        $remoteDesc = ""
        if (Has-Prop $t "description") { $remoteDesc = [string]$t.description }
        if ($null -eq $remoteDesc) { $remoteDesc = "" }

        $remoteHash = Get-Sha1 -Text (Normalize-DescriptionForHash -Text $remoteDesc)

        $colorId = ""
        if (Has-Prop $t "color_id") { $colorId = [string]$t.color_id }

        $spent = 0.0
        if (Has-Prop $t "time_spent") { $spent = ConvertTo-DoubleSafe $t.time_spent }

        $mdPath = Get-TaskMdPathForTask -Paths $Paths -ConfigObject $ConfigObject -TaskId $taskId -Title $title
        $fileName = Split-Path $mdPath -Leaf

        if (-not (Test-Path $mdPath)) {
            Set-Content -Path $mdPath -Value $remoteDesc -Encoding UTF8
        } else {
            $local = Get-Content $mdPath -Raw -Encoding UTF8
            if ($null -eq $local) { $local = "" }
            $newLocal = Merge-RemoteDeltaIntoLocalMd -LocalContent $local -RemoteContent $remoteDesc
            if ($newLocal -ne $local) { Set-Content -Path $mdPath -Value $newLocal -Encoding UTF8 }
        }

        $ConfigObject.TasksConfig["$taskId"] = [PSCustomObject]@{
            TaskId                = $taskId
            Title                 = $title
            FileName              = $fileName
            ColorId               = $colorId
            SpentHours            = $spent
            LastPull              = $nowIso
            RemoteDescriptionHash = $remoteHash
        }
    }

    Save-Config -Paths $Paths -ConfigObject $ConfigObject
    $Global:LastConflictSummary = As-Array (Get-ConflictSummary -Paths $Paths -ConfigObject $ConfigObject)

    if ((Get-ObjCount $Global:LastConflictSummary) -gt 0) {
        Write-Log -Level "WARN" -Message ("Conflicts pending: files={0}" -f (Get-ObjCount $Global:LastConflictSummary))
    } else {
        Write-Log -Level "INFO" -Message "No conflicts pending after PULL"
    }

    Write-Host ""
    Write-Ok "✅ PULL complete."
}

# -------------------------
# PUSH (GUARDED)
# -------------------------
function Push-MdToKanboard_Guarded {
    param($Paths,$ConfigObject)

    $ConfigObject.TasksConfig = Ensure-Hashtable $ConfigObject.TasksConfig
    $keys = @($ConfigObject.TasksConfig.Keys)
    if ((Get-ObjCount $keys) -eq 0) { Write-Warn "TasksConfig vacío. Nada para PUSH."; return $true }

    $remoteChanged = $false
    $nowIso = (Get-Date).ToString("s")

    foreach ($key in $keys) {
        $entry = $ConfigObject.TasksConfig["$key"]
        $taskId = [int]$entry.TaskId

        $fileName = [string]$entry.FileName
        if (Is-NullOrWhiteSpace $fileName) { continue }

        $mdPath = Join-Path $Paths.BacklogDir $fileName
        if (-not (Test-Path $mdPath)) { continue }

        $remoteTask = Get-TaskById -TaskId $taskId
        $currentRemoteDesc = ""
        if ($null -ne $remoteTask -and (Has-Prop $remoteTask "description")) { $currentRemoteDesc = [string]$remoteTask.description }
        if ($null -eq $currentRemoteDesc) { $currentRemoteDesc = "" }

        $currentRemoteHash = Get-Sha1 -Text (Normalize-DescriptionForHash -Text $currentRemoteDesc)
        $storedHash = [string]$entry.RemoteDescriptionHash

        if (-not (Is-NullOrWhiteSpace $storedHash) -and $storedHash -ne $currentRemoteHash) {
            $remoteChanged = $true
            Write-Warn ("REMOTE cambió desde el último PULL: TaskId={0}. Se agregó delta al .md" -f $taskId)
            Write-Log -Level "WARN" -Message ("Remote changed since pull TaskId={0} stored={1} current={2}" -f $taskId, $storedHash, $currentRemoteHash)

            $local = Get-Content $mdPath -Raw -Encoding UTF8
            if ($null -eq $local) { $local = "" }
            $newLocal = Merge-RemoteDeltaIntoLocalMd -LocalContent $local -RemoteContent $currentRemoteDesc
            if ($newLocal -ne $local) { Set-Content -Path $mdPath -Value $newLocal -Encoding UTF8 }
            continue
        }

        $mdContent = Get-Content $mdPath -Raw -Encoding UTF8
        if ($null -eq $mdContent) { $mdContent = "" }

        $params = @{
            id          = $taskId
            description = $mdContent
            time_spent  = [double]$entry.SpentHours  # never time_estimated
        }

        $title = [string]$entry.Title
        if (-not (Is-NullOrWhiteSpace $title)) { $params["title"] = $title }

        $colorId = [string]$entry.ColorId
        if (-not (Is-NullOrWhiteSpace $colorId)) { $params["color_id"] = $colorId }

        Invoke-Kanboard -Method "updateTask" -Params $params | Out-Null

        # actualizar hash guardado para no disparar falso conflicto en el próximo push
        $newHash = Get-Sha1 -Text (Normalize-DescriptionForHash -Text $mdContent)
        $entry.RemoteDescriptionHash = $newHash
        $entry.LastPull = $nowIso
    }

    Save-Config -Paths $Paths -ConfigObject $ConfigObject
    return (-not $remoteChanged)
}

function SafePush {
    param($Paths,$ConfigObject)

    Write-Api "SAFE PUSH: Ejecutando PULL previo al PUSH..."
    Pull-TasksToMd -Paths $Paths -ConfigObject $ConfigObject
    $ConfigObject = Load-Config -Paths $Paths

    Write-Api "SAFE PUSH: Verificando conflictos..."
    Wait-UntilConflictsResolved -Paths $Paths -ConfigObject $ConfigObject

    while ($true) {
        $ConfigObject = Load-Config -Paths $Paths
        Write-Api "SAFE PUSH: Verificando cambios remotos (hash) y enviando..."
        $ok = Push-MdToKanboard_Guarded -Paths $Paths -ConfigObject $ConfigObject

        if ($ok) {
            Write-Ok "✅ PUSH finalizado sin pisar cambios remotos."
            return
        }

        Write-Warn "Se detectaron cambios remotos durante el PUSH. Refrescando PULL para actualizar hashes..."
        Pull-TasksToMd -Paths $Paths -ConfigObject $ConfigObject
        $ConfigObject = Load-Config -Paths $Paths

        Write-Warn "Resolvé los bloques 'Cambios agregados' y presioná ENTER."
        Wait-UntilConflictsResolved -Paths $Paths -ConfigObject $ConfigObject
    }
}

# -------------------------
# MAIN
# -------------------------
try {
    $repoRoot = Get-GitRoot
    $paths = Get-Paths -RepoRoot $repoRoot
    Ensure-Directories -Paths $paths
    Start-Logging -Paths $paths

    Assert-Kanboard

    # ✅ 1 sola llamada en startup
    $Global:CachedProjects = As-Array (Get-Projects)
    Write-Ok "✅ Proyectos disponibles:"
    foreach ($p in $Global:CachedProjects) { Write-Host (" - [{0}] {1}" -f $p.id, $p.name) -ForegroundColor Green }

    $config = Ensure-ConfigOrBootstrap -Paths $paths

    while ($true) {
        Show-Header -Paths $paths -ConfigObject $config

        try {
            switch (Show-Menu) {
                "1" { Pull-TasksToMd -Paths $paths -ConfigObject $config; $config = Load-Config -Paths $paths }
                "2" { SafePush -Paths $paths -ConfigObject $config; $config = Load-Config -Paths $paths }
                "3" { $config = Change-Project -Paths $paths -ConfigObject $config; $config = Load-Config -Paths $paths }
                "0" { Write-Ok "Saliendo..."; Stop-Logging; return }
                default { Write-Warn "Opción inválida." }
            }
        }
        catch {
            $Global:CliLastErrorMessage = $_.Exception.Message
            Write-Fail ("Unhandled error: {0}" -f $Global:CliLastErrorMessage)
            Write-Log -Level "ERROR" -Message ("Unhandled error: {0}" -f $Global:CliLastErrorMessage)
        }

        Start-Sleep -Milliseconds 250
    }
}
catch {
    $msg = $_.Exception.Message
    Write-Fail ("FATAL: {0}" -f $msg)
    if ($Global:LogPath) { Write-Log -Level "ERROR" -Message ("FATAL: {0}" -f $msg) }
    try { Stop-Logging } catch { }
    exit 1
}
