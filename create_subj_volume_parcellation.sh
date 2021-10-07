#!/usr/bin/env bash

# Creates subject-level parcellation image from annotation files in fsaverage space. Can be used with the HCP-MMP1.0 projected on fsaverage annotation files available from https://figshare.com/articles/HCP-MMP1_0_projected_on_fsaverage/3498446
# usage:
# bash create_subj_volume_parcellation -L <subject_list> -a <name_of_annot_file> -f <first_subject_row> -l <last_subject_row> -d <name_of_output_dir>
# 
# 
# HOW TO USE
# 
# Ingredients:
# 
# Subject data. First of all, you need to have your subjects’ structural data preprocessed with FreeSurfer.
# Shell script. Download the script: create_subj_volume_parcellation, unzip it (because wordpress won’t upload .sh files directly), and copy it to to your $SUBJECTS_DIR/ folder.
# Fsaverage data. Copy the fsaverage folder from the FreeSurfer directory ($FREESURFER_HOME/subjects/fsaverage) to your $SUBJECTS_DIR/ folder.
# Annotation files. Download rh.HCPMMP1.annot and lh.HCPMMP1.annot from https://figshare.com/articles/HCP-MMP1_0_projected_on_fsaverage/3498446. Copy them to your $SUBJECTS_DIR/ folder or to $SUBJECTS_DIR/fsaverage/label/.
# Subject list. Create a list with the identifiers of the desired target subjects (named exactly as their corresponding names in $SUBJECTS_DIR/, of course).
#  
# Instructions:
# 
# Launch the script: bash create_subj_volume_parcellation.sh (this will show the compulsory and optional arguments).
# The compulsory arguments are:
# -L subject_list_name
# -a name_of_annotation_file (without hemisphere or extension; in this case, HCPMMP1)
# -d name_of_output_dir (will be created in $SUBJECTS_DIR)
# Optional arguments:
# -f and -l indicate the first and last subjects in the subject list to be processed. Eg, in order to process the third till the fifth subject, one would enter -f 3 -l 5 (whole thing takes a bit of time, so one might want to launch it in separate terminals for speed)
# -m (YES or NO, default NO) indicates whether individual volume files for each parcellation region should be created. This requires FSL
# -s (“YES” or “NO”, default is NO) indicates whether individual volume files for each subcortical aseg region should be created. Also requires FSL, and requires that the FreeSurferColorLUT.txt file be present at the base (subjects) folder
# -t (YES or NO, default YES) indicates whether to create anatomical stats table (number of vertices, area, volume, mean thickness, etc.) per region
# Output:
# An output folder named as specified with the -d option will be created, which will contain a directory called label/, where the labels for the regions projected on fsaverage will be stored. The output directory will also contain a folder for each subject. Inside these subject folders, a .nii.gz file named as # the annotation file (-a option) will contain the final parcellation volume. A look-up table will also be created inside each subject’s folder, named LUT_<name_of_annotation_file>.txt. In each subject’s folder, a directory called label/ will also be created, where the transformed labels will be stored
# If the -m option is set to YES, each subject’s directory will also contain a masks/ directory containing one volume .nii.gz file for each binary mask
# If the -s option is set to YES, an aseg_masks/ directory will be created, containing one .nii.gz file for each subcortical region
# Inside the original subjects’ label folders, post-transformation annotation files will be created. These are not overwritten if the script is relaunched; so, if you ran into a problem and want to start over, you should delete these files (named lh(rh).<subject>_<name_of_annotation_file>.annot)

# define compulsory and optional arguments
while getopts ":L:f:l:a:d::m:t:s:" o; do
    case "${o}" in
        L)
            L=${OPTARG}
            ;;
        f)
            f=${OPTARG}
            ;;
        l)
            l=${OPTARG}
            ;;
        a)
            a=${OPTARG}
            ;;
        d)
            d=${OPTARG}
            ;;
        m)
            m=${OPTARG}
            ;;
	t)
	    t=${OPTARG}
	    ;;
	s)
	    s=${OPTARG}
	    ;;
    esac
done

if [ -z "${L}" ] || [ -z "${a}" ] || [ -z "${d}" ]; then printf '\n Usage:\n	-To be run from the directory containing FreeSurfer subject folders, which should also contain the fsaverage folder. User must have writing permission. Original annotation files (eg, lh.HCPMMP1.annot, rh.HCPMMP1.annot) must be present in $SUBJECTS_DIR/fsaverage/label/, or in the base folder ($SUBJECTS_DIR/).\n	-Output: individual nifti volume, where regions are indicated by voxel values, is stored in each subject·s folder inside the output directory. Regions can then be identified through the region_index_table.txt stored in the output folder. Final annotation file in subject space is stored in original subject·s folder ($SUBJECTS_DIR/subject/label/), and will NOT ovewrite old files.\n\n Compulsory arguments:\n	-L <subject_list> (names must correspond to names of folders in $SUBJECTS_DIR)\n	-a <name_of_input_annot_file> (without specifying hemisphere and without extension. Usually, HCPMMP1)\n	-d <name_of_ouput_dir> \n\n Optional arguments:\n	-f: row in subject list indicating first subject to be processed\n	-l: row in subject list indicating last subject to be processed\n	-m <YES or NO> create individual nii.gz masks for cortical regions (requires FSL. Default is NO. Masks will be saved in /output_dir/subject/masks/)\n	-s <YES or NO> create individual nii.gz masks for 14 subcortical regions (from the FreeSurfer automatic segmentation. Requires the FreeSurferColorLUT.txt file in the base folder. Requires FSL. Defaults is NO)\n	-t <YES or NO> generate anatomical stats (mean area, volume, thickness, etc., per region. Saved in /output_dir/subject/tables/. Default is YES) table\n\n	2018 CJNeurolab\n	University of Barcelona\n	by Hugo C Baggio & Alexandra Abos\n\n'; exit 1; fi

create_individual_masks=NO
annotation_file=$a
subject_list_all=$L
output_dir=$d
get_anatomical_stats=YES
create_aseg_files=NO

if [ ! -z "${f}" ] ; then first=$f; else first=1; fi
if [ ! -z "${l}" ] ; then last=$l; else last=`wc -l < ${subject_list_all}`; fi
if [ ! -z "${m}" ] ; then create_individual_masks=$m; fi
if [ ! -z "${s}" ] ; then create_aseg_files=$s; fi
if [ ! -z "${t}" ] ; then get_anatomical_stats=$t; fi
 
printf "\n         >>>>         Current FreeSurfer subjects folder is $SUBJECTS_DIR\n\n"

#Check if FreeSurferColorLUT.txt is present in base folder
if [[ ${create_aseg_files} == "YES" ]]; then if [[ ! -e FreeSurferColorLUT.txt ]]; then printf "         >>>>         ERROR: FreeSurferColorLUT.txt file not found. Subcortical masks will NOT be created\n\n"; create_aseg_files=NO; colorlut_miss=YES; fi; fi

# Create subject list with subjects defined in the input
sed -n "${first},${last} p" ${subject_list_all} > temp_subject_list_${first}_${last}
subject_list=temp_subject_list_${first}_${last}

mkdir -p ${output_dir}
mkdir -p ${output_dir}/label
rand_id=$RANDOM
mkdir -p ${output_dir}/temp_${first}_${last}_${rand_id}
rm -f ${output_dir}/temp_${first}_${last}_${rand_id}/colortab_?
rm -f ${output_dir}/temp_${first}_${last}_${rand_id}/list_labels_${annotation_file}?

# Check whether original annotation files are in fsaverage/label folder, copy them if not
if [[ ! -e $SUBJECTS_DIR/fsaverage/label/lh.${annotation_file}.annot ]]
	then cp $SUBJECTS_DIR/lh.${annotation_file}.annot $SUBJECTS_DIR/fsaverage/label/
fi
if [[ ! -e $SUBJECTS_DIR/fsaverage/label/rh.${annotation_file}.annot ]] 
	then cp $SUBJECTS_DIR/rh.${annotation_file}.annot $SUBJECTS_DIR/fsaverage/label/
fi

# Convert annotation to label, and get color lookup tables
rm -f ./${output_dir}/log_annotation2label
mri_annotation2label --subject fsaverage --hemi lh --outdir ./${output_dir}/label --annotation ${annotation_file} >> ./${output_dir}/temp_${first}_${last}_${rand_id}/log_annotation2label
mri_annotation2label --subject fsaverage --hemi lh --outdir ./${output_dir}/label --annotation ${annotation_file} --ctab ${output_dir}/temp_${first}_${last}_${rand_id}/colortab_${annotation_file}_L1 >> ./${output_dir}/temp_${first}_${last}_${rand_id}/log_annotation2label
mri_annotation2label --subject fsaverage --hemi rh --outdir ./${output_dir}/label --annotation ${annotation_file} >> ./${output_dir}/temp_${first}_${last}_${rand_id}/log_annotation2label
mri_annotation2label --subject fsaverage --hemi rh --outdir ./${output_dir}/label --annotation ${annotation_file} --ctab ${output_dir}/temp_${first}_${last}_${rand_id}/colortab_${annotation_file}_R1 >> ./${output_dir}/temp_${first}_${last}_${rand_id}/log_annotation2label

# Remove number columns from ctab
awk '!($1="")' ${output_dir}/temp_${first}_${last}_${rand_id}/colortab_${annotation_file}_L1 >> ${output_dir}/temp_${first}_${last}_${rand_id}/colortab_${annotation_file}_L2
awk '!($1="")' ${output_dir}/temp_${first}_${last}_${rand_id}/colortab_${annotation_file}_R1 >> ${output_dir}/temp_${first}_${last}_${rand_id}/colortab_${annotation_file}_R2

# Create list with region names
awk '{print $2}' ${output_dir}/temp_${first}_${last}_${rand_id}/colortab_${annotation_file}_L1 > ${output_dir}/temp_${first}_${last}_${rand_id}/list_labels_${annotation_file}L1
awk '{print $2}' ${output_dir}/temp_${first}_${last}_${rand_id}/colortab_${annotation_file}_R1 > ${output_dir}/temp_${first}_${last}_${rand_id}/list_labels_${annotation_file}R1

# Create lists with regions that actually have corresponding labels
for labelsL in `cat ${output_dir}/temp_${first}_${last}_${rand_id}/list_labels_${annotation_file}L1`
	do if [[ -e ${output_dir}/label/lh.${labelsL}.label ]]
		then
		echo lh.${labelsL}.label >> ${output_dir}/temp_${first}_${last}_${rand_id}/list_labels_${annotation_file}L
		grep " ${labelsL} " ${output_dir}/temp_${first}_${last}_${rand_id}/colortab_${annotation_file}_L2 >> ${output_dir}/temp_${first}_${last}_${rand_id}/colortab_${annotation_file}_L3
	fi
done
for labelsR in `cat ${output_dir}/temp_${first}_${last}_${rand_id}/list_labels_${annotation_file}R1`
	do if [[ -e ${output_dir}/label/rh.${labelsR}.label ]]
		then
		echo rh.${labelsR}.label >> ${output_dir}/temp_${first}_${last}_${rand_id}/list_labels_${annotation_file}R
		grep " ${labelsR} " ${output_dir}/temp_${first}_${last}_${rand_id}/colortab_${annotation_file}_R2 >> ${output_dir}/temp_${first}_${last}_${rand_id}/colortab_${annotation_file}_R3
	fi
done

# Create new numbers column
number_labels_R=`wc -l < ${output_dir}/temp_${first}_${last}_${rand_id}/list_labels_${annotation_file}R` 
number_labels_L=`wc -l < ${output_dir}/temp_${first}_${last}_${rand_id}/list_labels_${annotation_file}L`

for ((i=1;i<=${number_labels_L};i+=1))
	do num=`echo "${i}+1000" | bc`
	printf "$num\n" >> ${output_dir}/temp_${first}_${last}_${rand_id}/LUT_number_table_${annotation_file}L
	printf "$i\n" >> ${output_dir}/temp_${first}_${last}_${rand_id}/${annotation_file}_number_tableL
done
for ((i=1;i<=${number_labels_R};i+=1))
	do num=`echo "${i}+2000" | bc`
	printf "$num\n" >> ${output_dir}/temp_${first}_${last}_${rand_id}/LUT_number_table_${annotation_file}R
	printf "$i\n" >> ${output_dir}/temp_${first}_${last}_${rand_id}/${annotation_file}_number_tableR
done

# Create ctabs with actual regions
paste ${output_dir}/temp_${first}_${last}_${rand_id}/${annotation_file}_number_tableL ${output_dir}/temp_${first}_${last}_${rand_id}/colortab_${annotation_file}_L3 > ${output_dir}/temp_${first}_${last}_${rand_id}/colortab_${annotation_file}_L
paste ${output_dir}/temp_${first}_${last}_${rand_id}/LUT_number_table_${annotation_file}L ${output_dir}/temp_${first}_${last}_${rand_id}/list_labels_${annotation_file}L > ${output_dir}/temp_${first}_${last}_${rand_id}/LUT_left_${annotation_file}
paste ${output_dir}/temp_${first}_${last}_${rand_id}/${annotation_file}_number_tableR ${output_dir}/temp_${first}_${last}_${rand_id}/colortab_${annotation_file}_R3 > ${output_dir}/temp_${first}_${last}_${rand_id}/colortab_${annotation_file}_R
paste ${output_dir}/temp_${first}_${last}_${rand_id}/LUT_number_table_${annotation_file}R ${output_dir}/temp_${first}_${last}_${rand_id}/list_labels_${annotation_file}R > ${output_dir}/temp_${first}_${last}_${rand_id}/LUT_right_${annotation_file}
cat ${output_dir}/temp_${first}_${last}_${rand_id}/LUT_left_${annotation_file} ${output_dir}/temp_${first}_${last}_${rand_id}/LUT_right_${annotation_file} > ${output_dir}/temp_${first}_${last}_${rand_id}/LUT_${annotation_file}.txt

# Take labels from fsaverage to subject space
for subject in `cat ${subject_list}`
	do printf "\n         >>>>         PREPROCESSING ${subject}         <<<< \n"

	echo $(date) > ${output_dir}/temp_${first}_${last}_${rand_id}/start_date
	echo "         >>>>         START TIME: `cat ${output_dir}/temp_${first}_${last}_${rand_id}/start_date`         <<<<"
	mkdir -p ${output_dir}/${subject}
	mkdir -p ${output_dir}/${subject}/label
	sed '/_H_ROI/d' ${output_dir}/temp_${first}_${last}_${rand_id}/LUT_${annotation_file}.txt > ${output_dir}/${subject}/LUT_${annotation_file}.txt

	if [[ -e $SUBJECTS_DIR/${subject}/label/lh.${subject}_${annotation_file}.annot ]] && [[ -e $SUBJECTS_DIR/${subject}/label/rh.${subject}_${annotation_file}.annot ]]
		then
		echo ">>>>	Annotation files lh.${subject}_${annotation_file}.annot and rh.${subject}_${annotation_file}.annot already exist in ${subject}/label. Won't perform transformations"
		else

		rm -f ${output_dir}/${subject}/label2annot_${annotation_file}?h.log
		rm -f ${output_dir}/${subject}/log_label2label
		
		for label in `cat ${output_dir}/temp_${first}_${last}_${rand_id}/list_labels_${annotation_file}R`
			do echo "transforming ${label}"
			mri_label2label --srcsubject fsaverage --srclabel ${output_dir}/label/${label} --trgsubject ${subject} --trglabel ${output_dir}/${subject}/label/${label}.label --regmethod surface --hemi rh >> ${output_dir}/${subject}/log_label2label
		done
		for label in `cat ${output_dir}/temp_${first}_${last}_${rand_id}/list_labels_${annotation_file}L`
			do echo "transforming ${label}"
			mri_label2label --srcsubject fsaverage --srclabel ${output_dir}/label/${label} --trgsubject ${subject} --trglabel ${output_dir}/${subject}/label/${label}.label --regmethod surface --hemi lh >> ${output_dir}/${subject}/log_label2label
		done

		# Convert labels to annot (in subject space)
		rm -f ${output_dir}/temp_${first}_${last}_${rand_id}/temp_cat_${annotation_file}_R
		rm -f ${output_dir}/temp_${first}_${last}_${rand_id}/temp_cat_${annotation_file}_L
		for labelsR in `cat ${output_dir}/temp_${first}_${last}_${rand_id}/list_labels_${annotation_file}R`
			do printf " --l ${output_dir}/${subject}/label/${labelsR}" >> ${output_dir}/temp_${first}_${last}_${rand_id}/temp_cat_${annotation_file}_R
		done
		for labelsL in `cat ${output_dir}/temp_${first}_${last}_${rand_id}/list_labels_${annotation_file}L`
			do if [ -e ${output_dir}/${subject}/label/${labelsL} ]
				then printf " --l ${output_dir}/${subject}/label/${labelsL}" >> ${output_dir}/temp_${first}_${last}_${rand_id}/temp_cat_${annotation_file}_L
			fi
		done
	
		mris_label2annot --s ${subject} --h rh `cat ${output_dir}/temp_${first}_${last}_${rand_id}/temp_cat_${annotation_file}_R` --a ${subject}_${annotation_file} --ctab ${output_dir}/temp_${first}_${last}_${rand_id}/colortab_${annotation_file}_R >> ${output_dir}/${subject}/label2annot_${annotation_file}rh.log 
		mris_label2annot --s ${subject} --h lh `cat ${output_dir}/temp_${first}_${last}_${rand_id}/temp_cat_${annotation_file}_L` --a ${subject}_${annotation_file} --ctab ${output_dir}/temp_${first}_${last}_${rand_id}/colortab_${annotation_file}_L >> ${output_dir}/${subject}/label2annot_${annotation_file}lh.log 

	fi

	# Convert annot to volume
	rm -f ${output_dir}/${subject}/log_aparc2aseg
	mri_aparc2aseg --s ${subject} --o ${output_dir}/temp_${first}_${last}_${rand_id}/${annotation_file}.nii.gz  --annot ${subject}_${annotation_file} >> ${output_dir}/${subject}/log_aparc2aseg

	# Remove hippocampal 'residue' --> voxels assigned to hippocampus in the HCPMMP1.0 parcellation will be very few, corresponding to vertices around the actual structure. These will be given the same voxel values as the hippocampi (as defined by the FS automatic segmentation): 17 (L) and 53 (R)
	l_hipp_index=`grep 'L_H_ROI.label' ${output_dir}/temp_${first}_${last}_${rand_id}/LUT_${annotation_file}.txt | cut -c-4`
	r_hipp_index=`grep 'R_H_ROI.label' ${output_dir}/temp_${first}_${last}_${rand_id}/LUT_${annotation_file}.txt | cut -c-4`

	fslmaths ${output_dir}/temp_${first}_${last}_${rand_id}/${annotation_file}.nii.gz -thr $l_hipp_index -uthr $l_hipp_index ${output_dir}/temp_${first}_${last}_${rand_id}/l_hipp_HCP
	fslmaths ${output_dir}/temp_${first}_${last}_${rand_id}/l_hipp_HCP -bin -mul 17 ${output_dir}/temp_${first}_${last}_${rand_id}/l_hipp_FS

	fslmaths ${output_dir}/temp_${first}_${last}_${rand_id}/${annotation_file}.nii.gz -thr $r_hipp_index -uthr $r_hipp_index -add ${output_dir}/temp_${first}_${last}_${rand_id}/l_hipp_HCP ${output_dir}/temp_${first}_${last}_${rand_id}/l_r_hipp_HCP
	fslmaths ${output_dir}/temp_${first}_${last}_${rand_id}/${annotation_file}.nii.gz -thr $r_hipp_index -uthr $r_hipp_index -bin -mul 53 -add ${output_dir}/temp_${first}_${last}_${rand_id}/l_hipp_FS ${output_dir}/temp_${first}_${last}_${rand_id}/l_r_hipp_FS

	fslmaths ${output_dir}/temp_${first}_${last}_${rand_id}/${annotation_file}.nii.gz -sub ${output_dir}/temp_${first}_${last}_${rand_id}/l_r_hipp_HCP -add ${output_dir}/temp_${first}_${last}_${rand_id}/l_r_hipp_FS ${output_dir}/${subject}/${annotation_file}.nii.gz

	# Create individual mask files
	if [[ ${create_individual_masks} == "YES" ]]
		then 
		printf ">> Creating individual region masks for subject ${subject}\n"
		mkdir -p ${output_dir}/${subject}/masks
		for ((i=1;i<=${number_labels_L};i+=1))
			do num=`echo "${i}+1000" | bc`
			if [[ $num != $l_hipp_index ]]
				then
				temp_region=`sed -n "$i,$i p" ${output_dir}/temp_${first}_${last}_${rand_id}/list_labels_${annotation_file}L1`
				echo "Mask left hemisphere: $i ${temp_region}"
				fslmaths ${output_dir}/${subject}/${annotation_file}.nii.gz -thr ${num} -uthr ${num} -bin ${output_dir}/${subject}/masks/${temp_region}
				else
				echo ">> Skipping left hippocampus"
			fi
		done
		for ((i=1;i<=${number_labels_R};i+=1))
			do num=`echo "${i}+2000" | bc`
			if [[ $num != $r_hipp_index ]]
				then
				temp_region=`sed -n "$i,$i p" ${output_dir}/temp_${first}_${last}_${rand_id}/list_labels_${annotation_file}R1`
				echo "Mask right hemisphere: $i ${temp_region}"
				fslmaths ${output_dir}/${subject}/${annotation_file}.nii.gz -thr ${num} -uthr ${num} -bin ${output_dir}/${subject}/masks/${temp_region}
				else
				echo ">> Skipping right hippocampus"
			fi
		done

	fi

	# Create individual subcortical masks
	if [[ ${create_aseg_files} == "YES" ]]
		then
		mkdir -p ${output_dir}/${subject}/aseg_masks
		printf ">> Creating subcortical aseg masks for subject ${subject}\n"
		if [[ -e ${output_dir}/${subject}/aseg_masks/list_aseg ]]; then rm ${output_dir}/${subject}/aseg_masks/list_aseg; fi
		for side in Left Right
			do printf "$side-Thalamus-Proper\n$side-Caudate\n$side-Pallidum\n$side-Hippocampus\n$side-Amygdala\n$side-Accumbens-area\n" >> ${output_dir}/${subject}/aseg_masks/list_aseg
		done
		
		for rois in `cat ${output_dir}/${subject}/aseg_masks/list_aseg`
			do roi_index=`grep "${rois} " FreeSurferColorLUT.txt | cut -c-2` # the space after ${rois} is not casual
			fslmaths ${output_dir}/${subject}/${annotation_file}.nii.gz -thr ${roi_index} -uthr ${roi_index} -bin ${output_dir}/${subject}/aseg_masks/${rois}
		done

	fi

	# Get anatomical stats table
	if [[ ${get_anatomical_stats} == "YES" ]]
		then
		mkdir -p ${output_dir}/${subject}/tables
		mris_anatomical_stats -a $SUBJECTS_DIR/${subject}/label/lh.${subject}_${annotation_file}.annot -b ${subject} lh > ${output_dir}/temp_${first}_${last}_${rand_id}/table_lh.txt
		sed '/_H_ROI/d; /???/d' ${output_dir}/temp_${first}_${last}_${rand_id}/table_lh.txt > ${output_dir}/${subject}/tables/table_lh.txt
		mris_anatomical_stats -a $SUBJECTS_DIR/${subject}/label/rh.${subject}_${annotation_file}.annot -b ${subject} rh > ${output_dir}/temp_${first}_${last}_${rand_id}/table_rh.txt
		sed '/_H_ROI/d; /???/d' ${output_dir}/temp_${first}_${last}_${rand_id}/table_rh.txt > ${output_dir}/${subject}/tables/table_rh.txt
		
		# Get tables with numerical values only
		grep -n 'structure' ${output_dir}/${subject}/tables/table_lh.txt > ${output_dir}/temp_${first}_${last}_${rand_id}/temp_line_structure_name
		grep -Eo '[0-9]{1,4}' ${output_dir}/temp_${first}_${last}_${rand_id}/temp_line_structure_name > ${output_dir}/temp_${first}_${last}_${rand_id}/temp_line_structure_name2
		line_structure_name=`cat ${output_dir}/temp_${first}_${last}_${rand_id}/temp_line_structure_name2`
		post_end_line=`echo "1+${line_structure_name}" | bc`
		sed "1,${post_end_line}d" ${output_dir}/${subject}/tables/table_rh.txt > ${output_dir}/${subject}/tables/table_rh_values
		sed "1,${post_end_line}d" ${output_dir}/${subject}/tables/table_lh.txt > ${output_dir}/${subject}/tables/table_lh_values
		sed -i -r 's/\S+//10' ${output_dir}/${subject}/tables/table_lh_values
		sed -i -r 's/\S+//10' ${output_dir}/${subject}/tables/table_rh_values

		# Get variable names
		grep -n 'number of vertices' ${output_dir}/${subject}/tables/table_lh.txt > ${output_dir}/temp_${first}_${last}_${rand_id}/temp_number_vert
		grep -Eo '[0-9]{1,4}' ${output_dir}/temp_${first}_${last}_${rand_id}/temp_number_vert > ${output_dir}/temp_${first}_${last}_${rand_id}/temp_number_vert2
		line_number_vert=`cat ${output_dir}/temp_${first}_${last}_${rand_id}/temp_number_vert2`
		pre_number_vert=`echo "${line_number_vert}-1" | bc`
		
		number_lines=`wc -l < ${output_dir}/${subject}/tables/table_rh.txt`
		sed "1,${pre_number_vert}d;${post_end_line},${number_lines}d" ${output_dir}/${subject}/tables/table_rh.txt > ${output_dir}/temp_${first}_${last}_${rand_id}/rh_mri_anatomical_stats_variables.txt
		cut -c5- ${output_dir}/temp_${first}_${last}_${rand_id}/rh_mri_anatomical_stats_variables.txt > ${output_dir}/temp_${first}_${last}_${rand_id}/rh_mri_anatomical_stats_variables2.txt 
		sed -i 's/ /_/g' ${output_dir}/temp_${first}_${last}_${rand_id}/rh_mri_anatomical_stats_variables2.txt        
		awk '{ for (f = 1; f <= NF; f++)   a[NR, f] = $f  }  NF > nf { nf = NF } END {   for (f = 1; f <= nf; f++) for (r = 1; r <= NR; r++)     printf a[r, f] (r==NR ? RS : FS)  }' ${output_dir}/temp_${first}_${last}_${rand_id}/rh_mri_anatomical_stats_variables2.txt > ${output_dir}/${subject}/tables/rh_mri_anatomical_stats_variables

		sed "1,${pre_number_vert}d;${post_end_line},${number_lines}d" ${output_dir}/${subject}/tables/table_lh.txt > ${output_dir}/temp_${first}_${last}_${rand_id}/lh_mri_anatomical_stats_variables.txt
		cut -c5- ${output_dir}/temp_${first}_${last}_${rand_id}/lh_mri_anatomical_stats_variables.txt > ${output_dir}/temp_${first}_${last}_${rand_id}/lh_mri_anatomical_stats_variables2.txt 
		sed -i 's/ /_/g' ${output_dir}/temp_${first}_${last}_${rand_id}/lh_mri_anatomical_stats_variables2.txt        
		awk '{ for (f = 1; f <= NF; f++)   a[NR, f] = $f  }  NF > nf { nf = NF } END {   for (f = 1; f <= nf; f++) for (r = 1; r <= NR; r++)     printf a[r, f] (r==NR ? RS : FS)  }' ${output_dir}/temp_${first}_${last}_${rand_id}/lh_mri_anatomical_stats_variables2.txt > ${output_dir}/${subject}/tables/lh_mri_anatomical_stats_variables

	fi

	if [[ ${colorlut_miss} == "YES" ]]; then printf "\n         >>>>         ERROR: FreeSurferColorLUT.txt file not found. Individual subcortical masks NOT created\n"; fi

	printf "\n         >>>>         ${subject} STARTED AT `cat ${output_dir}/temp_${first}_${last}_${rand_id}/start_date`, ENDED AT: $(date)\n\n"

done

rm -r ${output_dir}/temp_${first}_${last}_${rand_id}

rm ${subject_list}
