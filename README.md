# HCP-MMP1

The script was created by CJ Neurolab: https://cjneurolab.org

Neurolab, C. (2018). HCP-MMP1.0 volumetric (NIfTI) masks in native structural space (Version 5). figshare. https://doi.org/10.6084/m9.figshare.4249400.v5 (['http://www.nature.com/nature/journal/vaop/ncurrent/full/nature18933.html', 'https://figshare.com/articles/HCP-MMP1_0_projected_on_fsaverage/3498446', 'https://cjneurolab.org/2016/11/22/hcp-mmp1-0-volumetric-nifti-masks-in-native-structural-space/']) 

https://doi.org/10.6084/m9.figshare.4249400.v5

It was released under the MIT license: https://opensource.org/licenses/MIT

The following instructions are pulled verbatim from the CJ Neurolab: https://cjneurolab.org/2016/11/22/hcp-mmp1-0-volumetric-nifti-masks-in-native-structural-space/

We in our group received with great interest the publication of the HCP-MMP1.0 parcellation by Glasser et al. (Nature) [1] created using data from the Human Connectome Project earlier this year. Often in our connectivity pipelines we use volume files for parcellation in native space, so we decided to try and convert the Connectome Workbench files to volume masks in native structural space to try out in future studies.
We were happy to find that someone had already gone through the trouble of generating FreeSurfer annotation files projected on fsaverage, so all we had to do was find a way to transform these annot files to each subject’s space and convert them to volume masks.
To do that, we wrote a little Linux shell script that goes through a series of conversion and transformation steps using FreeSurfer commands. It first converts the downloaded annotation files (lh.HCPMMP1.annot and rh.HCPMMP1.annot) to labels using mri_annotation2label, then takes each label from fsaverage to each subject’s space with mri_label2label, converts transformed labels back to annotation with mri_label2annot, and finally converts these to volume files (nii.gz) with mris_label2annot. Seems like too many steps, but this is how we (who are far from being FreeSurfer experts) got satisfactory results.
The default final file consists of a single .nii.gz volume containing the cortical HCP-MMP1.0 regions plus the subcortical regions from the FreeSurfer segmentation, each assigned a unique voxel value. It should be noted that the HCP-MMP1.0 parcellation includes 180 regions – 179 of them cortical, and one subcortical (hippocampus). In the final volume file, left-hemisphere cortical HCP-MMP1.0 regions will have values between 1001 and 1181, whereas right-sided regions will have values between 2001 and 2181. The correspondence between each specific region and its voxel value is given in a look-up table that is saved in each subject’s output folder. To identify the hippocampus (and other subcortical structures), one needs to check the corresponding voxel values in the FreeSurferColorLUT.txt file provided with FreeSurfer (https://surfer.nmr.mgh.harvard.edu/fswiki/FsTutorial/AnatomicalROI/FreeSurferColorLUT), as it is generated based on the original aseg parcellation*.
*In the previous version of the script, a few perihippocampal cortical voxels were ascribed values (1121 and 2121) that should correspond to the hippocampus in the HCPMMP1.0 parcellation. Since only the cortical regions from this parcellation are generated, these voxels are now assigned the values corresponding to the hippocampus as defined by the automatic FreeSurfer subcortical segmentation (17 and 53).
Optionally, one can choose to also generate individual volume files for each cortical and/or subcortical parcellation region. This option requires FSL. If the user chooses to create individual subcortical masks, the FreeSurferColorLUT.txt  must also be available in the base ($SUBJECTS_DIR/) folder.
By default, the script also generates tables with anatomical information for each cortical region (number of vertices, area, volume, mean thickness, etc.).
Ingredients:

Subject data. First of all, you need to have your subjects’ structural data preprocessed with FreeSurfer.
Shell script. Download the script from here and copy it to to your $SUBJECTS_DIR/ folder.
Fsaverage data. If it’s not there already, copy the fsaverage folder from the FreeSurfer directory ($FREESURFER_HOME/subjects/fsaverage) to your $SUBJECTS_DIR/ folder.
Annotation files. Download rh.HCPMMP1.annot and lh.HCPMMP1.annot from https://figshare.com/articles/HCP-MMP1_0_projected_on_fsaverage/3498446. Copy them to your $SUBJECTS_DIR/ folder or to $SUBJECTS_DIR/fsaverage/label/.
Subject list. Create a list with the identifiers of the desired target subjects (named exactly as their corresponding names in $SUBJECTS_DIR/, of course).
FreeSurferColorLUT.txt. If the user chooses to generate individual volume files for the subcortical from the automatic FreeSurfer segmentation, this file should be placed in the $SUBJECTS_DIR/ folder.
Instructions:

Launch the script: bash create_subj_volume_parcellation.sh (this will show the compulsory and optional arguments).
The compulsory arguments are:
-L subject_list_name
-a name_of_annotation_file (without hemisphere or extension; in this case, HCPMMP1)
-d name_of_output_dir (will be created in $SUBJECTS_DIR)
Optional arguments:
-f and -l indicate the first and last subjects in the subject list to be processed. Eg, in order to process the third till the fifth subject, one would enter -f 3 -l 5 (whole thing takes a bit of time, so one might want to launch it in separate terminals for speed)
-t (“YES” or “NO”, default is YES) indicates whether individual tables with anatomical data per region (number of vertices, area, volume, mean thickness, …) will be created
-m (“YES” or “NO”, default is NO) indicates whether individual volume files for each cortical HCPMMP1.0 parcellation region should be created. This requires FSL
-s (“YES” or “NO”, default is NO) indicates whether individual volume files for each subcortical aseg region should be created. Also requires FSL
Examples:
To process the first five subjects listed in subject_list.txt, saving the results in a folder called HCPMMP_parcellation, including individual cortical (-m) and subcortical (-s) binary masks, the command would look like:
bash create_subj_volume_parcellation.sh -L subject_list.txt -f 1 -l 5 -a HCPMMP1 -d HCPMMP_parcellation -s YES -m YES 
 
To process all subjects in subject_list.txt, saving them to HCPMMP_parcellation, without generating individual region masks:
bash create_subj_volume_parcellation.sh -L subject_list.txt -a HCPMMP1 -d HCPMMP_parcellation
 
Output:
An output folder named as specified with the -d option will be created, which will contain a directory called label/, where the labels for the regions projected on fsaverage will be stored. The output directory will also contain a folder for each subject. Inside these subject folders, a .nii.gz file named as the annotation file (-a option) will contain the final parcellation volume. A look-up table will also be created inside each subject’s folder, named LUT_HCPMMP1.txt. In each subject’s folder, a directory called label/ will also be created, where the transformed labels will be stored
In each subject’s folder, a directory called tables/ will be generated, containing the anatomical information for each cortical region
If the -m option is set to YES, each subject’s directory will also contain a masks/ directory containing one volume .nii.gz file for each binary mask
If the -s option is set to YES, an aseg_masks/ directory will be created, containing one .nii.gz file for each subcortical region
Inside the original subjects’ label folders, post-transformation annotation files will be created. These are not overwritten if the script is relaunched; so, if you ran into a problem and want to start over, you should delete these files (named lh(rh).subject_HCPMMP1.annot)
 
References:
Glasser, Matthew F.  A multi-modal parcellation of human cerebral cortex. Nature 536, 171–178 (11 August 2016).  http://www.nature.com/nature/journal/vaop/ncurrent/full/nature18933.html
Mills, Kathryn (2016): HCP-MMP1.0 projected on fsaverage. figshare. https://dx.doi.org/10.6084/m9.figshare.3498446.v2 Retrieved: 08 57, Nov 22, 2016 (GMT)
