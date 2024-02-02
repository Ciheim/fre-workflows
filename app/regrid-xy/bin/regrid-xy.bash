#!/bin/bash
set -euo pipefail
set -x

#
# Regrid variables from latlon/cubed-sphere/tripolar to latlon
#

source $(dirname ${BASH_SOURCE[0]})/../shared/shared.sh

# To read the Rose config file
if [[ -z ${CYLC_TASK_WORK_DIR:-} ]]; then
    config="rose config --file $(dirname ${BASH_SOURCE[0]})/../rose-app.conf"
else
    config="rose config --file $CYLC_TASK_WORK_DIR/rose-app-run.conf"
fi

echo Arguments:
echo "    input dir: $inputDir"
echo "    output dir: $outputDir"
echo "    begin: $begin"
echo "    TMPDIR: $TMPDIR"
echo "    fregrid mapfile dir: $fregridRemapDir"
echo "    component(s): $component"
echo "    gridSpec: $gridSpec"
echo "    default xyInterp: $defaultxyInterp"
echo Utilities:
type ncdump
type ncks
type fregrid

# Verify input directory exists and is a directory
if [[ ! -d $inputDir ]]; then
    err "Error: Input directory '${inputDir}' does not exist or isn't a directory"
    exit 1
fi

# Verify output directory exists and is a directory
if [[ ! -d $outputDir ]]; then
    err "Error: Output directory '${outputDir}' does not exist or isn't a directory"
    exit 1
fi

# Parse default xyInterp
defaultOutputGridLon=$(echo $defaultxyInterp | cut -d ',' -f 1)
defaultOutputGridLat=$(echo $defaultxyInterp | cut -d ',' -f 2)

# Create remap cache dir if needed
mkdir -p $fregridRemapDir

# Will do the regridding in a workdir
mkdir -p $TMPDIR/work

# Loop over regridding instruction sets
# Process the component if any instruction sets match
for set in $($config --keys | grep -v command | grep -v env); do
    # xargs is needed to make this pattern match work properly.. yuck
    if ! [[ " $($config $set sources | xargs) " =~ " $component " ]]; then
        continue
    fi
    echo "Processing instruction '$set' for component '$component'"

    # Clean out workdir
    cd $TMPDIR/work
    rm -f *

    # Read in these component-specific config variables
    # required items
    inputGrid=$($config $set inputGrid)
    inputRealm=$($config $set inputRealm)
    interpMethod=$($config $set interpMethod)
    # optional items
    outputGridType=$($config --default= $set outputGridType)
    nlon=$($config --default=$defaultOutputGridLon $set outputGridLon)
    nlat=$($config --default=$defaultOutputGridLat $set outputGridLat)
    vars=$($config --default= $set variables)
    fregridRemapFile=$($config --default= $set fregridRemapFile)
    fregridMoreOptions=$($config --default= $set fregridMoreOptions)

    if [[ $inputGrid =~ cubedsphere ]]; then
        is_tiled=1
    else
        is_tiled=""
    fi

    fregridInterpOption="--interp_method $interpMethod"

    # Determine the mosaic file type to pass to fregrid
    case $inputRealm in
        atmos)
            mosaic_type=atm_mosaic_file
            ;;
        ocean)
            mosaic_type=ocn_mosaic_file
            ;;
        land)
            mosaic_type=lnd_mosaic_file
            ;;
        aerosol)
            mosaic_type=atm_mosaic_file
            ;;
        *)
            err "ERROR: Unknown realm '$inputRealm'"
            exit 1
    esac

    # Retrieve grid spec, usually in a tarfile
    if [[ $gridSpec =~ \.tar$ ]]; then
        tar -xvf $gridSpec
        if [[ -e mosaic.nc ]]; then
            gridSpecFile=mosaic.nc
        elif [[ -e grid_spec.nc ]]; then
            gridSpecFile=grid_spec.nc
        else
            err "ERROR: Cannot determine gridSpecFile within $gridSpec"
            exit 1
        fi
    else
        cp $gridSpec .
        gridSpecFile=$gridSpec
    fi
    input_mosaic=$(ncks -H -v $mosaic_type $gridSpecFile | grep -o '".*"' | tr -d \")
    if [[ -f $input_mosaic ]]; then
        echo "NOTE: input mosaic = '$input_mosaic'"
    else
        err "ERROR: input mosaic '$input_mosaic' does not exist"
        exit 1
    fi

    # Copy regrid file if specified
    # Get the source grid dimensions
    mosaic_gridfile=$(ncks --trd -H -v gridfiles $input_mosaic | sed 's/.*="//;s/"//' | xargs | cut -d ' ' -f 1)
    if [[ -f $mosaic_gridfile ]]; then
        echo "NOTE: mosaic gridfile = '$mosaic_gridfile'"
    else
        err "ERROR: mosaic gridfile '$mosaic_gridfile' does not exist"
        exit 1
    fi
    source_x=$(( $(ncdump -h $mosaic_gridfile | grep "nx =" | sed 's/.*=//;s/;//;s/ //g') / 2 ))
    source_y=$(( $(ncdump -h $mosaic_gridfile | grep "ny =" | sed 's/.*=//;s/;//;s/ //g') / 2 ))
    if [[ -n "$fregridRemapFile" ]]; then
        echo "NOTE: Using user-specified remap file '$fregridRemapFile'"
        cp $fregridRemapFile .
        fregridRemapFile=$(basename $fregridRemapFile)

    # If not specified, see if it is cached already
    else
        fregridRemapFile=fregrid_remap_file_${nlon}_by_$nlat.nc
        fregridRemapCacheFile="$fregridRemapDir/$inputGrid/$inputRealm/$source_x-by-$source_y/$interpMethod/$fregridRemapFile"
        centralRemapCacheFile="/home/fms/shared_fregrid_remap_files/$inputGrid/${source_x}_by_$source_y/$fregridRemapFile"
        if [[ -f $fregridRemapCacheFile ]]; then
            echo "NOTE: Using cached remap file '$fregridRemapCacheFile'"
            cp $fregridRemapCacheFile .
        elif [[ -f $centralRemapCacheFile ]]; then
            echo "NOTE: Using MSD-created cached remap file '$centralRemapCacheFile'"
            cp $centralRemapCacheFile .
        fi
    fi

    # Verify input files exist
    cd $inputDir
    date1=$(truncate_date $begin P1D) 
    if [[ $is_tiled ]]; then
        file=$date1.$component.tile1.nc
    else
        file=$date1.$component.nc
    fi
    if ! ls $file; then
        err "ERROR: Input file '$file' not found"
        exit 1
    fi

    # Regrid all variables by default
    if [[ -z $vars ]]; then
        vars=$(ncks --trd -m $file | grep -E ': type' | cut -f 1 -d ' ' | sort | xargs | sed 's/://g')
        # except average_(T1|T2|DT) which cause fregrid errors
        # and time and time_bnds
        # and the native grid dims
        vars=$(echo $vars | sed 's/average_..//g' | sed -r 's/\btime_?(bnds)?\b//g' | sed -r 's/\b(xh|xq|yh|yq|zi|zl)\b//g' | sed -r 's/\b(xB|xT|xTe|yB|yT|yTe)\b//g')
    fi
    count=$(echo $vars | wc -w)
    if (( count > 0 )); then
        echo "NOTE: About to regrid $count variables for component '$component'"
    else
        err "No input variables found for component '$component'"
        exit 1
    fi

    # Do the regridding in the workdir
    fregrid_input_file=$(echo $file | sed 's/\.tile1\.nc//')
    outputFile=$(echo $file | sed 's/\.tile1//')
    vars=$(echo $vars | tr ' ' ,)
    input_dir=$(pwd)
    pushd $TMPDIR/work

    fregrid \
        --standard_dimension \
        --input_mosaic $input_mosaic \
        --input_dir $input_dir \
        --input_file $fregrid_input_file \
        --associated_file_dir $input_dir $fregridInterpOption \
        --remap_file $fregridRemapFile \
        --nlon $nlon \
        --nlat $nlat \
        --scalar_field $vars \
        --output_file $outputFile \
        $fregridMoreOptions

    # Copy the remap file to the cache location
    if [[ ! -f $fregridRemapCacheFile ]]; then
        echo "NOTE: Caching remap file '$fregridRemapCacheFile'"
        mkdir -p $(dirname $fregridRemapCacheFile)
        cp -f $fregridRemapFile $(dirname $fregridRemapCacheFile)
    fi

    if [[ -z $outputGridType ]]; then
        # Copy the regridded output to the output location
        cp $outputFile $outputDir
    else
        # Create output location if needed
        mkdir -p $outputDir/$outputGridType
        # Copy the regridded output to the output location
        cp $outputFile $outputDir/$outputGridType
    fi 
    
    popd
done

echo Natural end of the xy regridding
exit 0
