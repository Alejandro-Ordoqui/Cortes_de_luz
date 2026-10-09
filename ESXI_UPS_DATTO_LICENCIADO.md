# ESXI_UPS_DATTO_LICENCIADO

**Versión:** 1.0.2  
**Branch:** develop  
**Commit de referencia:** 2d20cacf91ca4981be1c89ec1da1c3bf6a2007f3  
**Script:** ESXI_UPS_DATTO_LICENCIADO.ps1

## Objetivo
Monitorear un ESXi licenciado mediante un componente de monitor de Datto RMM y PowerCLI, integrando una UPS APC por SNMP y ejecutando, cuando corresponde, una contingencia ordenada de las VMs. El script informa el estado actual del host ESXi y no lo apaga.

## Método
- PowerCLI como único método VMware.
- Sin SSH.
- Shutdown-VMGuest para apagado ordenado de VMs.
- Ejecucion de Monitor siempre última.
- Verificación de TODAS las VMs como PoweredOff antes del host.
- Informe del estado de conexión y del estado de energía del host mediante PowerCLI.
- El script no incluye una acción de apagado del host ESXi.
- Un error SNMP nunca dispara un apagado automático.

## Variables de Datto RMM

El componente utiliza variables de Datto RMM para que la política pueda duplicarse entre clientes sin modificar la lógica del script.

### Variables visibles
- ESXI_HOST
- ESXI_MONITOR_METHOD
- ORDEN_VMS
- TIMEOUT_VM
- TIEMPO_ESPERA_VM
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
1. Guardar el script como componente de monitor de Datto RMM (no como Job Component).
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
6. Mantener Ejecucion de Monitor como última VM en ORDEN_VMS.
7. Verificar nuevamente todas las VMs configuradas.
8. Informar el estado de conexión y energía del host ESXi. El script no ejecuta su apagado.

## Pruebas
Para las pruebas, MODO_PRUEBA=True simula una condición crítica de UPS; si MODO_CONTINGENCIA=True, se ejecutará el apagado real de las VM enumeradas en ORDEN_VMS. Usar únicamente las VM de prueba autorizadas. El host ESXi no se apaga desde este script.

## Regla
Este documento acompaña exclusivamente a ESXI_UPS_DATTO_LICENCIADO.ps1. Ante cualquier cambio del script, actualizar versión y commit del documento.
