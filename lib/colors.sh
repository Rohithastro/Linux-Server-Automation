#!/usr/bin/env bash
# =============================================================================
# Project      : Linux Server Automation
# File         : lib/colors.sh
# Description  : Centralized ANSI color and text style definitions for
#                terminal output. Sourced by the logger and all modules
#                to produce consistent, readable colored messages.
# Compatible   : Ubuntu 24.04 LTS
# Usage        : source lib/colors.sh
#                echo -e "${C_GREEN}Success${C_RESET}"
# =============================================================================

# -----------------------------------------------------------------------------
# Re-source guard
# -----------------------------------------------------------------------------
# Prevent this file from being sourced multiple times in the same shell.
# Constants defined with `readonly` would trigger errors on re-source.
if [[ -n "${__COLORS_SH_LOADED:-}" ]]; then
    return 0
fi
readonly __COLORS_SH_LOADED=1

# -----------------------------------------------------------------------------
# TTY / color-support detection
# -----------------------------------------------------------------------------
# Only emit ANSI escape sequences when:
#   - STDOUT is attached to a terminal (interactive session)
#   - The NO_COLOR environment variable is NOT set (https://no-color.org)
#   - The terminal reports it supports at least 8 colors via tput
#
# If any check fails, all color variables are set to empty strings so that
# log files and non-interactive pipelines stay clean and free of escape codes.
# -----------------------------------------------------------------------------
_colors_supported() {
    # NO_COLOR takes precedence per the informal standard
    if [[ -n "${NO_COLOR:-}" ]]; then
        return 1
    fi

    # STDOUT must be a terminal
    if [[ ! -t 1 ]]; then
        return 1
    fi

    # tput must be available and report >= 8 colors
    if ! command -v tput >/dev/null 2>&1; then
        return 1
    fi

    local ncolors
    ncolors=$(tput colors 2>/dev/null || echo 0)
    [[ ${ncolors} -ge 8 ]]
}

# -----------------------------------------------------------------------------
# Color and style definitions
# -----------------------------------------------------------------------------
# All variables are prefixed with `C_` to avoid collisions with common
# shell variables and to make their purpose obvious at call sites.
#
# Escape sequences use the ANSI SGR (Select Graphic Rendition) format:
#   \033[<code>m
# where <code> selects color or style.
# -----------------------------------------------------------------------------
if _colors_supported; then

    # ---- Reset / styles ----------------------------------------------------
    readonly C_RESET='\033[0m'         # Reset all attributes to defaults
    readonly C_BOLD='\033[1m'          # Bold / bright text
    readonly C_DIM='\033[2m'           # Dim / faint text
    readonly C_UNDERLINE='\033[4m'     # Underlined text
    readonly C_BLINK='\033[5m'         # Blinking text (rarely supported)
    readonly C_REVERSE='\033[7m'       # Swap foreground and background

    # ---- Standard foreground colors ----------------------------------------
    readonly C_BLACK='\033[0;30m'      # Black text
    readonly C_RED='\033[0;31m'        # Red   - errors, failures
    readonly C_GREEN='\033[0;32m'      # Green - success messages
    readonly C_YELLOW='\033[0;33m'     # Yellow - warnings, prompts
    readonly C_BLUE='\033[0;34m'       # Blue - informational headers
    readonly C_MAGENTA='\033[0;35m'    # Magenta - highlights
    readonly C_CYAN='\033[0;36m'       # Cyan - info / debug messages
    readonly C_WHITE='\033[0;37m'      # White - default readable text

    # ---- Bright / bold foreground colors -----------------------------------
    readonly C_B_BLACK='\033[1;30m'    # Bold black (gray)
    readonly C_B_RED='\033[1;31m'      # Bold red
    readonly C_B_GREEN='\033[1;32m'    # Bold green
    readonly C_B_YELLOW='\033[1;33m'   # Bold yellow
    readonly C_B_BLUE='\033[1;34m'     # Bold blue
    readonly C_B_MAGENTA='\033[1;35m'  # Bold magenta
    readonly C_B_CYAN='\033[1;36m'     # Bold cyan
    readonly C_B_WHITE='\033[1;37m'    # Bold white

    # ---- Background colors -------------------------------------------------
    readonly C_BG_BLACK='\033[40m'     # Black background
    readonly C_BG_RED='\033[41m'       # Red background
    readonly C_BG_GREEN='\033[42m'     # Green background
    readonly C_BG_YELLOW='\033[43m'    # Yellow background
    readonly C_BG_BLUE='\033[44m'      # Blue background
    readonly C_BG_MAGENTA='\033[45m'   # Magenta background
    readonly C_BG_CYAN='\033[46m'      # Cyan background
    readonly C_BG_WHITE='\033[47m'     # White background

else

    # -------------------------------------------------------------------------
    # No-color fallback
    # -------------------------------------------------------------------------
    # When the terminal cannot render colors (or NO_COLOR is set), define
    # every constant as an empty string so `echo -e "${C_GREEN}..."` still
    # works without emitting raw escape codes.
    # -------------------------------------------------------------------------
    readonly C_RESET=''
    readonly C_BOLD=''
    readonly C_DIM=''
    readonly C_UNDERLINE=''
    readonly C_BLINK=''
    readonly C_REVERSE=''

    readonly C_BLACK=''
    readonly C_RED=''
    readonly C_GREEN=''
    readonly C_YELLOW=''
    readonly C_BLUE=''
    readonly C_MAGENTA=''
    readonly C_CYAN=''
    readonly C_WHITE=''

    readonly C_B_BLACK=''
    readonly C_B_RED=''
    readonly C_B_GREEN=''
    readonly C_B_YELLOW=''
    readonly C_B_BLUE=''
    readonly C_B_MAGENTA=''
    readonly C_B_CYAN=''
    readonly C_B_WHITE=''

    readonly C_BG_BLACK=''
    readonly C_BG_RED=''
    readonly C_BG_GREEN=''
    readonly C_BG_YELLOW=''
    readonly C_BG_BLUE=''
    readonly C_BG_MAGENTA=''
    readonly C_BG_CYAN=''
    readonly C_BG_WHITE=''

fi

# -----------------------------------------------------------------------------
# Semantic aliases
# -----------------------------------------------------------------------------
# Purpose-driven names that describe *intent* rather than color. Modules
# should prefer these so the color scheme can be tweaked in one place.
# -----------------------------------------------------------------------------
readonly C_SUCCESS="${C_B_GREEN}"      # Successful operations
readonly C_ERROR="${C_B_RED}"          # Errors and failures
readonly C_WARN="${C_B_YELLOW}"        # Warnings and cautions
readonly C_INFO="${C_B_CYAN}"          # Informational messages
readonly C_DEBUG="${C_DIM}"            # Debug / verbose output
readonly C_PROMPT="${C_B_MAGENTA}"     # Interactive prompts
readonly C_HEADER="${C_B_BLUE}"        # Section headers / banners