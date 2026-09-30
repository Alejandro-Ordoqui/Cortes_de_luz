# ESXI_UPS_DATTO_LICENCIADO

**Versión:** 1.0.0  
**Branch:** develop  
**Commit de referencia:** c7c9653d8ead77cfc7e4e79d015e4f834493b261  
**Script:** ESXI_UPS_DATTO_LICENCIADO.ps1

## Objetivo
Monitorear un ESXi licenciado mediante Datto RMM y PowerCLI, integrando una UPS APC por SNMP y ejecutando, cuando corresponde, una contingencia ordenada de las VMs y posteriormente del host.

## Método
- PowerCLI como único método VMware.
- Sin SSH.
- Shutdown-VMGuest para apagado ordenado de VMs.
- Ejecucion de Monitor siempre última.
- Verificación de TODAS las VMs como PoweredOff antes del host.
- Stop-VMHost para apagado ordenado del host.
- Un error SNMP nunca dispara un apagado automático.

## Variables
- ESXI_MONITOR_METHOD
- ESXI_CLI_USER
- ESXI_CLI_PASSWORD
- ORDEN_VMS
- TIMEOUT_VM
- TIEMPO_ESPERA_VM
- TIEMPO_APAGADO_ESXI
- APAGAR_ESXI
- IP_UPS
- MODO_PRUEBA
- UMBRAL_BATERIA
- UMBRAL_AUTONOMIA
- UMBRAL_VOLTAJE_AC
- MODO_CONTINGENCIA

## Secuencia
1. Detectar la condición de UPS.
2. Validar MODO_CONTINGENCIA.
3. Obtener inventario mediante PowerCLI.
4. Apagar las VMs en ORDEN_VMS.
5. Esperar y verificar PoweredOff.
6. Apagar Ejecucion de Monitor en último lugar.
7. Verificar nuevamente todas las VMs.
8. Si alguna no está PoweredOff, no apagar el host.
9. Si todas están apagadas y APAGAR_ESXI=True, solicitar Stop-VMHost.

## Pruebas
Para la primera prueba, mantener APAGAR_ESXI=False. Una vez validado el apagado de VMs, realizar por separado la prueba de apagado del host.

## Regla
Este documento acompaña exclusivamente a ESXI_UPS_DATTO_LICENCIADO.ps1. Ante cualquier cambio del script, actualizar versión y commit del documento.
