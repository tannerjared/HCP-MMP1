#!/usr/bin/env bash

# Refactored and Optimized Parcellation Script
# Original by CJNeurolab / Hugo C Baggio & Alexandra Abos
# Optimized version

# stricter error handling
set -e
set -o pipefail

# ------------------------------------------------------------------------------
# Functions
# ------------------------------------------------------------------------------

usage() {
    cat << EOF

Usage: $(basename "$0") -L <subject_list> -a <annot_name> -d <output_dir> [options]

Compulsory arguments:
  -L <file>   Text file containing subject IDs (must match folder names in \$SUBJECTS_DIR)
  -a <name>   Input annotation name (e.g., HCPMMP1). Must exist in fsaverage/label
  -d <dir>    Output directory name (created inside \$SUBJECTS_DIR)

Optional arguments:
  -f <int>    First row in subject list to process (default: 1)
  -l <int>    Last row in subject list to process (default: end of list)
  -m <YES/NO> Create individual .nii.gz masks for cortical regions (default: NO)
  -s <YES/NO> Create individual masks for subcortical aseg regions (default: NO)
  -t <YES/NO> Generate anatomical stats tables (default: YES)

EOF
    exit 1
}

check_dependencies() {
    local deps=("mri_annotation2label" "mri_surf2surf" "mris_label2annot" "mri_aparc2aseg" "fslmaths" "bc")
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "Error: Required command '$cmd' not found in PATH."
            exit 1
        fi
    done

    if [ -z "${SUBJECTS_DIR:-}" ]; then
        echo "Error: \$SUBJECTS_DIR is not set."
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Argument Parsing
# ------------------------------------------------------------------------------

# Defaults
FIRST_ROW=1
LAST_ROW=""
CREATE_MASKS="NO"
CREATE_ASEG="NO"
GET_STATS="YES"

while getopts ":L:f:l:a:d:m:t:s:" o; do
    case "${o}" in
        L) SUBJ_LIST_FILE=${OPTARG} ;;
        f) FIRST_ROW=${OPTARG} ;;
        l) LAST_ROW=${OPTARG} ;;
        a) ANNOT_NAME=${OPTARG} ;;
        d) OUT_DIR_NAME=${OPTARG} ;;
        m) CREATE_MASKS=${OPTARG} ;;
        t) GET_STATS=${OPTARG} ;;
        s) CREATE_ASEG=${OPTARG} ;;
        *) usage ;;
    esac
done

# Check compulsory args
if [ -z "${SUBJ_LIST_FILE:-}" ] || [ -z "${ANNOT_NAME:-}" ] || [ -z "${OUT_DIR_NAME:-}" ]; then
    usage
fi

check_dependencies

# Setup paths
FULL_OUTPUT_DIR="${SUBJECTS_DIR}/${OUT_DIR_NAME}"
TEMP_DIR="${FULL_OUTPUT_DIR}/temp_processing_${RANDOM}"

# Calculate last row if not set
if [ -z "${LAST_ROW}" ]; then
    LAST_ROW=$(wc -l < "${SUBJ_LIST_FILE}")
fi

printf "\n>>>> Current FreeSurfer subjects folder: %s\n" "$SUBJECTS_DIR"
printf ">>>> Output Directory: %s\n" "$FULL_OUTPUT_DIR"

# Check ColorLUT if needed
if [[ "${CREATE_ASEG}" == "YES" ]] && [[ ! -e "${SUBJECTS_DIR}/FreeSurferColorLUT.txt" ]]; then
    echo "WARNING: FreeSurferColorLUT.txt not found. Subcortical masks will skipped."
    CREATE_ASEG="NO"
fi

mkdir -p "${FULL_OUTPUT_DIR}/label"
mkdir -p "${TEMP_DIR}"

# ------------------------------------------------------------------------------
# Pre-processing: Generate LUT and Color Tables from fsaverage
# ------------------------------------------------------------------------------

echo ">>>> Generating LUTs from fsaverage..."

# Ensure fsaverage has the annotation
for hemi in lh rh; do
    if [[ ! -e "${SUBJECTS_DIR}/fsaverage/label/${hemi}.${ANNOT_NAME}.annot" ]]; then
        # Try copying from base dir if not in fsaverage
        if [[ -e "${SUBJECTS_DIR}/${hemi}.${ANNOT_NAME}.annot" ]]; then
            cp "${SUBJECTS_DIR}/${hemi}.${ANNOT_NAME}.annot" "${SUBJECTS_DIR}/fsaverage/label/"
        else
            echo "Error: Annotation ${hemi}.${ANNOT_NAME}.annot not found in fsaverage/label or SUBJECTS_DIR."
            exit 1
        fi
    fi
done

# Convert annotation to label and get colortabs (Just to generate the LUT logic)
# Note: We are doing this to extract region names to build the custom numbered LUT
for hemi in lh rh; do
    mri_annotation2label --subject fsaverage --hemi ${hemi} \
        --annotation "${ANNOT_NAME}" \
        --ctab "${TEMP_DIR}/ctab_${hemi}_raw.txt" \
        > /dev/null
done

# Clean ctabs (remove index column)
awk '{$1=""; print $0}' "${TEMP_DIR}/ctab_lh_raw.txt" | sed 's/^ //' > "${TEMP_DIR}/ctab_lh_names.txt"
awk '{$1=""; print $0}' "${TEMP_DIR}/ctab_rh_raw.txt" | sed 's/^ //' > "${TEMP_DIR}/ctab_rh_names.txt"

# Generate new LUTs with the 1000/2000 offsets
# Left Hemi (Starts at 1001)
awk -v base=1000 '{print base + NR, $1, $2, $3, $4, $5}' "${TEMP_DIR}/ctab_lh_names.txt" > "${TEMP_DIR}/LUT_lh.txt"
# Right Hemi (Starts at 2001)
awk -v base=2000 '{print base + NR, $1, $2, $3, $4, $5}' "${TEMP_DIR}/ctab_rh_names.txt" > "${TEMP_DIR}/LUT_rh.txt"

# Combine for Master LUT
cat "${TEMP_DIR}/LUT_lh.txt" "${TEMP_DIR}/LUT_rh.txt" > "${TEMP_DIR}/LUT_MASTER.txt"

# We also need a version without the color info for simple list iteration
awk '{print $2}' "${TEMP_DIR}/LUT_lh.txt" > "${TEMP_DIR}/list_lh_regions.txt"
awk '{print $2}' "${TEMP_DIR}/LUT_rh.txt" > "${TEMP_DIR}/list_rh_regions.txt"

# ------------------------------------------------------------------------------
# Subject Loop
# ------------------------------------------------------------------------------

# Extract subset of subjects
sed -n "${FIRST_ROW},${LAST_ROW} p" "${SUBJ_LIST_FILE}" > "${TEMP_DIR}/processing_list.txt"

while IFS= read -r subject; do
    # Skip empty lines
    [ -z "$subject" ] && continue

    printf "\n>>>> PROCESSING SUBJECT: %s\n" "${subject}"
    
    SUBJ_OUT_DIR="${FULL_OUTPUT_DIR}/${subject}"
    mkdir -p "${SUBJ_OUT_DIR}/label"
    
    # Save Subject Specific LUT (Removing H_ROI residue lines if desired, keeping logic from original)
    sed '/_H_ROI/d' "${TEMP_DIR}/LUT_MASTER.txt" > "${SUBJ_OUT_DIR}/LUT_${ANNOT_NAME}.txt"

    # 1. Map Annotation (Optimized: mri_surf2surf instead of loop)
    # -----------------------------------------------------------
    for hemi in lh rh; do
        tgt_annot="${SUBJ_OUT_DIR}/label/${hemi}.${subject}_${ANNOT_NAME}.annot"
        
        # Only process if output doesn't exist
        if [[ ! -e "${tgt_annot}" ]]; then
            echo "  Mapping ${hemi} annotation..."
            # Using mri_surf2surf to map the annotation file directly
            mri_surf2surf \
                --srcsubject fsaverage \
                --trgsubject "${subject}" \
                --hemi "${hemi}" \
                --sval-annot "${SUBJECTS_DIR}/fsaverage/label/${hemi}.${ANNOT_NAME}.annot" \
                --tval "${tgt_annot}" \
                > "${SUBJ_OUT_DIR}/log_surf2surf_${hemi}.txt" 2>&1
            
            # Copy to standard FS location as requested by original script logic
            # (Be careful not to overwrite if user has manual edits, but script says it puts them there)
            cp "${tgt_annot}" "${SUBJECTS_DIR}/${subject}/label/${hemi}.${subject}_${ANNOT_NAME}.annot"
        else
            echo "  Annotation ${hemi} already exists. Skipping."
        fi
    done

    # 2. Convert Annotation to Volume (aparc2aseg)
    # -----------------------------------------------------------
    # We must construct a ctab file that matches the LUT IDs we generated earlier 
    # so aparc2aseg assigns the correct integers.
    # mri_surf2surf preserves names. aparc2aseg maps names->integers based on --ctab
    
    echo "  Creating Volume..."
    mri_aparc2aseg \
        --s "${subject}" \
        --o "${TEMP_DIR}/${subject}_${ANNOT_NAME}.nii.gz" \
        --annot "${subject}_${ANNOT_NAME}" \
        --ctab "${TEMP_DIR}/LUT_MASTER.txt" \
        > "${SUBJ_OUT_DIR}/log_aparc2aseg.txt" 2>&1

    # 3. Hippocampus Fix (Preserved from original logic)
    # -----------------------------------------------------------
    # Finds ROI indices for L_H_ROI / R_H_ROI and re-assigns them to FS Hippocampus IDs (17/53)
    echo "  Applying Hippocampus fix..."
    
    # Get IDs from the Master LUT
    L_H_IDX=$(grep 'L_H_ROI.label' "${TEMP_DIR}/LUT_MASTER.txt" | awk '{print $1}')
    R_H_IDX=$(grep 'R_H_ROI.label' "${TEMP_DIR}/LUT_MASTER.txt" | awk '{print $1}')
    
    # Define working volume
    VOL="${TEMP_DIR}/${subject}_${ANNOT_NAME}.nii.gz"
    FIXED_VOL="${SUBJ_OUT_DIR}/${ANNOT_NAME}.nii.gz"
    
    # Temporary images
    TMP_H="${TEMP_DIR}/hipp_calc"

    # If the ROI exists in the LUT, process it. Otherwise skip.
    if [[ -n "$L_H_IDX" ]]; then
        # Extract L_H_ROI, binarize, multiply by 17 (Left Hippocampus FS ID)
        fslmaths "$VOL" -thr "$L_H_IDX" -uthr "$L_H_IDX" -bin -mul 17 "${TMP_H}_L"
        # Remove L_H_ROI from original
        fslmaths "$VOL" -thr "$L_H_IDX" -uthr "$L_H_IDX" -bin -mul -1 -add 1 -mul "$VOL" "$VOL"
        # Add corrected 17s back in
        fslmaths "$VOL" -add "${TMP_H}_L" "$VOL"
    fi

    if [[ -n "$R_H_IDX" ]]; then
        fslmaths "$VOL" -thr "$R_H_IDX" -uthr "$R_H_IDX" -bin -mul 53 "${TMP_H}_R"
        fslmaths "$VOL" -thr "$R_H_IDX" -uthr "$R_H_IDX" -bin -mul -1 -add 1 -mul "$VOL" "$VOL"
        fslmaths "$VOL" -add "${TMP_H}_R" "$VOL"
    fi
    
    # Move final volume
    mv "$VOL" "$FIXED_VOL"

    # 4. Individual Masks (Optional)
    # -----------------------------------------------------------
    if [[ "${CREATE_MASKS}" == "YES" ]]; then
        echo "  Creating individual masks (this may take time)..."
        mkdir -p "${SUBJ_OUT_DIR}/masks"
        
        # Read LUT line by line
        while read -r line; do
            id=$(echo "$line" | awk '{print $1}')
            name=$(echo "$line" | awk '{print $2}')
            
            # Skip Hippocampus ROIs if they were fixed
            if [[ "$name" == "L_H_ROI.label" ]] || [[ "$name" == "R_H_ROI.label" ]]; then continue; fi
            
            fslmaths "$FIXED_VOL" -thr "$id" -uthr "$id" -bin "${SUBJ_OUT_DIR}/masks/${name}"
        done < "${TEMP_DIR}/LUT_MASTER.txt"
    fi

    # 5. Aseg Masks (Optional)
    # -----------------------------------------------------------
    if [[ "${CREATE_ASEG}" == "YES" ]]; then
        echo "  Creating subcortical masks..."
        mkdir -p "${SUBJ_OUT_DIR}/aseg_masks"
        
        # Defined list of structures
        structures=("Thalamus-Proper" "Caudate" "Pallidum" "Hippocampus" "Amygdala" "Accumbens-area")
        
        for side in Left Right; do
            for struct in "${structures[@]}"; do
                full_name="${side}-${struct}"
                # Get ID from standard FS LUT
                fs_id=$(grep " ${full_name} " "${SUBJECTS_DIR}/FreeSurferColorLUT.txt" | awk '{print $1}')
                
                if [[ -n "$fs_id" ]]; then
                    fslmaths "$FIXED_VOL" -thr "$fs_id" -uthr "$fs_id" -bin "${SUBJ_OUT_DIR}/aseg_masks/${full_name}"
                fi
            done
        done
    fi

    # 6. Anatomical Stats (Optimized)
    # -----------------------------------------------------------
    if [[ "${GET_STATS}" == "YES" ]]; then
        echo "  Generating stats tables..."
        mkdir -p "${SUBJ_OUT_DIR}/tables"
        
        for hemi in lh rh; do
            # Use -f flag to generate a clean table file, avoiding sed/grep/awk parsing hell
            mris_anatomical_stats \
                -a "${SUBJECTS_DIR}/${subject}/label/${hemi}.${subject}_${ANNOT_NAME}.annot" \
                -b "${subject}" \
                -f "${SUBJ_OUT_DIR}/tables/${hemi}_stats.txt" \
                "${hemi}" > /dev/null
        done
    fi

done < "${TEMP_DIR}/processing_list.txt"

# Cleanup
rm -rf "${TEMP_DIR}"
echo ">>>> Processing Complete."