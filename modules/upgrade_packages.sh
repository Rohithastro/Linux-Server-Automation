#!/usr/bin/env bash
# =============================================================================
# Project      : Linux Server Automation
# File         : modules/upgrade_packages.sh
# Description  : Upgrade all installed apt packages to their latest available
#                versions. Complements modules/update_system.sh, which only
#                refreshes the package index.
# Compatible   : Ubuntu 24.04 LTS
# Depends on   : lib/colors.sh, lib/logger.sh, lib/utils.sh
# =============================================================================

# -----------------------------------------------------------------------------
# Re-source guard
# -----------------------------------------------------------------------------
if [[ -n "${__UPGRADE_PACKAGES_SH_LOADED:-}" ]]; then
    return 0
fi
readonly __UPGRADE_PACKAGES_SH_LOADED=1

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------
for _dep in log_info log_warn log_error log_success separator print_banner \
            confirm_action pause_screen check_root check_network \
            command_exists require_command show_spinner; do
    if ! declare -F "${_dep}" >/dev/null 2>&1; then
        echo "ERROR: modules/upgrade_packages.sh requires ${_dep} (missing lib)." >&2
        return 1 2>/dev/null || exit 1
    fi
done
unset _dep

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
# _APT_ENV and _APT_OPTS are provided by lib/utils.sh (single source of truth).
# DEBIAN_FRONTEND=noninteractive : suppress package config dialogs.
# The two Dpkg::Options force apt to keep the currently installed config
# file when a package ships a modified one. Safe non-interactive default
# for automation.

# Path to the temp file capturing apt-get output during the upgrade.
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
    printf "%b  >> Upgrade Installed Packages (apt upgrade)%b\n" \
        "${C_HEADER}" "${C_RESET}"
    separator "="
    echo ""
}

# -----------------------------------------------------------------------------
# Function : _prepare_apt_output_file
# Purpose  : Create a temporary log file to capture apt's output while the
#            spinner is running. Sets _APT_OUTPUT_FILE.
# Returns  : 0 on success, 1 on failure.
# -----------------------------------------------------------------------------
_prepare_apt_output_file() {
    local base_dir="${LOG_DIR:-/tmp}"

    if ! _APT_OUTPUT_FILE=$(mktemp "${base_dir}/apt-upgrade.XXXXXX.log" 2>/dev/null); then
        log_error "Failed to create temporary log file in ${base_dir}."
        return 1
    fi

    chmod 640 "${_APT_OUTPUT_FILE}" 2>/dev/null || true
    log_debug "apt output will be captured in: ${_APT_OUTPUT_FILE}"
    return 0
}

# -----------------------------------------------------------------------------
# Function : _cleanup_apt_output_file
# Purpose  : Append captured apt output to the session log and delete the
#            temp file. Called both on success and on failure.
# -----------------------------------------------------------------------------
_cleanup_apt_output_file() {
    if [[ -n "${_APT_OUTPUT_FILE}" && -f "${_APT_OUTPUT_FILE}" ]]; then
        if [[ -n "${LOG_FILE:-}" && -w "${LOG_FILE}" ]]; then
            {
                echo "----- apt upgrade output -----"
                cat "${_APT_OUTPUT_FILE}"
                echo "----- end apt upgrade output -----"
            } >> "${LOG_FILE}" 2>/dev/null || true
        fi
        rm -f "${_APT_OUTPUT_FILE}" 2>/dev/null || true
    fi
    _APT_OUTPUT_FILE=""
}

# -----------------------------------------------------------------------------
# Function : _count_upgradable_packages
# Purpose  : Query apt for the number of packages that currently have an
#            upgrade available. Runs before the upgrade so we can report how
#            many were pending. Uses `apt list --upgradable` which is stable
#            across recent Ubuntu releases.
# Output   : Prints an integer to stdout. Prints "0" on any failure.
# -----------------------------------------------------------------------------
_count_upgradable_packages() {
    local count=0

    # `apt list` prints a header line ("Listing...") which we exclude.
    # `2>/dev/null` silences the "WARNING: apt does not have a stable CLI"
    # noise that apt emits on stderr when used in scripts.
    if command_exists apt; then
        count=$(apt list --upgradable 2>/dev/null \
                 | grep -Ec '^[a-z0-9]' || true)
    fi

    # Guard against empty / non-numeric output.
    [[ "${count}" =~ ^[0-9]+$ ]] || count=0
    echo "${count}"
}

# -----------------------------------------------------------------------------
# Function : _run_apt_upgrade
# Purpose  : Launch `apt-get upgrade` in the background and drive the
#            spinner while it runs.
# Returns  : Exit status of apt-get.
# -----------------------------------------------------------------------------
_run_apt_upgrade() {
    local rc=0

    env "${_APT_ENV[@]}" apt-get upgrade "${_APT_OPTS[@]}" \
        >"${_APT_OUTPUT_FILE}" 2>&1 &
    local apt_pid=$!

    show_spinner "${apt_pid}" "Upgrading installed packages..."
    rc=$?

    return "${rc}"
}

# =============================================================================
# PUBLIC ENTRY POINT
# =============================================================================

# -----------------------------------------------------------------------------
# Function : upgrade_packages
# Purpose  : Menu-facing action: upgrade all installed apt packages.
#
# Flow     :
#   1. Print a section header.
#   2. Ask the user to confirm (this can be a long operation).
#   3. Verify root privileges.
#   4. Verify network connectivity.
#   5. Ensure apt-get is available.
#   6. Count upgradable packages up-front for the report.
#   7. Skip early if nothing is upgradable.
#   8. Run apt-get upgrade with a spinner and non-interactive options.
#   9. Report the outcome and the number of upgraded packages.
#  10. Pause before returning to the menu.
#
# Returns  :
#   0   on success (including "nothing to upgrade")
#   1   on user cancellation
#   2   on unmet prerequisite
#   3   on apt failure
# -----------------------------------------------------------------------------
upgrade_packages() {
    local rc=0
    local upgradable=0

    _print_section_header

    # ---- Step 1: user confirmation -----------------------------------------
    log_warn "Upgrading packages may take several minutes and may restart services."
    if ! confirm_action "Proceed with 'apt-get upgrade' now?"; then
        log_warn "User cancelled the operation."
        pause_screen
        return 1
    fi

    # ---- Step 2: environment prerequisites ---------------------------------
    check_root
    check_network
    require_command "apt-get" "apt"

    # ---- Step 3: pre-flight count ------------------------------------------
    log_info "Checking for upgradable packages..."
    upgradable=$(_count_upgradable_packages)

    if [[ "${upgradable}" -eq 0 ]]; then
        log_success "System is already up to date. No packages to upgrade."
        pause_screen
        return 0
    fi

    log_info "Detected ${upgradable} upgradable package(s)."

    # ---- Step 4: prepare output capture ------------------------------------
    if ! _prepare_apt_output_file; then
        pause_screen
        return 2
    fi

    log_info "Running: apt-get upgrade ${_APT_OPTS[*]}"

    # ---- Step 5: run apt upgrade with spinner ------------------------------
    # Temporarily disable errexit so a failing upgrade returns to the menu
    # instead of unwinding the whole script.
    set +e
    _run_apt_upgrade
    rc=$?
    set -e

    # ---- Step 6: persist captured output & clean up ------------------------
    _cleanup_apt_output_file

    # ---- Step 7: report outcome --------------------------------------------
    if [[ ${rc} -eq 0 ]]; then
        log_success "Upgrade completed successfully. ${upgradable} package(s) processed."

        # Suggest a reboot if the kernel or libc got upgraded and a marker
        # file exists (created by needrestart / update-notifier-common).
        if [[ -f /var/run/reboot-required ]]; then
            log_warn "A system reboot is required to finish applying updates."
        fi

        pause_screen
        return 0
    fi

    log_error "apt-get upgrade failed with exit code ${rc}."
    log_error "See the session log for details: ${LOG_FILE:-<not initialised>}"
    pause_screen
    return 3
}