#!/bin/bash
#!/bin/bash

######################################################################################################
# Bash script for installing Andi Klein's Python LCWA PPPoE Speedtest Logger
# as a service on systemd systems
######################################################################################################
SCRIPT_VERSION=20240202.165455
SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
SCRIPT_NAME=$(basename $0)
SCRIPT_DESC="Systemd service wrapper configuration script for python speedtest daemon."

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

# Locale setting override..
export LC_ALL=C

DEBUG=0
QUIET=0
VERBOSE=0
FORCE=0
TEST=0
NO_PAUSE=0
UPDATE=0
UNINSTALL=0

CUR_HOME="$HOME"

######################################################################################################
# Vars specific to this service install
######################################################################################################

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

######################################################################################################
# Incude our env vars declaration file..
######################################################################################################

# Definitions of all the variables needed to install the repos and the service & timer unit files
INCLUDE_FILE="${SCRIPT_DIR}/scripts/lcwa-speed-env.sh"
[ ! -f "$INCLUDE_FILE" ] && INCLUDE_FILE="${SCRIPT_DIR}/lcwa-speed-env.sh"
[ ! -f "$INCLUDE_FILE" ] && INCLUDE_FILE='/usr/local/sbin/lcwa-speed-env.sh'

if [ ! -f "$INCLUDE_FILE" ]; then
	error_echo "${SCRIPT_NAME} error: Could not find env vars declaration file ${INCLUDE_FILE}. Exiting."
	exit 1
fi

debug_echo "Including file: ${INCLUDE_FILE}"

. "$INCLUDE_FILE"

instsrv_functions_update(){
	debug_echo "${FUNCNAME}( $@ )"
	local LSCRIPT='instsrv_functions.sh'
	local LSOURCE="$(readlink -f "${SCRIPT_DIR}/${LSCRIPT}")"
	local LTARGET="/usr/local/sbin/${LSCRIPT}"

	if [ ! -f "$LSOURCE" ]; then
		error_exit "${SCRIPT_NAME}::${FUNCNAME}() error: Cannot find ${LSOURCE}. Exiiting."
	fi

	if [ ! -f "$LTARGET" ]; then
		[ $QUIET -lt 1 ] && error_echo "Copying ${LSCRIPT} to ${LTARGET}.."
		cp -p "$LSOURCE" "$LTARGET"
		if [ -f "$LTARGET" ]; then
			return 0
		else
			error_exit "${SCRIPT_NAME}::${FUNCNAME}() error: Could not install ${LSOURCE}. Exiiting."
		fi
	fi

	local LSOURCE_VER="$(grep -E '^INCSCRIPT_VERSION' "$LSOURCE" | sed -n -e 's/^.*=\(.*\)/\1/p')"
	local LTARGET_VER="$(grep -E '^INCSCRIPT_VERSION' "$LTARGET" | sed -n -e 's/^.*=\(.*\)/\1/p')"

	if [[ "$LSOURCE_VER" < "$LTARGET_VER" ]]; then
		echo "Warning: ${LTARGET} version ${LTARGET_VER} is newer than ${LSOURCE} version ${LSOURCE_VER}."
		return
	fi

	cp -p "$LSOURCE" "$LTARGET"
	if [ -f "$LTARGET" ]; then
		return 0
	else
		error_exit "${SCRIPT_NAME}::${FUNCNAME}() error: Could not install ${LSOURCE}. Exiiting."
	fi

	
}

inst_script_execute(){
	debug_echo "============================================================================================"
	debug_echo "${FUNCNAME}( $@ )"
	local LSCRIPT_NAME="$1"
	local LSCRIPT_ARGS="${@:2}"
	local LSCRIPT_FILE=
	local LRET=
	
	LSCRIPT_FILE="${SCRIPT_DIR}/scripts/${LSCRIPT_NAME}"
	[ ! -f "$LSCRIPT_FILE" ] && LSCRIPT_FILE="${SCRIPT_DIR}/${LSCRIPT_NAME}"
	
	if [ ! -f "$LSCRIPT_FILE" ]; then
		error_echo "${SCRIPT_NAME} error: could not find script ${LSCRIPT_NAME}."
		return 1
	fi

	[ $QUIET -lt 1 ] && error_echo ' '
	[ $QUIET -lt 1 ] && error_echo "Executing ${LSCRIPT_FILE} ${LSCRIPT_ARGS}"
	[ $TEST -lt 1 ] && "$LSCRIPT_FILE" "$LSCRIPT_ARGS"
	LRET=$?
	
	[ $VERBOSE -gt 0 ] && error_echo "${LSCRIPT_NAME}(${LSCRIPT_ARGS}) returned ${LRET}"
	
	debug_echo ' '
	debug_echo ' '
	debug_echo ' '
	debug_echo "--------------------------------------------------------------------------------------------"
	debug_echo "${SCRIPT_NAME}::${FUNCNAME}( ${LSCRIPT_NAME} ${LSCRIPT_ARGS} ) DONE, returning ${LRET}"
	debug_echo "--------------------------------------------------------------------------------------------"
	debug_pause "${LINENO}"
	debug_echo ' '
	return $LRET
}

#------------------------------------------------------------------------------
# banner_display() -- Script banner and warnings..
#------------------------------------------------------------------------------
banner_display(){
	local LSERVICE_TYPE='systemd'

	#~ LCWA_REPO
	#~ LCWA_REPO_BRANCH
	#~ LCWA_REPO_LOCAL


	error_echo "========================================================================================="
	if [ $UNINSTALL -gt 0 ]; then
		echo "This script REMOVES the ${LCWA_DESC} \"${INST_NAME}\" ${LSERVICE_TYPE} service,"
		echo "running under the \"${INST_USER}\" system account."
		echo ' '

		if [ $KEEPLOCALREPO -gt 0 ]; then
			echo "The local repo at ${LCWA_REPO_LOCAL} will be RETAINED."
		else
			echo "The local repo at ${LCWA_REPO_LOCAL} WILL BE DELETED."
		fi

		echo ' '

		if [ $KEEPLOCALDATA -gt 0 ]; then
			echo "The data dir /var/lib/${INST_NAME}_data and logs at /var/log/${INST_NAME}_log"
			echo "will be RETAINED along with the ${INST_USER} account."
		else
			echo "The data dir /var/lib/${INST_NAME}_data and logs at /var/log/${INST_NAME}_log"
			echo "WILL BE DELETED along with the ${INST_USER} account."
		fi

	else
		echo "This script installs the ${LCWA_DESC} as the ${LSERVICE_TYPE} controlled"
		echo "\"${INST_NAME}\" service, running under the \"${INST_USER}\" system account."
		echo ' '
		echo "The source for the git clone will be \"${LCWA_REPO}\"."
		echo ' '
		echo "The destination for the ${LCWA_REPO_BRANCH} code will be \"${LCWA_REPO_LOCAL}\"."
	fi
	echo ' '
	echo ' '
	if [ $NO_PAUSE -lt 1 ]; then
		pause 'Press Enter to continue, or ctrl-c to abort..'
	fi
}

#------------------------------------------------------------------------------
# finish()
#------------------------------------------------------------------------------
finish_display(){
	# Start the service..
	#service $INSTNAME start
	error_echo "========================================================================================="
	echo "Done. ${INST_DESC} is ready to run as a service (daemon)."
	echo ' '
	if [ $USE_UPSTART -gt 0 ]; then
		CMD="initctl start ${INST_NAME}"
	elif [ $USE_SYSTEMD -gt 0 ]; then
		CMD="systemctl start ${INST_NAME}.service"
	else
		CMD="service ${INST_NAME} start"
	fi

	if [[ $USE_UPSTART -gt 0 ]] || [[ $USE_SYSTEMD -gt 0 ]]; then
		echo "Run the command \"${CMD}\" to start the service."
		echo ' '
		echo "Run the command \"${LCWA_DEBUG_SCRIPT}\" to start the service"
		echo "in debugging mode.  Check the ${LCWA_LOGDIR}/${INST_NAME}-debug.log"
		echo "file for messages."
		echo ' '
		echo "To update the local git repo with the latest channges from"
		echo "${LCWA_REPO}, run the command:"
		echo ' '
		echo "${LCWA_UPDATE_SCRIPT}"
		echo ' '
	else
		echo "Run the command \"service ${INST_NAME} start\" to start the service."
		echo ' '
		echo "Run the command \"service ${INST_NAME} update\" to update ${LCWA_REPO_LOCAL} from ${LCWA_REPO}."
		echo ' '
	fi
	echo ' '
	echo 'Enjoy!'
}

script_opts_vars_name(){
	#~ debug_echo "${FUNCNAME}( $@ )"
	echo "PREP_OPTS" \
	"INST_OPTS" \
	"DEPS_OPTS" \
	"OOKLA_OPTS" \
	"REPO_OPTS" \
	"JSON_OPTS" \
	"SRVC_OPTS" \
	"PPPD_OPTS" \
	"UTIL_OPTS" \
	"FRWL_OPTS"
}

script_opts_vars_show(){
	local LVAR=
	for LVAR in $(script_opts_vars_name)
	do
		echo "${LVAR}=\"${!LVAR}\""
	done
}

script_opts_vars_ltrim(){
	local LVAR=
	for LVAR in $(script_opts_vars_name)
	do
		eval "${LVAR}=\"$(echo ${!LVAR} | sed -e 's/^\s\+//')\""
	done
}

script_opts_set_all(){
	#~ debug_echo "${FUNCNAME}( $@ )"
	local LVALUE="$@"
	local LVARS="$(script_opts_vars_name)"
	local LVAR=
	
	for LVAR in $LVARS
	do
		#~ debug_echo "eval ${LVAR}=\"${!LVAR} ${LVALUE}\""
		eval "${LVAR}=\"${!LVAR} ${LVALUE}\""
		#~ debug_echo "${LVAR}=${!LVAR}"
	done
}


###########################################################################################
###########################################################################################
###########################################################################################
#~ main()
###########################################################################################
###########################################################################################
###########################################################################################

export NO_PAUSE

PREP_OPTS=
INST_OPTS=
DEPS_OPTS=
OOKLA_OPTS="--env-file=/etc/default/lcwa-speed --direct --force"
REPO_OPTS=
JSON_OPTS=
SRVC_OPTS=
UTIL_OPTS=
FRWL_OPTS=

PRE_ARGS="$@"

# Declare the LCWA service environmental variables and zero them..
env_vars_zero $(env_vars_name)

# Declare the script control environmental variables and zero them..
env_vars_zero $(script_opts_vars_name)

SHORTARGS='hdqvtfurk'
LONGARGS="
help,
debug,
quiet,
verbose,
test,
force,
no-pause,
update,
clean,
keep,
shallow,
branch:,
supbranch:,
private,
public,
remove,uninstall,
no-hostname,
hostname:,
inst-name:,
service-name:,
pppoe::,
env-file:
"

# Remove line-feeds..
LONGARGS="$(echo "$LONGARGS" | sed ':a;N;$!ba;s/\n//g')"

ARGS=$(getopt -o "$SHORTARGS" -l "$LONGARGS"  -n "$(basename $0)" -- "$@")

if [ $? -gt 0 ]; then
	disp_help "$SCRIPT_DESC"
	exit 1
fi
	
eval set -- "$ARGS"

while [ $# -gt 0 ]; do

	case "$1" in
		--)
			;;
		-h|--help)		# Displays this help
			disp_help "$SCRIPT_DESC" 
			exit 0
			;;
		-d|--debug)		# Shows debugging info
			((DEBUG++))
			script_opts_set_all "$1"
			;;
		-q|--quiet)		# Supresses message output
			QUIET=1
			script_opts_set_all "$1"
			;;
		-v|--verbose)		# Shows additional message output
			((VERBOSE++))
			script_opts_set_all "$1"
			;;
		-t|--test)		# Tests script logic without performing actions
			((TEST++))
			script_opts_set_all "$1"
			;;
		-f|--force)		# Invokes force overwrite conditions in install scripts
			((FORCE+=1))
			script_opts_set_all "$1"
			;;
		--no-pause)		# Inhibits banner pause
			NO_PAUSE=1
			;;
		--hostname)		# Configure for a hostname other than actual
			shift
			PREP_OPTS="${PREP_OPTS} --hostname=${1}"
			;;
		--no-hostname)		# Don't configure for a hostname
			PREP_OPTS="${PREP_OPTS} ${1}"
			;;
		--private)		# Configures the system firewall so that ports 22, 68 & 5201 are only open on this subnet
			FRWL_OPTS="${FRWL_OPTS} ${1}"
			;;
		--public)
			# Configures the system firewall so that ports 22, 68 & 5201 are open to all subnets
			FRWL_OPTS="${FRWL_OPTS} ${1}"
			;;
		--shallow)		# Clone only latest repo committs
			REPO_OPTS="${REPO_OPTS} ${1}"
			;;
		--branch)		# Check-out a non-master branch of the primary repo
			shift
			LCWA_REPO_BRANCH="$1"
			;;
		--supbranch)		# Check-out a non-master branch of the suplementary repo
			shift
			LCWA_SUPREPO_BRANCH="$1"
			;;
		-u|update)		# Update the service components (dependencies, config)
			UPDATE=1
			#~ script_opts_set_all "--update"
			;;
		-r|--remove|--uninstall)	# Uninstall the service, repos, etc..
			UNINSTALL=1
			script_opts_set_all "--uninstall"
			;;
		-k|--keep)		# Retain repos, venv and data when uninstalling.
			UTIL_OPTS="${UTIL_OPTS} --keep"
			INST_OPTS="${INST_OPTS} --keep"
			;;
		--inst-name)
			# =NAME -- Instance name that defines the install location: /usr/local/share/NAME and user account name -- defaults to lcwa-speed.
			shift
			INST_INSTANCE_NAME="$1"
			LCWA_INSTANCE="$1"
			INST_NAME="$LCWA_INSTANCE"
			;;
		--service-name)
			# =NAME -- Defines the name of the service: /lib/systemd/system/NAME.service; config file will be NAME.json -- defaults to lcwa-speed.
			shift
			INST_SERVICE_NAME="$1"
			LCWA_SERVICE="$(basename "$INST_SERVICE_NAME")"
			;;
		--pppoe)			# ='ACCOUNT:PASSWORD' Installs the PPPoE connect service. Ex: --pppoe=account_name:password
			shift
			PPPD_OPTS="${PPPD_OPTS} --pppoe=${1}"
			LCWA_PPPOE_INSTALL=1
			LCWA_PPPOE_PROVIDER="$(echo "$1" | awk -F: '{ print $1 }')"
			LCWA_PPPOE_PASSWORD="$(echo "$1" | awk -F: '{ print $2 }')"
			;;
		--env-file)		# =path & filename of env-file.  Defaults to /etc/default/lcwa-speed
			shift
			# Fall through..
			;&
		*)
			LCWA_ENVFILE="$1"
			[ -f "$LCWA_ENVFILE" ] && LCWA_ENVFILE="$(readlink -f "$LCWA_ENVFILE")" || LCWA_ENVFILE=
			;;
   esac
   shift
done

[ $VERBOSE -gt 0 ] && error_echo "${SCRIPT_NAME} ${PRE_ARGS}"

# Make sure we're running as root 
is_root

# Default overrides:
[ $TEST -gt 1 ] && INST_SERVICE_NAME="./${INST_SERVICE_NAME}"

if [ ! -z "$LCWA_ENVFILE" ]; then
	LCWA_INSTANCE=
	LCWA_SERVICE=
	[ $QUIET -lt 1 ] && error_echo "Getting dependency install targets from ${LCWA_ENVFILE}."
	env_file_read "$LCWA_ENVFILE"
	if [ $? -gt 0 ]; then
		error_echo "${SCRIPT_NAME} fatal error: could not read from ${LCWA_ENVFILE}. Exiting."
		exit 1
	fi
#~ elif [ ! -z "$INST_SERVICE_NAME" ] && (env_file_exists "$INST_SERVICE_NAME"); then
	#~ LCWA_ENVFILE="$(env_file_exists "$INST_SERVICE_NAME" 'true')"
	#~ env_vars_defaults_get
	#~ [ $QUIET -lt 1 ] && error_echo "Modifying default dependency install targets from ${LCWA_ENVFILE}."
	#~ env_file_read "$INST_SERVICE_NAME"
else
	env_vars_defaults_get
	# Create the env file (for this specific service of the instance)
	[ $UNINSTALL -lt 1 ] && env_file_create "$INST_SERVICE_NAME" $(env_vars_name)
fi

script_opts_set_all "--env-file=${LCWA_ENVFILE}"


########################################################################################
# UNINSTALL
if [ $UNINSTALL -gt 0 ]; then

	# Stop, disable and remove the service and timer unit files
	inst_script_execute config-lcwa-speed-services.sh $SRVC_OPTS
	inst_script_execute config-lcwa-speed-pppoe.sh $PPPD_OPTS

	# Remove our utility scripts
	inst_script_execute config-lcwa-speed-utils.sh $UTIL_OPTS

	# Remove the instance -- deletes the repos and the data
	inst_script_execute config-lcwa-speed-inst.sh $INST_OPTS

	echo "${INST_NAME} is uninstalled."
	exit 0


########################################################################################
# UPDATE
elif [ $UPDATE -gt 0 ]; then
	# What do we want to update here??
	#   under what circumstances do we update the env file??
	if [ -z "$LCWA_PRESERVE_ENV" ] || [ $LCWA_PRESERVE_ENV -lt 1 ]; then
		env_file_create "$INST_SERVICE_NAME" $(env_vars_name)
	fi

	# Make sure our helper script is available..
	instsrv_functions_update	

	# Install the dependencies
	inst_script_execute config-lcwa-speed-deps.sh $DEPS_OPTS
	
	# Update the ookla binary..
	inst_script_execute config-ookla-speedtest.sh $OOKLA_OPTS

	# Create the config.json file
	inst_script_execute config-lcwa-speed-jsonconf.sh $JSON_OPTS

	# Create the service and timer unit files
	inst_script_execute config-lcwa-speed-services.sh $SRVC_OPTS

	# Install our utility scripts
	inst_script_execute config-lcwa-speed-utils.sh $UTIL_OPTS

	# Configure the firewall
	inst_script_execute config-lcwa-speed-fw.sh $FRWL_OPTS



########################################################################################
# INSTALL
else

	banner_display

	# Make sure our helper script is available..
	instsrv_functions_update	

	# Prepare the system
	inst_script_execute config-lcwa-speed-sysprep.sh $PREP_OPTS
	
	# Update the system locale vars (only rpi)
	LOCALE_SCR='/tmp/locale.sh'
	if [ -f "$LOCALE_SCR" ]; then
		[ $QUIET -lt 1 ] && error_echo "Updating and exporting locale vars.."
		unset LANG
		. "$LOCALE_SCR"
		export LANG=$LANG
		[ $DEBUG -gt 1 ] && locale
	fi

	# Create the instance
	inst_script_execute config-lcwa-speed-inst.sh $INST_OPTS
	
	# Install the dependencies
	inst_script_execute config-lcwa-speed-deps.sh $DEPS_OPTS
	
	# Install the code repos
	inst_script_execute config-lcwa-speed-repos.sh $REPO_OPTS

	# Create the config.json file
	inst_script_execute config-lcwa-speed-jsonconf.sh $JSON_OPTS

	# Install the speedtest binary
	inst_script_execute config-ookla-speedtest.sh $OOKLA_OPTS

	# Create the service and timer unit files
	inst_script_execute config-lcwa-speed-services.sh $SRVC_OPTS

	# Create the pppoe-connect service
	PPPD_OPTS="${PPPD_OPTS} -ddd"
	[ $LCWA_PPPOE_INSTALL -gt 0 ] && inst_script_execute config-lcwa-speed-pppoe.sh $PPPD_OPTS

	# Install our utility scripts
	inst_script_execute config-lcwa-speed-utils.sh $UTIL_OPTS

	# Configure the firewall
	inst_script_execute config-lcwa-speed-fw.sh $FRWL_OPTS

	finish_display
fi

exit 0
