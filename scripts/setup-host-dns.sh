#!/usr/bin/env bash

# Configure persistent wildcard DNS for *.dev.local on the host.
#
# Every platform gets there the same way - a dnsmasq answering 127.0.0.1 for the
# whole suffix - but each wires it up differently, so the work lives in
# platforms/<os>.sh and this script only picks the domain and reports.
#
# Run it with sudo (Administrator on Windows, where it will tell you there is
# nothing to configure).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
DOMAIN_SUFFIX="dev.local"

. "${INFRA_DIR}/platforms/platform.sh"

infra_banner "Wildcard DNS for *.${DOMAIN_SUFFIX} on $(platform_label)"

# The platform asks for root itself where it needs it - the ones that can't do
# this at all should explain that rather than demand a sudo first.
platform_setup_dns "$DOMAIN_SUFFIX" || exit 1

infra_info "Verifying..."
if infra_resolves_loopback "health.${DOMAIN_SUFFIX}"; then
    infra_ok "*.${DOMAIN_SUFFIX} resolves to 127.0.0.1"
else
    infra_warn "Could not verify wildcard DNS"
    infra_note "check with: ping -c1 health.${DOMAIN_SUFFIX}"
fi

infra_ok "Host DNS setup complete"
