#!/bin/bash

######################################################################################################
# Bash script for setting basic firewall rules
#   Defaults to openening bootpc, ssh & iperf3 to all subnnets.
######################################################################################################
SCRIPT_VERSION=20240202.155014

SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
SCRIPT_NAME="$(basename $0)"
SCRIPT_DESC="Configures and opens firewall for bootpc, ssh & iperf3 ports"


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
PRIVATE=0	# Default is public
TEST=0
#~ KEEP_PREVIOUS=1

########################################################################################
# firewall_check_install() -- checks for an active ufw or firewalld installation.
#							  Installs same if not found.
########################################################################################
firewall_check_install(){
	debug_echo "${FUNCNAME}( $@ )"

	# Simplistic check for for a firewall
	#~ [ ! -z "$(which ufw)" ] && return 0
	
	[ $USE_UFW -gt 0 ] || [ $USE_FIREWALLD -gt 0 ] && return 0
	
	# If neither ufw or firewalld is active, install one of them depending on the distro type
	if [ $USE_UFW -eq 0 ] && [ $USE_FIREWALLD -eq 0 ]; then
		if [ $USE_APT -gt 0 ]; then
			[ $QUIET -lt 1 ] && error_echo "Installing ufw.."
			[ $TEST -lt 1 ] && apt-get -qq update
			[ $TEST -lt 1 ] && apt-get -y -qq install 'ufw' >/dev/null 2>&1			
		elif [ $USE_YUM -gt 0 ]; then
			[ $QUIET -lt 1 ] && error_echo "Installing firewalld.."
			[ $TEST -lt 1 ] && dnf install firewalld -y
		else
			error_echo "${FUNCNAME}() error: cannot install a system firewall! Exiting!"
			exit 1
		fi
	fi
}

########################################################################################
# firewall_rule_count_get() -- attempts to get a rough count of active
#							   firewall rules.
########################################################################################
firewall_rule_count_get(){
	debug_echo "${FUNCNAME}( $@ )"
	if [ $USE_UFW -gt 0 ]; then
		ufw status numbered | grep -c -E '^\['
	elif [ $USE_FIREWALLD -gt 0 ]; then
		firewall-cmd --list-services | wc -w
	else
		error_echo "${FUNCNAME}() error: Cannot determine firewall service."
		return 1
	fi
}

########################################################################################
# firewall_failsafe_config() -- make sure every interface at least has 
#                               tcp port 22 open for ssh, upd & tcp port 68 for bootpc
#                               and udp & tcp pot 5201 for iperf3
########################################################################################
firewall_failsafe_config(){	
	debug_echo "${FUNCNAME}( $@ )"
	local LBPRIVATE="$1"
	local LIFACE=
	local LIPADDR=
	local LPORT=

	# Open for bootpc, ssh, iperf3
	local UDP_FAILSAFE_PORTS=(68 5201)
	local TCP_FAILSAFE_PORTS=(22 68 5201)
	
	# Open ports for connections from any source..
	if [ $LBPRIVATE -lt 1 ]; then
		for LPORT in "${UDP_FAILSAFE_PORTS[@]}"
		do
			iface_firewall_port_open "" 'udp' "$LPORT"
		done
	
		for LPORT in "${TCP_FAILSAFE_PORTS[@]}"
		do
			iface_firewall_port_open "" 'tcp' "$LPORT"
		done
		
		return 0
	fi

	# Open ports for connections only from our subnet..
	for LIFACE in $(ifaces_get)
	do
		iface_has_link "$LIFACE" || continue

		LIPADDR="$(iface_ipaddress_get "$LIFACE")"

		[ $QUIET -lt 1 ] && error_echo "Configuring failsafe firewall for ${LIFACE} ${LIPADDR}"

		for LPORT in "${UDP_FAILSAFE_PORTS[@]}"
		do
			# Open this port for connections from any source..
			ipaddr_firewall_port_open  "$LIPADDR" 'udp' "$LPORT"
		done

		for LPORT in "${TCP_FAILSAFE_PORTS[@]}"
		do
			ipaddr_firewall_port_open  "$LIPADDR" 'tcp' "$LPORT"
		done

	done
	debug_pause "${FUNCNAME}: ${LINENO}"
	return 0
}

########################################################################################
# firewall_disable() -- disables the system firewall
########################################################################################
firewall_disable(){
	debug_echo "${FUNCNAME}( $@ )"

	debug_echo "${FUNCNAME} $@"
	[ $QUIET -lt 1 ] && error_echo "Disabling firewall.."
	if [ $USE_FIREWALLD -gt 0 ]; then
		systemctl stop firewalld
	elif [ $USE_UFW -gt 0 ]; then
		ufw disable >/dev/null 2>&1
	fi
	debug_pause "${FUNCNAME}: ${LINENO}"
}

########################################################################################
# firewall_enable() -- enables the system firewall
########################################################################################
firewall_enable(){
	debug_echo "${FUNCNAME}( $@ )"

	[ $QUIET -lt 1 ] && error_echo "Enabling firewall.."
	if [ $USE_FIREWALLD -gt 0 ]; then
		systemctl start firewalld
		return 0
	elif [ $USE_UFW -gt 0 ]; then
		echo y | ufw enable >/dev/null 2>&1
		ufw status verbose
	fi
	debug_pause "${FUNCNAME}: ${LINENO}"
}

########################################################################################
# firewall_set_defaults() Resets the system firewall to all incoming ports closed
########################################################################################
firewall_set_defaults(){
	debug_echo "${FUNCNAME}( $@ )"
	local LFW_RULE_COUNT=$(firewall_rule_count_get)

	firewall_disable
	
	# Set defaults
	if [ $FORCE -gt 0 ] || [ $(firewall_rule_count_get) -lt 4 ]; then
		[ $QUIET -lt 1 ] && error_echo "Setting firewall to defaults.."
		# Wipe out any previous firewall settings..
		if [ $USE_FIREWALLD -gt 0 ]; then
			# Just remove all files from /etc/firewalld/zones & reload & restart firewalld?
			# See: https://bugzilla.redhat.com/show_bug.cgi?id=1531545
			
			local LIFACE=$(iface_primary_getb)
			local LSUBNET=$(iface_subnet_get "$LIFACE")
			local LFWZONE=

			# Delete any user modifications to zones..
			[ $TEST -lt 1 ] && rm -rf /etc/firewalld/zones/*
			[ $TEST -lt 1 ] && firewall-cmd --reload
			
			LFWZONE='public'
			[ $QUIET -lt 1 ] && error_echo "Adding interface ${LIFACE} to zone ${LFWZONE}.."
			[ $TEST -lt 1 ] && firewall-cmd --permanent --zone=${LFWZONE} --add-interface=${LFWZONE} >/dev/null
			
			LFWZONE="$(firewall-cmd --get-default-zone)"
			[ $QUIET -lt 1 ] && error_echo "Adding source ${LSUBNET} to zone ${LFWZONE}.."
			[ $TEST -lt 1 ] && firewall-cmd --zone=${LFWZONE} --change-source=${LSUBNET} --permanent >/dev/null
		
			firewall-cmd --reload
		elif [ $USE_UFW -gt 0 ]; then
			ufw --force reset >/dev/null 2>&1
			ufw default deny incoming >/dev/null 2>&1
			ufw default allow outgoing >/dev/null 2>&1
		fi
	fi

	firewall_failsafe_config $PRIVATE

	firewall_enable
	debug_pause "${FUNCNAME}: ${LINENO}"
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


SHORTARGS='hdqvftp'

LONGARGS="
help,
debug,
quiet,
verbose,
test,
force,
private,
public,
minimal
inst-name:,
service-name:,
env-file:
"

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
		-v|--verbose)			# Supresses message output.
			((VERBOSE+=1))
			;;
		-f|--force)			# Force wipe of any existing firewall rules.
			((FORCE+=1))
			;;
		-t|--test)			# Tests script logic without performing actions.
			((TEST+=1))
			;;
		-p|--private)		# Open default ports to local subnet only.
			PRIVATE=1
			;;
		-p|--pubic)		# Open default ports to any subnet.
			PRIVATE=0
			;;
		*)
			;;
	esac
	shift
done

[ $VERBOSE -gt 0 ] && error_echo "${SCRIPTNAME} ${PRE_ARGS}"

# Make sure ufw is installed
firewall_check_install

firewall_set_defaults



