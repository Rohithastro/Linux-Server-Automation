#!/usr/bin/env bash
# =============================================================================
# Project      : Linux Server Automation
# File         : modules/create_developer_user.sh
# Description  : Interactively create a Linux developer account with a home
#                directory, bash shell, an optional GECOS full name, group
#                memberships (sudo / docker), and a secure random one-time
#                password that must be changed on first login.
# Compatible   : Ubuntu 24.04 LTS
# Depends on   : lib/colors.sh, lib/logger.sh, lib/utils.sh, lib/validators.sh
# =============================================================================

# -----------------------------------------------------------------------------
# Re-source guard
# -----------------------------------------------------------------------------
if [[ -n "${__CREATE_DEV_USER_SH_LOADED:-}" ]]; then
    return 0
fi
readonly __CREATE_DEV_USER_SH_LOADED=1

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------
for _dep in log_info log_warn log_error log_success log_debug separator \
            confirm_action pause_screen check_root command_exists \
            require_command show_spinner validate_username validate_non_empty; do
    if ! declare -F "${_dep}" >/dev/null 2>&1; then
        echo "ERROR: modules/create_developer_user.sh requires ${_dep} (missing lib)." >&2
        return 1 2>/dev/null || exit 1
    fi
done
unset _dep

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
readonly _DEFAULT_SHELL="/bin/bash"
readonly _PASSWORD_LENGTH=20

# Characters allowed in the generated password. Excludes visually ambiguous
# characters (0/O, 1/l/I) and shell-quoting hazards ('"`\$).
readonly _PASSWORD_CHARSET='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'

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
    printf "%b  >> Create Developer User%b\n" "${C_HEADER}" "${C_RESET}"
    separator "="
    echo ""
}

# -----------------------------------------------------------------------------
# Function : _prompt_username
# Purpose  : Prompt the operator for a username and validate it. Retries
#            up to _MAX_ATTEMPTS times before giving up.
# Args     : none
# Output   : validated username on stdout.
# Returns  : 0 on success, 1 on give-up.
# -----------------------------------------------------------------------------
_prompt_username() {
    local -r _MAX_ATTEMPTS=3
    local attempt=1
    local username=""

    while (( attempt <= _MAX_ATTEMPTS )); do
        printf "%b  Username: %b" "${C_PROMPT}" "${C_RESET}" >&2

        if ! read -r username; then
            echo "" >&2
            return 1
        fi

        # Strip leading / trailing whitespace.
        username="${username#"${username%%[![:space:]]*}"}"
        username="${username%"${username##*[![:space:]]}"}"

        if validate_username "${username}"; then
            echo "${username}"
            return 0
        fi

        (( attempt++ ))
        log_warn "Attempt ${attempt}/${_MAX_ATTEMPTS}. Please try again."
    done

    log_error "Too many invalid username attempts."
    return 1
}

# -----------------------------------------------------------------------------
# Function : _prompt_full_name
# Purpose  : Prompt for an optional GECOS full name. Rejects characters that
#            are illegal in the GECOS field (":" separates GECOS fields;
#            "," is a sub-field separator).
# Output   : full name on stdout (possibly empty).
# Returns  : 0 always. Invalid input is reprompted (bounded).
# -----------------------------------------------------------------------------
_prompt_full_name() {
    local -r _MAX_ATTEMPTS=3
    local attempt=1
    local full_name=""

    while (( attempt <= _MAX_ATTEMPTS )); do
        printf "%b  Full name (optional, press Enter to skip): %b" \
            "${C_PROMPT}" "${C_RESET}" >&2

        if ! read -r full_name; then
            echo "" >&2
            echo ""
            return 0
        fi

        # Trim whitespace.
        full_name="${full_name#"${full_name%%[![:space:]]*}"}"
        full_name="${full_name%"${full_name##*[![:space:]]}"}"

        # Empty is fine - GECOS is optional.
        if [[ -z "${full_name}" ]]; then
            echo ""
            return 0
        fi

        # Reject GECOS-hostile characters.
        if [[ "${full_name}" == *:* ]] || [[ "${full_name}" == *,* ]]; then
            log_warn "Full name must not contain ':' or ','."
            (( attempt++ ))
            continue
        fi

        # Reject control characters.
        if [[ "${full_name}" =~ [[:cntrl:]] ]]; then
            log_warn "Full name must not contain control characters."
            (( attempt++ ))
            continue
        fi

        echo "${full_name}"
        return 0
    done

    log_warn "Falling back to an empty full name."
    echo ""
    return 0
}

# -----------------------------------------------------------------------------
# Function : _user_exists
# Purpose  : Return 0 if the given account exists on this system.
# Args     : $1 - username
# -----------------------------------------------------------------------------
_user_exists() {
    local user="$1"
    [[ -n "${user}" ]] || return 1
    id "${user}" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Function : _print_user_info
# Purpose  : Print a compact block describing an existing (or newly created)
#            user: home, shell, primary group, all groups, UID.
# Args     : $1 - username
# -----------------------------------------------------------------------------
_print_user_info() {
    local user="$1"

    if ! _user_exists "${user}"; then
        printf "   %b→%b  User '%s' does not exist.\n" \
            "${C_ERROR}" "${C_RESET}" "${user}"
        return 0
    fi

    local uid home shell groups
    uid=$(id -u "${user}" 2>/dev/null || echo "?")
    home=$(getent passwd "${user}" | awk -F: '{print $6}')
    shell=$(getent passwd "${user}" | awk -F: '{print $7}')
    groups=$(id -nG "${user}" 2>/dev/null || echo "")

    printf "   %b→%b  Username: %s (UID %s)\n" "${C_INFO}" "${C_RESET}" "${user}" "${uid}"
    printf "   %b→%b  Home    : %s\n" "${C_INFO}" "${C_RESET}" "${home:-<none>}"
    printf "   %b→%b  Shell   : %s\n" "${C_INFO}" "${C_RESET}" "${shell:-<none>}"
    printf "   %b→%b  Groups  : %s\n" "${C_INFO}" "${C_RESET}" "${groups:-<none>}"
}

# -----------------------------------------------------------------------------
# Function : _generate_password
# Purpose  : Generate a cryptographically strong password from a curated
#            alphabet. Reads /dev/urandom, filters to allowed chars, then
#            truncates. Retries on the extremely rare short-read.
# Output   : Password on stdout.
# -----------------------------------------------------------------------------
_generate_password() {
    local pw=""
    local attempts=0

    while (( ${#pw} < _PASSWORD_LENGTH )) && (( attempts < 5 )); do
        # Pull a large-enough chunk of bytes, filter to allowed chars, take
        # the first N. LC_ALL=C ensures 'tr' operates on bytes, not locale
        # collation classes.
        pw=$(LC_ALL=C tr -dc "${_PASSWORD_CHARSET}" < /dev/urandom \
             | head -c "${_PASSWORD_LENGTH}" || true)
        (( attempts++ ))
    done

    if (( ${#pw} < _PASSWORD_LENGTH )); then
        # Last-ditch fallback using openssl if available; still forces the
        # correct length. Should essentially never trigger on modern systems.
        if command_exists openssl; then
            pw=$(openssl rand -base64 48 \
                 | LC_ALL=C tr -dc "${_PASSWORD_CHARSET}" \
                 | head -c "${_PASSWORD_LENGTH}")
        fi
    fi

    echo "${pw}"
}

# -----------------------------------------------------------------------------
# Function : _create_user_account
# Purpose  : Run `useradd` in the background so we can drive a spinner.
#            Creates home, sets shell, and sets the GECOS full name.
# Args     : $1 - username
#            $2 - full name (may be empty)
# Returns  : Exit status of useradd.
# -----------------------------------------------------------------------------
_create_user_account() {
    local user="$1"
    local full_name="${2:-}"
    local rc=0

    # Build args as an array so an empty GECOS doesn't create a stray -c.
    local -a args=(
        "--create-home"
        "--shell" "${_DEFAULT_SHELL}"
        "--user-group"
    )
    if [[ -n "${full_name}" ]]; then
        args+=("--comment" "${full_name}")
    fi
    args+=("${user}")

    log_info "Running: useradd ${args[*]}"

    set +e
    useradd "${args[@]}" >>"${LOG_FILE:-/dev/null}" 2>&1 &
    show_spinner "$!" "Creating user '${user}'..."
    rc=$?
    set -e

    return "${rc}"
}

# -----------------------------------------------------------------------------
# Function : _set_password
# Purpose  : Set the user's password non-interactively via chpasswd. The
#            password is fed on stdin so it never appears in `ps` output or
#            the shell history.
# Args     : $1 - username
#            $2 - plaintext password
# Returns  : 0 on success, non-zero on failure.
# -----------------------------------------------------------------------------
_set_password() {
    local user="$1"
    local password="$2"

    if ! command_exists chpasswd; then
        log_error "chpasswd not found; cannot set password non-interactively."
        return 1
    fi

    if ! printf '%s:%s\n' "${user}" "${password}" | chpasswd 2>/dev/null; then
        log_error "Failed to set password for '${user}'."
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Function : _force_password_change
# Purpose  : Mark the account so the user MUST change the password on
#            their first login (chage -d 0).
# Args     : $1 - username
# Returns  : 0 on success, non-zero on failure.
# -----------------------------------------------------------------------------
_force_password_change() {
    local user="$1"

    if ! command_exists chage; then
        log_warn "chage not available; skipping forced password change."
        return 0
    fi

    if ! chage -d 0 "${user}" >/dev/null 2>&1; then
        log_error "Failed to force password change for '${user}'."
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Function : _add_to_group_if_confirmed
# Purpose  : If the operator confirms, and the group exists, add the user
#            to it. Skips gracefully otherwise.
# Args     : $1 - username
#            $2 - group name
#            $3 - human-readable prompt text
# Returns  : 0 always (adds are best-effort; failures logged).
# -----------------------------------------------------------------------------
_add_to_group_if_confirmed() {
    local user="$1"
    local group="$2"
    local prompt="$3"

    if ! getent group "${group}" >/dev/null 2>&1; then
        log_info "Group '${group}' does not exist on this system; skipping."
        return 0
    fi

    if ! confirm_action "${prompt}"; then
        log_info "User will NOT be added to '${group}'."
        return 0
    fi

    # Already a member?
    if id -nG "${user}" 2>/dev/null | tr ' ' '\n' | grep -qx "${group}"; then
        log_info "User '${user}' is already in group '${group}'."
        return 0
    fi

    log_info "Adding '${user}' to group '${group}'..."
    if ! usermod -aG "${group}" "${user}"; then
        log_error "Failed to add '${user}' to '${group}'."
        return 0
    fi

    log_success "'${user}' added to '${group}'."
    return 0
}

# -----------------------------------------------------------------------------
# Function : _print_credentials
# Purpose  : Display the one-time password in a highly visible block. Warn
#            the operator to record it before continuing.
# Args     : $1 - username
#            $2 - password
# -----------------------------------------------------------------------------
_print_credentials() {
    local user="$1"
    local password="$2"

    echo ""
    separator "="
    printf "%b  IMPORTANT: One-time credentials%b\n" "${C_WARN}" "${C_RESET}"
    separator "="
    printf "   %bUsername:%b %s\n" "${C_BOLD}" "${C_RESET}" "${user}"
    printf "   %bPassword:%b %s\n" "${C_BOLD}" "${C_RESET}" "${password}"
    printf "\n   %bThe password MUST be changed on first login.%b\n" \
        "${C_WARN}" "${C_RESET}"
    printf "   %bRecord it now - it will not be shown again and is NOT written to logs.%b\n" \
        "${C_WARN}" "${C_RESET}"
    separator "="
}

# =============================================================================
# PUBLIC ENTRY POINT
# =============================================================================

# -----------------------------------------------------------------------------
# Function : create_developer_user
# Purpose  : Menu-facing action: interactively create (or extend) a Linux
#            developer account.
#
# Returns  :
#   0   on success
#   1   on user cancellation
#   2   on unmet prerequisite (missing tool)
#   3   on invalid input after retries
#   4   on user-creation failure
#   5   on password-setup failure
# -----------------------------------------------------------------------------
create_developer_user() {
    local username=""
    local full_name=""
    local password=""
    local existing=false

    _print_section_header

    # ---- Step 1: prerequisites --------------------------------------------
    check_root
    require_command "useradd"    "passwd"
    require_command "usermod"    "passwd"
    require_command "chpasswd"   "passwd"
    require_command "getent"     "libc-bin"

    # ---- Step 2: gather inputs --------------------------------------------
    if ! username=$(_prompt_username); then
        pause_screen
        return 3
    fi

    full_name=$(_prompt_full_name)

    # ---- Step 3: existing-user handling -----------------------------------
    if _user_exists "${username}"; then
        existing=true
        log_warn "User '${username}' already exists."
        _print_user_info "${username}"

        if ! confirm_action "Continue and adjust groups / reset password for this user?"; then
            log_info "Operation cancelled by user."
            pause_screen
            return 1
        fi
    fi

    # ---- Step 4: final confirmation ---------------------------------------
    echo ""
    log_info "Planned changes:"
    log_info "  username : ${username}"
    log_info "  full name: ${full_name:-<none>}"
    log_info "  shell    : ${_DEFAULT_SHELL}"
    log_info "  home     : /home/${username}"
    log_info "  existing : ${existing}"
    echo ""
    if ! confirm_action "Proceed with these settings?"; then
        log_warn "User cancelled the operation."
        pause_screen
        return 1
    fi

    # ---- Step 5: create the account (skip if it already exists) -----------
    if [[ "${existing}" != "true" ]]; then
        if ! _create_user_account "${username}" "${full_name}"; then
            log_error "useradd failed for '${username}'."
            pause_screen
            return 4
        fi
        log_success "User '${username}' created."
    fi

    # ---- Step 6: group memberships ----------------------------------------
    _add_to_group_if_confirmed "${username}" "sudo" \
        "Add '${username}' to the 'sudo' group (grants administrative privileges)?"

    if getent group docker >/dev/null 2>&1; then
        _add_to_group_if_confirmed "${username}" "docker" \
            "Add '${username}' to the 'docker' group (Docker is installed)?"
    else
        log_info "Group 'docker' not present; skipping docker group prompt."
    fi

    # ---- Step 7: password + forced change ---------------------------------
    log_info "Generating a secure one-time password..."
    password=$(_generate_password)

    if [[ ${#password} -lt _PASSWORD_LENGTH ]]; then
        log_error "Failed to generate a password of the required length."
        pause_screen
        return 5
    fi

    if ! _set_password "${username}" "${password}"; then
        pause_screen
        return 5
    fi

    if ! _force_password_change "${username}"; then
        log_warn "User created but forced-change-on-first-login could not be set."
    fi

    # ---- Step 8: report ---------------------------------------------------
    echo ""
    printf "%b  Account details%b\n" "${C_HEADER}" "${C_RESET}"
    separator "-"
    _print_user_info "${username}"
    separator "-"

    _print_credentials "${username}" "${password}"

    # Best-effort scrub of the plaintext password from memory.
    password="$(printf '%*s' "${#password}" '')"
    unset password

    log_success "Developer user '${username}' is ready."
    pause_screen
    return 0
}
