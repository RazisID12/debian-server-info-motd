#!/bin/bash

set -Eeuo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

umask 077

readonly PROJECT_NAME="Debian Server Info MOTD"
readonly PROJECT_ID="debian-server-info-motd"
readonly REPOSITORY="RazisID12/debian-server-info-motd"
readonly SOURCE_REF="main"
readonly RAW_BASE_URL="https://raw.githubusercontent.com/${REPOSITORY}/${SOURCE_REF}"
readonly PAYLOAD_PATH="etc/update-motd.d/10-server-info"
readonly CHECKSUM_PATH="SHA256SUMS"

readonly MOTD_DIRECTORY="/etc/update-motd.d"
readonly TARGET_FILE="${MOTD_DIRECTORY}/10-server-info"
readonly MOTD_FILE="/etc/motd"
readonly ISSUE_FILE="/etc/issue"
readonly STATE_DIRECTORY="/var/lib/${PROJECT_ID}"

temporary_directory=""
state_work_directory=""
backup_directory=""
mode_file=""
changes_started=0

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n $temporary_directory && -d $temporary_directory ]]; then
        rm -rf -- "$temporary_directory"
    fi

    if ((changes_started == 0)) &&
        [[ -n $state_work_directory && -d $state_work_directory ]]; then
        rm -rf -- "$state_work_directory"
    fi
}

backup_file() {
    local source_path=$1
    local backup_name=$2

    if [[ -e $source_path || -L $source_path ]]; then
        cp -a -- "$source_path" "${backup_directory}/${backup_name}"
        : > "${backup_directory}/${backup_name}.present"
    fi
}

restore_file() {
    local target_path=$1
    local backup_name=$2

    rm -f -- "$target_path" || return 1

    if [[ -f ${backup_directory}/${backup_name}.present ]]; then
        cp -a -- "${backup_directory}/${backup_name}" "$target_path"
    fi
}

rollback_installation() {
    local rollback_failed=0
    local mode
    local script_name

    rm -f -- "$TARGET_FILE" || rollback_failed=1

    restore_file "$MOTD_FILE" "motd" || rollback_failed=1
    restore_file "$ISSUE_FILE" "issue" || rollback_failed=1

    if [[ -f $mode_file ]]; then
        while IFS=$'\t' read -r mode script_name; do
            if [[ -n $mode && -n $script_name &&
                -f ${MOTD_DIRECTORY}/${script_name} &&
                ! -L ${MOTD_DIRECTORY}/${script_name} ]]; then
                chmod "$mode" -- "${MOTD_DIRECTORY}/${script_name}" ||
                    rollback_failed=1
            fi
        done < "$mode_file"
    fi

    if [[ ! -f ${state_work_directory}/update-motd-directory.present ]]; then
        rmdir -- "$MOTD_DIRECTORY" 2>/dev/null || true
    fi

    if ((rollback_failed == 0)); then
        changes_started=0
        return 0
    fi

    return 1
}

on_failure() {
    local exit_status=$1
    local line_number=$2

    trap - ERR HUP INT TERM
    set +e

    if ((changes_started == 1)); then
        if rollback_installation; then
            printf 'Installation failed and all changes were rolled back.\n' >&2
        else
            printf 'Installation failed and automatic rollback was incomplete.\n' >&2
            printf 'Recovery data was kept in: %s\n' "$state_work_directory" >&2
        fi
    else
        printf 'Installation failed.\n' >&2
    fi

    printf 'Failed near line %s.\n' "$line_number" >&2
    cleanup
    exit "$exit_status"
}

trap cleanup EXIT
trap 'on_failure "$?" "$LINENO"' ERR
trap 'on_failure 129 "$LINENO"' HUP
trap 'on_failure 130 "$LINENO"' INT
trap 'on_failure 143 "$LINENO"' TERM

if ((EUID != 0)); then
    fail "run this installer as root"
fi

if [[ ! -r /etc/os-release ]]; then
    fail "cannot read /etc/os-release"
fi

ID=""
VERSION_ID=""
. /etc/os-release

if [[ $ID != "debian" || $VERSION_ID != "13" ]]; then
    fail "this installer currently supports Debian 13 only"
fi

for command_name in wget sha256sum run-parts; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        fail "required command not found: ${command_name}"
    fi
done

if [[ -f ${STATE_DIRECTORY}/installed ]]; then
    printf '%s is already installed.\n' "$PROJECT_NAME"
    exit 0
fi

if [[ -e $STATE_DIRECTORY || -L $STATE_DIRECTORY ]]; then
    fail "state path already exists: ${STATE_DIRECTORY}"
fi

if [[ -e $TARGET_FILE || -L $TARGET_FILE ]]; then
    fail "refusing to overwrite an unmanaged file: ${TARGET_FILE}"
fi

if [[ -L $MOTD_DIRECTORY ||
    ( -e $MOTD_DIRECTORY && ! -d $MOTD_DIRECTORY ) ]]; then
    fail "expected a directory: ${MOTD_DIRECTORY}"
fi

for static_file in "$MOTD_FILE" "$ISSUE_FILE"; do
    if [[ -L $static_file ||
        ( -e $static_file && ! -f $static_file ) ]]; then
        fail "expected a regular file or an absent path: ${static_file}"
    fi
done

enabled_scripts=()

if [[ -d $MOTD_DIRECTORY ]]; then
    if ! enabled_output=$(run-parts --test --lsbsysinit "$MOTD_DIRECTORY"); then
        fail "cannot inspect ${MOTD_DIRECTORY}"
    fi

    while IFS= read -r script_path; do
        [[ -n $script_path ]] || continue

        if [[ $script_path != "${MOTD_DIRECTORY}/"* ||
            ! -f $script_path || -L $script_path ]]; then
            fail "unsupported MOTD script: ${script_path}"
        fi

        enabled_scripts+=("$script_path")
    done <<< "$enabled_output"
fi

if ! {
    printf 'Install %s? [y/N] ' "$PROJECT_NAME" > /dev/tty
    IFS= read -r answer < /dev/tty
}; then
    fail "an interactive terminal is required"
fi

case "${answer,,}" in
    y|yes)
        ;;
    *)
        printf 'Installation cancelled.\n'
        exit 0
        ;;
esac

temporary_directory=$(mktemp -d "/tmp/${PROJECT_ID}.XXXXXX")
downloaded_script="${temporary_directory}/${PAYLOAD_PATH}"
downloaded_checksums="${temporary_directory}/${CHECKSUM_PATH}"

install -d -m 0700 -- "${temporary_directory}/etc/update-motd.d"

if ! wget --quiet --https-only --timeout=30 --tries=3 \
    --output-document="$downloaded_script" \
    "${RAW_BASE_URL}/${PAYLOAD_PATH}"; then
    fail "could not download ${PAYLOAD_PATH}"
fi

if ! wget --quiet --https-only --timeout=30 --tries=3 \
    --output-document="$downloaded_checksums" \
    "${RAW_BASE_URL}/${CHECKSUM_PATH}"; then
    fail "could not download ${CHECKSUM_PATH}"
fi

expected_checksum=$(
    awk -v path="$PAYLOAD_PATH" '
        $2 == path {
            print $1
            exit
        }
    ' "$downloaded_checksums"
)

if [[ ! $expected_checksum =~ ^[[:xdigit:]]{64}$ ]]; then
    fail "no valid checksum found for ${PAYLOAD_PATH}"
fi

actual_checksum=$(sha256sum -- "$downloaded_script")
actual_checksum=${actual_checksum%% *}

if [[ ${expected_checksum,,} != $actual_checksum ]]; then
    fail "checksum verification failed for ${PAYLOAD_PATH}"
fi

if ! bash -n "$downloaded_script"; then
    fail "downloaded MOTD script has invalid Bash syntax"
fi

state_work_directory=$(mktemp -d "/var/lib/.${PROJECT_ID}.XXXXXX")
backup_directory="${state_work_directory}/backup"
mode_file="${state_work_directory}/enabled-script-modes"

install -d -o root -g root -m 0700 -- "$backup_directory"

if [[ -d $MOTD_DIRECTORY ]]; then
    : > "${state_work_directory}/update-motd-directory.present"
fi

backup_file "$MOTD_FILE" "motd"
backup_file "$ISSUE_FILE" "issue"

: > "$mode_file"

for script_path in "${enabled_scripts[@]}"; do
    printf '%s\t%s\n' \
        "$(stat -c '%a' -- "$script_path")" \
        "${script_path##*/}" >> "$mode_file"
done

printf '%s\n' "1" > "${state_work_directory}/state-format"
printf '%s\n' "$SOURCE_REF" > "${state_work_directory}/source-ref"
printf '%s\n' "$actual_checksum" > "${state_work_directory}/payload.sha256"

changes_started=1

if [[ ! -d $MOTD_DIRECTORY ]]; then
    install -d -o root -g root -m 0755 -- "$MOTD_DIRECTORY"
fi

install -o root -g root -m 0644 -- "$downloaded_script" "$TARGET_FILE"

for script_path in "${enabled_scripts[@]}"; do
    chmod a-x -- "$script_path"
done

if [[ -e $MOTD_FILE || -L $MOTD_FILE ]]; then
    : > "$MOTD_FILE"
else
    install -o root -g root -m 0644 -- /dev/null "$MOTD_FILE"
fi

if [[ -e $ISSUE_FILE || -L $ISSUE_FILE ]]; then
    : > "$ISSUE_FILE"
else
    install -o root -g root -m 0644 -- /dev/null "$ISSUE_FILE"
fi

chmod 0755 -- "$TARGET_FILE"

if ! enabled_output=$(run-parts --test --lsbsysinit "$MOTD_DIRECTORY"); then
    printf 'Could not verify the installed MOTD scripts.\n' >&2
    false
fi

if [[ $enabled_output != "$TARGET_FILE" ]]; then
    printf 'Unexpected enabled MOTD scripts were found.\n' >&2
    false
fi

"$TARGET_FILE" >/dev/null

: > "${state_work_directory}/installed"
mv -- "$state_work_directory" "$STATE_DIRECTORY"

changes_started=0
state_work_directory=""
trap - ERR HUP INT TERM

printf '\n%s was installed successfully.\n' "$PROJECT_NAME"
printf 'Open a new SSH or local console session to see the MOTD.\n'
