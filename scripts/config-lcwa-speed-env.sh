#!/bin/bash

SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
SCRIPT_NAME="$(basename $0)"
SCRIPT_DESC='Creates the environmental variables file for the lcwa-speed service.'


######################################################################################################
# Include the generic service install functions
######################################################################################################

REC_INCSCRIPT_VER=20201220
INCLUDE_FILE="$(dirname $(readlink -f $0))/instsrv_functions.sh"
[ ! -f "$INCLUDE_FILE" ] && INCLUDE_FILE='/usr/local/sbin/instsrv_functions.sh'

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


# Change to 1 to prevent updates to the env file
INST_ENVFILE_LOCK=0

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


INCLUDE_FILE="$(dirname $(readlink -f $0))/lcwa-speed-env.sh"
[ ! -f "$INCLUDE_FILE" ] && INCLUDE_FILE='/usr/local/sbin/lcwa-speed-env.sh'

if [ ! -f "$INCLUDE_FILE" ]; then
	error_echo "${SCRIPT_NAME} error: Could not find env vars declaration file ${INCLUDE_FILE}. Exiting."
	exit 1
fi

debug_echo "Including file: ${INCLUDE_FILE}"

. "$INCLUDE_FILE"


######################################################################################
######################################################################################
######################################################################################
# main()
######################################################################################
######################################################################################
######################################################################################

echo "${SCRIPT_NAME} $@"

is_root

# Declare our environmental variables and zero them..
env_vars_zero $(env_vars_name)

SHORTARGS='hdqtf'
LONGARGS="
help,
debug,
quiet,
verbose,
test,
force,
inst-name:,
service-name:,
pppoe::"

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
			break
			;;
		-h|--help)			# Display help
			disp_help "$SCRIPT_DESC"
			exit 0
			;;
		-d|--debug)			# Emit debugging info
			((DEBUG+=1))
			;;
		-q|--quiet)			# Supress output
			QUIET=1
			;;
		-t|--test)			# Test logic, but don't perform actions
			((TEST+=1))
			;;
		-f|--force)			# Inhibit rpi checks
			FORCE=1
			;;
		--inst-name)		# =NAME -- Instance name that defines the install location: /usr/local/share/NAME and user account name -- defaults to lcwa-speed.
			shift
			INST_INSTANCE_NAME="$1"
			LCWA_INSTANCE="$1"
			;;
		--service-name)			# =NAME -- Defines the name of the service: /lib/systemd/system/NAME.service -- defaults to lcwa-speed.
			shift
			INST_SERVICE_NAME="$1"
			LCWA_SERVICE="$(basename "$INST_SERVICE_NAME")"
			;;
		--pppoe)	# ='ACCOUNT:PASSWORD' Forces install of the PPPoE connect service. Ex: --pppoe=account_name:password
			shift
			LCWA_PPPOE_INSTALL=1
			LCWA_PPPOE_PROVIDER="$( echo "$1" | awk -F: '{ print $1 }')"
			LCWA_PPPOE_PASSWORD="$( echo "$1" | awk -F: '{ print $2 }')"
			;;
		*)
			error_echo "Error: unrecognized option ${1}."
			disp_help "$SCRIPT_DESC"
			exit 1
			;;
	esac
	shift
done

# Default overrides if super-testing:
if [ $TEST -gt 1 ]; then
	if [ ! -z "$LCWA_SERVICE" ]; then
		#~ LCWA_ENVFILE="${SCRIPT_DIR}/${LCWA_SERVICE}"
		LCWA_ENVFILE="$(readlink -f "./${LCWA_SERVICE}")"
	else
		#~ LCWA_ENVFILE="${SCRIPT_DIR}/${INST_SERVICE_NAME}" 
		LCWA_ENVFILE="$(readlink -f "./${INST_SERVICE_NAME}")"
	fi
	INST_SERVICE_NAME="$(readlink -f "./${INST_SERVICE_NAME}")"
fi

if [ $DEBUG -gt 0 ]; then
	error_echo "=========================================="
	error_echo "            DEBUG == ${DEBUG}"
	error_echo "             TEST == ${TEST}"
	error_echo "=========================================="
	error_echo "    INST_INSTANCE_NAME == ${INST_INSTANCE_NAME}"
	error_echo "         LCWA_INSTANCE == ${LCWA_INSTANCE}"
	error_echo "=========================================="
	error_echo "INST_SERVICE_NAME == ${INST_SERVICE_NAME}"
	error_echo "     LCWA_SERVICE == ${LCWA_SERVICE}"
	error_echo "     LCWA_ENVFILE == ${LCWA_SERVICE}"
	error_echo "=========================================="
fi


env_vars_defaults_get

env_file_create "$INST_SERVICE_NAME" $(env_vars_name)



