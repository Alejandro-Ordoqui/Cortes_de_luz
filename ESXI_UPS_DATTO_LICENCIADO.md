# ESXI_UPS_DATTO_LICENCIADO

**Versión:** 1.0.1  
**Branch:** develop  
**Commit de referencia:** 3d87b71cd060ab7782eb5e1a2509eb45e45e0585  
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

## Variables de Datto RMM

El componente utiliza variables de Datto RMM para que la política pueda duplicarse entre clientes sin modificar la lógica del script.

### Variables visibles
- ESXI_HOST
- ESXI_MONITOR_METHOD
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

### Variables protegidas/ocultas
- ESXI_CLI_USER
- ESXI_CLI_PASSWORD
- SNMP_COMMUNITY

El script solo referencia los nombres de las variables. Los valores de cada cliente se cargan en Datto RMM. Las variables protegidas no se muestran en la salida de diagnóstico.

### Modelo operativo
1. Guardar el script como componente de monitor.
2. Crear la política de Datto RMM y cargar sus variables.
3. Para un nuevo cliente, duplicar la política.
4. Modificar únicamente los valores de las variables del nuevo cliente.
5. Si Datto requiere nombres diferentes para variables protegidas, adaptar únicamente sus referencias en el script.

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
