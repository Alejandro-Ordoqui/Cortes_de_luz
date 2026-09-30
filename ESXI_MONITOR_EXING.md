# ESXI_MONITOR_EXING

**Versión:** 1.5.0  
**Branch:** develop  
**Commit de referencia:** bbac4c98e296bb735f6244a2dd29f6ba414517fe  
**Script:** ESXI_MONITOR_EXING.ps1

## Objetivo
Monitorear ESXi y una UPS APC desde Datto RMM, manteniendo PowerCLI como método principal y SSH como respaldo configurable.

## Método
- CLI/PowerCLI como camino normal.
- SSH como backup opcional.
- ESXI_HABILITAR_SSH_BACKUP controla el backup SSH.
- ORDEN_VMS define la secuencia.
- Ejecucion de Monitor permanece última.
- Se verifica el estado final de todas las VMs antes del host.
- APAGAR_ESXI permite probar VMs sin apagar el host.
- El host utiliza el método implementado en la contingencia.
- Un error SNMP no autoriza un apagado automático.

## Variables principales
- ESXI_MONITOR_METHOD
- ESXI_CLI_USER / ESXI_CLI_PASSWORD
- ESXI_HABILITAR_SSH_BACKUP
- ORDEN_VMS
- TIMEOUT_VM
- TIEMPO_ESPERA_VM
- TIEMPO_APAGADO_ESXI
- APAGAR_ESXI
- IP_UPS
- MODO_PRUEBA
- Umbrales UPS
- MODO_CONTINGENCIA

## Pruebas
Primero laboratorio. Para validar únicamente VMs, APAGAR_ESXI=False. La prueba de host debe realizarse separadamente después de verificar las VMs.

## Regla
Este documento acompaña exclusivamente a ESXI_MONITOR_EXING.ps1. Ante cualquier modificación, actualizar versión y commit.
