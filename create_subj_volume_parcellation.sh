#!/usr/bin/env bash

# Create a subject-space HCP-MMP1 parcellation volume from fsaverage annotation
# files. The script expects FreeSurfer subjects that have already completed
# recon-all, plus the HCP-MMP1 annotation files in fsaverage space.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"

usage() {
    cat <<EOF

Usage:
  ${SCRIPT_NAME} -L <subject_list> -a <annotation_name> -d <output_dir> [options]

Required arguments:
  -L <file>     Text file containing FreeSurfer subject IDs.
  -a <name>     Annotation basename without hemisphere or extension.
                Example: HCPMMP1 for lh.HCPMMP1.annot and rh.HCPMMP1.annot.
  -d <dir>      Output directory. Relative paths are created inside SUBJECTS_DIR.

Optional arguments:
  -f <int>      First row in the subject list to process. Default: 1.
  -l <int>      Last row in the subject list to process. Default: end of file.
  -m <YES|NO>   Create one cortical mask per region. Default: NO.
  -s <YES|NO>   Create subcortical aseg masks. Default: NO.
  -t <YES|NO>   Create anatomical stats tables. Default: YES.
  -h            Show this help text.

Examples:
  ${SCRIPT_NAME} -L subject_list.txt -a HCPMMP1 -d HCPMMP_parcellation
  ${SCRIPT_NAME} -L subject_list.txt -f 1 -l 5 -a HCPMMP1 -d HCPMMP_parcellation -m YES -s YES

EOF
}

log() {
    printf '\n>>>> %s\n' "$*"
}

info() {
    printf '  %s\n' "$*"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}"
    fi
}

is_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 > 0))
}

normalize_yes_no() {
    local flag_name="$1"
    local value="$2"

    value="$(printf '%s' "${value}" | tr '[:lower:]' '[:upper:]')"
    case "${value}" in
        YES | NO)
            printf '%s\n' "${value}"
            ;;
        *)
            fail "${flag_name} must be YES or NO, got '${value}'."
            ;;
    esac
}

require_command() {
    local command_name="$1"

    if ! command -v "${command_name}" >/dev/null 2>&1; then
        fail "Required command '${command_name}' was not found in PATH."
    fi
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

find_color_lut() {
    if [[ -f "${SUBJECTS_DIR}/FreeSurferColorLUT.txt" ]]; then
        printf '%s\n' "${SUBJECTS_DIR}/FreeSurferColorLUT.txt"
        return
    fi

    if [[ -n "${FREESURFER_HOME:-}" && -f "${FREESURFER_HOME}/FreeSurferColorLUT.txt" ]]; then
        printf '%s\n' "${FREESURFER_HOME}/FreeSurferColorLUT.txt"
        return
    fi

    return 1
}

ensure_annotation_files() {
    local fsaverage_label_dir="${SUBJECTS_DIR}/fsaverage/label"
    local hemi
    local target
    local fallback

    [[ -d "${fsaverage_label_dir}" ]] || fail "Expected fsaverage labels at ${fsaverage_label_dir}."
    [[ -f "${SUBJECTS_DIR}/fsaverage/surf/lh.white" ]] || fail "fsaverage is missing surf/lh.white."
    [[ -f "${SUBJECTS_DIR}/fsaverage/surf/rh.white" ]] || fail "fsaverage is missing surf/rh.white."
    [[ -f "${SUBJECTS_DIR}/fsaverage/surf/lh.sphere.reg" ]] || fail "fsaverage is missing surf/lh.sphere.reg."
    [[ -f "${SUBJECTS_DIR}/fsaverage/surf/rh.sphere.reg" ]] || fail "fsaverage is missing surf/rh.sphere.reg."

    for hemi in lh rh; do
        target="${fsaverage_label_dir}/${hemi}.${ANNOT_NAME}.annot"
        fallback="${SUBJECTS_DIR}/${hemi}.${ANNOT_NAME}.annot"

        if [[ -f "${target}" ]]; then
            continue
        fi

        if [[ -f "${fallback}" ]]; then
            info "Copying ${hemi}.${ANNOT_NAME}.annot into fsaverage/label."
            cp "${fallback}" "${fsaverage_label_dir}/"
        else
            fail "Missing ${hemi}.${ANNOT_NAME}.annot in ${fsaverage_label_dir} or ${SUBJECTS_DIR}."
        fi
    done
}

build_region_metadata() {
    local atlas_label_dir="${OUTPUT_DIR}/label"
    local hemi
    local base
    local ctab_file
    local clean_ctab_file
    local log_file

    log "Reading annotation metadata from fsaverage"
    mkdir -p "${atlas_label_dir}" "${OUTPUT_DIR}/logs"

    : >"${MASTER_LUT}"
    : >"${REGION_TABLE}"
    printf 'index\tlabel_file\tregion_name\n' >"${MASTER_LUT}"
    printf 'index\themi\tregion_name\tlabel_file\n' >"${REGION_TABLE}"

    for hemi in lh rh; do
        if [[ "${hemi}" == "lh" ]]; then
            base=1000
        else
            base=2000
        fi

        ctab_file="${TEMP_DIR}/${hemi}.${ANNOT_NAME}.raw.ctab"
        clean_ctab_file="$(ctab_for_hemi "${hemi}")"
        log_file="${OUTPUT_DIR}/logs/mri_annotation2label_${hemi}.log"

        : >"${clean_ctab_file}"

        mri_annotation2label \
            --subject fsaverage \
            --hemi "${hemi}" \
            --annotation "${ANNOT_NAME}" \
            --outdir "${atlas_label_dir}" \
            --ctab "${ctab_file}" \
            >"${log_file}" 2>&1

        awk \
            -v base="${base}" \
            -v hemi="${hemi}" \
            -v label_dir="${atlas_label_dir}" \
            -v clean_ctab="${clean_ctab_file}" \
            -v master_lut="${MASTER_LUT}" \
            -v region_table="${REGION_TABLE}" '
            NF >= 6 && $1 ~ /^[0-9]+$/ {
                region_name = $2

                if ($1 == 0 || tolower(region_name) == "unknown" || region_name == "???") {
                    next
                }

                label_file = hemi "." region_name ".label"
                label_path = label_dir "/" label_file

                if ((getline first_line < label_path) >= 0) {
                    close(label_path)
                    local_index++
                    final_index = base + local_index
                    printf "%d\t%s\t%s\t%s\t%s\t%s\n", local_index, region_name, $3, $4, $5, $6 >> clean_ctab
                    printf "%d\t%s\t%s\n", final_index, label_file, region_name >> master_lut
                    printf "%d\t%s\t%s\t%s\n", final_index, hemi, region_name, label_file >> region_table
                }
            }
        ' "${ctab_file}"
    done
}

ctab_for_hemi() {
    local hemi="$1"

    printf '%s/%s.%s.label2annot.ctab\n' "${TEMP_DIR}" "${hemi}" "${ANNOT_NAME}"
}

subject_annotation_path() {
    local subject="$1"
    local hemi="$2"

    printf '%s/%s/label/%s.%s_%s.annot\n' \
        "${SUBJECTS_DIR}" "${subject}" "${hemi}" "${subject}" "${ANNOT_NAME}"
}

map_annotations_direct_to_subject() {
    local subject="$1"
    local subject_output_dir="$2"
    local hemi
    local source_annot
    local subject_annot
    local output_copy
    local log_file

    mkdir -p "${subject_output_dir}/label" "${subject_output_dir}/logs"

    for hemi in lh rh; do
        source_annot="${SUBJECTS_DIR}/fsaverage/label/${hemi}.${ANNOT_NAME}.annot"
        subject_annot="$(subject_annotation_path "${subject}" "${hemi}")"
        output_copy="${subject_output_dir}/label/${hemi}.${subject}_${ANNOT_NAME}.annot"
        log_file="${subject_output_dir}/logs/mri_surf2surf_${hemi}.log"

        if [[ -f "${subject_annot}" ]]; then
            info "Using existing ${hemi} annotation for ${subject}."
            cp "${subject_annot}" "${output_copy}"
            continue
        fi

        if [[ -f "${output_copy}" ]]; then
            info "Restoring ${hemi} annotation for ${subject} from the output folder."
            cp "${output_copy}" "${subject_annot}"
            continue
        fi

        info "Mapping ${hemi} annotation to ${subject}."
        mri_surf2surf \
            --srcsubject fsaverage \
            --trgsubject "${subject}" \
            --hemi "${hemi}" \
            --sval-annot "${source_annot}" \
            --tval "${subject_annot}" \
            >"${log_file}" 2>&1

        cp "${subject_annot}" "${output_copy}"
    done
}

map_labels_to_subject() {
    local subject="$1"
    local subject_output_dir="$2"
    local hemi
    local final_index
    local region_hemi
    local region_name
    local label_file
    local source_label
    local target_label
    local subject_annot
    local output_copy
    local log_file
    local ctab_file
    local -a label_args

    mkdir -p "${subject_output_dir}/label" "${subject_output_dir}/logs"

    for hemi in lh rh; do
        subject_annot="$(subject_annotation_path "${subject}" "${hemi}")"
        output_copy="${subject_output_dir}/label/${hemi}.${subject}_${ANNOT_NAME}.annot"

        if [[ -f "${subject_annot}" ]]; then
            info "Using existing ${hemi} annotation for ${subject}."
            cp "${subject_annot}" "${output_copy}"
            continue
        fi

        label_args=()
        log_file="${subject_output_dir}/logs/mri_label2label_${hemi}.log"
        : >"${log_file}"

        while IFS=$'\t' read -r final_index region_hemi region_name label_file; do
            [[ "${final_index}" == "index" ]] && continue
            [[ "${region_hemi}" == "${hemi}" ]] || continue

            source_label="${OUTPUT_DIR}/label/${label_file}"
            target_label="${subject_output_dir}/label/${label_file}"

            info "Mapping ${label_file} to ${subject}."
            mri_label2label \
                --srcsubject fsaverage \
                --srclabel "${source_label}" \
                --trgsubject "${subject}" \
                --trglabel "${target_label}" \
                --regmethod surface \
                --hemi "${hemi}" \
                >>"${log_file}" 2>&1

            label_args+=(--l "${target_label}")
        done <"${REGION_TABLE}"

        ((${#label_args[@]} > 0)) || fail "No ${hemi} labels were available for ${subject}."

        ctab_file="$(ctab_for_hemi "${hemi}")"
        log_file="${subject_output_dir}/logs/mris_label2annot_${hemi}.log"

        mris_label2annot \
            --s "${subject}" \
            --h "${hemi}" \
            "${label_args[@]}" \
            --a "${subject}_${ANNOT_NAME}" \
            --ctab "${ctab_file}" \
            >"${log_file}" 2>&1

        cp "${subject_annot}" "${output_copy}"
    done
}

map_annotations_to_subject() {
    local subject="$1"
    local subject_output_dir="$2"

    if [[ "${MAPPING_MODE}" == "direct" ]]; then
        map_annotations_direct_to_subject "${subject}" "${subject_output_dir}"
    else
        map_labels_to_subject "${subject}" "${subject_output_dir}"
    fi
}

create_volume() {
    local subject="$1"
    local subject_output_dir="$2"
    local raw_volume="${TEMP_DIR}/${subject}_${ANNOT_NAME}_raw.nii.gz"
    local final_volume="${subject_output_dir}/${ANNOT_NAME}.nii.gz"
    local log_file="${subject_output_dir}/logs/mri_aparc2aseg.log"

    info "Creating parcellation volume."
    mri_aparc2aseg \
        --s "${subject}" \
        --o "${raw_volume}" \
        --annot "${subject}_${ANNOT_NAME}" \
        >"${log_file}" 2>&1

    apply_hippocampus_fix "${raw_volume}" "${final_volume}" "${subject}"
}

roi_index() {
    local region_name="$1"

    awk -v region_name="${region_name}" '$3 == region_name { print $1; exit }' "${MASTER_LUT}"
}

apply_hippocampus_fix() {
    local input_volume="$1"
    local output_volume="$2"
    local subject="$3"
    local current_volume="${input_volume}"
    local left_index
    local right_index
    local hcp_mask
    local fs_mask
    local updated_volume

    left_index="$(roi_index "L_H_ROI")"
    right_index="$(roi_index "R_H_ROI")"

    if [[ -z "${left_index}" && -z "${right_index}" ]]; then
        warn "No H_ROI labels found for ${subject}; copying volume without hippocampus reassignment."
        cp "${input_volume}" "${output_volume}"
        return
    fi

    info "Reassigning H_ROI voxels to FreeSurfer hippocampus IDs."

    if [[ -n "${left_index}" ]]; then
        hcp_mask="${TEMP_DIR}/${subject}_left_h_roi.nii.gz"
        fs_mask="${TEMP_DIR}/${subject}_left_fs_hippocampus.nii.gz"
        updated_volume="${TEMP_DIR}/${subject}_after_left_hippocampus.nii.gz"

        fslmaths "${current_volume}" -thr "${left_index}" -uthr "${left_index}" "${hcp_mask}"
        fslmaths "${hcp_mask}" -bin -mul 17 "${fs_mask}"
        fslmaths "${current_volume}" -sub "${hcp_mask}" -add "${fs_mask}" "${updated_volume}"
        current_volume="${updated_volume}"
    fi

    if [[ -n "${right_index}" ]]; then
        hcp_mask="${TEMP_DIR}/${subject}_right_h_roi.nii.gz"
        fs_mask="${TEMP_DIR}/${subject}_right_fs_hippocampus.nii.gz"
        updated_volume="${TEMP_DIR}/${subject}_after_right_hippocampus.nii.gz"

        fslmaths "${current_volume}" -thr "${right_index}" -uthr "${right_index}" "${hcp_mask}"
        fslmaths "${hcp_mask}" -bin -mul 53 "${fs_mask}"
        fslmaths "${current_volume}" -sub "${hcp_mask}" -add "${fs_mask}" "${updated_volume}"
        current_volume="${updated_volume}"
    fi

    cp "${current_volume}" "${output_volume}"
}

create_cortical_masks() {
    local subject_output_dir="$1"
    local final_volume="${subject_output_dir}/${ANNOT_NAME}.nii.gz"
    local mask_dir="${subject_output_dir}/masks"
    local index
    local hemi
    local region_name
    local label_file

    info "Creating cortical region masks."
    mkdir -p "${mask_dir}"

    tail -n +2 "${REGION_TABLE}" | while IFS=$'\t' read -r index hemi region_name label_file; do
        case "${region_name}" in
            L_H_ROI | R_H_ROI)
                continue
                ;;
        esac

        fslmaths "${final_volume}" \
            -thr "${index}" \
            -uthr "${index}" \
            -bin "${mask_dir}/${region_name}.nii.gz"
    done
}

lut_index_for_name() {
    local structure_name="$1"
    local index

    index="$(awk -v name="${structure_name}" '$2 == name { print $1; exit }' "${COLOR_LUT}")"
    [[ -n "${index}" ]] || return 1

    printf '%s\n' "${index}"
}

create_aseg_mask() {
    local final_volume="$1"
    local aseg_mask_dir="$2"
    local structure_name="$3"
    local fs_index

    if ! fs_index="$(lut_index_for_name "${structure_name}")"; then
        warn "Could not find '${structure_name}' in ${COLOR_LUT}; skipping."
        return
    fi

    fslmaths "${final_volume}" \
        -thr "${fs_index}" \
        -uthr "${fs_index}" \
        -bin "${aseg_mask_dir}/${structure_name}.nii.gz"
}

create_aseg_masks() {
    local subject_output_dir="$1"
    local final_volume="${subject_output_dir}/${ANNOT_NAME}.nii.gz"
    local aseg_mask_dir="${subject_output_dir}/aseg_masks"
    local side
    local structure
    local thalamus_name

    info "Creating subcortical aseg masks."
    mkdir -p "${aseg_mask_dir}"

    for side in Left Right; do
        if lut_index_for_name "${side}-Thalamus-Proper" >/dev/null; then
            thalamus_name="${side}-Thalamus-Proper"
        else
            thalamus_name="${side}-Thalamus"
        fi

        create_aseg_mask "${final_volume}" "${aseg_mask_dir}" "${thalamus_name}"

        for structure in Caudate Pallidum Hippocampus Amygdala Accumbens-area; do
            create_aseg_mask "${final_volume}" "${aseg_mask_dir}" "${side}-${structure}"
        done
    done
}

create_stats_tables() {
    local subject="$1"
    local subject_output_dir="$2"
    local hemi
    local subject_annot
    local stats_file
    local log_file

    info "Creating anatomical stats tables."
    mkdir -p "${subject_output_dir}/tables"

    for hemi in lh rh; do
        subject_annot="$(subject_annotation_path "${subject}" "${hemi}")"
        stats_file="${subject_output_dir}/tables/table_${hemi}.txt"
        log_file="${subject_output_dir}/logs/mris_anatomical_stats_${hemi}.log"

        mris_anatomical_stats \
            -a "${subject_annot}" \
            -f "${stats_file}" \
            "${subject}" "${hemi}" \
            >"${log_file}" 2>&1
    done
}

validate_subject() {
    local subject="$1"
    local subject_dir="${SUBJECTS_DIR}/${subject}"
    local required_file

    [[ -d "${subject_dir}" ]] || fail "Subject '${subject}' was not found in ${SUBJECTS_DIR}."
    [[ -d "${subject_dir}/label" ]] || fail "Subject '${subject}' is missing a label directory."

    for required_file in \
        mri/aseg.mgz \
        mri/ribbon.mgz \
        surf/lh.white \
        surf/lh.pial \
        surf/lh.sphere.reg \
        surf/rh.white \
        surf/rh.pial \
        surf/rh.sphere.reg; do
        [[ -f "${subject_dir}/${required_file}" ]] || fail "Subject '${subject}' is missing ${required_file}. Run recon-all first."
    done
}

process_subjects() {
    local subject
    local subject_output_dir
    local started_at
    local subjects_to_process="${TEMP_DIR}/subjects_to_process.txt"

    sed -n "${FIRST_ROW},${LAST_ROW}p" "${SUBJECT_LIST_FILE}" >"${subjects_to_process}"

    while IFS= read -r subject || [[ -n "${subject}" ]]; do
        subject="${subject%$'\r'}"
        [[ -z "${subject}" ]] && continue
        [[ "${subject}" =~ ^[[:space:]]*# ]] && continue

        started_at="$(date)"
        subject_output_dir="${OUTPUT_DIR}/${subject}"

        log "Processing ${subject}"
        validate_subject "${subject}"
        mkdir -p "${subject_output_dir}/logs"

        cp "${MASTER_LUT}" "${subject_output_dir}/LUT_${ANNOT_NAME}.txt"
        sed -i.bak '/_H_ROI/d' "${subject_output_dir}/LUT_${ANNOT_NAME}.txt"
        rm -f "${subject_output_dir}/LUT_${ANNOT_NAME}.txt.bak"

        map_annotations_to_subject "${subject}" "${subject_output_dir}"
        create_volume "${subject}" "${subject_output_dir}"

        if [[ "${CREATE_MASKS}" == "YES" ]]; then
            create_cortical_masks "${subject_output_dir}"
        fi

        if [[ "${CREATE_ASEG}" == "YES" ]]; then
            create_aseg_masks "${subject_output_dir}"
        fi

        if [[ "${GET_STATS}" == "YES" ]]; then
            create_stats_tables "${subject}" "${subject_output_dir}"
        fi

        info "${subject} started at ${started_at}; finished at $(date)."
    done <"${subjects_to_process}"
}

FIRST_ROW=1
LAST_ROW=""
CREATE_MASKS=NO
CREATE_ASEG=NO
GET_STATS=YES
MAPPING_MODE="${HCPMMP1_MAPPING_MODE:-labels}"

while getopts ":L:f:l:a:d:m:t:s:h" option; do
    case "${option}" in
        L) SUBJECT_LIST_ARG="${OPTARG}" ;;
        f) FIRST_ROW="${OPTARG}" ;;
        l) LAST_ROW="${OPTARG}" ;;
        a) ANNOT_NAME="${OPTARG}" ;;
        d) OUTPUT_DIR_ARG="${OPTARG}" ;;
        m) CREATE_MASKS="${OPTARG}" ;;
        t) GET_STATS="${OPTARG}" ;;
        s) CREATE_ASEG="${OPTARG}" ;;
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
[[ -n "${FREESURFER_HOME:-}" ]] || fail "FREESURFER_HOME is not set. Source FreeSurfer's setup script before running."
[[ -d "${FREESURFER_HOME}" ]] || fail "FREESURFER_HOME does not exist: ${FREESURFER_HOME}"

is_positive_integer "${FIRST_ROW}" || fail "-f must be a positive integer."
if [[ -n "${LAST_ROW}" ]]; then
    is_positive_integer "${LAST_ROW}" || fail "-l must be a positive integer."
fi

CREATE_MASKS="$(normalize_yes_no "-m" "${CREATE_MASKS}")"
CREATE_ASEG="$(normalize_yes_no "-s" "${CREATE_ASEG}")"
GET_STATS="$(normalize_yes_no "-t" "${GET_STATS}")"

case "${MAPPING_MODE}" in
    labels | direct)
        ;;
    *)
        fail "HCPMMP1_MAPPING_MODE must be 'labels' or 'direct', got '${MAPPING_MODE}'."
        ;;
esac

SUBJECT_LIST_FILE="$(resolve_subject_list "${SUBJECT_LIST_ARG}")"
if [[ -z "${LAST_ROW}" ]]; then
    LAST_ROW="$(wc -l <"${SUBJECT_LIST_FILE}" | tr -d '[:space:]')"
fi
is_positive_integer "${LAST_ROW}" || fail "Subject list is empty: ${SUBJECT_LIST_FILE}"

((FIRST_ROW <= LAST_ROW)) || fail "-f cannot be greater than -l."

OUTPUT_DIR="$(resolve_output_dir "${OUTPUT_DIR_ARG}")"
mkdir -p "${OUTPUT_DIR}"

TEMP_DIR="$(mktemp -d "${OUTPUT_DIR}/.tmp.${SCRIPT_NAME}.XXXXXX")"
trap cleanup EXIT

MASTER_LUT="${TEMP_DIR}/LUT_${ANNOT_NAME}.tsv"
REGION_TABLE="${TEMP_DIR}/regions_${ANNOT_NAME}.tsv"
COLOR_LUT=""

require_command mri_annotation2label
require_command mri_aparc2aseg
require_command fslmaths

if [[ "${GET_STATS}" == "YES" ]]; then
    require_command mris_anatomical_stats
fi

if [[ "${MAPPING_MODE}" == "direct" ]]; then
    require_command mri_surf2surf
    warn "Using experimental direct annotation mapping. Validate outputs before production use."
else
    require_command mri_label2label
    require_command mris_label2annot
fi

if [[ "${CREATE_ASEG}" == "YES" ]]; then
    if COLOR_LUT="$(find_color_lut)"; then
        info "Using FreeSurfer color LUT: ${COLOR_LUT}"
    else
        warn "FreeSurferColorLUT.txt was not found; subcortical masks will be skipped."
        CREATE_ASEG=NO
    fi
fi

log "SUBJECTS_DIR: ${SUBJECTS_DIR}"
log "Output directory: ${OUTPUT_DIR}"
log "Mapping mode: ${MAPPING_MODE}"

ensure_annotation_files
build_region_metadata
process_subjects

log "Processing complete"
