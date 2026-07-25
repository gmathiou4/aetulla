#!/usr/bin/env bash
# Detects the correct OLLAMA_BASE_URL for this host's Docker setup.
# Prints the resolved URL to stdout; nothing else. Source or capture it:
#   OLLAMA_BASE_URL=$(bash installer/detect_ollama_host.sh)
set -euo pipefail

OLLAMA_PORT="${OLLAMA_PORT:-11434}"

is_wsl2() {
    grep -qi microsoft /proc/version 2>/dev/null
}

is_macos() {
    [[ "$(uname -s)" == "Darwin" ]]
}

docker_supports_host_gateway() {
    # host-gateway special value requires Docker Engine >= 20.10
    local ver
    ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0.0.0")
    local major minor
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
    [[ "$major" -gt 20 || ("$major" -eq 20 && "$minor" -ge 10) ]]
}

if is_wsl2 || is_macos; then
    # Docker Desktop (WSL2 backend) and Docker Desktop for Mac both provide
    # host.docker.internal out of the box.
    echo "http://host.docker.internal:${OLLAMA_PORT}"
    exit 0
fi

# Linux-native Docker Engine (no Docker Desktop).
if docker_supports_host_gateway; then
    # extra_hosts: host.docker.internal:host-gateway in docker-compose.yml
    # makes this resolve even on native Linux with Engine >= 20.10.
    echo "http://host.docker.internal:${OLLAMA_PORT}"
    exit 0
fi

# Fallback for old Docker Engine without host-gateway support: use the
# bridge network's gateway IP directly.
GATEWAY_IP=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo "172.17.0.1")
echo "http://${GATEWAY_IP}:${OLLAMA_PORT}"
