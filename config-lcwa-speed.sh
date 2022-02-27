#!/bin/bash

#Todo:

# Review environmental vars
# LCWA_NO_UPDATES should be a settable var, defaulting to 1......................done
# 
# 
# Identify Utility scripts:
#  	Raspberry Pi Prep script: 			scripts/config-rpi-prep.sh	.............done
# 	Ookla speedtest install script		scripts/config-ookla-speedtest.sh  ......done
# 	Dependency install script           scripts/config-lcwa-speed-deps.sh  ......done
# 	config json install script			scripts/config-lcwa-speed-jsonconf.sh  ..done
# 	pppchk.sh script					scripts/lcwa-speed-pppck.sh  ............done
#   lcwa-speed debugging script			scripts/lcwa-speed-debug.sh  ............done
# 	lcwa-speed-update.sh script			scripts/lcwa-speed-update.sh  ...........done
#
# Check utility scripts for env var use
#	Env vars definition script			scripts/lcwa-speed-env.sh................done
#	Env file create script				scripts/config-lcwa-speed-env.sh.........done
#  	Raspberry Pi Prep script			scripts/config-rpi-prep.sh...............done
# 	Ookla speedtest install script		scripts/config-ookla-speedtest.sh........done
# 	Dependency install script			scripts/config-lcwa-speed-deps.sh........done
# 	Config json install script			scripts/config-lcwa-speed-jsonconf.sh....done
# 	pppchk.sh script					scripts/lcwa-speed-pppck.sh..............done
#   lcwa-speed-debug.sh script			scripts/lcwa-speed-debug.sh..............done
# 	lcwa-speed-update.sh script			scripts/lcwa-speed-update.sh
#
# config-rpi-prep.sh: Add setting NTPServers to /etc/systemd/timesyncd.conf......done
#
# Replace LCWA_APP with LCWA_INSTANCE in all scripts.............................done
#
# Update REPO URLs in config-lcwa-speed.sh.......................................done
#
# Add support for LCWA_SERVICE_NAME to config-lcwa-speed.sh
# Add support for using a pre-existing env file for config-lcwa-speed.sh
# Review and clean cmdline options for config-lcwa-speed.sh
# Work out LCWA_SERVICE vs LCWA_SERVICE_NAME ....................................done
# Check config-lcwa-speed.sh script for env var use
#
# Update gharris999/LCWA fork from upstream master...............................done
# Apply reapply patches to gharris999/LCWA.......................................done
# Push patches to gharris999.....................................................done
# 
# Review repo references in config-lcwa-speed.sh
# Test through env file create
# Test through dependency install
# Test through config json install
# Test through repo installs
# 
# Review and factor lcwa-speed-update.sh invocation via cron / systemd.timers
# 
# Create pppoe-connect.service....................................................done
# 
# Test through timer installations
# 
# Test through to lcwa-speed.service installation, enable, start
# 
# Test through installation complete
# 
# Test install on newly installed Pi.
# 
# Test install on fresh LC99.
# 
# Test install on LC05
# 
# Test install on LC20
# 
# Test install on LC16
# 
# Test install on LC18
# 
# Update config-lcwa-speed repo.




######################################################################################################
# Bash script for installing Andi Klein's Python LCWA PPPoE Speedtest Logger
# as a service on systemd, upstart & sysv systems
######################################################################################################
SCRIPT_VERSION=20220227.144800
SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
SCRIPTNAME=$(basename $0)
SCRIPT_DESC="Systemd service wrapper configuration script for python speedtest daemon."

######################################################################################################
# Include the generic service install functions
######################################################################################################

REC_INCSCRIPT_VER=20201220
INCLUDE_FILE="$(dirname $(readlink -f $0))/instsrv_functions.sh"
[ ! -f "$INCLUDE_FILE" ] && INCLUDE_FILE='/usr/local/sbin/instsrv_functions.sh'

if [ ! -f "$INCLUDE_FILE" ]; then
	echo "${SCRIPTNAME} error: cannot find include file ${INCLUDE_FILE}. Exiting."
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
NO_PAUSE=0
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
	error_echo "${SCRIPTNAME} error: Could not find env vars declaration file ${INCLUDE_FILE}. Exiting."
	exit 1
fi

debug_echo "Including file: ${INCLUDE_FILE}"

. "$INCLUDE_FILE"

inst_script_execute(){
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

	[ $VERBOSE -gt 0 ] && error_echo "Executing ${LSCRIPT_FILE} ${LSCRIPT_ARGS}"
	[ $TEST -lt 1 ] && "$LSCRIPT_FILE" "$LSCRIPT_ARGS"
	LRET=$?
	
	[ $VERBOSE -gt 0 ] && error_echo "${LSCRIPT_NAME}(${LSCRIPT_ARGS}) returned ${LRET}"
	
	debug_echo ' '
	debug_pause "${LINENO} -- ${FUNCNAME} done, returning ${LRET}"
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
	"OKLA_OPTS" \
	"REPO_OPTS" \
	"JSON_OPTS" \
	"SRVC_OPTS" \
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

# Args needed by the various install scripts:
# 
# config-lcwa-speed.sh			--inst-name --service-name --env-file
# 
# All scripts need: 				--force --env-file --uninstall
# 
# config-lcwa-speed-sysprep.sh	
# config-lcwa-speed-inst.sh 		--clean
# config-lcwa-speed-deps.sh 		--clean --keep-cache --force
# config-lcwa-speed-repos.sh		--shallow --branch --supbranch --update
# config-lcwa-speed-jsonconf.sh 	
# config-lcwa-speed-services.sh	--pppoe
# config-lcwa-speed-utils.sh		
# config-lcwa-speed-fw.sh			--private --public

PREP_OPTS=
INST_OPTS=
DEPS_OPTS=
OKLA_OPTS=
REPO_OPTS=
JSON_OPTS=
SRVC_OPTS=
UTIL_OPTS=
FRWL_OPTS=

PRE_ARGS="$@"

# Make sure we're running as root 
is_root

# Declare the LCWA service environmental variables and zero them..
env_vars_zero $(env_vars_name)

# Declare the script control environmental variables and zero them..
env_vars_zero $(script_opts_vars_name)

SHORTARGS='hdqvtfr'
LONGARGS="
help,
debug,
quiet,
verbose,
test,
force,
no-pause,
clean,
keep,
shallow,
branch:,
supbranch:,
private,
public,
remove,uninstall,
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
		-h|--help)			# Displays this help
			disp_help "$SCRIPT_DESC" 
			exit 0
			;;
		-d|--debug)			# Shows debugging info
			((DEBUG++))
			script_opts_set_all "$1"
			;;
		-q|--quiet)			# Supresses message output
			QUIET=1
			script_opts_set_all "$1"
			;;
		-v|--verbose)		# Shows additional message output
			((VERBOSE++))
			script_opts_set_all "$1"
			;;
		-t|--test)			# Tests script logic without performing actions
			((TEST++))
			script_opts_set_all "$1"
			;;
		-f|--force)			# Invokes force overwrite conditions in install scripts
			FORCE=1
			script_opts_set_all "$1"
			;;
		--no-pause)		# Inhibits banner pause
			NO_PAUSE=1
			;;
		--private)		# Configures the system firewall so that ports 22, 68 & 5201 are only open on  this subnet
			FRWL_OPTS="${FRWL_OPTS} ${1}"
			;;
		--public)		# Configures the system firewall so that ports 22, 68 & 5201 are open to all subnets
			FRWL_OPTS="${FRWL_OPTS} ${1}"
			;;
		--shallow)		# Clone only latest repo committs
			REPO_OPTS="${REPO_OPTS} ${1}"
			;;
		--branch)					# Check-out a non-master branch of the primary repo
			shift
			LCWA_REPO_BRANCH="$1"
			;;
		--supbranch)			# Check-out a non-master branch of the suplementary repo
			shift
			LCWA_SUPREPO_BRANCH="$1"
			;;
		-r|--remove|--uninstall)
			UNINSTALL=1
			script_opts_set_all "--uninstall"
			;;
		-k|--keep)			# Retain repos, venv and data when uninstalling.
			UTIL_OPTS="${UTIL_OPTS} --keep"
			INST_OPTS="${INST_OPTS} --keep"
			;;
		--inst-name)		# =NAME -- Instance name that defines the install location: /usr/local/share/NAME and user account name -- defaults to lcwa-speed.
			shift
			INST_INSTANCE_NAME="$1"
			LCWA_INSTANCE="$1"
			INST_NAME="$LCWA_INSTANCE"
			;;
		--service-name)		# =NAME -- Defines the name of the service: /lib/systemd/system/NAME.service; config file will be NAME.json -- defaults to lcwa-speed.
			shift
			INST_SERVICE_NAME="$1"
			LCWA_SERVICE="$(basename "$INST_SERVICE_NAME")"
			;;
		--pppoe)	# ='ACCOUNT:PASSWORD' Forces install of the PPPoE connect service. Ex: --pppoe=account_name:password
			shift
			DEPS_OPTS="${DEPS_OPTS} --pppoe=${1}"
			SRVC_OPTS="${SRVC_OPTS} --pppoe=${1}"
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

[ $VERBOSE -gt 0 ] && error_echo "${SCRIPTNAME} ${PRE_ARGS}"

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

	# Remove our utility scripts
	inst_script_execute config-lcwa-speed-utils.sh $UTIL_OPTS

	# Remove the instance -- deletes the repos and the data
	inst_script_execute config-lcwa-speed-inst.sh $INST_OPTS

	echo "${INST_NAME} is uninstalled."
	exit 0

########################################################################################
# INSTALL
else

	banner_display

	# Prepare the system
	inst_script_execute config-lcwa-speed-sysprep.sh $PREP_OPTS

	# Create the instance
	inst_script_execute config-lcwa-speed-inst.sh $INST_OPTS
	
	# Install the dependencies
	inst_script_execute config-lcwa-speed-deps.sh $DEPS_OPTS
	
	inst_script_execute config-ookla-speedtest.sh $OKLA_OPTS

	# Install the code repos
	inst_script_execute config-lcwa-speed-repos.sh $REPO_OPTS

	# Create the config.json file
	inst_script_execute config-lcwa-speed-jsonconf.sh $JSON_OPTS

	# Create the service and timer unit files
	inst_script_execute config-lcwa-speed-services.sh $SRVC_OPTS

	# Install our utility scripts
	inst_script_execute config-lcwa-speed-utils.sh $UTIL_OPTS

	# Configure the firewall
	inst_script_execute config-lcwa-speed-fw.sh $FRWL_OPTS

	finish_display
fi

exit 0