#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are consumed by sourced modules
set -Eeuo pipefail

# shellcheck source=../lib/harness.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../lib/harness.sh"
# shellcheck source=../../lib/core.sh
source "$ROOT/lib/core.sh"
# shellcheck source=../../lib/ui.sh
source "$ROOT/lib/ui.sh"

UI_MODE=plain

test_menu_returns_tag() {
    local selected
    selected=$(printf '2\n' | ui_menu "Тест" "Выбери" "one" "Первый" "two" "Второй")
    assert_eq "two" "$selected" "second item"
}

test_menu_retries_invalid_choice() {
    local selected
    selected=$(printf '9\n1\n' | ui_menu "Тест" "Выбери" "one" "Первый" "two" "Второй")
    assert_eq "one" "$selected" "retry then first"
}

test_menu_cancel() {
    if printf 'q\n' | ui_menu "Тест" "Выбери" "one" "Первый" >/dev/null; then
        fail "q must cancel the menu"
        return 1
    fi
}

test_confirm() {
    assert_true "yes confirms" bash -c "source '$ROOT/lib/ui.sh'; printf 'y\\n' | ui_confirm 'Continue?'"
    assert_false "no declines" bash -c "source '$ROOT/lib/ui.sh'; printf 'n\\n' | ui_confirm 'Continue?'"
    assert_false "empty declines" bash -c "source '$ROOT/lib/ui.sh'; printf '\\n' | ui_confirm 'Continue?'"
}

test_input_default() {
    local value
    value=$(printf '\n' | ui_input "Тест" "Значение" "default")
    assert_eq "default" "$value" "default value"
    value=$(printf 'custom\n' | ui_input "Тест" "Значение" "default")
    assert_eq "custom" "$value" "typed value"
}

test_password_not_echoed_to_value_stream() {
    local value
    value=$(printf 's3cret\n' | ui_password "Тест" "Пароль")
    assert_eq "s3cret" "$value" "password return value"
}

run_test "menu returns tag" test_menu_returns_tag
run_test "menu retries invalid input" test_menu_retries_invalid_choice
run_test "menu cancel" test_menu_cancel
run_test "confirm" test_confirm
run_test "input default" test_input_default
run_test "password return value" test_password_not_echoed_to_value_stream
test_summary
