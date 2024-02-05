#!/bin/bash
######################################################################################################
# Bash script for installing dependencies required for Andi Klein's Python LCWA PPPoE Speedtest Logger
#   A python3 venv will be installed to /usr/local/share/lcwa-speed
######################################################################################################
SCRIPT_VERSION=20240204.222312

SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
SCRIPT_NAME="$(basename $0)"
SCRIPT_DESC="Installs system and python library dependencies for the lcwa-speed service."


######################################################################################################
# Include the generic service install functions
######################################################################################################

REC_INCSCRIPT_VER=20201220
INCLUDE_FILE="$(dirname $(readlink -f $0))/instsrv_functions.sh"
[ ! -f "$INCLUDE_FILE" ] && INCLUDE_FILE='/usr/local/sbin/instsrv_functions.sh'

if [ ! -f "$INCLUDE_FILE" ]; then
	echo "${SCRIPT_NAME} error: cannot find include file ${INCLUDE_FILE}. Exiting."
	exit 1
fi

. "$INCLUDE_FILE"

if [[ -z "$INCSCRIPT_VERSION" ]] || [[ "$INCSCRIPT_VERSION" < "$REC_INCSCRIPT_VER" ]]; then
	echo "Error: ${INCLUDE_FILE} version is ${INCSCRIPT_VERSION}. Version ${REC_INCSCRIPT_VER} or newer is required."
fi

######################################################################################################
# Vars
######################################################################################################

DEBUG=0
QUIET=0
VERBOSE=0
FORCE=0
TEST=0
UNINSTALL=0

INST_NAME='lcwa-speed'
INST_PROD="LCWA Python3 PPPoE Speedtest Logger"
INST_DESC='LCWA PPPoE Speedtest Logger Daemon'

INST_INSTANCE_NAME="$INST_NAME"
INST_SERVICE_NAME="$INST_NAME"


INST_USER="$INST_NAME"
if [ $IS_DEBIAN -gt 0 ]; then
	INST_GROUP='nogroup'
else
	INST_GROUP="$INST_NAME"
fi

NEEDSUSER=1
NEEDSCONF=1
NEEDSDATA=1
NEEDSLOG=1

NO_CLEAN=1
KEEP=0
#~ KEEPCACHE=0
#~ KEEPDATA=0
#~ KEEPREPO=0

######################################################################################################
# Incude our env vars declaration file..
######################################################################################################

INCLUDE_FILE="$(dirname $(readlink -f $0))/lcwa-speed-env.sh"
[ ! -f "$INCLUDE_FILE" ] && INCLUDE_FILE='/usr/local/sbin/lcwa-speed-env.sh'

if [ ! -f "$INCLUDE_FILE" ]; then
	error_echo "${SCRIPT_NAME} error: Could not find env vars declaration file ${INCLUDE_FILE}. Exiting."
	exit 1
fi

debug_echo "Including file: ${INCLUDE_FILE}"

. "$INCLUDE_FILE"


lcwa_conf_dir_create(){
	debug_echo "${FUNCNAME}( $@ )"
	local LLCWA_CONFDIR="${1:-${LCWA_CONFDIR}}"

	if [ ! -d "$LLCWA_CONFDIR" ]; then
		[ $QUIET -lt 1 ] && error_echo "Creating ${LLCWA_CONFDIR} conf dir for ${LCWA_USER}.."
		conf_dir_create "$LLCWA_CONFDIR"
	fi

	debug_echo "${LINENO} -- ${FUNCNAME}() done."

	[ -d "$LLCWA_CONFDIR" ] && return 0 || return 1
}



lcwa_instance_dir_create(){
	debug_echo "${FUNCNAME}( $@ )"
	local LINST_DIR="${1:-${LCWA_INSTDIR}}"

	[ $VERBOSE -gt 0 ] && error_echo "Making ${LINST_DIR} the home dir for ${INST_USER}.."
	usermod "--home=${LINST_DIR}" "$LCWA_USER"
	
	if [ ! -d "$LINST_DIR" ]; then
		[ $VERBOSE -gt 0 ] && error_echo "Creating ${LINST_DIR} home dir for ${INST_USER}.."
		mkdir -p "$LINST_DIR"
	fi

	[ $VERBOSE -gt 0 ] && error_echo "Fixing permissions for ${LCWA_USER}:${LCWA_GROUP} on ${LINST_DIR}.."
	chown --silent -R "${LCWA_USER}:${LCWA_GROUP}" "$LINST_DIR"

	debug_echo "${LINENO} -- ${FUNCNAME}() done."

	[ -d "$LINST_DIR" ] && return 0 || return 1
}

lcwa_home_dir_create(){
	debug_echo "${FUNCNAME}( $@ )"
	local LLCWA_HOMEDIR="${1:-${LCWA_HOMEDIR}}"

	if [ ! -d "$LLCWA_HOMEDIR" ]; then
		[ $VERBOSE -gt 0 ] && error_echo "Creating ${LLCWA_HOMEDIR} home dir for ${LCWA_USER}.."
		mkdir -p "$LLCWA_HOMEDIR"
	fi

	[ $VERBOSE -gt 0 ] && error_echo "Fixing permissions for ${LCWA_USER}:${LCWA_GROUP} on ${LLCWA_HOMEDIR}.."
	chown --silent -R "${LCWA_USER}:${LCWA_GROUP}" "$LLCWA_HOMEDIR"

	debug_echo "${LINENO} -- ${FUNCNAME}() done."

	[ -d "$LLCWA_HOMEDIR" ] && return 0 || return 1
}


lcwa_log_dir_create(){
	debug_echo "${FUNCNAME}( $@ )"
	local LLCWA_LOGDIR="${1:-${LCWA_LOGDIR}}"
	local LLOG=

	# Create a log dir
	log_dir_create "$LCWA_LOGDIR"

	for LLOG in "$LCWA_LOGFILE" "$LCWA_ERRFILE" "$LCWA_VCLOG"
	do
		LLOG="${LLCWA_LOGDIR}/$(basename "$LLOG")"
		debug_echo "Touching ${LLOG}.."
		touch "$LLOG"
	done

	[ $VERBOSE -gt 0 ] && error_echo "Fixing permissions for ${LCWA_USER}:${LCWA_GROUP} on ${LLCWA_LOGDIR}.."
	chown --silent -R "${LCWA_USER}:${LCWA_GROUP}" "$LLCWA_LOGDIR"

	# Create the log rotate scripts using wildcards..
	log_rotate_script_create "${LLCWA_LOGDIR}/*.log"
	
	debug_echo "${LINENO} -- ${FUNCNAME}() done."

	[ -d "$LLCWA_LOGDIR" ] && return 0 || return 1
}


# Clean up from previous install attempts..
clean_up(){
	debug_echo "${FUNCNAME}( $@ )"
	

	# Remove the config files..
	conf_dir_remove "$LCWA_CONFDIR"
	
	# Remove the env file..
	env_file_remove "$LCWA_ENVFILE"

	# Delete any fake homedir -- may have a partial pip cache
	if [ -d "/home/${LCWA_USER}" ]; then
		# Make sure the home directory is really fake!
		# lcwa-speed:x:113:65534: user account,,,:/home/lcwa-speed:/usr/sbin/nologin
		
		if [ $(grep -c -E "${LCWA_USER}:.*/nologin" /etc/passwd) -gt 0 ]; then
			[ $QUIET -lt 1 ] && error_echo "Deleteing /home/${LCWA_USER}"
			[ $TEST -lt 1 ] && rm -Rf "/home/${LCWA_USER}"
		fi
	fi
	
	# Delete the install dir -- this is the venv python environment and the local repos
	if [ -d "$LCWA_INSTDIR" ]; then
		[ $QUIET -lt 1 ] && error_echo "Deleteing ${LCWA_INSTDIR}"
		[ $TEST -lt 1 ] && rm -Rf "$LCWA_INSTDIR"
	fi
	
	# Delete the cache & data dir tree
	if [ $KEEPCACHE -lt 1 ] && [ $KEEPDATA -lt 1 ] && [ -d "$LCWA_HOMEDIR" ]; then
		[ $QUIET -lt 1 ] && error_echo "Deleteing ${LCWA_HOMEDIR}"
		[ $TEST -lt 1 ] && rm -Rf "$LCWA_HOMEDIR"
	fi
	
	# Delete the log dir
	if [ -d "$LCWA_LOGDIR" ]; then
		[ $QUIET -lt 1 ] && error_echo "Deleteing ${LCWA_LOGDIR}"
		[ $TEST -lt 1 ] && rm -Rf "$LCWA_LOGDIR"
	fi
	
	# Delete the log rotate script
	log_rotate_script_remove "$LCWA_INSTANCE"
	
	# Delete the user account.
	inst_user_remove "$LCWA_USER"
	
	debug_echo "${LINENO} -- ${FUNCNAME}() done."
}

##################################################################################
##################################################################################
##################################################################################
# main()
##################################################################################
##################################################################################
##################################################################################

PRE_ARGS="$@"

# Make sure we're running as root 
is_root

# Declare our environmental variables and zero them..
env_vars_zero $(env_vars_name)

SHORTARGS='hdqvftk'

LONGARGS="
help,
debug,
quiet,
verbose,
test,
force,
keep,
clean,
uninstall,
remove,
inst-name:,
service-name:,
env-file:"

# Remove line-feeds..
LONGARGS="$(echo "$LONGARGS" | sed ':a;N;$!ba;s/\n//g')"

ARGS=$(getopt -o "$SHORTARGS" -l "$LONGARGS"  -n "$(basename $0)" -- $@)

if [ $? -gt 0 ]; then
	disp_help "$SCRIPT_DESC"
	exit 1
fi

eval set -- "$ARGS"

# Check args..
while test $# -gt 0
do
	case "$1" in
		--)
			;;
		-h|--help)			# Displays this help
			disp_help "$SCRIPT_DESC"
			exit 0
			;;
		-d|--debug)			# Shows debugging info
			((DEBUG+=1))
			;;
		-q|--quiet)			# Supresses message output
			QUIET=1
			;;
		-t|--test)			# Tests script logic without performing actions
			((TEST+=1))
			;;
		-f|--force)			# Force overwriting of an existing env file.
			FORCE=1
			;;
		-k|--keep)			# Retains local venv, repos and the speedfile data when uninstalling
			KEEP=1
			KEEPCACHE=1
			KEEPDATA=1
			;;
		--uninstall|--remove)	# Deletes all service directories, config files and the service user account.
			UNINSTALL=1
			;;
		-c|--clean)			# Cleans and deletes previous install before reinstalling.
			NO_CLEAN=0
			;;
		--inst-name)		# =NAME -- Instance name that defines the install location: /usr/local/share/NAME and user account name -- defaults to lcwa-speed.
			shift
			INST_INSTANCE_NAME="$1"
			LCWA_INSTANCE="$1"
			INST_NAME="$LCWA_INSTANCE"
			;;
		--service-name)			# =NAME -- Defines the name of the service: /lib/systemd/system/NAME.service -- defaults to lcwa-speed.
			shift
			# arg can be a path to the env_file
			INST_SERVICE_NAME="$1"
			LCWA_SERVICE="$(basename "$INST_SERVICE_NAME")"
			;;
		--env-file)				# =NAME -- Read a specific env file to get the locations for the install.
			shift
			LCWA_ENVFILE="$1"
			[ -f "$LCWA_ENVFILE" ] && LCWA_ENVFILE="$(readlink -f "$LCWA_ENVFILE")" || LCWA_ENVFILE=
			;;
		*)
			;;
	esac
	shift
done

[ $VERBOSE -gt 0 ] && error_echo "${SCRIPTNAME} ${PRE_ARGS}"


# Default overrides:
[ $TEST -gt 1 ] && INST_SERVICE_NAME="./${INST_SERVICE_NAME}"

if [ ! -z "$LCWA_ENVFILE" ]; then
	LCWA_INSTANCE=
	LCWA_SERVICE=
	[ $VERBOSE -gt 0 ] && error_echo "Getting instance information from ${LCWA_ENVFILE}."
	env_file_read "$LCWA_ENVFILE"
	if [ $? -gt 0 ]; then
		error_echo "${SCRIPT_NAME} fatal error: could not read from ${LCWA_ENVFILE}. Exiting."
		exit 1
	fi
#~ elif [ $FORCE -lt 1 ] && [ ! -z "$INST_SERVICE_NAME" ] && (env_file_exists "$INST_SERVICE_NAME"); then
	#~ LCWA_ENVFILE="$(env_file_exists "$INST_SERVICE_NAME" 'true')"
	#~ env_vars_defaults_get
	#~ [ $QUIET -lt 1 ] && error_echo "Modifying default dependency install targets from ${LCWA_ENVFILE}."
	#~ env_file_read "$INST_SERVICE_NAME"
	#~ [ $UNINSTALL -lt 1 ] && env_file_create "$INST_SERVICE_NAME" $(env_vars_name)
else
	env_vars_defaults_get
	# Create the env file (for this specific service of the instance)
	[ $UNINSTALL -lt 1 ] && env_file_create "$INST_SERVICE_NAME" $(env_vars_name)
fi

INST_NAME="$LCWA_INSTANCE"
INST_INSTANCE_NAME="$LCWA_INSTANCE"
INST_SERVICE_NAME="$LCWA_SERVICE"

if [ $DEBUG -gt 1 ]; then
	env_vars_show $(env_vars_name)
	debug_pause "Press any key to continue.."
fi

if [ $DEBUG -gt 0 ]; then
	error_echo "=========================================="
	error_echo "              DEBUG == ${DEBUG}"
	error_echo "              QUIET == ${QUIET}"
	error_echo "            VERBOSE == ${VERBOSE}"
	error_echo "              FORCE == ${FORCE}"
	error_echo "               TEST == ${TEST}"
	error_echo "          UNINSTALL == ${UNINSTALL}"
	error_echo "               KEEP == ${KEEP}"
	error_echo "           NO_CLEAN == ${NO_CLEAN}"
	error_echo "=========================================="
	error_echo "       LCWA_ENVFILE == ${LCWA_ENVFILE}"
	error_echo "=========================================="
	error_echo "          LCWA_USER == ${LCWA_USER}"
	error_echo "         LCWA_GROUP == ${LCWA_GROUP}"
	error_echo "=========================================="
	error_echo "      LCWA_INSTANCE == ${LCWA_INSTANCE}"
	error_echo "       LCWA_SERVICE == ${LCWA_SERVICE}"
	error_echo "       LCWA_CONFDIR == ${LCWA_CONFDIR}"
	error_echo "       LCWA_INSTDIR == ${LCWA_INSTDIR}"
	error_echo "       LCWA_HOMEDIR == ${LCWA_HOMEDIR}"
	error_echo "       LCWA_DATADIR == ${LCWA_DATADIR}"
	error_echo "        LCWA_LOGDIR == ${LCWA_LOGDIR}"
	error_echo "    LCWA_REPO_LOCAL == ${LCWA_REPO_LOCAL}"
	error_echo "=========================================="
	error_echo " LCWA_PPPOE_INSTALL == ${LCWA_PPPOE_INSTALL}"
	error_echo "LCWA_PPPOE_PROVIDER == ${LCWA_PPPOE_PROVIDER}"
	error_echo "LCWA_PPPOE_PASSWORD == ${LCWA_PPPOE_PASSWORD}"
	error_echo "=========================================="
	error_echo "               HOME == ${HOME}"
	error_echo "=========================================="
	debug_pause "Press any key to continue.."
fi

if [ $UNINSTALL -gt 0 ]; then
	# Do nothing if asked to keep
	[ $KEEP -gt 0 ] && exit 0

	# Remove the log_dir & logrotate scripts
	[ $QUIET -lt 1 ] && error_echo "Removing ${LCWA_LOGDIR}.."
	[ $TEST -lt 1 ] && rm -Rf "$LCWA_LOGDIR"
	[ $TEST -lt 1 ] && log_rotate_script_remove "$LCWA_LOGFILE"
	
	# Delete the data dir
	[ $QUIET -lt 1 ] && error_echo "Removing ${LCWA_HOMEDIR}.."
	[ $TEST -lt 1 ] && rm -Rf "$LCWA_HOMEDIR"
	
	# delete the instance dir
	[ $QUIET -lt 1 ] && error_echo "Removing ${LCWA_INSTDIR}.."
	[ $TEST -lt 1 ] && rm -Rf "$LCWA_INSTDIR"
	
	# Remove the conf dir
	[ $QUIET -lt 1 ] && error_echo "Removing ${LCWA_CONFDIR}.."
	[ $TEST -lt 1 ] && rm -Rf "$LCWA_CONFDIR"
	
	# Remove the envfile
	[ $TEST -lt 1 ] && env_file_remove "$LCWA_ENVFILE"

	# Remove the user account
	[ $TEST -lt 1 ] && inst_user_remove "$LCWA_USER"
	
else

	# Start with a fresh slate..
	if [ $NO_CLEAN -lt 1 ] || [ $UNINSTALL -gt 0 ]; then
		clean_up
		[ $UNINSTALL -gt 0 ] && exit 0
	fi	

	# Create the service account
	inst_user_create "$LCWA_USER"

	lcwa_instance_dir_create "$LCWA_INSTDIR"

	lcwa_home_dir_create "$LCWA_HOMEDIR"

	data_dir_create "$LCWA_DATADIR"

	lcwa_log_dir_create "$LCWA_LOGDIR"

fi



