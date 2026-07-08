#!/usr/bin/env bash
# =============================================================================
# Project      : Linux Server Automation
# File         : modules/install_docker.sh
# Description  : Install the latest Docker Engine from Docker's official apt
#                repository (docs.docker.com/engine/install/ubuntu). Also
#                installs the Buildx and Compose v2 plugins, enables the
#                daemon, and grants the invoking user access to the docker
#                group.
# Compatible   : Ubuntu 24.04 LTS
# Depends on   : lib/colors.sh, lib/logger.sh, lib/utils.sh
# =============================================================================

# -----------------------------------------------------------------------------
# Re-source guard
# -----------------------------------------------------------------------------
if [[ -n "${__INSTALL_DOCKER_SH_LOADED:-}" ]]; then
    return 0
fi
readonly __INSTALL_DOCKER_SH_LOADED=1

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------
for _dep in log_info log_warn log_error log_success log_debug separator \
            confirm_action pause_screen check_root check_network \
            command_exists require_command package_installed service_exists \
            show_spinner; do
    if ! declare -F "${_dep}" >/dev/null 2>&1; then
        echo "ERROR: modules/install_docker.sh requires ${_dep} (missing lib)." >&2
        return 1 2>/dev/null || exit 1
    fi
done
unset _dep

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

# Official Docker apt repository details.
readonly _DOCKER_GPG_URL="https://download.docker.com/linux/ubuntu/gpg"
readonly _DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
readonly _DOCKER_REPO_FILE="/etc/apt/sources.list.d/docker.list"
readonly _DOCKER_REPO_BASE="https://download.docker.com/linux/ubuntu"

# Prerequisites required to fetch the key and set up the repo.
readonly _DOCKER_PREREQS=(
    ca-certificates
    curl
    gnupg
)

# Full Docker Engine + tooling set.
readonly _DOCKER_PACKAGES=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
    docker-compose-plugin
)

# _APT_ENV and _APT_OPTS are provided by lib/utils.sh (single source of truth).

# Path to the apt output capture file.
_APT_OUTPUT_FILE=""

# =============================================================================
# INTERNAL HELPERS
# =============================================================================

# -----------------------------------------------------------------------------
# Function : _print_section_header
# Purpose  : Colored header for this module.
# -----------------------------------------------------------------------------
_print_section_header() {
    echo ""
    separator "="
    printf "%b  >> Install Docker Engine (official repository)%b\n" \
        "${C_HEADER}" "${C_RESET}"
    separator "="
    echo ""
}

# -----------------------------------------------------------------------------
# Function : _prepare_apt_output_file
# Purpose  : Create a temp file for capturing apt output during spinner ops.
# Returns  : 0 on success, 1 on failure.
# -----------------------------------------------------------------------------
_prepare_apt_output_file() {
    local base_dir="${LOG_DIR:-/tmp}"

    if ! _APT_OUTPUT_FILE=$(mktemp "${base_dir}/apt-docker.XXXXXX.log" 2>/dev/null); then
        log_error "Failed to create temporary log file in ${base_dir}."
        return 1
    fi

    chmod 640 "${_APT_OUTPUT_FILE}" 2>/dev/null || true
    return 0
}

# -----------------------------------------------------------------------------
# Function : _cleanup_apt_output_file
# Purpose  : Append captured apt output to the session log and delete temp.
# -----------------------------------------------------------------------------
_cleanup_apt_output_file() {
    if [[ -n "${_APT_OUTPUT_FILE}" && -f "${_APT_OUTPUT_FILE}" ]]; then
        if [[ -n "${LOG_FILE:-}" && -w "${LOG_FILE}" ]]; then
            {
                echo "----- apt (docker) output -----"
                cat "${_APT_OUTPUT_FILE}"
                echo "----- end apt (docker) output -----"
            } >> "${LOG_FILE}" 2>/dev/null || true
        fi
        rm -f "${_APT_OUTPUT_FILE}" 2>/dev/null || true
    fi
    _APT_OUTPUT_FILE=""
}

# -----------------------------------------------------------------------------
# Function : _detect_ubuntu_codename
# Purpose  : Return the Ubuntu release codename (e.g. "noble" for 24.04).
#            Preferred source: /etc/os-release VERSION_CODENAME. Falls back
#            to `lsb_release -cs` if available.
# Output   : Codename on stdout. Empty string if it cannot be determined.
# -----------------------------------------------------------------------------
_detect_ubuntu_codename() {
    local codename=""

    if [[ -r /etc/os-release ]]; then
        codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}")
    fi

    if [[ -z "${codename}" ]] && command_exists lsb_release; then
        codename=$(lsb_release -cs 2>/dev/null || true)
    fi

    echo "${codename}"
}

# -----------------------------------------------------------------------------
# Function : _detect_target_user
# Purpose  : Determine which non-root account should be added to the docker
#            group. Priority:
#              1) SUDO_USER (set by sudo)
#              2) The first regular login user with UID >= 1000, if unique
#            Returns an empty string if no suitable user is found.
# -----------------------------------------------------------------------------
_detect_target_user() {
    local candidate="${SUDO_USER:-}"

    # SUDO_USER is empty when the script is run as root directly (not via
    # sudo). Fall back to /etc/passwd for a single non-root login user.
    if [[ -z "${candidate}" || "${candidate}" == "root" ]]; then
        local count
        count=$(awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd | wc -l)
        if [[ "${count}" == "1" ]]; then
            candidate=$(awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd)
        else
            candidate=""
        fi
    fi

    echo "${candidate}"
}

# -----------------------------------------------------------------------------
# Function : _is_docker_installed
# Purpose  : Consider Docker installed only if the CLI is present AND the
#            main package is registered with dpkg. Prevents false positives
#            from leftover binaries.
# -----------------------------------------------------------------------------
_is_docker_installed() {
    command_exists docker && package_installed docker-ce
}

# -----------------------------------------------------------------------------
# Function : _print_docker_version
# Purpose  : Print `docker --version` in a compact, colored line.
# -----------------------------------------------------------------------------
_print_docker_version() {
    local ver=""
    if command_exists docker; then
        ver=$(docker --version 2>/dev/null || true)
    fi
    if [[ -n "${ver}" ]]; then
        printf "   %b→%b  %s\n" "${C_INFO}" "${C_RESET}" "${ver}"
    else
        printf "   %b→%b  Docker CLI not available.\n" \
            "${C_ERROR}" "${C_RESET}"
    fi
}

# -----------------------------------------------------------------------------
# Function : _install_prerequisites
# Purpose  : Install ca-certificates / curl / gnupg (only the ones missing).
# Returns  : 0 on success, non-zero on apt failure.
# -----------------------------------------------------------------------------
_install_prerequisites() {
    local missing=()
    local pkg
    for pkg in "${_DOCKER_PREREQS[@]}"; do
        if ! package_installed "${pkg}"; then
            missing+=("${pkg}")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_info "Prerequisites already satisfied."
        return 0
    fi

    log_info "Installing prerequisites: ${missing[*]}"

    _prepare_apt_output_file || return 1

    local rc=0
    set +e
    env "${_APT_ENV[@]}" apt-get install "${_APT_OPTS[@]}" \
        "${missing[@]}" >"${_APT_OUTPUT_FILE}" 2>&1 &
    show_spinner "$!" "Installing Docker prerequisites..."
    rc=$?
    set -e

    _cleanup_apt_output_file
    return "${rc}"
}

# -----------------------------------------------------------------------------
# Function : _add_docker_gpg_key
# Purpose  : Download Docker's official GPG key into /etc/apt/keyrings using
#            the ASCII-armored form (docker.asc), per current Docker docs.
# Returns  : 0 on success, non-zero on failure.
# -----------------------------------------------------------------------------
_add_docker_gpg_key() {
    log_info "Adding Docker's official GPG key..."

    # /etc/apt/keyrings must exist with world-readable perms.
    if ! install -m 0755 -d /etc/apt/keyrings; then
        log_error "Failed to create /etc/apt/keyrings."
        return 1
    fi

    # Download the ASCII-armored key. `-fsSL` = fail on HTTP errors, silent,
    # show errors, follow redirects.
    if ! curl -fsSL --connect-timeout 10 --max-time 60 \
            "${_DOCKER_GPG_URL}" -o "${_DOCKER_KEYRING}"; then
        log_error "Failed to download Docker GPG key from ${_DOCKER_GPG_URL}."
        return 1
    fi

    # Key file must be readable by _apt / everyone.
    chmod a+r "${_DOCKER_KEYRING}" || {
        log_error "Failed to set permissions on ${_DOCKER_KEYRING}."
        return 1
    }

    log_success "Docker GPG key installed at ${_DOCKER_KEYRING}."
    return 0
}

# -----------------------------------------------------------------------------
# Function : _add_docker_repository
# Purpose  : Write /etc/apt/sources.list.d/docker.list pointing at Docker's
#            official Ubuntu repository for the current release + arch.
# Returns  : 0 on success, non-zero on failure.
# -----------------------------------------------------------------------------
_add_docker_repository() {
    local codename arch
    codename=$(_detect_ubuntu_codename)
    arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")

    if [[ -z "${codename}" ]]; then
        log_error "Unable to determine Ubuntu codename; cannot configure Docker repo."
        return 1
    fi

    log_info "Configuring Docker repository (arch=${arch}, codename=${codename})..."

    local repo_line
    repo_line="deb [arch=${arch} signed-by=${_DOCKER_KEYRING}] ${_DOCKER_REPO_BASE} ${codename} stable"

    if ! echo "${repo_line}" > "${_DOCKER_REPO_FILE}"; then
        log_error "Failed to write ${_DOCKER_REPO_FILE}."
        return 1
    fi

    chmod 0644 "${_DOCKER_REPO_FILE}" || true

    log_success "Docker repository configured at ${_DOCKER_REPO_FILE}."
    return 0
}

# -----------------------------------------------------------------------------
# Function : _apt_update
# Purpose  : Refresh the apt index after adding the Docker repo. Wrapped so
#            we get a spinner + captured output.
# Returns  : 0 on success, non-zero on failure.
# -----------------------------------------------------------------------------
_apt_update() {
    log_info "Refreshing apt package index..."
    _prepare_apt_output_file || return 1

    local rc=0
    set +e
    env "${_APT_ENV[@]}" apt-get update \
        >"${_APT_OUTPUT_FILE}" 2>&1 &
    show_spinner "$!" "Refreshing apt package index..."
    rc=$?
    set -e

    _cleanup_apt_output_file
    return "${rc}"
}

# -----------------------------------------------------------------------------
# Function : _install_docker_packages
# Purpose  : Install the Docker Engine package set.
# Returns  : 0 on success, non-zero on apt failure.
# -----------------------------------------------------------------------------
_install_docker_packages() {
    log_info "Installing Docker packages: ${_DOCKER_PACKAGES[*]}"
    _prepare_apt_output_file || return 1

    local rc=0
    set +e
    env "${_APT_ENV[@]}" apt-get install "${_APT_OPTS[@]}" \
        "${_DOCKER_PACKAGES[@]}" >"${_APT_OUTPUT_FILE}" 2>&1 &
    show_spinner "$!" "Installing Docker Engine + plugins..."
    rc=$?
    set -e

    _cleanup_apt_output_file
    return "${rc}"
}

# -----------------------------------------------------------------------------
# Function : _enable_and_start_docker
# Purpose  : Enable and start the docker.service systemd unit.
# Returns  : 0 on success, non-zero on failure.
# -----------------------------------------------------------------------------
_enable_and_start_docker() {
    require_command "systemctl" "systemd"

    if ! service_exists docker; then
        log_error "docker.service unit not found; installation may be incomplete."
        return 1
    fi

    log_info "Enabling docker.service at boot..."
    if ! systemctl enable docker >/dev/null 2>&1; then
        log_error "Failed to enable docker.service."
        return 1
    fi

    log_info "Starting docker.service..."
    if ! systemctl start docker >/dev/null 2>&1; then
        log_error "Failed to start docker.service."
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Function : _verify_docker_installation
# Purpose  : Sanity-check the install by asserting the CLI exists, the
#            daemon is active, and `docker version` can talk to it.
# Returns  : 0 if healthy, non-zero otherwise.
# -----------------------------------------------------------------------------
_verify_docker_installation() {
    if ! command_exists docker; then
        log_error "docker CLI not found after installation."
        return 1
    fi

    if ! systemctl is-active --quiet docker; then
        log_error "docker.service is not active."
        return 1
    fi

    # `docker version` (no --) queries both client and server. Use a short
    # timeout so a stuck daemon does not hang the script.
    if ! timeout 10 docker version >/dev/null 2>&1; then
        log_error "docker daemon is not responding to 'docker version'."
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Function : _print_docker_status
# Purpose  : Print daemon status and version banner after a successful install.
# -----------------------------------------------------------------------------
_print_docker_status() {
    echo ""
    printf "%b  Docker status%b\n" "${C_HEADER}" "${C_RESET}"
    separator "-"
    _print_docker_version

    local status
    status=$(systemctl is-active docker 2>/dev/null || echo "unknown")
    if [[ "${status}" == "active" ]]; then
        printf "   %b→%b  Service : %bactive%b\n" \
            "${C_INFO}" "${C_RESET}" \
            "${C_SUCCESS}" "${C_RESET}"
    else
        printf "   %b→%b  Service : %b%s%b\n" \
            "${C_INFO}" "${C_RESET}" \
            "${C_ERROR}" "${status}" "${C_RESET}"
    fi

    local enabled
    enabled=$(systemctl is-enabled docker 2>/dev/null || echo "unknown")
    printf "   %b→%b  Enabled : %s\n" "${C_INFO}" "${C_RESET}" "${enabled}"
    separator "-"
}

# -----------------------------------------------------------------------------
# Function : _add_user_to_docker_group
# Purpose  : Add the invoking non-root user to the docker group so they can
#            run docker without sudo. Skips gracefully if no user is found.
# -----------------------------------------------------------------------------
_add_user_to_docker_group() {
    local user
    user=$(_detect_target_user)

    if [[ -z "${user}" ]]; then
        log_warn "Could not determine a non-root user to add to the docker group."
        log_warn "Add a user manually with: usermod -aG docker <username>"
        return 0
    fi

    if ! id "${user}" >/dev/null 2>&1; then
        log_warn "User '${user}' does not exist; skipping docker group assignment."
        return 0
    fi

    if id -nG "${user}" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        log_info "User '${user}' is already a member of the docker group."
        return 0
    fi

    log_info "Adding user '${user}' to the docker group..."
    if ! usermod -aG docker "${user}"; then
        log_error "Failed to add '${user}' to the docker group."
        return 1
    fi

    log_success "User '${user}' added to docker group."
    log_warn "'${user}' must log out and log back in (or run 'newgrp docker') for the change to take effect."
    return 0
}

# =============================================================================
# PUBLIC ENTRY POINT
# =============================================================================

# -----------------------------------------------------------------------------
# Function : install_docker
# Purpose  : Menu-facing action: install Docker Engine from Docker's official
#            apt repository, enable/start the daemon, verify the install, and
#            grant the invoking user access to the docker group.
#
# Returns  :
#   0   on success
#   1   on user cancellation / user chose to skip
#   2   on unmet prerequisite
#   3   on installation failure
#   4   on post-install verification failure
# -----------------------------------------------------------------------------
install_docker() {
    _print_section_header

    # ---- Step 1: root + network + apt -------------------------------------
    check_root
    check_network
    require_command "apt-get" "apt"

    # ---- Step 2: already installed? ---------------------------------------
    if _is_docker_installed; then
        log_info "Docker appears to be installed already."
        _print_docker_version

        if ! confirm_action "Reinstall Docker from the official repository?"; then
            log_info "Skipping Docker installation at user request."
            pause_screen
            return 1
        fi
    else
        if ! confirm_action "Install Docker Engine from the official repository?"; then
            log_warn "User cancelled the operation."
            pause_screen
            return 1
        fi
    fi

    # ---- Step 3: install prerequisites ------------------------------------
    if ! _install_prerequisites; then
        log_error "Failed to install prerequisite packages."
        pause_screen
        return 3
    fi

    # ---- Step 4: add GPG key + repo ---------------------------------------
    if ! _add_docker_gpg_key; then
        pause_screen
        return 3
    fi

    if ! _add_docker_repository; then
        pause_screen
        return 3
    fi

    # ---- Step 5: apt update -----------------------------------------------
    if ! _apt_update; then
        log_error "apt-get update failed after adding Docker repository."
        pause_screen
        return 3
    fi

    # ---- Step 6: install Docker packages ----------------------------------
    if ! _install_docker_packages; then
        log_error "Failed to install Docker packages."
        pause_screen
        return 3
    fi

    # ---- Step 7: enable + start service -----------------------------------
    if ! _enable_and_start_docker; then
        pause_screen
        return 3
    fi

    # ---- Step 8: verify ---------------------------------------------------
    if ! _verify_docker_installation; then
        log_error "Docker installation verification failed."
        pause_screen
        return 4
    fi

    # ---- Step 9: post-install: group membership + report -------------------
    _add_user_to_docker_group || true
    _print_docker_status

    log_success "Docker Engine installed and running."
    pause_screen
    return 0
}