#!/usr/bin/env bash
# =============================================================================
# Project      : Linux Server Automation
# File         : lib/utils.sh
# Description  : General-purpose helper library. Provides environment checks
#                (root, OS, network), presence checks (command, package,
#                service), user-interaction helpers (confirm, pause), and
#                cosmetic utilities (banner, separator, spinner).
# Compatible   : Ubuntu 24.04 LTS
# Depends on   : lib/colors.sh, lib/logger.sh
# Usage        : source lib/utils.sh
# =============================================================================

# -----------------------------------------------------------------------------
# Re-source guard
# -----------------------------------------------------------------------------
# Prevent multiple sourcing which would try to redeclare readonly variables.
# -----------------------------------------------------------------------------
if [[ -n "${__UTILS_SH_LOADED:-}" ]]; then
    return 0
fi
readonly __UTILS_SH_LOADED=1

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------
# colors.sh must define C_RESET; logger.sh must define log_info.
# -----------------------------------------------------------------------------
if [[ -z "${C_RESET+x}" ]]; then
    echo "ERROR: lib/utils.sh requires lib/colors.sh to be sourced first." >&2
    return 1 2>/dev/null || exit 1
fi
if ! declare -F log_info >/dev/null 2>&1; then
    echo "ERROR: lib/utils.sh requires lib/logger.sh to be sourced first." >&2
    return 1 2>/dev/null || exit 1
fi

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
readonly REQUIRED_OS_ID="ubuntu"
readonly REQUIRED_OS_VERSION="24.04"

# Hosts used for network connectivity probes. Multiple hosts provide
# redundancy in case one is blocked or down.
readonly _NETWORK_PROBE_HOSTS=(
    "1.1.1.1"          # Cloudflare DNS
    "8.8.8.8"          # Google DNS
    "9.9.9.9"          # Quad9 DNS
)
readonly _NETWORK_PROBE_TIMEOUT=5   # seconds per host

# -----------------------------------------------------------------------------
# Shared apt constants
# -----------------------------------------------------------------------------
# Single source of truth for the environment and options every apt-using
# module needs. Previously each module declared these as `readonly` at
# file scope, which crashed with "readonly variable: _APT_ENV" as soon as
# setup.sh sourced more than one apt-using module into the same shell.
#
# Defined here so every module inherits the same values automatically once
# lib/utils.sh is loaded.
#
#   _APT_ENV  : environment prefix that suppresses interactive prompts.
#   _APT_OPTS : safe non-interactive install/upgrade flags. The
#               Dpkg::Options entries tell dpkg to keep the currently
#               installed config file whenever a package ships a new one,
#               which is the correct default for scripted runs.
# -----------------------------------------------------------------------------
readonly _APT_ENV=("DEBIAN_FRONTEND=noninteractive")
readonly _APT_OPTS=(
    "-y"
    "-o" "Dpkg::Options::=--force-confdef"
    "-o" "Dpkg::Options::=--force-confold"
)

# =============================================================================
# 1. ENVIRONMENT CHECKS
# =============================================================================

# -----------------------------------------------------------------------------
# Function : check_root
# Purpose  : Verify the current process runs with EUID 0 (root). Required
#            because apt, ufw, systemctl and user management calls need it.
# Exits    : 1 if not running as root.
# -----------------------------------------------------------------------------
check_root() {
    if [[ ${EUID} -ne 0 ]]; then
        log_error "This script must be run as root. Try: sudo $0"
        exit 1
    fi
    log_debug "Root privilege check passed (EUID=${EUID})."
}

# -----------------------------------------------------------------------------
# Function : check_ubuntu_version
# Purpose  : Validate that the host is Ubuntu 24.04 LTS by inspecting
#            /etc/os-release. Warns (does not exit) on newer minor versions
#            so the script remains forward-compatible.
# Exits    : 1 if /etc/os-release is missing or OS is not Ubuntu 24.04.
# -----------------------------------------------------------------------------
check_ubuntu_version() {
    local os_release="/etc/os-release"

    if [[ ! -r "${os_release}" ]]; then
        log_error "Cannot read ${os_release}. Unable to identify OS."
        exit 1
    fi

    # Source os-release in a subshell to avoid polluting our namespace,
    # then echo the values we need.
    local os_id os_version os_pretty
    os_id=$(. "${os_release}" && echo "${ID:-}")
    os_version=$(. "${os_release}" && echo "${VERSION_ID:-}")
    os_pretty=$(. "${os_release}" && echo "${PRETTY_NAME:-unknown}")

    if [[ "${os_id,,}" != "${REQUIRED_OS_ID}" ]]; then
        log_error "Unsupported OS: ${os_pretty}. This script requires Ubuntu."
        exit 1
    fi

    if [[ "${os_version}" != "${REQUIRED_OS_VERSION}" ]]; then
        log_warn "Detected Ubuntu ${os_version}. Target is ${REQUIRED_OS_VERSION} LTS."
        log_warn "The script may work but has not been validated on this version."
    else
        log_debug "OS check passed: ${os_pretty}"
    fi
}

# -----------------------------------------------------------------------------
# Function : check_network
# Purpose  : Verify internet connectivity by pinging a small set of highly
#            available public DNS resolvers. Success requires only one host
#            to respond within the timeout.
# Exits    : 1 if no probe host is reachable.
# -----------------------------------------------------------------------------
check_network() {
    log_info "Checking network connectivity..."

    if ! command_exists ping; then
        log_warn "'ping' not available; skipping strict network check."
        return 0
    fi

    local host
    for host in "${_NETWORK_PROBE_HOSTS[@]}"; do
        if ping -c 1 -W "${_NETWORK_PROBE_TIMEOUT}" "${host}" >/dev/null 2>&1; then
            log_success "Network reachable (via ${host})."
            return 0
        fi
        log_debug "No response from ${host}."
    done

    log_error "No internet connectivity detected. Aborting."
    exit 1
}

# =============================================================================
# 2. PRESENCE CHECKS
# =============================================================================

# -----------------------------------------------------------------------------
# Function : command_exists
# Purpose  : Return 0 if the given command is found in PATH, 1 otherwise.
#            Intended for use in `if` statements; does not print anything.
# Args     : $1 - command name
# -----------------------------------------------------------------------------
command_exists() {
    local cmd="${1:-}"
    [[ -n "${cmd}" ]] || return 1
    command -v "${cmd}" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Function : service_exists
# Purpose  : Return 0 if a systemd unit with the given name is known to the
#            system (loaded or on-disk), 1 otherwise.
# Args     : $1 - unit name (e.g. "nginx" or "nginx.service")
# -----------------------------------------------------------------------------
service_exists() {
    local unit="${1:-}"
    [[ -n "${unit}" ]] || return 1

    if ! command_exists systemctl; then
        return 1
    fi

    # `list-unit-files` returns unit files installed on disk; grep matches
    # exact unit name at start of line to avoid partial matches.
    systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null \
        | awk '{print $1}' \
        | grep -qE "^${unit}(\.service)?$"
}

# -----------------------------------------------------------------------------
# Function : package_installed
# Purpose  : Check whether an apt/dpkg package is installed (status = "ii").
# Args     : $1 - package name
# Returns  : 0 if installed, 1 otherwise.
# -----------------------------------------------------------------------------
package_installed() {
    local pkg="${1:-}"
    [[ -n "${pkg}" ]] || return 1

    if ! command_exists dpkg-query; then
        return 1
    fi

    local status
    status=$(dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null || true)
    [[ "${status}" == "install ok installed" ]]
}

# -----------------------------------------------------------------------------
# Function : require_command
# Purpose  : Ensure a command is available; log an error and exit if not.
#            Use for hard dependencies inside modules.
# Args     : $1 - command name
#            $2 - (optional) apt package that provides it (for the hint)
# Exits    : 127 if the command is missing.
# -----------------------------------------------------------------------------
require_command() {
    local cmd="${1:-}"
    local pkg="${2:-}"

    if [[ -z "${cmd}" ]]; then
        log_error "require_command called without an argument."
        exit 2
    fi

    if ! command_exists "${cmd}"; then
        if [[ -n "${pkg}" ]]; then
            log_error "Required command '${cmd}' not found. Install with: apt-get install -y ${pkg}"
        else
            log_error "Required command '${cmd}' not found in PATH."
        fi
        exit 127
    fi
    log_debug "Required command available: ${cmd}"
}

# =============================================================================
# 3. USER INTERACTION
# =============================================================================

# -----------------------------------------------------------------------------
# Function : confirm_action
# Purpose  : Ask the user for a Yes/No confirmation. Default is No.
# Args     : $1 - (optional) prompt message. Defaults to "Continue?".
# Returns  : 0 on Yes, 1 on No / anything else / empty.
# -----------------------------------------------------------------------------
confirm_action() {
    local prompt="${1:-Continue?}"
    local reply=""

    # If stdin is not a terminal, we cannot ask - assume No for safety.
    if [[ ! -t 0 ]]; then
        log_warn "Non-interactive shell detected; refusing action: ${prompt}"
        return 1
    fi

    # -r : do not interpret backslashes
    # -p : print the prompt on the same line
    printf "%b%s (y/N): %b" "${C_PROMPT}" "${prompt}" "${C_RESET}"
    read -r reply

    case "${reply,,}" in
        y|yes) return 0 ;;
        *)     return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# Function : pause_screen
# Purpose  : Halt execution until the user presses Enter. Used after menu
#            actions so the user can read the output before the menu redraws.
# -----------------------------------------------------------------------------
pause_screen() {
    # Skip in non-interactive contexts (e.g. CI, piped input)
    if [[ ! -t 0 ]]; then
        return 0
    fi
    printf "\n%bPress [Enter] to continue...%b" "${C_DIM}" "${C_RESET}"
    read -r _
    echo ""
}

# =============================================================================
# 4. COSMETIC HELPERS
# =============================================================================

# -----------------------------------------------------------------------------
# Function : separator
# Purpose  : Print a horizontal rule that matches the terminal width (capped
#            at 80 columns for readability).
# Args     : $1 - (optional) character to repeat. Defaults to "─".
# -----------------------------------------------------------------------------
separator() {
    local char="${1:-─}"
    local width=80

    # Detect actual terminal width when possible
    if command_exists tput && [[ -t 1 ]]; then
        local cols
        cols=$(tput cols 2>/dev/null || echo 80)
        [[ ${cols} -lt ${width} ]] && width=${cols}
    fi

    local line
    # Build a string of `width` characters. printf + tr is portable and fast.
    line=$(printf '%*s' "${width}" '' | tr ' ' "${char}")
    printf "%b%s%b\n" "${C_DIM}" "${line}" "${C_RESET}"
}

# -----------------------------------------------------------------------------
# Function : print_banner
# Purpose  : Print a professional colored banner at the top of the menu.
# Args     : $1 - (optional) title. Defaults to $PROJECT_NAME.
# -----------------------------------------------------------------------------
print_banner() {
    local title="${1:-${PROJECT_NAME:-Linux Server Automation}}"
    local version="${PROJECT_VERSION:-1.0.0}"

    echo ""
    separator "="
    printf "%b" "${C_HEADER}"
    cat <<'BANNER'
   _     _                    ____                             
  | |   (_)_ __  _   ___  __ / ___|  ___ _ ____   _____ _ __   
  | |   | | '_ \| | | \ \/ / \___ \ / _ \ '__\ \ / / _ \ '__|  
  | |___| | | | | |_| |>  <   ___) |  __/ |   \ V /  __/ |     
  |_____|_|_| |_|\__,_/_/\_\ |____/ \___|_|    \_/ \___|_|     
                     A u t o m a t i o n   T o o l k i t       
BANNER
    printf "%b" "${C_RESET}"
    printf "  %b%s%b  %bv%s%b\n" \
        "${C_BOLD}" "${title}" "${C_RESET}" \
        "${C_DIM}"  "${version}" "${C_RESET}"
    separator "="
    echo ""
}

# -----------------------------------------------------------------------------
# Function : show_spinner
# Purpose  : Display a rotating spinner while a background PID is running.
#            The caller launches a command in the background, captures its
#            PID with $!, then calls: show_spinner "$!" "message".
# Args     : $1 - PID to watch
#            $2 - (optional) label displayed next to the spinner
# Returns  : Exit status of the watched process.
# -----------------------------------------------------------------------------
show_spinner() {
    local pid="${1:-}"
    local label="${2:-Working...}"

    if [[ -z "${pid}" ]]; then
        log_error "show_spinner requires a PID argument."
        return 2
    fi

    # If the PID isn't valid, don't spin - just wait and return.
    if ! kill -0 "${pid}" 2>/dev/null; then
        wait "${pid}" 2>/dev/null || return $?
        return 0
    fi

    # In non-interactive mode just wait silently (no cursor games).
    if [[ ! -t 1 ]]; then
        wait "${pid}"
        return $?
    fi

    local -a frames=('|' '/' '-' '\')
    local i=0
    local delay=0.1

    # Hide cursor for a cleaner effect; ensure it is restored on exit.
    tput civis 2>/dev/null || true
    # shellcheck disable=SC2064
    trap "tput cnorm 2>/dev/null || true" RETURN

    # Loop until the background process terminates
    while kill -0 "${pid}" 2>/dev/null; do
        printf "\r  %b[%s]%b %s" \
            "${C_INFO}" "${frames[i]}" "${C_RESET}" "${label}"
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep "${delay}"
    done

    # Reap the process and capture its exit status
    local rc=0
    wait "${pid}" 2>/dev/null || rc=$?

    # Clear the spinner line
    printf "\r\033[K"
    tput cnorm 2>/dev/null || true

    return "${rc}"
}