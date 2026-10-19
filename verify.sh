#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
DC=(sudo docker compose)
echo '== Compose structure =='
"${DC[@]}" config --quiet
echo '== Service state (route jobs and arkime-init should exit 0) =='
"${DC[@]}" ps -a
echo '== Endpoint routes =='
"${DC[@]}" exec -T src ip route get 10.10.2.10
"${DC[@]}" exec -T dst ip route get 10.10.1.10
echo '== End-to-end ping =='
"${DC[@]}" exec -T src ping -c 2 -W 2 10.10.2.10
echo '== Forwarder processes =='
"${DC[@]}" exec -T src pgrep -a splunkd
"${DC[@]}" exec -T dst pgrep -a splunkd
echo '== Indexer receiver connectivity =='
"${DC[@]}" exec -T src ncat -z -w 3 10.10.1.30 9997
"${DC[@]}" exec -T dst ncat -z -w 3 10.10.2.30 9997
echo '== Test endpoint logs =='
"${DC[@]}" exec -T -u 0 src sh -c 'echo "action=test_message host=src" >> /endpoint-logs/activity.log'
"${DC[@]}" exec -T -u 0 dst sh -c 'echo "action=test_message host=dst" >> /endpoint-logs/activity.log'
echo '== OpenSearch =='
"${DC[@]}" exec -T opensearch curl -fsS http://localhost:9200/_cluster/health
echo
echo 'All command-line tests passed. In Splunk Web, select All time and search:'
echo 'index=main sourcetype="lab:endpoint" "action=test_message" | stats count by host'
