#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are consumed by sourced modules
set -Eeuo pipefail

# shellcheck source=../lib/harness.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../lib/harness.sh"
# shellcheck source=../../lib/core.sh
source "$ROOT/lib/core.sh"
# shellcheck source=../../lib/validate.sh
source "$ROOT/lib/validate.sh"

# Build a deterministic fake pacman so package preflight can be tested without
# a network, a real package database or root privileges.
FAKE_BIN="$TEMP_DIR/fake-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/pacman" <<'FAKE'
#!/usr/bin/env bash
mode=${1:-}
shift || true
[[ ${1:-} == -- ]] && shift
name=${1:-}
case $mode in
    -Sgq)
        case $name in
            base-devel) printf 'gcc\nmake\n' ;;
            *) exit 1 ;;
        esac
        ;;
    -Si)
        case $name in
            base) printf 'Name            : base\nInstalled Size  : 2.00 MiB\n' ;;
            gcc) printf 'Name            : gcc\nInstalled Size  : 10.00 MiB\n' ;;
            make) printf 'Name            : make\nInstalled Size  : 1.00 MiB\n' ;;
            *) exit 1 ;;
        esac
        ;;
    *)
        exit 1
        ;;
esac
FAKE
chmod +x "$FAKE_BIN/pacman"
PATH="$FAKE_BIN:$PATH"

test_package_available() {
    assert_true "regular package" validate_package_available gcc
    assert_true "group is available" validate_package_available base-devel
    assert_false "unknown package" validate_package_available definitely-missing
}

test_validate_packages() {
    PACKAGES=(base gcc make)
    assert_true "known package set" validate_packages

    PACKAGES=(base definitely-missing)
    assert_fails "unknown package aborts preflight" validate_packages

    PACKAGES=(base 'bad package')
    assert_fails "invalid package name aborts preflight" validate_packages

    PACKAGES=()
    assert_fails "empty package list aborts preflight" validate_packages
}

test_installed_size_parsing() {
    assert_eq "10485760" "$(_package_installed_bytes gcc)" "gcc size"
    assert_false "unknown package has no size" _package_installed_bytes nope
}

test_package_size_total() {
    PACKAGES=(gcc make)
    validate_package_size >/dev/null
    assert_eq "11534336" "$REQUIRED_BYTES" "10 MiB + 1 MiB"

    PACKAGES=(gcc gcc make)
    validate_package_size >/dev/null
    assert_eq "11534336" "$REQUIRED_BYTES" "duplicates are counted once"

    PACKAGES=(base-devel)
    validate_package_size >/dev/null
    assert_eq "11534336" "$REQUIRED_BYTES" "group members are expanded"

    PACKAGES=(definitely-missing)
    validate_package_size >/dev/null
    assert_eq "0" "$REQUIRED_BYTES" "unknown packages contribute nothing"
}

run_test "package availability" test_package_available
run_test "package preflight" test_validate_packages
run_test "installed size parsing" test_installed_size_parsing
run_test "package size total" test_package_size_total
test_summary
