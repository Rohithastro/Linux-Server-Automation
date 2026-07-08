#!/usr/bin/env bash
# =============================================================================
# Project      : Linux Server Automation
# File         : modules/check_system_health.sh
# Description  : Collect a broad system health snapshot (host, kernel, CPU,
#                memory, disks, processes, network, services, firewall,
#                package updates) and render a colored dashboard.
# Compatible   : Ubuntu 24.04 LTS
# Depends on   : lib/colors.sh, lib/logger.sh, lib/utils.sh
# =============================================================================

# -----------------------------------------------------------------------------
# Re-source guard
# -----------------------------------------------------------------------------
if [[ -n "${__CHECK_SYSTEM_HEALTH_SH_LOADED:-}" ]]; then
    return 0
fi
readonly __CHECK_SYSTEM_HEALTH_SH_LOADED=1

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------
for _dep in log_info log_warn log_error log_success log_debug separator \
            pause_screen command_exists show_spinner; do
    if ! declare -F "${_dep}" >/dev/null 2>&1; then
        echo "ERROR: modules/check_system_health.sh requires ${_dep}." >&2
        return 1 2>/dev/null || exit 1
    fi
done
unset _dep

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

# Thresholds for warning / critical highlighting.
readonly _WARN_PCT=75      # yellow at >= 75%
readonly _CRIT_PCT=90      # red    at >= 90%

# Services this module inspects as part of the "running services" row.
readonly _WATCHED_SERVICES=(docker nginx ssh)

# Public-IP probes. Multiple providers give redundancy without a hard
# dependency on any single vendor.
readonly _PUBLIC_IP_PROBES=(
    "https://ifconfig.me"
    "https://api.ipify.org"
    "https://icanhazip.com"
)
readonly _PUBLIC_IP_TIMEOUT=4    # seconds per probe

# Working directory for cached probe outputs. Populated at runtime.
_HEALTH_TMPDIR=""

# Aggregated warnings/criticals accumulated during collection; printed as
# the last section of the dashboard.
_HEALTH_WARNINGS=()
_HEALTH_CRITICALS=()

# =============================================================================
# INTERNAL HELPERS
# =============================================================================

# -----------------------------------------------------------------------------
# Function : _print_section_header
# Purpose  : Top banner for the whole dashboard.
# -----------------------------------------------------------------------------
_print_section_header() {
    echo ""
    separator "="
    printf "%b  >> System Health Dashboard%b\n" "${C_HEADER}" "${C_RESET}"
    separator "="
    echo ""
}

# -----------------------------------------------------------------------------
# Function : _sub_header
# Purpose  : Colored sub-section header used between dashboard groups.
# Args     : $1 - title
# -----------------------------------------------------------------------------
_sub_header() {
    printf "\n%b  %s%b\n" "${C_HEADER}" "$1" "${C_RESET}"
    separator "-"
}

# -----------------------------------------------------------------------------
# Function : _row
# Purpose  : Print a "label : value" row with consistent alignment. Empty
#            values are rendered as "(unknown)" in dim color.
# Args     : $1 - label
#            $2 - value (may be multi-word)
#            $3 - optional color for the value (defaults to none)
# -----------------------------------------------------------------------------
_row() {
    local label="$1"
    local value="${2:-}"
    local color="${3:-}"

    if [[ -z "${value}" ]]; then
        printf "   %-22s : %b(unknown)%b\n" "${label}" "${C_DIM}" "${C_RESET}"
        return
    fi

    if [[ -n "${color}" ]]; then
        printf "   %-22s : %b%s%b\n" "${label}" "${color}" "${value}" "${C_RESET}"
    else
        printf "   %-22s : %s\n" "${label}" "${value}"
    fi
}

# -----------------------------------------------------------------------------
# Function : _color_for_pct
# Purpose  : Pick a color escape based on a percentage vs WARN/CRIT.
# Args     : $1 - integer percentage (0-100)
# Output   : Color variable value on stdout.
# -----------------------------------------------------------------------------
_color_for_pct() {
    local pct="${1:-0}"
    [[ "${pct}" =~ ^[0-9]+$ ]] || { echo "${C_DIM}"; return; }

    if (( pct >= _CRIT_PCT )); then
        echo "${C_ERROR}"
    elif (( pct >= _WARN_PCT )); then
        echo "${C_WARN}"
    else
        echo "${C_SUCCESS}"
    fi
}

# -----------------------------------------------------------------------------
# Function : _record_warning / _record_critical
# Purpose  : Push a message into the aggregated issue lists.
# -----------------------------------------------------------------------------
_record_warning()  { _HEALTH_WARNINGS+=("$1");  log_warn  "$1"; }
_record_critical() { _HEALTH_CRITICALS+=("$1"); log_error "$1"; }

# -----------------------------------------------------------------------------
# Function : _prepare_tmpdir / _cleanup_tmpdir
# Purpose  : Scratch space for cached probe outputs (public IP, updates).
# -----------------------------------------------------------------------------
_prepare_tmpdir() {
    _HEALTH_TMPDIR=$(mktemp -d /tmp/healthcheck.XXXXXX 2>/dev/null || echo "")
    if [[ -n "${_HEALTH_TMPDIR}" ]]; then
        chmod 700 "${_HEALTH_TMPDIR}" 2>/dev/null || true
    fi
}
_cleanup_tmpdir() {
    if [[ -n "${_HEALTH_TMPDIR}" && -d "${_HEALTH_TMPDIR}" ]]; then
        rm -rf "${_HEALTH_TMPDIR}" 2>/dev/null || true
    fi
    _HEALTH_TMPDIR=""
}

# =============================================================================
# COLLECTORS - each _collect_* function is designed to never abort the
# script. If a required command is missing, they return empty/unknown data
# and log a debug line, so the dashboard degrades gracefully.
# =============================================================================

# -----------------------------------------------------------------------------
# Function : _collect_public_ip
# Purpose  : Probe a series of public-IP services (short timeouts) and cache
#            the first successful answer in the temp dir. Runs during the
#            spinner phase because it is the slowest single collector.
# -----------------------------------------------------------------------------
_collect_public_ip() {
    local out="${_HEALTH_TMPDIR:-/tmp}/public_ip"
    : > "${out}" 2>/dev/null || return 0

    command_exists curl || return 0

    local url ip
    for url in "${_PUBLIC_IP_PROBES[@]}"; do
        ip=$(curl -fsS --connect-timeout "${_PUBLIC_IP_TIMEOUT}" \
                       --max-time "${_PUBLIC_IP_TIMEOUT}" \
                       "${url}" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "${ip}" ]]; then
            echo "${ip}" > "${out}"
            return 0
        fi
    done
    return 0
}

# -----------------------------------------------------------------------------
# Function : _collect_apt_updates
# Purpose  : Count packages with an upgrade available via `apt list
#            --upgradable`. Cached to a file to avoid a second slow apt call.
# -----------------------------------------------------------------------------
_collect_apt_updates() {
    local out="${_HEALTH_TMPDIR:-/tmp}/apt_updates"
    echo "0" > "${out}" 2>/dev/null

    command_exists apt || return 0

    local count
    count=$(apt list --upgradable 2>/dev/null | grep -Ec '^[a-z0-9]' || true)
    [[ "${count}" =~ ^[0-9]+$ ]] || count=0
    echo "${count}" > "${out}"
}

# -----------------------------------------------------------------------------
# Function : _prime_slow_collectors
# Purpose  : Run the two slow collectors (public IP + apt update count) in
#            the background so the spinner can cover their latency.
# -----------------------------------------------------------------------------
_prime_slow_collectors() {
    (
        _collect_public_ip
        _collect_apt_updates
    ) &
    show_spinner "$!" "Collecting system information..."
}

# =============================================================================
# SECTION RENDERERS
# =============================================================================

# -----------------------------------------------------------------------------
# Function : _section_host
# Purpose  : Hostname, current user, timestamp, OS, kernel, uptime.
# -----------------------------------------------------------------------------
_section_host() {
    _sub_header "Host"

    local hostname current_user datetime os kernel uptime_str
    hostname=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "")
    current_user=$(id -un 2>/dev/null || echo "")
    datetime=$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "")

    if [[ -r /etc/os-release ]]; then
        os=$(. /etc/os-release && echo "${PRETTY_NAME:-}")
    fi
    kernel=$(uname -sr 2>/dev/null || echo "")

    if command_exists uptime; then
        uptime_str=$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo "")
    fi

    _row "Hostname"   "${hostname}"
    _row "User"       "${current_user}"
    _row "Date/Time"  "${datetime}"
    _row "OS"         "${os}"
    _row "Kernel"     "${kernel}"
    _row "Uptime"     "${uptime_str}"
}

# -----------------------------------------------------------------------------
# Function : _section_cpu
# Purpose  : CPU model + current usage percentage (100 - %idle from top).
# -----------------------------------------------------------------------------
_section_cpu() {
    _sub_header "CPU"

    local cpu_model=""
    if [[ -r /proc/cpuinfo ]]; then
        cpu_model=$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
    fi

    # `top -bn1` prints a one-shot snapshot; the %Cpu line contains an
    # "N.N id" field. We compute usage = 100 - idle, rounded to an int.
    local cpu_usage_pct=0
    if command_exists top; then
        local idle
        idle=$(top -bn1 2>/dev/null \
               | awk -F'[, ]+' '/^%Cpu/ {for (i=1;i<=NF;i++) if ($i=="id") print $(i-1); exit}')
        if [[ "${idle}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            cpu_usage_pct=$(awk -v i="${idle}" 'BEGIN{printf "%d", 100 - i}')
        fi
    fi

    _row "Model"   "${cpu_model}"

    local color
    color=$(_color_for_pct "${cpu_usage_pct}")
    _row "Usage %" "${cpu_usage_pct}%" "${color}"
}

# -----------------------------------------------------------------------------
# Function : _section_memory
# Purpose  : Total / used / free RAM (MiB) and swap. Highlights when the
#            used percentage crosses the critical threshold.
# -----------------------------------------------------------------------------
_section_memory() {
    _sub_header "Memory"

    if ! command_exists free; then
        _row "Memory" ""
        return
    fi

    # `free -m` in MiB. Field indexes: 2=total 3=used 4=free (for the
    # "Mem:" line) and same shape for the "Swap:" line.
    local mem_line swap_line
    mem_line=$(free -m | awk '/^Mem:/  {print $2, $3, $4}')
    swap_line=$(free -m | awk '/^Swap:/ {print $2, $3, $4}')

    local mem_total mem_used mem_free swap_total swap_used swap_free
    read -r mem_total mem_used mem_free  <<< "${mem_line}"
    read -r swap_total swap_used swap_free <<< "${swap_line}"

    local mem_pct=0
    if [[ "${mem_total:-0}" -gt 0 ]]; then
        mem_pct=$(( mem_used * 100 / mem_total ))
    fi
    local color
    color=$(_color_for_pct "${mem_pct}")

    _row "RAM total" "${mem_total} MiB"
    _row "RAM used"  "${mem_used} MiB (${mem_pct}%)" "${color}"
    _row "RAM free"  "${mem_free} MiB"

    if (( mem_pct >= _CRIT_PCT )); then
        _record_critical "Memory usage is critical: ${mem_pct}% (threshold ${_CRIT_PCT}%)."
    elif (( mem_pct >= _WARN_PCT )); then
        _record_warning  "Memory usage is high: ${mem_pct}%."
    fi

    if [[ "${swap_total:-0}" -gt 0 ]]; then
        local swap_pct=$(( swap_used * 100 / swap_total ))
        color=$(_color_for_pct "${swap_pct}")
        _row "Swap used" "${swap_used} / ${swap_total} MiB (${swap_pct}%)" "${color}"
    else
        _row "Swap" "not configured"
    fi
}

# -----------------------------------------------------------------------------
# Function : _section_disk
# Purpose  : Disk usage for every mounted local filesystem. Records a
#            critical issue for the root partition if it crosses threshold.
# -----------------------------------------------------------------------------
_section_disk() {
    _sub_header "Disks"

    if ! command_exists df; then
        _row "Disks" ""
        return
    fi

    # -h : human sizes
    # -x : exclude pseudo-fs types that add clutter
    local df_out
    df_out=$(df -hP -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2)

    printf "   %-30s %-8s %-8s %-8s %-6s %s\n" \
        "Filesystem" "Size" "Used" "Avail" "Use%" "Mount"
    printf "   %s\n" "$(printf '%.0s-' {1..70})"

    local fs size used avail pct mount pct_num color
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        # shellcheck disable=SC2086
        read -r fs size used avail pct mount <<< "${line}"
        pct_num="${pct%\%}"
        [[ "${pct_num}" =~ ^[0-9]+$ ]] || pct_num=0
        color=$(_color_for_pct "${pct_num}")

        printf "   %-30s %-8s %-8s %-8s %b%-6s%b %s\n" \
            "${fs}" "${size}" "${used}" "${avail}" \
            "${color}" "${pct}" "${C_RESET}" \
            "${mount}"

        if (( pct_num >= _CRIT_PCT )); then
            _record_critical "Disk ${mount} is at ${pct_num}% (threshold ${_CRIT_PCT}%)."
        elif (( pct_num >= _WARN_PCT )); then
            _record_warning  "Disk ${mount} is at ${pct_num}%."
        fi
    done <<< "${df_out}"

    # Root partition percentage as an explicit row.
    local root_pct=""
    root_pct=$(df -hP / 2>/dev/null | awk 'NR==2 {print $5}')
    [[ -n "${root_pct}" ]] && _row "Root usage" "${root_pct}"
}

# -----------------------------------------------------------------------------
# Function : _section_processes
# Purpose  : Top 5 by CPU and top 5 by memory. Falls back gracefully if
#            ps output shape changes.
# -----------------------------------------------------------------------------
_section_processes() {
    _sub_header "Top Processes"

    if ! command_exists ps; then
        _row "ps" "not available"
        return
    fi

    printf "\n   %bTop 5 by CPU%b\n" "${C_INFO}" "${C_RESET}"
    printf "   %-7s %-7s %-7s %s\n" "PID" "%CPU" "%MEM" "COMMAND"
    ps -eo pid=,pcpu=,pmem=,comm= --sort=-pcpu 2>/dev/null \
        | head -n 5 \
        | awk '{printf "   %-7s %-7s %-7s %s\n", $1, $2, $3, $4}'

    printf "\n   %bTop 5 by Memory%b\n" "${C_INFO}" "${C_RESET}"
    printf "   %-7s %-7s %-7s %s\n" "PID" "%CPU" "%MEM" "COMMAND"
    ps -eo pid=,pcpu=,pmem=,comm= --sort=-pmem 2>/dev/null \
        | head -n 5 \
        | awk '{printf "   %-7s %-7s %-7s %s\n", $1, $2, $3, $4}'
}

# -----------------------------------------------------------------------------
# Function : _section_load_and_sessions
# Purpose  : Load average + currently logged-in users.
# -----------------------------------------------------------------------------
_section_load_and_sessions() {
    _sub_header "Load & Sessions"

    local load=""
    if [[ -r /proc/loadavg ]]; then
        load=$(awk '{print $1", "$2", "$3}' /proc/loadavg)
    fi
    _row "Load average" "${load}"

    local users_list=""
    if command_exists who; then
        users_list=$(who | awk '{print $1}' | sort -u | paste -sd ',' -)
    fi
    _row "Logged-in users" "${users_list:-none}"
}

# -----------------------------------------------------------------------------
# Function : _section_network
# Purpose  : Local IPv4 (from `hostname -I` or `ip -4`), cached public IP,
#            and a list of non-loopback interfaces.
# -----------------------------------------------------------------------------
_section_network() {
    _sub_header "Network"

    # Local IPv4 (first non-loopback address).
    local local_ip=""
    if command_exists hostname; then
        local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [[ -z "${local_ip}" ]] && command_exists ip; then
        local_ip=$(ip -o -4 addr show scope global 2>/dev/null \
                    | awk '{print $4}' | cut -d/ -f1 | head -n1)
    fi
    _row "Local IPv4" "${local_ip}"

    # Public IP (produced by the background collector).
    local public_ip=""
    if [[ -f "${_HEALTH_TMPDIR}/public_ip" ]]; then
        public_ip=$(<"${_HEALTH_TMPDIR}/public_ip")
    fi
    if [[ -n "${public_ip}" ]]; then
        _row "Public IPv4" "${public_ip}"
    else
        _row "Public IPv4" "(unavailable)"
        _record_warning "Could not determine public IP; internet may be unreachable."
    fi

    # Interfaces.
    if command_exists ip; then
        printf "   %-22s :\n" "Interfaces"
        local iface state addr
        while IFS= read -r line; do
            iface=$(awk -F': ' '{print $2}' <<< "${line}" | awk '{print $1}')
            state=$(awk -F'state ' '{print $2}' <<< "${line}" | awk '{print $1}')
            [[ "${iface}" == "lo" ]] && continue

            addr=$(ip -o -4 addr show dev "${iface}" 2>/dev/null \
                    | awk '{print $4}' | head -n1)

            local color="${C_DIM}"
            [[ "${state}" == "UP" ]] && color="${C_SUCCESS}"

            printf "       %b•%b  %-12s %-6s %s\n" \
                "${color}" "${C_RESET}" \
                "${iface}" "${state}" "${addr:-—}"
        done < <(ip -o link show 2>/dev/null)
    fi
}

# -----------------------------------------------------------------------------
# Function : _section_services
# Purpose  : Report active/enabled state for Docker, Nginx, SSH. Missing
#            units are reported as "not installed" (not counted as errors).
# -----------------------------------------------------------------------------
_section_services() {
    _sub_header "Services"

    if ! command_exists systemctl; then
        _row "systemctl" "not available"
        return
    fi

    local svc state enabled color
    for svc in "${_WATCHED_SERVICES[@]}"; do
        if ! systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 \
             || ! systemctl cat "${svc}.service" >/dev/null 2>&1; then
            _row "${svc}" "not installed"
            continue
        fi

        state=$(systemctl is-active "${svc}" 2>/dev/null || echo "unknown")
        enabled=$(systemctl is-enabled "${svc}" 2>/dev/null || echo "unknown")

        case "${state}" in
            active)     color="${C_SUCCESS}" ;;
            inactive)   color="${C_ERROR}"
                        _record_critical "Service '${svc}' is inactive." ;;
            failed)     color="${C_ERROR}"
                        _record_critical "Service '${svc}' has failed." ;;
            *)          color="${C_WARN}" ;;
        esac

        printf "   %-22s : %b%-10s%b  (enabled: %s)\n" \
            "${svc}" "${color}" "${state}" "${C_RESET}" "${enabled}"
    done
}

# -----------------------------------------------------------------------------
# Function : _section_firewall
# Purpose  : UFW status summary.
# -----------------------------------------------------------------------------
_section_firewall() {
    _sub_header "Firewall"

    if ! command_exists ufw; then
        _row "UFW" "not installed"
        return
    fi

    local status color
    status=$(ufw status 2>/dev/null | awk '/Status:/ {print $2; exit}')
    case "${status,,}" in
        active)   color="${C_SUCCESS}" ;;
        inactive) color="${C_WARN}"
                  _record_warning "UFW is installed but inactive." ;;
        *)        color="${C_DIM}"     ;;
    esac

    _row "UFW status" "${status:-unknown}" "${color}"
}

# -----------------------------------------------------------------------------
# Function : _section_tools
# Purpose  : Report versions of common tooling (Docker, AWS CLI).
# -----------------------------------------------------------------------------
_section_tools() {
    _sub_header "Tools"

    local ver=""
    if command_exists docker; then
        ver=$(docker --version 2>/dev/null)
        _row "Docker" "${ver}"
    else
        _row "Docker" "not installed"
    fi

    if command_exists aws; then
        ver=$(aws --version 2>&1 | awk '{print $1}')
        _row "AWS CLI" "${ver}"
    else
        _row "AWS CLI" "not installed"
    fi
}

# -----------------------------------------------------------------------------
# Function : _section_updates
# Purpose  : Available package updates (from the cached count).
# -----------------------------------------------------------------------------
_section_updates() {
    _sub_header "Package Updates"

    local count=0
    if [[ -f "${_HEALTH_TMPDIR}/apt_updates" ]]; then
        count=$(<"${_HEALTH_TMPDIR}/apt_updates")
    fi
    [[ "${count}" =~ ^[0-9]+$ ]] || count=0

    local color="${C_SUCCESS}"
    if (( count > 0 )); then
        color="${C_WARN}"
        _record_warning "${count} package update(s) available."
    fi
    _row "Available updates" "${count}" "${color}"

    if [[ -f /var/run/reboot-required ]]; then
        _record_warning "System indicates a reboot is required."
        _row "Reboot required" "yes" "${C_WARN}"
    fi
}

# -----------------------------------------------------------------------------
# Function : _section_connectivity
# Purpose  : Quick internet-reachability probe. Uses ping if available;
#            failure is a critical issue for the report but does NOT abort.
# -----------------------------------------------------------------------------
_section_connectivity() {
    _sub_header "Connectivity"

    if ! command_exists ping; then
        _row "Internet" "(ping unavailable)"
        return
    fi

    if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
        _row "Internet" "reachable" "${C_SUCCESS}"
    else
        _row "Internet" "unreachable" "${C_ERROR}"
        _record_critical "No internet connectivity detected."
    fi
}

# -----------------------------------------------------------------------------
# Function : _section_issues
# Purpose  : Final summary of every warning/critical raised during the run.
# -----------------------------------------------------------------------------
_section_issues() {
    _sub_header "Issues Detected"

    if [[ ${#_HEALTH_CRITICALS[@]} -eq 0 && ${#_HEALTH_WARNINGS[@]} -eq 0 ]]; then
        printf "   %b✓  No issues detected.%b\n" "${C_SUCCESS}" "${C_RESET}"
        return
    fi

    local msg
    for msg in "${_HEALTH_CRITICALS[@]}"; do
        printf "   %b✗ CRITICAL%b  %s\n" "${C_ERROR}" "${C_RESET}" "${msg}"
    done
    for msg in "${_HEALTH_WARNINGS[@]}"; do
        printf "   %b! WARNING %b  %s\n" "${C_WARN}"  "${C_RESET}" "${msg}"
    done
}

# =============================================================================
# PUBLIC ENTRY POINT
# =============================================================================

# -----------------------------------------------------------------------------
# Function : check_system_health
# Purpose  : Menu-facing action: build and print the health dashboard.
#            Never aborts on a single failing collector - every section is
#            wrapped in an `|| true` so subsequent sections still render.
# Returns  : 0 always (informational report).
# -----------------------------------------------------------------------------
check_system_health() {
    # Reset accumulators (module can be re-run from the menu).
    _HEALTH_WARNINGS=()
    _HEALTH_CRITICALS=()

    _print_section_header
    _prepare_tmpdir

    # Prime the slow collectors under a spinner so the user sees progress.
    log_info "Gathering system information..."
    _prime_slow_collectors || true

    # Render sections. Each is guarded so one failure never breaks the rest.
    _section_host              || log_debug "host section failed"
    _section_cpu               || log_debug "cpu section failed"
    _section_memory            || log_debug "memory section failed"
    _section_disk              || log_debug "disk section failed"
    _section_load_and_sessions || log_debug "load section failed"
    _section_processes         || log_debug "processes section failed"
    _section_network           || log_debug "network section failed"
    _section_connectivity      || log_debug "connectivity section failed"
    _section_services          || log_debug "services section failed"
    _section_firewall          || log_debug "firewall section failed"
    _section_tools             || log_debug "tools section failed"
    _section_updates           || log_debug "updates section failed"
    _section_issues            || log_debug "issues section failed"

    separator "="
    if [[ ${#_HEALTH_CRITICALS[@]} -gt 0 ]]; then
        log_error "Health check completed with ${#_HEALTH_CRITICALS[@]} critical issue(s)."
    elif [[ ${#_HEALTH_WARNINGS[@]} -gt 0 ]]; then
        log_warn "Health check completed with ${#_HEALTH_WARNINGS[@]} warning(s)."
    else
        log_success "Health check completed - system is healthy."
    fi

    _cleanup_tmpdir
    pause_screen
    return 0
}