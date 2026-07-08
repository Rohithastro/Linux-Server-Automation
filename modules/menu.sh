#!/usr/bin/env bash
# =============================================================================
# Project      : Linux Server Automation
# File         : modules/menu.sh
# Description  : Interactive top-level menu. Renders a banner + numbered list
#                of automation actions, validates the user's choice, and
#                dispatches to the appropriate module function.
# Compatible   : Ubuntu 24.04 LTS
# Depends on   : lib/colors.sh, lib/logger.sh, lib/utils.sh, lib/validators.sh
#                and every modules/*.sh that defines a dispatched action.
# =============================================================================

# -----------------------------------------------------------------------------
# Re-source guard
# -----------------------------------------------------------------------------
if [[ -n "${__MENU_SH_LOADED:-}" ]]; then
    return 0
fi
readonly __MENU_SH_LOADED=1

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------
if [[ -z "${C_RESET+x}" ]]; then
    echo "ERROR: modules/menu.sh requires lib/colors.sh to be sourced first." >&2
    return 1 2>/dev/null || exit 1
fi
for _dep in log_info print_banner separator pause_screen validate_non_empty; do
    if ! declare -F "${_dep}" >/dev/null 2>&1; then
        echo "ERROR: modules/menu.sh requires ${_dep} (missing lib)." >&2
        return 1 2>/dev/null || exit 1
    fi
done
unset _dep

# -----------------------------------------------------------------------------
# Menu configuration
# -----------------------------------------------------------------------------
# The menu is table-driven: two parallel arrays hold the labels shown to
# the user and the module functions to invoke. Adding a new menu item is
# a one-line change in each array (in matching order).
#
# The index 0 slot is reserved for "Exit" and handled specially in the
# dispatcher, so it does not appear in these arrays.
# -----------------------------------------------------------------------------
readonly _MENU_LABELS=(
    "Update System"
    "Upgrade Packages"
    "Install Developer Tools"
    "Install Docker"
    "Install Nginx"
    "Install AWS CLI"
    "Configure Firewall"
    "Create Developer User"
    "Enable SSH"
    "Check System Health"
    "Generate Installation Report"
)

readonly _MENU_ACTIONS=(
    "update_system"
    "upgrade_packages"
    "install_devtools"
    "install_docker"
    "install_nginx"
    "install_awscli"
    "configure_firewall"
    "create_developer_user"
    "enable_ssh"
    "check_system_health"
    "generate_report"
)

# Highest valid choice (excluding "0" for Exit). Computed once for validation.
readonly _MENU_MAX=${#_MENU_LABELS[@]}

# =============================================================================
# INTERNAL HELPERS
# =============================================================================

# -----------------------------------------------------------------------------
# Function : _clear_screen
# Purpose  : Clear the terminal before redrawing the menu. Falls back to a
#            handful of newlines if 'clear' is unavailable or output is not
#            a TTY (e.g. logging to a file).
# -----------------------------------------------------------------------------
_clear_screen() {
    if [[ -t 1 ]] && command_exists clear; then
        clear
    else
        printf '\n%.0s' {1..3}
    fi
}

# -----------------------------------------------------------------------------
# Function : _render_menu
# Purpose  : Print the banner, title bar, and numbered action list.
# -----------------------------------------------------------------------------
_render_menu() {
    _clear_screen
    print_banner

    printf "%b" "${C_HEADER}"
    printf "  %s\n" "================================================"
    printf "            Linux Server Automation Toolkit\n"
    printf "  %s\n"   "================================================"
    printf "%b\n" "${C_RESET}"

    # Numbered items, colored index for scannability.
    local i label
    for (( i = 0; i < _MENU_MAX; i++ )); do
        label="${_MENU_LABELS[i]}"
        printf "   %b%2d)%b  %s\n" \
            "${C_B_CYAN}" "$(( i + 1 ))" "${C_RESET}" \
            "${label}"
    done

    # Exit entry, styled in red so it stands out.
    printf "\n   %b%2d)%b  %bExit%b\n\n" \
        "${C_B_RED}" "0" "${C_RESET}" \
        "${C_B_RED}" "${C_RESET}"

    separator "="
}

# -----------------------------------------------------------------------------
# Function : _prompt_choice
# Purpose  : Read a menu selection from the user. Sets the global _CHOICE.
# Returns  : 0 on any read (validation happens in _dispatch).
#            1 on EOF (Ctrl+D) so the caller can exit cleanly.
# -----------------------------------------------------------------------------
_prompt_choice() {
    _CHOICE=""
    printf "%b  Select an option [0-%d]: %b" \
        "${C_PROMPT}" "${_MENU_MAX}" "${C_RESET}"

    # `read` returns non-zero on EOF; propagate that so the loop can exit.
    if ! read -r _CHOICE; then
        echo ""
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Function : _is_valid_choice
# Purpose  : Predicate that returns 0 iff the given string is an integer in
#            the range [0.._MENU_MAX].
# Args     : $1 - candidate input
# -----------------------------------------------------------------------------
_is_valid_choice() {
    local value="${1-}"
    [[ "${value}" =~ ^[0-9]+$ ]] || return 1
    (( 10#${value} >= 0 && 10#${value} <= _MENU_MAX ))
}

# -----------------------------------------------------------------------------
# Function : _run_action
# Purpose  : Invoke a module function safely. Reports success/failure via
#            the logger without allowing the action's non-zero exit to
#            terminate the outer script (which uses `set -e`).
# Args     : $1 - function name to call
#            $2 - human-readable label for messages
# -----------------------------------------------------------------------------
_run_action() {
    local func="$1"
    local label="$2"
    local rc=0

    if ! declare -F "${func}" >/dev/null 2>&1; then
        log_error "Action '${label}' is not available (missing function: ${func})."
        return 1
    fi

    separator
    log_info "Starting: ${label}"
    separator

    # Temporarily relax `errexit` so a failing action returns to the menu
    # instead of killing the whole session.
    set +e
    "${func}"
    rc=$?
    set -e

    separator
    if [[ ${rc} -eq 0 ]]; then
        log_success "Completed: ${label}"
    else
        log_error "Failed: ${label} (exit code ${rc})"
    fi
    separator

    return "${rc}"
}

# -----------------------------------------------------------------------------
# Function : _dispatch
# Purpose  : Map a validated numeric choice to the corresponding action
#            (or exit). Called once per menu iteration.
# Args     : $1 - validated numeric choice
# Returns  : 0 normally; the special value 255 signals "user chose Exit".
# -----------------------------------------------------------------------------
_dispatch() {
    local choice="$1"

    # 0 = Exit sentinel
    if (( choice == 0 )); then
        return 255
    fi

    local idx=$(( choice - 1 ))
    _run_action "${_MENU_ACTIONS[idx]}" "${_MENU_LABELS[idx]}" || true
    pause_screen
}

# -----------------------------------------------------------------------------
# Function : _confirm_exit
# Purpose  : Ask the user to confirm they really want to leave the toolkit.
# Returns  : 0 if the user confirmed exit, 1 to stay in the menu.
# -----------------------------------------------------------------------------
_confirm_exit() {
    if confirm_action "Are you sure you want to exit?"; then
        log_info "Goodbye."
        return 0
    fi
    return 1
}

# =============================================================================
# PUBLIC ENTRY POINT
# =============================================================================

# -----------------------------------------------------------------------------
# Function : show_menu
# Purpose  : Infinite menu loop invoked by setup.sh. Draws the menu, reads
#            a choice, validates it, dispatches, and repeats until the user
#            selects "0" (Exit) or triggers EOF/Ctrl+C.
# -----------------------------------------------------------------------------
show_menu() {
    local _CHOICE=""

    while true; do
        _render_menu

        if ! _prompt_choice; then
            # EOF (Ctrl+D) - exit gracefully.
            log_info "End of input detected. Exiting."
            break
        fi

        # Strip surrounding whitespace so " 3 " is treated as "3".
        _CHOICE="${_CHOICE#"${_CHOICE%%[![:space:]]*}"}"
        _CHOICE="${_CHOICE%"${_CHOICE##*[![:space:]]}"}"

        if ! validate_non_empty "${_CHOICE}" "menu choice"; then
            pause_screen
            continue
        fi

        if ! _is_valid_choice "${_CHOICE}"; then
            log_error "Invalid selection: '${_CHOICE}'. Choose a number between 0 and ${_MENU_MAX}."
            pause_screen
            continue
        fi

        # Dispatch. A return value of 255 signals "Exit chosen".
        set +e
        _dispatch "$(( 10#${_CHOICE} ))"
        local rc=$?
        set -e

        if (( rc == 255 )); then
            if _confirm_exit; then
                break
            fi
        fi
    done
}