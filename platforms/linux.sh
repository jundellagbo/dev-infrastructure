#!/usr/bin/env bash

# A normal Linux box: systemd supervises, /usr/local/bin is shared, sudo works.
#
# wsl.sh sources this file and then overrides what the Windows host next door
# changes, so the work lives in linux_* functions and the platform_* hooks are
# thin wrappers over them - that way WSL can call the Linux behaviour and add to
# it rather than copying it.

platform_label() {
    local pretty=""
    # /etc/os-release is the one distro identity file everything ships. Sourced
    # in a subshell so its variables never land in the caller's shell.
    [ -r /etc/os-release ] && pretty="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}")"
    printf '%s\n' "${pretty:-Linux}"
}

platform_pkg_manager() {
    local mgr
    for mgr in apt-get dnf yum pacman zypper apk; do
        if command -v "$mgr" >/dev/null 2>&1; then
            printf '%s\n' "$mgr"
            return 0
        fi
    done
    printf '%s\n' none
}

# ------------------------------------------------------------------------ DNS

# dnsmasq answering 127.0.0.1 for the whole suffix, supervised by systemd, with
# systemd-resolved told to route that domain to it. Debian without resolved and
# WSL - whose resolv.conf is written by Windows - get the service without the
# hand-off, and a resolv.conf line instead.
linux_setup_dns() {
    local domain="$1" unit="infra-dev-local-dns.service" dnsmasq_bin post=""

    # Asked for here rather than by the caller: the platforms that can't do this
    # at all should say so instead of demanding root first.
    platform_require_root || return 1

    if ! infra_require_command dnsmasq; then
        infra_note "install it first, e.g. apt-get install dnsmasq"
        return 1
    fi
    dnsmasq_bin="$(command -v dnsmasq)"

    if ! command -v systemctl >/dev/null 2>&1; then
        infra_err "no systemd here, so there is no service to install"
        infra_note "run it yourself: ${dnsmasq_bin} $(infra_dnsmasq_args "$domain" | tr '\n' ' ')"
        return 1
    fi

    # resolvectl only means anything where systemd-resolved is actually the
    # resolver; its stub file is the evidence, since the binary can be installed
    # on a box that never runs it.
    if command -v resolvectl >/dev/null 2>&1 && [ -e /run/systemd/resolve/stub-resolv.conf ]; then
        local resolvectl_bin
        resolvectl_bin="$(command -v resolvectl)"
        post="ExecStartPost=${resolvectl_bin} dns lo 127.0.0.1
ExecStartPost=${resolvectl_bin} domain lo ~${domain}
ExecStartPost=${resolvectl_bin} default-route lo false"
    fi

    infra_info "Installing ${unit}..."
    cat > "/etc/systemd/system/${unit}" <<EOF
[Unit]
Description=Infra wildcard DNS for *.${domain}
After=network.target

[Service]
Type=simple
ExecStart=${dnsmasq_bin} $(infra_dnsmasq_args "$domain" | tr '\n' ' ')
${post}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$unit"
    infra_ok "${unit} started"

    if [ -z "$post" ]; then
        # Nothing to hand the domain to, so the stub has to be in resolv.conf
        # itself - which is exactly the file WSL regenerates on every boot.
        if grep -qE '^nameserver[[:space:]]+127\.0\.0\.1$' /etc/resolv.conf 2>/dev/null; then
            infra_ok "/etc/resolv.conf already points at 127.0.0.1"
        else
            infra_warn "systemd-resolved is not managing DNS here - point the resolver at dnsmasq:"
            infra_note 'sudo sed -i "1i nameserver 127.0.0.1" /etc/resolv.conf'
        fi
    fi
}

platform_setup_dns() { linux_setup_dns "$@"; }

# ---------------------------------------------------------------------- ports

linux_free_ports() {
    local services="apache2 nginx mysql postgresql" svc

    platform_require_root || return 1

    if command -v systemctl >/dev/null 2>&1; then
        infra_info "Stopping and disabling host services..."
        for svc in $services; do
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
        done
    else
        # WSL without systemd, or a container-ish box: the SysV wrappers are
        # still there and still the way to take a service down.
        infra_info "No systemd here - stopping via service(8)..."
        for svc in $services; do
            service "$svc" stop 2>/dev/null || true
        done
    fi
    infra_ok "Services stopped"

    if ! command -v apt-get >/dev/null 2>&1; then
        infra_warn "Not a Debian/Ubuntu box - services are stopped but not removed."
        infra_warn "  Remove them with $(platform_pkg_manager), e.g."
        infra_warn "  dnf remove httpd nginx mariadb-server postgresql-server"
        return 0
    fi

    infra_info "Uninstalling Apache2..."
    apt-get purge -y apache2 apache2-utils apache2-bin 'libapache2-mod-php*' 2>/dev/null || true
    rm -rf /etc/apache2 2>/dev/null || true

    infra_info "Uninstalling Nginx..."
    apt-get purge -y nginx nginx-common nginx-full 2>/dev/null || true
    rm -rf /etc/nginx 2>/dev/null || true

    # Only the packages go - a database's data directory is never this script's
    # to delete, on any platform.
    infra_info "Uninstalling MySQL..."
    apt-get purge -y mysql-server mysql-client mysql-common 2>/dev/null || true
    infra_warn "MySQL data kept at /var/lib/mysql - remove manually if needed"

    infra_info "Uninstalling PostgreSQL..."
    apt-get purge -y postgresql postgresql-contrib 2>/dev/null || true
    infra_warn "PostgreSQL data kept at /var/lib/postgresql - remove manually if needed"

    infra_info "Cleaning up..."
    apt-get autoremove -y 2>/dev/null || true
    apt-get autoclean -y 2>/dev/null || true
    infra_ok "Host web services removed"
}

platform_free_ports() { linux_free_ports "$@"; }

# ------------------------------------------------------------------------- CA

linux_trust_ca() {
    local crt="$1"
    echo "System trust store (curl, wget, composer, most tooling):"
    echo "  sudo cp \"${crt}\" /usr/local/share/ca-certificates/dev-local-ca.crt"
    echo "  sudo update-ca-certificates"
    echo ""
    echo "On Fedora/RHEL/Arch instead:"
    echo "  sudo cp \"${crt}\" /etc/pki/ca-trust/source/anchors/dev-local-ca.crt"
    echo "  sudo update-ca-trust"
    echo ""
    echo "Chrome and Chromium read their own NSS database, not that store:"
    echo "  certutil -d sql:\$HOME/.pki/nssdb -A -t 'C,,' -n dev-local-ca -i \"${crt}\""
}

platform_trust_ca() { linux_trust_ca "$@"; }
