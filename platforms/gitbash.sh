#!/usr/bin/env bash

# Git for Windows' bash (uname says MINGW64_NT). Almost everything it needs is
# already in windows.sh - the hosts file, path translation, the docker argument
# mangling, no sudo - so this file is only what Git Bash does differently:
#
#   - git and curl are part of the installation, so nothing has to install them
#   - there is no pacman; packages come from winget, scoop or choco
#   - the bundled openssl and coreutils are complete enough for the SSL script
#   - a MinTTY console is UTF-8 and ANSI-capable, unlike a cmd.exe-hosted one,
#     which is why common.sh decides colour from the terminal rather than the OS

. "${INFRA_PLATFORM_DIR}/windows.sh"

platform_label() { printf 'Git Bash on Windows (%s)\n' "$(uname -m)"; }

# No pacman in Git for Windows' MSYS runtime - it ships a fixed package set.
platform_pkg_manager() {
    local mgr
    for mgr in winget scoop choco; do
        command -v "$mgr" >/dev/null 2>&1 && { printf '%s\n' "$mgr"; return 0; }
    done
    printf '%s\n' none
}

# git is the reason this shell exists, so a "git is missing" path would be
# nonsense. Callers ask this before offering to install it.
platform_has_bundled_git() { return 0; }
