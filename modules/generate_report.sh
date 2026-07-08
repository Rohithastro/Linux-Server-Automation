#!/usr/bin/env bash
# =============================================================================
# Project      : Linux Server Automation
# File         : modules/generate_report.sh
# Description  : Produce a comprehensive post-run report of the system:
#                general info, hardware, network, installed software,
#                service state, security posture, package inventory, and a
#                bottom-line summary. Writes both a human-readable .txt
#                report and a machine-readable .json report to reports/.
# Compatible   : Ubuntu 24.04 LTS
# Depends on   : lib/colors.sh, lib/logger.sh, lib/utils.sh
# =============================================================================

# -----------------------------------------------------------------------------
# Re-source guard
# -----------------------------------------------------------------------------
if [[ -n "${__GENERATE_REPORT_SH_LOADED:-}" ]]; then
    return 0
fi
readonly __GENERATE_REPORT_SH_LOADED=1

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------
for _dep in log_info log_warn log_error log_success log_debug separator \
            pause_screen command_exists show_spinner; do
    if ! declare -F "${_dep}" >/dev/null 2>&1; then
        echo "ERROR: modules/generate_report.sh requires ${_dep}." >&2
        return 1 2>/dev/null || exit 1
    fi
done
unset _dep

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

# Services this report tracks under "SERVICE STATUS".
readonly _REPORT_SERVICES=(docker nginx ssh ufw)

# Software this report tracks under "INSTALLED SOFTWARE". Each entry is
# "<label>|<command>|<version-cmd>". A "-" for command means "detect via
# dpkg only".
readonly _REPORT_SOFTWARE=(
    "Git|git|git --version"
    "Curl|curl|curl --version"
    "Wget|wget|wget --version"
    "Vim|vim|vim --version"
    "Docker|docker|docker --version"
    "Docker Compose|docker|docker compose version"
    "Nginx|nginx|nginx -v"
    "AWS CLI|aws|aws --version"
    "OpenSSH|sshd|-"
    "UFW|ufw|ufw --version"
)

# Public-IP probes with short timeouts.
# Working state (populated by _reset_state).
_REPORT_TS=""
_REPORT_TXT=""
_REPORT_JSON=""
_REPORT_TMPDIR=""

# Bucketed findings (populated during collection, rendered in the summary).
_INSTALLED_COMPONENTS=()
_RUNNING_SERVICES=()
_MISSING_COMPONENTS=()
_REPORT_WARNINGS=()
_REPORT_ERRORS=()

# JSON key/value pairs collected across sections. We deliberately keep
# JSON assembly simple (string map -> flat object per section) so we don't
# need jq at runtime.
declare -A _JSON_GENERAL=()
declare -A _JSON_SYSTEM=()
declare -A _JSON_NETWORK=()
declare -A _JSON_SOFTWARE=()
declare -A _JSON_SERVICES=()
declare -A _JSON_SECURITY=()
declare -A _JSON_PACKAGES=()

# =============================================================================
# INTERNAL HELPERS
# =============================================================================

# -----------------------------------------------------------------------------
# Function : _reset_state
# Purpose  : Clear all module-scoped accumulators. Called at the top of
#            every invocation so re-runs from the menu are idempotent.
# -----------------------------------------------------------------------------
_reset_state() {
    _REPORT_TS=""
    _REPORT_TXT=""
    _REPORT_JSON=""
    _REPORT_TMPDIR=""

    _INSTALLED_COMPONENTS=()
    _RUNNING_SERVICES=()
    _MISSING_COMPONENTS=()
    _REPORT_WARNINGS=()
    _REPORT_ERRORS=()

    _JSON_GENERAL=()
    _JSON_SYSTEM=()
    _JSON_NETWORK=()
    _JSON_SOFTWARE=()
    _JSON_SERVICES=()
    _JSON_SECURITY=()
    _JSON_PACKAGES=()
}

# -----------------------------------------------------------------------------
# Function : _print_section_header
# Purpose  : Colored terminal header for the module.
# -----------------------------------------------------------------------------
_print_section_header() {
    echo ""
    separator "="
    printf "%b  >> Generate Installation Report%b\n" \
        "${C_HEADER}" "${C_RESET}"
    separator "="
    echo ""
}

# -----------------------------------------------------------------------------
# Function : _prepare_paths
# Purpose  : Ensure the reports directory exists and compute the paths of
#            the .txt and .json reports for this session.
# Returns  : 0 on success, non-zero if the directory cannot be created.
# -----------------------------------------------------------------------------
_prepare_paths() {
    local reports_dir="${REPORT_DIR:-./reports}"

    if [[ ! -d "${reports_dir}" ]]; then
        if ! mkdir -p "${reports_dir}" 2>/dev/null; then
            log_error "Failed to create report directory: ${reports_dir}"
            return 1
        fi
    fi
    if [[ ! -w "${reports_dir}" ]]; then
        log_error "Report directory not writable: ${reports_dir}"
        return 1
    fi

    _REPORT_TS=$(date '+%Y%m%d_%H%M%S')
    _REPORT_TXT="${reports_dir}/system_report_${_REPORT_TS}.txt"
    _REPORT_JSON="${reports_dir}/system_report_${_REPORT_TS}.json"

    if ! _REPORT_TMPDIR=$(mktemp -d /tmp/report.XXXXXX 2>/dev/null); then
        log_error "Failed to create temporary directory."
        return 1
    fi
    chmod 700 "${_REPORT_TMPDIR}" 2>/dev/null || true

    return 0
}

# -----------------------------------------------------------------------------
# Function : _cleanup_tmpdir
# Purpose  : Remove the scratch directory. Safe to call multiple times.
# -----------------------------------------------------------------------------
_cleanup_tmpdir() {
    if [[ -n "${_REPORT_TMPDIR}" && -d "${_REPORT_TMPDIR}" ]]; then
        rm -rf "${_REPORT_TMPDIR}" 2>/dev/null || true
    fi
    _REPORT_TMPDIR=""
}

# -----------------------------------------------------------------------------
# Function : _txt_header
# Purpose  : Write a "====" banner line + title to the .txt report.
# Args     : $1 - section title
# -----------------------------------------------------------------------------
_txt_header() {
    local title="$1"
    {
        echo ""
        echo "===================================================="
        echo "${title}"
        echo "===================================================="
    } >> "${_REPORT_TXT}"
}

# -----------------------------------------------------------------------------
# Function : _txt_row
# Purpose  : Append a "label : value" row to the .txt report. Empty values
#            are recorded as "(unknown)" for consistency.
# Args     : $1 - label
#            $2 - value
# -----------------------------------------------------------------------------
_txt_row() {
    local label="$1"
    local value="${2-}"
    [[ -z "${value}" ]] && value="(unknown)"
    printf "  %-24s : %s\n" "${label}" "${value}" >> "${_REPORT_TXT}"
}

# -----------------------------------------------------------------------------
# Function : _txt_line
# Purpose  : Append a free-form line to the .txt report.
# -----------------------------------------------------------------------------
_txt_line() {
    printf "  %s\n" "$*" >> "${_REPORT_TXT}"
}

# -----------------------------------------------------------------------------
# Function : _json_escape
# Purpose  : Escape a string so it can be embedded in a JSON string literal.
#            Handles backslashes, double quotes, control chars, and newlines.
# Args     : $1 - raw string
# Output   : Escaped string on stdout (WITHOUT surrounding quotes).
# -----------------------------------------------------------------------------
_json_escape() {
    local s="${1-}"
    # Order matters: escape backslashes first.
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\n'/\\n}"
    printf '%s' "${s}"
}

# -----------------------------------------------------------------------------
# Function : _json_dump_map
# Purpose  : Serialise an associative array as a JSON object body. Keys are
#            emitted in sorted order for deterministic output.
# Args     : $1 - name of the associative array (nameref)
# Output   : Comma-separated `"key":"value"` pairs on stdout, no braces.
# -----------------------------------------------------------------------------
_json_dump_map() {
    local -n _map="$1"
    local -a keys=()
    local k v first=1

    # Collect and sort keys.
    for k in "${!_map[@]}"; do keys+=("${k}"); done
    IFS=$'\n' keys=($(printf '%s\n' "${keys[@]}" | sort))
    unset IFS

    for k in "${keys[@]}"; do
        v="${_map[${k}]}"
        if [[ ${first} -eq 1 ]]; then
            first=0
        else
            printf ','
        fi
        printf '"%s":"%s"' "$(_json_escape "${k}")" "$(_json_escape "${v}")"
    done
}

# -----------------------------------------------------------------------------
# Function : _json_dump_array
# Purpose  : Serialise a bash array as a JSON array of strings.
# Args     : $1 - name of the array (nameref)
# Output   : `["a","b",...]` on stdout.
# -----------------------------------------------------------------------------
_json_dump_array() {
    local -n _arr="$1"
    local i first=1 item
    printf '['
    for item in "${_arr[@]}"; do
        if [[ ${first} -eq 1 ]]; then
            first=0
        else
            printf ','
        fi
        printf '"%s"' "$(_json_escape "${item}")"
    done
    printf ']'
}

# -----------------------------------------------------------------------------
# Function : _run_or_empty
# Purpose  : Execute a command tolerantly - returns its first line of
#            output on stdout, or empty string if the command is missing
#            or fails. Never aborts.
# Args     : $@ - command + args
# -----------------------------------------------------------------------------
_run_or_empty() {
    local cmd="${1:-}"
    [[ -n "${cmd}" ]] || return 0
    command_exists "${cmd}" || return 0
    "$@" 2>&1 | awk 'NF { print; exit }' || true
}

# =============================================================================
# COLLECTORS
# =============================================================================

# -----------------------------------------------------------------------------
# Function : _collect_public_ip
# Purpose  : Fetch the public IP via one of the probe endpoints. Cached to
#            the temp dir so multiple sections can reuse the same value.
# -----------------------------------------------------------------------------
_collect_public_ip() {
    local out="${_REPORT_TMPDIR}/public_ip"
    : > "${out}" 2>/dev/null || return 0
    command_exists curl || return 0

    local url ip
    for url in "${_PUBLIC_IP_PROBES[@]}"; do
        ip=$(curl -fsS --connect-timeout "${_PUBLIC_IP_TIMEOUT}" \
                       --max-time "${_PUBLIC_IP_TIMEOUT}" \
                       "${url}" 2>/dev/null | tr -d '[:space:]')
        [[ -n "${ip}" ]] && { echo "${ip}" > "${out}"; return 0; }
    done
}

# -----------------------------------------------------------------------------
# Function : _collect_apt_state
# Purpose  : Grab installed-package count + upgradable-package count from
#            apt and cache them in the temp dir.
# -----------------------------------------------------------------------------
_collect_apt_state() {
    local installed=0 upgradable=0

    if command_exists dpkg-query; then
        installed=$(dpkg-query -f '${binary:Package}\n' -W 2>/dev/null | wc -l)
    fi
    if command_exists apt; then
        upgradable=$(apt list --upgradable 2>/dev/null \
                     | grep -Ec '^[a-z0-9]' || true)
    fi
    [[ "${installed}"  =~ ^[0-9]+$ ]] || installed=0
    [[ "${upgradable}" =~ ^[0-9]+$ ]] || upgradable=0

    echo "${installed}"  > "${_REPORT_TMPDIR}/apt_installed"
    echo "${upgradable}" > "${_REPORT_TMPDIR}/apt_upgradable"
}

# -----------------------------------------------------------------------------
# Function : _prime_slow_collectors
# Purpose  : Kick off the slow collectors in the background while the
#            spinner covers the wait.
# -----------------------------------------------------------------------------
_prime_slow_collectors() {
    (
        _collect_public_ip
        _collect_apt_state
    ) &
    show_spinner "$!" "Collecting system data for report..."
}

# =============================================================================
# SECTION WRITERS - each fills both TXT and JSON. Wrapped by the caller in
# `|| true` so a single failure never aborts the whole report.
# =============================================================================

# -----------------------------------------------------------------------------
# Function : _section_general
# Purpose  : GENERAL INFORMATION section.
# -----------------------------------------------------------------------------
_section_general() {
    _txt_header "GENERAL INFORMATION"

    local project="${PROJECT_NAME:-Linux Server Automation}"
    local version="${PROJECT_VERSION:-unknown}"
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S %Z')
    local hostname current_user os kernel uptime_str

    hostname=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "")
    current_user=$(id -un 2>/dev/null || echo "")
    if [[ -r /etc/os-release ]]; then
        os=$(. /etc/os-release && echo "${PRETTY_NAME:-}")
    fi
    kernel=$(uname -sr 2>/dev/null || echo "")
    uptime_str=$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo "")

    _txt_row "Project Name"    "${project}"
    _txt_row "Project Version" "${version}"
    _txt_row "Generated At"    "${now}"
    _txt_row "Hostname"        "${hostname}"
    _txt_row "Current User"    "${current_user}"
    _txt_row "Operating System" "${os}"
    _txt_row "Kernel Version"  "${kernel}"
    _txt_row "Uptime"          "${uptime_str}"

    _JSON_GENERAL["project_name"]="${project}"
    _JSON_GENERAL["project_version"]="${version}"
    _JSON_GENERAL["generated_at"]="${now}"
    _JSON_GENERAL["hostname"]="${hostname}"
    _JSON_GENERAL["current_user"]="${current_user}"
    _JSON_GENERAL["operating_system"]="${os}"
    _JSON_GENERAL["kernel_version"]="${kernel}"
    _JSON_GENERAL["uptime"]="${uptime_str}"
}

# -----------------------------------------------------------------------------
# Function : _section_system
# Purpose  : SYSTEM INFORMATION section.
# -----------------------------------------------------------------------------
_section_system() {
    _txt_header "SYSTEM INFORMATION"

    local cpu_model="" cpu_pct=0
    if [[ -r /proc/cpuinfo ]]; then
        cpu_model=$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo)
    fi
    if command_exists top; then
        local idle
        idle=$(top -bn1 2>/dev/null \
               | awk -F'[, ]+' '/^%Cpu/ {for (i=1;i<=NF;i++) if ($i=="id") print $(i-1); exit}')
        if [[ "${idle}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            cpu_pct=$(awk -v i="${idle}" 'BEGIN{printf "%d", 100 - i}')
        fi
    fi

    local mem_total="" mem_used="" mem_free="" swap_used="" swap_total=""
    if command_exists free; then
        read -r mem_total mem_used mem_free \
            <<< "$(free -m | awk '/^Mem:/  {print $2, $3, $4}')"
        read -r swap_total swap_used _ \
            <<< "$(free -m | awk '/^Swap:/ {print $2, $3, $4}')"
    fi

    local root_pct=""
    if command_exists df; then
        root_pct=$(df -hP / 2>/dev/null | awk 'NR==2 {print $5}')
    fi

    _txt_row "CPU Model"            "${cpu_model}"
    _txt_row "CPU Usage (%)"        "${cpu_pct}"
    _txt_row "Memory Total (MiB)"   "${mem_total}"
    _txt_row "Memory Used  (MiB)"   "${mem_used}"
    _txt_row "Memory Free  (MiB)"   "${mem_free}"
    _txt_row "Swap Used/Total (MiB)" "${swap_used:-0}/${swap_total:-0}"
    _txt_row "Root Usage"           "${root_pct}"

    _txt_line ""
    _txt_line "Disk usage (all mounts):"
    if command_exists df; then
        df -hP -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null \
            | tail -n +2 \
            | while IFS= read -r line; do
                _txt_line "  ${line}"
            done
    fi

    _JSON_SYSTEM["cpu_model"]="${cpu_model}"
    _JSON_SYSTEM["cpu_usage_pct"]="${cpu_pct}"
    _JSON_SYSTEM["memory_total_mib"]="${mem_total:-0}"
    _JSON_SYSTEM["memory_used_mib"]="${mem_used:-0}"
    _JSON_SYSTEM["memory_free_mib"]="${mem_free:-0}"
    _JSON_SYSTEM["swap_used_mib"]="${swap_used:-0}"
    _JSON_SYSTEM["swap_total_mib"]="${swap_total:-0}"
    _JSON_SYSTEM["root_usage"]="${root_pct}"

    # Feed the summary buckets.
    if [[ "${mem_total:-0}" -gt 0 ]]; then
        local pct=$(( mem_used * 100 / mem_total ))
        (( pct >= 90 )) && _REPORT_ERRORS+=("Memory usage critical: ${pct}%")
        (( pct >= 75 && pct < 90 )) && _REPORT_WARNINGS+=("Memory usage high: ${pct}%")
    fi
    if [[ -n "${root_pct}" ]]; then
        local rp="${root_pct%\%}"
        [[ "${rp}" =~ ^[0-9]+$ ]] || rp=0
        (( rp >= 90 )) && _REPORT_ERRORS+=("Root filesystem at ${rp}%")
        (( rp >= 75 && rp < 90 )) && _REPORT_WARNINGS+=("Root filesystem at ${rp}%")
    fi
}

# -----------------------------------------------------------------------------
# Function : _section_network
# Purpose  : NETWORK INFORMATION section.
# -----------------------------------------------------------------------------
_section_network() {
    _txt_header "NETWORK INFORMATION"

    local hostname local_ip public_ip="" gateway="" dns=""

    hostname=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "")
    if command_exists hostname; then
        local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [[ -z "${local_ip}" ]] && command_exists ip; then
        local_ip=$(ip -o -4 addr show scope global 2>/dev/null \
                    | awk '{print $4}' | cut -d/ -f1 | head -n1)
    fi

    if [[ -f "${_REPORT_TMPDIR}/public_ip" ]]; then
        public_ip=$(<"${_REPORT_TMPDIR}/public_ip")
    fi

    if command_exists ip; then
        gateway=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
    fi

    # DNS servers: prefer resolvectl, then /etc/resolv.conf.
    if command_exists resolvectl; then
        dns=$(resolvectl status 2>/dev/null \
               | awk '/DNS Servers/ {sub(/.*DNS Servers: */, ""); print; exit}')
    fi
    if [[ -z "${dns}" && -r /etc/resolv.conf ]]; then
        dns=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf \
              | paste -sd ',' -)
    fi

    _txt_row "Hostname"        "${hostname}"
    _txt_row "Local IP"        "${local_ip}"
    _txt_row "Public IP"       "${public_ip}"
    _txt_row "Default Gateway" "${gateway}"
    _txt_row "DNS Servers"     "${dns}"

    _txt_line ""
    _txt_line "Active interfaces:"
    if command_exists ip; then
        while IFS= read -r line; do
            local iface state addr
            iface=$(awk -F': ' '{print $2}' <<< "${line}" | awk '{print $1}')
            state=$(awk -F'state ' '{print $2}' <<< "${line}" | awk '{print $1}')
            [[ "${iface}" == "lo" ]] && continue
            addr=$(ip -o -4 addr show dev "${iface}" 2>/dev/null \
                    | awk '{print $4}' | head -n1)
            _txt_line "  ${iface}  ${state}  ${addr:-—}"
        done < <(ip -o link show 2>/dev/null)
    fi

    _JSON_NETWORK["hostname"]="${hostname}"
    _JSON_NETWORK["local_ip"]="${local_ip}"
    _JSON_NETWORK["public_ip"]="${public_ip}"
    _JSON_NETWORK["default_gateway"]="${gateway}"
    _JSON_NETWORK["dns_servers"]="${dns}"

    [[ -z "${public_ip}" ]] && _REPORT_WARNINGS+=("Public IP could not be determined.")
}

# -----------------------------------------------------------------------------
# Function : _software_version
# Purpose  : Return a single-line version string for one software entry,
#            or the string "not installed" if not present.
# Args     : $1 - probe command name
#            $2 - version command (may be "-" to skip and use dpkg only)
#            $3 - package name for dpkg fallback (optional)
# -----------------------------------------------------------------------------
_software_version() {
    local cmd="$1"
    local vcmd="$2"
    local pkg="${3:-}"
    local ver=""

    if command_exists "${cmd}"; then
        if [[ "${vcmd}" != "-" ]]; then
            # shellcheck disable=SC2086
            ver=$(${vcmd} 2>&1 | awk 'NF { print; exit }')
        fi
    fi

    if [[ -z "${ver}" && -n "${pkg}" ]] && command_exists dpkg-query; then
        ver=$(dpkg-query -W -f='${Version}' "${pkg}" 2>/dev/null || true)
    fi

    if [[ -z "${ver}" ]] && ! command_exists "${cmd}"; then
        ver="not installed"
    fi

    echo "${ver:-installed}"
}

# -----------------------------------------------------------------------------
# Function : _section_software
# Purpose  : INSTALLED SOFTWARE section. Populates installed/missing buckets.
# -----------------------------------------------------------------------------
_section_software() {
    _txt_header "INSTALLED SOFTWARE"

    local entry label cmd vcmd ver key
    for entry in "${_REPORT_SOFTWARE[@]}"; do
        IFS='|' read -r label cmd vcmd <<< "${entry}"
        ver=$(_software_version "${cmd}" "${vcmd}")
        _txt_row "${label}" "${ver}"

        key=$(tr '[:upper:] ' '[:lower:]_' <<< "${label}")
        _JSON_SOFTWARE["${key}"]="${ver}"

        if [[ "${ver}" == "not installed" ]]; then
            _MISSING_COMPONENTS+=("${label}")
        else
            _INSTALLED_COMPONENTS+=("${label}")
        fi
    done
}

# -----------------------------------------------------------------------------
# Function : _section_services
# Purpose  : SERVICE STATUS section - ACTIVE / INACTIVE / NOT INSTALLED.
# -----------------------------------------------------------------------------
_section_services() {
    _txt_header "SERVICE STATUS"

    local svc state status
    for svc in "${_REPORT_SERVICES[@]}"; do
        if ! command_exists systemctl \
           || ! systemctl cat "${svc}.service" >/dev/null 2>&1; then
            status="NOT INSTALLED"
            _MISSING_COMPONENTS+=("${svc} (service)")
        else
            state=$(systemctl is-active "${svc}" 2>/dev/null || echo "unknown")
            case "${state}" in
                active)     status="ACTIVE"
                            _RUNNING_SERVICES+=("${svc}") ;;
                inactive)   status="INACTIVE"
                            _REPORT_WARNINGS+=("Service '${svc}' is inactive.") ;;
                failed)     status="INACTIVE (failed)"
                            _REPORT_ERRORS+=("Service '${svc}' has failed.") ;;
                *)          status="${state^^}" ;;
            esac
        fi
        _txt_row "${svc}" "${status}"
        _JSON_SERVICES["${svc}"]="${status}"
    done
}

# -----------------------------------------------------------------------------
# Function : _section_security
# Purpose  : SECURITY INFORMATION section.
# -----------------------------------------------------------------------------
_section_security() {
    _txt_header "SECURITY INFORMATION"

    local fw_status="not installed"
    if command_exists ufw; then
        fw_status=$(ufw status 2>/dev/null | awk '/Status:/ {print $2; exit}')
        [[ -z "${fw_status}" ]] && fw_status="unknown"
    fi
    _txt_row "Firewall Status" "${fw_status}"

    _txt_line ""
    _txt_line "Open ports (listening):"
    local open_ports=""
    if command_exists ss; then
        open_ports=$(ss -Htlnp 2>/dev/null | awk '{print $4}' | sort -u)
    elif command_exists netstat; then
        open_ports=$(netstat -tlnp 2>/dev/null | awk '/LISTEN/ {print $4}' | sort -u)
    fi
    if [[ -n "${open_ports}" ]]; then
        while IFS= read -r p; do _txt_line "  ${p}"; done <<< "${open_ports}"
    else
        _txt_line "  (none detected)"
    fi

    local users_list=""
    if command_exists who; then
        users_list=$(who | awk '{print $1}' | sort -u | paste -sd ',' -)
    fi
    _txt_row "Logged-in Users" "${users_list:-none}"

    local last_login=""
    if command_exists last; then
        last_login=$(last -n 1 -F 2>/dev/null | head -n 1)
    fi
    _txt_row "Last Login" "${last_login}"

    _JSON_SECURITY["firewall_status"]="${fw_status}"
    _JSON_SECURITY["open_ports"]="$(echo "${open_ports}" | paste -sd ',' -)"
    _JSON_SECURITY["logged_in_users"]="${users_list}"
    _JSON_SECURITY["last_login"]="${last_login}"

    if [[ "${fw_status,,}" == "inactive" ]]; then
        _REPORT_WARNINGS+=("Firewall (UFW) is inactive.")
    fi
}

# -----------------------------------------------------------------------------
# Function : _section_packages
# Purpose  : PACKAGE INFORMATION section.
# -----------------------------------------------------------------------------
_section_packages() {
    _txt_header "PACKAGE INFORMATION"

    local installed=0 upgradable=0 last_update="(unknown)"
    if [[ -f "${_REPORT_TMPDIR}/apt_installed" ]]; then
        installed=$(<"${_REPORT_TMPDIR}/apt_installed")
    fi
    if [[ -f "${_REPORT_TMPDIR}/apt_upgradable" ]]; then
        upgradable=$(<"${_REPORT_TMPDIR}/apt_upgradable")
    fi

    # Last apt update time: mtime of the apt lists directory is a good proxy.
    if [[ -d /var/lib/apt/lists ]]; then
        last_update=$(date -r /var/lib/apt/lists '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "(unknown)")
    fi

    _txt_row "Installed Packages" "${installed}"
    _txt_row "Available Updates"  "${upgradable}"
    _txt_row "Last apt Update"    "${last_update}"

    _JSON_PACKAGES["installed_packages"]="${installed}"
    _JSON_PACKAGES["available_updates"]="${upgradable}"
    _JSON_PACKAGES["last_update"]="${last_update}"

    (( upgradable > 0 )) && \
        _REPORT_WARNINGS+=("${upgradable} package update(s) available.")

    if [[ -f /var/run/reboot-required ]]; then
        _REPORT_WARNINGS+=("System indicates a reboot is required.")
    fi
}

# -----------------------------------------------------------------------------
# Function : _section_summary
# Purpose  : Bottom-line SUMMARY section rendered in both TXT and terminal.
# -----------------------------------------------------------------------------
_section_summary() {
    _txt_header "SUMMARY"

    _txt_line "Installed Components (${#_INSTALLED_COMPONENTS[@]}):"
    local item
    if [[ ${#_INSTALLED_COMPONENTS[@]} -eq 0 ]]; then
        _txt_line "  (none)"
    else
        for item in "${_INSTALLED_COMPONENTS[@]}"; do
            _txt_line "  ✔ ${item}"
        done
    fi

    _txt_line ""
    _txt_line "Running Services (${#_RUNNING_SERVICES[@]}):"
    if [[ ${#_RUNNING_SERVICES[@]} -eq 0 ]]; then
        _txt_line "  (none)"
    else
        for item in "${_RUNNING_SERVICES[@]}"; do
            _txt_line "  ✔ ${item}"
        done
    fi

    _txt_line ""
    _txt_line "Missing Components (${#_MISSING_COMPONENTS[@]}):"
    if [[ ${#_MISSING_COMPONENTS[@]} -eq 0 ]]; then
        _txt_line "  (none)"
    else
        for item in "${_MISSING_COMPONENTS[@]}"; do
            _txt_line "  ✖ ${item}"
        done
    fi

    _txt_line ""
    _txt_line "Warnings (${#_REPORT_WARNINGS[@]}):"
    if [[ ${#_REPORT_WARNINGS[@]} -eq 0 ]]; then
        _txt_line "  (none)"
    else
        for item in "${_REPORT_WARNINGS[@]}"; do
            _txt_line "  ! ${item}"
        done
    fi

    _txt_line ""
    _txt_line "Errors (${#_REPORT_ERRORS[@]}):"
    if [[ ${#_REPORT_ERRORS[@]} -eq 0 ]]; then
        _txt_line "  (none)"
    else
        for item in "${_REPORT_ERRORS[@]}"; do
            _txt_line "  ✖ ${item}"
        done
    fi
}

# -----------------------------------------------------------------------------
# Function : _write_json_report
# Purpose  : Assemble and write the JSON report. No jq required.
# -----------------------------------------------------------------------------
_write_json_report() {
    {
        printf '{'
        printf '"general":{';   _json_dump_map _JSON_GENERAL;  printf '},'
        printf '"system":{';    _json_dump_map _JSON_SYSTEM;   printf '},'
        printf '"network":{';   _json_dump_map _JSON_NETWORK;  printf '},'
        printf '"software":{';  _json_dump_map _JSON_SOFTWARE; printf '},'
        printf '"services":{';  _json_dump_map _JSON_SERVICES; printf '},'
        printf '"security":{';  _json_dump_map _JSON_SECURITY; printf '},'
        printf '"packages":{';  _json_dump_map _JSON_PACKAGES; printf '},'
        printf '"summary":{'
        printf '"installed_components":';  _json_dump_array _INSTALLED_COMPONENTS
        printf ',"running_services":';     _json_dump_array _RUNNING_SERVICES
        printf ',"missing_components":';   _json_dump_array _MISSING_COMPONENTS
        printf ',"warnings":';             _json_dump_array _REPORT_WARNINGS
        printf ',"errors":';               _json_dump_array _REPORT_ERRORS
        printf '}}'
        printf '\n'
    } > "${_REPORT_JSON}"
}

# -----------------------------------------------------------------------------
# Function : _print_summary_to_terminal
# Purpose  : Show a colored, condensed version of the summary on stdout.
# -----------------------------------------------------------------------------
_print_summary_to_terminal() {
    echo ""
    printf "%b  Report Summary%b\n" "${C_HEADER}" "${C_RESET}"
    separator "-"

    printf "   %b✔ Installed components%b : %d\n" \
        "${C_SUCCESS}" "${C_RESET}" "${#_INSTALLED_COMPONENTS[@]}"
    printf "   %b✔ Running services%b     : %d\n" \
        "${C_SUCCESS}" "${C_RESET}" "${#_RUNNING_SERVICES[@]}"
    printf "   %b✖ Missing components%b   : %d\n" \
        "${C_ERROR}"   "${C_RESET}" "${#_MISSING_COMPONENTS[@]}"
    printf "   %b! Warnings%b             : %d\n" \
        "${C_WARN}"    "${C_RESET}" "${#_REPORT_WARNINGS[@]}"
    printf "   %b✖ Errors%b               : %d\n" \
        "${C_ERROR}"   "${C_RESET}" "${#_REPORT_ERRORS[@]}"

    separator "-"
    printf "   %bText report %b : %s\n" "${C_INFO}" "${C_RESET}" "${_REPORT_TXT}"
    printf "   %bJSON report %b : %s\n" "${C_INFO}" "${C_RESET}" "${_REPORT_JSON}"
    separator "-"
}

# =============================================================================
# PUBLIC ENTRY POINT
# =============================================================================

# -----------------------------------------------------------------------------
# Function : generate_report
# Purpose  : Menu-facing action: produce a complete .txt + .json system
#            report in the reports/ directory.
# Returns  :
#   0   on success
#   2   on unmet prerequisite (cannot create reports directory)
#   3   on failure to write the report files
# -----------------------------------------------------------------------------
generate_report() {
    _print_section_header
    _reset_state

    # ---- Step 1: prepare filesystem paths ---------------------------------
    if ! _prepare_paths; then
        pause_screen
        return 2
    fi

    # Ensure temp dir is cleaned up on every exit path.
    # shellcheck disable=SC2064
    trap "_cleanup_tmpdir" RETURN

    log_info "Text report : ${_REPORT_TXT}"
    log_info "JSON report : ${_REPORT_JSON}"

    # ---- Step 2: prime slow collectors (public IP, apt) -------------------
    _prime_slow_collectors || true

    # ---- Step 3: initialize the txt report --------------------------------
    if ! : > "${_REPORT_TXT}"; then
        log_error "Failed to open text report for writing: ${_REPORT_TXT}"
        pause_screen
        return 3
    fi
    chmod 640 "${_REPORT_TXT}" 2>/dev/null || true

    {
        echo "===================================================="
        echo "  ${PROJECT_NAME:-Linux Server Automation} - System Report"
        echo "  Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "===================================================="
    } > "${_REPORT_TXT}"

    # ---- Step 4: fill each section (guarded) ------------------------------
    _section_general   || log_debug "general section failed"
    _section_system    || log_debug "system section failed"
    _section_network   || log_debug "network section failed"
    _section_software  || log_debug "software section failed"
    _section_services  || log_debug "services section failed"
    _section_security  || log_debug "security section failed"
    _section_packages  || log_debug "packages section failed"
    _section_summary   || log_debug "summary section failed"

    # ---- Step 5: JSON report ----------------------------------------------
    if ! _write_json_report; then
        log_error "Failed to write JSON report: ${_REPORT_JSON}"
        pause_screen
        return 3
    fi
    chmod 640 "${_REPORT_JSON}" 2>/dev/null || true

    # ---- Step 6: terminal summary + outcome -------------------------------
    _print_summary_to_terminal

    if [[ ${#_REPORT_ERRORS[@]} -gt 0 ]]; then
        log_error "Report generated with ${#_REPORT_ERRORS[@]} error(s)."
    elif [[ ${#_REPORT_WARNINGS[@]} -gt 0 ]]; then
        log_warn  "Report generated with ${#_REPORT_WARNINGS[@]} warning(s)."
    else
        log_success "Report generated successfully."
    fi

    pause_screen
    return 0
}
