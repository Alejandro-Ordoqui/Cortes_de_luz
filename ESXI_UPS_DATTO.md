# ESXI_UPS_DATTO

**Versión:** 1.0.0  
**Branch:** develop  
**Commit de referencia:** a68e411c6549ca961911770f813835acda03812d  
**Script:** ESXI_UPS_DATTO.ps1

## Objetivo
Monitorear VMware ESXi y una UPS APC desde Datto RMM, utilizando PowerCLI como método principal y SSH como respaldo opcional.

## Método
- PowerCLI/CLI como método principal.
- SSH como backup opcional mediante ESXI_HABILITAR_SSH_BACKUP.
- Contingencia ordenada según ORDEN_VMS.
- Ejecucion de Monitor siempre última.
- Verificación final de todas las VMs.
- El host solo se apaga después de comprobar que todas están PoweredOff.
- Un error SNMP no dispara automáticamente una contingencia.

## Variables
- ESXI_MONITOR_METHOD
- ESXI_CLI_USER / ESXI_CLI_PASSWORD
- ESXI_SSH_USER / ESXI_SSH_PASSWORD
- ESXI_HABILITAR_SSH_BACKUP
- ORDEN_VMS
- TIMEOUT_VM
- TIEMPO_ESPERA_VM
- TIEMPO_APAGADO_ESXI
- APAGAR_ESXI
- IP_UPS
- MODO_PRUEBA
- UMBRALES UPS
- MODO_CONTINGENCIA

## Prueba de laboratorio
ESXi: 192.168.0.188

Orden de laboratorio:
1. srv25
2. srv26
3. win10
4. Ejecucion de Monitor

Para probar únicamente las VMs, mantener APAGAR_ESXI=False.

## Regla
Este documento acompaña exclusivamente a ESXI_UPS_DATTO.ps1. No trasladar configuraciones del script licenciado ni del script original a este documento.
