# ==========================================================
# ESXI_UPS_DATTO
# Version: 1.0.0
# Estado: TEST DATTO RMM
#
# Monitoreo y contingencia VMware ESXi mediante Datto RMM
# Integracion de UPS APC mediante SNMP.
#
# Metodo VMware:
#   CLI  = PowerCLI
#   SSH  = SSH/CLI
#   AUTO = PowerCLI y fallback a SSH/CLI
#
# MODO_CONTINGENCIA debe ser TRUE para ejecutar apagado de VMs.
# En FALSE, el script solo monitorea ESXi y UPS.
# ==========================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ==========================================================
# CONFIGURACION
# ==========================================================

$MonitorConfig = @{
    Name   = 'ESXI-01'
    Host   = '192.168.0.188'

    # CLI/PowerCLI es el metodo principal. SSH queda disponible solo como backup.
    Method = 'CLI'
    Method_Variable = 'ESXI_MONITOR_METHOD'
    SSH_BackupEnabled_Variable = 'ESXI_HABILITAR_SSH_BACKUP'

    CLI_User_Variable     = 'ESXI_CLI_USER'
    CLI_Password_Variable = 'ESXI_CLI_PASSWORD'

    SSH_User_Variable     = 'ESXI_SSH_USER'
    SSH_Password_Variable = 'ESXI_SSH_PASSWORD'
    SSH_KeyPath_Variable  = 'ESXI_SSH_PRIVATE_KEY_PATH'

    VMOrder_Variable         = 'ORDEN_VMS'
    ShutdownTimeout_Variable = 'TIMEOUT_VM'
    WaitBetweenVMs_Variable  = 'TIEMPO_ESPERA_VM'
    HostShutdownDelay_Variable = 'TIEMPO_APAGADO_ESXI'
    HostShutdownEnabled_Variable = 'APAGAR_ESXI'

    # UPS / Datto
    UPS_IP_Variable          = 'IP_UPS'
    UPS_TestMode_Variable    = 'MODO_PRUEBA'
    UPS_Battery_Variable     = 'UMBRAL_BATERIA'
    UPS_Runtime_Variable     = 'UMBRAL_AUTONOMIA'
    UPS_AC_Variable          = 'UMBRAL_VOLTAJE_AC'

    # Fallback de laboratorio. En Datto se recomienda configurar las variables.
    # Para la prueba inicial en Datto se recomienda definir ORDEN_VMS
    # como variable del componente. Si no se define, se usa este orden de laboratorio.
    VMOrder_Test = @(
        'srv25'
        'srv26'
        'win10'
        'Ejecucion de Monitor'
    )

    SSH_KeyPath_Test = "$env:TEMP\esxi_monitor_rsa"
    ShutdownTimeout_Test = 120
    WaitBetweenVMs_Test = 10
    HostShutdownDelay_Test = 60

    UPS_Battery_Test = 20
    UPS_Runtime_Test = 20
    UPS_AC_Test = 10

    # ======================================================
    # TRAZA DE CONTINGENCIA
    # ======================================================
    # Por defecto se oculta el detalle TRACE. Para activarlo:
    #   $env:MOSTRAR_TRAZA = 'True'
    ContingencyTrace_Test = $false
}

# OIDs APC PowerNet utilizados por la contingencia.
$OID_Bateria        = '.1.3.6.1.4.1.318.1.1.1.2.2.1.0'
$OID_Autonomia      = '.1.3.6.1.4.1.318.1.1.1.2.2.3.0'
$OID_VoltajeEntrada = '.1.3.6.1.4.1.318.1.1.1.3.2.1.0'
$ComunidadSNMP = 'public'

# ==========================================================
# FUNCIONES GENERALES
# ==========================================================

function Get-EnvironmentVariableValue {
    param([string]$VariableName)

    if ([string]::IsNullOrWhiteSpace($VariableName)) { return $null }

    foreach ($Target in @('Process','User','Machine')) {
        try {
            $Value = [Environment]::GetEnvironmentVariable($VariableName, $Target)
            if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }
        }
        catch {}
    }

    return $null
}

function Convert-ToBoolean {
    param(
        [string]$Value,
        [bool]$Default = $false
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }

    try { return [System.Convert]::ToBoolean($Value) }
    catch { throw "Valor booleano invalido: '$Value'. Use TRUE o FALSE." }
}

function Write-DRRMAlert {
    param([string]$Message)
    Write-Host '<-Start Result->'
    Write-Host "Alert=$Message"
    Write-Host '<-End Result->'
}

function Write-DRRMDiagnostic {
    param([string]$Text)
    Write-Host '<-Start Diagnostic->'
    Write-Host $Text
    Write-Host '<-End Diagnostic->'
}

function Write-ContingencyTrace {
    param(
        [string]$Section,
        [string]$Message
    )

    # MOSTRAR_TRAZA=True habilita el detalle completo.
    # Si no está definida, se respeta el valor predeterminado del monitor.
    $TraceRaw = Get-EnvironmentVariableValue 'MOSTRAR_TRAZA'
    $MostrarTraza = $MonitorConfig.ContingencyTrace_Test

    if (-not [string]::IsNullOrWhiteSpace($TraceRaw)) {
        try {
            $MostrarTraza = Convert-ToBoolean $TraceRaw $MonitorConfig.ContingencyTrace_Test
        }
        catch {
            $MostrarTraza = $MonitorConfig.ContingencyTrace_Test
        }
    }

    if (-not $MostrarTraza) { return }

    $Timestamp = Get-Date -Format 'HH:mm:ss'
    $SectionDisplay = '{0,-12}' -f $Section
    Write-Host "TRACE | $Timestamp | $SectionDisplay | $Message"
}

function Get-SSHKeyPath {
    $Path = Get-EnvironmentVariableValue $MonitorConfig.SSH_KeyPath_Variable
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = $MonitorConfig.SSH_KeyPath_Test }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "No se encontro la clave privada SSH: $Path"
    }

    return $Path
}

function Get-ConfiguredVMOrder {
    $RawOrder = Get-EnvironmentVariableValue $MonitorConfig.VMOrder_Variable

    if (-not [string]::IsNullOrWhiteSpace($RawOrder)) {
        $Order = @($RawOrder -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    else {
        $Order = @($MonitorConfig.VMOrder_Test)
    }

    if ($Order.Count -eq 0) { throw 'No se definio ORDEN_VMS para la contingencia.' }

    return $Order
}

function Get-ContingencySettings {
    $TimeoutRaw = Get-EnvironmentVariableValue $MonitorConfig.ShutdownTimeout_Variable
    $WaitRaw = Get-EnvironmentVariableValue $MonitorConfig.WaitBetweenVMs_Variable
    $HostDelayRaw = Get-EnvironmentVariableValue $MonitorConfig.HostShutdownDelay_Variable
    $HostShutdownRaw = Get-EnvironmentVariableValue $MonitorConfig.HostShutdownEnabled_Variable

    $Timeout = $MonitorConfig.ShutdownTimeout_Test
    $Wait = $MonitorConfig.WaitBetweenVMs_Test
    $HostDelay = $MonitorConfig.HostShutdownDelay_Test

    if (-not [string]::IsNullOrWhiteSpace($TimeoutRaw)) { $Timeout = [int]$TimeoutRaw }
    if (-not [string]::IsNullOrWhiteSpace($WaitRaw)) { $Wait = [int]$WaitRaw }
    if (-not [string]::IsNullOrWhiteSpace($HostDelayRaw)) { $HostDelay = [int]$HostDelayRaw }

    if ($Timeout -lt 10) { throw 'TIMEOUT_VM debe ser >= 10 segundos.' }
    if ($Wait -lt 0) { throw 'TIEMPO_ESPERA_VM no puede ser negativo.' }
    if ($HostDelay -lt 30) { throw 'TIEMPO_APAGADO_ESXI debe ser >= 30 segundos.' }

    $HostShutdownEnabled = Convert-ToBoolean $HostShutdownRaw $true

    return [pscustomobject]@{
        TimeoutSeconds = $Timeout
        WaitSeconds = $Wait
        HostShutdownDelaySeconds = $HostDelay
        HostShutdownEnabled = $HostShutdownEnabled
    }
}

# ==========================================================
# FUNCIONES UPS / SNMP
# ==========================================================

function Get-UPSSettings {
    $UPSIP = Get-EnvironmentVariableValue $MonitorConfig.UPS_IP_Variable
    $TestRaw = Get-EnvironmentVariableValue $MonitorConfig.UPS_TestMode_Variable
    $BatteryRaw = Get-EnvironmentVariableValue $MonitorConfig.UPS_Battery_Variable
    $RuntimeRaw = Get-EnvironmentVariableValue $MonitorConfig.UPS_Runtime_Variable
    $ACRaw = Get-EnvironmentVariableValue $MonitorConfig.UPS_AC_Variable

    $TestMode = Convert-ToBoolean $TestRaw $false
    $BatteryThreshold = $MonitorConfig.UPS_Battery_Test
    $RuntimeThreshold = $MonitorConfig.UPS_Runtime_Test
    $ACThreshold = $MonitorConfig.UPS_AC_Test

    if (-not [string]::IsNullOrWhiteSpace($BatteryRaw)) { $BatteryThreshold = [int]$BatteryRaw }
    if (-not [string]::IsNullOrWhiteSpace($RuntimeRaw)) { $RuntimeThreshold = [int]$RuntimeRaw }
    if (-not [string]::IsNullOrWhiteSpace($ACRaw)) { $ACThreshold = [int]$ACRaw }

    if (-not $TestMode -and [string]::IsNullOrWhiteSpace($UPSIP)) {
        throw 'IP_UPS no esta configurada.'
    }

    if ($BatteryThreshold -lt 0 -or $BatteryThreshold -gt 100) { throw 'UMBRAL_BATERIA debe estar entre 0 y 100.' }
    if ($RuntimeThreshold -lt 0) { throw 'UMBRAL_AUTONOMIA no puede ser negativo.' }
    if ($ACThreshold -lt 0) { throw 'UMBRAL_VOLTAJE_AC no puede ser negativo.' }

    return [pscustomobject]@{
        IP = $UPSIP
        TestMode = $TestMode
        BatteryThreshold = $BatteryThreshold
        RuntimeThreshold = $RuntimeThreshold
        ACThreshold = $ACThreshold
    }
}

function Get-SNMPValue {
    param(
        [string]$UPSIP,
        [string]$OID,
        [string]$Description
    )

    $SNMP = Get-Command snmpget -ErrorAction SilentlyContinue
    if ($null -eq $SNMP) { throw 'No se encontro snmpget en el equipo.' }

    $Response = & $SNMP.Source -v 2c -c $ComunidadSNMP $UPSIP $OID 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "SNMP fallo al consultar $Description en $UPSIP."
    }

    $Text = (($Response | Out-String).Trim())
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text -match '(?i)timeout|no response|unknown host') {
        throw "SNMP no respondio al consultar $Description."
    }

    return $Text
}

function Test-UPS {
    param($Settings)

    $Result = [pscustomobject]@{
        Success = $false
        Battery = $null
        RuntimeMinutes = $null
        ACVoltage = $null
        ContingencyRequired = $false
        Reason = ''
        Detail = ''
    }

    try {
        if ($Settings.TestMode) {
            # Modo prueba: simula UPS en bateria y condicion critica.
            $Result.Battery = 20
            $Result.RuntimeMinutes = 20
            $Result.ACVoltage = 0
            $Result.Success = $true
            $Result.ContingencyRequired = $true
            $Result.Reason = 'MODO_PRUEBA activo.'
            $Result.Detail = 'Valores UPS simulados: bateria=20%, autonomia=20 min, AC=0 V.'
            return $Result
        }

        $BatteryResponse = Get-SNMPValue $Settings.IP $OID_Bateria 'bateria'
        if ($BatteryResponse -match '(?i)Gauge32:\s*(\d+)') {
            $Result.Battery = [int]$Matches[1]
        }
        else { throw 'No se pudo interpretar el porcentaje de bateria SNMP.' }

        $RuntimeResponse = Get-SNMPValue $Settings.IP $OID_Autonomia 'autonomia'
        if ($RuntimeResponse -match '(?i)Timeticks:\s*\((\d+)\)') {
            $Ticks = [int64]$Matches[1]
            $Result.RuntimeMinutes = [math]::Round($Ticks / 6000)
        }
        else { throw 'No se pudo interpretar la autonomia SNMP.' }

        $ACResponse = Get-SNMPValue $Settings.IP $OID_VoltajeEntrada 'voltaje de entrada'
        if ($ACResponse -match '(?i)Gauge32:\s*(\d+)') {
            $Result.ACVoltage = [int]$Matches[1]
        }
        else { throw 'No se pudo interpretar el voltaje de entrada SNMP.' }

        # Condicion de contingencia: sin corriente Y bateria <= umbral O autonomia <= umbral.
        $NoHayCorriente = $Result.ACVoltage -le $Settings.ACThreshold
        $BateriaCritica = $Result.Battery -le $Settings.BatteryThreshold
        $AutonomiaCritica = $Result.RuntimeMinutes -le $Settings.RuntimeThreshold

        if ($NoHayCorriente -and ($BateriaCritica -or $AutonomiaCritica)) {
            $Result.ContingencyRequired = $true
            $Result.Reason = 'UPS en bateria con condicion critica de bateria/autonomia.'
        }
        elseif (-not $NoHayCorriente) {
            $Result.Reason = 'Suministro electrico normal.'
        }
        else {
            $Result.Reason = 'UPS en bateria, pero bateria y autonomia aun no son criticas.'
        }

        $Result.Success = $true
        $Result.Detail = "Bateria=$($Result.Battery)% | Autonomia=$($Result.RuntimeMinutes) min | AC=$($Result.ACVoltage) V"
        return $Result
    }
    catch {
        $Result.Detail = "UPS/SNMP ERROR: $($_.Exception.Message)"
        return $Result
    }
}

# ==========================================================
# FUNCIONES VM / POWERCLI
# ==========================================================

function Test-PowerCLI {
    $script:DetalleCLI = ''

    try { $null = Get-Command Connect-VIServer -ErrorAction Stop }
    catch {
        $script:DetalleCLI = 'PowerCLI no disponible: Connect-VIServer no esta disponible.'
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($CLIUser) -or [string]::IsNullOrWhiteSpace($CLIPassword)) {
        $script:DetalleCLI = 'Credenciales CLI no configuradas en las variables de Datto RMM/Windows.'
        return $false
    }

    try {
        if (Get-Command Set-PowerCLIConfiguration -ErrorAction SilentlyContinue) {
            Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }

        $SecurePassword = ConvertTo-SecureString $CLIPassword -AsPlainText -Force
        $Credential = New-Object System.Management.Automation.PSCredential($CLIUser, $SecurePassword)
        $script:ConexionESXi = Connect-VIServer -Server $ESXiHost -Credential $Credential -Force -NotDefault -ErrorAction Stop -WarningAction SilentlyContinue
        if ($null -eq $script:ConexionESXi) { throw 'PowerCLI no devolvio una sesion valida.' }

        $script:ConexionCreadaPorMonitor = $true
        $VMHost = @(Get-VMHost -Server $script:ConexionESXi -ErrorAction Stop)[0]
        if ($null -eq $VMHost) { throw 'No se pudo obtener el host ESXi mediante PowerCLI.' }

        $script:HostName = $VMHost.Name
        $script:HostVersion = [string]$VMHost.Version
        $script:HostBuild = [string]$VMHost.Build

        if ($VMHost.CpuTotalMhz -gt 0) {
            $script:CPUUsage = [math]::Round(($VMHost.CpuUsageMhz * 100) / $VMHost.CpuTotalMhz, 1)
        }
        if ($VMHost.MemoryTotalGB -gt 0) {
            $script:MemoryUsage = [math]::Round(($VMHost.MemoryUsageGB * 100) / $VMHost.MemoryTotalGB, 1)
        }

        $script:VMs = @(Get-VM -Server $script:ConexionESXi -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                Id = $_.Id
                PowerState = $_.PowerState.ToString()
            }
        })

        $script:DetalleCLI = 'PowerCLI OK.'
        return $true
    }
    catch {
        $script:DetalleCLI = "PowerCLI fallo: $($_.Exception.Message)"
        return $false
    }
}

# ==========================================================
# FUNCIONES SSH
# ==========================================================

function Invoke-ESXiSSHCommand {
    param([string]$Command)

    $KeyPath = Get-SSHKeyPath
    if ([string]::IsNullOrWhiteSpace($SSHUser)) { throw 'Usuario SSH no configurado.' }

    $SSH = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if ($null -eq $SSH) { throw 'No se encontro ssh.exe.' }

    $Output = & $SSH.Source -i $KeyPath -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSHUser@$ESXiHost" $Command 2>&1
    if ($LASTEXITCODE -ne 0) { throw (($Output | Out-String).Trim()) }
    return (($Output | Out-String).Trim())
}

function Test-SSH {
    $script:DetalleSSH = ''

    try {
        $Output = Invoke-ESXiSSHCommand 'vim-cmd vmsvc/getallvms'
        if ([string]::IsNullOrWhiteSpace($Output)) { throw 'SSH respondio sin datos.' }

        $script:VMs = @()
        foreach ($Line in ($Output -split "`r?`n")) {
            if ($Line -match '^\s*(\d+)\s+(.+?)\s+\[') {
                $script:VMs += [pscustomobject]@{
                    Name = $Matches[2].Trim()
                    Id = [int]$Matches[1]
                    PowerState = 'Unknown'
                }
            }
        }

        if ($script:VMs.Count -eq 0) { throw 'SSH respondio, pero no se pudieron obtener VMID.' }

        foreach ($VM in $script:VMs) {
            try {
                $StateOutput = Invoke-ESXiSSHCommand "vim-cmd vmsvc/power.getstate $($VM.Id)"
                if ($StateOutput -match '(?im)^\s*Powered on\s*$') { $VM.PowerState = 'PoweredOn' }
                elseif ($StateOutput -match '(?im)^\s*Powered off\s*$') { $VM.PowerState = 'PoweredOff' }
                elseif ($StateOutput -match '(?im)^\s*Guest OS not running\s*$') { $VM.PowerState = 'PoweredOff' }
                else { $VM.PowerState = 'Unknown' }
            }
            catch { $VM.PowerState = 'Unknown' }
        }

        $VersionOutput = Invoke-ESXiSSHCommand 'vmware -v'
        $HostOutput = Invoke-ESXiSSHCommand 'hostname'
        $script:HostName = ($HostOutput | Out-String).Trim()
        $script:HostVersion = (($VersionOutput | Out-String).Trim() -replace '^VMware ESXi\s*','' -replace '\s+',' ')
        $script:DetalleSSH = 'SSH OK.'
        return $true
    }
    catch {
        $script:DetalleSSH = "SSH fallo: $($_.Exception.Message)"
        return $false
    }
}

function Wait-VMOffPowerCLI {
    param($VM, [int]$TimeoutSeconds)
    $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $ElapsedSeconds = 0
    $CheckInterval = 5

    Write-ContingencyTrace 'ESPERA' "VM=$($VM.Name) | Metodo=PowerCLI | Esperando PoweredOff | Timeout=$TimeoutSeconds s"

    do {
        Start-Sleep -Seconds $CheckInterval
        $ElapsedSeconds += $CheckInterval
        $State = (Get-VM -Server $script:ConexionESXi -Id $VM.Id -ErrorAction Stop).PowerState.ToString()

        if ($State -eq 'PoweredOff') {
            Write-ContingencyTrace 'ESPERA' "VM=$($VM.Name) | Estado=PoweredOff | Tiempo=$ElapsedSeconds/$TimeoutSeconds s"
            return $true
        }

        Write-ContingencyTrace 'ESPERA' "VM=$($VM.Name) | Estado=$State | Tiempo=$ElapsedSeconds/$TimeoutSeconds s"
    } while ((Get-Date) -lt $Deadline)

    Write-ContingencyTrace 'TIMEOUT' "VM=$($VM.Name) | No llego a PoweredOff dentro de $TimeoutSeconds s"
    return $false
}

function Wait-VMOffSSH {
    param([int]$VMId, [string]$VMName, [int]$TimeoutSeconds)
    $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $ElapsedSeconds = 0
    $CheckInterval = 5

    Write-ContingencyTrace 'ESPERA' "VM=$VMName | Metodo=SSH | Esperando PoweredOff | Timeout=$TimeoutSeconds s"

    do {
        Start-Sleep -Seconds $CheckInterval
        $ElapsedSeconds += $CheckInterval
        $StateOutput = Invoke-ESXiSSHCommand "vim-cmd vmsvc/power.getstate $VMId"

        if ($StateOutput -match '(?im)^\s*Powered off\s*$' -or $StateOutput -match '(?im)^\s*Guest OS not running\s*$') {
            Write-ContingencyTrace 'ESPERA' "VM=$VMName | Estado=PoweredOff | Tiempo=$ElapsedSeconds/$TimeoutSeconds s"
            return $true
        }

        $StateDisplay = (($StateOutput -split "`r?`n") | Where-Object { $_ -match 'Powered' -or $_ -match 'Guest OS' } | Select-Object -First 1).Trim()
        if ([string]::IsNullOrWhiteSpace($StateDisplay)) { $StateDisplay = 'Estado no interpretado' }
        Write-ContingencyTrace 'ESPERA' "VM=$VMName | Estado=$StateDisplay | Tiempo=$ElapsedSeconds/$TimeoutSeconds s"
    } while ((Get-Date) -lt $Deadline)

    Write-ContingencyTrace 'TIMEOUT' "VM=$VMName | No llego a PoweredOff dentro de $TimeoutSeconds s"
    return $false
}

function Invoke-PowerCLIVMShutdown {
    param($VM)
    try {
        # $VM es inventario simplificado; recuperamos el objeto VMware real.
        $PowerCLIVM = Get-VM -Server $script:ConexionESXi -Id $VM.Id -ErrorAction Stop
        if ($null -eq $PowerCLIVM) {
            throw "No se encontro la VM '$($VM.Name)' mediante PowerCLI."
        }

        Write-ContingencyTrace 'ACCION' "VM=$($VM.Name) | Enviando Shutdown-VMGuest | VMID=$($VM.Id)"
        Shutdown-VMGuest -VM $PowerCLIVM -Confirm:$false -ErrorAction Stop | Out-Null
        Write-ContingencyTrace 'ACCION' "VM=$($VM.Name) | Shutdown-VMGuest enviado correctamente"

        if (Wait-VMOffPowerCLI -VM $VM -TimeoutSeconds $script:TimeoutVM) {
            $VM.PowerState = 'PoweredOff'
            return [pscustomobject]@{ Success = $true; Detail = "OK | $($VM.Name) | Apagada y verificada." }
        }
        return [pscustomobject]@{ Success = $false; Detail = "CRITICAL | $($VM.Name) | Timeout de $($script:TimeoutVM) segundos." }
    }
    catch {
        $PowerCLIError = $_.Exception.Message

        if ($PowerCLIError -match '(?i)license|licen[cs]|prohibits execution|no permite') {
            Write-ContingencyTrace 'ADVERTENCIA' "VM=$($VM.Name) | PowerCLI no permitido por licencia o version de ESXi"
            $DetallePowerCLI = 'licencia o version de ESXi no permite Shutdown-VMGuest'
        }
        else {
            Write-ContingencyTrace 'ADVERTENCIA' "VM=$($VM.Name) | PowerCLI no pudo completar el apagado"
            $DetallePowerCLI = 'error no detallado en TRACE; revisar diagnostico tecnico'
        }

        return [pscustomobject]@{ Success = $false; Detail = "CRITICAL | $($VM.Name) | Fallo shutdown PowerCLI: $DetallePowerCLI." }
    }
}

function Invoke-SSHVMShutdown {
    param($VM)
    try {
        Write-ContingencyTrace 'ACCION' "VM=$($VM.Name) | Enviando vim-cmd vmsvc/power.shutdown | VMID=$($VM.Id)"
        $null = Invoke-ESXiSSHCommand "vim-cmd vmsvc/power.shutdown $($VM.Id)"
        Write-ContingencyTrace 'ACCION' "VM=$($VM.Name) | Shutdown SSH enviado correctamente"

        if (Wait-VMOffSSH -VMId $VM.Id -VMName $VM.Name -TimeoutSeconds $script:TimeoutVM) {
            $VM.PowerState = 'PoweredOff'
            return [pscustomobject]@{ Success = $true; Detail = "OK | $($VM.Name) | Apagada y verificada." }
        }
        return [pscustomobject]@{ Success = $false; Detail = "CRITICAL | $($VM.Name) | Timeout de $($script:TimeoutVM) segundos." }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Detail = "CRITICAL | $($VM.Name) | Fallo shutdown SSH/CLI: $($_.Exception.Message)" }
    }
}

function Test-AllConfiguredVMsPoweredOff {
    param([string]$Metodo)
    $AllOff = $true
    if ($Metodo -like 'PowerCLI*') {
        try {
            $VMsFinal = @(Get-VM -Server $script:ConexionESXi -ErrorAction Stop)
            foreach ($NombreVM in $script:OrdenVMs) {
                $VMFinal = @($VMsFinal | Where-Object { $_.Name -eq $NombreVM })[0]
                if ($null -eq $VMFinal) { $script:ResultadosContingencia += "VERIFY | CRITICAL | $NombreVM | No encontrada."; $AllOff=$false; continue }
                $EstadoFinal=$VMFinal.PowerState.ToString()
                $script:ResultadosContingencia += "VERIFY | $NombreVM | $EstadoFinal"
                if ($EstadoFinal -ne 'PoweredOff') { $AllOff=$false }
            }
        } catch { $script:ResultadosContingencia += "VERIFY | CRITICAL | Error consultando PowerCLI: $($_.Exception.Message)"; return $false }
    } else {
        if (-not (Test-SSH)) { $script:ResultadosContingencia += 'VERIFY | CRITICAL | No se pudo actualizar el inventario por SSH.'; return $false }
        foreach ($NombreVM in $script:OrdenVMs) {
            $VMFinal=@($script:VMs | Where-Object { $_.Name -eq $NombreVM })[0]
            if ($null -eq $VMFinal) { $script:ResultadosContingencia += "VERIFY | CRITICAL | $NombreVM | No encontrada."; $AllOff=$false; continue }
            $script:ResultadosContingencia += "VERIFY | $NombreVM | $($VMFinal.PowerState)"
            if ($VMFinal.PowerState -ne 'PoweredOff') { $AllOff=$false }
        }
    }
    return $AllOff
}

function Invoke-PowerCLIHostShutdown {
    param([int]$DelaySeconds)

    if ($DelaySeconds -lt 30) { throw 'TIEMPO_APAGADO_ESXI debe ser >= 30 segundos.' }

    if ($null -eq $script:ConexionESXi) {
        throw 'No existe una sesion PowerCLI valida para apagar el host ESXi.'
    }

    $VMHost = @(Get-VMHost -Server $script:ConexionESXi -ErrorAction Stop)[0]
    if ($null -eq $VMHost) {
        throw 'No se pudo obtener el host ESXi mediante PowerCLI.'
    }

    Write-ContingencyTrace 'HOST' "Programando apagado PowerCLI del ESXi en $DelaySeconds segundos."

    # Stop-VMHost realiza el apagado ordenado del host.
    # El delay se conserva para dejar margen antes del apagado.
    if ($DelaySeconds -gt 0) {
        Write-ContingencyTrace 'HOST' "Esperando $DelaySeconds segundos antes de solicitar el apagado del host."
        Start-Sleep -Seconds $DelaySeconds
    }

    Stop-VMHost -VMHost $VMHost -Confirm:$false -ErrorAction Stop | Out-Null
    $script:ResultadosContingencia += "HOST | ESXi | Apagado PowerCLI solicitado correctamente."
    return $true
}

function Invoke-ESXiHostShutdown {
    param(
        [int]$DelaySeconds,
        [string]$Metodo
    )

    if ($Metodo -eq 'PowerCLI') {
        return Invoke-PowerCLIHostShutdown -DelaySeconds $DelaySeconds
    }

    if ($Metodo -eq 'SSH' -or $Metodo -like 'SSH*') {
        if (-not $script:SSHBackupEnabled) {
            throw 'SSH esta deshabilitado. Habilite ESXI_HABILITAR_SSH_BACKUP=True para usarlo como backup.'
        }

        if ($DelaySeconds -lt 30) { throw 'TIEMPO_APAGADO_ESXI debe ser >= 30 segundos.' }

        Write-ContingencyTrace 'HOST' "Programando apagado SSH del ESXi en $DelaySeconds segundos."
        $Command="esxcli system shutdown poweroff -d $DelaySeconds -r 'UPS DATTO - contingencia automatica'"
        $null=Invoke-ESXiSSHCommand $Command
        $script:ResultadosContingencia += "HOST | ESXi | Apagado SSH programado en $DelaySeconds segundos."
        return $true
    }

    throw "Metodo de apagado de host no soportado: $Metodo"
}

function Invoke-Contingencia {
    param([string]$Metodo)

    $Fallos = 0
    $InventarioInicial = @($script:VMs)
    $TotalVMs = $script:OrdenVMs.Count
    $IndiceVM = 0

    Write-ContingencyTrace 'CONTINGENCIA' '=========================================='
    Write-ContingencyTrace 'CONTINGENCIA' "Inicio del apagado | Metodo=$Metodo | VMs=$TotalVMs"
    Write-ContingencyTrace 'CONTINGENCIA' "Timeout por VM=$script:TimeoutVM s | Espera entre VMs=$script:EsperaEntreVMs s"

    foreach ($NombreVM in $script:OrdenVMs) {
        $IndiceVM++
        $VM = @($InventarioInicial | Where-Object { $_.Name -eq $NombreVM })[0]

        Write-ContingencyTrace 'VM' "[$IndiceVM/$TotalVMs] Preparando '$NombreVM'"

        if ($null -eq $VM) {
            Write-ContingencyTrace 'ERROR' "[$IndiceVM/$TotalVMs] VM=$NombreVM | No encontrada en inventario"
            $script:ResultadosContingencia += "CRITICAL | $NombreVM | No encontrada en ESXi."
            $Fallos++
            continue
        }

        Write-ContingencyTrace 'VM' "[$IndiceVM/$TotalVMs] VM=$($VM.Name) | Estado inicial=$($VM.PowerState) | VMID=$($VM.Id)"

        if ($VM.PowerState -eq 'PoweredOff') {
            Write-ContingencyTrace 'VM' "[$IndiceVM/$TotalVMs] VM=$($VM.Name) | Ya estaba PoweredOff | Se continua con la siguiente"
            $script:ResultadosContingencia += "INFO | $($VM.Name) | Ya estaba apagada. VMID=$($VM.Id)."
            continue
        }

        if ($VM.PowerState -ne 'PoweredOn') {
            Write-ContingencyTrace 'ERROR' "[$IndiceVM/$TotalVMs] VM=$($VM.Name) | Estado no valido: $($VM.PowerState)"
            $script:ResultadosContingencia += "CRITICAL | $($VM.Name) | Estado desconocido. VMID=$($VM.Id)."
            $Fallos++
            continue
        }

        Write-ContingencyTrace 'VM' "[$IndiceVM/$TotalVMs] VM=$($VM.Name) | Iniciando shutdown ordenado"
        $script:ResultadosContingencia += "INFO | $($VM.Name) | Iniciando shutdown ordenado. VMID=$($VM.Id)."

        if ($Metodo -eq 'PowerCLI') { $Resultado = Invoke-PowerCLIVMShutdown $VM }
        else { $Resultado = Invoke-SSHVMShutdown $VM }

        $script:ResultadosContingencia += $Resultado.Detail
        Write-ContingencyTrace 'RESULTADO' "[$IndiceVM/$TotalVMs] VM=$($VM.Name) | $($Resultado.Detail)"

        if (-not $Resultado.Success) {
            $Fallos++
            Write-ContingencyTrace 'ERROR' "[$IndiceVM/$TotalVMs] VM=$($VM.Name) | Se registra fallo y se continua con la siguiente VM"
        }

        if ($script:EsperaEntreVMs -gt 0 -and $NombreVM -ne $script:OrdenVMs[-1]) {
            Write-ContingencyTrace 'ESPERA' "VM=$($VM.Name) | Esperando $script:EsperaEntreVMs s antes de continuar"
            Start-Sleep -Seconds $script:EsperaEntreVMs
            Write-ContingencyTrace 'ESPERA' "VM=$($VM.Name) | Espera finalizada"
        }
    }

    Write-ContingencyTrace 'CONTINGENCIA' "Fin del apagado | Fallos=$Fallos"
    return $Fallos
}

# ==========================================================
# INICIO / VARIABLES DE EJECUCION
# ==========================================================

$VMs = @()
$ResultadoVMs = @()
$ResultadosContingencia = @()
$CodigoSalida = 1
$EstadoDatto = 'ESXi UPS DATTO - CRITICAL - Monitoreo fallido - ESXI-01'
$MetodoUtilizado = '-'
$DetalleCLI = 'No ejecutado'
$DetalleSSH = 'No ejecutado'
$HostName = '-'
$HostVersion = '-'
$HostBuild = '-'
$CPUUsage = '-'
$MemoryUsage = '-'
$ConexionESXi = $null
$ConexionCreadaPorMonitor = $false
$OrdenVMs = @()
$TimeoutVM = 120
$EsperaEntreVMs = 10
$TiempoApagadoESXi = 60
$ApagarESXi = $true
$SSHBackupEnabled = $false

$CLIUser = Get-EnvironmentVariableValue $MonitorConfig.CLI_User_Variable
$CLIPassword = Get-EnvironmentVariableValue $MonitorConfig.CLI_Password_Variable
$SSHUser = Get-EnvironmentVariableValue $MonitorConfig.SSH_User_Variable
$SSHPassword = Get-EnvironmentVariableValue $MonitorConfig.SSH_Password_Variable

$ModoContingencia = Convert-ToBoolean (Get-EnvironmentVariableValue 'MODO_CONTINGENCIA') $false
$MethodFromEnvironment = Get-EnvironmentVariableValue $MonitorConfig.Method_Variable
if ([string]::IsNullOrWhiteSpace($MethodFromEnvironment)) { $MonitorMethod = ([string]$MonitorConfig.Method).ToUpperInvariant() }
else { $MonitorMethod = $MethodFromEnvironment.ToUpperInvariant() }

$SSHBackupEnabled = Convert-ToBoolean (Get-EnvironmentVariableValue $MonitorConfig.SSH_BackupEnabled_Variable) $false

$UPSSettings = $null
$UPSResult = $null

# ==========================================================
# VALIDACION DE CONFIGURACION
# ==========================================================

try {
    $ESXiHost = [string]$MonitorConfig.Host
    $OrdenVMs = @(Get-ConfiguredVMOrder)
    $ContingencySettings = Get-ContingencySettings
    $TimeoutVM = $ContingencySettings.TimeoutSeconds
    $EsperaEntreVMs = $ContingencySettings.WaitSeconds
    $TiempoApagadoESXi = $ContingencySettings.HostShutdownDelaySeconds
    $ApagarESXi = $ContingencySettings.HostShutdownEnabled
    $UPSSettings = Get-UPSSettings

    if ([string]::IsNullOrWhiteSpace($MonitorConfig.Name)) { throw 'Falta el nombre del monitor ESXi.' }
    if ([string]::IsNullOrWhiteSpace($ESXiHost)) { throw 'Falta el host/IP del ESXi.' }
    if ($MonitorMethod -notin @('CLI','SSH','AUTO')) { throw "Metodo invalido: '$MonitorMethod'. Valores permitidos: CLI, SSH, AUTO." }
}
catch {
    $EstadoDatto = "ESXi EXING - CRITICAL - Configuracion incorrecta - $($MonitorConfig.Name)"
    Write-DRRMAlert $EstadoDatto
    Write-DRRMDiagnostic "ESXI UPS DATTO`n==========================================`nVersion: 1.0.0`n`nEstado: MONITOREO FALLIDO`n`nMotivo:`n$($_.Exception.Message)"
    exit 1
}

# ==========================================================
# LECTURA UPS
# ==========================================================

$UPSResult = Test-UPS $UPSSettings

# ==========================================================
# MONITOREO ESXi
# ==========================================================

$CLI_OK = $false
$SSH_OK = $false

# CLI/PowerCLI es el camino normal.
# SSH solo se prueba como backup cuando ESXI_HABILITAR_SSH_BACKUP=True,
# salvo que el administrador fuerce ESXI_MONITOR_METHOD=SSH.
if ($MonitorMethod -eq 'CLI' -or $MonitorMethod -eq 'AUTO') { $CLI_OK = Test-PowerCLI }
if ($MonitorMethod -eq 'SSH' -or ($MonitorMethod -eq 'AUTO' -and -not $CLI_OK -and $SSHBackupEnabled)) { $SSH_OK = Test-SSH }

if ($CLI_OK) {
    $MetodoUtilizado = 'PowerCLI'
    $EstadoDatto = 'ESXi EXING - OK - Monitoreo funcionando - Metodo: PowerCLI'
    $CodigoSalida = 0
    $DetalleSSH = if ($MonitorMethod -eq 'AUTO') { 'No ejecutado: PowerCLI funciono correctamente.' } else { 'No ejecutado.' }
}
elseif ($SSH_OK) {
    $MetodoUtilizado = 'SSH'
    $EstadoDatto = 'ESXi EXING - OK - Monitoreo funcionando - Metodo: SSH'
    $CodigoSalida = 0
}
else {
    $EstadoDatto = "ESXi EXING - CRITICAL - Monitoreo fallido - $($MonitorConfig.Name)"
    $CodigoSalida = 1
}

# ==========================================================
# DECISION DE CONTINGENCIA
# ==========================================================

# Un error SNMP nunca dispara un apagado automatico.
if (-not $UPSResult.Success) {
    $ResultadosContingencia += 'CRITICAL | UPS | No se puede evaluar la condicion de contingencia por error SNMP.'
    if ($CodigoSalida -eq 0) { $CodigoSalida = 1 }
    $EstadoDatto = 'ESXi EXING - CRITICAL - UPS/SNMP no disponible'
}
elseif ($ModoContingencia -and ($CLI_OK -or $SSH_OK) -and $UPSResult.ContingencyRequired) {
    $ResultadosContingencia += "INFO | UPS | Contingencia autorizada. $($UPSResult.Reason)"
    $ContingenciaFallos = 0

    if ($MonitorMethod -eq 'CLI') {
        $ContingenciaFallos = Invoke-Contingencia -Metodo 'PowerCLI'
    }
    elseif ($MonitorMethod -eq 'SSH') {
        $ContingenciaFallos = Invoke-Contingencia -Metodo 'SSH'
    }
    else {
        if ($CLI_OK) {
            $ContingenciaFallos = Invoke-Contingencia -Metodo 'PowerCLI'
            if ($ContingenciaFallos -gt 0 -and $SSHBackupEnabled) {
                $ResultadosContingencia += 'AUTO | PowerCLI no completo la contingencia. Se intenta SSH como backup.'
                $SSH_OK = Test-SSH
                if ($SSH_OK) {
                    $MetodoUtilizado = 'SSH (backup AUTO)'
                    $ContingenciaFallos = Invoke-Contingencia -Metodo 'SSH'
                }
                else {
                    $ContingenciaFallos = 1
                    $ResultadosContingencia += "CRITICAL | AUTO | SSH backup no disponible. $DetalleSSH"
                }
            }
        }
        else {
            $ContingenciaFallos = Invoke-Contingencia -Metodo 'SSH'
            $MetodoUtilizado = 'SSH'
        }
    }

    if ($ContingenciaFallos -gt 0) {
        $EstadoDatto = "ESXi EXING - CRITICAL - Contingencia: fallaron $ContingenciaFallos apagados/verificaciones - $($MonitorConfig.Name)"
        $CodigoSalida = 1
    }
    else {
        $EstadoDatto = "ESXi EXING - OK - Contingencia VMs completada - Metodo: $MetodoUtilizado"
        $CodigoSalida = 0
    }
}
elseif ($ModoContingencia -and -not $UPSResult.ContingencyRequired) {
    $ResultadosContingencia += "INFO | UPS | No corresponde contingencia. $($UPSResult.Reason)"
}
elseif (-not $ModoContingencia -and $UPSResult.ContingencyRequired) {
    $ResultadosContingencia += 'INFO | UPS | Condicion critica detectada, pero MODO_CONTINGENCIA=False. No se apaga ninguna VM.'
}
else {
    $ResultadosContingencia += 'INFO | UPS | Condicion normal. No se ejecuta contingencia.'
}

# ==========================================================
# VERIFICACION FINAL DE VMs Y APAGADO DEL HOST
# ==========================================================

$TodasLasVMsApagadas = $false

if ($ModoContingencia -and $UPSResult.Success -and $UPSResult.ContingencyRequired -and ($CLI_OK -or $SSH_OK)) {
    $TodasLasVMsApagadas = Test-AllConfiguredVMsPoweredOff -Metodo $MetodoUtilizado
    if (-not $TodasLasVMsApagadas) {
        $CodigoSalida=1
        $EstadoDatto="ESXi EXING - CRITICAL - Contingencia no verificada completamente - $($MonitorConfig.Name)"
    }
    elseif ($ContingenciaFallos -eq 0) {
        if (-not $ApagarESXi) {
            $ResultadosContingencia += 'HOST | INFO | Apagado del ESXi deshabilitado por APAGAR_ESXI=False. Las VMs fueron apagadas y verificadas.'
            $EstadoDatto="ESXi EXING - OK - Contingencia VMs completada - Apagado ESXi deshabilitado"
            $CodigoSalida=0
        }
        else {
            try {
                $null=Invoke-ESXiHostShutdown -DelaySeconds $TiempoApagadoESXi -Metodo $MetodoUtilizado
                $EstadoDatto="ESXi EXING - OK - VMs apagadas. ESXi programado para apagarse en $TiempoApagadoESXi segundos."
                $CodigoSalida=0
            } catch {
                $ResultadosContingencia += "HOST | CRITICAL | No se pudo programar el apagado del ESXi: $($_.Exception.Message)"
                $EstadoDatto="ESXi EXING - CRITICAL - VMs apagadas pero no se pudo programar el apagado del ESXi - $($MonitorConfig.Name)"
                $CodigoSalida=1
            }
        }
    }
}

# ==========================================================
# FORMATO DE SALIDA
# ==========================================================

$VMsEncendidas = @($VMs | Where-Object { $_.PowerState -eq 'PoweredOn' })
$VMsApagadas = @($VMs | Where-Object { $_.PowerState -eq 'PoweredOff' })
$VMsDesconocidas = @($VMs | Where-Object { $_.PowerState -ne 'PoweredOn' -and $_.PowerState -ne 'PoweredOff' })

$VMNameWidth = [math]::Max(4, (($VMs | ForEach-Object { ([string]$_.Name).Length } | Measure-Object -Maximum).Maximum))
if ($VMNameWidth -lt 20) { $VMNameWidth = 20 }

foreach ($VM in $VMs) {
    $VMName = ([string]$VM.Name).PadRight($VMNameWidth)
    $State = ([string]$VM.PowerState).PadRight(12)
    $VMID = ([string]$VM.Id).PadLeft(4)
    $ResultadoVMs += "INFO | $VMName | $State | VMID=$VMID"
}

# ==========================================================
# SALIDA DATTO RMM
# ==========================================================

$UPSStatus = if ($UPSResult.Success) { 'OK' } else { 'CRITICAL' }
$UPSReason = if ($UPSResult.Success) { $UPSResult.Reason } else { $UPSResult.Detail }

Write-DRRMAlert $EstadoDatto
Write-DRRMDiagnostic @"
ESXI MONITOR EXING
==========================================
Version: 1.0.0

ESXi: $($MonitorConfig.Name)
Host: $($MonitorConfig.Host)
Metodo configurado: $MonitorMethod
Metodo utilizado: $MetodoUtilizado
SSH backup habilitado: $SSHBackupEnabled
MODO_CONTINGENCIA: $ModoContingencia

Estado:
$EstadoDatto

------------------------------------------
UPS / SNMP:
Estado: $UPSStatus
IP UPS: $($UPSSettings.IP)
Bateria: $($UPSResult.Battery) %
Autonomia: $($UPSResult.RuntimeMinutes) minutos
Voltaje AC: $($UPSResult.ACVoltage) V
Umbral bateria: $($UPSSettings.BatteryThreshold) %
Umbral autonomia: $($UPSSettings.RuntimeThreshold) minutos
Umbral AC: $($UPSSettings.ACThreshold) V
MODO_PRUEBA UPS: $($UPSSettings.TestMode)
Condicion: $UPSReason

------------------------------------------
POWERCLI:
$DetalleCLI

SSH:
$DetalleSSH

SSH backup habilitado: $SSHBackupEnabled

------------------------------------------
Host:
$HostName
Version:
$HostVersion
Build:
$HostBuild
CPU:
$CPUUsage %
Memoria:
$MemoryUsage %

------------------------------------------
VMs:
$(if ($ResultadoVMs.Count -gt 0) { $ResultadoVMs -join "`n" } else { 'No se pudieron obtener VMs.' })

VMs detectadas: $($VMs.Count)
VMs encendidas: $($VMsEncendidas.Count)
VMs apagadas: $($VMsApagadas.Count)
VMs en estado desconocido: $($VMsDesconocidas.Count)

------------------------------------------
ORDEN DE CONTINGENCIA:
$($OrdenVMs -join "`n")

Timeout por VM: $TimeoutVM segundos
Espera entre VMs: $EsperaEntreVMs segundos
Tiempo apagado ESXi: $TiempoApagadoESXi segundos
Apagado ESXi habilitado: $ApagarESXi

------------------------------------------
CONTINGENCIA:
$($ResultadosContingencia -join "`n")

Las VMs se informan normalmente como INFO.
Durante MODO_CONTINGENCIA, un fallo de apagado/verificacion genera CRITICAL.
El host ESXi solo se programa para apagarse despues de verificar que TODAS las VMs configuradas estan PoweredOff.
CLI/PowerCLI es el metodo principal. SSH se mantiene como backup y se habilita con ESXI_HABILITAR_SSH_BACKUP=True.
Ejecucion de Monitor debe permanecer ultima en ORDEN_VMS.
Un error SNMP nunca dispara un apagado automatico.

Estado Datto: $EstadoDatto
Codigo salida: $CodigoSalida
Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
==========================================
"@

if ($ConexionCreadaPorMonitor -and $null -ne $ConexionESXi) {
    Disconnect-VIServer -Server $ConexionESXi -Confirm:$false -Force -ErrorAction SilentlyContinue
}

exit $CodigoSalida