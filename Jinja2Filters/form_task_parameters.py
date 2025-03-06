#import re
import os
#import metomi.rose.config
#import ast
from pathlib import Path 
import yaml

# set up logging
import logging
logging.basicConfig()
logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

def form_task_parameters(grid_type, temporal_type, pp_components_str, yamlfile):
    """Form the task parameter list based on the grid type, the temporal type,
    and the desired pp component(s)

    Arguments:
        grid_type (str): One of: native or regrid-xy
        temporal_type (str): One of: temporal or static
        pp_component (str): all, or a space-separated list
    """
    logger.debug(f"Desired pp components: {pp_components_str}")
    pp_components = pp_components_str.split()
#    path_to_conf = os.path.dirname(os.path.abspath(__file__)) + '/../app/remap-pp-components/rose-app.conf'
#    node = metomi.rose.config.load(path_to_conf)

    # Path to yaml configuration
    exp_dir = Path(__file__).resolve().parents[1]
    path_to_yamlconfig = os.path.join(exp_dir, yamlfile)
    # Load and read yaml configuration 
    with open(path_to_yamlconfig,'r') as yml:
        yml_info = yaml.safe_load(yml)

    #
    results = []
    for comp_info in yml_info["postprocess"]["components"]:
        comp = comp_info.get("type")

        # Check that pp_components defined matches those in the yaml file
        # Skip component if they don't match
        # skip if pp component not desired
        logger.debug(f"Is {comp} in {pp_components}?")
        if comp in pp_components: 
            logger.debug('Yes')
        else:
            logger.debug('No')
            continue

#### CHECK THIS SECTION ####
        # Set grid type if component has xyInterp defined or not
        if "xyInterp" not in comp_info.keys():
            candidate_grid_type = "native"
        else:
            candidate_grid_type = "regrid-xy"

        # Check that candidate_grid_type matches grid type passed in function
        # If not, skip post-processing of component
        if candidate_grid_type != grid_type:
            logger.debug(f"Skipping as not right grid; got '{candidate_grid_type}' and wanted '{grid_type}'")
            continue

## original
#        # filter static and temporal
#        # if freq is not set             => temporal
#        # if freq includes "P0Y"         => static
#        # if freq does not include "P0Y" => temporal
#        freq = node.get_value(keys=[item, 'freq'])
#        if freq is not None and 'P0Y' in freq and temporal_type == 'temporal':
#            logger.debug("Skipping static when temporal is requested")
#            continue
#        if temporal_type == "static":
#            if freq is not None and 'P0Y' not in freq:
#                logger.debug("Skipping as static is requested, no P0Y here", freq)
#                continue
#        elif (temporal_type == "temporal"):
#            if freq is not None and 'P0Y' in freq:
#                logger.debug("Skipping as temporal is requested, P0Y here", freq)
#                continue
#        else:
#            raise Exception("Unknown temporal type:", temporal_type)
#
#        # convert array in string form to array
#        sources = ast.literal_eval(node.get_value(keys=[item, 'sources']))
#        results.extend(sources)

## rewrite
        # Filter static and temporal
        if temporal_type == "static":
            #print(comp_info["static"]["freq"])
            if "static" not in comp_info.keys():
                logger.debug("Skipping static as there is no static source")
                continue

            results = comp_info.get("static").get("sources")

        elif temporal_type == "temporal":
            results = results + comp_info.get("sources")

        else:
            raise Exception(f"Unknown temporal type: {temporal_type}")
            
    # results list --> set --> list: checks for repetitive sources listed
    answer = sorted(list(set(results)))

    # Returns a comma separated list of sources
    logger.debug("Returning string" + ', '.join(answer))
    return(', '.join(answer))

## TESTING ##
#print(form_task_parameters('regrid-xy', 'temporal', 'ocean_cobalt_sfc ocean_cobalt_btm', 'COBALT_postprocess.yaml')))
#print(form_task_parameters('regrid-xy', 'static', 'ocean_cobalt_sfc ocean_cobalt_btm', 'COBALT_postprocess.yaml'))
#print(form_task_parameters('native', 'temporal', 'ocean_cobalt_sfc ocean_cobalt_btm', 'COBALT_postprocess.yaml'))
#print(form_task_parameters('native', 'static', 'ocean_cobalt_sfc ocean_cobalt_btm', 'COBALT_postprocess.yaml'))
