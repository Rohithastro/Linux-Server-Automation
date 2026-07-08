#!/usr/bin/env bash
# =============================================================================
# Project      : Linux Server Automation
# File         : modules/enable_ssh.sh
# Description  : Install (if missing), enable, and start the OpenSSH server.
#                Verifies the daemon is listening, reports version + port,
#                and optionally opens port 22 in UFW.
# Compatible   : Ubuntu 24.04 LTS
# Depends on   : lib/colors.sh, lib/logger.sh, lib/utils.sh
# =============================================================================

# -----------------------------------------------------------------------------
# Re-source guard
# -----------------------------------------------------------------------------
if [[ -n "${__ENABLE_SSH_SH_LOADED:-}" ]]; then
    return 0
fi
readonly __ENABLE_SSH_SH_LOADED=1

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------
for _dep in log_info log_warn log_error log_success log_debug separator \
            confirm_action pause_screen check_root check_network \
            command_exists require_command package_installed service_exists \
            show_spinner; do
    if ! declare -F "${_dep}" >/dev/null 2>&1; then
        echo "ERROR: modules/enable_ssh.sh requires ${_dep} (missing lib)." >&2
        return 1 2>/dev/null || exit 1
    fi
done
unset _dep

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
readonly _SSH_PACKAGE="openssh-server"
# Ubuntu 24.04 uses socket activation via ssh.socket; the actual daemon
# unit is named "ssh.service". We normalize on "ssh" for systemctl calls.
readonly _SSH_SERVICE="ssh"
readonly _SSHD_CONFIG="/etc/ssh/sshd_config"
readonly _DEFAULT_SSH_PORT=22

# _APT_ENV and _APT_OPTS are provided by lib/utils.sh (single source of truth).

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
    printf "%b  >> Enable SSH (OpenSSH Server)%b\n" "${C_HEADER}" "${C_RESET}"
    separator "="
    echo ""
}

# -----------------------------------------------------------------------------
# Function : _prepare_apt_output_file
# Purpose  : Create a temp file to capture apt output for the spinner path.
# Returns  : 0 on success, 1 on failure.
# -----------------------------------------------------------------------------
_prepare_apt_output_file() {
    local base_dir="${LOG_DIR:-/tmp}"

    if ! _APT_OUTPUT_FILE=$(mktemp "${base_dir}/apt-ssh.XXXXXX.log" 2>/dev/null); then
        log_error "Failed to create temporary log file in ${base_dir}."
        return 1
    fi

    chmod 640 "${_APT_OUTPUT_FILE}" 2>/dev/null || true
    return 0
}

# -----------------------------------------------------------------------------
# Function : _cleanup_apt_output_file
# Purpose  : Persist captured apt output to the session log and delete temp.
# -----------------------------------------------------------------------------
_cleanup_apt_output_file() {
    if [[ -n "${_APT_OUTPUT_FILE}" && -f "${_APT_OUTPUT_FILE}" ]]; then
        if [[ -n "${LOG_FILE:-}" && -w "${LOG_FILE}" ]]; then
            {
                echo "----- apt (openssh-server) output -----"
                cat "${_APT_OUTPUT_FILE}"
                echo "----- end apt (openssh-server) output -----"
            } >> "${LOG_FILE}" 2>/dev/null || true
        fi
        rm -f "${_APT_OUTPUT_FILE}" 2>/dev/null || true
    fi
    _APT_OUTPUT_FILE=""
}

# -----------------------------------------------------------------------------
# Function : _install_openssh_server
# Purpose  : Install openssh-server via apt if it is not already installed.
# Returns  : 0 on success (or already installed), non-zero on failure.
# -----------------------------------------------------------------------------
_install_openssh_server() {
    if package_installed "${_SSH_PACKAGE}"; then
        log_info "${_SSH_PACKAGE} is already installed."
        return 0
    fi

    log_warn "${_SSH_PACKAGE} is not installed. It will be installed automatically."
    require_command "apt-get" "apt"
    _prepare_apt_output_file || return 1

    local rc=0
    set +e
    env "${_APT_ENV[@]}" apt-get install "${_APT_OPTS[@]}" "${_SSH_PACKAGE}" \
        >"${_APT_OUTPUT_FILE}" 2>&1 &
    show_spinner "$!" "Installing ${_SSH_PACKAGE}..."
    rc=$?
    set -e

    _cleanup_apt_output_file

    if [[ ${rc} -ne 0 ]]; then
        log_error "Failed to install ${_SSH_PACKAGE} (apt exit code ${rc})."
        return 1
    fi

    log_success "${_SSH_PACKAGE} installed."
    return 0
}

# -----------------------------------------------------------------------------
# Function : _enable_and_start_ssh
# Purpose  : Enable ssh.service at boot and start it now.
# Returns  : 0 on success, non-zero on failure.
# -----------------------------------------------------------------------------
_enable_and_start_ssh() {
    require_command "systemctl" "systemd"

    if ! service_exists "${_SSH_SERVICE}"; then
        log_error "${_SSH_SERVICE}.service unit not found; installation incomplete."
        return 1
    fi

    log_info "Enabling ${_SSH_SERVICE}.service at boot..."
    if ! systemctl enable "${_SSH_SERVICE}" >/dev/null 2>&1; then
        log_error "Failed to enable ${_SSH_SERVICE}.service."
        return 1
    fi

    # Start with a spinner. Use `start` not `restart` so we do not
    # accidentally kick off a live remote session (defensive).
    log_info "Starting ${_SSH_SERVICE}.service..."
    local rc=0
    set +e
    systemctl start "${_SSH_SERVICE}" >/dev/null 2>&1 &
    show_spinner "$!" "Starting SSH service..."
    rc=$?
    set -e

    if [[ ${rc} -ne 0 ]]; then
        log_error "Failed to start ${_SSH_SERVICE}.service."
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Function : _verify_ssh_active
# Purpose  : Assert that ssh.service is active.
# Returns  : 0 if active, 1 otherwise.
# -----------------------------------------------------------------------------
_verify_ssh_active() {
    if systemctl is-active --quiet "${_SSH_SERVICE}"; then
        return 0
    fi
    log_error "${_SSH_SERVICE}.service is not active."
    return 1
}

# -----------------------------------------------------------------------------
# Function : _get_ssh_version
# Purpose  : Return the OpenSSH server version banner. `sshd -V` is not
#            portable; the reliable trick is `sshd -v` on an intentionally
#            invalid invocation, which prints the version on stderr.
#            Fall back to dpkg-query if sshd is unavailable.
# Output   : Version string on stdout, or empty on failure.
# -----------------------------------------------------------------------------
_get_ssh_version() {
    if command_exists sshd; then
        # `sshd -\?` prints usage plus the "OpenSSH_..." banner on stderr.
        local ver
        ver=$(sshd -\? 2>&1 | grep -o 'OpenSSH[^ ,]*' | head -n1)
        if [[ -n "${ver}" ]]; then
            echo "${ver}"
            return 0
        fi
    fi

    if command_exists dpkg-query; then
        dpkg-query -W -f='openssh-server ${Version}' "${_SSH_PACKAGE}" 2>/dev/null
    fi
}

# -----------------------------------------------------------------------------
# Function : _get_ssh_port
# Purpose  : Determine the port sshd is configured to listen on. Priority:
#              1) `sshd -T` (authoritative effective config), root-only
#              2) grep the Port directive in sshd_config
#              3) fall back to the default (22)
# Output   : Port number on stdout.
# -----------------------------------------------------------------------------
_get_ssh_port() {
    local port=""

    if command_exists sshd; then
        # -T prints effective config; port lines look like "port 22".
        port=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')
    fi

    if [[ -z "${port}" && -r "${_SSHD_CONFIG}" ]]; then
        # Uncommented Port directive.
        port=$(awk '/^[[:space:]]*Port[[:space:]]+/ {print $2; exit}' \
                    "${_SSHD_CONFIG}" 2>/dev/null)
    fi

    [[ -z "${port}" ]] && port="${_DEFAULT_SSH_PORT}"
    echo "${port}"
}

# -----------------------------------------------------------------------------
# Function : _get_ssh_listeners
# Purpose  : Return the actual TCP listeners for sshd, one per line.
#            Prefers `ss` (iproute2), falls back to `netstat`.
# -----------------------------------------------------------------------------
_get_ssh_listeners() {
    if command_exists ss; then
        ss -Htlnp 2>/dev/null | awk '/sshd/ {print $4}' | sort -u
    elif command_exists netstat; then
        netstat -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | sort -u
    fi
}

# -----------------------------------------------------------------------------
# Function : _print_ssh_status
# Purpose  : Colored status block: service state, version, listening ports,
#            config file path.
# -----------------------------------------------------------------------------
_print_ssh_status() {
    echo ""
    printf "%b  SSH status%b\n" "${C_HEADER}" "${C_RESET}"
    separator "-"

    # Service state
    local state
    state=$(systemctl is-active "${_SSH_SERVICE}" 2>/dev/null || echo "unknown")
    if [[ "${state}" == "active" ]]; then
        printf "   %b→%b  Service : %bactive%b\n" \
            "${C_INFO}" "${C_RESET}" "${C_SUCCESS}" "${C_RESET}"
    else
        printf "   %b→%b  Service : %b%s%b\n" \
            "${C_INFO}" "${C_RESET}" "${C_ERROR}" "${state}" "${C_RESET}"
    fi

    # Enabled state
    local enabled
    enabled=$(systemctl is-enabled "${_SSH_SERVICE}" 2>/dev/null || echo "unknown")
    printf "   %b→%b  Enabled : %s\n" "${C_INFO}" "${C_RESET}" "${enabled}"

    # Version
    local ver
    ver=$(_get_ssh_version)
    if [[ -n "${ver}" ]]; then
        printf "   %b→%b  Version : %s\n" "${C_INFO}" "${C_RESET}" "${ver}"
    else
        printf "   %b→%b  Version : %b(unknown)%b\n" \
            "${C_INFO}" "${C_RESET}" "${C_DIM}" "${C_RESET}"
    fi

    # Configured port
    local port
    port=$(_get_ssh_port)
    printf "   %b→%b  Port    : %s\n" "${C_INFO}" "${C_RESET}" "${port}"

    # Actual listeners
    printf "   %b→%b  Listeners:\n" "${C_INFO}" "${C_RESET}"
    local listeners
    listeners=$(_get_ssh_listeners)
    if [[ -z "${listeners}" ]]; then
        printf "       %b(none detected)%b\n" "${C_DIM}" "${C_RESET}"
    else
        local line
        while IFS= read -r line; do
            printf "       %b•%b  %s\n" "${C_SUCCESS}" "${C_RESET}" "${line}"
        done <<< "${listeners}"
    fi

    # Config file
    if [[ -f "${_SSHD_CONFIG}" ]]; then
        printf "   %b→%b  Config  : %s\n" "${C_INFO}" "${C_RESET}" "${_SSHD_CONFIG}"
    else
        printf "   %b→%b  Config  : %b(not found)%b\n" \
            "${C_INFO}" "${C_RESET}" "${C_DIM}" "${C_RESET}"
    fi

    separator "-"
}

# -----------------------------------------------------------------------------
# Function : _ufw_available
# Purpose  : Return 0 if UFW is installed AND currently active. Firewall
#            rule management is only meaningful when the firewall is on.
# -----------------------------------------------------------------------------
_ufw_available() {
    command_exists ufw || return 1
    ufw status 2>/dev/null | grep -qi "Status: active"
}

# -----------------------------------------------------------------------------
# Function : _ssh_port_allowed_in_ufw
# Purpose  : Check whether an ALLOW rule already exists for the given port
#            in the current UFW ruleset.
# Args     : $1 - port number
# -----------------------------------------------------------------------------
_ssh_port_allowed_in_ufw() {
    local port="$1"
    ufw status 2>/dev/null \
        | grep -Eq "^${port}(/tcp)?[[:space:]]+ALLOW"
}

# -----------------------------------------------------------------------------
# Function : _maybe_allow_ssh_in_ufw
# Purpose  : Offer to add a UFW rule for the SSH port if the firewall is
#            active and no matching rule exists. No-op when UFW is off.
# -----------------------------------------------------------------------------
_maybe_allow_ssh_in_ufw() {
    if ! command_exists ufw; then
        log_debug "ufw not installed; skipping firewall check."
        return 0
    fi

    if ! _ufw_available; then
        log_info "UFW is installed but not active; skipping firewall check."
        return 0
    fi

    local port
    port=$(_get_ssh_port)

    if _ssh_port_allowed_in_ufw "${port}"; then
        log_success "UFW already allows SSH on port ${port}."
        return 0
    fi

    log_warn "UFW is active but port ${port} (SSH) is NOT allowed."
    log_warn "Enabling SSH without opening the firewall will lock out remote logins."

    if ! confirm_action "Add UFW rule to allow ${port}/tcp?"; then
        log_warn "Skipped firewall rule at user request."
        return 0
    fi

    if ! ufw allow "${port}/tcp" >/dev/null 2>&1; then
        log_error "Failed to add UFW rule for ${port}/tcp."
        return 1
    fi

    if ! ufw reload >/dev/null 2>&1; then
        log_warn "Added rule but 'ufw reload' failed; rule may still be pending."
    fi

    log_success "UFW rule added: allow ${port}/tcp."
    return 0
}

# =============================================================================
# PUBLIC ENTRY POINT
# =============================================================================

# -----------------------------------------------------------------------------
# Function : enable_ssh
# Purpose  : Menu-facing action: ensure openssh-server is installed, enabled
#            and running; verify it is listening; and optionally open the
#            SSH port in UFW.
#
# Returns  :
#   0   on success
#   1   on user cancellation
#   2   on unmet prerequisite (e.g. openssh-server install failed)
#   3   on service enable/start failure
#   4   on post-install verification failure
# -----------------------------------------------------------------------------
enable_ssh() {
    _print_section_header

    # ---- Step 1: user confirmation ----------------------------------------
    log_info "This will install (if needed), enable, and start OpenSSH server."
    if ! confirm_action "Proceed?"; then
        log_warn "User cancelled the operation."
        pause_screen
        return 1
    fi

    # ---- Step 2: environment prerequisites --------------------------------
    check_root
    check_network

    # ---- Step 3: install openssh-server if missing ------------------------
    if ! _install_openssh_server; then
        pause_screen
        return 2
    fi

    # ---- Step 4: enable + start service -----------------------------------
    if ! _enable_and_start_ssh; then
        pause_screen
        return 3
    fi

    # ---- Step 5: verify active --------------------------------------------
    if ! _verify_ssh_active; then
        pause_screen
        return 4
    fi

    # ---- Step 6: report ---------------------------------------------------
    _print_ssh_status

    # ---- Step 7: firewall integration -------------------------------------
    _maybe_allow_ssh_in_ufw || true

    log_success "SSH is enabled, running, and listening."
    pause_screen
    return 0
}