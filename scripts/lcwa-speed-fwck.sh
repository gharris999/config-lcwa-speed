#!/bin/bash

# Bash script to check to see that the firewall config at boot time matches our linked subnet.
#   Calls config-firewall.sh or config-firewall-prep-apps.sh if the firewall needs to be reconfigured.

######################################################################################################
# Vars
######################################################################################################

##SCRIPT_VERSION=20240118.181639
SCRIPT_VERSION=20240118.181639
SCRIPT="$(realpath -s "$0")"
SCRIPT_NAME="$(basename "$SCRIPT")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
SCRIPT_DESC="Script to check that firewall is configured for our subnet."
SCRIPT_EXTRA=""
SCRIPT_LOG="/var/log/${SCRIPT_NAME%%.*}.log"

SCRIPT_FUNC='instsrv_functions.sh'
RQD_SCRIPT_FUNC_VER=20201220

# Load the helper functions..
source "${SCRIPT_DIR}/${SCRIPT_FUNC}" >/dev/null 2>&1
if [ $? -gt 0 ]; then
	source "$SCRIPT_FUNC" >/dev/null 2>&1
	if [ $? -gt 0 ]; then
		echo "${SCRIPT_NAME} error: Cannot load script helper functions in ${SCRIPT_FUNC}. Exiting."
		exit $ERROR_EXIT_VALUE
	fi
fi

if [[ -z "$INCSCRIPT_VERSION" ]] || [[ "$INCSCRIPT_VERSION" < "$RQD_SCRIPT_FUNC_VER" ]]; then
	# Don't error_exit -- at least try to continue with the utility functions as installed..
	echo "Error: ${INCLUDE_FILE} version is ${INCSCRIPT_VERSION}. Version ${RQD_SCRIPT_FUNC_VER} or newer is required."
fi

DEBUG=0
VERBOSE=0
QUIET=0
TEST=0
FORCE=0
LOG=0

ANY_IFACE=0
SETTLE_TIME=0
MINIMAL=0
PUBLIC=0
CONFIG_FIREWALL_OPTS=
USE_FW_APPS=0
ERROR_EXIT_VALUE=0

########################################################################################
# get_link_wait( $NETDEV, wait_time ) Tests to see if an interface is linked. returns 0 == linked; 1 == no link;
########################################################################################
get_link_wait(){
	debug_echo "${FUNCNAME}( $@ )"
	local LIFACE="$1"
	local LWAIT_TIME="${2:-10}"
	local n=0

	[ -z "$LIFACE" ] && LIFACE="$(iface_primary_getb)"

	# If we have a link
	[ $VERBOSE -gt 1 ] && log_msg "Looking for link on interface ${LIFACE}.."
	iface_has_link "$LIFACE"
	if [ $? -lt 1 ]; then
		echo "$LIFACE"
		return 0
	fi

	# Make 4 more attempts to find a link..
	for n in 1 2 3 4
	do
		[ $VERBOSE -gt 0 ] && log_msg "No link detected on interface ${LIFACE}...waiting ${LWAIT_TIME} seconds to try again.."
		sleep $LWAIT_TIME

		iface_has_link "$LIFACE"
		if [ $? -lt 1 ]; then
			[ $VERBOSE -gt 0 ] && log_msg "Link detected on interface ${LIFACE}."
			echo "$LIFACE"
			return 0
		fi
	done

	if [ ! -z "$LIFACES" ]; then
		echo "$LIFACES"
		return 0
	fi

	# Give up..
	error_echo "No link found on any network device.."
	return 1

}

########################################################################################
# get_links_wait( $NETDEV) Tests to see if an interface is linked. returns 0 == linked; 1 == no link;
########################################################################################
get_links_wait(){
	debug_echo "${FUNCNAME}( $@ )"
	local LIFACES="$1"
	local LWAIT_TIME="${2:-10}"
	local n=0

	[ $VERBOSE -gt 1 ] && log_msg "Looking for links on any interface.."

	# Make 5 attempts to find a link..
	for n in 1 2 3 4 5
	do
		LIFACES=$(ifaces_get_links)
		if [ ! -z "$LIFACES" ]; then
			break
		fi
		# No link...try to wait a bit for the network to be established..
		[ $VERBOSE -gt 0 ] && error_echo "No link detected on any network interface...waiting ${LWAIT_TIME} seconds to try again.."
		sleep $LWAIT_TIME
	done

	if [ ! -z "$LIFACES" ]; then
		[ $VERBOSE -gt 0 ] && log_msg "Link(s) detected on interface(s) ${LIFACES}."
		echo "$LIFACES"
		return 0
	fi

	# Give up..
	[ $VERBOSE -gt 1 ] && log_msg "No links found on any network device.."
	return 1

}


trim(){
	local LVALUE="$1"
	LVALUE="${LVALUE##*( )}"
	LVALUE="${LVALUE%%*( )}"

	echo $LVALUE

}

firewall_subnet_check(){
	debug_echo "${FUNCNAME}( $@ )"
	local LIFACE="$1"
	local LSETTLE_TIME="${2:-10}"
	local LANY_IFACE="${3:-0}"
	local LIFACES=
	local LHAS_LINK=1
	local LFW_SUBNETS=
	local LFW_SUBNET=
	local LNEEDS_FWRECONFIG=0
	local n=

	[ $VERBOSE -gt 0 ] && log_msg "Checking the firewall to see that it is configured for the local subnet(s).."

	# Get the link status of the interface(s)
	
	if [ $LANY_IFACE -gt 0 ]; then
		[ $VERBOSE -gt 0 ] && log_msg "Getting link status for all network interfaces.."
		LIFACES="$(get_links_wait "" "$LSETTLE_TIME")"
	else
		[ -z "$LIFACE" ] && LIFACE="$(iface_primary_getb)"
		[ $VERBOSE -gt 0 ] && log_msg "Getting link status for interface ${LIFACE}.."
		LIFACES="$(get_link_wait "$LIFACE" "$LSETTLE_TIME")"
	fi
	LHAS_LINK=$?
	
	# if there is no link (e.g. ethernet not plugged in) give up immediatly without changing anything..
	if [ $LHAS_LINK -gt 0 ]; then
		[ $VERBOSE -gt 0 ] && log_msg "No links found on any interfaces. Aborting."
		exit $ERROR_EXIT_VALUE
	fi

	# Get the subnet config for UFW..
	LFW_SUBNETS="$(ufw status | sed -e 's/ (v6)/_(v6)/' | grep 'ALLOW' | awk '{print $3}' | sort --unique | xargs)"

	# If UFW is unconfigured, flag it for configuration..
	if [ -z "$LFW_SUBNETS" ]; then
		[ $QUIET -lt 1 ] && log_msg "${FUNCNAME}{} Cannot determine subnets from ufw."
		[ $QUIET -lt 1 ] && log_msg "UFW $(ufw status)"

		LSUBNET="$(iface_subnet_get $LIFACE)"
		LNEEDS_FWRECONFIG=1
	else
		# Check the subnets to see if the current config is good..
		# Get the subnet for each iface..
		for LIFACE in $LIFACES
		do
			[ $VERBOSE -gt 0 ] && log_msg "Getting subnet for interface ${LIFACE}.."
			LSUBNET=""
			for n in 1 2 3
			do
				LSUBNET="$(iface_subnet_get "$LIFACE")"
				if [ -z "$LSUBNET" ] || [ "$LSUBNET" = "127.0.0.0/8" ]; then
					[ $VERBOSE -gt 0 ] && log_msg "No subnet on ${LIFACE}. Waiting ${LSETTLE_TIME} seconds for dhcp.."
					sleep $LSETTLE_TIME
				else
					break
				fi
			done

			# If we didn't a subnet..
			[ -z "$LSUBNET" ] && continue

			# Check the subnet against the UFW subnets..
			for LFW_SUBNET in $LFW_SUBNETS
			do
				if [ "$LFW_SUBNET" = "$LSUBNET" ] || [ "$LFW_SUBNET" = 'Anywhere' ]; then
					[ $VERBOSE -gt 0 ] && log_msg "Iface ${LIFACE} Subnet: '${LSUBNET}' matches firewall subnet: '${LFW_SUBNET}' so firewall is OK.."
					# ! Forcing == Permissive mode: Any publically open port or an open port on our subnet means the firewall is OK.
					[ $FORCE -lt 1 ] && return 0
				else
					[ $VERBOSE -gt 0 ] && log_msg "Iface ${LIFACE} Subnet: '${LSUBNET}' does not match firewall subnet: '${LFW_SUBNET}'"
					LNEEDS_FWRECONFIG=1
				fi
			done

		done

	fi

	# If we never got a subnet for any interface, we don't know how to configure ufw..
	if [ -z "$LSUBNET" ]; then
		[ $VERBOSE -gt 0 ] && log_msg "No subnets found on any interfaces. Aborting."
		exit $ERROR_EXIT_VALUE
	fi

	

	if [ $LNEEDS_FWRECONFIG -gt 0 ];  then

		#~ if [ $USE_FW_APPS -gt 0 ]; then
			#~ [ $QUIET -lt 1 ] && log_msg "Reconfiguring firewall: ${SCRIPT_DIR}/config-firewall-prep-apps.sh ${CONFIG_FIREWALL_OPTS}"
			#~ "${SCRIPT_DIR}/config-firewall-prep-apps.sh" $CONFIG_FIREWALL_OPTS 2>&1 | tee -a "$SCRIPT_LOG"
		#~ else
			#~ [ $QUIET -lt 1 ] && log_msg "Reconfiguring firewall: ${SCRIPT_DIR}/config-firewall.sh ${CONFIG_FIREWALL_OPTS}"
			#~ "${SCRIPT_DIR}/config-firewall.sh" $CONFIG_FIREWALL_OPTS 2>&1 | tee -a "$SCRIPT_LOG"
		#~ fi

		[ $QUIET -lt 1 ] && log_msg "Reconfiguring firewall: ${SCRIPT_DIR}/config-lcwa-speed-fw.sh ${CONFIG_NETWORK_OPTS}"
		"${SCRIPT_DIR}/config-lcwa-speed-fw.sh" $CONFIG_NETWORK_OPTS
	fi



}


####################################################################################################
####################################################################################################
####################################################################################################
####################################################################################################
# main()
####################################################################################################
####################################################################################################
####################################################################################################
####################################################################################################

debug_echo '===================================================================='
debug_echo "${SCRIPT_DIR}/${SCRIPT_NAME} ${@}"
debug_echo '===================================================================='

# Get cmd line args..

# Process cmd line args..
SHORTARGS='hdvqftw:lLampPA'
LONGARGS='help,debug,verbose,quiet,force,test,wait:,log,logfile:,any,minimal,private,public,fwapps'
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
		-h|--help)	# Displays this help
			disp_help "$SCRIPT_DESC"
			exit 0
			;;
		-d|--debug)	# Emits debugging info
			((DEBUG++))
			CONFIG_FIREWALL_OPTS="${CONFIG_FIREWALL_OPTS} --debug"
			;;
		-v|--verbose)	# Emits extra info
			QUIET=0
			((VERBOSE++))
			CONFIG_FIREWALL_OPTS="${CONFIG_FIREWALL_OPTS} --verbose"
			;;
		-q|--quiet)	# Supresses output
			QUIET=1
			VERBOSE=0
			CONFIG_FIREWALL_OPTS="${CONFIG_FIREWALL_OPTS} --quiet"
			;;
		-f|--force)	# Enforces strict checking that the firewall is configured for all linked subnets
			((FORCE++))
			CONFIG_FIREWALL_OPTS="${CONFIG_FIREWALL_OPTS} --force"
			;;
		-t|--test)	# Tests script logic without performing actions
			TEST=1
			CONFIG_FIREWALL_OPTS="${CONFIG_FIREWALL_OPTS} --test"
			;;
		-l|--log)	# Saves output to default logfile /var/log/chknet.log
			LOG=1
			;;
		-L|--logfile)	# [logfile pathname] Saves output to specified logfile
			shift
			LOG=1
			SCRIPT_LOG="$1"
			;;
		-a|--any)	# Checks the firewall subnet against any linked interface.
			ANY_IFACE=1
			;;
		-w|--wait)	# Waits x seconds for the network to settle before checking firewall
			shift
			debug_echo "arg == $1"
			[ "$1" -eq "$1" ] && SETTLE_TIME="$1" || error_exit "--wait=${1} needs to be an integer."
			;;
		-m|--minimal)	# Configures a minimal firewall (bootpc and ssh)
			MINIMAL=1
			CONFIG_FIREWALL_OPTS="${CONFIG_FIREWALL_OPTS} --minimal"
			;;
		-p|--private)
			PUBLIC=0
			CONFIG_NETWORK_OPTS="${CONFIG_NETWORK_OPTS} --private"
			;;
		-P|--public)	# Configures the open ports to be accessable from all subnets
			PUBLIC=1
			CONFIG_FIREWALL_OPTS="${CONFIG_FIREWALL_OPTS} --public"
			;;
		-A|--fwapps)	# Configures the firewall to open ports for select enabled services.
			USE_FW_APPS=1
			CONFIG_FIREWALL_OPTS="${CONFIG_FIREWALL_OPTS} --fwapps"
			;;
		*)
			error_echo "${SCRIPT_NAME}: Unknown arg ${1}"
			;;
	esac
	shift
done

#~ [ $SETTLE_TIME -eq 0 ] && SETTLE_TIME=5

if [ $DEBUG -gt 0 ]; then
	echo "DEBUG                == ${DEBUG}"
	echo "QUIET                == ${QUIET}"
	echo "VERBOSE              == ${VERBOSE}"
	echo "TEST                 == ${TEST}"
	echo "FORCE                == ${FORCE}"
	echo "LOGING               == ${LOGING}"
	echo "LOGFILE              == ${LOGFILE}"
	echo "SCRIPT_LOG           == ${SCRIPT_LOG}"
	echo ' '
	echo "SETTLE_TIME          == ${SETTLE_TIME}"
	echo "MINIMAL              == ${MINIMAL}"
	echo "PUBLIC               == ${PUBLIC}"
	echo "CONFIG_FIREWALL_OPTS == ${CONFIG_FIREWALL_OPTS}"
	echo "USE_FW_APPS          == ${USE_FW_APPS}"
	echo ' '
fi

if [ $LOG -gt 0 ]; then
	# Create the logfile if it doesn't exist..
	# Note that if LOG == 0, no logging happens.
	[ ! -f "$SCRIPT_LOG" ] && touch "$SCRIPT_LOG"
		
	# Only create our log rotate script if the log is somewhere in /var/log..
	if [ $( echo "$SCRIPT_LOG" | grep -c '/var/log') -gt 0 ]; then
		LOG_ROTATE_SCR="/etc/logrotate.d/${SCRIPT_NAME%%.*}"
		[ ! -f "$LOG_ROTATE_SCR" ] && log_rotate_script_create "$SCRIPT_LOG"
	fi
fi

firewall_subnet_check "" $SETTLE_TIME $ANY_IFACE

exit 0
