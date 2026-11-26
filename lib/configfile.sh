#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # variables set here are consumed by install.sh/workflow.sh after source
# Configuration file manager for unattended (non-interactive) installation.
#
# A configuration file uses a simple INI-like syntax that can be parsed with
# pure Bash (no yq, jq or python required). Sections are [section] headers;
# keys are `key = value` lines. Comments start with # or ;.
#
# Example:
#   [system]
#   hostname = archlinux
#   username = alice
#   timezone = Europe/Prague
#   locale = en_US.UTF-8
#   keymap = us
#   root_policy = password
#   zram = false
#
#   [install]
#   mode = minimal
#   desktop = gnome
#   kernel = linux
#   filesystem = ext4
#   encryption = false
#
#   [disk]
#   device = /dev/nvme0n1
#   efi_size_mib = 1024
#
#   [packages]
#   extra = git vim htop
#
#   [network]
#   wifi_ssid = MyNetwork
#   wifi_password = secret

[[ -n ${AS_CONFIGFILE_LOADED:-} ]] && return 0
AS_CONFIGFILE_LOADED=1

CONFIG_FILE=
CONFIG_SECTION=

# Print an error and exit. Used by the config loader only.
configfile_die() {
    printf 'configfile: %s\n' "$*" >&2
    exit 2
}

# Trim leading/trailing whitespace from a value.
configfile_trim() {
    local value=$1
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

# Remove inline comments (but not inside quotes).
# Both # and ; are treated as comment starters outside of quotes.
configfile_strip_comment() {
    local line=$1
    local in_quote=0
    local i ch out=
    for ((i = 0; i < ${#line}; i++)); do
        ch="${line:$i:1}"
        if [[ $ch == '"' ]]; then
            ((in_quote ^= 1))
            out+="$ch"
        elif [[ $in_quote == 0 && ($ch == '#' || $ch == ';') ]]; then
            break
        else
            out+="$ch"
        fi
    done
    printf '%s' "$out"
}

# Parse a configuration file. After sourcing, call configfile_apply to copy
# values into installer variables.
configfile_parse() {
    local file=$1
    local line section key value
    [[ -f $file ]] || configfile_die "configuration file not found: $file"
    [[ -r $file ]] || configfile_die "configuration file is not readable: $file"
    while IFS= read -r line || [[ -n $line ]]; do
        line=$(configfile_strip_comment "$line")
        line=$(configfile_trim "$line")
        [[ -z $line ]] && continue
        if [[ $line == '['*']' ]]; then
            section=${line#[}
            section=${section%]}
            section=$(configfile_trim "$section")
            continue
        fi
        if [[ $line == *=* ]]; then
            key=${line%%=*}
            value=${line#*=}
            key=$(configfile_trim "$key")
            value=$(configfile_trim "$value")
            # Strip surrounding quotes.
            if [[ ${#value} -ge 2 && $value == '"'*'"' ]]; then
                value=${value:1:${#value}-2}
            fi
            [[ -n $key ]] || configfile_die "empty key in $file"
            printf '%s\t%s\t%s\n' "$section" "$key" "$value"
        fi
    done <"$file"
}

# Apply parsed configuration values to installer globals.
#
# Recognised sections: system, install, disk, packages, network.
# Boolean values: true/false/yes/no/1/0.
configfile_apply() {
    local section key value
    while IFS=$'\t' read -r section key value; do
        case $section in
            system)
                case $key in
                    hostname) HOSTNAME=$value ;;
                    username) USERNAME=$value ;;
                    timezone) TIMEZONE=$value ;;
                    locale) LOCALE=$value ;;
                    keymap) KEYMAP=$value ;;
                    root_policy) ROOT_POLICY=$value ;;
                    zram)
                        case ${value,,} in
                            true|yes|1) ZRAM=1 ;;
                            false|no|0) ZRAM=0 ;;
                            *) configfile_die "invalid boolean for system.zram: $value" ;;
                        esac
                        ;;
                    *) configfile_die "unknown key in [system]: $key" ;;
                esac
                ;;
            install)
                case $key in
                    mode) MODE=$value ;;
                    desktop) DESKTOP=$value ;;
                    kernel) KERNEL=$value ;;
                    filesystem) FS_TYPE=$value ;;
                    encryption)
                        case ${value,,} in
                            true|yes|1) ENCRYPT=1 ;;
                            false|no|0) ENCRYPT=0 ;;
                            *) configfile_die "invalid boolean for install.encryption: $value" ;;
                        esac
                        ;;
                    luks_password) LUKS_PASSWORD=$value ;;
                    root_password) ROOT_PASSWORD=$value ;;
                    user_password) USER_PASSWORD=$value ;;
                    efi_size_mib) EFI_SIZE_MIB=$value ;;
                    *) configfile_die "unknown key in [install]: $key" ;;
                esac
                ;;
            disk)
                case $key in
                    device) DISK=$value ;;
                    efi_size_mib) EFI_SIZE_MIB=$value ;;
                    *) configfile_die "unknown key in [disk]: $key" ;;
                esac
                ;;
            packages)
                case $key in
                    extra)
                        read -r -a EXTRA_PACKAGES <<<"$value"
                        ;;
                    *) configfile_die "unknown key in [packages]: $key" ;;
                esac
                ;;
            network)
                case $key in
                    wifi_ssid) CONFIG_WIFI_SSID=$value ;;
                    wifi_password) CONFIG_WIFI_PASSWORD=$value ;;
                    *) configfile_die "unknown key in [network]: $key" ;;
                esac
                ;;
            *)
                configfile_die "unknown section: [$section]" ;;
        esac
    done
}

# Load and apply a configuration file. Exits on error.
#
# Uses process substitution so that variable assignments inside configfile_apply
# are visible in the calling shell (a plain pipe would run configfile_apply in a
# subshell and the assignments would be lost).
configfile_load() {
    local file=$1
    [[ -n $file ]] || configfile_die "no configuration file specified"
    configfile_apply < <(configfile_parse "$file")
}

# Validate required fields for unattended mode.
configfile_validate_required() {
    local -a missing=()
    [[ -n ${DISK:-} ]] || missing+=("disk.device")
    [[ -n ${MODE:-} ]] || missing+=("install.mode")
    [[ -n ${KERNEL:-} ]] || missing+=("install.kernel")
    [[ -n ${FS_TYPE:-} ]] || missing+=("install.filesystem")
    [[ -n ${HOSTNAME:-} ]] || missing+=("system.hostname")
    [[ -n ${USERNAME:-} ]] || missing+=("system.username")
    if [[ ${ENCRYPT:-0} == 1 && -z ${LUKS_PASSWORD:-} ]]; then
        missing+=("install.luks_password")
    fi
    if [[ ${ROOT_POLICY:-password} == password && -z ${ROOT_PASSWORD:-} ]]; then
        missing+=("install.root_password")
    fi
    if [[ -z ${USER_PASSWORD:-} ]]; then
        missing+=("install.user_password")
    fi
    if ((${#missing[@]})); then
        die "Configuration file is missing required fields: $(core_join_by ', ' "${missing[@]}")"
    fi
}

# Print a sample configuration file to stdout.
configfile_sample() {
    cat <<'EOF'
# ArchinstallSuper unattended installation configuration.
# Copy this file, edit the values, and run:
#   bash install.sh --config myconfig.conf --auto

[system]
hostname = archlinux
username = alice
timezone = Europe/Prague
locale = en_US.UTF-8
keymap = us
root_policy = password
zram = false

[install]
mode = minimal
desktop = gnome
kernel = linux
filesystem = ext4
encryption = false
# Set passwords only for unattended mode. They are not logged.
root_password = CHANGE_ME
user_password = CHANGE_ME
luks_password = CHANGE_ME

[disk]
device = /dev/nvme0n1
efi_size_mib = 1024

[packages]
extra = git vim htop

[network]
# wifi_ssid = MyNetwork
# wifi_password = secret
EOF
}
