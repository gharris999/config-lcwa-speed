#!/bin/bash

############################################################################################################
# Bash script to check to see if a auto initiated pppoe connection is still up, and if not, re-establish it.
############################################################################################################

SCRIPT_VERSION=20220227.100059
SCRIPT_NAME="$(basename $0)"

QUIET=0
TEST=0
FORCE=0
WAITSECS=4
IFACE_FILE='/etc/network/interfaces'

DEF_PROVIDER='provider'

# Get our PPPoE account name from /etc/network/interfaces
#~ if [ ! -f "$IFACE_FILE" ]; then
	#~ exit 1
#~ fi

error_echo(){
	echo "$@" 1>&2;
}

####################################################################################
# Stamp a message with the date and the script name (and process id) using
# the same format as found in the squeezeboxserver server.log
#
date_message(){
	DATE=$(date '+%F %H:%M:%S.%N')
	DATE=${DATE#??}
	DATE=${DATE%?????}
	echo "[${DATE}] " $@ 1>&2;
}


pppoe_provider_get(){
	local LIFACE_FILE='/etc/network/interfaces'
	local LIFACES=
	local LIFACE=
	local LPPPOE_PROVIDER=
	
	if [ ! -f "$IFACE_FILE" ]; then
		if [ $FORCE -gt 0 ]; then
			echo "$DEF_PROVIDER"
		else
			date_message "${SCRIPT_NAME} error -- file not found: ${LIFACE_FILE}"
		fi
		return 1
	fi
	
	LIFACES="$(grep -E '^auto' "$LIFACE_FILE" | awk '{ print $2 }')"

	for LIFACE in $LIFACES
	do
		if [ $(grep -c -E "^iface ${LIFACE} inet ppp" "$LIFACE_FILE") -gt 0 ]; then
			LPPPOE_PROVIDER="$LIFACE"
			break
		fi
	done

	if [ -z "$LPPPOE_PROVIDER" ]; then
		date_message "${SCRIPT_NAME} error: No ppp interface defined in ${LIFACE_FILE}"
		exit 1
	fi
	
	echo "$LPPPOE_PROVIDER"
	return 0
}

ppp_link_is_up(){

	[ $(ip -br a | grep -c -E '^ppp.*peer') -gt 0 ] && return 0 || return 1

}

ppp_link_check(){

	local LPPPOE_PROVIDER="$(pppoe_provider_get)"
	local LRET=1
	
	if ppp_link_is_up; then
		[ $QUIET -lt 1 ] && date_message "PPPoE connection ${LPPPOE_PROVIDER} is UP."
		LRET=0
	else
		[ $QUIET -lt 1 ] && date_message "PPPoE connection ${LPPPOE_PROVIDER} is DOWN."
	
		if [ ! -z "$LPPPOE_PROVIDER" ]; then
			[ $QUIET -lt 1 ] && date_message "Reestablishing ${LPPPOE_PROVIDER} PPPoE connection."
			#~ [ $TEST -lt 1 ] && pppd call "$LPPPOE_PROVIDER"
			[ $TEST -lt 1 ] && pon "$LPPPOE_PROVIDER"
			[ $TEST -lt 1 ] && sleep $WAITSECS
			if ppp_link_is_up; then
				[ $QUIET -lt 1 ] && date_message "PPPoE connection ${LPPPOE_PROVIDER} reestablished and is UP."
			else 
				date_message "${SCRIPT_NAME} error: Could not reestablish PPPoE connection ${LPPPOE_PROVIDER}."
			fi
			LRET=$?
		else
			date_message "Error: could not determine a PPPoE account to reestablish PPPoE connection."
			LRET=1
		fi
	fi
	
	return $LRET
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

# Process cmd line args..
SHORTARGS='hqftw:'
LONGARGS='help,quiet,force,test,wait:'
ARGS=$(getopt -o "$SHORTARGS" -l "$LONGARGS"  -n "$(basename $0)" -- $@)

eval set -- "$ARGS"

while [ $# -gt 0 ]; do
	case "$1" in
		--)
			;;
		-h|--help)		# Display this help
			date_message "${SCRIPT_NAME} [ -h|--help ] [ -f|--force ] [ -t|--test ] [ -w|--wait=waitsecs ] [ provider_name ]"
			exit 0
			;;
		-q|--quiet)		# Inhibit message output
			QUIET=1
			VERBOSE=0
			;;
		-f|--force)		# Use the DEF_PROVIDER account if no /etc/network/interfaces file
			FORCE=1
			;;
		-t|--test)
			TEST=1
			;;
		-w|--wait)
			shift
			WAITSECS=$1
			;;
		*)
			DEF_PROVIDER="$1"
			;;
	esac
	shift
done

ppp_link_check
exit $?

