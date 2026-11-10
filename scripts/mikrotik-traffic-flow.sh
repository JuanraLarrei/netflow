#!/usr/bin/env bash
# Configura Traffic-Flow (NetFlow v9/IPFIX) en un MikroTik por SSH para enviar al colector ELK.
# Soporta RouterOS v6 y v7 (detecta la versión).
# Uso:  MIKROTIK_PASS='xxx' ./scripts/mikrotik-traffic-flow.sh [apply|show|remove]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /nonexistent)"
# shellcheck disable=SC1091
[[ -f "$SCRIPT_DIR/../config.env" ]] && source "$SCRIPT_DIR/../config.env"

MIKROTIK_IP="${MIKROTIK_IP:-10.10.10.1}"
MIKROTIK_SSH_PORT="${MIKROTIK_SSH_PORT:-22}"
MIKROTIK_USER="${MIKROTIK_USER:-admin}"
COLLECTOR_IP="${COLLECTOR_IP:-10.10.10.14}"
NETFLOW_PORT="${NETFLOW_PORT:-2055}"
NETFLOW_VERSION="${NETFLOW_VERSION:-9}"
FLOW_INTERFACES="${FLOW_INTERFACES:-all}"
ACTIVE_FLOW_TIMEOUT="${ACTIVE_FLOW_TIMEOUT:-1m}"
INACTIVE_FLOW_TIMEOUT="${INACTIVE_FLOW_TIMEOUT:-15s}"
ACTION="${1:-apply}"

log() { printf '\e[1;34m[mikrotik]\e[0m %s\n' "$*"; }
die() { printf '\e[1;31m[mikrotik] ERROR:\e[0m %s\n' "$*" >&2; exit 1; }

SSH_OPTS=(-p "$MIKROTIK_SSH_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10
          -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa)

if [[ -z "${MIKROTIK_PASS:-}" && -t 0 ]]; then
  read -rsp "Contraseña SSH de ${MIKROTIK_USER}@${MIKROTIK_IP}: " MIKROTIK_PASS; echo
fi

ros() {  # ejecuta comandos RouterOS en el router
  if [[ -n "${MIKROTIK_PASS:-}" ]]; then
    command -v sshpass >/dev/null || die "instala sshpass (apt install sshpass) o usa clave SSH"
    SSHPASS="$MIKROTIK_PASS" sshpass -e ssh "${SSH_OPTS[@]}" "${MIKROTIK_USER}@${MIKROTIK_IP}" "$1"
  else
    # shellcheck disable=SC2029  # expansión local intencionada
    ssh "${SSH_OPTS[@]}" "${MIKROTIK_USER}@${MIKROTIK_IP}" "$1"
  fi
}

show() {
  ros ':put "--- /ip traffic-flow ---"
/ip traffic-flow print
:put "--- /ip traffic-flow target ---"
/ip traffic-flow target print detail'
}

log "Conectando a ${MIKROTIK_USER}@${MIKROTIK_IP}:${MIKROTIK_SSH_PORT} ..."
VERSION_RAW="$(ros ':put [/system resource get version]' | tr -d '\r')" || die "no se pudo conectar por SSH"
MAJOR="$(grep -oE '^[[:space:]]*[0-9]+' <<<"$VERSION_RAW" | head -1 | tr -d '[:space:]')"
[[ -n "$MAJOR" ]] || die "no se pudo leer la versión de RouterOS (salida: '$VERSION_RAW')"
log "RouterOS detectado: ${VERSION_RAW}"

if (( MAJOR >= 7 )); then
  FIND_TARGET="[find dst-address=${COLLECTOR_IP} port=${NETFLOW_PORT}]"
  ADD_TARGET="/ip traffic-flow target add dst-address=${COLLECTOR_IP} port=${NETFLOW_PORT} version=${NETFLOW_VERSION}"
else
  FIND_TARGET="[find address=\"${COLLECTOR_IP}:${NETFLOW_PORT}\"]"
  ADD_TARGET="/ip traffic-flow target add address=${COLLECTOR_IP}:${NETFLOW_PORT} version=${NETFLOW_VERSION}"
fi

case "$ACTION" in
  show) show ;;
  remove)
    log "Eliminando destino ${COLLECTOR_IP}:${NETFLOW_PORT} y deshabilitando traffic-flow"
    ros "/ip traffic-flow target remove ${FIND_TARGET}
/ip traffic-flow set enabled=no"
    show ;;
  apply)
    log "Aplicando configuración traffic-flow -> ${COLLECTOR_IP}:${NETFLOW_PORT} (v${NETFLOW_VERSION})"
    # Idempotente: borra el destino si ya existía y lo vuelve a crear.
    # La plantilla v9 se reenvía cada 20 paquetes / 1 min para que Elastic decodifique pronto
    # (opcional: si la propiedad no existe en tu versión, se ignora).
    ros "/ip traffic-flow set enabled=yes interfaces=${FLOW_INTERFACES} active-flow-timeout=${ACTIVE_FLOW_TIMEOUT} inactive-flow-timeout=${INACTIVE_FLOW_TIMEOUT}
/ip traffic-flow target remove ${FIND_TARGET}
${ADD_TARGET}
:do { /ip traffic-flow target set ${FIND_TARGET} v9-template-refresh=20 v9-template-timeout=1m } on-error={ :put \"(aviso) v9-template-* no soportado, se omite\" }
:put \"OK traffic-flow configurado\""
    show ;;
  *) die "acción desconocida: $ACTION (usa apply|show|remove)" ;;
esac
