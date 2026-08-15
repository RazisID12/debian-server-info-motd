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

readonly STEP_DELAY="0.4"
readonly DEBUG_LINE_DELAY="0.1"

step_count=4
temporary_directory=""
state_work_directory=""
backup_directory=""
mode_file=""
rollback_directory=""
rollback_mode_file=""
target_temp_file=""
state_checksum_temp=""
state_source_ref_temp=""
downloaded_script=""
downloaded_checksums=""
expected_checksum=""
actual_checksum=""
installed_checksum=""
installed_source_ref=""
selected_action=""
motd_directory_preexisted=1
active_operation="Installation"
operation_key="install"
changes_started=0
step_active=0
debug_mode=0
debug_pacing=0
preserve_temporary=0

saved_script_modes=()
saved_script_names=()

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

        if ((debug_pacing == 1)) && [[ -t 2 ]]; then
            sleep "$DEBUG_LINE_DELAY"
        fi
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
        if ((step_number > 1)); then
            printf '\n' >&2
        fi

        debug_log "$description"
        return 0
    fi

    step_active=1
    printf '%s[%s/%s]%s %-38s' \
        "$COLOR_CYAN" "$step_number" "$step_count" "$COLOR_RESET" \
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

download_and_verify_payload() {
    local download_step=$1
    local verify_step=$2

    begin_step "$download_step" "Downloading files..."

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
    begin_step "$verify_step" "Verifying SHA-256 checksum..."

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

    expected_checksum=${expected_checksum,,}
    debug_log "Expected SHA-256: ${expected_checksum}"

    actual_checksum=$(sha256sum -- "$downloaded_script")
    actual_checksum=${actual_checksum%% *}

    debug_log "Actual SHA-256: ${actual_checksum}"

    if [[ $expected_checksum != $actual_checksum ]]; then
        fail "checksum verification failed for ${PAYLOAD_PATH}"
    fi

    if ! bash -n "$downloaded_script"; then
        fail "downloaded MOTD script has invalid Bash syntax"
    fi

    debug_log "Downloaded MOTD script syntax: valid"
    complete_step
}

cleanup() {
    if [[ -n $target_temp_file &&
        ( -e $target_temp_file || -L $target_temp_file ) ]]; then
        rm -f -- "$target_temp_file"
    fi

    if [[ -n $state_checksum_temp &&
        ( -e $state_checksum_temp || -L $state_checksum_temp ) ]]; then
        rm -f -- "$state_checksum_temp"
    fi

    if [[ -n $state_source_ref_temp &&
        ( -e $state_source_ref_temp || -L $state_source_ref_temp ) ]]; then
        rm -f -- "$state_source_ref_temp"
    fi

    if ((preserve_temporary == 0)) &&
        [[ -n $temporary_directory && -d $temporary_directory ]]; then
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

backup_transaction_file() {
    local source_path=$1
    local backup_name=$2

    if [[ -e $source_path || -L $source_path ]]; then
        cp -a -- "$source_path" "${rollback_directory}/${backup_name}"
        : > "${rollback_directory}/${backup_name}.present"
    fi
}

restore_transaction_file() {
    local target_path=$1
    local backup_name=$2

    rm -f -- "$target_path" || return 1

    if [[ -f ${rollback_directory}/${backup_name}.present ]]; then
        cp -a -- "${rollback_directory}/${backup_name}" "$target_path"
    fi
}

verify_restored_file() {
    local target_path=$1
    local backup_name=$2

    if [[ -f ${backup_directory}/${backup_name}.present ]]; then
        [[ -f $target_path && ! -L $target_path ]] || return 1
        cmp -s -- "${backup_directory}/${backup_name}" "$target_path" &&
            [[ $(stat -c '%U:%G:%a' -- "$target_path") == \
                "$(stat -c '%U:%G:%a' -- \
                    "${backup_directory}/${backup_name}")" ]]
    else
        [[ ! -e $target_path && ! -L $target_path ]]
    fi
}

validate_installed_state() {
    local backup_name
    local current_checksum
    local current_mode
    local enabled_output
    local expected_disabled_mode
    local expected_disabled_value
    local extra_field
    local mode
    local original_mode_value
    local script_name
    local script_path
    local state_attributes
    local state_format
    local state_path
    local -A seen_scripts=()

    if [[ -L $STATE_DIRECTORY || ! -d $STATE_DIRECTORY ]]; then
        fail "invalid installation state directory: ${STATE_DIRECTORY}"
    fi

    state_attributes=$(stat -c '%U:%G:%a' -- "$STATE_DIRECTORY")

    if [[ $state_attributes != "root:root:700" ]]; then
        fail "unexpected ownership or mode on ${STATE_DIRECTORY}"
    fi

    for state_path in \
        "${STATE_DIRECTORY}/installed" \
        "${STATE_DIRECTORY}/state-format" \
        "${STATE_DIRECTORY}/source-ref" \
        "${STATE_DIRECTORY}/payload.sha256" \
        "${STATE_DIRECTORY}/enabled-script-modes"; do
        if [[ -L $state_path || ! -f $state_path ]]; then
            fail "invalid installation state file: ${state_path}"
        fi
    done

    backup_directory="${STATE_DIRECTORY}/backup"
    mode_file="${STATE_DIRECTORY}/enabled-script-modes"

    if [[ -L $backup_directory || ! -d $backup_directory ]]; then
        fail "invalid backup directory: ${backup_directory}"
    fi

    state_format=$(< "${STATE_DIRECTORY}/state-format")

    if [[ $state_format != "1" ]]; then
        fail "unsupported installation state format: ${state_format}"
    fi

    installed_source_ref=$(< "${STATE_DIRECTORY}/source-ref")

    if [[ ! $installed_source_ref =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ||
        $installed_source_ref == *".."* ]]; then
        fail "invalid source reference in installation state"
    fi

    installed_checksum=$(< "${STATE_DIRECTORY}/payload.sha256")
    installed_checksum=${installed_checksum,,}

    if [[ ! $installed_checksum =~ ^[[:xdigit:]]{64}$ ]]; then
        fail "invalid payload checksum in installation state"
    fi

    for backup_name in motd issue; do
        if [[ -e ${backup_directory}/${backup_name}.present ||
            -L ${backup_directory}/${backup_name}.present ]]; then
            if [[ -L ${backup_directory}/${backup_name}.present ||
                ! -f ${backup_directory}/${backup_name}.present ||
                -L ${backup_directory}/${backup_name} ||
                ! -f ${backup_directory}/${backup_name} ]]; then
                fail "invalid backup entry: ${backup_name}"
            fi
        elif [[ -e ${backup_directory}/${backup_name} ||
            -L ${backup_directory}/${backup_name} ]]; then
            fail "backup marker is missing for: ${backup_name}"
        fi
    done

    if [[ -e ${STATE_DIRECTORY}/update-motd-directory.present ||
        -L ${STATE_DIRECTORY}/update-motd-directory.present ]]; then
        if [[ -L ${STATE_DIRECTORY}/update-motd-directory.present ||
            ! -f ${STATE_DIRECTORY}/update-motd-directory.present ]]; then
            fail "invalid update-motd directory marker"
        fi

        motd_directory_preexisted=1
    else
        motd_directory_preexisted=0
    fi

    if [[ -L $MOTD_DIRECTORY || ! -d $MOTD_DIRECTORY ]]; then
        fail "expected a directory: ${MOTD_DIRECTORY}"
    fi

    if [[ -L $TARGET_FILE || ! -f $TARGET_FILE ]]; then
        fail "installed MOTD script is missing or unsupported: ${TARGET_FILE}"
    fi

    if [[ $(stat -c '%U:%G:%a' -- "$TARGET_FILE") != "root:root:755" ]]; then
        fail "unexpected ownership or mode on ${TARGET_FILE}"
    fi

    current_checksum=$(sha256sum -- "$TARGET_FILE")
    current_checksum=${current_checksum%% *}

    if [[ $current_checksum != "$installed_checksum" ]]; then
        fail "installed MOTD script was modified: ${TARGET_FILE}"
    fi

    for state_path in "$MOTD_FILE" "$ISSUE_FILE"; do
        if [[ -L $state_path || ! -f $state_path ]]; then
            fail "expected a regular file: ${state_path}"
        fi

        if [[ -s $state_path ]]; then
            fail "file was modified after installation: ${state_path}"
        fi
    done

    saved_script_modes=()
    saved_script_names=()

    while IFS=$'\t' read -r mode script_name extra_field; do
        if [[ ! $mode =~ ^[0-7]{3,4}$ ||
            ! $script_name =~ ^[A-Za-z0-9_-]+$ ||
            -n $extra_field || $script_name == "${TARGET_FILE##*/}" ]]; then
            fail "invalid enabled-script entry in installation state"
        fi

        if [[ -n ${seen_scripts[$script_name]:-} ]]; then
            fail "duplicate enabled-script entry: ${script_name}"
        fi

        seen_scripts[$script_name]=1
        script_path="${MOTD_DIRECTORY}/${script_name}"

        if [[ -L $script_path || ! -f $script_path ]]; then
            fail "previous MOTD script is missing or unsupported: ${script_path}"
        fi

        original_mode_value=$((8#$mode))

        if (( (original_mode_value & 0111) == 0 )); then
            fail "saved MOTD script mode is not executable: ${script_path}"
        fi

        expected_disabled_value=$((original_mode_value & ~0111))
        printf -v expected_disabled_mode '%o' "$expected_disabled_value"
        current_mode=$(stat -c '%a' -- "$script_path")

        if [[ $current_mode != "$expected_disabled_mode" ]]; then
            fail "MOTD script mode was modified: ${script_path}"
        fi

        saved_script_modes+=("$mode")
        saved_script_names+=("$script_name")
    done < "$mode_file"

    if ! enabled_output=$(run-parts --test --lsbsysinit "$MOTD_DIRECTORY"); then
        fail "cannot inspect ${MOTD_DIRECTORY}"
    fi

    if [[ $enabled_output != "$TARGET_FILE" ]]; then
        fail "unexpected enabled MOTD scripts were found"
    fi

    debug_log "Installation state format: ${state_format}"
    debug_log "Installed source reference: ${installed_source_ref}"
    debug_log "Installed payload SHA-256: ${installed_checksum}"
    debug_log "Installed MOTD configuration: valid"
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

rollback_update() {
    local rollback_failed=0

    debug_log "Rolling back update"

    if ! restore_transaction_file "$TARGET_FILE" "target"; then
        rollback_failed=1
    else
        debug_log "Restored previous version: ${TARGET_FILE}"
    fi

    if ! printf '%s\n' "$installed_checksum" > \
        "${STATE_DIRECTORY}/payload.sha256"; then
        rollback_failed=1
    fi

    if ! printf '%s\n' "$installed_source_ref" > \
        "${STATE_DIRECTORY}/source-ref"; then
        rollback_failed=1
    fi

    if ((rollback_failed == 0)); then
        changes_started=0
        return 0
    fi

    preserve_temporary=1
    return 1
}

rollback_uninstallation() {
    local mode
    local rollback_failed=0
    local script_name

    debug_log "Rolling back uninstallation"

    if [[ ! -d $MOTD_DIRECTORY ]]; then
        install -d -o root -g root -m 0755 -- "$MOTD_DIRECTORY" || \
            rollback_failed=1
    fi

    restore_transaction_file "$TARGET_FILE" "target" || rollback_failed=1
    restore_transaction_file "$MOTD_FILE" "motd" || rollback_failed=1
    restore_transaction_file "$ISSUE_FILE" "issue" || rollback_failed=1

    if [[ -f $rollback_mode_file ]]; then
        while IFS=$'\t' read -r mode script_name; do
            if [[ -n $mode && -n $script_name &&
                -f ${MOTD_DIRECTORY}/${script_name} &&
                ! -L ${MOTD_DIRECTORY}/${script_name} ]]; then
                chmod "$mode" -- "${MOTD_DIRECTORY}/${script_name}" || \
                    rollback_failed=1
            else
                rollback_failed=1
            fi
        done < "$rollback_mode_file"
    else
        rollback_failed=1
    fi

    if ((rollback_failed == 0)); then
        changes_started=0
        return 0
    fi

    preserve_temporary=1
    return 1
}

on_failure() {
    local exit_status=$1
    local line_number=$2
    local rollback_succeeded=0

    trap - ERR HUP INT TERM
    set +e
    mark_step_failed

    if ((changes_started == 1)); then
        case $operation_key in
            install)
                rollback_installation && rollback_succeeded=1
                ;;
            update)
                rollback_update && rollback_succeeded=1
                ;;
            uninstall)
                rollback_uninstallation && rollback_succeeded=1
                ;;
        esac

        if ((rollback_succeeded == 1)); then
            printf '%s failed and all changes were rolled back.\n' \
                "$active_operation" >&2
        else
            printf '%s failed and automatic rollback was incomplete.\n' \
                "$active_operation" >&2

            if [[ -n $state_work_directory && -d $state_work_directory ]]; then
                printf 'Recovery data was kept in: %s\n' \
                    "$state_work_directory" >&2
            fi

            if [[ -n $temporary_directory && -d $temporary_directory ]]; then
                printf 'Temporary recovery data was kept in: %s\n' \
                    "$temporary_directory" >&2
            fi
        fi
    else
        printf '%s failed.\n' "$active_operation" >&2
    fi

    printf 'Failed near line %s.\n' "$line_number" >&2
    cleanup
    exit "$exit_status"
}

print_success() {
    local message=$1

    if ((debug_mode == 1)); then
        printf '%s\n' "$message"
    else
        printf '\n%s[OK]%s %s\n\n' \
            "$COLOR_GREEN" "$COLOR_RESET" "$message"
    fi
}

prompt_installed_action() {
    print_header
    printf 'Status: installed\n\n'
    printf '  [1] Update\n'
    printf '  [2] Uninstall\n'
    printf '  [3] Cancel\n\n'

    while true; do
        if ! {
            printf 'Select an action [1-3]: ' > /dev/tty
            IFS= read -r answer < /dev/tty
        }; then
            fail "an interactive terminal is required"
        fi

        case "${answer,,}" in
            1|update)
                selected_action="update"
                return 0
                ;;
            2|uninstall)
                selected_action="uninstall"
                return 0
                ;;
            3|cancel)
                selected_action="cancel"
                return 0
                ;;
            *)
                printf 'Please select 1, 2, or 3.\n' > /dev/tty
                ;;
        esac
    done
}

confirm_uninstallation() {
    if ! {
        printf 'Uninstall %s and restore the previous MOTD? %s[y/N]%s ' \
            "$PROJECT_NAME" "$COLOR_YELLOW" "$COLOR_RESET" > /dev/tty
        IFS= read -r answer < /dev/tty
    }; then
        fail "an interactive terminal is required"
    fi

    case "${answer,,}" in
        y|yes)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

run_update() {
    local current_checksum
    local enabled_output

    active_operation="Update"
    operation_key="update"
    step_count=6

    begin_step 1 "Validating installation..."
    validate_installed_state
    complete_step

    download_and_verify_payload 2 3

    begin_step 4 "Comparing versions..."

    if [[ $actual_checksum == "$installed_checksum" ]]; then
        debug_log "Installed version is already current"
        complete_step

        begin_step 5 "No update required..."
        complete_step

        begin_step 6 "Verifying installation..."
        "$TARGET_FILE" >/dev/null
        complete_step

        trap - ERR HUP INT TERM
        print_success "${PROJECT_NAME} is already up to date."
        return 0
    fi

    debug_log "Update available: ${installed_checksum} -> ${actual_checksum}"
    complete_step
    begin_step 5 "Installing update..."

    rollback_directory="${temporary_directory}/rollback"
    install -d -m 0700 -- "$rollback_directory"
    backup_transaction_file "$TARGET_FILE" "target"

    target_temp_file=$(mktemp "${MOTD_DIRECTORY}/.10-server-info.XXXXXX")
    install -o root -g root -m 0755 -- \
        "$downloaded_script" "$target_temp_file"

    changes_started=1
    mv -f -- "$target_temp_file" "$TARGET_FILE"
    target_temp_file=""

    debug_log "Installed updated file: ${TARGET_FILE}"
    complete_step
    begin_step 6 "Verifying update..."

    current_checksum=$(sha256sum -- "$TARGET_FILE")
    current_checksum=${current_checksum%% *}

    if [[ $current_checksum != "$actual_checksum" ]]; then
        mark_step_failed
        printf 'Updated MOTD checksum verification failed.\n' >&2
        false
    fi

    if ! enabled_output=$(run-parts --test --lsbsysinit "$MOTD_DIRECTORY"); then
        mark_step_failed
        printf 'Could not verify the updated MOTD scripts.\n' >&2
        false
    fi

    if [[ $enabled_output != "$TARGET_FILE" ]]; then
        mark_step_failed
        printf 'Unexpected enabled MOTD scripts were found after update.\n' >&2
        false
    fi

    "$TARGET_FILE" >/dev/null

    state_checksum_temp=$(mktemp \
        "${STATE_DIRECTORY}/.payload.sha256.XXXXXX")
    printf '%s\n' "$actual_checksum" > "$state_checksum_temp"
    chmod 0600 -- "$state_checksum_temp"

    state_source_ref_temp=$(mktemp \
        "${STATE_DIRECTORY}/.source-ref.XXXXXX")
    printf '%s\n' "$SOURCE_REF" > "$state_source_ref_temp"
    chmod 0600 -- "$state_source_ref_temp"

    mv -f -- "$state_checksum_temp" "${STATE_DIRECTORY}/payload.sha256"
    state_checksum_temp=""
    mv -f -- "$state_source_ref_temp" "${STATE_DIRECTORY}/source-ref"
    state_source_ref_temp=""

    if [[ $(< "${STATE_DIRECTORY}/payload.sha256") != "$actual_checksum" ||
        $(< "${STATE_DIRECTORY}/source-ref") != "$SOURCE_REF" ]]; then
        mark_step_failed
        printf 'Could not verify the updated installation state.\n' >&2
        false
    fi

    debug_log "Updated payload SHA-256: ${actual_checksum}"
    complete_step

    changes_started=0
    trap - ERR HUP INT TERM
    print_success "${PROJECT_NAME} was updated successfully."
}

run_uninstallation() {
    local current_mode
    local enabled_output
    local expected_enabled_output=""
    local index
    local script_name
    local script_path

    active_operation="Uninstallation"
    operation_key="uninstall"
    step_count=4

    begin_step 1 "Validating installation..."
    validate_installed_state
    complete_step
    begin_step 2 "Restoring previous MOTD..."

    temporary_directory=$(mktemp -d "/tmp/${PROJECT_ID}.uninstall.XXXXXX")
    rollback_directory="${temporary_directory}/rollback"
    rollback_mode_file="${rollback_directory}/script-modes"

    install -d -m 0700 -- "$rollback_directory"
    backup_transaction_file "$TARGET_FILE" "target"
    backup_transaction_file "$MOTD_FILE" "motd"
    backup_transaction_file "$ISSUE_FILE" "issue"
    : > "$rollback_mode_file"

    for ((index = 0; index < ${#saved_script_names[@]}; index++)); do
        script_name=${saved_script_names[index]}
        script_path="${MOTD_DIRECTORY}/${script_name}"
        current_mode=$(stat -c '%a' -- "$script_path")
        printf '%s\t%s\n' "$current_mode" "$script_name" >> \
            "$rollback_mode_file"
    done

    changes_started=1

    restore_file "$MOTD_FILE" "motd"
    restore_file "$ISSUE_FILE" "issue"

    for ((index = 0; index < ${#saved_script_names[@]}; index++)); do
        script_name=${saved_script_names[index]}
        script_path="${MOTD_DIRECTORY}/${script_name}"
        chmod "${saved_script_modes[index]}" -- "$script_path"
        debug_log \
            "Restored mode ${saved_script_modes[index]}: ${script_path}"
    done

    complete_step
    begin_step 3 "Removing installed files..."

    debug_log "Removing: ${TARGET_FILE}"
    rm -f -- "$TARGET_FILE"

    if ((motd_directory_preexisted == 0)); then
        debug_log "Removing installer-created directory: ${MOTD_DIRECTORY}"
        rmdir -- "$MOTD_DIRECTORY"
    fi

    complete_step
    begin_step 4 "Verifying removal..."

    if [[ -e $TARGET_FILE || -L $TARGET_FILE ]]; then
        mark_step_failed
        printf 'Installed MOTD script still exists after removal.\n' >&2
        false
    fi

    if ! verify_restored_file "$MOTD_FILE" "motd" ||
        ! verify_restored_file "$ISSUE_FILE" "issue"; then
        mark_step_failed
        printf 'Previous MOTD files were not restored correctly.\n' >&2
        false
    fi

    if ((motd_directory_preexisted == 1)); then
        for script_name in "${saved_script_names[@]}"; do
            if [[ -n $expected_enabled_output ]]; then
                expected_enabled_output+=$'\n'
            fi

            expected_enabled_output+="${MOTD_DIRECTORY}/${script_name}"
        done

        if ! enabled_output=$(run-parts --test --lsbsysinit \
            "$MOTD_DIRECTORY"); then
            mark_step_failed
            printf 'Could not verify the restored MOTD scripts.\n' >&2
            false
        fi

        if [[ $enabled_output != "$expected_enabled_output" ]]; then
            mark_step_failed
            printf 'Unexpected enabled MOTD scripts were found after removal.\n' >&2
            false
        fi
    elif [[ -e $MOTD_DIRECTORY || -L $MOTD_DIRECTORY ]]; then
        mark_step_failed
        printf 'Installer-created MOTD directory still exists.\n' >&2
        false
    fi

    debug_log "Previous MOTD configuration: restored"
    debug_log "Removing installation state: ${STATE_DIRECTORY}"

    preserve_temporary=1
    changes_started=0

    if ! rm -rf -- "$STATE_DIRECTORY"; then
        mark_step_failed
        printf 'MOTD was removed, but installation state cleanup failed.\n' >&2
        printf 'Recovery data was kept in: %s\n' \
            "$temporary_directory" >&2
        exit 1
    fi

    preserve_temporary=0
    complete_step

    trap - ERR HUP INT TERM
    print_success "${PROJECT_NAME} was uninstalled successfully."
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

for command_name in wget sha256sum run-parts sleep cmp; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        fail "required command not found: ${command_name}"
    fi
done

debug_log "Required commands: available"

if [[ -e $STATE_DIRECTORY || -L $STATE_DIRECTORY ]]; then
    if [[ -L $STATE_DIRECTORY || ! -d $STATE_DIRECTORY ||
        -L ${STATE_DIRECTORY}/installed ||
        ! -f ${STATE_DIRECTORY}/installed ]]; then
        fail "invalid installation state: ${STATE_DIRECTORY}"
    fi

    debug_log "Installation state: installed"
    prompt_installed_action

    case $selected_action in
        update)
            if ((debug_mode == 1)); then
                debug_pacing=1
            fi

            printf '\n'
            run_update
            exit 0
            ;;
        uninstall)
            if ! confirm_uninstallation; then
                printf 'Uninstallation cancelled.\n'
                exit 0
            fi

            if ((debug_mode == 1)); then
                debug_pacing=1
            fi

            printf '\n'
            run_uninstallation
            exit 0
            ;;
        cancel)
            printf 'No changes were made.\n'
            exit 0
            ;;
    esac
fi

debug_log "Installation state: not installed"

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

if ((debug_mode == 1)); then
    debug_pacing=1
fi

printf '\n'

download_and_verify_payload 1 2
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
print_success "${PROJECT_NAME} was installed successfully."
printf 'Open a new SSH or local console session to see the MOTD.\n'
