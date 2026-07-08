#!/usr/bin/env bash
# =============================================================================
# Project      : Linux Server Automation
# File         : setup.sh
# Description  : Main entry point for the Linux Server Automation toolkit.
#                Loads all modules, validates environment, and launches the
#                interactive menu.
# Author       : Senior Linux DevOps Engineer
# Compatible   : Ubuntu 24.04 LTS
# Usage        : sudo ./setup.sh
# =============================================================================

# ---- Strict mode -----------------------------------------------------------
# -e : exit on any command failure
# -u : treat unset variables as errors
# -o pipefail : fail a pipeline if any command in it fails
set -euo pipefail

# ---- Global constants ------------------------------------------------------
# Resolve absolute directory of this script (works even if symlinked/sourced)
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_NAME="Linux Server Automation"
readonly PROJECT_VERSION="1.0.0"

# Directory layout
readonly LIB_DIR="${SCRIPT_DIR}/lib"
readonly MODULES_DIR="${SCRIPT_DIR}/modules"
readonly LOG_DIR="${SCRIPT_DIR}/logs"
readonly REPORT_DIR="${SCRIPT_DIR}/reports"

# Export commonly used paths so modules can reference them
export SCRIPT_DIR LIB_DIR MODULES_DIR LOG_DIR REPORT_DIR
export PROJECT_NAME PROJECT_VERSION

# -----------------------------------------------------------------------------
# Function : bootstrap_directories
# Purpose  : Ensure that required runtime directories (logs, reports) exist.
#            Called before any logging module is sourced, so uses plain echo.
# -----------------------------------------------------------------------------
bootstrap_directories() {
    local dir
    for dir in "${LOG_DIR}" "${REPORT_DIR}"; do
        if [[ ! -d "${dir}" ]]; then
            mkdir -p "${dir}" || {
                echo "ERROR: Failed to create directory: ${dir}" >&2
                exit 1
            }
        fi
    done
}

# -----------------------------------------------------------------------------
# Function : source_file
# Purpose  : Safely source a shell library file, aborting with a clear error
#            if the file is missing or unreadable.
# Args     : $1 - absolute path to file to source
# -----------------------------------------------------------------------------
source_file() {
    local file="$1"
    if [[ ! -f "${file}" ]]; then
        echo "ERROR: Required file not found: ${file}" >&2
        exit 1
    fi
    if [[ ! -r "${file}" ]]; then
        echo "ERROR: Required file not readable: ${file}" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    source "${file}"
}

# -----------------------------------------------------------------------------
# Function : load_libraries
# Purpose  : Source all shared library files (colors, logger, utils, validators).
#            Order matters: colors -> logger -> utils -> validators.
# -----------------------------------------------------------------------------
load_libraries() {
    source_file "${LIB_DIR}/colors.sh"
    source_file "${LIB_DIR}/logger.sh"
    source_file "${LIB_DIR}/utils.sh"
    source_file "${LIB_DIR}/validators.sh"
}

# -----------------------------------------------------------------------------
# Function : load_modules
# Purpose  : Source all feature modules that implement individual menu actions.
# -----------------------------------------------------------------------------
load_modules() {
    local module
    for module in "${MODULES_DIR}"/*.sh; do
        [[ -e "${module}" ]] || {
            log_error "No modules found in ${MODULES_DIR}"
            exit 1
        }
        source_file "${module}"
    done
}

# -----------------------------------------------------------------------------
# Function : preflight_checks
# Purpose  : Verify that the script is being executed in a valid environment:
#            - Running as root (required for apt, ufw, systemctl, etc.)
#            - Running on Ubuntu 24.04
#            - Has network connectivity
# -----------------------------------------------------------------------------
preflight_checks() {
    check_root
    check_ubuntu_version
    check_network
}

# -----------------------------------------------------------------------------
# Function : handle_exit
# Purpose  : Trap handler that runs on script exit (normal or error).
#            Logs the final exit status so users can trace unexpected exits.
# -----------------------------------------------------------------------------
handle_exit() {
    local exit_code=$?
    if [[ ${exit_code} -eq 0 ]]; then
        log_info "Session ended successfully."
    else
        log_error "Session ended with exit code ${exit_code}."
    fi
    exit "${exit_code}"
}

# -----------------------------------------------------------------------------
# Function : handle_interrupt
# Purpose  : Trap handler for SIGINT (Ctrl+C) and SIGTERM. Prints a friendly
#            message and exits gracefully with code 130 (standard for SIGINT).
# -----------------------------------------------------------------------------
handle_interrupt() {
    echo ""
    log_warn "Interrupted by user. Exiting gracefully..."
    exit 130
}

# -----------------------------------------------------------------------------
# Function : main
# Purpose  : Orchestrates the full boot sequence and launches the menu loop.
# -----------------------------------------------------------------------------
main() {
    # Ensure required directories exist before anything else
    bootstrap_directories

    # Load libraries first (colors, logger, utils, validators)
    load_libraries

    # Register signal handlers *after* logger is available
    trap handle_exit EXIT
    trap handle_interrupt INT TERM

    # Initialize logging (creates timestamped log file)
    init_logger

    log_info "Starting ${PROJECT_NAME} v${PROJECT_VERSION}"

    # Verify environment is suitable
    preflight_checks

    # Load feature modules
    load_modules

    # Launch the interactive menu (defined in modules/menu.sh)
    show_menu
}

# ---- Entrypoint ------------------------------------------------------------
# Only run main when executed directly (not when sourced by tests)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi