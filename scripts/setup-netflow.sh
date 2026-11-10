#!/usr/bin/env bash
# Orquestador: ejecutar como root en la VM ELK (10.10.10.14).
#   1) prepara/verifica el colector  2) configura el MikroTik por SSH  3) verifica que llegan flujos
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v sshpass >/dev/null || { apt-get update -qq && apt-get install -y -qq sshpass tcpdump; }
"$DIR/elk-netflow-check.sh" --capture-seconds 1 >/dev/null 2>&1 || true   # abre firewall
"$DIR/mikrotik-traffic-flow.sh" apply
echo; echo "Esperando 60s a que el MikroTik exporte flujos y plantillas..."; sleep 60
"$DIR/elk-netflow-check.sh" --capture-seconds 20
