#!/usr/bin/env bash
# =============================================================================
# Project      : Linux Server Automation
# File         : modules/install_awscli.sh
# Description  : Install AWS CLI v2 from the official AWS installer bundle.
#                Does NOT use the Ubuntu 'awscli' apt package (which ships
#                AWS CLI v1 and is unsupported by AWS).
# Compatible   : Ubuntu 24.04 LTS
# Depends on   : lib/colors.sh, lib/logger.sh, lib/utils.sh
# Reference    : https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
# =============================================================================

# -----------------------------------------------------------------------------
# Re-source guard
# -----------------------------------------------------------------------------
if [[ -n "${__INSTALL_AWSCLI_SH_LOADED:-}" ]]; then
    return 0
fi
readonly __INSTALL_AWSCLI_SH_LOADED=1

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------
for _dep in log_info log_warn log_error log_success log_debug separator \
            confirm_action pause_screen check_root check_network \
            command_exists require_command show_spinner; do
    if ! declare -F "${_dep}" >/dev/null 2>&1; then
        echo "ERROR: modules/install_awscli.sh requires ${_dep} (missing lib)." >&2
        return 1 2>/dev/null || exit 1
    fi
done
unset _dep

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

# Official AWS CLI v2 download URL template. AWS provides per-architecture
# bundles under stable URLs.
readonly _AWSCLI_URL_X86_64="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
readonly _AWSCLI_URL_AARCH64="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"

# Curl timeouts (seconds).
readonly _CURL_CONNECT_TIMEOUT=15
readonly _CURL_MAX_TIME=300

# Filesystem layout for the installer.
readonly _AWSCLI_ZIP_NAME="awscliv2.zip"
readonly _AWSCLI_INSTALL_DIR="/usr/local/aws-cli"
readonly _AWSCLI_BIN_PATH="/usr/local/bin/aws"

# Working directory for download + extraction. Populated at runtime by
# _prepare_workdir; cleaned up by _cleanup_workdir on every exit path.
_AWSCLI_WORKDIR=""

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
    printf "%b  >> Install AWS CLI v2 (official installer)%b\n" \
        "${C_HEADER}" "${C_RESET}"
    separator "="
    echo ""
}

# -----------------------------------------------------------------------------
# Function : _detect_installer_url
# Purpose  : Pick the correct AWS CLI installer URL for the current CPU
#            architecture. Returns an empty string on unsupported arches.
# Output   : URL on stdout.
# -----------------------------------------------------------------------------
_detect_installer_url() {
    local arch
    arch=$(uname -m 2>/dev/null || echo "unknown")

    case "${arch}" in
        x86_64|amd64)          echo "${_AWSCLI_URL_X86_64}"   ;;
        aarch64|arm64)         echo "${_AWSCLI_URL_AARCH64}"  ;;
        *)                     echo ""                          ;;
    esac
}

# -----------------------------------------------------------------------------
# Function : _is_awscli_installed
# Purpose  : Detect an existing AWS CLI v2 install. Reports true only when
#            the aws binary is present AND reports major version 2, so we
#            never mistake the deprecated v1 apt package for v2.
# -----------------------------------------------------------------------------
_is_awscli_installed() {
    command_exists aws || return 1

    local ver
    ver=$(aws --version 2>&1 | awk '{print $1}')

    # Expected format: aws-cli/2.x.y  (v1 would be aws-cli/1.x.y)
    [[ "${ver}" == aws-cli/2.* ]]
}

# -----------------------------------------------------------------------------
# Function : _get_awscli_version
# Purpose  : Return the compact `aws --version` string. AWS prints it on
#            stdout in modern versions, but we merge stderr just in case.
# -----------------------------------------------------------------------------
_get_awscli_version() {
    if command_exists aws; then
        aws --version 2>&1 | awk 'NF { print; exit }'
    fi
}

# -----------------------------------------------------------------------------
# Function : _print_awscli_version
# Purpose  : Print the version line in a compact colored form.
# -----------------------------------------------------------------------------
_print_awscli_version() {
    local ver
    ver=$(_get_awscli_version)
    if [[ -n "${ver}" ]]; then
        printf "   %b→%b  %s\n" "${C_INFO}" "${C_RESET}" "${ver}"
    else
        printf "   %b→%b  aws CLI not available.\n" \
            "${C_ERROR}" "${C_RESET}"
    fi
}

# -----------------------------------------------------------------------------
# Function : _prepare_workdir
# Purpose  : Create a private temp directory for download + extraction.
#            Sets _AWSCLI_WORKDIR.
# Returns  : 0 on success, 1 on failure.
# -----------------------------------------------------------------------------
_prepare_workdir() {
    if ! _AWSCLI_WORKDIR=$(mktemp -d /tmp/awscli-install.XXXXXX 2>/dev/null); then
        log_error "Failed to create temporary working directory."
        return 1
    fi
    chmod 700 "${_AWSCLI_WORKDIR}" 2>/dev/null || true
    log_debug "Working directory: ${_AWSCLI_WORKDIR}"
    return 0
}

# -----------------------------------------------------------------------------
# Function : _cleanup_workdir
# Purpose  : Recursively remove the working directory. Safe to call on any
#            code path; a no-op when nothing was created.
# -----------------------------------------------------------------------------
_cleanup_workdir() {
    if [[ -n "${_AWSCLI_WORKDIR}" && -d "${_AWSCLI_WORKDIR}" ]]; then
        rm -rf "${_AWSCLI_WORKDIR}" 2>/dev/null || true
        log_debug "Cleaned working directory: ${_AWSCLI_WORKDIR}"
    fi
    _AWSCLI_WORKDIR=""
}

# -----------------------------------------------------------------------------
# Function : _download_installer
# Purpose  : Download the AWS CLI v2 installer zip to the working directory
#            using curl. A spinner is shown while curl runs in the background.
# Args     : $1 - installer URL
# Returns  : 0 on success, 1 on any failure (bad HTTP, empty file, etc.)
# -----------------------------------------------------------------------------
_download_installer() {
    local url="$1"
    local dest="${_AWSCLI_WORKDIR}/${_AWSCLI_ZIP_NAME}"
    local rc=0

    log_info "Downloading AWS CLI installer from ${url}"

    # -f : fail on HTTP >= 400
    # -sS : silent but show errors
    # -L : follow redirects
    set +e
    curl -fsSL \
        --connect-timeout "${_CURL_CONNECT_TIMEOUT}" \
        --max-time "${_CURL_MAX_TIME}" \
        --output "${dest}" \
        "${url}" &
    show_spinner "$!" "Downloading AWS CLI installer..."
    rc=$?
    set -e

    if [[ ${rc} -ne 0 ]]; then
        log_error "curl failed to download installer (exit code ${rc})."
        return 1
    fi

    if [[ ! -s "${dest}" ]]; then
        log_error "Downloaded installer is missing or empty: ${dest}"
        return 1
    fi

    log_success "Installer downloaded ($(du -h "${dest}" | awk '{print $1}'))."
    return 0
}

# -----------------------------------------------------------------------------
# Function : _extract_installer
# Purpose  : Extract the AWS CLI zip inside the working directory.
# Returns  : 0 on success, 1 on failure.
# -----------------------------------------------------------------------------
_extract_installer() {
    local zip_path="${_AWSCLI_WORKDIR}/${_AWSCLI_ZIP_NAME}"

    log_info "Extracting installer..."

    # -q : quiet
    # -o : overwrite without prompting (defensive if a stale dir exists)
    # -d : target directory
    if ! unzip -q -o "${zip_path}" -d "${_AWSCLI_WORKDIR}" 2>/dev/null; then
        log_error "Failed to extract installer archive."
        return 1
    fi

    # Sanity-check the expected installer script exists.
    if [[ ! -x "${_AWSCLI_WORKDIR}/aws/install" ]]; then
        log_error "Extracted archive does not contain aws/install."
        return 1
    fi

    log_success "Installer extracted."
    return 0
}

# -----------------------------------------------------------------------------
# Function : _run_installer
# Purpose  : Execute AWS's ./aws/install script. Uses --update when an
#            existing install is detected so the run is idempotent.
# Args     : $1 - "install" (default) or "reinstall"
# Returns  : Exit status of the installer.
# -----------------------------------------------------------------------------
_run_installer() {
    local mode="${1:-install}"
    local installer="${_AWSCLI_WORKDIR}/aws/install"
    local rc=0

    log_info "Running AWS CLI installer (${mode})..."

    # The installer supports --update to overwrite an existing v2 install
    # without erroring out. We pass it whenever the caller says "reinstall"
    # OR when we detect the target paths already exist (defensive).
    local -a args=(
        "--install-dir" "${_AWSCLI_INSTALL_DIR}"
        "--bin-dir"     "/usr/local/bin"
    )
    if [[ "${mode}" == "reinstall" ]] \
        || [[ -d "${_AWSCLI_INSTALL_DIR}" ]] \
        || [[ -e "${_AWSCLI_BIN_PATH}" ]]; then
        args+=("--update")
    fi

    set +e
    "${installer}" "${args[@]}" \
        >>"${LOG_FILE:-/dev/null}" 2>&1 &
    show_spinner "$!" "Installing AWS CLI..."
    rc=$?
    set -e

    return "${rc}"
}

# -----------------------------------------------------------------------------
# Function : _verify_awscli
# Purpose  : Confirm the aws binary is on PATH and reports v2.
# Returns  : 0 if healthy, 1 otherwise.
# -----------------------------------------------------------------------------
_verify_awscli() {
    if ! command_exists aws; then
        log_error "aws binary not found on PATH after installation."
        return 1
    fi

    local ver
    ver=$(aws --version 2>&1 | awk '{print $1}')
    if [[ "${ver}" != aws-cli/2.* ]]; then
        log_error "Unexpected AWS CLI version detected: ${ver} (expected aws-cli/2.x)."
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Function : _print_awscli_status
# Purpose  : Print installed version and resolved binary path.
# -----------------------------------------------------------------------------
_print_awscli_status() {
    echo ""
    printf "%b  AWS CLI status%b\n" "${C_HEADER}" "${C_RESET}"
    separator "-"

    _print_awscli_version

    local bin_path=""
    if command_exists aws; then
        bin_path=$(command -v aws 2>/dev/null || true)
    fi
    if [[ -n "${bin_path}" ]]; then
        printf "   %b→%b  Binary  : %s\n" "${C_INFO}" "${C_RESET}" "${bin_path}"
    fi

    if [[ -d "${_AWSCLI_INSTALL_DIR}" ]]; then
        printf "   %b→%b  Install : %s\n" "${C_INFO}" "${C_RESET}" "${_AWSCLI_INSTALL_DIR}"
    fi

    separator "-"
}

# =============================================================================
# PUBLIC ENTRY POINT
# =============================================================================

# -----------------------------------------------------------------------------
# Function : install_awscli
# Purpose  : Menu-facing action: install AWS CLI v2 from the official
#            AWS installer bundle.
#
# Flow     :
#   1. Print a section header.
#   2. Verify root + network.
#   3. Verify required tools: curl, unzip.
#   4. Detect existing install; print version and offer reinstall/skip.
#   5. Otherwise, ask for confirmation.
#   6. Download the correct installer for the current architecture.
#   7. Extract, run installer (with --update if needed).
#   8. Verify aws is on PATH and reports v2.
#   9. Print status (version + install path). Clean up temp dir.
#  10. Pause before returning to the menu.
#
# Returns  :
#   0   on success
#   1   on user cancellation / user chose to skip
#   2   on unmet prerequisite
#   3   on installation failure
#   4   on post-install verification failure
# -----------------------------------------------------------------------------
install_awscli() {
    _print_section_header

    # ---- Step 1: environment prerequisites --------------------------------
    check_root
    check_network
    require_command "curl" "curl"
    require_command "unzip" "unzip"

    # ---- Step 2: architecture selection -----------------------------------
    local url
    url=$(_detect_installer_url)
    if [[ -z "${url}" ]]; then
        log_error "Unsupported CPU architecture: $(uname -m). AWS CLI v2 requires x86_64 or aarch64."
        pause_screen
        return 2
    fi

    # ---- Step 3: detect existing installation -----------------------------
    local mode="install"
    if _is_awscli_installed; then
        log_info "AWS CLI v2 appears to be installed already."
        _print_awscli_version

        if ! confirm_action "Reinstall / update AWS CLI v2?"; then
            log_info "Skipping AWS CLI installation at user request."
            _print_awscli_status
            pause_screen
            return 1
        fi
        mode="reinstall"
    else
        # A stray v1 install can confuse users; warn but continue.
        if command_exists aws; then
            log_warn "Detected an aws binary that is NOT AWS CLI v2. It will be superseded."
        fi
        if ! confirm_action "Install AWS CLI v2 now?"; then
            log_warn "User cancelled the operation."
            pause_screen
            return 1
        fi
    fi

    # ---- Step 4: prepare workspace ----------------------------------------
    if ! _prepare_workdir; then
        pause_screen
        return 2
    fi
    # Ensure the temp dir is removed even on error paths.
    # shellcheck disable=SC2064
    trap "_cleanup_workdir" RETURN

    # ---- Step 5: download -------------------------------------------------
    if ! _download_installer "${url}"; then
        pause_screen
        return 3
    fi

    # ---- Step 6: extract --------------------------------------------------
    if ! _extract_installer; then
        pause_screen
        return 3
    fi

    # ---- Step 7: install --------------------------------------------------
    if ! _run_installer "${mode}"; then
        log_error "AWS CLI installer failed. See session log for details: ${LOG_FILE:-<not initialised>}"
        pause_screen
        return 3
    fi

    # ---- Step 8: verify ---------------------------------------------------
    if ! _verify_awscli; then
        pause_screen
        return 4
    fi

    # ---- Step 9: report ---------------------------------------------------
    _print_awscli_status

    log_success "AWS CLI v2 installed and verified."
    pause_screen
    return 0
}