#!/usr/bin/env bash
# =============================================================================
# Project      : Linux Server Automation
# File         : modules/configure_firewall.sh
# Description  : Configure UFW (Uncomplicated Firewall) with a safe default
#                policy: deny inbound, allow outbound, and permit SSH, HTTP,
#                HTTPS plus any additional operator-supplied ports.
# Compatible   : Ubuntu 24.04 LTS
# Depends on   : lib/colors.sh, lib/logger.sh, lib/utils.sh, lib/validators.sh
# =============================================================================

# -----------------------------------------------------------------------------
# Re-source guard
# -----------------------------------------------------------------------------
if [[ -n "${__CONFIGURE_FIREWALL_SH_LOADED:-}" ]]; then
    return 0
fi
readonly __CONFIGURE_FIREWALL_SH_LOADED=1

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------
for _dep in log_info log_warn log_error log_success log_debug separator \
            confirm_action pause_screen check_root check_network \
            command_exists require_command package_installed show_spinner \
            validate_port validate_yes_no; do
    if ! declare -F "${_dep}" >/dev/null 2>&1; then
        echo "ERROR: modules/configure_firewall.sh requires ${_dep} (missing lib)." >&2
        return 1 2>/dev/null || exit 1
    fi
done
unset _dep

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

# Baseline ports every managed host should allow.
# Format: "<port>/<proto> <label>" - kept as a single string per entry so
# it's easy to iterate and pretty-print.
readonly _DEFAULT_ALLOWED_RULES=(
    "22/tcp  SSH"
    "80/tcp  HTTP"
    "443/tcp HTTPS"
)

# Hard limit on how many extra ports we will accept in one interactive
# session (prevents accidental infinite loops on runaway input).
readonly _MAX_EXTRA_PORTS=32

# _APT_ENV and _APT_OPTS are provided by lib/utils.sh (single source of truth).

# Path to apt output capture file (populated at runtime).
_APT_OUTPUT_FILE=""

# Ports actually applied during this session (for the final summary).
_APPLIED_RULES=()

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
    printf "%b  >> Configure UFW Firewall%b\n" "${C_HEADER}" "${C_RESET}"
    separator "="
    echo ""
}

# -----------------------------------------------------------------------------
# Function : _prepare_apt_output_file
# Purpose  : Create a temp file to capture apt output while a spinner runs.
# -----------------------------------------------------------------------------
_prepare_apt_output_file() {
    local base_dir="${LOG_DIR:-/tmp}"

    if ! _APT_OUTPUT_FILE=$(mktemp "${base_dir}/apt-ufw.XXXXXX.log" 2>/dev/null); then
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
                echo "----- apt (ufw) output -----"
                cat "${_APT_OUTPUT_FILE}"
                echo "----- end apt (ufw) output -----"
            } >> "${LOG_FILE}" 2>/dev/null || true
        fi
        rm -f "${_APT_OUTPUT_FILE}" 2>/dev/null || true
    fi
    _APT_OUTPUT_FILE=""
}

# -----------------------------------------------------------------------------
# Function : _ensure_ufw_installed
# Purpose  : Install ufw via apt if it is not already present. Runs the apt
#            transaction with a spinner and captures output.
# Returns  : 0 on success, non-zero on failure.
# -----------------------------------------------------------------------------
_ensure_ufw_installed() {
    if package_installed ufw && command_exists ufw; then
        log_info "UFW is already installed."
        return 0
    fi

    log_warn "UFW is not installed. It will be installed automatically."
    require_command "apt-get" "apt"
    _prepare_apt_output_file || return 1

    local rc=0
    set +e
    env "${_APT_ENV[@]}" apt-get install "${_APT_OPTS[@]}" ufw \
        >"${_APT_OUTPUT_FILE}" 2>&1 &
    show_spinner "$!" "Installing UFW..."
    rc=$?
    set -e

    _cleanup_apt_output_file

    if [[ ${rc} -ne 0 ]]; then
        log_error "Failed to install UFW (apt exit code ${rc})."
        return 1
    fi

    if ! command_exists ufw; then
        log_error "UFW installation appeared to succeed but 'ufw' is not on PATH."
        return 1
    fi

    log_success "UFW installed."
    return 0
}

# -----------------------------------------------------------------------------
# Function : _ufw_status_raw
# Purpose  : Return the raw output of `ufw status verbose`. Requires root.
# -----------------------------------------------------------------------------
_ufw_status_raw() {
    ufw status verbose 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Function : _print_current_status
# Purpose  : Print a colored view of the current UFW state.
# -----------------------------------------------------------------------------
_print_current_status() {
    echo ""
    printf "%b  Current UFW status%b\n" "${C_HEADER}" "${C_RESET}"
    separator "-"

    local status
    status=$(_ufw_status_raw)

    if [[ -z "${status}" ]]; then
        printf "   %b→%b  (unable to query ufw status)\n" \
            "${C_ERROR}" "${C_RESET}"
    else
        # Indent for readability.
        while IFS= read -r line; do
            printf "   %s\n" "${line}"
        done <<< "${status}"
    fi

    separator "-"
}

# -----------------------------------------------------------------------------
# Function : _rule_already_present
# Purpose  : Return 0 if a rule for the given "port/proto" already exists
#            in the current UFW ruleset. Prevents duplicate `ufw allow`
#            calls (UFW would treat them as no-ops but still logs noise).
# Args     : $1 - "<port>/<proto>" e.g. "22/tcp"
# -----------------------------------------------------------------------------
_rule_already_present() {
    local rule="$1"
    local status

    status=$(_ufw_status_raw)
    [[ -z "${status}" ]] && return 1

    # Match on the exact "port/proto" token. UFW status prints rules like:
    #    22/tcp                     ALLOW IN    Anywhere
    # so anchoring on whitespace after the token is reliable.
    grep -Eq "^${rule}[[:space:]]+ALLOW" <<< "${status}"
}

# -----------------------------------------------------------------------------
# Function : _apply_rule
# Purpose  : Add a single `ufw allow` rule if not already present. Updates
#            _APPLIED_RULES on success.
# Args     : $1 - "<port>/<proto>"
#            $2 - human-readable label (used in log line only)
# Returns  : 0 on success or "already present", 1 on failure.
# -----------------------------------------------------------------------------
_apply_rule() {
    local rule="$1"
    local label="${2:-}"

    if _rule_already_present "${rule}"; then
        log_info "Rule already present: ${rule} (${label})"
        _APPLIED_RULES+=("${rule}  ${label}  (existing)")
        return 0
    fi

    log_info "Adding UFW rule: ufw allow ${rule}  # ${label}"
    if ! ufw allow "${rule}" >/dev/null 2>&1; then
        log_error "Failed to add UFW rule: ${rule}"
        return 1
    fi

    _APPLIED_RULES+=("${rule}  ${label}  (added)")
    return 0
}

# -----------------------------------------------------------------------------
# Function : _apply_default_rules
# Purpose  : Iterate the baseline rule set and apply each one.
# Returns  : 0 if all applied successfully, 1 if any failed.
# -----------------------------------------------------------------------------
_apply_default_rules() {
    local overall_rc=0
    local entry rule label

    for entry in "${_DEFAULT_ALLOWED_RULES[@]}"; do
        # Split "22/tcp  SSH" into rule="22/tcp" and label="SSH".
        # `read` collapses runs of whitespace by default.
        read -r rule label <<< "${entry}"

        if ! _apply_rule "${rule}" "${label}"; then
            overall_rc=1
        fi
    done

    return "${overall_rc}"
}

# -----------------------------------------------------------------------------
# Function : _prompt_extra_ports
# Purpose  : Ask the operator whether additional ports should be opened.
#            Each entered value is validated with validate_port(); the
#            protocol is tcp by default but "<port>/udp" is accepted.
#            Terminates on empty input, "done", or after _MAX_EXTRA_PORTS.
# -----------------------------------------------------------------------------
_prompt_extra_ports() {
    if [[ ! -t 0 ]]; then
        log_warn "Non-interactive shell: skipping extra port prompt."
        return 0
    fi

    if ! confirm_action "Open additional ports beyond SSH/HTTP/HTTPS?"; then
        log_info "No additional ports requested."
        return 0
    fi

    local count=0
    local input port proto rule

    while (( count < _MAX_EXTRA_PORTS )); do
        printf "%b  Extra port [<port> or <port>/tcp|udp] (empty to finish): %b" \
            "${C_PROMPT}" "${C_RESET}"

        if ! read -r input; then
            echo ""
            break
        fi

        # Trim whitespace.
        input="${input#"${input%%[![:space:]]*}"}"
        input="${input%"${input##*[![:space:]]}"}"

        # Termination sentinels.
        [[ -z "${input}" || "${input,,}" == "done" ]] && break

        # Split off an optional /tcp or /udp suffix.
        if [[ "${input}" == */* ]]; then
            port="${input%/*}"
            proto="${input##*/}"
            proto="${proto,,}"
            if [[ "${proto}" != "tcp" && "${proto}" != "udp" ]]; then
                log_error "Invalid protocol '${proto}'. Use 'tcp' or 'udp'."
                continue
            fi
        else
            port="${input}"
            proto="tcp"
        fi

        # Validate the numeric port (delegates error message to validator).
        if ! validate_port "${port}"; then
            continue
        fi

        rule="${port}/${proto}"
        if ! _apply_rule "${rule}" "custom"; then
            log_warn "Skipping ${rule} due to previous error."
        fi

        count=$(( count + 1 ))
    done

    if (( count >= _MAX_EXTRA_PORTS )); then
        log_warn "Reached maximum of ${_MAX_EXTRA_PORTS} extra ports for this session."
    fi
}

# -----------------------------------------------------------------------------
# Function : _set_default_policies
# Purpose  : Enforce sane defaults: deny inbound, allow outbound. This is
#            the standard "server" posture.
# Returns  : 0 on success, non-zero on any failure.
# -----------------------------------------------------------------------------
_set_default_policies() {
    log_info "Setting default policy: deny incoming, allow outgoing."
    ufw default deny incoming  >/dev/null 2>&1 || {
        log_error "Failed to set default incoming policy."
        return 1
    }
    ufw default allow outgoing >/dev/null 2>&1 || {
        log_error "Failed to set default outgoing policy."
        return 1
    }
    return 0
}

# -----------------------------------------------------------------------------
# Function : _enable_ufw
# Purpose  : Enable UFW if not already active. Uses `--force` to avoid the
#            "may disrupt SSH" interactive prompt (SSH is explicitly allowed
#            by the baseline rules before this runs).
# Returns  : 0 on success, non-zero on failure.
# -----------------------------------------------------------------------------
_enable_ufw() {
    if ufw status 2>/dev/null | grep -qi "Status: active"; then
        log_info "UFW is already active."
        return 0
    fi

    log_info "Enabling UFW..."
    if ! ufw --force enable >/dev/null 2>&1; then
        log_error "Failed to enable UFW."
        return 1
    fi

    log_success "UFW enabled."
    return 0
}

# -----------------------------------------------------------------------------
# Function : _reload_ufw
# Purpose  : Reload the ruleset so changes are guaranteed to be live.
# Returns  : 0 on success, non-zero on failure.
# -----------------------------------------------------------------------------
_reload_ufw() {
    log_info "Reloading UFW..."
    if ! ufw reload >/dev/null 2>&1; then
        log_error "Failed to reload UFW."
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Function : _print_summary
# Purpose  : Print the list of rules applied this session plus the final
#            UFW status block.
# -----------------------------------------------------------------------------
_print_summary() {
    echo ""
    printf "%b  Applied rules%b\n" "${C_HEADER}" "${C_RESET}"
    separator "-"

    if [[ ${#_APPLIED_RULES[@]} -eq 0 ]]; then
        printf "   %b(none)%b\n" "${C_DIM}" "${C_RESET}"
    else
        local entry
        for entry in "${_APPLIED_RULES[@]}"; do
            printf "   %b✓%b  %s\n" "${C_SUCCESS}" "${C_RESET}" "${entry}"
        done
    fi
    separator "-"

    _print_current_status
}

# =============================================================================
# PUBLIC ENTRY POINT
# =============================================================================

# -----------------------------------------------------------------------------
# Function : configure_firewall
# Purpose  : Menu-facing action: install (if needed) and configure UFW with
#            SSH/HTTP/HTTPS plus any extra operator-supplied ports. Uses
#            deny-in / allow-out defaults and enables UFW non-interactively.
#
# Returns  :
#   0   on success
#   1   on user cancellation
#   2   on unmet prerequisite (e.g. ufw install failed)
#   3   on rule / policy application failure
#   4   on failure to enable or reload UFW
# -----------------------------------------------------------------------------
configure_firewall() {
    _APPLIED_RULES=()

    _print_section_header

    # ---- Step 1: environment prerequisites --------------------------------
    check_root
    check_network

    log_warn "This will enable UFW and allow only the listed ports inbound."
    log_warn "Ensure SSH access (port 22) is intended before continuing."
    if ! confirm_action "Proceed with UFW configuration?"; then
        log_warn "User cancelled the operation."
        pause_screen
        return 1
    fi

    # ---- Step 2: ensure ufw is present ------------------------------------
    if ! _ensure_ufw_installed; then
        pause_screen
        return 2
    fi

    # ---- Step 3: show status BEFORE changes -------------------------------
    _print_current_status

    # ---- Step 4: set default deny-in / allow-out policies -----------------
    if ! _set_default_policies; then
        pause_screen
        return 3
    fi

    # ---- Step 5: apply baseline rules (SSH/HTTP/HTTPS) --------------------
    if ! _apply_default_rules; then
        log_error "One or more baseline rules failed to apply."
        pause_screen
        return 3
    fi

    # ---- Step 6: interactive extra ports ----------------------------------
    _prompt_extra_ports

    # ---- Step 7: enable + reload ------------------------------------------
    if ! _enable_ufw; then
        pause_screen
        return 4
    fi

    if ! _reload_ufw; then
        pause_screen
        return 4
    fi

    # ---- Step 8: summary --------------------------------------------------
    _print_summary

    log_success "UFW configured successfully."
    pause_screen
    return 0
}