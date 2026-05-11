#!/usr/bin/env bash

# Run the validated and optimized workflows side by side, then compare the
# resulting parcellation volumes. Existing subject annotation files are restored
# after validation so the check does not leave the FreeSurfer subject directory
# in a different state.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

usage() {
    cat <<EOF

Usage:
  ${SCRIPT_NAME} -L <subject_list> -a <annotation_name> -d <validation_dir> [options]

Required arguments:
  -L <file>     Text file containing FreeSurfer subject IDs.
  -a <name>     Annotation basename without hemisphere or extension.
  -d <dir>      Validation output directory. Relative paths are created inside SUBJECTS_DIR.

Optional arguments:
  -f <int>      First row in the subject list to process. Default: 1.
  -l <int>      Last row in the subject list to process. Default: end of file.
  -j <int>      Number of subjects to process at once. Default: 1.
  -h            Show this help text.

Example:
  ${SCRIPT_NAME} -L subject_list.txt -a HCP-MMP1 -d HCPMMP_validation -f 1 -l 1

EOF
}

log() {
    printf '\n>>>> %s\n' "$*"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

is_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 > 0))
}

resolve_subject_list() {
    local requested_path="$1"

    if [[ -f "${requested_path}" ]]; then
        printf '%s\n' "${requested_path}"
        return
    fi

    if [[ -n "${SUBJECTS_DIR:-}" && -f "${SUBJECTS_DIR}/${requested_path}" ]]; then
        printf '%s\n' "${SUBJECTS_DIR}/${requested_path}"
        return
    fi

    fail "Subject list not found: ${requested_path}"
}

resolve_output_dir() {
    local requested_path="$1"

    if [[ "${requested_path}" = /* ]]; then
        printf '%s\n' "${requested_path}"
    else
        printf '%s\n' "${SUBJECTS_DIR}/${requested_path}"
    fi
}

find_python() {
    command -v python3 2>/dev/null || command -v python 2>/dev/null
}

cleanup() {
    restore_subject_annotations || true

    if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}"
    fi
}

backup_subject_annotations() {
    local subject
    local hemi
    local source
    local backup

    BACKUP_DIR="${TEMP_DIR}/annotation_backup"
    mkdir -p "${BACKUP_DIR}"

    while IFS= read -r subject || [[ -n "${subject}" ]]; do
        mkdir -p "${BACKUP_DIR}/${subject}"

        for hemi in lh rh; do
            source="${SUBJECTS_DIR}/${subject}/label/${hemi}.${subject}_${ANNOT_NAME}.annot"
            backup="${BACKUP_DIR}/${subject}/${hemi}.annot"

            if [[ -f "${source}" ]]; then
                cp "${source}" "${backup}"
            else
                : >"${BACKUP_DIR}/${subject}/${hemi}.missing"
            fi
        done
    done <"${SELECTED_SUBJECTS}"
}

restore_subject_annotations() {
    local subject
    local hemi
    local target
    local backup
    local marker

    [[ -n "${BACKUP_DIR:-}" && -d "${BACKUP_DIR}" ]] || return 0
    [[ -n "${SELECTED_SUBJECTS:-}" && -f "${SELECTED_SUBJECTS}" ]] || return 0

    while IFS= read -r subject || [[ -n "${subject}" ]]; do
        for hemi in lh rh; do
            target="${SUBJECTS_DIR}/${subject}/label/${hemi}.${subject}_${ANNOT_NAME}.annot"
            backup="${BACKUP_DIR}/${subject}/${hemi}.annot"
            marker="${BACKUP_DIR}/${subject}/${hemi}.missing"

            if [[ -f "${backup}" ]]; then
                cp "${backup}" "${target}"
            elif [[ -f "${marker}" ]]; then
                rm -f "${target}"
            fi
        done
    done <"${SELECTED_SUBJECTS}"
}

build_selected_subjects() {
    : >"${SELECTED_SUBJECTS}"

    sed -n "${FIRST_ROW},${LAST_ROW}p" "${SUBJECT_LIST_FILE}" | while IFS= read -r subject || [[ -n "${subject}" ]]; do
        subject="${subject%$'\r'}"
        [[ -z "${subject}" ]] && continue
        [[ "${subject}" =~ ^[[:space:]]*# ]] && continue
        printf '%s\n' "${subject}" >>"${SELECTED_SUBJECTS}"
    done

    [[ -s "${SELECTED_SUBJECTS}" ]] || fail "No subjects were selected from ${SUBJECT_LIST_FILE}."
}

run_workflows() {
    local subject_count

    subject_count="$(wc -l <"${SELECTED_SUBJECTS}" | tr -d '[:space:]')"

    log "Running label-by-label workflow"
    bash "${SCRIPT_DIR}/create_subj_volume_parcellation.sh" \
        -L "${SELECTED_SUBJECTS}" \
        -f 1 \
        -l "${subject_count}" \
        -a "${ANNOT_NAME}" \
        -d "${LABEL_OUTPUT_DIR}" \
        -m NO \
        -s NO \
        -t NO \
        -r YES \
        -j "${JOBS}"

    log "Running optimized direct-mapping workflow"
    bash "${SCRIPT_DIR}/create_subj_volume_parcellation_optimized.sh" \
        -L "${SELECTED_SUBJECTS}" \
        -f 1 \
        -l "${subject_count}" \
        -a "${ANNOT_NAME}" \
        -d "${DIRECT_OUTPUT_DIR}" \
        -m NO \
        -s NO \
        -t NO \
        -r YES \
        -j "${JOBS}"
}

compare_outputs() {
    local subject
    local reference
    local candidate
    local failed=0

    mkdir -p "${COMPARISON_DIR}"

    while IFS= read -r subject || [[ -n "${subject}" ]]; do
        reference="${LABEL_OUTPUT_DIR}/${subject}/${ANNOT_NAME}.nii.gz"
        candidate="${DIRECT_OUTPUT_DIR}/${subject}/${ANNOT_NAME}.nii.gz"

        log "Comparing ${subject}"
        if ! "${PYTHON_BIN}" "${SCRIPT_DIR}/compare_parcellations.py" \
            "${reference}" \
            "${candidate}" \
            --json-out "${COMPARISON_DIR}/${subject}.json" \
            --tsv-out "${COMPARISON_DIR}/${subject}.tsv"; then
            failed=1
        fi
    done <"${SELECTED_SUBJECTS}"

    return "${failed}"
}

FIRST_ROW=1
LAST_ROW=""
JOBS=1

while getopts ":L:f:l:a:d:j:h" option; do
    case "${option}" in
        L) SUBJECT_LIST_ARG="${OPTARG}" ;;
        f) FIRST_ROW="${OPTARG}" ;;
        l) LAST_ROW="${OPTARG}" ;;
        a) ANNOT_NAME="${OPTARG}" ;;
        d) OUTPUT_DIR_ARG="${OPTARG}" ;;
        j) JOBS="${OPTARG}" ;;
        h)
            usage
            exit 0
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

[[ -n "${SUBJECT_LIST_ARG:-}" ]] || { usage; fail "Missing required -L argument."; }
[[ -n "${ANNOT_NAME:-}" ]] || { usage; fail "Missing required -a argument."; }
[[ -n "${OUTPUT_DIR_ARG:-}" ]] || { usage; fail "Missing required -d argument."; }

[[ -n "${SUBJECTS_DIR:-}" ]] || fail "SUBJECTS_DIR is not set."
[[ -d "${SUBJECTS_DIR}" ]] || fail "SUBJECTS_DIR does not exist: ${SUBJECTS_DIR}"
is_positive_integer "${FIRST_ROW}" || fail "-f must be a positive integer."
is_positive_integer "${JOBS}" || fail "-j must be a positive integer."

SUBJECT_LIST_FILE="$(resolve_subject_list "${SUBJECT_LIST_ARG}")"
if [[ -z "${LAST_ROW}" ]]; then
    LAST_ROW="$(wc -l <"${SUBJECT_LIST_FILE}" | tr -d '[:space:]')"
fi
is_positive_integer "${LAST_ROW}" || fail "Subject list is empty: ${SUBJECT_LIST_FILE}"
((FIRST_ROW <= LAST_ROW)) || fail "-f cannot be greater than -l."

PYTHON_BIN="$(find_python)" || fail "Python was not found."
"${PYTHON_BIN}" "${SCRIPT_DIR}/compare_parcellations.py" --help >/dev/null
"${PYTHON_BIN}" "${SCRIPT_DIR}/hcp_mmp1_postprocess.py" check-dependencies >/dev/null ||
    fail "Validation comparison needs Python with nibabel and numpy."

OUTPUT_DIR="$(resolve_output_dir "${OUTPUT_DIR_ARG}")"
LABEL_OUTPUT_DIR="${OUTPUT_DIR}/labels"
DIRECT_OUTPUT_DIR="${OUTPUT_DIR}/direct"
COMPARISON_DIR="${OUTPUT_DIR}/comparison"
mkdir -p "${OUTPUT_DIR}"

TEMP_DIR="$(mktemp -d "${OUTPUT_DIR}/.tmp.${SCRIPT_NAME}.XXXXXX")"
SELECTED_SUBJECTS="${TEMP_DIR}/subjects.txt"
BACKUP_DIR=""
trap cleanup EXIT

build_selected_subjects
backup_subject_annotations
run_workflows

if compare_outputs; then
    log "Validation passed: optimized output matched label-by-label output."
else
    fail "Validation found differences. See ${COMPARISON_DIR} for details."
fi
