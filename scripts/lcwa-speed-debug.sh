#!/bin/bash
# lcwa-speed-debug.sh -- script to debug lcwa-speed startup..

SCRIPT_VERSION=20240118.150037

SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
SCRIPT_NAME="$(basename $0)"
SCRIPT_DESC="Script to debug systemd lcwa-speed.service startup."

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
# Script Control Vars
######################################################################################################
DEBUG=0
QUIET=0
TEST=0

INST_NAME='lcwa-speed'
INST_PROD="LCWA Python3 PPPoE Speedtest Logger"
INST_DESC='LCWA PPPoE Speedtest Logger Daemon'

PYTHON3=
PYSCRIPT=
SCRIPTARGS=
MY_OPTS=

# Save our HOME var to be restored later..
CUR_HOME="$HOME"

debug_echo(){
	[ $DEBUG -gt 0 ] && echo "$@" 1>&2;
}

######################################################################################################
# Incude our lcwa-speed service env vars declaration file..
######################################################################################################

INCLUDE_FILE="$(dirname $(readlink -f $0))/lcwa-speed-env.sh"
[ ! -f "$INCLUDE_FILE" ] && INCLUDE_FILE='/usr/local/sbin/lcwa-speed-env.sh'

if [ ! -f "$INCLUDE_FILE" ]; then
	error_echo "${SCRIPT_NAME} error: Could not find env vars declaration file ${INCLUDE_FILE}. Exiting."
	exit 1
fi

debug_echo "Including file: ${INCLUDE_FILE}"

. "$INCLUDE_FILE"


########################################################################
########################################################################
########################################################################
# main()
########################################################################
########################################################################
########################################################################

echo "${SCRIPT_NAME} $@"

# Make sure we're running as root 
is_root

# Declare our environmental variables and zero them..
env_vars_zero $(env_vars_name)

SHORTARGS='hdt'
LONGARGS="help,debug,test,env-file:,options:"

ARGS=$(getopt -o "$SHORTARGS" -l "$LONGARGS"  -n "$SCRIPT_NAME" -- $@)

if [ $? -gt 0 ]; then
	disp_help "$SCRIPT_DESC" "[ optional python script pathname ]"
	exit 1
fi

eval set -- "$ARGS"

# Parse args..
while test $# -gt 0
do
	case "$1" in
		--)
			;;
		-h|--help)		# Display help
			disp_help "$SCRIPT_DESC" "[ optional python script pathname ]"
			exit 0
			;;
		-d|--debug)		# Shows debugging info.
			((DEBUG+=1))
			;;
		-t|--test)		# Test mode: skip python syntax checking of source script.
			((TEST+=1))
			;;
		--env-file)		# =path & filename of env-file.  Defaults to /etc/default/lcwa-speed
			shift
			echo $1
			if [ -f "$1" ]; then
				LCWA_ENVFILE="$(readlink -f "$1")"
				error_echo "Using env-file ${LCWA_ENVFILE}"
			else
				error_echo "${SCRIPT_NAME} error: env-file ${1} not found. Exiting."
				exit 1
			fi
			;;
		--options)		# =additional options to pass to the python script
			shift
			error_echo "Adding option ${1} to script cmdline args."
			MY_OPTS="${MY_OPTS} ${1}"
			;;
		*)
			if [ -f "$1" ]; then
				if [ $(file -b "$1" | grep -c -E '^Python script') -gt 0 ]; then
					PYSCRIPT="$(readlink -f "$1")"
				fi
			fi
			if [ -z "$PYSCRIPT" ]; then
				error_echo "${SCRIPT_NAME} error: ${1} not found or is not a python script."
				exit 1
			fi
			;;
	esac
	shift
done

# Read from the environmental vars file if passed on the cmd line
if [ ! -z "$LCWA_ENVFILE" ]; then
	[ $QUIET -lt 1 ] && error_echo "Getting environmental variables from ${LCWA_ENVFILE}."
	env_file_read "$LCWA_ENVFILE"
	if [ $? -gt 0 ]; then
		error_echo "${SCRIPT_NAME} fatal error: could not read from ${LCWA_ENVFILE}. Exiting."
		exit 1
	fi
else
	# else, use default values..
	env_vars_defaults_get
fi

#~ LCWA_DAEMON="/usr/local/share/lcwa-speed/bin/python3 -u /usr/local/share/lcwa-speed/speedtest/src/test_speed1_3.py"
#~ LCWA_OPTIONS="--conf /etc/lcwa-speed/lcwa-speed.json"

# Get the venv instance of python3
PYTHON3="$(echo "$LCWA_DAEMON" | awk '{ print $1 }')"
# Get the pathname of the script to run
PYSCRIPT="$(echo "$LCWA_DAEMON" | sed -n -e 's#^.* \(/.*\.py\)#\1#p')"

SCRIPTARGS="${LCWA_OPTIONS} ${MY_OPTS}"
RET=1

if [ -z "$PYTHON3" ] || [ ! -f "$PYTHON3" ]; then
	error_echo "${SCRIPT_NAME} fatal error: could not find venv python3."
	error_echo "   Check the contents of the ${LCWA_ENVFILE} env var file."
	exit 1
fi


if [ -z "$PYSCRIPT" ] || [ ! -f "$PYSCRIPT" ]; then
	error_echo "${SCRIPT_NAME} fatal error: could not find the python script to execute."
	error_echo "   Check the contents of the ${LCWA_ENVFILE} env var file."
	exit 1
fi

# Check syntax first:

if [ $TEST -lt 1 ]; then
	#~ /usr/local/share/lcwa-speed/speedtest/src/__pycache__/
	# Make sure the __pycache__ dir is writeable..
	error_echo ' '
	error_echo "Checking python syntax for ${PYSCRIPT}:"
	error_echo '=========================================================================='
	error_echo ' '
	
	PYCACHE="$(dirname "$PYSCRIPT")"
	if [ ! -d "$PYCACHE" ]; then
		error_echo "${SCRIPT_NAME} fatal error: Directory ${PYCACHE} does not exist."
		exit 1
	fi
	PYCACHE="${PYCACHE}/__pycache__"
	[ ! -d "$PYCACHE" ] && mkdir "$PYCACHE"
	chmod 777 "$PYCACHE"
	
	error_echo sudo HOME="$HOME" -u "$LCWA_USER" "$PYTHON3" -m py_compile "$PYSCRIPT"
	sudo HOME="$HOME" -u "$LCWA_USER" "$PYTHON3" -m py_compile "$PYSCRIPT"
	RET=$?

	error_echo ' '
	error_echo '=========================================================================='

	if [ $RET -gt 0 ]; then
		error_echo "Errors in: ${PYSCRIPT}"
		exit 1
	else
		error_echo "${PYSCRIPT} compiled with no errors."
	fi
fi

error_echo ' '
error_echo "Attempting to run ${PYSCRIPT}.."
error_echo '=========================================================================='
error_echo ' '
echo sudo HOME="$HOME" -u "$LCWA_USER" "$PYTHON3" "$PYSCRIPT" $SCRIPTARGS
sudo HOME="$HOME" -u "$LCWA_USER" "$PYTHON3" "$PYSCRIPT" $SCRIPTARGS
RET=$?
error_echo ' '
error_echo '=========================================================================='
error_echo "${PYSCRIPT} returned ${RET}"

HOME="$CUR_HOME"

exit $RET
