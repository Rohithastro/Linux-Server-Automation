#!/usr/bin/env bash
# =============================================================================
# Project      : Linux Server Automation
# File         : modules/install_devtools.sh
# Description  : Install a curated set of core developer / sysadmin CLI tools
#                via apt. Skips packages that are already installed and
#                reports per-package status at the end.
# Compatible   : Ubuntu 24.04 LTS
# Depends on   : lib/colors.sh, lib/logger.sh, lib/utils.sh
# =============================================================================

# -----------------------------------------------------------------------------
# Re-source guard
# -----------------------------------------------------------------------------
if [[ -n "${__INSTALL_DEVTOOLS_SH_LOADED:-}" ]]; then
    return 0
fi
readonly __INSTALL_DEVTOOLS_SH_LOADED=1

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------
for _dep in log_info log_warn log_error log_success log_debug separator \
            confirm_action pause_screen check_root check_network \
            command_exists require_command package_installed show_spinner; do
    if ! declare -F "${_dep}" >/dev/null 2>&1; then
        echo "ERROR: modules/install_devtools.sh requires ${_dep} (missing lib)." >&2
        return 1 2>/dev/null || exit 1
    fi
done
unset _dep

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

# The canonical list of developer tools this module manages. Kept as a
# readonly array so it is easy to review and audit in one place.
readonly _DEVTOOLS_PACKAGES=(
    git
    curl
    wget
    vim
    nano
    unzip
    zip
    tree
    htop
    net-tools
    build-essential
    software-properties-common
)

# _APT_ENV and _APT_OPTS are provided by lib/utils.sh (single source of truth).

# Mapping from package name -> executable to probe for a version string.
# Not every package installs a binary matching its name, so we keep an
# explicit table. Packages absent from this table are reported as
# "installed" without a version line.
declare -rA _DEVTOOLS_VERSION_CMD=(
    [git]="git --version"
    [curl]="curl --version"
    [wget]="wget --version"
    [vim]="vim --version"
    [nano]="nano --version"
    [unzip]="unzip -v"
    [zip]="zip --version"
    [tree]="tree --version"
    [htop]="htop --version"
    [net-tools]="ifconfig --version"
    [build-essential]="gcc --version"
    [software-properties-common]="add-apt-repository --help"
)

# Runtime state populated by _classify_packages / _install_missing.
# Declared at file scope so helper functions can update and read them.
_ALREADY_INSTALLED=()
_TO_INSTALL=()
_INSTALLED_OK=()
_INSTALL_FAILED=()

# Path to the apt output capture file.
_APT_OUTPUT_FILE=""

# =============================================================================
# INTERNAL HELPERS
# =============================================================================

# -----------------------------------------------------------------------------
# Function : _print_section_header
# Purpose  : Colored section header for the module.
# -----------------------------------------------------------------------------
_print_section_header() {
    echo ""
    separator "="
    printf "%b  >> Install Developer Tools%b\n" "${C_HEADER}" "${C_RESET}"
    separator "="
    echo ""
}

# -----------------------------------------------------------------------------
# Function : _reset_state
# Purpose  : Clear all module-scoped arrays so repeated invocations from the
#            menu do not accumulate stale state.
# -----------------------------------------------------------------------------
_reset_state() {
    _ALREADY_INSTALLED=()
    _TO_INSTALL=()
    _INSTALLED_OK=()
    _INSTALL_FAILED=()
    _APT_OUTPUT_FILE=""
}

# -----------------------------------------------------------------------------
# Function : _classify_packages
# Purpose  : Split the canonical package list into "already installed" and
#            "to install" buckets by querying dpkg via package_installed().
# -----------------------------------------------------------------------------
_classify_packages() {
    local pkg
    for pkg in "${_DEVTOOLS_PACKAGES[@]}"; do
        if package_installed "${pkg}"; then
            _ALREADY_INSTALLED+=("${pkg}")
            log_debug "Already installed: ${pkg}"
        else
            _TO_INSTALL+=("${pkg}")
            log_debug "Pending install:   ${pkg}"
        fi
    done
}

# -----------------------------------------------------------------------------
# Function : _prepare_apt_output_file
# Purpose  : Create a temp file to capture apt-get output while the spinner
#            is running. Sets _APT_OUTPUT_FILE.
# Returns  : 0 on success, 1 on failure.
# -----------------------------------------------------------------------------
_prepare_apt_output_file() {
    local base_dir="${LOG_DIR:-/tmp}"

    if ! _APT_OUTPUT_FILE=$(mktemp "${base_dir}/apt-devtools.XXXXXX.log" 2>/dev/null); then
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
#            temp file. Safe to call multiple times.
# -----------------------------------------------------------------------------
_cleanup_apt_output_file() {
    if [[ -n "${_APT_OUTPUT_FILE}" && -f "${_APT_OUTPUT_FILE}" ]]; then
        if [[ -n "${LOG_FILE:-}" && -w "${LOG_FILE}" ]]; then
            {
                echo "----- apt install (devtools) output -----"
                cat "${_APT_OUTPUT_FILE}"
                echo "----- end apt install (devtools) output -----"
            } >> "${LOG_FILE}" 2>/dev/null || true
        fi
        rm -f "${_APT_OUTPUT_FILE}" 2>/dev/null || true
    fi
    _APT_OUTPUT_FILE=""
}

# -----------------------------------------------------------------------------
# Function : _apt_install_batch
# Purpose  : Attempt a single apt-get install call for every pending package.
#            This is the fast path: one apt transaction resolves all deps
#            at once.
# Returns  : Exit status of apt-get.
# -----------------------------------------------------------------------------
_apt_install_batch() {
    local rc=0

    env "${_APT_ENV[@]}" apt-get install "${_APT_OPTS[@]}" \
        --no-install-recommends "${_TO_INSTALL[@]}" \
        >"${_APT_OUTPUT_FILE}" 2>&1 &
    local apt_pid=$!

    show_spinner "${apt_pid}" \
        "Installing ${#_TO_INSTALL[@]} developer package(s)..."
    rc=$?

    return "${rc}"
}

# -----------------------------------------------------------------------------
# Function : _reconcile_install_results
# Purpose  : After an install attempt, re-query dpkg for each requested
#            package and populate _INSTALLED_OK / _INSTALL_FAILED. This
#            handles the "batch install partially succeeded" case cleanly.
# -----------------------------------------------------------------------------
_reconcile_install_results() {
    local pkg
    for pkg in "${_TO_INSTALL[@]}"; do
        if package_installed "${pkg}"; then
            _INSTALLED_OK+=("${pkg}")
        else
            _INSTALL_FAILED+=("${pkg}")
        fi
    done
}

# -----------------------------------------------------------------------------
# Function : _install_missing
# Purpose  : Orchestrate the installation of _TO_INSTALL. Runs one apt
#            transaction, then reconciles results per package so we can
#            report which succeeded and which failed.
# Returns  : 0 if every requested package ended up installed, 1 otherwise.
# -----------------------------------------------------------------------------
_install_missing() {
    if [[ ${#_TO_INSTALL[@]} -eq 0 ]]; then
        log_info "No missing packages to install."
        return 0
    fi

    if ! _prepare_apt_output_file; then
        # Mark everything as failed so the summary reflects reality.
        _INSTALL_FAILED=("${_TO_INSTALL[@]}")
        return 1
    fi

    log_info "Installing: ${_TO_INSTALL[*]}"

    # Temporarily disable errexit: apt may fail on a subset of packages
    # (e.g. missing candidate) but we still want to run reconciliation.
    local rc=0
    set +e
    _apt_install_batch
    rc=$?
    set -e

    _cleanup_apt_output_file
    _reconcile_install_results

    if [[ ${rc} -ne 0 ]]; then
        log_warn "apt-get install exited with code ${rc}."
    fi

    [[ ${#_INSTALL_FAILED[@]} -eq 0 ]]
}

# -----------------------------------------------------------------------------
# Function : _get_package_version
# Purpose  : Return a short version string for a package by invoking its
#            associated version command. Falls back to dpkg-query when no
#            explicit command is defined.
# Args     : $1 - package name
# Output   : First non-empty line of version output, or "installed".
# -----------------------------------------------------------------------------
_get_package_version() {
    local pkg="$1"
    local cmd="${_DEVTOOLS_VERSION_CMD[${pkg}]:-}"
    local first_line=""

    if [[ -n "${cmd}" ]]; then
        # Grab the first non-empty line of the command's output. `head -n1`
        # keeps the rendering compact; `2>&1` catches tools that print
        # version info on stderr (e.g. some GNU utils).
        first_line=$(${cmd} 2>&1 | awk 'NF { print; exit }' || true)
    fi

    if [[ -z "${first_line}" ]] && command_exists dpkg-query; then
        first_line=$(dpkg-query -W -f='${Version}' "${pkg}" 2>/dev/null || true)
    fi

    if [[ -z "${first_line}" ]]; then
        first_line="installed"
    fi

    echo "${first_line}"
}

# -----------------------------------------------------------------------------
# Function : _print_versions
# Purpose  : List every managed package with its detected version. Purely
#            informational.
# -----------------------------------------------------------------------------
_print_versions() {
    echo ""
    printf "%b  Installed package versions:%b\n" "${C_HEADER}" "${C_RESET}"
    separator "-"

    local pkg version
    for pkg in "${_DEVTOOLS_PACKAGES[@]}"; do
        # Only report packages that are actually installed on disk right now.
        if ! package_installed "${pkg}"; then
            printf "   %b✗%b  %-28s  %bnot installed%b\n" \
                "${C_ERROR}" "${C_RESET}" "${pkg}" \
                "${C_DIM}" "${C_RESET}"
            continue
        fi

        version=$(_get_package_version "${pkg}")
        printf "   %b✓%b  %-28s  %b%s%b\n" \
            "${C_SUCCESS}" "${C_RESET}" "${pkg}" \
            "${C_DIM}" "${version}" "${C_RESET}"
    done

    separator "-"
}

# -----------------------------------------------------------------------------
# Function : _print_summary
# Purpose  : Print a three-bucket summary of the operation.
# -----------------------------------------------------------------------------
_print_summary() {
    echo ""
    printf "%b  Summary%b\n" "${C_HEADER}" "${C_RESET}"
    separator "-"

    printf "   %bNewly installed  : %d%b\n" \
        "${C_SUCCESS}" "${#_INSTALLED_OK[@]}" "${C_RESET}"
    if [[ ${#_INSTALLED_OK[@]} -gt 0 ]]; then
        printf "       %s\n" "${_INSTALLED_OK[*]}"
    fi

    printf "   %bAlready installed: %d%b\n" \
        "${C_INFO}" "${#_ALREADY_INSTALLED[@]}" "${C_RESET}"
    if [[ ${#_ALREADY_INSTALLED[@]} -gt 0 ]]; then
        printf "       %s\n" "${_ALREADY_INSTALLED[*]}"
    fi

    printf "   %bFailed           : %d%b\n" \
        "${C_ERROR}" "${#_INSTALL_FAILED[@]}" "${C_RESET}"
    if [[ ${#_INSTALL_FAILED[@]} -gt 0 ]]; then
        printf "       %s\n" "${_INSTALL_FAILED[*]}"
    fi

    separator "-"
}

# =============================================================================
# PUBLIC ENTRY POINT
# =============================================================================

# -----------------------------------------------------------------------------
# Function : install_devtools
# Purpose  : Menu-facing action: install the curated developer toolset.
#
# Flow     :
#   1. Print a section header.
#   2. Ask the user to confirm.
#   3. Verify root privileges + network + apt.
#   4. Classify packages (already installed vs missing).
#   5. Short-circuit when nothing to install.
#   6. Install missing packages in one apt transaction, with a spinner.
#   7. Reconcile per-package success/failure.
#   8. Display versions for every managed package.
#   9. Print a colored summary (installed / already / failed).
#  10. Pause before returning to the menu.
#
# Returns  :
#   0   on success (every requested package installed / already present)
#   1   on user cancellation
#   2   on unmet prerequisite
#   3   when one or more packages failed to install
# -----------------------------------------------------------------------------
install_devtools() {
    _print_section_header
    _reset_state

    # ---- Step 1: user confirmation -----------------------------------------
    log_info "This will install ${#_DEVTOOLS_PACKAGES[@]} developer tool(s): ${_DEVTOOLS_PACKAGES[*]}"
    if ! confirm_action "Proceed with installation?"; then
        log_warn "User cancelled the operation."
        pause_screen
        return 1
    fi

    # ---- Step 2: environment prerequisites ---------------------------------
    check_root
    check_network
    require_command "apt-get" "apt"

    # ---- Step 3: classify what's already installed -------------------------
    log_info "Detecting already-installed packages..."
    _classify_packages
    log_info "Already installed: ${#_ALREADY_INSTALLED[@]} / ${#_DEVTOOLS_PACKAGES[@]}"
    log_info "To be installed  : ${#_TO_INSTALL[@]} / ${#_DEVTOOLS_PACKAGES[@]}"

    # ---- Step 4: install missing packages ----------------------------------
    local install_rc=0
    if ! _install_missing; then
        install_rc=1
    fi

    # ---- Step 5: report ----------------------------------------------------
    _print_versions
    _print_summary

    # ---- Step 6: final outcome & meaningful exit code ----------------------
    if [[ ${install_rc} -eq 0 ]]; then
        log_success "Developer tools installation completed successfully."
        pause_screen
        return 0
    fi

    log_error "Developer tools installation completed with failures."
    log_error "See the session log for details: ${LOG_FILE:-<not initialised>}"
    pause_screen
    return 3
}