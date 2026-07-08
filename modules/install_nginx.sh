#!/usr/bin/env bash
# =============================================================================
# Project      : Linux Server Automation
# File         : modules/install_nginx.sh
# Description  : Install Nginx from the Ubuntu apt repository, enable and
#                start the systemd service, verify it is answering HTTP on
#                localhost, and report status + listening ports.
# Compatible   : Ubuntu 24.04 LTS
# Depends on   : lib/colors.sh, lib/logger.sh, lib/utils.sh
# =============================================================================

# -----------------------------------------------------------------------------
# Re-source guard
# -----------------------------------------------------------------------------
if [[ -n "${__INSTALL_NGINX_SH_LOADED:-}" ]]; then
    return 0
fi
readonly __INSTALL_NGINX_SH_LOADED=1

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------
for _dep in log_info log_warn log_error log_success log_debug separator \
            confirm_action pause_screen check_root check_network \
            command_exists require_command package_installed service_exists \
            show_spinner; do
    if ! declare -F "${_dep}" >/dev/null 2>&1; then
        echo "ERROR: modules/install_nginx.sh requires ${_dep} (missing lib)." >&2
        return 1 2>/dev/null || exit 1
    fi
done
unset _dep

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
readonly _NGINX_PACKAGE="nginx"
readonly _NGINX_SERVICE="nginx"
readonly _NGINX_HTTP_URL="http://127.0.0.1/"
readonly _NGINX_HTTP_TIMEOUT=5   # seconds for the smoke test

# _APT_ENV and _APT_OPTS are provided by lib/utils.sh (single source of truth).

# Path to the apt output capture file (populated at runtime).
_APT_OUTPUT_FILE=""

# =============================================================================
# INTERNAL HELPERS
# =============================================================================

# -----------------------------------------------------------------------------
# Function : _print_section_header
# Purpose  : Colored section header for this module.
# -----------------------------------------------------------------------------
_print_section_header() {
    echo ""
    separator "="
    printf "%b  >> Install Nginx Web Server%b\n" "${C_HEADER}" "${C_RESET}"
    separator "="
    echo ""
}

# -----------------------------------------------------------------------------
# Function : _prepare_apt_output_file
# Purpose  : Create a temp file to capture apt output while the spinner runs.
# Returns  : 0 on success, 1 on failure.
# -----------------------------------------------------------------------------
_prepare_apt_output_file() {
    local base_dir="${LOG_DIR:-/tmp}"

    if ! _APT_OUTPUT_FILE=$(mktemp "${base_dir}/apt-nginx.XXXXXX.log" 2>/dev/null); then
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
                echo "----- apt (nginx) output -----"
                cat "${_APT_OUTPUT_FILE}"
                echo "----- end apt (nginx) output -----"
            } >> "${LOG_FILE}" 2>/dev/null || true
        fi
        rm -f "${_APT_OUTPUT_FILE}" 2>/dev/null || true
    fi
    _APT_OUTPUT_FILE=""
}

# -----------------------------------------------------------------------------
# Function : _get_nginx_version
# Purpose  : Return the Nginx version string. `nginx -v` prints to stderr,
#            so we redirect stderr to stdout to capture it.
# Output   : Version string on stdout, or empty on failure.
# -----------------------------------------------------------------------------
_get_nginx_version() {
    if command_exists nginx; then
        nginx -v 2>&1 | awk 'NF { print; exit }'
    fi
}

# -----------------------------------------------------------------------------
# Function : _print_nginx_version
# Purpose  : Display the Nginx version in a compact colored line.
# -----------------------------------------------------------------------------
_print_nginx_version() {
    local ver
    ver=$(_get_nginx_version)
    if [[ -n "${ver}" ]]; then
        printf "   %b→%b  %s\n" "${C_INFO}" "${C_RESET}" "${ver}"
    else
        printf "   %b→%b  Nginx binary not available.\n" \
            "${C_ERROR}" "${C_RESET}"
    fi
}

# -----------------------------------------------------------------------------
# Function : _install_nginx_package
# Purpose  : Install (or reinstall) the nginx apt package with a spinner.
# Args     : $1 - "install" (default) or "reinstall"
# Returns  : Exit status of apt-get.
# -----------------------------------------------------------------------------
_install_nginx_package() {
    local mode="${1:-install}"

    _prepare_apt_output_file || return 1

    log_info "Running: apt-get ${mode} ${_NGINX_PACKAGE}"

    local rc=0
    set +e
    if [[ "${mode}" == "reinstall" ]]; then
        env "${_APT_ENV[@]}" apt-get install "${_APT_OPTS[@]}" \
            --reinstall "${_NGINX_PACKAGE}" \
            >"${_APT_OUTPUT_FILE}" 2>&1 &
    else
        env "${_APT_ENV[@]}" apt-get install "${_APT_OPTS[@]}" \
            "${_NGINX_PACKAGE}" \
            >"${_APT_OUTPUT_FILE}" 2>&1 &
    fi
    show_spinner "$!" "Installing Nginx (${mode})..."
    rc=$?
    set -e

    _cleanup_apt_output_file
    return "${rc}"
}

# -----------------------------------------------------------------------------
# Function : _enable_and_start_nginx
# Purpose  : Enable nginx.service at boot and start it now.
# Returns  : 0 on success, non-zero on failure.
# -----------------------------------------------------------------------------
_enable_and_start_nginx() {
    require_command "systemctl" "systemd"

    if ! service_exists "${_NGINX_SERVICE}"; then
        log_error "${_NGINX_SERVICE}.service unit not found; installation incomplete."
        return 1
    fi

    log_info "Enabling ${_NGINX_SERVICE}.service at boot..."
    if ! systemctl enable "${_NGINX_SERVICE}" >/dev/null 2>&1; then
        log_error "Failed to enable ${_NGINX_SERVICE}.service."
        return 1
    fi

    # `start` is a no-op if already running; use `restart` if we just
    # reinstalled to ensure a clean state.
    log_info "Starting ${_NGINX_SERVICE}.service..."
    if ! systemctl restart "${_NGINX_SERVICE}" >/dev/null 2>&1; then
        log_error "Failed to start ${_NGINX_SERVICE}.service."
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Function : _verify_nginx_active
# Purpose  : Assert that nginx.service is active.
# Returns  : 0 if active, 1 otherwise.
# -----------------------------------------------------------------------------
_verify_nginx_active() {
    if systemctl is-active --quiet "${_NGINX_SERVICE}"; then
        return 0
    fi
    log_error "${_NGINX_SERVICE}.service is not active."
    return 1
}

# -----------------------------------------------------------------------------
# Function : _verify_http_response
# Purpose  : Smoke-test Nginx by fetching the default index on localhost.
#            Accepts any 2xx or 3xx response as a healthy signal.
# Returns  : 0 on healthy HTTP response, 1 otherwise.
# -----------------------------------------------------------------------------
_verify_http_response() {
    if ! command_exists curl; then
        log_warn "curl not available; skipping HTTP smoke test."
        return 0
    fi

    log_info "Verifying local HTTP response at ${_NGINX_HTTP_URL}..."

    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' \
                --connect-timeout "${_NGINX_HTTP_TIMEOUT}" \
                --max-time "${_NGINX_HTTP_TIMEOUT}" \
                "${_NGINX_HTTP_URL}" 2>/dev/null || echo "000")

    if [[ "${code}" =~ ^(2|3)[0-9]{2}$ ]]; then
        log_success "Nginx responded with HTTP ${code}."
        return 0
    fi

    log_error "Nginx did not respond as expected (HTTP ${code})."
    return 1
}

# -----------------------------------------------------------------------------
# Function : _print_listening_ports
# Purpose  : Print the ports Nginx is listening on. Prefers `ss` (iproute2),
#            falls back to `netstat` from net-tools.
# -----------------------------------------------------------------------------
_print_listening_ports() {
    printf "   %b→%b  Listening ports:\n" "${C_INFO}" "${C_RESET}"

    local listing=""

    if command_exists ss; then
        # -H : no header, -t : tcp, -l : listening, -n : numeric, -p : processes
        listing=$(ss -Htlnp 2>/dev/null | awk '/nginx/ {print $4}' | sort -u)
    elif command_exists netstat; then
        listing=$(netstat -tlnp 2>/dev/null | awk '/nginx/ {print $4}' | sort -u)
    else
        printf "       %b(ss/netstat not available)%b\n" "${C_DIM}" "${C_RESET}"
        return 0
    fi

    if [[ -z "${listing}" ]]; then
        printf "       %b(no nginx listeners detected)%b\n" "${C_DIM}" "${C_RESET}"
        return 0
    fi

    local line
    while IFS= read -r line; do
        printf "       %b•%b  %s\n" "${C_SUCCESS}" "${C_RESET}" "${line}"
    done <<< "${listing}"
}

# -----------------------------------------------------------------------------
# Function : _print_nginx_status
# Purpose  : Print a compact colored status block: version, service state,
#            enabled state, and listening ports.
# -----------------------------------------------------------------------------
_print_nginx_status() {
    echo ""
    printf "%b  Nginx status%b\n" "${C_HEADER}" "${C_RESET}"
    separator "-"

    _print_nginx_version

    local state
    state=$(systemctl is-active "${_NGINX_SERVICE}" 2>/dev/null || echo "unknown")
    if [[ "${state}" == "active" ]]; then
        printf "   %b→%b  Service : %bactive%b\n" \
            "${C_INFO}" "${C_RESET}" \
            "${C_SUCCESS}" "${C_RESET}"
    else
        printf "   %b→%b  Service : %b%s%b\n" \
            "${C_INFO}" "${C_RESET}" \
            "${C_ERROR}" "${state}" "${C_RESET}"
    fi

    local enabled
    enabled=$(systemctl is-enabled "${_NGINX_SERVICE}" 2>/dev/null || echo "unknown")
    printf "   %b→%b  Enabled : %s\n" "${C_INFO}" "${C_RESET}" "${enabled}"

    _print_listening_ports
    separator "-"
}

# =============================================================================
# PUBLIC ENTRY POINT
# =============================================================================

# -----------------------------------------------------------------------------
# Function : install_nginx
# Purpose  : Menu-facing action: install Nginx, enable/start the service,
#            verify it is answering HTTP locally, and print status details.
#
# Flow     :
#   1. Print a section header.
#   2. Verify root + network + apt.
#   3. Detect existing installation; print version and ask reinstall/skip.
#   4. Otherwise, ask for confirmation.
#   5. Install (or reinstall) the nginx package with a spinner.
#   6. Enable + start (or restart) nginx.service.
#   7. Verify service is active.
#   8. Verify local HTTP response with curl.
#   9. Print status: version, service state, listening ports.
#  10. Pause before returning to the menu.
#
# Returns  :
#   0   on success
#   1   on user cancellation / user chose to skip
#   2   on unmet prerequisite
#   3   on installation failure
#   4   on post-install verification failure
# -----------------------------------------------------------------------------
install_nginx() {
    _print_section_header

    # ---- Step 1: environment prerequisites --------------------------------
    check_root
    check_network
    require_command "apt-get" "apt"

    # ---- Step 2: detect existing installation -----------------------------
    local mode="install"
    if package_installed "${_NGINX_PACKAGE}" && command_exists nginx; then
        log_info "Nginx appears to be installed already."
        _print_nginx_version

        if ! confirm_action "Reinstall Nginx from the apt repository?"; then
            log_info "Skipping Nginx installation at user request."

            # Still surface current status so the user has useful info.
            _print_nginx_status
            pause_screen
            return 1
        fi
        mode="reinstall"
    else
        if ! confirm_action "Install Nginx now?"; then
            log_warn "User cancelled the operation."
            pause_screen
            return 1
        fi
    fi

    # ---- Step 3: install --------------------------------------------------
    if ! _install_nginx_package "${mode}"; then
        log_error "apt-get failed to ${mode} ${_NGINX_PACKAGE}."
        log_error "See the session log for details: ${LOG_FILE:-<not initialised>}"
        pause_screen
        return 3
    fi

    # ---- Step 4: enable + start -------------------------------------------
    if ! _enable_and_start_nginx; then
        pause_screen
        return 3
    fi

    # ---- Step 5: verify service is active ---------------------------------
    if ! _verify_nginx_active; then
        pause_screen
        return 4
    fi

    # ---- Step 6: HTTP smoke test ------------------------------------------
    if ! _verify_http_response; then
        # Non-fatal for the install itself, but signal a verification issue.
        log_warn "Service is active but HTTP verification failed."
        _print_nginx_status
        pause_screen
        return 4
    fi

    # ---- Step 7: report ---------------------------------------------------
    _print_nginx_status

    log_success "Nginx installed, running, and responding to HTTP requests."
    pause_screen
    return 0
}