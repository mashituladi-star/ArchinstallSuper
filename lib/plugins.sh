#!/usr/bin/env bash
# shellcheck shell=bash
# Minimal, explicit plugin system.
#
# A plugin is a local shell file in plugins/*.sh named with letters, digits and
# underscores. It may define functions named plugin_<file>_<hook>, for example
# plugin_example_pre_install. Hooks are called synchronously; a failing hook
# aborts the installation. Plugins are trusted local code, so they are never
# downloaded automatically.

[[ -n ${AS_PLUGINS_LOADED:-} ]] && return 0
AS_PLUGINS_LOADED=1

PLUGIN_NAMES=()

plugin_load_all() {
    local dir="${SCRIPT_DIR:-$(pwd)}/plugins"
    PLUGIN_NAMES=()
    [[ -d $dir ]] || return 0
    local file name
    for file in "$dir"/*.sh; do
        [[ -f $file ]] || continue
        name=$(basename -- "$file" .sh)
        if [[ ! $name =~ ^[A-Za-z0-9_]+$ ]]; then
            warn "Пропускаю плагин с недопустимым именем: $file"
            continue
        fi
        # shellcheck source=/dev/null
        source "$file" || die "Не удалось загрузить плагин: $file"
        PLUGIN_NAMES+=("$name")
        info "Загружен плагин: $name"
    done
}

plugin_hook() {
    local hook=$1
    shift
    local name function
    for name in "${PLUGIN_NAMES[@]}"; do
        function="plugin_${name}_${hook}"
        if declare -F "$function" >/dev/null 2>&1; then
            debug "Плагин $name: hook $hook"
            "$function" "$@" || die "Плагин $name прервал установку на hook $hook."
        fi
    done
}
