#!/bin/bash

######################################################################################################
# Bash script for installing systemd service and timer unit files to run and maintain the
#   LCWA PPPoE Speedtest Logger python code.
######################################################################################################
SCRIPT_VERSION=20220227.145316

SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
SCRIPT_NAME="$(basename $0)"
SCRIPT_DESC="Installs systemd service and timer unit files for the lcwa-speed service."

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
ALLOW_BADARGS=0
NO_PAUSE=0
UNINSTALL=0
UPDATE=0
ENABLE=1
DISABLE=0
NO_START=0

ACTION=

# Save our HOME var to be restored later..
CUR_HOME="$HOME"

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

INCLUDE_FILE="$(dirname $(readlink -f $0))/lcwa-speed-env.sh"
[ ! -f "$INCLUDE_FILE" ] && INCLUDE_FILE='/usr/local/sbin/lcwa-speed-env.sh'

if [ ! -f "$INCLUDE_FILE" ]; then
	error_echo "${SCRIPT_NAME} error: Could not find env vars declaration file ${INCLUDE_FILE}. Exiting."
	exit 1
fi

debug_echo "Including file: ${INCLUDE_FILE}"

. "$INCLUDE_FILE"


systemd_uint_start(){
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

systemd_uint_stop(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LUNIT="$1"
	
	if systemctl is-active --quiet "$LUNIT" 2>/dev/null; then
		[ $QUIET -lt 1 ] && error_echo "Stopping ${LUNIT}.."
		[ $TEST -lt 1 ] && systemctl stop "$LUNIT"
	fi
}

systemd_uint_enable(){
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

systemd_uint_disable(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LUNIT="$1"
	
	systemd_uint_stop "$LUNIT"
	
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
		systemd_uint_disable "$LUNIT"
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

######################################################################################################
# systemd_unit_file_create() Create the main service systemd unit file.  Depends on global variables
######################################################################################################
lcwa_speed_unit_file_create(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LUNIT_FILE="/lib/systemd/system/${LCWA_SERVICE}.service"
	local LACTION=
	
	[ $TEST -gt 2 ] && LUNIT_FILE="./${LCWA_SERVICE}.service"
	
	[ ! -f "$LUNIT_FILE" ] && LACTION='Creating' || LACTION='Overwriting'
	[ $QUIET -lt 1 ] && error_echo "${LACTION} ${LUNIT_FILE}.."
	
	[ $TEST -lt 1 ] && cat >"$LUNIT_FILE" <<-SYSTEMD_SCR1;
	## ${LUNIT_FILE} -- $(date)
	## systemd service unit file

	[Unit]
	Description=$LCWA_DESC
	After=network-online.target

	[Service]
	#UMask=002
	Nice=-19
	LimitRTPRIO=infinity
	LimitMEMLOCK=infinity
	EnvironmentFile=${LCWA_ENVFILE}
	RuntimeDirectory=${LCWA_SERVICE}
	Type=simple
	User=${LCWA_USER}
	Group=${LCWA_GROUP}
	ExecStart=${LCWA_DAEMON} \$LCWA_OPTIONS
	RestartSec=5
	Restart=on-failure
	StandardOutput=append:${LCWA_LOGFILE}
	StandardError=append:${LCWA_ERRFILE}

	[Install]
	WantedBy=multi-user.target

	SYSTEMD_SCR1
	
	[ $DEBUG -gt 2 ] && debug_cat "$LUNIT_FILE"
	
	#~ systemd_uint_enable "${LCWA_SERVICE}.service"
	
	debug_pause "${LINENO} ${FUNCNAME}() done."

	return 0
}

lcwa_speed_update_timer_create(){
	debug_echo "${FUNCNAME}( $@ )"
	
	local LUPDATE_TIMER_NAME=
	local LUPDATE_TIMER_FILE=
	local LUPDATE_SERVICE_NAME=
	local LUPDATE_SERVICE_FILE=
	

	#~ LCWA_SUPREPO_LOCAL="/usr/local/share/lcwa-speed/speedtest-config"
	local LUPDATE_CMD="${LCWA_SUPREPO_LOCAL}/scripts/lcwa-speed-update.sh --debug"
	local LACTION=

	LUPDATE_TIMER_NAME="${LCWA_SERVICE}-update.timer"

	# Create the service file
	LUPDATE_SERVICE_NAME="${LCWA_SERVICE}-update.service"
	LUPDATE_SERVICE_FILE="/lib/systemd/system/${LUPDATE_SERVICE_NAME}"
	[ ! -f "$LUPDATE_SERVICE_FILE" ] && LACTION='Creating' || LACTION='Overwriting'
	
	[ $QUIET -lt 1 ] && error_echo "${LACTION} ${LUPDATE_SERVICE_FILE} service file.."
	
	[ $TEST -lt 1 ] && cat >"$LUPDATE_SERVICE_FILE" <<-EOF_TMRDEF1;
	## ${LUPDATE_SERVICE_FILE} -- $(date)
	## systemd service unit file

	[Unit]
	Description=Updates the ${LCWA_SERVICE} service.
	Wants=${LUPDATE_TIMER_NAME}

	[Service]
	Type=oneshot
	ExecStart=${LUPDATE_CMD}
	StandardError=append:${LCWA_LOGDIR}/${LCWA_SERVICE}-update.log

	[Install]
	WantedBy=multi-user.target	
	EOF_TMRDEF1
	
	if [ ! -f "$LUPDATE_SERVICE_FILE" ] && [ $TEST -lt 1 ]; then
		error_echo "${FUNCNAME}( $@ ): Error -- could not create ${LUPDATE_SERVICE_FILE} file."
		return 1
	else
		[ $TEST -lt 1 ] && chown root:root "$LUPDATE_SERVICE_FILE"
		[ $TEST -lt 1 ] && chmod 0644 "$LUPDATE_SERVICE_FILE"
	fi
	
	[ $DEBUG -gt 0 ] && debug_cat "$LUPDATE_SERVICE_FILE"	
	[ $DEBUG -gt 0 ] && debug_pause "${FUNCNAME}: ${LINENO}"

	# Create the timer file
	LUPDATE_TIMER_NAME="${LCWA_SERVICE}-update.timer"
	LUPDATE_TIMER_FILE="/lib/systemd/system/${LUPDATE_TIMER_NAME}"
	
	[ ! -f "$LUPDATE_TIMER_FILE" ] && LACTION='Creating' || LACTION='Overwriting'
	[ $QUIET -lt 1 ] && error_echo "${LACTION} ${LUPDATE_TIMER_FILE} timer file.."

	[ $TEST -lt 1 ] && cat >"$LUPDATE_TIMER_FILE" <<-EOF_TMRDEF2;
	## ${LUPDATE_TIMER_FILE} -- $(date)
	## systemd timer unit file

	[Unit]
	Description=Triggers the ${LUPDATE_SERVICE_NAME} at 00:05 daily, which runs the $(basename ${LCWA_UPDATE_SCRIPT}) script.
	Requires=${LUPDATE_SERVICE_NAME}

	[Timer]
	Unit=${LUPDATE_SERVICE_NAME}
	# See: https://silentlad.com/systemd-timers-oncalendar-(cron)-format-explained
	# Every day at 5 after midnight
	OnCalendar=*-*-* 00:05:00

	[Install]
	WantedBy=timers.target	
	EOF_TMRDEF2
	
	if [ ! -f "$LUPDATE_TIMER_FILE" ] && [ $TEST -lt 1 ]; then
		error_echo "${FUNCNAME}() error: could not create ${LUPDATE_TIMER_FILE} file."
		return 1
	else
		[ $TEST -lt 1 ] && chown root:root "$LUPDATE_TIMER_FILE"
		[ $TEST -lt 1 ] && chmod 0644 "$LUPDATE_TIMER_FILE"
	fi
	
	[ $DEBUG -gt 1 ] && debug_cat "$LUPDATE_TIMER_FILE"	
	[ $DEBUG -gt 1 ] && debug_pause "${FUNCNAME}: ${LINENO}"	

	# Enable the timer
	systemd_uint_enable "$LUPDATE_TIMER_NAME"
	
	debug_pause "${LINENO} ${FUNCNAME}() done."
	
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

lcwa_pppoe_provider_create(){
	debug_echo "${FUNCNAME}( $@ )"
	# Get the first linked interface with a 172.16. static ip..
	local LSTATIC_IFACE="$(iface_static_get)"
	local LPROVIDER_DIR='/etc/ppp/peers'
	local LPROVIDER_FILE="${LPROVIDER_DIR}/${LCWA_PPPOE_PROVIDER}"
	# Two more tries to get an interface name.
	[ -z "$LSTATIC_IFACE" ] && LSTATIC_IFACE="$(iface_primary_geta)"
	[ -z "$LSTATIC_IFACE" ] && LSTATIC_IFACE="$(ls -1 '/sys/class/net' | sort | grep -m1 -v -E '^lo$')"
	
	if [ -z "$LSTATIC_IFACE" ]; then
		error_echo "${SCRIPT_NAME} error: Could not find a linked network interface."
		return 1
	fi
	
	# Search for the provider name in the /etc/ppp/chap-secrets file
	LCWA_PPPOE_PROVIDER
	LCWA_PPPOE_PASSWORD
	
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
	user "${LCWA_PPPOE_PROVIDER}"
	usepeerdns
	EOF_PROVIDER
	
	# Create the /etc/ppp/chap-secrets
	local LSECRETS_FILE='/etc/ppp/chap-secrets'

	[ -f "$LSECRETS_FILE" ] && [ ! -f "${LSECRETS_FILE}.org" ] && cp -p "$LSECRETS_FILE" "${LSECRETS_FILE}.org"

	[ $QUIET -lt 1 ] && error_echo "Creating ${LSECRETS_FILE}.."

	[ $TEST -lt 1 ] && cat >"$LSECRETS_FILE" <<-EOF_SECRETS0;
	# $(date) -- ${LSECRETS_FILE}
	# Secrets for authentication using CHAP
	# client	server	secret			IP addresses

	"speedtest5a" "speedtest5a" "ocm68hv0"
	"speedtest20a" "speedtest20a" "ocm68hv0"
	"speedtest20b" "speedtest20b" "ocm68hv0"
	"speedtest20c" "speedtest20c" "ocm68hv0"
	"speedtest20d" "speedtest20d" "ocm68hv0"
	"speedtest20e" "speedtest20e" "ocm68hv0"
	"speedtest20f" "speedtest20f" "ocm68hv0"
	"speedtest20g" "speedtest20g" "ocm68hv0"
	
	EOF_SECRETS0
	
	# See if our provider & password are in the secrets file..if not, add it.
	if [ $(cat "$LSECRETS_FILE" | grep -E "^.*${LCWA_PPPOE_PROVIDER}.*${LCWA_PPPOE_PASSWORD}.*$") -lt 1 ]; then
		echo "\"${LCWA_PPPOE_PROVIDER}\" \"${LCWA_PPPOE_PROVIDER}\" \"${LCWA_PPPOE_PASSWORD}\"" >>"$LSECRETS_FILE"
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

	"speedtest5a" "speedtest5a" "ocm68hv0"
	"speedtest20a" "speedtest20a" "ocm68hv0"
	"speedtest20b" "speedtest20b" "ocm68hv0"
	"speedtest20c" "speedtest20c" "ocm68hv0"
	"speedtest20d" "speedtest20d" "ocm68hv0"
	"speedtest20e" "speedtest20e" "ocm68hv0"
	"speedtest20f" "speedtest20f" "ocm68hv0"
	"speedtest20g" "speedtest20g" "ocm68hv0"

	EOF_SECRETS1

	# create the /etc/ppp/resolv.conf file???
	# See if our provider & password are in the secrets file..if not, add it.
	if [ $(cat "$LSECRETS_FILE" | grep -E "^.*${LCWA_PPPOE_PROVIDER}.*${LCWA_PPPOE_PASSWORD}.*$") -lt 1 ]; then
		echo "\"${LCWA_PPPOE_PROVIDER}\" \"${LCWA_PPPOE_PROVIDER}\" \"${LCWA_PPPOE_PASSWORD}\"" >>"$LSECRETS_FILE"
	fi
	
	
}

lcwa_pppoe_connect_create(){
	debug_echo "${FUNCNAME}( $@ )"
	
	# create the /lib/systemd/system/pppoe-connect.service file
	local LPPPOE_SERVICE_NAME='pppoe-connect.service'
	local LPPPOE_SERVICE_FILE="/lib/systemd/system/${LPPPOE_SERVICE_NAME}"
	
	[ $QUIET -lt 1 ] && error_echo "Creating ${LPPPOE_SERVICE_NAME} for provider ${LCWA_PPPOE_PROVIDER}.."

	[ $TEST -lt 1 ] && cat >"$LPPPOE_SERVICE_FILE" <<-EOF_PPPOESRVC0;
	# $(date) -- ${LPPPOE_SERVICE_FILE}
	# Adapted from https://www.sherbers.de/diy-linux-router-part-3-pppoe-and-routing/

	[Unit]
	Description=PPPoE Connection Service
	After=network-online.target

	[Service]
	Type=exec
	EnvironmentFile=${LCWA_ENVFILE}
	ExecStart=/usr/sbin/pppd call \$LCWA_PPPOE_PROVIDER
	StandardOutput=append:${LCWA_LOGDIR}/pppoe-connect.log
	StandardError=append:${LCWA_LOGDIR}/pppoe-connect-error.log

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
		return 1
	else
		[ $TEST -lt 1 ] && chown root:root "$LPPPOE_SERVICE_FILE"
		[ $TEST -lt 1 ] && chmod 0644 "$LPPPOE_SERVICE_FILE"
	fi
	
	[ $DEBUG -gt 0 ] && debug_cat "$LPPPOE_SERVICE_FILE"	
	[ $DEBUG -gt 0 ] && debug_pause "${FUNCNAME}: ${LINENO}"
	
}


# This lists just the unit files that should be enabled / started
units_list_names(){
	UNITS_LIST=" \
	${LCWA_SERVICE}.service \
	${LCWA_SERVICE}-update.timer \
	pppoe-connect.service"
	
	echo "$UNITS_LIST" | xargs
}

# This lists ALL unit files created by this script
units_list_names_all(){
	UNITS_LIST=" \
	$(units_list_names) \
	${LCWA_SERVICE}-update.service"
	echo "$UNITS_LIST" | xargs
}


units_start(){
	debug_echo "${FUNCNAME}( $@ )"
	local LUNIT=
	
	systemctl daemon-reload && systemctl reset-failed
	
	for LUNIT in $(units_list_names)
	do
		systemd_uint_start "$LUNIT"
	done
}

units_stop(){
	debug_echo "${FUNCNAME}( $@ )"
	local LUNIT=
	
	for LUNIT in $(units_list_names)
	do
		systemd_uint_stop "$LUNIT"
	done
}

units_enable(){
	debug_echo "${FUNCNAME}( $@ )"
	local LUNIT=
	
	systemctl daemon-reload && systemctl reset-failed
	
	for LUNIT in $(units_list_names)
	do
		systemd_uint_enable "$LUNIT"
	done
}

units_disable(){
	debug_echo "${FUNCNAME}( $@ )"
	local LUNIT=
	
	for LUNIT in $(units_list_names)
	do
		systemd_uint_disable "$LUNIT"
	done
}

units_remove(){
	debug_echo "${FUNCNAME}( $@ )"
	local LUNIT=
	
	for LUNIT in $(units_list_names_all)
	do
		systemd_unit_remove "$LUNIT"
	done
	
	systemctl daemon-reload && systemctl reset-failed
}

units_status(){
	debug_echo "${FUNCNAME}( $@ )"
	local LUNIT=

	[ $DEBUG -gt 1 ] && units_list_names
	
	for LUNIT in $(units_list_names)
	do
		debug_echo "Getting status of ${LUNIT}"
		systemctl -l --no-pager status "$LUNIT"
		debug_pause "Done with ${LUNIT}"
	done
}


# Remove old crontab entries
crontab_entry_remove(){
	debug_echo "${FUNCNAME}( $@ )"
	local ROOTCRONTAB='/var/spool/cron/crontabs/root'
	local COMMENT=
	local EVENT=

	[ ! -f "$ROOTCRONTAB" ] && return 0
	
	[ $QUIET -lt 1 ] && error_echo "Removing old crontab entries from ${ROOTCRONTAB}"
	
	# Remove any entry for the proc-net-dev.sh logger
	COMMENT='#At the top of every hour, log our net stats for the ppp0 interface'
	EVENT='0 * * * * /usr/local/sbin/log-proc-net-dev.sh | /usr/bin/logger -t lcwa-netstats'
	[ $QUIET -lt 1 ] && error_echo "Removing ${EVENT} from ${ROOTCRONTAB}"
	sed -i '/^#.*top of every hour.*$/d' "$ROOTCRONTAB" >/dev/null 2>&1
	sed -i '/^.*log-proc-net-dev.*$/d' "$ROOTCRONTAB" >/dev/null 2>&1

	COMMENT='#Everyday, at 5 minutes past midnight, update lcwa-speed and restart the service:'
	EVENT='5 0 * * * /usr/local/share/config-lcwa-speed/scripts/lcwa-speed-update.sh --debug | /usr/bin/logger -t lcwa-speed'
	[ $QUIET -lt 1 ] && error_echo "Removing ${EVENT} from ${ROOTCRONTAB}"
	sed -i '/^#.*at 5 minutes past midnight.*$/d' "$ROOTCRONTAB" >/dev/null 2>&1
	sed -i '/^.*lcwa-speed-update.*$/d' "$ROOTCRONTAB" >/dev/null 2>&1
	
	COMMENT='#At every 10th minute, check the lcwa20a PPPoE connecton and reestablish it if down.'
	EVENT='*/10 * * * * /usr/local/sbin/chkppp.sh | /usr/bin/logger -t lcwa-pppchk'
	[ $QUIET -lt 1 ] && error_echo "Removing ${EVENT} from ${ROOTCRONTAB}"
	sed -i '/^#.*every 10th minute.*$/d' "$ROOTCRONTAB" >/dev/null 2>&1
	sed -i '/^.*chkppp.*$/d' "$ROOTCRONTAB" >/dev/null 2>&1

	# signal crond to reload the file
	sudo touch /var/spool/cron/crontabs

	# Make the entry stick
	[ $QUIET -lt 1 ] && error_echo "Restarting root crontab.."
	systemctl restart cron

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

# Declare our environmental variables and zero them..
env_vars_zero $(env_vars_name)

SHORTARGS='hdqvftlr'

LONGARGS="help,
debug,
quiet,
verbose,
test,
force,
clean,
update,
list,
start,stop,
enable,disable,
status,
remove,
uninstall,
inst-name:,
service-name:,
pppoe::,
env-file:"

# Remove line-feeds..
LONGARGS="$(echo "$LONGARGS" | sed ':a;N;$!ba;s/\n//g')"

ARGS=$(getopt -o "$SHORTARGS" -l "$LONGARGS"  -n "$(basename $0)" -- $@)

if [ $? -gt 0 ] && [ $ALLOW_BADARGS -lt 1 ]; then
	error_echo "ARGS == ${ARGS}"
	error_echo "   @ == $@"
	for ARG in $@
	do
		error_echo "   ${ARG}"
	done
	pause 'press any key to continue..'
	#~ disp_help "$SCRIPT_DESC"
	#~ exit 1
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
		-t|--test)				# Tests script logic without performing actions.
			((TEST+=1))
			;;
		-l|--list)				# Lists all the services and timers created by this script.
			ACTION=list
			;;
		--start)				# Starts the enabled services and timers
			ACTION=start
			;;
		--stop)					# Stops the running services and timers
			ACTION=stop
			;;
		--enable)				# Enables the configured services and timers
			ACTION=enable
			;;
		--disable)				# Disables the configured services and timers
			ACTION=disable
			;;
		--status)				# Lists the status of the services and timers created by this script
			ACTION=status
			;;
		-r|--remove|--uninstall) 	# Disables and removes the lcwa-speed services and timers
			UNINSTALL=1
			;;
		--inst-name)			# =NAME -- Instance name that defines the install location: /usr/local/share/NAME and user account name -- defaults to lcwa-speed.
			shift
			INST_INSTANCE_NAME="$1"
			LCWA_INSTANCE="$(basename "$INST_INSTANCE_NAME")"
			INST_NAME="$LCWA_INSTANCE"
			;;
		--service-name)				# =NAME -- Defines the name of the service: /lib/systemd/system/NAME.service -- defaults to lcwa-speed.
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

if [ ! -z "$LCWA_ENVFILE" ]; then
	[ $VERBOSE -gt 0 ] && error_echo "Getting instance information from ${LCWA_ENVFILE}."
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
	# Write the env-file if it doesn't exist..
	[ ! -f "$LCWA_ENVFILE" ] && env_file_create "$LCWA_SERVICE" $(env_vars_name)	
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


if [ ! -z "$ACTION" ]; then
	case "$ACTION" in
		list)
			error_echo "Unit files created by this script:"
			for UNIT in $(units_list_names_all)
			do
				[ -f "/lib/systemd/system/${UNIT}" ] && echo -e "\\t*INSTALLED*\\t${UNIT}" 1>&2 || echo -e "\\t\\t\\t${UNIT}" 1>&2 
				#~ error_echo "    ${UNIT}"
			done
			;;
		start)
			units_start
			;;
		stop)
			units_stop
			;;
		enable)
			units_enable
			;;
		disable)
			units_disable
			;;
		status)
			units_status
			;;
	esac
	exit 0
fi

if [ $UNINSTALL -gt 0 ]; then

	# Stop, disable and remove the all systemd unit files (services, timers)
	# created by this script.
	units_remove
	
	systemctl daemon-reload && systemctl reset-failed
	
else
	# Install or update..
	
	# Stop & disable our services & timers
	units_stop
	units_disable

	# Create & enable the lcwa-speed.service
	lcwa_speed_unit_file_create
	
	# Create & enable the lcwa-speed-update.service & timer
	lcwa_speed_update_timer_create
	
	# Detect if a ppp net interface is configured & create keep-alive timers
	if [ $LCWA_PPPOE_INSTALL -gt 0 ] || ppp_detect || ppp_link_is_up; then
		# Create a /etc/ppp/peers/provider file
		lcwa_pppoe_provider_create
		# Create the pppoe-connect.service
		lcwa_pppoe_connect_create
	fi
	
	# Get rid of old crontab entries
	crontab_entry_remove

	# Enable our services and timers
	units_enable
	
	# Start the services & timers
	[ $NO_START -lt 1 ] && units_start

fi

[ $QUIET -lt 1 ] && error_echo "${SCRIPT_NAME} done."

