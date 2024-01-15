#!/bin/bash

######################################################################################################
# Bash script for installing basic script utilities to /usr/local/sbin
######################################################################################################
SCRIPT_VERSION=20240115.085852

SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
SCRIPT_NAME="$(basename $0)"
SCRIPT_DESC="Installs basic bash scripts used by lcwa-speed to /usr/local/sbin"

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
KEEP=0

######################################################################################################
# rclocal_create() Create the /etc/rc.local file to check the subnet
######################################################################################################

rclocal_create(){
	debug_echo "${FUNCNAME}( $@ )"

	local RCLOCAL='/etc/rc.local'

	if [ -f "$RCLOCAL" ]; then
		if [ ! -f "${RCLOCAL}.org" ]; then
			cp -p "$RCLOCAL" "${RCLOCAL}.org"
		fi
	cp -p "$RCLOCAL" "${RCLOCAL}.bak"
	fi

	[ $QUIET -lt 1 ] && error_echo "Creating ${RCLOCAL}.."


	[ $TEST -lt 1 ] && cat >"$RCLOCAL" <<-RCLOCAL1;
	#!/bin/sh -e
	#
	# rc.local
	#
	# This script is executed at the end of each multiuser runlevel.
	# Make sure that the script will "exit 0" on success or any other
	# value on error.
	#
	# In order to enable or disable this script just change the execution
	# bits.
	#
	# By default this script does nothing.

	########################################################################################
	# ALWAYS fix the /tmp directory
	########################################################################################
	chmod 1777 /tmp

	########################################################################################
	#
	# Check the current network connection. If the subnet has changed, reconfigure the
	# firewall.
	#
	########################################################################################

	/usr/local/sbin/lcwa-speed-fwck.sh --verbose --minimal --public

	exit 0
	RCLOCAL1

	[ $TEST -lt 1 ] && chmod 755 "$RCLOCAL"


}


######################################################################################################
# utility_scripts_name( [ script_dir ] ) Lists the scripts we want to install..
######################################################################################################
utility_scripts_name(){
	debug_echo "${FUNCNAME}( $@ )"
	local LSCRIPT_DIR="${1:-${SCRIPT_DIR}}"
	echo	"../../instsrv_functions.sh" \
			"../instsrv_functions.sh" \
			"./instsrv_functions.sh" \
			"../config-lcwa-speed.sh" \
			"./config-ookla-speedtest.sh" \
			$(find "$LSCRIPT_DIR" -maxdepth 1 -name '*lcwa*' -printf '%f\n' | grep -v -E '[\./]+bak' | sort)
}

# Abbrivated list of scripts...used for uninstall
utility_scripts_name_abbr(){
	debug_echo "${FUNCNAME}( $@ )"
	local LSCRIPT_DIR="${1:-${SCRIPT_DIR}}"
	echo	$(find "$LSCRIPT_DIR" -maxdepth 1 -name '*lcwa*' -printf '%f\n' | grep -v -E '[\./]+bak' | sort)
}


######################################################################################################
# utility_scripts_install( SUP_REPO_SCRIPT_DIR ) Installs the utility scripts to /usr/local/sbin
######################################################################################################
utility_scripts_install(){
	debug_echo "${FUNCNAME}( $@ )"
	local LSCRIPT_DIR="${1:-${SCRIPT_DIR}}"
	local LTARGET_DIR="${2:-/usr/local/sbin}"
	local LSCRIPT=
	local LSOURCE=
	local LTARGET=

	[ $QUIET -lt 1 ] && error_echo "Updating utility scripts in ${LTARGET_DIR} from ${LSCRIPT_DIR}"

	# Copy just the scripts with 'lcwa' in the name..
	#~ for LSCRIPT in 	"${LSCRIPT_DIR}/../../instsrv_functions.sh" \
					#~ "${LSCRIPT_DIR}/../instsrv_functions.sh" \
					#~ "${LSCRIPT_DIR}/./instsrv_functions.sh" \
					#~ "${LSCRIPT_DIR}/config-ookla-speedtest.sh" \
					#~ $(find "$LSCRIPT_DIR" -maxdepth 1 -name '*lcwa*' -printf '%f\n' | grep -v -E '[\./]+bak' | sort)

	for LSCRIPT in $(utility_scripts_name)
	do
		[ $VERBOSE -gt 1 ] && error_echo "$LSCRIPT"

		LSOURCE="$(readlink -f "${LSCRIPT_DIR}/${LSCRIPT}")"

		if [ -z "$LSOURCE" ] || [ ! -f "$LSOURCE" ]; then
			continue
		fi
		
		[ $VERBOSE -gt 1 ] && error_echo "$LSOURCE"
		
		LTARGET="${LTARGET_DIR}/$(basename "$LSCRIPT")"

		# Skip overwriting newer files..
		if [ -f "$LTARGET" ] && [ ! "$LSOURCE" -ot "$LTARGET" ]; then
			[ $FORCE -lt 1 ] && continue
		fi

		# Only copy shell script files..
		if [ $(file "$LSOURCE" | grep -c 'shell script') -lt 1 ]; then
			[ $VERBOSE -gt 0 ] && error_echo "$(basename "$LSOURCE") is not a shell script.."
			continue
		fi
		
		if [ -f "$LSOURCE" ]; then
			if [ ! -f "$TARGET" ] || [ "$SOURCE" -nt "$TARGET" ] || [ $FORCE -gt 0 ]; then
				# Test the script for errors
				bash -n "$LSOURCE"
				if [ $? -gt 0 ]; then
					error_echo '============================================================='
					error_echo "${SCRIPT_NAME} error: bash says that ${LSOURCE} has errors!!!"
					error_echo '============================================================='
				else
					[ $VERBOSE -gt 0 ] && error_echo "Copying ${LSOURCE} to ${LTARGET}"
					[ $TEST -lt 1 ] && cp -p "$LSOURCE" "$LTARGET"
				fi
			else
				[ $VERBOSE -gt 0 ] && error_echo "Not copying ${LSOURCE} to ${LTARGET}"
			fi
		fi

	done
	
	rclocal_create

}

######################################################################################################
# utility_scripts_remove() Removes the utility scripts from /usr/local/sbin
######################################################################################################
utility_scripts_remove(){
	debug_echo "${FUNCNAME}( $@ )"
	local LSCRIPT_DIR="${1:-${SCRIPT_DIR}}"
	local LTARGET_DIR="${2:-/usr/local/sbin}"
	local LSCRIPT=
	local LSOURCE=
	local LTARGET=

	[ $QUIET -lt 1 ] && error_echo "Removing utility scripts in ${LTARGET_DIR}.."

	#~ for LSCRIPT in $(find "$LSCRIPT_DIR" -maxdepth 1 -name '*lcwa*' -printf '%f\n' | sort)
	for LSCRIPT in $(utility_scripts_name_abbr)
	do
		LTARGET="${LTARGET_DIR}/${LSCRIPT}"
		if [ -f "$LTARGET" ]; then
			[ $VERBOSE -gt 0 ] && error_echo "Removing ${LTARGET}"
			[ $TEST -lt 1 ] && rm -f "$LTARGET"
		fi
	done
	
	LSCRIPT='/etc/rc.local'
	[ -f "$LSCRIPT" ] && [ $TEST -lt 1 ] && rm "$LSCRIPT"

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


SHORTARGS='hdqvftkr'

LONGARGS="
help,
debug,
quiet,
verbose,
test,
force,
keep,
remove,uninstall,
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
		-d|--debug)			# Shows debugging info.
			((DEBUG+=1))
			;;
		-q|--quiet)			# Supresses message output.
			QUIET=1
			;;
		-v|--verbose)		# Increase message output.
			((VERBOSE+=1))
			;;
		-f|--force)			# Force overwriting target files.
			((FORCE+=1))
			;;
		-t|--test)			# Tests script logic without performing actions.
			((TEST+=1))
			;;
		-k|--keep)
			KEEP=1
			;;
		-r|--remove|--uninstall)	# Removes the utility scripts from /usr/local/sbin
			UNINSTALL=1
			;;
		*)
			;;
	esac
	shift
done

[ $VERBOSE -gt 0 ] && error_echo "${SCRIPTNAME} ${PRE_ARGS}"

if [ $KEEP -gt 0 ] && [ $UNINSTALL -gt 0 ]; then
	[ $VERBOSE -gt 0 ] && error_echo "${SCRIPT_NAME}: Keeping install scripts."
	exit 0
fi

if [ $UNINSTALL -gt 0 ]; then
	utility_scripts_remove
else
	utility_scripts_install
fi
