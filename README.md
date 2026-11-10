# NetFlow MikroTik → ELK (Elastic Agent "NetFlow Records")

| Rol | IP | Acceso |
|---|---|---|
| Exportador (MikroTik RouterOS v6/v7) | 10.10.10.1 | SSH `admin` |
| Colector (VM Proxmox, ELK + Elastic Agent) | 10.10.10.14 | SSH `root` |
| Flujo | UDP 2055, NetFlow v9 | MikroTik → ELK |

## 1. Colector: filebeat (módulo netflow) en la VM
Esta VM usa **filebeat 9.x** (no Fleet). El módulo `netflow` viene deshabilitado y escuchando en `localhost`, por lo que no recibe nada de la red. Configuración aplicada (`/etc/filebeat/modules.d/netflow.yml`):
```yaml
- module: netflow
  log:
    enabled: true
    var:
      netflow_host: 0.0.0.0
      netflow_port: 2055
      internal_networks: [private]
```
y en `/etc/filebeat/filebeat.yml`, salida a Elasticsearch con HTTPS y credenciales desde el keystore (`filebeat keystore add ES_USER|ES_PWD`):
```yaml
output.elasticsearch:
  hosts: ["https://10.10.10.14:9200"]
  username: "${ES_USER}"
  password: "${ES_PWD}"
  ssl.certificate_authorities: ["/etc/elasticsearch/certs/http_ca.crt"]
```
Después: `filebeat setup --index-management && systemctl enable --now filebeat`.
(Con Elastic Agent/Fleet la integración "NetFlow Records" también debe escuchar en `0.0.0.0`, no en `localhost`.)

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
RouterOS v7 (probado en 7.23.2):
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
Kibana → Discover, data view `filebeat-*`, filtro `event.dataset : "netflow.log"`. (Con Elastic Agent los datos van a `logs-netflow.log-*`.)

## Problemas típicos
- `0 paquetes` en tcpdump → firewall de Proxmox (Datacenter/Node/VM → Firewall) o target mal configurado en el MikroTik.
- Paquetes llegan pero 0 documentos → host de la integración en `localhost`, o el agente aún no tiene la plantilla v9 (esperar ~1 min).
