#!/usr/bin/env bash
# =============================================================================
# Project      : Linux Server Automation
# File         : lib/validators.sh
# Description  : Input-validation library. Provides pure, side-effect-free
#                predicate functions that return 0 on valid input and 1 on
#                invalid input, and log a descriptive error via logger.sh
#                when validation fails.
# Compatible   : Ubuntu 24.04 LTS
# Depends on   : lib/colors.sh, lib/logger.sh, lib/utils.sh
# Usage        : source lib/validators.sh
#                if validate_username "$name"; then ... fi
# =============================================================================

# -----------------------------------------------------------------------------
# Re-source guard
# -----------------------------------------------------------------------------
if [[ -n "${__VALIDATORS_SH_LOADED:-}" ]]; then
    return 0
fi
readonly __VALIDATORS_SH_LOADED=1

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------
if [[ -z "${C_RESET+x}" ]]; then
    echo "ERROR: lib/validators.sh requires lib/colors.sh to be sourced first." >&2
    return 1 2>/dev/null || exit 1
fi
if ! declare -F log_error >/dev/null 2>&1; then
    echo "ERROR: lib/validators.sh requires lib/logger.sh to be sourced first." >&2
    return 1 2>/dev/null || exit 1
fi

# -----------------------------------------------------------------------------
# Regex constants
# -----------------------------------------------------------------------------
# Kept as readonly constants so patterns can be tuned in a single place and
# re-used by both the validator functions and any callers that need them.
# -----------------------------------------------------------------------------

# Linux username per POSIX/NAME_REGEX (see /etc/adduser.conf, useradd(8)):
#   - starts with a lowercase letter or underscore
#   - contains only [a-z0-9_-]
#   - may end with '$' (rare, reserved for samba machine accounts) - not allowed here
readonly _RE_USERNAME='^[a-z_][a-z0-9_-]{0,31}$'
readonly _MAX_USERNAME_LEN=32

# Debian package name per policy §5.6.7:
#   - length >= 2
#   - lowercase letters, digits, plus, minus, period
#   - must start with an alphanumeric character
readonly _RE_PACKAGE='^[a-z0-9][a-z0-9+.-]+$'

# systemd unit name: alphanumerics plus ':-_.\', optional .service suffix.
# See systemd.unit(5) - "Valid Characters".
readonly _RE_SERVICE='^[a-zA-Z0-9:_.\\-]+(\.service)?$'

# Single IPv4 octet (0-255) without leading zeros beyond a single '0'.
readonly _RE_IPV4_OCTET='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'

# Full hostname per RFC 1123:
#   - labels of 1-63 chars, alphanumerics and hyphens, not starting/ending with hyphen
#   - total length <= 253
readonly _RE_HOSTNAME_LABEL='[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?'
readonly _MAX_HOSTNAME_LEN=253

# =============================================================================
# STRING VALIDATORS
# =============================================================================

# -----------------------------------------------------------------------------
# Function : validate_non_empty
# Purpose  : Ensure a string is not empty and not only whitespace.
# Args     : $1 - value to check
#            $2 - (optional) human-readable field name for error messages
# Returns  : 0 if non-empty, 1 otherwise.
# -----------------------------------------------------------------------------
validate_non_empty() {
    local value="${1-}"
    local field="${2:-value}"

    # Strip leading/trailing whitespace to also reject "   "
    local trimmed="${value#"${value%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

    if [[ -z "${trimmed}" ]]; then
        log_error "Invalid ${field}: value must not be empty."
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Function : validate_yes_no
# Purpose  : Accept common yes/no answers in any case: y, Y, yes, YES,
#            n, N, no, NO.
# Args     : $1 - user input
# Returns  : 0 if input is a recognized yes/no answer, 1 otherwise.
# -----------------------------------------------------------------------------
validate_yes_no() {
    local input="${1-}"

    if ! validate_non_empty "${input}" "yes/no answer"; then
        return 1
    fi

    case "${input,,}" in
        y|yes|n|no) return 0 ;;
        *)
            log_error "Invalid answer: '${input}'. Expected: y, yes, n, or no."
            return 1
            ;;
    esac
}

# =============================================================================
# IDENTIFIER VALIDATORS
# =============================================================================

# -----------------------------------------------------------------------------
# Function : validate_username
# Purpose  : Validate a Linux username against POSIX/useradd rules.
#            - Starts with a lowercase letter or underscore
#            - Contains only lowercase letters, digits, underscores, hyphens
#            - Length 1-32 characters
# Args     : $1 - candidate username
# Returns  : 0 if valid, 1 otherwise.
# -----------------------------------------------------------------------------
validate_username() {
    local name="${1-}"

    if ! validate_non_empty "${name}" "username"; then
        return 1
    fi

    if (( ${#name} > _MAX_USERNAME_LEN )); then
        log_error "Invalid username: '${name}' exceeds ${_MAX_USERNAME_LEN} characters."
        return 1
    fi

    if [[ ! "${name}" =~ ${_RE_USERNAME} ]]; then
        log_error "Invalid username: '${name}'. Must start with a lowercase letter or underscore and contain only [a-z0-9_-]."
        return 1
    fi

    # Reject reserved names that would collide with system accounts or PATH.
    case "${name}" in
        root|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|gnats|nobody|systemd-*|_apt)
            log_error "Invalid username: '${name}' is reserved for the system."
            return 1
            ;;
    esac

    return 0
}

# -----------------------------------------------------------------------------
# Function : validate_package_name
# Purpose  : Validate an apt/dpkg package name per Debian Policy §5.6.7.
# Args     : $1 - candidate package name
# Returns  : 0 if valid, 1 otherwise.
# -----------------------------------------------------------------------------
validate_package_name() {
    local pkg="${1-}"

    if ! validate_non_empty "${pkg}" "package name"; then
        return 1
    fi

    if (( ${#pkg} < 2 )); then
        log_error "Invalid package name: '${pkg}'. Must be at least 2 characters."
        return 1
    fi

    if [[ ! "${pkg}" =~ ${_RE_PACKAGE} ]]; then
        log_error "Invalid package name: '${pkg}'. Allowed: lowercase letters, digits, '+', '-', '.'; must start alphanumeric."
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Function : validate_service_name
# Purpose  : Validate a systemd service unit name.
# Args     : $1 - candidate service name (with or without .service suffix)
# Returns  : 0 if valid, 1 otherwise.
# -----------------------------------------------------------------------------
validate_service_name() {
    local svc="${1-}"

    if ! validate_non_empty "${svc}" "service name"; then
        return 1
    fi

    # systemd caps unit names at 255 bytes (including suffix).
    if (( ${#svc} > 255 )); then
        log_error "Invalid service name: '${svc}' exceeds 255 characters."
        return 1
    fi

    if [[ ! "${svc}" =~ ${_RE_SERVICE} ]]; then
        log_error "Invalid service name: '${svc}'. Allowed characters: [A-Za-z0-9:_.-]."
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Function : validate_hostname
# Purpose  : Validate a hostname per RFC 1123.
#            - Total length <= 253
#            - Labels of 1-63 chars, alphanumerics and hyphens
#            - Labels must not start or end with a hyphen
# Args     : $1 - candidate hostname
# Returns  : 0 if valid, 1 otherwise.
# -----------------------------------------------------------------------------
validate_hostname() {
    local host="${1-}"

    if ! validate_non_empty "${host}" "hostname"; then
        return 1
    fi

    if (( ${#host} > _MAX_HOSTNAME_LEN )); then
        log_error "Invalid hostname: '${host}' exceeds ${_MAX_HOSTNAME_LEN} characters."
        return 1
    fi

    # Reject a trailing dot for simplicity (FQDN root label).
    if [[ "${host}" == *. ]]; then
        log_error "Invalid hostname: '${host}' must not end with a dot."
        return 1
    fi

    # Build a full-hostname regex from the single-label pattern.
    local re="^${_RE_HOSTNAME_LABEL}(\.${_RE_HOSTNAME_LABEL})*$"
    if [[ ! "${host}" =~ ${re} ]]; then
        log_error "Invalid hostname: '${host}'. Must comply with RFC 1123."
        return 1
    fi

    # Purely numeric hostnames are ambiguous with IPs - reject them.
    if [[ "${host}" =~ ^[0-9.]+$ ]]; then
        log_error "Invalid hostname: '${host}' looks like an IP address."
        return 1
    fi

    return 0
}

# =============================================================================
# NETWORK VALIDATORS
# =============================================================================

# -----------------------------------------------------------------------------
# Function : validate_port
# Purpose  : Validate a TCP/UDP port number in the range 1-65535.
# Args     : $1 - candidate port
# Returns  : 0 if valid, 1 otherwise.
# -----------------------------------------------------------------------------
validate_port() {
    local port="${1-}"

    if ! validate_non_empty "${port}" "port"; then
        return 1
    fi

    # Must be all digits (rejects negatives, decimals, hex, whitespace).
    if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
        log_error "Invalid port: '${port}'. Must be a positive integer."
        return 1
    fi

    # Numeric range check (bash treats a leading zero as octal in $(( )),
    # so force base 10 with 10#).
    if (( 10#${port} < 1 || 10#${port} > 65535 )); then
        log_error "Invalid port: '${port}'. Must be between 1 and 65535."
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Function : validate_ipv4
# Purpose  : Validate a dotted-quad IPv4 address. Each octet must be 0-255
#            with no leading zeros (except the literal '0' itself).
# Args     : $1 - candidate address
# Returns  : 0 if valid, 1 otherwise.
# -----------------------------------------------------------------------------
validate_ipv4() {
    local ip="${1-}"

    if ! validate_non_empty "${ip}" "IPv4 address"; then
        return 1
    fi

    local re="^${_RE_IPV4_OCTET}(\.${_RE_IPV4_OCTET}){3}$"
    if [[ ! "${ip}" =~ ${re} ]]; then
        log_error "Invalid IPv4 address: '${ip}'. Expected format A.B.C.D with each octet 0-255."
        return 1
    fi

    return 0
}

# =============================================================================
# FILESYSTEM VALIDATORS
# =============================================================================

# -----------------------------------------------------------------------------
# Function : validate_directory
# Purpose  : Verify that a path exists and is a directory.
# Args     : $1 - candidate path
# Returns  : 0 if it is an existing directory, 1 otherwise.
# -----------------------------------------------------------------------------
validate_directory() {
    local path="${1-}"

    if ! validate_non_empty "${path}" "directory path"; then
        return 1
    fi

    if [[ ! -e "${path}" ]]; then
        log_error "Directory does not exist: '${path}'."
        return 1
    fi

    if [[ ! -d "${path}" ]]; then
        log_error "Path is not a directory: '${path}'."
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Function : validate_file
# Purpose  : Verify that a path exists and is a regular file.
# Args     : $1 - candidate path
# Returns  : 0 if it is an existing regular file, 1 otherwise.
# -----------------------------------------------------------------------------
validate_file() {
    local path="${1-}"

    if ! validate_non_empty "${path}" "file path"; then
        return 1
    fi

    if [[ ! -e "${path}" ]]; then
        log_error "File does not exist: '${path}'."
        return 1
    fi

    if [[ ! -f "${path}" ]]; then
        log_error "Path is not a regular file: '${path}'."
        return 1
    fi

    return 0
}