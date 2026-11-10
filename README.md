# NetFlow MikroTik → ELK (Elastic Agent "NetFlow Records")

| Rol | IP | Acceso |
|---|---|---|
| Exportador (MikroTik RouterOS v6/v7) | 10.10.10.1 | SSH `admin` |
| Colector (VM Proxmox, ELK + Elastic Agent) | 10.10.10.14 | SSH `root` |
| Flujo | UDP 2055, NetFlow v9 | MikroTik → ELK |

## 1. Kibana: la integración tiene que escuchar en 0.0.0.0
Por defecto la integración **NetFlow Records** escucha en `localhost:2055`, así que **no recibe nada desde la red**.
Kibana → Fleet → Agent policies → (la política del agente de 10.10.10.14) → NetFlow Records → *Edit integration*:
- **UDP host to listen on**: `0.0.0.0`
- **UDP port to listen on**: `2055`
- *Save and deploy*

## 2. Ejecutar en la VM ELK (como root)
```bash
git clone https://github.com/JuanraLarrei/netflow.git && cd netflow
cp config.env.example config.env        # ajusta si cambian IPs/puerto
./scripts/setup-netflow.sh              # te pide la contraseña del MikroTik y la de 'elastic'
```
Por separado:
```bash
./scripts/mikrotik-traffic-flow.sh apply|show|remove   # configura/ver/quitar en el MikroTik por SSH
./scripts/elk-netflow-check.sh                         # agente, puerto, firewall, tcpdump, documentos en ES
```
Las contraseñas también se pueden pasar sin prompt: `MIKROTIK_PASS=... ES_PASS=... ./scripts/setup-netflow.sh`.

## 3. Lo que se aplica en el MikroTik
RouterOS v7:
```
/ip traffic-flow set enabled=yes interfaces=all active-flow-timeout=1m inactive-flow-timeout=15s
/ip traffic-flow target add dst-address=10.10.10.14 port=2055 version=9
```
RouterOS v6:
```
/ip traffic-flow set enabled=yes interfaces=all active-flow-timeout=1m inactive-flow-timeout=15s
/ip traffic-flow target add address=10.10.10.14:2055 version=9
```

## 4. Ver los datos
Kibana → Dashboards → `[Logs Netflow] Overview` (o Discover con el data view `logs-*`, filtro `data_stream.dataset : "netflow.log"`).

## Problemas típicos
- `0 paquetes` en tcpdump → firewall de Proxmox (Datacenter/Node/VM → Firewall) o target mal configurado en el MikroTik.
- Paquetes llegan pero 0 documentos → host de la integración en `localhost`, o el agente aún no tiene la plantilla v9 (esperar ~1 min).
