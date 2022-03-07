#!/bin/bash

######################################################################################################
# Bash script for installing systemd service and timer unit files to run and maintain the
#   LCWA PPPoE Speedtest Logger python code.
######################################################################################################
SCRIPT_VERSION=20220306.190748

SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
SCRIPT_NAME="$(basename $0)"
SCRIPT_DESC="Installs the ppp package and a systemd service to connect a PPPoE interface."

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

echo "Reading ${INCLUDE_FILE}.." 1>&2
. "$INCLUDE_FILE"

if [[ -z "$INCSCRIPT_VERSION" ]] || [[ "$INCSCRIPT_VERSION" < "$REC_INCSCRIPT_VER" ]]; then
	echo "${SCRIPT_NAME} error: ${INCLUDE_FILE} version is ${INCSCRIPT_VERSION}. Version ${REC_INCSCRIPT_VER} or newer is required."
fi

######################################################################################################
# Vars
######################################################################################################

DEBUG=0
QUIET=0
VERBOSE=0
FORCE=0
TEST=0
NO_PAUSE=1
NO_START=0
INST_ENVFILE_LOCK=0

INST_NAME='pppoe-connect'
INST_NAME_SERVICE="${INST_NAME}.service"
[ $IS_DEBIAN -gt 0 ] && INST_NAME_ENVFILE="/etc/default/${INST_NAME}" || INST_NAME_ENVFILE="/etc/sysconfig/${INST_NAME}"
INST_PROD="PPPoE Connection Service"
INST_DESC="$INST_DESC"

INST_PPPOE_INSTALL=
INST_PPPOE_PROVIDER=
INST_PPPOE_PASSWORD=
INST_NAME_ENVFILE=
LCWA_ENVFILE=

NEEDSUSER=0
NEEDSCONF=0
NEEDSDATA=0
NEEDSLOG=0



ppp_pkg_install(){
	debug_echo "${FUNCNAME}( $@ )"
	local LPKG='ppp'
	
	if [ $USE_APT -gt 0 ]; then
		local MAX_AGE=$((2 * 60 * 60))
		local CACHE_DIR='/var/cache/apt/'
		local CACHE_DATE=$(stat -c %Y "$CACHE_DIR")
		local NOW_DATE=$(date --utc '+%s')
		local CACHE_AGE=$(($NOW_DATE - $CACHE_DATE))
		local SZCACHE_AGE="$(echo "scale=2; (${CACHE_AGE} / 60 / 60)" | bc) hours"
		local LFIX_MISSING=

		if [ $FORCE -gt 0 ] || [ $CACHE_AGE -gt $MAX_AGE ]; then
			[ $CACHE_AGE -gt $MAX_AGE ] && [ $VERBOSE -gt 0 ] && error_echo "Local cache is out of date. Updating apt-get package cacahe.." || error_echo "Updating apt-get package cacahe.."
			[ $FORCE -gt 1 ] && LFIX_MISSING='--fix-missing'
			[ $DEBUG -gt 0 ] && apt-get "$LFIX_MISSING" update  || apt-get -qq "$LFIX_MISSING" update 
		else
			[ $VERBOSE -gt 0 ] && error_echo  "Local apt cache is up to date as of ${SZCACHE_AGE} ago."
		fi

		if [ $(dpkg -s "$LPKG" 2>&1 | grep -c 'Status: install ok installed') -gt 0 ] && [ $FORCE -lt 1 ]; then
			[ $VERBOSE -gt 0 ] && error_echo "Package ${LPKG} already installed.."
		else
			[ $QUIET -lt 1 ] && error_echo "Installing package ${LPKG}.."
			[ $DEBUG -gt 0 ] && apt-get install "$LPKG" || apt-get -y -qq install "$LPKG"
		fi
	else
		[ $QUIET -lt 1 ] && error_echo "Updating dnf package cacahe.."
		dnf -y update
		[ $QUIET -lt 1 ] && error_echo "Installing package ${LPKG}.."
		dnf install -y --allowerasing "$LPKG"

	fi

	if [ -z "$(which pppd)" ]; then
		error_echo  "${SCRIPT_NAME} error: Could not install package ${LPKG}."
		return 1
	fi
}


systemd_unit_start(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LUNIT="$1"
	local LUNIT_FILE="/lib/systemd/system/${LUNIT}"
	LRET=1
	
	# Start only enabled services or timers..
	if [ -f "$LUNIT_FILE" ]; then
		if systemctl is-enabled --quiet "$LUNIT" 2>/dev/null; then
			[ $QUIET -lt 1 ] && error_echo "Starting ${LUNIT}.."
			[ $TEST -lt 1 ] && systemctl restart "$LUNIT" && LRET=0
		fi
	else
		[ $VERBOSE -gt 0 ] && error_echo "${SCRIPT_NAME} ${FUNCNAME}() error: Cannot start ${LUNIT}."
		[ $VERBOSE -gt 0 ] && error_echo "File ${LUNIT_FILE} not found."
	fi
	
	return $LRET
}

systemd_unit_stop(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LUNIT="$1"
	
	if systemctl is-active --quiet "$LUNIT" 2>/dev/null; then
		[ $QUIET -lt 1 ] && error_echo "Stopping ${LUNIT}.."
		[ $TEST -lt 1 ] && systemctl stop "$LUNIT"
	fi
}

systemd_unit_enable(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LUNIT="$1"
	local LUNIT_FILE="/lib/systemd/system/${LUNIT}"
	
	if [ -f "$LUNIT_FILE" ]; then
		[ $QUIET -lt 1 ] && error_echo "Enabling ${LUNIT}.."
		[ $TEST -lt 1 ] && systemctl enable "$LUNIT"
	else
		# This is not actually an error condition..
		[ $VERBOSE -gt 0 ] && error_echo "${SCRIPT_NAME} ${FUNCNAME}() error: Cannot enable ${LUNIT}."
		[ $VERBOSE -gt 0 ] && error_echo "File ${LUNIT_FILE} not found."
	fi
}

systemd_unit_disable(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LUNIT="$1"
	
	systemd_unit_stop "$LUNIT"
	
	if systemctl is-enabled --quiet "$LUNIT" 2>/dev/null; then
		[ $QUIET -lt 1 ] && error_echo "Disabling ${LUNIT}.."
		[ $TEST -lt 1 ] && systemctl disable "$LUNIT"
	fi
}

# systemd_unit_remove() -- stops, disables, and removes a systemd unit file
systemd_unit_remove(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LUNIT="$1"
	local LUNIT_FILE="/lib/systemd/system/${LUNIT}"
	
	if [ -f "$LUNIT_FILE" ]; then
		systemd_unit_disable "$LUNIT"
		[ $QUIET -lt 1 ] && error_echo "Removing ${LUNIT_FILE}.."
		[ $TEST -lt 1 ] && rm "$LUNIT_FILE"
	fi
}

systemd_unit_status(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LUNIT="$1"
	local LUNIT_FILE="/lib/systemd/system/${LUNIT}"
	
	if [ -f "$LUNIT_FILE" ]; then
		[ $TEST -lt 1 ] && systemctl -l --no-pager status "$LUNIT"
	else
		error_echo "${SCRIPT_NAME} ${FUNCNAME}() error: Cannot cannot get status of ${LUNIT}."
		error_echo "File ${LUNIT_FILE} not found."
	fi
}

ppp_detect(){
	debug_echo "${FUNCNAME}( $@ )"
	local LPPPOE_ACCOUNT=

	if [ ! -f /etc/network/interfaces ]; then
		return 1
	fi
	
	[ $QUIET -lt 1 ] && error_echo "Checking for PPPoE interface in /etc/network/interfaces"
	
	LPPPOE_ACCOUNT="$(grep -E '^auto.*lcwa.*$|^auto.*provider.*$' /etc/network/interfaces | awk '{ print $2 }')"
	
	if [ -z "$LPPPOE_ACCOUNT" ]; then
		[ $QUIET -lt 1 ] && error_echo "No ppp interface defined in /etc/network/interfaces"
		return 1
	fi
	
	return 0
}

ppp_link_is_up(){

	[ $(ip -br a | grep -c -E '^ppp.*peer') -gt 0 ] && return 0 || return 1

}

iface_static_get(){
	debug_echo "${FUNCNAME}( $@ )"
	
	# Return the 1st interface that has a static ip address
	#~ ip -4 addr show | grep -E '^\s+inet.*global' | grep -v 'ppp' | grep -m1 -v 'dynamic' | awk '{print $NF}'
	ip -o addr show | grep -E 'inet.*172\.16\..*global' | grep -v 'ppp' | awk '{ print $2 }'
}

pppoe_provider_create(){
	debug_echo "${FUNCNAME}( $@ )"
	local LPROVIDER="${1:-'provider'}"
	local LPASSWORD="${2:-'password'}"
	# Get the first linked interface with a 172.16. static ip..
	local LSTATIC_IFACE="$(iface_static_get)"
	local LPROVIDER_DIR='/etc/ppp/peers'
	local LPROVIDER_FILE="${LPROVIDER_DIR}/${LPROVIDER}"
	local LDEFPASS='b2NtNjhodjAK'
	local LRET=0
	
	
	# Two more tries to get an interface name.
	[ -z "$LSTATIC_IFACE" ] && LSTATIC_IFACE="$(iface_primary_geta)"
	[ -z "$LSTATIC_IFACE" ] && LSTATIC_IFACE="$(ls -1 '/sys/class/net' | sort | grep -m1 -v -E '^lo$')"
	
	if [ -z "$LSTATIC_IFACE" ]; then
		error_echo "${SCRIPT_NAME} error: Could not find a linked network interface."
		return 1
	fi
	
	# Note: Fedora's ppp package doesn't create the peers directory
	[ ! -d "$LPROVIDER_DIR" ] && mkdir -p "$LPROVIDER_DIR"
	
	# Create the /etc/ppp/peers/provider file

	[ -f "$LPROVIDER_FILE" ] && [ ! -f "${LPROVIDER_FILE}.org" ] && cp -p "$LPROVIDER_FILE" "${LPROVIDER_FILE}.org"
	
	[ $QUIET -lt 1 ] && error_echo "Creating ${LPROVIDER_FILE}.."
	
	[ $TEST -lt 1 ] && cat >"$LPROVIDER_FILE" <<-EOF_PROVIDER;
	# $(date) -- ${LPROVIDER_FILE}
	# Minimalistic default options file for DSL/PPPoE connections

	noipdefault
	defaultroute
	replacedefaultroute
	hide-password
	#lcp-echo-interval 30
	#lcp-echo-failure 4
	noauth
	persist
	nodetach
	#debug
	mtu 1480
	#persist
	#maxfail 0
	#holdoff 20
	plugin rp-pppoe.so
	nic-${LSTATIC_IFACE}
	user "${LPROVIDER}"
	usepeerdns
	EOF_PROVIDER
	
	[ $DEBUG -gt 2 ] && debug_cat "$LPROVIDER_FILE"	

	if [ ! -f "$LPROVIDER_FILE" ]; then
		error_echo "${FUNCNAME}( $@ ): Error -- could not create ${LPROVIDER_FILE} provider file."
		((LRET+=1))
	else
		[ $TEST -lt 1 ] && chown root:root "$LPROVIDER_FILE"
		[ $TEST -lt 1 ] && chmod 0640 "$LPROVIDER_FILE"
	fi
	
	# Create the /etc/ppp/chap-secrets
	local LSECRETS_FILE='/etc/ppp/chap-secrets'

	[ -f "$LSECRETS_FILE" ] && [ ! -f "${LSECRETS_FILE}.org" ] && cp -p "$LSECRETS_FILE" "${LSECRETS_FILE}.org"

	[ $QUIET -lt 1 ] && error_echo "Creating ${LSECRETS_FILE}.."
	
	LDEFPASS="$(echo "$LDEFPASS" | openssl enc -base64 -d)"

	[ $TEST -lt 1 ] && cat >"$LSECRETS_FILE" <<-EOF_SECRETS0;
	# $(date) -- ${LSECRETS_FILE}
	# Secrets for authentication using CHAP
	# client	server	secret			IP addresses

	"speedtest5a" "speedtest5a" "${LDEFPASS}"
	"speedtest20a" "speedtest20a" "${LDEFPASS}"
	"speedtest20b" "speedtest20b" "${LDEFPASS}"
	"speedtest20c" "speedtest20c" "${LDEFPASS}"
	"speedtest20d" "speedtest20d" "${LDEFPASS}"
	"speedtest20e" "speedtest20e" "${LDEFPASS}"
	"speedtest20f" "speedtest20f" "${LDEFPASS}"
	"speedtest20g" "speedtest20g" "${LDEFPASS}"
	
	EOF_SECRETS0
	
	# See if our provider & password are in the secrets file..if not, add it.
	if [ $(cat "$LSECRETS_FILE" | grep -c -E "^.*${LPROVIDER}.*${LPASSWORD}.*\$") -lt 1 ]; then
		echo "\"${LPROVIDER}\" \"${LPROVIDER}\" \"${LPASSWORD}\"" >>"$LSECRETS_FILE"
	fi

	[ $DEBUG -gt 2 ] && debug_cat "$LSECRETS_FILE"
	
	if [ ! -f "$LSECRETS_FILE" ]; then
		error_echo "${FUNCNAME}( $@ ): Error -- could not create ${LSECRETS_FILE} secrets file."
		((LRET+=1))
	else
		[ $TEST -lt 1 ] && chown root:root "$LSECRETS_FILE"
		[ $TEST -lt 1 ] && chmod 0600 "$LSECRETS_FILE"
	fi
	
	# Create the /etc/ppp/pap-secrets file
	local LSECRETS_FILE='/etc/ppp/pap-secrets'
	
	[ $QUIET -lt 1 ] && error_echo "Creating ${LSECRETS_FILE}.."

	[ -f "$LSECRETS_FILE" ] && [ ! -f "${LSECRETS_FILE}.org" ] && cp -p "$LSECRETS_FILE" "${LSECRETS_FILE}.org"
	[ $TEST -lt 1 ] && cat >"$LSECRETS_FILE" <<-EOF_SECRETS1;
	# $(date) -- ${LSECRETS_FILE}
	# Every regular user can use PPP and has to use passwords from /etc/passwd
	*	hostname	""	*

	# UserIDs that cannot use PPP at all. Check your /etc/passwd and add any
	# other accounts that should not be able to use pppd!
	guest	hostname	"*"	-
	master	hostname	"*"	-
	root	hostname	"*"	-
	support	hostname	"*"	-
	stats	hostname	"*"	-

	# OUTBOUND connections

	# Here you should add your userid password to connect to your providers via
	# PAP. The * means that the password is to be used for ANY host you connect
	# to. Thus you do not have to worry about the foreign machine name. Just
	# replace password with your password.
	# If you have different providers with different passwords then you better
	# remove the following line.

	#	*	password

	"speedtest5a" "speedtest5a" "${LDEFPASS}"
	"speedtest20a" "speedtest20a" "${LDEFPASS}"
	"speedtest20b" "speedtest20b" "${LDEFPASS}"
	"speedtest20c" "speedtest20c" "${LDEFPASS}"
	"speedtest20d" "speedtest20d" "${LDEFPASS}"
	"speedtest20e" "speedtest20e" "${LDEFPASS}"
	"speedtest20f" "speedtest20f" "${LDEFPASS}"
	"speedtest20g" "speedtest20g" "${LDEFPASS}"

	EOF_SECRETS1

	# create the /etc/ppp/resolv.conf file???
	# See if our provider & password are in the secrets file..if not, add it.
	if [ $(cat "$LSECRETS_FILE" | grep -c -E "^.*${LPROVIDER}.*${LPASSWORD}.*\$") -lt 1 ]; then
		echo "\"${LPROVIDER}\" \"${LPROVIDER}\" \"${LPASSWORD}\"" >>"$LSECRETS_FILE"
	fi
	
	[ $DEBUG -gt 2 ] && debug_cat "$LSECRETS_FILE"	

	if [ ! -f "$LSECRETS_FILE" ]; then
		error_echo "${FUNCNAME}( $@ ): Error -- could not create ${LSECRETS_FILE} secrets file."
		((LRET+=1))
	else
		[ $TEST -lt 1 ] && chown root:root "$LSECRETS_FILE"
		[ $TEST -lt 1 ] && chmod 0600 "$LSECRETS_FILE"
	fi
	
	[ $DEBUG -gt 3 ] && debug_pause "${LINENO} ${FUNCNAME}() done."
	
	return $LRET
}

pppoe_connect_service_create(){
	debug_echo "${FUNCNAME}( $@ )"
	
	# create the /lib/systemd/system/pppoe-connect.service file
	local LPPPOE_SERVICE_NAME="${1:-${INST_NAME_SERVICE}}"
	local LPPPOE_PROVIDER="${2:-'provider'}"
	local LENV_FILE="${3:-${INST_NAME_ENVFILE}}"
	local LENV_PROVIDER_VARNAME="$(grep 'PROVIDER' "$LENV_FILE" | awk -F '=' '{ print $1 }')"
	local LPPPOE_SERVICE_FILE="/lib/systemd/system/${LPPPOE_SERVICE_NAME}"
	local LRET=1
	
	if [ $DEBUG -gt 1 ]; then
		error_echo "=========================================="
		error_echo "   LPPPOE_SERVICE_NAME == ${LPPPOE_SERVICE_NAME}"
		error_echo "   LPPPOE_SERVICE_FILE == ${LPPPOE_SERVICE_FILE}"
		error_echo "       LPPPOE_PROVIDER == ${LPPPOE_PROVIDER}"
		error_echo "             LENV_FILE == ${LENV_FILE}"
		error_echo " LENV_PROVIDER_VARNAME == ${LENV_PROVIDER_VARNAME}"
		error_echo "=========================================="
	fi
	
	[ $QUIET -lt 1 ] && error_echo "Creating ${LPPPOE_SERVICE_NAME} for provider ${LPPPOE_PROVIDER}.."

	[ $TEST -lt 1 ] && cat >"$LPPPOE_SERVICE_FILE" <<-EOF_PPPOESRVC0;
	# $(date) -- ${LPPPOE_SERVICE_FILE}
	# Adapted from https://www.sherbers.de/diy-linux-router-part-3-pppoe-and-routing/

	[Unit]
	Description=PPPoE Connection Service
	After=network-online.target

	[Service]
	Type=exec
	EnvironmentFile=${LENV_FILE}
	ExecStart=/usr/sbin/pppd call \$${LENV_PROVIDER_VARNAME}

	Restart=always
	RestartSec=10s

	# filesystem access
	ProtectSystem=strict
	ReadWritePaths=/run/

	PrivateTmp=true
	ProtectControlGroups=true
	ProtectKernelModules=true
	ProtectKernelTunables=true

	# network
	RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_PPPOX AF_PACKET AF_NETLINK

	# misc
	NoNewPrivileges=true
	RestrictRealtime=true
	MemoryDenyWriteExecute=true
	ProtectKernelLogs=true
	LockPersonality=true
	ProtectHostname=true
	RemoveIPC=true
	RestrictSUIDSGID=true
	RestrictNamespaces=true

	# capabilities
	CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
	SystemCallFilter=@system-service
	SystemCallErrorNumber=EPERM

	[Install]
	WantedBy=multi-user.target
	
	EOF_PPPOESRVC0
	
	if [ ! -f "$LPPPOE_SERVICE_FILE" ] && [ $TEST -lt 1 ]; then
		error_echo "${FUNCNAME}( $@ ): Error -- could not create ${LPPPOE_SERVICE_FILE} file."
		LRET=1
	else
		[ $TEST -lt 1 ] && chown root:root "$LPPPOE_SERVICE_FILE"
		[ $TEST -lt 1 ] && chmod 0644 "$LPPPOE_SERVICE_FILE"
		LRET=0
	fi
	
	[ $DEBUG -gt 2 ] && debug_cat "$LPPPOE_SERVICE_FILE"	

	[ $DEBUG -gt 3 ] && debug_pause "${LINENO} ${FUNCNAME}() done."
	
	return $LRET
}


# Remove old crontab entries
crontab_clean(){
	debug_echo "${FUNCNAME}( $@ )"
	local ROOTCRONTAB='/var/spool/cron/crontabs/root'
	local COMMENT=
	local EVENT=

	[ ! -f "$ROOTCRONTAB" ] && return 0
	
	[ $QUIET -lt 1 ] && error_echo "Removing old crontab entries from ${ROOTCRONTAB}"
	
	COMMENT='#At every 10th minute, check the lcwa20a PPPoE connecton and reestablish it if down.'
	EVENT='*/10 * * * * /usr/local/sbin/chkppp.sh | /usr/bin/logger -t lcwa-pppchk'
	[ $QUIET -lt 1 ] && error_echo "Removing ${EVENT} from ${ROOTCRONTAB}"
	[ $TEST -lt 1 ] && sed -i '/^#.*every 10th minute.*$/d' "$ROOTCRONTAB" >/dev/null 2>&1
	[ $TEST -lt 1 ] && sed -i '/^.*chkppp.*$/d' "$ROOTCRONTAB" >/dev/null 2>&1

	# signal crond to reload the file
	[ $TEST -lt 1 ] && sudo touch /var/spool/cron/crontabs

	# Make the entry stick
	[ $QUIET -lt 1 ] && error_echo "Restarting root crontab.."
	[ $TEST -lt 1 ] && systemctl restart cron

	[ $QUIET -lt 1 ] && error_echo 'New crontab:'
	[ $QUIET -lt 1 ] && error_echo "========================================================================================="
	[ $QUIET -lt 1 ] && crontab -l >&2
	[ $QUIET -lt 1 ] && error_echo "========================================================================================="

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

SHORTARGS='hdqvftr'

LONGARGS="help,
debug,
quiet,
verbose,
test,
force,
remove,
uninstall,
static,
pppoe::,
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
		-h|--help)				# Displays this help
			disp_help "$SCRIPT_DESC"
			exit 0
			;;
		-d|--debug)				# Shows debugging info.
			((DEBUG+=1))
			;;
		-q|--quiet)				# Supresses message output.
			QUIET=1
			;;
		-v|--verbose)			# Increase message output.
			((VERBOSE+=1))
			;;
		-f|--force)				# Tests script logic without performing actions.
			((FORCE+=1))
			;;
		-t|--test)				# Tests script logic without performing actions.
			((TEST+=1))
			;;
		-r|--remove|--uninstall) 	# Disables and removes the lcwa-speed services and timers
			UNINSTALL=1
			;;
		--pppoe)	# ='ACCOUNT:PASSWORD' Forces install of the PPPoE connect service. Ex: --pppoe=account_name:password
			shift
			INST_PPPOE_INSTALL=1
			INST_PPPOE_PROVIDER="$( echo "$1" | awk -F: '{ print $1 }')"
			INST_PPPOE_PASSWORD="$( echo "$1" | awk -F: '{ print $2 }')"
			;;
		--env-file)				# =NAME -- Read a specific env file to get the locations for the install.
			shift
			LCWA_ENVFILE="$1"
			if [ -f "$LCWA_ENVFILE" ] && [ $(grep -c 'LCWA_' "$LCWA_ENVFILE") -gt 0 ]; then
				LCWA_ENVFILE="$(readlink -f "$LCWA_ENVFILE")"
				INST_NAME_ENVFILE="$LCWA_ENVFILE"
			else
				LCWA_ENVFILE=
			fi
			;;
		*)
			;;
	esac
	shift
done

[ $VERBOSE -gt 0 ] && error_echo "${SCRIPTNAME} ${PRE_ARGS}"

if [ $DEBUG -gt 0 ];  then
	error_echo "=========================================="
	error_echo "              DEBUG == ${DEBUG}"
	error_echo "              QUIET == ${QUIET}"
	error_echo "            VERBOSE == ${VERBOSE}"
	error_echo "              FORCE == ${FORCE}"
	error_echo "               TEST == ${TEST}"
	error_echo "          UNINSTALL == ${UNINSTALL}"
	error_echo "=========================================="
	error_echo "       LCWA_ENVFILE == ${LCWA_ENVFILE}"
	error_echo "  INST_NAME_ENVFILE == ${INST_NAME_ENVFILE}"
	error_echo "=========================================="
	error_echo " INST_PPPOE_INSTALL == ${INST_PPPOE_INSTALL}"
	error_echo "INST_PPPOE_PROVIDER == ${INST_PPPOE_PROVIDER}"
	error_echo "INST_PPPOE_PASSWORD == ${INST_PPPOE_PASSWORD}"
	error_echo "=========================================="
	debug_pause "Press any key to continue.."
fi

if [ $UNINSTALL -gt 0 ]; then
	[ $QUIET -lt 1 ] & error_echo "Uninstalling ${INST_NAME_SERVICE}.."
	systemd_unit_stop "$INST_NAME_SERVICE"
	systemd_unit_disable "$INST_NAME_SERVICE"
	systemd_unit_remove "$INST_NAME_SERVICE"
	systemctl daemon-reload
	systemctl reset-failed
	if [ -z "$LCWA_ENVFILE" ] && [ -f "$INST_NAME_ENVFILE" ]; then
		env_file_remove "$INST_NAME_ENVFILE"
	fi
	
else
	[ $QUIET -lt 1 ] & error_echo "Installing ${INST_NAME_SERVICE}.."
	INST_PPPOE_INSTALL=1
	[ -z "$INST_PPPOE_PROVIDER" ] && INST_PPPOE_PROVIDER="provider"
	[ -z "$INST_PPPOE_PASSWORD" ] && INST_PPPOE_PASSWORD="password"
	
	if [ ! -z "$LCWA_ENVFILE" ]; then
		[ $QUIET -lt 1 ] && error_echo "Updating ${LCWA_ENVFILE} with provider information.."
		
		[ ! -f "${LCWA_ENVFILE}.org" ] && cp -p "$LCWA_ENVFILE" "${LCWA_ENVFILE}.org"
		cp -p "$LCWA_ENVFILE" "${LCWA_ENVFILE}.bak"

		LCWA_PPPOE_INSTALL="$INST_PPPOE_INSTALL"
		LCWA_PPPOE_PROVIDER="$INST_PPPOE_PROVIDER"
		LCWA_PPPOE_PASSWORD="$INST_PPPOE_PASSWORD"
		
		env_file_update "$LCWA_ENVFILE" LCWA_PPPOE_INSTALL LCWA_PPPOE_PROVIDER LCWA_PPPOE_PASSWORD
		
		debug_cat "$LCWA_ENVFILE"
	else
		[ $QUIET -lt 1 ] && error_echo "Saving provider information to ${INST_NAME_ENVFILE}.."
		echo "PROVIDER=${INST_PPPOE_PROVIDER}" >"$INST_NAME_ENVFILE"
	fi
	
	# Clean out possible chkppp.sh entries from the root crontab only if forcing..
	[ $FORCE -gt 0 ] && crontab_clean

	systemd_unit_stop "$INST_NAME_SERVICE"
	systemd_unit_disable "$INST_NAME_SERVICE"

	ppp_pkg_install || error_exit "Could not install ppp package. Exiting."
	
	pppoe_provider_create "$INST_PPPOE_PROVIDER" "$INST_PPPOE_PASSWORD" || error_exit "Could not create provider files. Exiting."
	
	pppoe_connect_service_create "$INST_NAME_SERVICE" "$INST_PPPOE_PROVIDER" "$INST_NAME_ENVFILE" || error_exit "Could not create ${INST_NAME} service file. Exiting."
	
	systemd_unit_enable "$INST_NAME_SERVICE"
	
	systemctl daemon-reload
	systemctl reset-failed

	[ $NO_START -lt 1 ] && systemd_unit_start "$INST_NAME_SERVICE"
	
	systemd_unit_status "$INST_NAME_SERVICE"
	
fi

[ $QUIET -lt 1 ] && error_echo "${SCRIPT_NAME} done."

