#!/bin/bash

# Install PHP (multiple versions + switcher), Composer, WP-CLI, Node and the
# starship prompt on the host.
#
#   sudo ./install.sh                          # everything: PHP 8.3, default 8.3
#   sudo ./install.sh --versions 8.2 8.3 8.4   # only these (also: --versions=8.2,8.3)
#   sudo ./install.sh --default 8.2            # pick the default CLI version
#   sudo ./install.sh --no-composer --no-wp    # skip the extras
#   sudo ./install.sh --no-node                # skip Node/nvm
#   sudo ./install.sh --node-version 20        # install this Node major (default: --lts)
#   sudo ./install.sh --no-starship            # skip the starship prompt
#
# Component selectors: --php --composer --wp --node --starship
#
# On their own they install ONLY what they name, and reinstall it if it is
# already there. After --uninstall they remove only what they name.
#
#   sudo ./install.sh --node                   # (re)install just Node via nvm
#   sudo ./install.sh --starship               # (re)install the prompt and its config
#   sudo ./install.sh --php 8.2 8.3            # only these PHP versions
#   sudo ./install.sh --uninstall --php 8.1 8.2 # uninstall selected PHP versions
#   sudo ./install.sh --uninstall               # uninstall everything managed here
#
# Afterwards "phpsw" switches the active CLI/FPM version and "nvm" switches Node:
#
#   phpsw          # list installed PHP versions
#   phpsw 8.2      # make 8.2 the default
#   nvm ls         # list installed Node versions
#   nvm use 20     # switch the active Node version
#
# The Claude Code CLI, its MCP servers and its plugins are installed separately:
# see install.sh in the llm-infrastructure repo.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_info() { echo -e "${BLUE}→ $1${NC}"; }
print_warning() { echo -e "${YELLOW}! $1${NC}"; }

PHP_VERSIONS="8.3"
DEFAULT_VERSION="8.3"
INSTALL_PHP=1
INSTALL_COMPOSER=1
INSTALL_WPCLI=1
INSTALL_NODE=1
NODE_VERSION="--lts"
INSTALL_STARSHIP=1
UNINSTALL_PHP=0
UNINSTALL_COMPOSER=0
UNINSTALL_WPCLI=0
UNINSTALL_NODE=0
UNINSTALL_STARSHIP=0
UNINSTALL_ALL=0

# Component selectors (--php, --node, ...) mean "only these": which side they
# apply to depends on whether --uninstall came along.
SEL_PHP=0
SEL_COMPOSER=0
SEL_WPCLI=0
SEL_NODE=0
SEL_STARSHIP=0
selector=0
# Picking a component explicitly means "(re)do this one", so the install steps
# that normally skip an already-present tool run anyway.
FORCE_REINSTALL=0

# --versions takes one or more versions: "--versions 8.2 8.3", --versions=8.2,8.3
# and --versions "8.2 8.3" all mean the same thing.
picked_versions=""
add_versions() {
    local v
    for v in $(printf '%s' "$1" | tr ',' ' '); do
        picked_versions="$picked_versions $v"
    done
}

while [ $# -gt 0 ]; do
    case "$1" in
        --versions|-V)      add_versions "$2"; shift ;;
        --versions=*)       add_versions "${1#*=}" ;;
        --uninstall)        UNINSTALL_MODE=1 ;;
        --php)              SEL_PHP=1; selector=1 ;;
        --composer)         SEL_COMPOSER=1; selector=1 ;;
        --wp|--wpcli)       SEL_WPCLI=1; selector=1 ;;
        --node)             SEL_NODE=1; selector=1 ;;
        --starship)         SEL_STARSHIP=1; selector=1 ;;
        --default|-d)       DEFAULT_VERSION="$2"; shift ;;
        --default=*)        DEFAULT_VERSION="${1#*=}" ;;
        --no-composer)      INSTALL_COMPOSER=0 ;;
        --no-wp|--no-wpcli) INSTALL_WPCLI=0 ;;
        --no-node)          INSTALL_NODE=0 ;;
        --no-starship)      INSTALL_STARSHIP=0 ;;
        --node-version)     NODE_VERSION="$2"; shift ;;
        --node-version=*)   NODE_VERSION="${1#*=}" ;;
        -h|--help)
            # The header comment is the help text: everything from line 3 up to
            # the first non-comment line, so it can't drift out of range.
            awk 'NR > 2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
            exit 0 ;;
        # Bare version numbers extend the list: "--versions 8.2 8.3 8.4"
        [0-9].[0-9]|[0-9].[0-9][0-9]) add_versions "$1" ;;
        *) print_error "unknown option: $1"; exit 1 ;;
    esac
    shift
done

if [ -n "$picked_versions" ]; then
    PHP_VERSIONS="${picked_versions# }"
fi

UNINSTALL_MODE="${UNINSTALL_MODE:-0}"

if [ "$UNINSTALL_MODE" -eq 1 ]; then
    if [ "$selector" -eq 0 ]; then
        # Bare --uninstall means everything this script manages
        UNINSTALL_ALL=1
        SEL_PHP=1; SEL_COMPOSER=1; SEL_WPCLI=1; SEL_NODE=1; SEL_STARSHIP=1
    fi
    UNINSTALL_PHP=$SEL_PHP
    UNINSTALL_COMPOSER=$SEL_COMPOSER
    UNINSTALL_WPCLI=$SEL_WPCLI
    UNINSTALL_NODE=$SEL_NODE
    UNINSTALL_STARSHIP=$SEL_STARSHIP
elif [ "$selector" -eq 1 ]; then
    # Install mode with selectors: only the named components, and they are
    # (re)installed rather than skipped as already-present. --no-* is redundant
    # here - anything not selected is off already.
    INSTALL_PHP=$SEL_PHP
    INSTALL_COMPOSER=$SEL_COMPOSER
    INSTALL_WPCLI=$SEL_WPCLI
    INSTALL_NODE=$SEL_NODE
    INSTALL_STARSHIP=$SEL_STARSHIP
    FORCE_REINSTALL=1
fi

if [ -n "$picked_versions" ] && [ "$selector" -eq 1 ] && [ "$SEL_PHP" -eq 0 ]; then
    print_error "PHP versions require the --php selector"
    exit 1
fi

for version in $PHP_VERSIONS; do
    case "$version" in
        [0-9].[0-9]|[0-9].[0-9][0-9]) ;;
        *) print_error "invalid PHP version: $version"; exit 1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run with sudo"
    exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
    print_error "This installer targets Debian/Ubuntu (apt-get not found)"
    exit 1
fi

TOOL_USER="${SUDO_USER:-root}"
TOOL_HOME="$(getent passwd "$TOOL_USER" | cut -d: -f6)"
TOOL_HOME="${TOOL_HOME:-$HOME}"
run_as_user() { su - "$TOOL_USER" -c "$1"; }

# --------------------------------------------------------------- uninstall PHP

if [ "$UNINSTALL_MODE" -eq 1 ]; then
    if [ "$UNINSTALL_PHP" -eq 1 ]; then
        if [ -z "$picked_versions" ]; then
            PHP_VERSIONS="$(dpkg-query -W -f='${Package}\n' 'php[0-9].[0-9]-cli' 2>/dev/null \
                | sed -n 's/^php\([0-9][0-9]*\.[0-9][0-9]*\)-cli$/\1/p' | sort -Vu)"
        fi

        if [ -z "$PHP_VERSIONS" ]; then
            print_warning "No PHP versions are installed"
        fi

    for version in $PHP_VERSIONS; do
        print_info "Uninstalling PHP ${version}..."
        pkgs="$(dpkg-query -W -f='${Package}\n' 2>/dev/null | awk -v prefix="php${version}" '
            $0 == prefix || index($0, prefix "-") == 1
        ')"

        if [ -z "$pkgs" ]; then
            print_warning "PHP ${version} is not installed - skipping"
            continue
        fi

        # shellcheck disable=SC2086
        apt-get purge -y -qq $pkgs >/dev/null
        print_success "PHP ${version} uninstalled"
    done

    remaining="$(ls -1 /usr/bin/php[0-9].[0-9] 2>/dev/null | sed 's#.*/php##' | sort -V)"
    if [ -n "$remaining" ]; then
        fallback="$(printf '%s\n' "$remaining" | tail -1)"
        if [ -x /usr/local/bin/phpsw ]; then
            print_info "Switching the default to remaining PHP ${fallback}..."
            /usr/local/bin/phpsw "$fallback"
        fi
        print_info "Remaining PHP versions: $(printf '%s\n' "$remaining" | tr '\n' ' ')"
    else
        print_warning "No PHP versions remain installed"
    fi
    fi

    if [ "$UNINSTALL_COMPOSER" -eq 1 ]; then
        print_info "Uninstalling Composer..."
        rm -f /usr/local/bin/composer /etc/profile.d/composer.sh
        print_success "Composer uninstalled"
    fi

    if [ "$UNINSTALL_WPCLI" -eq 1 ]; then
        print_info "Uninstalling WP-CLI..."
        rm -f /usr/local/bin/wp /usr/local/bin/wp-cli.phar
        print_success "WP-CLI uninstalled"
    fi

    if [ "$UNINSTALL_NODE" -eq 1 ]; then
        print_info "Uninstalling Node and nvm for ${TOOL_USER}..."
        rm -rf "${TOOL_HOME}/.nvm"
        print_success "Node and nvm uninstalled"
    fi

    if [ "$UNINSTALL_STARSHIP" -eq 1 ]; then
        print_info "Uninstalling starship..."
        rm -f /usr/local/bin/starship
        # Only the config this script wrote - one the user edited or brought
        # themselves loses the marker line and is theirs to keep.
        starship_toml="${TOOL_HOME}/.config/starship.toml"
        if [ -f "$starship_toml" ] && grep -q '^# managed by infra install.sh' "$starship_toml"; then
            rm -f "$starship_toml"
            print_info "removed the generated ${starship_toml}"
        fi
        # The machine-wide init drop-in is always ours - drop it too.
        rm -f /etc/profile.d/starship.sh
        # And the statusLine script + its settings entry, when the entry is ours.
        rm -f "${TOOL_HOME}/.config/starship-statusline.sh"
        claude_settings="${TOOL_HOME}/.claude/settings.json"
        if [ -f "$claude_settings" ] && command -v jq >/dev/null 2>&1; then
            cur_sl="$(jq -r '.statusLine.command // ""' "$claude_settings" 2>/dev/null)"
            case "$cur_sl" in
                *starship-statusline*)
                    tmp="$(mktemp)"
                    if jq 'del(.statusLine)' "$claude_settings" > "$tmp" 2>/dev/null; then
                        mv "$tmp" "$claude_settings"
                        chown "$TOOL_USER" "$claude_settings" 2>/dev/null || true
                        print_info "removed the starship statusLine from ${claude_settings}"
                    else
                        rm -f "$tmp"
                    fi ;;
            esac
        fi
        print_success "starship uninstalled - git.sh falls back to its own prompt"
    fi

    if [ "$UNINSTALL_ALL" -eq 1 ]; then
        rm -f /usr/local/bin/phpsw
        print_success "phpsw uninstalled"
    fi

    print_success "Uninstall complete"
    exit 0
fi

case " $PHP_VERSIONS " in
    *" $DEFAULT_VERSION "*) ;;
    *)  # Fall back to the newest version actually being installed
        for v in $PHP_VERSIONS; do DEFAULT_VERSION="$v"; done ;;
esac

export DEBIAN_FRONTEND=noninteractive

print_info "PHP versions: ${PHP_VERSIONS} (default ${DEFAULT_VERSION})"

# Extensions every Laravel app needs, plus the WordPress/dev extras.
# Laravel requires ctype, curl, dom, fileinfo, filter, hash, mbstring, openssl,
# pcre, pdo, session and tokenizer - those ship inside -cli/-common/-xml.
PHP_EXTENSIONS="
bcmath
bz2
cli
common
curl
dev
fpm
gd
gmp
igbinary
imagick
imap
intl
ldap
mbstring
memcached
msgpack
mysql
opcache
pgsql
readline
redis
soap
sqlite3
tidy
xdebug
xml
xsl
zip
"

# ---------------------------------------------------------------- repositories

# The full prerequisite set is only needed by the apt-installed components.
# Selecting just a per-user tool (--node) shouldn't drag an apt update along -
# that installer only needs curl.
if [ $INSTALL_PHP -eq 1 ] || [ $INSTALL_COMPOSER -eq 1 ] || [ $INSTALL_WPCLI -eq 1 ]; then
    print_info "Installing prerequisites..."
    apt-get update -qq
    apt-get install -y -qq \
        ca-certificates \
        apt-transport-https \
        software-properties-common \
        lsb-release \
        gnupg \
        curl \
        unzip \
        git >/dev/null
    print_success "Prerequisites installed"
elif ! command -v curl >/dev/null 2>&1; then
    print_info "Installing curl..."
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl >/dev/null
    print_success "curl installed"
fi

if [ $INSTALL_PHP -eq 1 ]; then
    if grep -rqs "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then
        print_info "ondrej/php repository already present"
    else
        print_info "Adding the ondrej/php repository..."
        add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1 || {
            print_error "Failed to add ppa:ondrej/php"
            exit 1
        }
        print_success "Repository added"
    fi

    apt-get update -qq
fi

# ------------------------------------------------------------------ php builds

# Not every extension exists for every version, so filter against the real
# package index instead of letting one missing package fail the whole install.
packages_for() {
    local version="$1" ext pkg available=""
    for ext in $PHP_EXTENSIONS; do
        pkg="php${version}-${ext}"
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            available="$available $pkg"
        else
            print_warning "skipping $pkg (not available)" >&2
        fi
    done
    printf '%s\n' "$available"
}

if [ $INSTALL_PHP -eq 1 ]; then
    for version in $PHP_VERSIONS; do
        print_info "Installing PHP ${version}..."
        pkgs="$(packages_for "$version")"
        if [ -z "$pkgs" ]; then
            print_error "No packages found for PHP ${version} - skipping"
            continue
        fi
        # shellcheck disable=SC2086
        apt-get install -y -qq $pkgs >/dev/null || {
            print_error "PHP ${version} installation failed"
            exit 1
        }
        # Xdebug is installed but left off - "phpenmod -v <version> xdebug" turns it on
        if command -v phpdismod >/dev/null 2>&1; then
            phpdismod -v "$version" xdebug >/dev/null 2>&1 || true
        fi
        print_success "PHP ${version} installed"
    done
fi

# ---------------------------------------------------------------- php switcher

# phpsw only makes sense next to the PHP builds, so it follows the same gate.
# The heredoc below is left unindented on purpose - it is the script's source.
if [ $INSTALL_PHP -eq 1 ]; then

print_info "Installing the phpsw version switcher..."
cat > /usr/local/bin/phpsw << 'SWITCHER'
#!/bin/bash
#
# Switch the default PHP version (CLI + FPM).
#
#   phpsw          list installed versions
#   phpsw 8.2      switch to PHP 8.2

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

installed_versions() {
    ls -1 /usr/bin/php[0-9].[0-9] 2>/dev/null | sed 's#.*/php##' | sort -V
}

if [ -z "$1" ]; then
    current="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)"
    echo "installed PHP versions:"
    for v in $(installed_versions); do
        if [ "$v" = "$current" ]; then
            echo -e "  ${GREEN}* ${v}${NC}"
        else
            echo "    ${v}"
        fi
    done
    echo ""
    echo "usage: phpsw <version>"
    exit 0
fi

version="$1"
if [ ! -x "/usr/bin/php${version}" ]; then
    echo -e "${RED}✗ PHP ${version} is not installed${NC}" >&2
    echo "installed: $(installed_versions | tr '\n' ' ')" >&2
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

for binary in php phar phar.phar php-config phpize; do
    [ -x "/usr/bin/${binary}${version}" ] || continue
    update-alternatives --set "$binary" "/usr/bin/${binary}${version}" >/dev/null 2>&1 ||
        update-alternatives --install "/usr/bin/${binary}" "$binary" \
            "/usr/bin/${binary}${version}" 100 >/dev/null 2>&1 || true
done

# Keep only the selected FPM pool running so the socket path is predictable
if command -v systemctl >/dev/null 2>&1; then
    for v in $(installed_versions); do
        service="php${v}-fpm.service"
        systemctl list-unit-files "$service" >/dev/null 2>&1 || continue
        if [ "$v" = "$version" ]; then
            systemctl enable --now "$service" >/dev/null 2>&1 || true
            systemctl restart "$service" >/dev/null 2>&1 || true
        else
            systemctl disable --now "$service" >/dev/null 2>&1 || true
        fi
    done
fi

echo -e "${GREEN}✓ now using $(php -v | head -1)${NC}"
echo -e "${BLUE}→ fpm socket: /run/php/php${version}-fpm.sock${NC}"
SWITCHER
chmod +x /usr/local/bin/phpsw
print_success "phpsw installed"

print_info "Setting PHP ${DEFAULT_VERSION} as the default..."
/usr/local/bin/phpsw "$DEFAULT_VERSION"

fi

# -------------------------------------------------------------------- composer

if [ $INSTALL_COMPOSER -eq 1 ]; then
    print_info "Installing Composer..."
    expected="$(curl -fsSL https://composer.github.io/installer.sig)"
    tmp="$(mktemp -d)"
    curl -fsSL https://getcomposer.org/installer -o "${tmp}/composer-setup.php"
    actual="$(php -r "echo hash_file('sha384', '${tmp}/composer-setup.php');")"
    if [ "$expected" != "$actual" ]; then
        rm -rf "$tmp"
        print_error "Composer installer checksum mismatch - aborting"
        exit 1
    fi
    php "${tmp}/composer-setup.php" --quiet --install-dir=/usr/local/bin --filename=composer
    rm -rf "$tmp"

    # Composer refuses to run plugins/scripts as root without this; dev box, so allow it
    cat > /etc/profile.d/composer.sh << 'EOF'
export COMPOSER_ALLOW_SUPERUSER=1
export PATH="$PATH:$HOME/.config/composer/vendor/bin:$HOME/.composer/vendor/bin"
EOF
    chmod 644 /etc/profile.d/composer.sh
    print_success "Composer installed"
fi

# ---------------------------------------------------------------------- wp-cli

if [ $INSTALL_WPCLI -eq 1 ]; then
    print_info "Installing WP-CLI..."
    curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
        -o /usr/local/bin/wp-cli.phar
    chmod +x /usr/local/bin/wp-cli.phar

    # Wrapper so root doesn't have to remember --allow-root every single time
    cat > /usr/local/bin/wp << 'EOF'
#!/bin/bash
if [ "$EUID" -eq 0 ]; then
    case " $* " in
        *" --allow-root "*) ;;
        *) set -- --allow-root "$@" ;;
    esac
fi
exec /usr/local/bin/wp-cli.phar "$@"
EOF
    chmod +x /usr/local/bin/wp
    print_success "WP-CLI installed"
fi

# ------------------------------------------------------------------ node / nvm

# nvm is a per-user tool: it installs into a home directory and runs from a
# login shell, so target the user who invoked sudo (not root) - that's whose
# shell will actually use it.

if [ $INSTALL_NODE -eq 1 ]; then
    print_info "Installing Node via nvm..."

    # "20" and "--lts" both mean an install target; only "--lts" needs the
    # lts/* alias for a persistent default.
    if [ "$NODE_VERSION" = "--lts" ]; then
        node_default="lts/*"
    else
        node_default="$NODE_VERSION"
    fi

    if [ -s "$TOOL_HOME/.nvm/nvm.sh" ]; then
        print_info "nvm already present for ${TOOL_USER}"
    else
        run_as_user 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash >/dev/null 2>&1' \
            && print_success "nvm installed for ${TOOL_USER}" \
            || print_warning "nvm install failed for ${TOOL_USER} - skipping Node"
    fi

    if [ -s "$TOOL_HOME/.nvm/nvm.sh" ]; then
        run_as_user "export NVM_DIR=\"\$HOME/.nvm\"; . \"\$NVM_DIR/nvm.sh\"; nvm install ${NODE_VERSION} && nvm alias default '${node_default}'" >/dev/null 2>&1 \
            && print_success "Node ${NODE_VERSION} installed (default: ${node_default})" \
            || print_warning "Node ${NODE_VERSION} installation failed"
    fi
fi

# -------------------------------------------------------------------- starship

# The prompt itself. Installed to /usr/local/bin rather than a home directory so
# every user on the box gets the same one, and so a root shell renders the same
# prompt as the invoking user's. git.sh picks it up when it is on PATH and keeps
# its own PS1 as the fallback, so neither half depends on the other.
if [ $INSTALL_STARSHIP -eq 1 ]; then
    print_info "Installing starship..."

    if [ -x /usr/local/bin/starship ] && [ $FORCE_REINSTALL -eq 0 ]; then
        print_info "starship already present"
    else
        # -y skips the confirmation prompt, -b picks the bin dir. The installer
        # writes nothing outside it - the shell wiring is git.sh's job.
        curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b /usr/local/bin >/dev/null 2>&1 \
            && print_success "starship installed" \
            || print_warning "starship install failed - see https://starship.rs"
    fi

    # The config belongs to the user whose shell renders the prompt, not root.
    # A config already there is left alone unless --starship asked for a reset:
    # it is a file people tune, and clobbering it on every run would undo that.
    starship_toml="${TOOL_HOME}/.config/starship.toml"
    if [ -f "$starship_toml" ] && [ $FORCE_REINSTALL -eq 0 ]; then
        print_info "starship config already at ${starship_toml}"
    elif [ -x /usr/local/bin/starship ]; then
        run_as_user 'mkdir -p "$HOME/.config"'
        # Directory and git branch, in the shape the old hand-rolled PS1 had:
        # user@host:/current/path (branch:status)$
        cat > "$starship_toml" << 'EOF'
# managed by infra install.sh - delete this line to keep your own edits
"$schema" = 'https://starship.rs/config-schema.json'

add_newline = false
format = "$username$hostname$directory$git_branch$git_status$character"

[username]
show_always = true
style_user = "green"
style_root = "red"
format = "[$user]($style)"

[hostname]
ssh_only = false
style = "green"
format = "[@$hostname]($style):"

[directory]
style = "blue"
truncate_to_repo = false
truncation_length = 0
format = "[$path]($style)"

[git_branch]
style = "yellow"
format = "[ \\($branch]($style)"

[git_status]
style = "yellow"
format = "[$all_status$ahead_behind\\)]($style)"
conflicted = "!"
untracked = "?"
modified = "*"
staged = "+"
renamed = "r"
deleted = "x"
stashed = "\\$"
ahead = "^${count}"
behind = "v${count}"
diverged = "^v"
up_to_date = ""

[character]
success_symbol = "[\\$](white)"
error_symbol = "[\\$](red)"
EOF
        chown "$TOOL_USER" "$starship_toml" 2>/dev/null || true
        print_success "starship config written to ${starship_toml}"
    fi

    # Machine-wide init. The per-user prompt is wired through git.sh, sourced
    # from ~/.bashrc - but a login shell reads ~/.profile, and the shells claude,
    # codex and other agents open often never source ~/.bashrc at all, so they
    # fall back to bash's default prompt with no directory or branch. A profile.d
    # drop-in runs for every interactive shell that reads /etc/profile (login
    # shells, most agent terminals) and starts starship there too. It is guarded
    # so it never double-inits when git.sh already ran, and is (re)written on
    # every run - it is managed, not a file people tune - so the fix lands even
    # when the user config above was left in place.
    if [ -x /usr/local/bin/starship ]; then
        cat > /etc/profile.d/starship.sh << 'EOF'
# managed by infra install.sh - machine-wide starship prompt for login and
# agent shells that never source a per-user ~/.bashrc. Edits are overwritten.
case $- in *i*) ;; *) return 0 2>/dev/null || exit 0 ;; esac
if command -v starship >/dev/null 2>&1; then
    declare -F starship_precmd >/dev/null 2>&1 || eval "$(starship init bash)"
fi
EOF
        chmod 644 /etc/profile.d/starship.sh
        print_success "starship init written to /etc/profile.d/starship.sh"
    fi

    # Agents (claude, codex, ...) take over the whole terminal, so the shell
    # prompt never shows while you are inside one. Claude Code's statusLine runs
    # a command and renders its output at the bottom of that UI - point it at the
    # same starship render and the branch and path show inside the agent too.
    # The script sits next to starship.toml and is managed like it; the settings
    # merge is jq so the file's other keys (hooks, theme, ...) are untouched, and
    # it only writes when the statusLine is unset or already ours - a hand-tuned
    # one is left alone.
    if [ -x /usr/local/bin/starship ]; then
        statusline_sh="${TOOL_HOME}/.config/starship-statusline.sh"
        run_as_user 'mkdir -p "$HOME/.config"'
        cat > "$statusline_sh" << 'EOF'
#!/usr/bin/env bash
# managed by infra install.sh --starship - Claude Code statusLine that renders
# the starship prompt for the session's directory, so branch and path show
# inside the agent's UI. Overwritten on every --starship run.
input="$(cat)"
dir=""
command -v jq >/dev/null 2>&1 && dir="$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)"
[ -n "$dir" ] && [ -d "$dir" ] && cd "$dir" 2>/dev/null
command -v starship >/dev/null 2>&1 || exit 0
# Strip the \[ \] readline markers and the \$ the character module escapes for
# PS1 - a status line wants plain ANSI, not prompt escaping.
starship prompt 2>/dev/null | sed 's/\\\[//g; s/\\\]//g; s/\\[$]/$/g' | tr -d '\n'
EOF
        chmod 755 "$statusline_sh"
        chown "$TOOL_USER" "$statusline_sh" 2>/dev/null || true
        print_success "starship statusLine script written to ${statusline_sh}"

        claude_settings="${TOOL_HOME}/.claude/settings.json"
        if command -v jq >/dev/null 2>&1; then
            run_as_user 'mkdir -p "$HOME/.claude"'
            [ -f "$claude_settings" ] || printf '{}\n' > "$claude_settings"
            cur_sl="$(jq -r '.statusLine.command // ""' "$claude_settings" 2>/dev/null)"
            case "$cur_sl" in
                ""|*starship-statusline*)
                    tmp="$(mktemp)"
                    if jq --arg c '~/.config/starship-statusline.sh' \
                          '.statusLine = {type:"command", command:$c, padding:0}' \
                          "$claude_settings" > "$tmp" 2>/dev/null; then
                        mv "$tmp" "$claude_settings"
                        print_success "Claude Code statusLine now shows the starship prompt"
                    else
                        rm -f "$tmp"
                        print_warning "could not update ${claude_settings} - set statusLine by hand"
                    fi ;;
                *)
                    print_info "Claude Code already has a custom statusLine - left it alone" ;;
            esac
            chown "$TOOL_USER" "$claude_settings" 2>/dev/null || true
        else
            print_warning "jq not found - skipped Claude statusLine wiring (install jq, then re-run --starship)"
        fi
    fi
fi

# ------------------------------------------------------------------------ done

echo ""
print_success "Installation complete"
echo ""
# Report only what this run touched, and only with `if` - under `set -e` a
# trailing "[ test ] && echo" that tests false ends the script right here,
# before the shell integration below ever runs.
if [ $INSTALL_PHP -eq 1 ]; then
    echo "  php       $(php -v 2>/dev/null | head -1)"
fi
if [ $INSTALL_COMPOSER -eq 1 ]; then
    echo "  composer  $(COMPOSER_ALLOW_SUPERUSER=1 composer --version --no-ansi 2>/dev/null | head -1)"
fi
if [ $INSTALL_WPCLI -eq 1 ]; then
    echo "  wp        $(wp --version 2>/dev/null | head -1)"
fi
if [ $INSTALL_NODE -eq 1 ]; then
    node_ver="$(su - "${SUDO_USER:-root}" -c 'export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh" 2>/dev/null; node --version' 2>/dev/null | tail -1)"
    if [ -n "$node_ver" ]; then
        echo "  node      ${node_ver} (via nvm)"
    fi
fi
if [ $INSTALL_STARSHIP -eq 1 ] && [ -x /usr/local/bin/starship ]; then
    echo "  starship  $(/usr/local/bin/starship --version 2>/dev/null | head -1)"
fi
echo ""
if [ $INSTALL_PHP -eq 1 ]; then
    echo "  installed: $(ls -1 /usr/bin/php[0-9].[0-9] 2>/dev/null | sed 's#.*/php##' | sort -V | tr '\n' ' ')"
    echo "  switch:    phpsw <version>"
fi
if [ $INSTALL_NODE -eq 1 ]; then
    echo "  node:      nvm use <version>"
fi
echo ""

# ------------------------------------------------------------ shell integration

# Make bash load git.sh (shortcuts, branch prompt, worktree helpers) in future
# sessions. The repo is resolved from this script's own location, and the line
# is written to the invoking user's ~/.bashrc - so it works wherever the
# checkout lives and for whoever ran sudo, not a fixed path.
INFRA_DIR="$(cd "$(dirname "$0")" && pwd)"
GIT_SH="${INFRA_DIR}/git.sh"
if [ -f "$GIT_SH" ]; then
    src_line="[ -f \"$GIT_SH\" ] && source \"$GIT_SH\""
    bashrc="${TOOL_HOME}/.bashrc"
    # A hand-written or older line may source the same file through $HOME rather
    # than the absolute path - match that form too, or every run appends a second
    # copy that grep for the absolute path never sees. Keep the literal $HOME.
    case "$GIT_SH" in
        "$TOOL_HOME"/*) GIT_SH_HOME="\$HOME/${GIT_SH#"$TOOL_HOME"/}" ;;
        *)              GIT_SH_HOME="$GIT_SH" ;;
    esac
    # An earlier install may have written a commands.sh line for a file that no
    # longer exists - drop it rather than leaving a dead source in ~/.bashrc.
    old_line="${INFRA_DIR}/commands.sh"
    run_as_user "touch '$bashrc'
        if grep -qF '$old_line' '$bashrc' 2>/dev/null; then
            tmp=\$(mktemp) && grep -vF '$old_line' '$bashrc' > \"\$tmp\" && mv \"\$tmp\" '$bashrc'
        fi
        grep -qF '$GIT_SH' '$bashrc' 2>/dev/null \
            || grep -qF '$GIT_SH_HOME' '$bashrc' 2>/dev/null \
            || printf '%s\n' '$src_line' >> '$bashrc'"
    print_success "bash will auto-load git.sh (${GIT_SH})"
else
    print_warning "no git.sh next to install.sh - skipping shell integration"
fi

# Auto-reload bash so the new environment is live right away. A script can't
# mutate its parent shell, so the closest thing is to exec a fresh login shell
# for the invoking user - it re-reads ~/.bashrc and thus sources git.sh.
# Only do this interactively so non-interactive/CI runs still return.
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != root ] && [ -t 0 ] && [ -t 1 ]; then
    print_info "Reloading bash so the shell helpers and new tools are ready..."
    exec su - "$SUDO_USER"
else
    print_warning "Open a new shell (or 'source ${GIT_SH:-./git.sh}') to pick up the environment"
fi
