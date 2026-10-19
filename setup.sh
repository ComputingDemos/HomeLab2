#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
umask 022
mkdir -p pcaps zeek-logs arkime endpoint-logs/src endpoint-logs/dst
chmod 755 pcaps zeek-logs arkime endpoint-logs endpoint-logs/src endpoint-logs/dst
umask 077
if [[ ! -f .env ]]; then
  command -v openssl >/dev/null || { echo 'Install openssl first: sudo apt install -y openssl'; exit 1; }
  printf 'SPLUNK_PASSWORD=%s\nUF_ADMIN_PASSWORD=%s\n' \
    "$(openssl rand -hex 16)" "$(openssl rand -hex 16)" > .env
  echo 'Generated .env (keep it private).'
else
  grep -q '^SPLUNK_PASSWORD=' .env || { echo '.env missing SPLUNK_PASSWORD'; exit 1; }
  grep -q '^UF_ADMIN_PASSWORD=' .env || { echo '.env missing UF_ADMIN_PASSWORD'; exit 1; }
  echo 'Preserved existing .env credentials.'
fi
chmod 600 .env
# The Splunk process can read logs produced by root in these directories.
chmod 755 endpoint-logs endpoint-logs/src endpoint-logs/dst
printf '\nPrerequisite: vm.max_map_count >= 262144 for OpenSearch.\n'
cat /proc/sys/vm/max_map_count
