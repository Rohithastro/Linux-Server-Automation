#!/usr/bin/env bash
# =============================================================================
# Project      : Linux Server Automation
# File         : modules/update_system.sh
# Description  : Refresh the local apt package index by running `apt update`.
#                Does NOT upgrade installed packages - that is handled by
#                modules/upgrade_packages.sh.
# Compatible   : Ubuntu 24.04 LTS
# Depends on   : lib/colors.sh, lib/logger.sh, lib/utils.sh
# =============================================================================

# -----------------------------------------------------------------------------
# Re-source guard
# -----------------------------------------------------------------------------
if [[ -n "${__UPDATE_SYSTEM_SH_LOADED:-}" ]]; then
    return 0
fi
readonly __UPDATE_SYSTEM_SH_LOADED=1

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------
for _dep in log_info log_error log_success separator print_banner \
            confirm_action pause_screen check_root check_network \
            command_exists require_command show_spinner; do
    if ! declare -F "${_dep}" >/dev/null 2>&1; then
        echo "ERROR: modules/update_system.sh requires ${_dep} (missing lib)." >&2
        return 1 2>/dev/null || exit 1
    fi
done
unset _dep

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
# DEBIAN_FRONTEND=noninteractive prevents apt from prompting for input
# (e.g. package config dialogs) while we run non-interactively.
# Dedicated output file for the background apt process. Placed inside the
# session log directory so it is captured alongside session logs.
_APT_OUTPUT_FILE=""

# =============================================================================
# INTERNAL HELPERS
# =============================================================================

# -----------------------------------------------------------------------------
# Function : _print_section_header
# Purpose  : Render a clear, colored header identifying the current action.
# -----------------------------------------------------------------------------
_print_section_header() {
    echo ""
    separator "="
    printf "%b  >> Update System (apt update)%b\n" "${C_HEADER}" "${C_RESET}"
    echo ""
}

# -----------------------------------------------------------------------------
# Function : _prepare_apt_output_file
# Purpose  : Create a temporary file to capture apt's stdout/stderr while
#            the spinner runs. Sets _APT_OUTPUT_FILE. Returns 1 on failure.
# -----------------------------------------------------------------------------
_prepare_apt_output_file() {
    local base_dir="${LOG_DIR:-/tmp}"

    if ! _APT_OUTPUT_FILE=$(mktemp "${base_dir}/apt-update.XXXXXX.log" 2>/dev/null); then
        log_error "Failed to create temporary log file in ${base_dir}."
        return 1
    fi

    chmod 640 "${_APT_OUTPUT_FILE}" 2>/dev/null || true
    log_debug "apt output will be captured in: ${_APT_OUTPUT_FILE}"
    return 0
}

# -----------------------------------------------------------------------------
# Function : _cleanup_apt_output_file
# Purpose  : Append the captured apt output to the session log (for the
#            record) and then remove the temporary file.
# -----------------------------------------------------------------------------
_cleanup_apt_output_file() {
    if [[ -n "${_APT_OUTPUT_FILE}" && -f "${_APT_OUTPUT_FILE}" ]]; then
        if [[ -n "${LOG_FILE:-}" && -w "${LOG_FILE}" ]]; then
            {
                echo "----- apt update output -----"
                cat "${_APT_OUTPUT_FILE}"
                echo "----- end apt update output -----"
            } >> "${LOG_FILE}" 2>/dev/null || true
        fi
        rm -f "${_APT_OUTPUT_FILE}" 2>/dev/null || true
    fi
    _APT_OUTPUT_FILE=""
}

# -----------------------------------------------------------------------------
# Function : _run_apt_update
# Purpose  : Launch `apt-get update` in the background, show a spinner while
#            it runs, and wait for it to finish.
# Returns  : Exit status of apt-get.
# -----------------------------------------------------------------------------
_run_apt_update() {
    local rc=0

    # Run apt in the background so show_spinner can watch its PID. All
    # output is redirected to the capture file to keep the terminal clean.
    env "${_APT_ENV[@]}" apt-get update -y \
        >"${_APT_OUTPUT_FILE}" 2>&1 &
    local apt_pid=$!

    # Show a spinner. Its return value equals the child's exit status.
    show_spinner "${apt_pid}" "Refreshing apt package index..."
    rc=$?

    return "${rc}"
}

# =============================================================================
# PUBLIC ENTRY POINT
# =============================================================================

# -----------------------------------------------------------------------------
# Function : update_system
# Purpose  : Menu-facing action: refresh the apt package index.
#
# Flow     :
#   1. Print a section header.
#   2. Ask the user to confirm.
#   3. Verify root privileges.
#   4. Verify network connectivity.
#   5. Ensure `apt-get` is available.
#   6. Run `apt-get update` with a spinner.
#   7. Log every step and outcome.
#   8. Pause before returning to the menu.
#
# Returns  :
#   0   on success
#   1   on user cancellation
#   2   on unmet prerequisite (network / missing command)
#   3   on apt failure
# -----------------------------------------------------------------------------
update_system() {
    local rc=0

    _print_section_header

    # ---- Step 1: user confirmation -----------------------------------------
    if ! confirm_action "Refresh the apt package index now?"; then
        log_warn "User cancelled the operation."
        pause_screen
        return 1
    fi

    # ---- Step 2: root check ------------------------------------------------
    # check_root exits on failure; harmless if we're already root.
    check_root

    # ---- Step 3: network check ---------------------------------------------
    # check_network exits on failure, which is fine: without network there
    # is nothing productive we can do here.
    check_network

    # ---- Step 4: verify apt-get is present ---------------------------------
    require_command "apt-get" "apt"

    # ---- Step 5: prepare output capture ------------------------------------
    if ! _prepare_apt_output_file; then
        pause_screen
        return 2
    fi

    log_info "Running: apt-get update"

    # ---- Step 6: run apt update with spinner -------------------------------
    # Temporarily disable `errexit` so a non-zero apt exit doesn't unwind
    # the whole script - we want to report it and return to the menu.
    set +e
    _run_apt_update
    rc=$?
    set -e

    # ---- Step 7: persist captured output & clean up ------------------------
    _cleanup_apt_output_file

    # ---- Step 8: report outcome --------------------------------------------
    if [[ ${rc} -eq 0 ]]; then
        log_success "apt package index refreshed successfully."
        pause_screen
        return 0
    fi

    log_error "apt-get update failed with exit code ${rc}."
    log_error "See the session log for details: ${LOG_FILE:-<not initialised>}"
    pause_screen
    return 3
}
