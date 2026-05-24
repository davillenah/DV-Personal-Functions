# ==========================================
# CONFIGURACIÓN DE ACCESO PERSONAL (SECRETO)
# ==========================================
$User     = "DAVillenaH"
$ApiToken = "6230519d06fd777ff91904e60ebfd8e02d33c0047d7d42715c678fd25e67"
# ==========================================

# Endpoint CONFIRMADO ✅
$KanboardUrl = "https://kam.energysapiens.net.ar/jsonrpc.php"

$ErrorActionPreference = "Stop"

# =========================
# COLORES
# =========================
function Write-Ok($msg)   { Write-Host $msg -ForegroundColor Green }
function Write-Info($msg) { Write-Host $msg -ForegroundColor Cyan }
function Write-Fail($msg) { Write-Host $msg -ForegroundColor Red }
function Write-Warn($msg) { Write-Host $msg -ForegroundColor Yellow }

# =========================
# AUTH HEADER
# =========================
function Get-AuthHeaders {
    $pair  = "$User`:$ApiToken"
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
    $base64 = [Convert]::ToBase64String($bytes)

    return @{
        Authorization  = "Basic $base64"
        "Content-Type" = "application/json"
    }
}

# =========================
# LLAMADA GENERICA JSON-RPC
# =========================
function Invoke-Kanboard {
    param(
        [Parameter(Mandatory)]
        [string]$Method,

        [hashtable]$Params = @{}
    )

    $headers = Get-AuthHeaders

    $body = @{
        jsonrpc = "2.0"
        method  = $Method
        id      = 1
        params  = $Params
    } | ConvertTo-Json -Depth 5

    Invoke-RestMethod `
        -Uri $KanboardUrl `
        -Method Post `
        -Headers $headers `
        -Body $body
}

# =========================
# TEST PRINCIPAL
# =========================
function Test-KanboardConnection {

    try {
        Write-Info "Probando conexión con Kanboard..."
        Write-Host ""

        # 1. Test básico: getVersion
        $versionResp = Invoke-Kanboard -Method "getVersion"

        if ($versionResp.result) {
            Write-Ok "✅ Conexión OK"
            Write-Ok "Versión Kanboard: $($versionResp.result)"
        }
        else {
            Write-Fail "❌ No se recibió respuesta válida"
            return
        }

        Write-Host ""

        # 2. Test adicional: obtener proyectos
        Write-Info "Verificando acceso a proyectos..."
        $projectsResp = Invoke-Kanboard -Method "getMyProjects"

        if ($projectsResp.result) {
            $count = $projectsResp.result.Count
            Write-Ok "✅ Acceso OK a proyectos ($count encontrados)"

            foreach ($p in $projectsResp.result) {
                Write-Host " - [$($p.id)] $($p.name)" -ForegroundColor Green
            }
        }
        else {
            Write-Warn "⚠ No se pudieron listar proyectos (posible limitación de permisos)"
        }

        Write-Host ""
        Write-Ok "✔ TEST COMPLETO FINALIZADO"

    }
    catch {
        Write-Host ""
        Write-Fail "❌ Error de conexión o autenticación"

        $msg = $_.Exception.Message
        Write-Host $msg -ForegroundColor Red

        if ($msg -match "401") {
            Write-Warn "👉 Problema de autenticación (usuario o token incorrecto)"
        }
        elseif ($msg -match "403") {
            Write-Warn "👉 Sin permisos suficientes"
        }
        elseif ($msg -match "404") {
            Write-Warn "👉 Endpoint incorrecto (aunque ya lo validaste ✅)"
        }
    }
}

# =========================
# EJECUCIÓN
# =========================
Test-KanboardConnection