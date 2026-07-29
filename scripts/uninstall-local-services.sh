#!/usr/bin/env bash

# Free the ports the Docker stack wants by taking down web services installed
# straight onto the host.
#
# How much of that is possible differs per platform - Debian purges packages,
# macOS can only stop Homebrew's services, Windows owns its own - so the work
# lives in platforms/<os>.sh and this script picks the ports and reports.
#
# Database data directories are never removed on any platform.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
PORTS="80 443 3306 5432 8080 8443"

. "${INFRA_DIR}/platforms/platform.sh"

infra_banner "Freeing Ports on $(platform_label)"

# The platform asks for root itself where it needs it - Windows has nothing here
# to stop and should say so rather than demand an Administrator shell first.
platform_free_ports || true

echo ""
infra_info "Checking the ports the stack needs..."
# shellcheck disable=SC2086
infra_report_ports $PORTS

infra_banner "Done" "$INFRA_GREEN"
echo "Ports the stack wants: ${PORTS}"
echo ""
echo "Start the Docker services:"
echo "  cd ${INFRA_DIR} && docker compose up -d"
echo ""
