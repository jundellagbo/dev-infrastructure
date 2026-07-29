#!/usr/bin/env bash

# Platform layer. Source this once, then call the platform_* hooks - each of the
# five supported platforms answers them its own way and no caller needs a case
# statement:
#
#   . "${INFRA_DIR}/platforms/platform.sh"
#   infra_info "installing on $(platform_label)"
#   platform_setup_dns dev.local
#
# common.sh holds the default implementation of every hook and the helpers that
# are the same everywhere; the file for the detected platform is sourced after
# it and overrides what differs. WSL inherits from linux.sh and Git Bash from
# windows.sh, so each only carries its own deltas.
#
#   linux.sh    a normal Linux box - systemd, /usr/local/bin, sudo
#   wsl.sh      + the Windows host next door, which resolves and browses on its own
#   macos.sh    launchd, Homebrew, /etc/resolver, per-user installs
#   windows.sh  MSYS2/Cygwin - Windows' hosts file, no sudo, path mangling
#   gitbash.sh  Git for Windows' bash, which is windows.sh with git already there
#
# Everything here is namespaced infra_*/platform_*/INFRA_*: git.sh sources this
# into every interactive shell, so nothing may take a name a user might type.
# Nothing here exits, sets shell options or writes to stdout on load.

# Sourced more than once per shell - by git.sh's reload hook, or by a script
# that also sourced a helper that sourced it. Loading twice is harmless but
# pointless, so the second time is a no-op.
if [ -z "${INFRA_PLATFORM_LOADED:-}" ]; then

INFRA_PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# uname is the one identity check available before anything is installed. The
# Windows shells differ in their prefix: MINGW is Git for Windows, MSYS is
# MSYS2, CYGWIN is Cygwin - the first gets its own file, the other two share.
INFRA_OS="$(
    case "$(uname -s 2>/dev/null)" in
        Linux)
            # WSL identifies itself in the kernel release string; the env vars
            # are the modern signal but are absent under some init setups.
            if [ -n "${WSL_DISTRO_NAME:-}" ] || [ -n "${WSL_INTEROP:-}" ] \
               || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
                echo wsl
            else
                echo linux
            fi ;;
        Darwin)               echo macos ;;
        MINGW*)               echo gitbash ;;
        MSYS*|CYGWIN*)        echo windows ;;
        *)                    echo linux ;;   # a Unix we don't know: Linux is the closest fit
    esac
)"

. "${INFRA_PLATFORM_DIR}/common.sh"

case "$INFRA_OS" in
    linux)   . "${INFRA_PLATFORM_DIR}/linux.sh" ;;
    wsl)     . "${INFRA_PLATFORM_DIR}/wsl.sh" ;;
    macos)   . "${INFRA_PLATFORM_DIR}/macos.sh" ;;
    windows) . "${INFRA_PLATFORM_DIR}/windows.sh" ;;
    gitbash) . "${INFRA_PLATFORM_DIR}/gitbash.sh" ;;
esac

INFRA_PLATFORM_LOADED=1

fi
