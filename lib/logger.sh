#!/usr/bin/env bash
# =============================================================================
# Project      : Linux Server Automation
# File         : lib/logger.sh
# Description  : Structured logging library. Provides leveled log functions
#                that print colorized messages to the terminal and append
#                plain-text (uncolored) entries to a timestamped log file.
# Compatible   : Ubuntu 24.04 LTS
# Depends on   : lib/colors.sh, ${LOG_DIR} (exported by setup.sh)
# Usage        : source lib/logger.sh
#                init_logger
#                log_info  "System updated"
#                log_warn  "Disk space is low"
#                log_error "Failed to install package"
#                log_debug "Variable x=42"
# =============================================================================

# -----------------------------------------------------------------------------
# Re-source guard
# -----------------------------------------------------------------------------
# Skip re-loading if this file was already sourced in the current shell.
# -----------------------------------------------------------------------------
if [[ -n "${__LOGGER_SH_LOADED:-}" ]]; then
    return 0
fi
readonly __LOGGER_SH_LOADED=1

# -----------------------------------------------------------------------------
# Dependency check
# -----------------------------------------------------------------------------
# Ensure colors.sh has been sourced first (it defines C_* constants).
# We check a semantic alias so both real and no-color modes are accepted.
# -----------------------------------------------------------------------------
if [[ -z "${C_RESET+x}" ]]; then
    echo "ERROR: lib/logger.sh requires lib/colors.sh to be sourced first." >&2
    return 1 2>/dev/null || exit 1
fi

# -----------------------------------------------------------------------------
# Log level configuration
# -----------------------------------------------------------------------------
# Numeric severities let log_* functions decide whether to emit output based
# on the currently configured minimum level (LOG_LEVEL).
#
# Levels:
#   10 = DEBUG
#   20 = INFO   (default)
#   30 = WARN
#   40 = ERROR
#
# Override at runtime:
#   LOG_LEVEL=DEBUG ./setup.sh
# -----------------------------------------------------------------------------
readonly LOG_LEVEL_DEBUG=10
readonly LOG_LEVEL_INFO=20
readonly LOG_LEVEL_WARN=30
readonly LOG_LEVEL_ERROR=40

# Resolve LOG_LEVEL (string) to a numeric threshold. Defaults to INFO.
_resolve_log_level() {
    local level_str="${LOG_LEVEL:-INFO}"
    case "${level_str^^}" in
        DEBUG) echo "${LOG_LEVEL_DEBUG}" ;;
        INFO)  echo "${LOG_LEVEL_INFO}"  ;;
        WARN|WARNING) echo "${LOG_LEVEL_WARN}" ;;
        ERROR) echo "${LOG_LEVEL_ERROR}" ;;
        *)     echo "${LOG_LEVEL_INFO}"  ;;
    esac
}

# Populated by init_logger; used by _should_log
_LOG_LEVEL_NUM=""

# Path to the active log file (set by init_logger)
LOG_FILE=""
export LOG_FILE

# -----------------------------------------------------------------------------
# Function : _timestamp
# Purpose  : Return the current time in ISO-8601-like format for log entries.
# Output   : YYYY-MM-DD HH:MM:SS
# -----------------------------------------------------------------------------
_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# -----------------------------------------------------------------------------
# Function : _file_timestamp
# Purpose  : Return a filesystem-safe timestamp for log file names.
# Output   : YYYYMMDD_HHMMSS
# -----------------------------------------------------------------------------
_file_timestamp() {
    date '+%Y%m%d_%H%M%S'
}

# -----------------------------------------------------------------------------
# Function : _should_log
# Purpose  : Determine if a message at the given numeric level should be
#            emitted based on the configured LOG_LEVEL threshold.
# Args     : $1 - numeric level of the incoming message
# Returns  : 0 if message should be logged, 1 otherwise.
# -----------------------------------------------------------------------------
_should_log() {
    local msg_level="$1"
    [[ ${msg_level} -ge ${_LOG_LEVEL_NUM} ]]
}

# -----------------------------------------------------------------------------
# Function : init_logger
# Purpose  : Initialize the logger. Creates the log directory if needed,
#            creates a timestamped log file, and writes a session header.
#            Must be called once before any log_* function.
# Args     : None (uses LOG_DIR from environment; falls back to ./logs)
# Exits    : 1 if the log file cannot be created.
# -----------------------------------------------------------------------------
init_logger() {
    # Resolve numeric log level from LOG_LEVEL env var
    _LOG_LEVEL_NUM="$(_resolve_log_level)"

    # Fall back to ./logs if LOG_DIR was not exported
    local log_dir="${LOG_DIR:-./logs}"

    # Create the log directory if missing
    if [[ ! -d "${log_dir}" ]]; then
        if ! mkdir -p "${log_dir}" 2>/dev/null; then
            echo "ERROR: Cannot create log directory: ${log_dir}" >&2
            exit 1
        fi
    fi

    # Ensure the log directory is writable
    if [[ ! -w "${log_dir}" ]]; then
        echo "ERROR: Log directory is not writable: ${log_dir}" >&2
        exit 1
    fi

    # Compose the timestamped log file name
    LOG_FILE="${log_dir}/session_$(_file_timestamp).log"

    # Create the file and verify it can be written to
    if ! touch "${LOG_FILE}" 2>/dev/null; then
        echo "ERROR: Cannot create log file: ${LOG_FILE}" >&2
        exit 1
    fi

    # Restrict permissions (logs may contain hostnames, users, etc.)
    chmod 640 "${LOG_FILE}" 2>/dev/null || true

    # Write a session banner to the log
    {
        echo "============================================================"
        echo " Session Start : $(_timestamp)"
        echo " Project       : ${PROJECT_NAME:-Linux Server Automation}"
        echo " Version       : ${PROJECT_VERSION:-unknown}"
        echo " Host          : $(hostname -f 2>/dev/null || hostname)"
        echo " User          : $(id -un)"
        echo " Log Level     : ${LOG_LEVEL:-INFO}"
        echo " Log File      : ${LOG_FILE}"
        echo "============================================================"
    } >> "${LOG_FILE}"
}

# -----------------------------------------------------------------------------
# Function : _write_log
# Purpose  : Core log emitter. Prints a colored message to the terminal
#            and appends a plain-text entry to the log file.
# Args     : $1 - level label (e.g. "INFO", "WARN")
#            $2 - color escape sequence (from colors.sh)
#            $3 - message text
#            $4 - output stream: "stdout" or "stderr"
# -----------------------------------------------------------------------------
_write_log() {
    local level="$1"
    local color="$2"
    local message="$3"
    local stream="${4:-stdout}"
    local ts
    ts="$(_timestamp)"

    # Terminal output (colored). Pad level to 5 chars for alignment.
    local pretty
    printf -v pretty "%b[%s]%b %b%-5s%b %s" \
        "${C_DIM}" "${ts}" "${C_RESET}" \
        "${color}" "${level}" "${C_RESET}" \
        "${message}"

    if [[ "${stream}" == "stderr" ]]; then
        echo -e "${pretty}" >&2
    else
        echo -e "${pretty}"
    fi

    # File output (plain text, no escape sequences). Guard against being
    # called before init_logger by checking LOG_FILE is set and writable.
    if [[ -n "${LOG_FILE}" && -w "${LOG_FILE}" ]]; then
        printf '[%s] %-5s %s\n' "${ts}" "${level}" "${message}" >> "${LOG_FILE}"
    fi
}

# -----------------------------------------------------------------------------
# Function : log_debug
# Purpose  : Emit a DEBUG-level message (only when LOG_LEVEL=DEBUG).
# Args     : $* - message text
# -----------------------------------------------------------------------------
log_debug() {
    _should_log "${LOG_LEVEL_DEBUG}" || return 0
    _write_log "DEBUG" "${C_DEBUG}" "$*" "stdout"
}

# -----------------------------------------------------------------------------
# Function : log_info
# Purpose  : Emit an INFO-level message. Used for normal progress updates.
# Args     : $* - message text
# -----------------------------------------------------------------------------
log_info() {
    _should_log "${LOG_LEVEL_INFO}" || return 0
    _write_log "INFO" "${C_INFO}" "$*" "stdout"
}

# -----------------------------------------------------------------------------
# Function : log_warn
# Purpose  : Emit a WARN-level message. Used for recoverable issues.
# Args     : $* - message text
# -----------------------------------------------------------------------------
log_warn() {
    _should_log "${LOG_LEVEL_WARN}" || return 0
    _write_log "WARN" "${C_WARN}" "$*" "stderr"
}

# -----------------------------------------------------------------------------
# Function : log_error
# Purpose  : Emit an ERROR-level message. Used for failures. Does not exit;
#            callers decide whether the error is fatal.
# Args     : $* - message text
# -----------------------------------------------------------------------------
log_error() {
    _should_log "${LOG_LEVEL_ERROR}" || return 0
    _write_log "ERROR" "${C_ERROR}" "$*" "stderr"
}

# -----------------------------------------------------------------------------
# Function : log_success
# Purpose  : Emit a success confirmation. Semantically an INFO-level event
#            but rendered in green for visibility.
# Args     : $* - message text
# -----------------------------------------------------------------------------
log_success() {
    _should_log "${LOG_LEVEL_INFO}" || return 0
    _write_log "OK"   "${C_SUCCESS}" "$*" "stdout"
}