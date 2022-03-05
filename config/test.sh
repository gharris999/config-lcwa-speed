#!/bin/bash

# See: https://unix.stackexchange.com/questions/588063/merging-multiple-json-file-into-one-object-using-jq-with-argument

# See: https://stackoverflow.com/questions/63046989/how-to-merge-multiple-json-files-in-a-directory-with-jq-or-any-tool


SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
SCRIPT_NAME="$(basename $0)"
SCRIPT_DESC="Creates the config.json file for the lcwa-speed service."


######################################################################################################
# Include the generic service install functions
######################################################################################################

REC_INCSCRIPT_VER=20201220
INCLUDE_FILE="$(dirname $(readlink -f $0))/../instsrv_functions.sh"
[ ! -f "$INCLUDE_FILE" ] && INCLUDE_FILE='/usr/local/sbin/instsrv_functions.sh'

if [ ! -f "$INCLUDE_FILE" ]; then
	echo "${SCRIPTNAME} error: cannot find include file ${INCLUDE_FILE}. Exiting."
	exit 1
fi

. "$INCLUDE_FILE"

if [[ -z "$INCSCRIPT_VERSION" ]] || [[ "$INCSCRIPT_VERSION" < "$REC_INCSCRIPT_VER" ]]; then
	echo "Error: ${INCLUDE_FILE} version is ${INCSCRIPT_VERSION}. Version ${REC_INCSCRIPT_VER} or newer is required."
fi



DEBUG=0
QUIET=0
TEST=0
VERBOSE=0
NO_PAUSE=0



############################################################################
# json_validate( src_json, dest_json ) -- validates and installs src to dest
############################################################################
json_validate(){
	debug_echo "${FUNCNAME[*]}( $@ )"
	local LSOURCE="$1"
	local LTARGET="$2"
	local LTEMP_FILE=
	local LSOURCE_NAME="$1"
	local LJQ="$3"
	local LRET=1
	local LCRET='0'
	
	[ -z "$LJQ" ] && LJQ="$(which jq)"
	
	if [ ! -f "$LSOURCE" ]; then
		error_echo "${FUNCNAME[*]}() Error: could not find ${LSOURCE}."
		return 1
	fi
	
	# If no target is supplied, just validate the source to see that it's valid json
	
	# If souce & target are the same, copy source to a temp file, validate that and
	# copy the reformatted and json-prettified back to the source..
	
	if [ "$LTARGET" = "$LSOURCE" ]; then
		LTEMP_FILE="$(mktemp --suffix=.json)"
		cp -p "$LSOURCE" "$LTEMP_FILE"
		LTARGET="$LSOURCE"
		LSOURCE="$LTEMP_FILE"
	fi
	
	# Validate the new json
	[ $VERBOSE -gt 0 ] && error_echo "${FUNCNAME[*]}(): Validating JSON in ${LSOURCE_NAME}.."
	
	# First pass.. use jq . rather than jq -e for old rpi versions of jq
	cat "$LSOURCE" | "$LJQ" . > /dev/null 2>&1
	LRET=$?
	[ $LRET -eq 0 ] && 	debug_echo "${FUNCNAME[*]}(): first pass vaidation OK" || debug_cat "$LSOURCE" "${FUNCNAME[*]}(): first pass vaidation NOTOK " 

	# Second pass: grep stderr for 'parse error'
	LCRET="$(cat "$LSOURCE" | "$LJQ" 2>&1 | grep -c 'parse error')"
	[ $LCRET -eq 0 ] && debug_echo "${FUNCNAME[*]}():  2nd pass vaidation OK" || debug_cat "$LSOURCE"  "${FUNCNAME[*]}():  2nd pass vaidation NOTOK " 

	if [ $LRET -eq 0 ] && [ $LCRET -eq 0 ]; then
		debug_echo "${FUNCNAME[*]}(): ${LSOURCE_NAME} passes json validation."
		if [ ! -z "$LTARGET" ]; then
			# backup original..
			[ ! -f "${LTARGET}.org" ] && cp -p "$LTARGET" "${LTARGET}.org"
			cp -p "$LTARGET" "${LTARGET}.bak"
			debug_echo "${FUNCNAME[*]}(): Copying ${LSOURCE_NAME} to ${LTARGET}.."
			cp -p "$LSOURCE" "$LTARGET"
			chmod 644 "$LTARGET"
			[ $VERBOSE -gt 0 ] && error_echo "${FUNCNAME[*]}(): ${LTARGET} is valid JSON."
		else 
			[ $VERBOSE -gt 0 ] && error_echo "${FUNCNAME[*]}(): ${LSOURCE_NAME} is valid JSON."
			
		fi
	else
		error_echo "{FUNCNAME[*]}() Error: ${LSOURCE_NAME} did not pass json validation."
		debug_cat "$LSOURCE_NAME"  "{FUNCNAME[*]}() Error: ${LSOURCE_NAME} did not pass json validation: "
		LRET=1
	fi
	
	# Clean up..
	[ ! -z "$LTEMP_JSON" ] && [ -f "$LTEMP_JSON" ] && rm "$LTEMP_JSON"
	
	debug_pause "${LINENO} -- ${FUNCNAME[*]}() done."
	
	return $LRET
}

json_modify(){
	debug_echo "${FUNCNAME[*]}( $@ )"
	local LSOURCE="$1"
	local LJSON="$2"
	local LJQ="$3"
	local LRET=1
	local LCRET='0'

	local LTEMP_JSON=
	
	[ -z "$LJQ" ] && LJQ="$(which jq)"
	
	if [ ! -f "$LSOURCE" ]; then
		error_echo "${FUNCNAME[*]}() Error: could not find ${LSOURCE}."
		return 1
	fi

	if [ -z "$LJSON" ]; then
		error_echo "${FUNCNAME[*]}() Error: JSON modifier is empty."
		return 1
	fi
	
	# is our JSON string valid?
	[ $VERBOSE -gt 0 ] && error_echo "${FUNCNAME[*]}():  Validating ${LJSON}"
	
	# First pass.. use jq . rather than jq -e for old rpi versions of jq
	"$LJQ" "$LJSON" "$LSOURCE" > /dev/null 2>&1
	LRET=$?
	[ $LRET -eq 0 ] && 	debug_echo "${FUNCNAME[*]}(): first pass vaidation OK" || debug_cat "$LSOURCE" "${FUNCNAME[*]}(): first pass vaidation NOTOK " 

	# Second pass: grep stderr for 'parse error'
	LCRET="$("$LJQ" "$LJSON" "$LSOURCE" | grep -c 'parse error')"
	[ $LCRET -eq 0 ] && debug_echo "${FUNCNAME[*]}():  2nd pass vaidation OK" || debug_cat "$LSOURCE"  "${FUNCNAME[*]}():  2nd pass vaidation NOTOK " 
	
	if [ $LRET -gt 0 ] || [ $LCRET -gt 0 ]; then
		error_echo  "{FUNCNAME[*]}() Error: ${LJSON} did not pass json validation."
		LRET=1
	fi
	
	# JSON is valid, now modify the source file:
	if [ $LRET -eq 0 ]; then
		LTEMP_JSON="$(mktemp --suffix=.json)"
		[ $VERBOSE -gt 0 ] && error_echo "${FUNCNAME[*]}():  Merging ${LJSON} and ${LSOURCE} to ${LTEMP_JSON}"
		jq "$LJSON" "$LSOURCE" >"$LTEMP_JSON"
		LRET=$?

		if [ $LRET -eq 0 ]; then
			json_validate "$LTEMP_JSON" "$LSOURCE" "$LJQ"
			LRET=$?
		fi
	fi

	# Clean up..
	[ ! -z "$LTEMP_JSON" ] && [ -f "$LTEMP_JSON" ] && rm "$LTEMP_JSON"
	
	debug_pause "${LINENO} -- ${FUNCNAME[*]}() done."
	return $LRET
	
}

#########################################################################################################
# clustercontrol_update( target.json, source.json ) Updates target with ClusterControl block from source.
#########################################################################################################
clustercontrol_update(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LLCWA_CONFFILE="${1:-${INST_CONFIG_JSON}}"
	local LREPO_CONFFILE="${2:-${INST_REPO_CONFIG_JSON}}"
	local LHOSTNAME=
	local LTEMP_JSON=
	local LTEMP_JSON2=
	local LJQ="$(which jq)"
	local LRET=1
	
	if [ -z "$LLCWA_CONFFILE" ] || [ ! -f "$LLCWA_CONFFILE" ]; then
		error_echo "Error: ${LLCWA_CONFFILE} json config file not found."
		return 1
	fi
	
	if [ -z "$LREPO_CONFFILE" ] || [ ! -f "$LREPO_CONFFILE" ]; then
		error_echo "Error: repo ${LLCWA_CONFFILE} json config file not found."
		return 1
	fi
	
	if [ -z "$LJQ" ]; then
		error_echo "${FUNCNAME}() Error: jq  command-line sjon processor not found."
		return 1
	fi
	
	[ $QUIET -lt 1 ] && error_echo "Updating ClusterControl block of ${LLCWA_CONFFILE}.."

	LTEMP_JSON="$(mktemp --suffix=.json)"
	
	# Strip the current ClusterControl from our json conf file.
	"$LJQ" 'del(.ClusterControl)' "$LLCWA_CONFFILE" >"$LTEMP_JSON"

	# Validate the json..
	json_validate "$LTEMP_JSON" "$LLCWA_CONFFILE" "$LJQ"
	LRET=$?
	if [ $LRET -gt 0 ]; then
		error_echo "Error: Could not validate ClusterControl removal from ${LLCWA_CONFFILE}"
		debug_cat "$LTEMP_JSON" "${FUNCNAME}() "
		[ -f "$LTEMP_JSON" ] && rm "$LTEMP_JSON"
		return 1
	fi
	
	debug_cat "$LLCWA_CONFFILE" "Done stripping ClusterControl from ${LLCWA_CONFFILE}: "
	
	# Merge in Andi's repo's json conf file with ours to a temp file..
	"$LJQ" -s ".[0] * .[1]" "$LREPO_CONFFILE" "$LLCWA_CONFFILE" >"$LTEMP_JSON"
	LRET=$?
	if [ $LRET -gt 0 ]; then
		debug_cat "$LTEMP_JSON" "Error: Could not validate ClusterControl merge from ${LREPO_CONFFILE}: "
		#~ error_echo "Error: Could not validate ClusterControl merge from ${LREPO_CONFFILE}"
		[ -f "$LTEMP_JSON" ] && rm "$LTEMP_JSON"
		return 1
	fi

	# Validate the merged json data in the temp file and add to ours..
	json_validate "$LTEMP_JSON" "$LLCWA_CONFFILE" "$LJQ"
	LRET=$?
	if [ $LRET -gt 0 ]; then
		error_echo "${FUNCNAME}() Error: Could not validate merged json data in ${LLCWA_CONFFILE}."
		[ -f "$LTEMP_JSON" ] && rm "$LTEMP_JSON"
		return 1
	fi
	
	debug_cat "$LLCWA_CONFFILE" "Done merging ClusterControl from ${LREPO_CONFFILE} to ${LLCWA_CONFFILE}: "
	

	# Make modifications to the ClusterControl blocks
	#	Make all runmodes "Both"
	
	[ $QUIET -lt 1 ] && error_echo "Modifying all ${LLCWA_CONFFILE} ClusterControl keys to runmode=\"Both\""
	
	for LHOSTNAME in LC{01..24}
	do
		json_modify "$LLCWA_CONFFILE" ".ClusterControl.${LHOSTNAME}.runmode=\"Both\""
		LRET=$?
		[ $LRET -gt 0 ] && break
	done
	
	if [ $LRET -gt 0 ]; then
		error_echo "${FUNCNAME}() Error: Could not modify ${LLCWA_CONFFILE} ClusterControl keys runmode value."
		debug_cat "$LTEMP_JSON" "${FUNCNAME}() "
		[ -f "$LTEMP_JSON" ] && rm "$LTEMP_JSON"
		return 1
	else 
		debug_cat "$LLCWA_CONFFILE" "Done fixing ${LLCWA_CONFFILE} ClusterControl keys runmode=\"Both\": "
	fi
	
	#	Make all iperf_duration "10"
	[ $QUIET -lt 1 ] && error_echo "Modifying all ${LLCWA_CONFFILE} ClusterControl keys to nondefault.iperf_duration=\"10\""
	for LHOSTNAME in LC{01..24}
	do
		json_modify "$LLCWA_CONFFILE" ".ClusterControl.${LHOSTNAME}.nondefault.iperf_duration=\"10\""
		LRET=$?
		[ $LRET -gt 0 ] && break
	done
	
	if [ $LRET -gt 0 ]; then
		error_echo "${FUNCNAME}() Error: Could not modify ${LLCWA_CONFFILE} ClusterControl keys .nondefault.iperf_duration value."
		debug_cat "$LTEMP_JSON" "${FUNCNAME}() "
		[ -f "$LTEMP_JSON" ] && rm "$LTEMP_JSON"
		return 1
	else 
		debug_cat "$LLCWA_CONFFILE" "Done fixing ${LLCWA_CONFFILE} ClusterControl keys nondefault.iperf_duration=\"10\": "
	fi
	
	
	# Create a ClusterControl block for ourselves
	
	LHOSTNAME="$(hostname)"
	
	# Are we an 'LC' box? If so, truncate our identifier at 4 characters..
	[ "$(echo "$LHOSTNAME" | grep -c -E "^LC[[:digit:]]{2}")" -gt 0 ] && LHOSTNAME="${LHOSTNAME:0:4}"
	
	# Do we already have a cluster control block?
	
	if [ "$("$LJQ" ".ClusterControl.${LHOSTNAME}" $LLCWA_CONFFILE)" = 'null' ]; then

		[ $QUIET -lt 1 ] && error_echo "Creating ClusterControl block for ${LHOSTNAME}.."

		cat <<- EOF_JSON2 | "$LJQ" '.' >"$LTEMP_JSON"
		{
		  "ClusterControl": {
			"${LHOSTNAME}": {
			  "runmode": "Both",
			  "nondefault": {
				"server_ip": "63.229.162.245",
				"serverid": 18002,
				"time_window": 10,
				"latency_ip": "65.19.14.51",
				"iperf_serverport": "5201",
				"iperf_serverip": "63.229.162.245",
				"iperf_duration": 10,
				"iperf_numstreams": 2,
				"iperf_blksize": 1024,
				"iperf_latency_ip": "65.19.14.51",
				"iperf_time_window": 10,
				"iperf_reverse": false,
				"random": false
			  }
			}
		  }
		}    
		EOF_JSON2
		LRET=$?
	
		# Is that valid json?
		if [ $LRET -gt 0 ]; then
			error_echo "${FUNCNAME}() Error: Invalid JSON ClusterControl block in ${LTEMP_JSON}."
			[ -f "$LTEMP_JSON" ] && rm "$LTEMP_JSON"
			return 1
		fi

		# Merge in our ClusterControl block..
		LTEMP_JSON2="$(mktemp --suffix=.json)"

		"$LJQ" -s ".[0] * .[1]" "$LLCWA_CONFFILE" "$LTEMP_JSON" >"$LTEMP_JSON2"
		LRET=$?
		if [ $LRET -gt 0 ]; then
			error_echo "Error: Could not validate ClusterControl merge from ${LREPO_CONFFILE}"
			[ -f "$LTEMP_JSON" ] && rm "$LTEMP_JSON"
			return 1
		fi
	
		# Validate the merged json data..
		json_validate "$LTEMP_JSON2" "$LLCWA_CONFFILE" "$LJQ"
		LRET=$?
		if [ $LRET -gt 0 ]; then
			error_echo "${FUNCNAME}() Error: Could not validate merged json data in ${LLCWA_CONFFILE}."
			[ -f "$LTEMP_JSON" ] && rm "$LTEMP_JSON"
			[ -f "$LTEMP_JSON2" ] && rm "$LTEMP_JSON2"
			return 1
		fi
		
	fi
	

	[ $QUIET -lt 1 ] && error_echo "ClusterControl update of ${LLCWA_CONFFILE} complete."
	
	# Clean up..
	[ ! -z "$LTEMP_JSON" ] && [ -f "$LTEMP_JSON" ] && rm "$LTEMP_JSON"
	[ ! -z "$LTEMP_JSON2" ] && [ -f "$LTEMP_JSON2" ] && rm "$LTEMP_JSON2"
	
	debug_pause "${LINENO} -- ${FUNCNAME}() done."
	return $LRET
	
}

config_json_create_new(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LCONF_JSON_FILE="${1:-${LCWA_CONFFILE}}"
	local LREPO_JSON_FILE="${2:-${LCWA_REPO_LOCAL_CONF}}"
	local LRET=1
	
	return $LRET
}
	

####################################################################################################
# config_json_create( conf_json_file_path, andi_scr_dir, data_dir, runmode [Both|Iperf|Speedtest] )
#   Creates a config.json file (sans ClusterControl) with our paths.
#   Subsequent call to clustercontrol_update will fill in any blanks.
####################################################################################################
config_json_create(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LCONF_JSON_FILE="${1:-${LCWA_CONFFILE}}"
	local LSRC_DIR="${2:-${LCWA_REPO_LOCAL}/src}"
	local LDATA_DIR="${3:-${LCWA_DATADIR}}"
	local LRUN_MODE="${4:-Both}"
	local LCONF_DIR="${5:-${LCWA_CONFDIR}}"
	local LTIMEOUT_BIN="$(which timeout)"
	local LOOKLA_BIN="$(which speedtest)"
	local LJQ="$(which jq)"
	local LRET=1
	
	# Arg error checking
	if [ -z "$LCONF_JSON_FILE" ]; then
		error_echo "${FUNCNAME}() Error: no configuration file specified."
		return 1
	fi
	
	# Skip directory exists check if in test mode..
	if [ $TEST -lt 1 ]; then
		if [ -z "$LSRC_DIR" ] || [ ! -d "$LSRC_DIR" ]; then
			error_echo "${FUNCNAME}() Error: incorrect source directory specified."
			return 1
		fi
	fi
	
	if [ -z "$LDATA_DIR" ]; then
		error_echo "${FUNCNAME}() Error: no data directory specified."
		return 1
	fi

	if [ -z "$LTIMEOUT_BIN" ] || [ -z "$LOOKLA_BIN" ]; then
		error_echo "${FUNCNAME}() Error: Could not find timeout binary and/or ookla speedtest binary."
		return 1
	fi
	
	if [ -z "$LJQ" ]; then
		error_echo "${FUNCNAME}() Error: jq binary not installed."
		return 1
	fi
	
	
	# Properly terminate the src & speedfiles directory paths..
	LSRC_DIR="$(readlink -f "$LSRC_DIR")/"
	LDATA_DIR="$(readlink -f "$LDATA_DIR")/"

	# Create needed directories
	[ ! -d "$LDATA_DIR" ] && mkdir -p "$LDATA_DIR"
	[ ! -d "$LCONF_DIR" ] && mkdir -p "$LCONF_DIR"
	
	# Write the config file 
	touch "$LCONF_JSON_FILE"
	
	if [ ! -f "$LCONF_JSON_FILE" ]; then
		error_echo "${FUNCNAME}() Error: could not create ${LCONF_JSON_FILE}."
		return 1
	fi
	
	[ $QUIET -lt 1 ] && error_echo "Creating ${LCONF_JSON_FILE}.."


	# Write our initial conf.json using our corrected paths..
	cat <<- EOF_JSON1 | "$LJQ" '.' >"$LCONF_JSON_FILE"
	{
	  "Darwin": {
		"timeout": "${LTIMEOUT_BIN}",
		"speedtest": "${LOOKLA_BIN}",
		"srcdir": "${LSRC_DIR}",
		"datadir": "${LDATA_DIR}",
		"conf_dir": "${LCONF_DIR}"
	  },
	  "Linux": {
		"timeout": "${LTIMEOUT_BIN}",
		"speedtest": "${LOOKLA_BIN}",
		"srcdir": "${LSRC_DIR}",
		"datadir": "${LDATA_DIR}",
		"conf_dir": "${LCONF_DIR}"
	  },
	  "Control": {
		"runmode": "${LRUN_MODE}",
		"debug": false,
		"cryptofile": "${LCONF_DIR}/LCWA_d.txt",
		"click": "1",
		"random": false
	  },
	  "Iperf": {
		"iperf_serverport": "5201",
		"iperf_serverip": "63.229.162.245",
		"iperf_duration": 10,
		"iperf_numstreams": 2,
		"iperf_blksize": 1024,
		"iperf_latency_ip": "65.19.14.51",
		"iperf_time_window": 10,
		"iperf_reverse": false
	  },
	  "Speedtest": {
		"serverip": "63.229.162.245",
		"serverid": 18002,
		"time_window": 10,
		"latency_ip": "65.19.14.51"
	  }
	}
	EOF_JSON1
	LRET=$?
	
	if [ $LRET -gt 0 ]; then
		error_echo "${FUNCNAME}() Error: Invalid JSON block(s) in ${LCONF_JSON_FILE}."
	else
		[ $QUIET -lt 1 ] && error_echo "${LCONF_JSON_FILE} created."
	fi
	
	debug_cat "$LCONF_JSON_FILE" "${FUNCNAME[*]}() done, returning ${LRET}: "
	#~ debug_pause "${LINENO} -- ${FUNCNAME}() done, returning ${LRET}."
	return $LRET
}

error_exit(){
	error_echo $@
	exit 1
}


clear
echo '####################################################################################'


#~ SOURCE_JSON="test_speed_cfg.json"
#~ TARGET_JSON="lcwa-speed.json"

LCWA_DATADIR="$(readlink -f ./)"

LCWA_CONFDIR="$(readlink -f ./)"

LCWA_REPO_LOCAL='..'

LREPO_CONFFILE="./test_speed_cfg.json"
#~ LLCWA_CONFFILE="./lcwa-speed.json"
LCWA_CONFFILE="./lcwa-speed.json"

LTEMPFILE='results.json'

# Rest files to originals..
cp -p test_speed_cfg.json.org test_speed_cfg.json
#~ cp -p lcwa-speed.json.org lcwa-speed.json
rm "$LCWA_CONFFILE"

LJQ=$(which jq)


#######################################################################################################
# VERBATUM from config-lcwa-speed-jsonconf.sh

# Validate Andi's config.json
INST_REPO_CONFIG_JSON="${LCWA_REPO_LOCAL}/config/test_speed_cfg.json"

json_validate "$INST_REPO_CONFIG_JSON" || error_exit "${SCRIPT_NAME} error: ${INST_REPO_CONFIG_JSON} contains invalid json.  Exiting."

# Create the json file..
config_json_create "$LCWA_CONFFILE" || error_exit "${SCRIPT_NAME} error: ${LCWA_CONFFILE} contains invalid json.  Exiting."
#~ config_json_create_new "$LCWA_CONFFILE" "$INST_REPO_CONFIG_JSON" || error_exit "${SCRIPT_NAME} error: ${LCWA_CONFFILE} contains invalid json.  Exiting."

#~ pause "config_json_create() done. Press any key to continue.."

# Add the cluster control block from Andi's config.json
clustercontrol_update "$LCWA_CONFFILE" "$INST_REPO_CONFIG_JSON" || error_exit "${SCRIPT_NAME} error: could not update ${LCWA_CONFFILE} ClusterControl block from ${INST_REPO_CONFIG_JSON}. Exiting."


#######################################################################################################
# MODS HERE

# Modify the iperf durration for this host
#~ MY_HOST="$(hostname)"
#~ [ "${MY_HOST:0:2}" = 'LC' ] && MY_HOST="${MY_HOST:0:4}"

	# jq ".ClusterControl.${MY_HOST}.nondefault.iperf_duration |= 10" lcwa-speed-beta.json

#~ json_modify "$LCWA_CONFFILE" ".ClusterControl.${MY_HOST}.nondefault.iperf_duration |= 10"

# View the differences between Andi's original and ours..
[ $DEBUG -gt 0 ] && diff -ZbwB "$LCWA_CONFFILE" "$INST_REPO_CONFIG_JSON"
