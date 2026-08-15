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

readonly STEP_COUNT=4
readonly STEP_DELAY="0.4"

temporary_directory=""
state_work_directory=""
backup_directory=""
mode_file=""
changes_started=0
step_active=0
debug_mode=0

case $# in
    0)
        ;;
    1)
        if [[ $1 != "--debug" ]]; then
            printf 'Error: unsupported option: %s\n' "$1" >&2
            exit 2
        fi

        debug_mode=1
        ;;
    *)
        printf 'Error: expected no arguments or --debug\n' >&2
        exit 2
        ;;
esac

COLOR_RESET=""
COLOR_BOLD=""
COLOR_CYAN=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_RED=""

if ((debug_mode == 0)) &&
    [[ -t 1 && -t 2 && ${TERM:-dumb} != "dumb" && -z ${NO_COLOR:-} ]]; then
    COLOR_RESET=$'\e[0m'
    COLOR_BOLD=$'\e[1m'
    COLOR_CYAN=$'\e[36m'
    COLOR_GREEN=$'\e[32m'
    COLOR_YELLOW=$'\e[33m'
    COLOR_RED=$'\e[31m'
fi

debug_log() {
    if ((debug_mode == 1)); then
        printf 'DEBUG: %s\n' "$*" >&2
    fi
}

print_header() {
    if ((debug_mode == 1)); then
        return 0
    fi

    printf '\n%s%s%s\n' "$COLOR_BOLD" "$PROJECT_NAME" "$COLOR_RESET"
    printf '%s\n\n' '-----------------------'
}

begin_step() {
    local step_number=$1
    local description=$2

    if ((debug_mode == 1)); then
        debug_log "$description"
        return 0
    fi

    step_active=1
    printf '%s[%s/%s]%s %-38s' \
        "$COLOR_CYAN" "$step_number" "$STEP_COUNT" "$COLOR_RESET" \
        "$description"
}

complete_step() {
    if ((debug_mode == 1)); then
        return 0
    fi

    if [[ -t 1 ]]; then
        sleep "$STEP_DELAY"
    fi

    printf '%sdone%s\n' "$COLOR_GREEN" "$COLOR_RESET"
    step_active=0
}

mark_step_failed() {
    if ((debug_mode == 1)); then
        return 0
    fi

    if ((step_active == 1)); then
        printf '%sfailed%s\n' "$COLOR_RED" "$COLOR_RESET"
        step_active=0
    fi
}

fail() {
    mark_step_failed
    printf '%sError:%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
    exit 1
}

download_file() {
    local source_url=$1
    local destination_path=$2

    debug_log "Downloading: ${source_url}"

    if ((debug_mode == 1)); then
        wget --no-verbose --https-only --timeout=30 --tries=3 \
            --output-document="$destination_path" "$source_url"
    else
        wget --quiet --https-only --timeout=30 --tries=3 \
            --output-document="$destination_path" "$source_url"
    fi
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
        debug_log "Backing up: ${source_path}"
        cp -a -- "$source_path" "${backup_directory}/${backup_name}"
        : > "${backup_directory}/${backup_name}.present"
    else
        debug_log "Backup source is absent: ${source_path}"
    fi
}

restore_file() {
    local target_path=$1
    local backup_name=$2

    if [[ -f ${backup_directory}/${backup_name}.present ]]; then
        debug_log "Restoring: ${target_path}"
    else
        debug_log "Removing installer-created file: ${target_path}"
    fi

    rm -f -- "$target_path" || return 1

    if [[ -f ${backup_directory}/${backup_name}.present ]]; then
        cp -a -- "${backup_directory}/${backup_name}" "$target_path"
    fi
}

rollback_installation() {
    local rollback_failed=0
    local mode
    local script_name

    debug_log "Rolling back installation"
    debug_log "Removing: ${TARGET_FILE}"
    rm -f -- "$TARGET_FILE" || rollback_failed=1

    restore_file "$MOTD_FILE" "motd" || rollback_failed=1
    restore_file "$ISSUE_FILE" "issue" || rollback_failed=1

    if [[ -f $mode_file ]]; then
        while IFS=$'\t' read -r mode script_name; do
            if [[ -n $mode && -n $script_name &&
                -f ${MOTD_DIRECTORY}/${script_name} &&
                ! -L ${MOTD_DIRECTORY}/${script_name} ]]; then
                if chmod "$mode" -- "${MOTD_DIRECTORY}/${script_name}"; then
                    debug_log \
                        "Restored mode ${mode}: ${MOTD_DIRECTORY}/${script_name}"
                else
                    rollback_failed=1
                fi
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
    mark_step_failed

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

debug_log "Installer: ${PROJECT_NAME}"
debug_log "Source reference: ${SOURCE_REF}"

if ((EUID != 0)); then
    fail "run this installer as root"
fi

if [[ ! -r /etc/os-release ]]; then
    fail "cannot read /etc/os-release"
fi

ID=""
NAME=""
VERSION_ID=""
. /etc/os-release

debug_log "Operating system: ${NAME:-$ID} ${VERSION_ID}"

if [[ $ID != "debian" || $VERSION_ID != "13" ]]; then
    fail "this installer currently supports Debian 13 only"
fi

for command_name in wget sha256sum run-parts sleep; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        fail "required command not found: ${command_name}"
    fi
done

debug_log "Required commands: available"

if [[ -f ${STATE_DIRECTORY}/installed ]]; then
    debug_log "Installation state: installed"
    printf '%s is already installed.\n' "$PROJECT_NAME"
    exit 0
fi

debug_log "Installation state: not installed"

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

if ((${#enabled_scripts[@]} == 0)); then
    debug_log "Enabled MOTD scripts: none"
else
    for script_path in "${enabled_scripts[@]}"; do
        debug_log "Enabled MOTD script: ${script_path}"
    done
fi

print_header

if ! {
    printf 'Install %s? %s[y/N]%s ' \
        "$PROJECT_NAME" "$COLOR_YELLOW" "$COLOR_RESET" > /dev/tty
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

printf '\n'

begin_step 1 "Downloading files..."

temporary_directory=$(mktemp -d "/tmp/${PROJECT_ID}.XXXXXX")
downloaded_script="${temporary_directory}/${PAYLOAD_PATH}"
downloaded_checksums="${temporary_directory}/${CHECKSUM_PATH}"

debug_log "Temporary directory: ${temporary_directory}"

install -d -m 0700 -- "${temporary_directory}/etc/update-motd.d"

if ! download_file \
    "${RAW_BASE_URL}/${PAYLOAD_PATH}" "$downloaded_script"; then
    fail "could not download ${PAYLOAD_PATH}"
fi

if ! download_file \
    "${RAW_BASE_URL}/${CHECKSUM_PATH}" "$downloaded_checksums"; then
    fail "could not download ${CHECKSUM_PATH}"
fi

complete_step
begin_step 2 "Verifying SHA-256 checksum..."

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

debug_log "Expected SHA-256: ${expected_checksum}"

actual_checksum=$(sha256sum -- "$downloaded_script")
actual_checksum=${actual_checksum%% *}

debug_log "Actual SHA-256: ${actual_checksum}"

if [[ ${expected_checksum,,} != $actual_checksum ]]; then
    fail "checksum verification failed for ${PAYLOAD_PATH}"
fi

if ! bash -n "$downloaded_script"; then
    fail "downloaded MOTD script has invalid Bash syntax"
fi

debug_log "Downloaded MOTD script syntax: valid"

complete_step
begin_step 3 "Installing MOTD..."

state_work_directory=$(mktemp -d "/var/lib/.${PROJECT_ID}.XXXXXX")
backup_directory="${state_work_directory}/backup"
mode_file="${state_work_directory}/enabled-script-modes"

debug_log "State work directory: ${state_work_directory}"

install -d -o root -g root -m 0700 -- "$backup_directory"

if [[ -d $MOTD_DIRECTORY ]]; then
    : > "${state_work_directory}/update-motd-directory.present"
fi

backup_file "$MOTD_FILE" "motd"
backup_file "$ISSUE_FILE" "issue"

: > "$mode_file"

for script_path in "${enabled_scripts[@]}"; do
    script_mode=$(stat -c '%a' -- "$script_path")
    printf '%s\t%s\n' \
        "$script_mode" \
        "${script_path##*/}" >> "$mode_file"
    debug_log "Saved mode ${script_mode}: ${script_path}"
done

printf '%s\n' "1" > "${state_work_directory}/state-format"
printf '%s\n' "$SOURCE_REF" > "${state_work_directory}/source-ref"
printf '%s\n' "$actual_checksum" > "${state_work_directory}/payload.sha256"

changes_started=1

if [[ ! -d $MOTD_DIRECTORY ]]; then
    debug_log "Creating directory: ${MOTD_DIRECTORY}"
    install -d -o root -g root -m 0755 -- "$MOTD_DIRECTORY"
fi

debug_log "Installing: ${TARGET_FILE}"
install -o root -g root -m 0644 -- "$downloaded_script" "$TARGET_FILE"

for script_path in "${enabled_scripts[@]}"; do
    debug_log "Disabling MOTD script: ${script_path}"
    chmod a-x -- "$script_path"
done

debug_log "Clearing: ${MOTD_FILE}"
if [[ -e $MOTD_FILE || -L $MOTD_FILE ]]; then
    : > "$MOTD_FILE"
else
    install -o root -g root -m 0644 -- /dev/null "$MOTD_FILE"
fi

debug_log "Clearing: ${ISSUE_FILE}"
if [[ -e $ISSUE_FILE || -L $ISSUE_FILE ]]; then
    : > "$ISSUE_FILE"
else
    install -o root -g root -m 0644 -- /dev/null "$ISSUE_FILE"
fi

chmod 0755 -- "$TARGET_FILE"
debug_log "Installed mode 0755: ${TARGET_FILE}"

complete_step
begin_step 4 "Verifying installation..."

if ! enabled_output=$(run-parts --test --lsbsysinit "$MOTD_DIRECTORY"); then
    mark_step_failed
    printf 'Could not verify the installed MOTD scripts.\n' >&2
    false
fi

debug_log "Enabled after installation: ${enabled_output:-none}"

if [[ $enabled_output != "$TARGET_FILE" ]]; then
    mark_step_failed
    printf 'Unexpected enabled MOTD scripts were found.\n' >&2
    false
fi

debug_log "Executing installed MOTD script for verification"
"$TARGET_FILE" >/dev/null

complete_step

: > "${state_work_directory}/installed"
mv -- "$state_work_directory" "$STATE_DIRECTORY"

debug_log "Installation state saved: ${STATE_DIRECTORY}"

changes_started=0
state_work_directory=""
trap - ERR HUP INT TERM

if ((debug_mode == 1)); then
    printf '%s was installed successfully.\n' "$PROJECT_NAME"
else
    printf '\n%s[OK]%s %s was installed successfully.\n\n' \
        "$COLOR_GREEN" "$COLOR_RESET" "$PROJECT_NAME"
fi

printf 'Open a new SSH or local console session to see the MOTD.\n'
