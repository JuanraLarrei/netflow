#!/usr/bin/env bash
# Ejecutar como root EN LA VM ELK (10.10.10.14).
# Comprueba/prepara la recepción NetFlow: Elastic Agent, puerto UDP, firewall, paquetes y documentos en Elasticsearch.
# Uso: ./scripts/elk-netflow-check.sh [--no-firewall] [--capture-seconds N]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -f "$SCRIPT_DIR/../config.env" ]] && source "$SCRIPT_DIR/../config.env"

MIKROTIK_IP="${MIKROTIK_IP:-10.10.10.1}"
NETFLOW_PORT="${NETFLOW_PORT:-2055}"
ES_URL="${ES_URL:-https://localhost:9200}"
ES_USER="${ES_USER:-elastic}"
CAPTURE_SECONDS="${CAPTURE_SECONDS:-20}"
DO_FIREWALL=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-firewall) DO_FIREWALL=0 ;;
    --capture-seconds) CAPTURE_SECONDS="$2"; shift ;;
    *) echo "opción desconocida: $1" >&2; exit 2 ;;
  esac; shift
done

ok()   { printf '\e[1;32m[ OK ]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[WARN]\e[0m %s\n' "$*"; WARNINGS=$((WARNINGS+1)); }
fail() { printf '\e[1;31m[FAIL]\e[0m %s\n' "$*"; FAILS=$((FAILS+1)); }
info() { printf '\e[1;34m[INFO]\e[0m %s\n' "$*"; }
WARNINGS=0; FAILS=0

[[ $EUID -eq 0 ]] || { echo "Ejecuta como root"; exit 1; }

# 1) Elastic Agent / Filebeat
if systemctl list-unit-files 2>/dev/null | grep -q '^elastic-agent'; then
  if systemctl is-active --quiet elastic-agent; then ok "elastic-agent activo"
  else fail "elastic-agent instalado pero parado -> systemctl enable --now elastic-agent"; fi
  if command -v elastic-agent >/dev/null; then
    elastic-agent status 2>/dev/null | grep -iE 'netflow|healthy|degraded|failed' | head -20 || true
  fi
elif systemctl list-unit-files 2>/dev/null | grep -q '^filebeat'; then
  info "No hay elastic-agent; se detecta filebeat (módulo netflow)"
  if systemctl is-active --quiet filebeat; then ok "filebeat activo"; else fail "filebeat parado"; fi
else
  warn "No se encuentra elastic-agent ni filebeat como servicio systemd"
fi

# 2) Puerto UDP a la escucha y en qué dirección
LISTEN="$(ss -H -lunp "sport = :${NETFLOW_PORT}" 2>/dev/null)"
if [[ -z "$LISTEN" ]]; then
  fail "Nada escucha en UDP ${NETFLOW_PORT}. En Kibana > Fleet > Agent policies > (política del agente) > NetFlow Records: comprueba que está asignada a ESTE agente y que el puerto es ${NETFLOW_PORT}"
else
  echo "$LISTEN"
  LOCAL_ADDR="$(awk '{print $4}' <<<"$LISTEN" | head -1)"
  case "$LOCAL_ADDR" in
    127.*|"[::1]"*|localhost*)
      fail "UDP ${NETFLOW_PORT} escucha solo en ${LOCAL_ADDR} (por defecto la integración usa host=localhost)."
      echo "       Arreglo: Kibana > Fleet > Agent policies > NetFlow Records > Edit integration > 'UDP host to listen on' = 0.0.0.0 > Save and deploy" ;;
    *) ok "UDP ${NETFLOW_PORT} escucha en ${LOCAL_ADDR} (accesible desde la red)" ;;
  esac
fi

# 3) Firewall local
if (( DO_FIREWALL )); then
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow proto udp from "$MIKROTIK_IP" to any port "$NETFLOW_PORT" comment 'NetFlow MikroTik' >/dev/null && ok "ufw: permitido UDP ${NETFLOW_PORT} desde ${MIKROTIK_IP}"
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${NETFLOW_PORT}/udp" >/dev/null && firewall-cmd --reload >/dev/null && ok "firewalld: abierto ${NETFLOW_PORT}/udp"
  elif command -v iptables >/dev/null && iptables -S INPUT 2>/dev/null | grep -qE '^-P INPUT (DROP|REJECT)'; then
    iptables -C INPUT -p udp -s "$MIKROTIK_IP" --dport "$NETFLOW_PORT" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p udp -s "$MIKROTIK_IP" --dport "$NETFLOW_PORT" -j ACCEPT
    ok "iptables: regla ACCEPT UDP ${NETFLOW_PORT} desde ${MIKROTIK_IP} (no persistente; usa iptables-persistent)"
  else
    ok "Sin firewall local activo que bloquee (revisa también el firewall de Proxmox en la VM/datacenter)"
  fi
fi

# 4) ¿Llegan paquetes del MikroTik?
if command -v tcpdump >/dev/null; then
  info "Capturando ${CAPTURE_SECONDS}s paquetes UDP ${NETFLOW_PORT} desde ${MIKROTIK_IP} ..."
  PKTS="$(timeout "$CAPTURE_SECONDS" tcpdump -i any -nn -l "udp and dst port ${NETFLOW_PORT} and src host ${MIKROTIK_IP}" 2>/dev/null | wc -l)"
  if (( PKTS > 0 )); then ok "Recibidos ${PKTS} paquetes NetFlow desde ${MIKROTIK_IP}"
  else fail "0 paquetes desde ${MIKROTIK_IP} en ${CAPTURE_SECONDS}s (revisa config del MikroTik / firewall Proxmox / que haya tráfico)"; fi
else
  warn "tcpdump no instalado (apt install tcpdump) – se omite la captura"
fi

# 5) ¿Hay documentos en Elasticsearch?
if [[ -z "${ES_PASS:-}" && -t 0 ]]; then read -rsp "Contraseña de Elasticsearch para ${ES_USER} (Enter para omitir): " ES_PASS; echo; fi
if [[ -n "${ES_PASS:-}" ]]; then
  Q='{"query":{"range":{"@timestamp":{"gte":"now-15m"}}}}'
  RESP="$(curl -sk -u "${ES_USER}:${ES_PASS}" -H 'Content-Type: application/json' \
          "${ES_URL}/logs-netflow.log-*/_count" -d "$Q" 2>&1)"
  COUNT="$(grep -oE '"count":[0-9]+' <<<"$RESP" | cut -d: -f2)"
  if [[ -n "$COUNT" && "$COUNT" -gt 0 ]]; then ok "Elasticsearch: ${COUNT} flujos en logs-netflow.log-* (últimos 15 min)"
  elif [[ -n "$COUNT" ]]; then warn "Elasticsearch: 0 documentos aún (la plantilla v9 puede tardar hasta ~1 min en llegar)"
  else fail "Consulta a Elasticsearch fallida: ${RESP:0:200}"; fi
fi

echo; info "Resumen: ${FAILS} fallos, ${WARNINGS} avisos"
(( FAILS == 0 ))
