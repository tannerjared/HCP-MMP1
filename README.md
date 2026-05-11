# HCP-MMP1 Subject-Space Volume Parcellation

This repository contains a Bash workflow for creating subject-space NIfTI
volumes from the HCP-MMP1.0 fsaverage annotation files. It maps the left and
right hemisphere annotations to each FreeSurfer subject, converts the mapped
annotations to a combined volume, and optionally writes per-region masks and
anatomical stats tables.

The script is based on the CJ Neurolab workflow by Hugo C. Baggio and Alexandra
Abos. The maintained script keeps the original label-by-label mapping workflow
as the default path, but the implementation is cleaned up and easier to inspect.
Validation and post-processing helpers are included so the optimized path can be
checked against the default path before it is used for analysis.

## What Changed

- `create_subj_volume_parcellation.sh` is the main maintained script.
- `create_subj_volume_parcellation_optimized.sh` is an experimental
  entry point because the newer optimized approach has not been fully validated.
  Limited testing has produced the same results as the default method, but
  verify it with your own data before using it for analysis.
- The default script still maps labels with `mri_label2label` and rebuilds
  annotations with `mris_label2annot`, matching the established CJ Neurolab
  workflow more closely.
- The optimized entry point enables FreeSurfer's direct annotation mapping with
  `mri_surf2surf --sval-annot`, which may be faster but should be validated
  before production use.
- Anatomical stats tables are written directly with `mris_anatomical_stats -f`
  instead of post-processing command output with many `sed`, `grep`, and `awk`
  steps.
- Temporary files are created in a private scratch directory and removed
  automatically.
- Inputs, required tools, and missing subject data are checked before each
  subject is processed.
- Empty labels emitted by `mri_annotation2label` are skipped so the
  label-by-label workflow does not stop on regions with zero fsaverage vertices.
- `validate_optimized_output.sh` runs the default and optimized workflows into
  separate folders and compares the resulting NIfTI volumes.
- Python post-processing is used automatically when `nibabel` and `numpy` are
  available. It reduces repeated `fslmaths` calls for hippocampus reassignment
  and mask generation. If Python dependencies are unavailable, the script falls
  back to `fslmaths`.
- Subjects can be processed in parallel with `-j`.

## Requirements

- Bash.
- FreeSurfer with `FREESURFER_HOME` and `SUBJECTS_DIR` set.
- A completed FreeSurfer `recon-all` directory for each subject.
- The `fsaverage` subject in `$SUBJECTS_DIR/fsaverage`.
- Either Python with `nibabel` and `numpy`, or FSL's `fslmaths`, for
  hippocampus reassignment and optional masks.
- Python with `nibabel` and `numpy` for `validate_optimized_output.sh` and
  `compare_parcellations.py`.
- HCP-MMP1 annotation files:
  - `lh.HCP-MMP1.annot`
  - `rh.HCP-MMP1.annot`

If needed, install the Python dependencies into your working environment:

```bash
conda install -c conda-forge nibabel numpy
```

Place the annotation files in `$SUBJECTS_DIR/fsaverage/label/`. If they are in
the root of `$SUBJECTS_DIR`, the script will copy them into `fsaverage/label/`.

For subcortical aseg masks (`-s YES`), the script looks for
`FreeSurferColorLUT.txt` in `$SUBJECTS_DIR` first, then in `$FREESURFER_HOME`.
For thalamus masks, it prefers the older `Left-Thalamus-Proper` and
`Right-Thalamus-Proper` names when present, then falls back to the newer
`Left-Thalamus` and `Right-Thalamus` names.

## Main vs. Optimized Script

Use the main script for normal processing:

```bash
./create_subj_volume_parcellation.sh -L subject_list.txt -a HCP-MMP1 -d HCPMMP_parcellation
```

The optimized script is intentionally marked as experimental:

```bash
./create_subj_volume_parcellation_optimized.sh -L subject_list.txt -a HCP-MMP1 -d HCPMMP_parcellation
```

It sets `HCPMMP1_MAPPING_MODE=direct` and uses direct annotation transfer. Before
using it for analysis, compare its output against the main script for a subject
with known-good results.

Use the validation wrapper to run both paths and compare the final volumes:

```bash
./validate_optimized_output.sh \
  -L subject_list.txt \
  -a HCP-MMP1 \
  -d HCPMMP_validation \
  -f 1 \
  -l 1
```

The validation wrapper writes:

- `labels/`: output from `create_subj_volume_parcellation.sh`.
- `direct/`: output from `create_subj_volume_parcellation_optimized.sh`.
- `comparison/`: JSON and TSV comparison summaries for each subject.

The wrapper forces both workflows to recreate the subject annotation files so
the comparison cannot accidentally reuse a previous result. It backs up and
restores the original subject annotation files in `$SUBJECTS_DIR/<subject>/label/`
when it finishes.

## Usage

```bash
./create_subj_volume_parcellation.sh -L subject_list.txt -a HCP-MMP1 -d HCPMMP_parcellation
```

Required options:

| Option | Description |
| --- | --- |
| `-L <file>` | Text file containing subject IDs, one per line. Relative paths are checked from the current directory and then from `$SUBJECTS_DIR`. |
| `-a <name>` | Annotation basename without hemisphere or extension, such as `HCP-MMP1`. |
| `-d <dir>` | Output directory. Relative paths are created inside `$SUBJECTS_DIR`. |

Optional options:

| Option | Default | Description |
| --- | --- | --- |
| `-f <int>` | `1` | First row of the subject list to process. |
| `-l <int>` | End of file | Last row of the subject list to process. |
| `-m <YES\|NO>` | `NO` | Create individual cortical region masks. |
| `-s <YES\|NO>` | `NO` | Create individual subcortical aseg masks. |
| `-t <YES\|NO>` | `YES` | Create anatomical stats tables. |
| `-r <YES\|NO>` | `NO` | Recreate subject annotation files even when they already exist. Useful for validation. |
| `-j <int>` | `1` | Number of subjects to process at once. |

Process all subjects:

```bash
./create_subj_volume_parcellation.sh -L subject_list.txt -a HCP-MMP1 -d HCPMMP_parcellation
```

Process rows 1 through 5 and create cortical and subcortical masks:

```bash
./create_subj_volume_parcellation.sh \
  -L subject_list.txt \
  -f 1 \
  -l 5 \
  -a HCP-MMP1 \
  -d HCPMMP_parcellation \
  -m YES \
  -s YES \
  -j 2
```

By default, post-processing uses Python when `nibabel` and `numpy` are available
and falls back to `fslmaths` otherwise. To force one backend:

```bash
HCPMMP1_POSTPROCESS=python ./create_subj_volume_parcellation.sh \
  -L subject_list.txt \
  -a HCP-MMP1 \
  -d HCPMMP_parcellation

HCPMMP1_POSTPROCESS=fsl ./create_subj_volume_parcellation.sh \
  -L subject_list.txt \
  -a HCP-MMP1 \
  -d HCPMMP_parcellation
```

If Python is installed somewhere unusual, set `HCPMMP1_PYTHON` to that Python
executable.

## Output

The output directory contains:

- `label/`: fsaverage labels generated from the source annotation.
- `logs/`: logs from the fsaverage annotation conversion step.
- One directory per subject.

Each subject directory contains:

- `<annotation_name>.nii.gz`: final subject-space parcellation volume.
- `LUT_<annotation_name>.txt`: region index lookup table for the final volume.
- `label/`: mapped subject-space annotation files.
- `logs/`: command logs for troubleshooting.
- `tables/`: anatomical stats tables, when `-t YES`.
- `masks/`: cortical region masks, when `-m YES`.
- `aseg_masks/`: subcortical aseg masks, when `-s YES`.

The HCP-MMP1 H_ROI voxels are reassigned to the standard FreeSurfer hippocampus
IDs:

- Left hippocampus: `17`
- Right hippocampus: `53`

## Notes

The final cortical labels follow FreeSurfer-style hemisphere offsets. Left
hemisphere cortical values are in the `1000` range and right hemisphere cortical
values are in the `2000` range. Use the per-subject lookup table to match voxel
values to region names.

If a subject already has
`lh.<subject>_<annotation_name>.annot` and
`rh.<subject>_<annotation_name>.annot` in its FreeSurfer `label/` folder, the
script reuses those files instead of overwriting them. Use `-r YES` when you
need to recreate them for validation.

## References

- CJ Neurolab. HCP-MMP1.0 volumetric NIfTI masks in native structural space.
  https://cjneurolab.org/2016/11/22/hcp-mmp1-0-volumetric-nifti-masks-in-native-structural-space/
- Glasser, M. F. et al. A multi-modal parcellation of human cerebral cortex.
  Nature 536, 171-178 (2016). https://doi.org/10.1038/nature18933
- Mills, K. HCP-MMP1.0 projected on fsaverage. figshare.
  https://doi.org/10.6084/m9.figshare.3498446.v2
- CJ Neurolab. HCP-MMP1.0 volumetric masks in native structural space.
  figshare. https://doi.org/10.6084/m9.figshare.4249400.v5
