#!/bin/bash

######################################################################################################
# Bash include script for generically installing services on upstart, systemd & sysv systems
# 20220207 -- Gordon Harris
######################################################################################################
INCSCRIPT_VERSION=20220306.190515
SCRIPTNAME=$(basename "$0")

# Get the underlying user...i.e. who called sudo..
UUSER="$(logname 2>/dev/null)"
[ -z "$UUSER" ] && UUSER="$(who am i | awk '{print $1}')"
[ -z "$UUSER" ] && [ "$(tty)" != 'not a tty' ] && UUSER="$(ls -l $(tty) | awk '{print $3}')"
[ -z "$UUSER" ] && UUSER="$(awk -F':' '{ if($7 ~ /\/bin\/bash/ && $1 !~ /root/) {print $1; exit} };0' /etc/passwd)"


NOPROMPT=0
QUIET=0
VERBOSE=0
DEBUG=0
TEST=0
UPDATE=0
UNINSTALL=0
REMOVEALL=0
FORCE=0

DISABLE=0
ENABLE=0
UPDATE=0
UNINSTALL=0

# Defaults..should be overridden in calling script
NEEDSPID=0
NEEDSUSER=0
NEEDSDATA=0
NEEDSLOG=0
NEEDSCONF=0
NEEDSPRIORITY=0

USE_UPSTART=0
USE_SYSTEMD=0
USE_SYSV=1

USE_APT=0
USE_YUM=0

######################################################################################################
# Identify system type, init type, update utility, firewall utility, network config system..
######################################################################################################

#~ IS_DEBIAN="$(which apt-get 2>/dev/null | wc -l)"
#~ IS_FEDORA="$(hostnamectl status | grep -c 'Fedora')"
# The following works for debian, ubuntu, raspbian
IS_DEBIAN="$(grep -c -e '^ID.*=.*debian' /etc/os-release)"
# The following ought to work for fedora, centos, etc.
IS_FEDORA="$(grep -c -e '^ID.*=.*fedora' /etc/os-release)"

if [ -f /etc/debian_version ]; then
	IS_DEB=1
	USE_APT=1
	IS_RPM=0
	USE_YUM=0
	IS_MAC=0
else
	IS_DEB=0
	USE_APT=0
	IS_RPM=1
	USE_YUM=1
	IS_MAC=0
fi

if [[ $OSTYPE == 'darwin'* ]]; then
	IS_MAC=1
	IS_DEB=0
	USE_APT=0
	IS_RPM=0
	USE_YUM=0
fi


IS_FOCAL=0
if [ $IS_DEBIAN -gt 0 ]; then
	IS_FOCAL="$(lsb_release -a 2>/dev/null | grep -c 'focal')"
fi

IS_UPSTART=$(initctl version 2>/dev/null | grep -c 'upstart')
IS_SYSTEMD=$(systemctl --version 2>/dev/null | grep -c 'systemd')


# Network service type
IS_NETPLAN="$(which netplan 2>/dev/null | wc -l)"
IS_DHCPCD=$(( systemctl is-enabled --quiet 'dhcpcd' 2>/dev/null ) && echo 1 || echo 0)
if [[ $IS_DHCPCD -gt 0 ]] && [[ $IS_SYSTEMD -gt 0 ]]; then
	systemctl is-active --quiet dhcpcd.service
	[ $? -eq 0 ] && IS_DHCPCD=1 || IS_DHCPCD=0
fi

# Network renderer
IS_NETWORKD=$(( systemctl is-enabled --quiet 'systemd-networkd' 2>/dev/null ) && echo 1 || echo 0)
IS_NETWORKMNGR=$(( systemctl is-enabled --quiet 'NetworkManager' 2>/dev/null ) && echo 1 || echo 0)

# Firewall font-end
USE_UFW=$(( systemctl is-enabled --quiet 'ufw' 2>/dev/null ) && echo 1 || echo 0)
USE_FIREWALLD=$(( systemctl is-enabled --quiet 'firewalld' 2>/dev/null ) && echo 1 || echo 0)

# Gui?
HAS_GUI=$(ls -l /usr/bin/gnome* 2>/dev/null | wc -l)
IS_GUI=$(systemctl get-default | grep -c 'graphical')
IS_TEXT=$(systemctl get-default | grep -c 'multi-user')


# Identify the init system
# Prefer upstart to systemd if both are installed..

if [ $(ps -eaf | grep -c [u]pstart) -gt 1 ]; then
	USE_UPSTART=1
	USE_SYSTEMD=0
	USE_SYSV=0
elif [ $(ps -eaf | grep -c [s]ystemd) -gt 2 ]; then
	USE_UPSTART=0
	USE_SYSTEMD=1
	USE_SYSV=0
else
	USE_UPSTART=0
	USE_SYSTEMD=0
	USE_SYSV=1
fi


######################################################################################################
# Variables for fetching scripts to fetch/install from scserver to this machine.
######################################################################################################
SCSERVER='scserver'
SCSERVER_IP='192.168.0.198'
PING_BIN="$(which ping)"
PING_OPTS='-c 1 -w 5'


######################################################################################################
# Vars: the calling script must define at least define INST_NAME & INST_BIN
######################################################################################################

INST_NAME=
INST_PROD=
INST_DESC=

INST_BIN=
INST_PID=
INST_PIDDIR=
INST_CONF=
INST_NICE=
INST_RTPRIO=
INST_MEMLOCK=

INST_USER=
INST_GROUP=
INST_ENVFILE=
INST_ENVFILE_LOCK=0

INST_DATADIR=
INST_DATAFILE=
INST_LOGDIR=
INST_LOGFILE=

INST_IFACE=
INST_SUBNET=
INST_FWZONE=

HOSTNAME=$(hostname | tr [a-z] [A-Z])

######################################################################################################
# is_root() -- make sure we're running with suficient credentials..
######################################################################################################
function is_root(){
	if [ $(whoami) != 'root' ]; then
		echo '################################################################################'
		echo -e "\nError: ${SCRIPTNAME} needs to be run with root cridentials, either via:\n\n# sudo ${0}\n\nor under su.\n"
		echo '################################################################################'
		exit 1
	fi
}

######################################################################################################
# psgrep() -- get info on a process grepping via a regular expression..
######################################################################################################
function psgrep(){
    ps aux | grep -v grep | grep -E $*
}


######################################################################################################
# timezone_get() -- Use the api.ipgeolocation.io website to get the local timezone..
######################################################################################################
function timezone_get(){
	#~ local LMY_APIKEY='60aca0cf9d45428e9ee1e27a63bbb329'
	#~ local LMYTZ="$(curl --silent "https://api.ipgeolocation.io/timezone?apiKey=${LMY_APIKEY}" | sed -n -e 's/^.*"timezone":"\([^\s]\+\/[^\s]\+\)",.*$/\1/p')"

	# 4 Different methods of getting a time zone..
	local LMYTZ=
	local LCMD=
	local LCMD1="LMYTZ=\$(curl --silent \"https://ipapi.co/timezone\" 2>/dev/null)"
	local LCMD3="LMYTZ=\$(curl --silent \"http://ip-api.com/line/?fields=256\" 2>/dev/null)"
	local LCMD3="LMYTZ=\$(curl --silent \"https://freegeoip.app/json/\"  2>/dev/null | sed -n -e 's/^.*\"time_zone\":\"\([^\s]\+\/[^\s]\+\)\",.*$/\1/p')"
	local LCMD4="LMYTZ=\$(curl --silent \"http://worldtimeapi.org/api/ip/\"  2>/dev/null | sed -n -e 's/^.*\"timezone\":\"\([^\s]\+\/[^\s]\+\)\",\"unixtime\".*$/\1/p')"
	
	for LCMD in "$LCMD1" "$LCMD2" "$LCMD3" "$LCMD4"
	do
		eval "$LCMD"

		# Does this look like a timezone?
		if [ $(echo $LMYTZ | grep -c -E '^\S+/\S+$') -gt 0 ]; then
			echo "$LMYTZ"
			return 0
		fi
	
	done

	return 1
}

######################################################################################################
# timestamp_get_iso8601() -- Get a second granularity local TZ timestamp in ISO-8601 format..
######################################################################################################
function timestamp_get_iso8601(){
	echo "$(date --iso-8601=s)"
}

######################################################################################################
# timestamp_get_iso8601u() -- Get a second granularity UTC timestamp in ISO-8601 format..
######################################################################################################
timestamp_get_iso8601u(){
	echo "$(date -u --iso-8601=s)"
}

######################################################################################################
# timestamp_get_epoch() -- Get a second granularity epoch timestamp..
######################################################################################################
timestamp_get_epoch(){
	echo "$(date +%s)"
}

######################################################################################################
# date_iso8601_to_epoch() -- Convert a ISO-8601 timestamp to epoch time..
######################################################################################################
date_iso8601_to_epoch(){
	local LISO="$1"
	echo "$(date "-d${LISO}" +%s)"
}

######################################################################################################
# date_epoch_to_iso8601() -- Convert an epoch time to ISO-8601 format in local TZ..
######################################################################################################
date_epoch_to_iso8601(){
	local LEPOCH="$1"
	echo "$(date -d "@${LEPOCH}" --iso-8601=s)"
}

######################################################################################################
# date_epoch_to_iso8601u() -- Convert an epoch time to ISO-8601 format in UTC..
######################################################################################################
date_epoch_to_iso8601u(){
	local LEPOCH="$1"
	echo "$(date -u -d "@${LEPOCH}" --iso-8601=s)"
}

error_log(){
	echo "${SCRIPT} $(timestamp_get_iso8601) " "$@" >>"$INST_LOGFILE"
}

######################################################################################################
# error_echo() -- echo a message to stderr
######################################################################################################
error_echo(){
	echo "$@" 1>&2;
}

######################################################################################################
# debug_echo() -- echo a debugging message to stderr
######################################################################################################
debug_echo(){
	[ $DEBUG -gt 0 ] && echo "$@" 1>&2;
}

######################################################################################################
# error_exit() -- echo a message to stderr and exit with an errorlevel
######################################################################################################
error_exit(){
    error_echo "Error: $@"
    exit 1
}

######################################################################################################
# pause() -- echo a prompt and then wait for keypress
######################################################################################################
pause(){
	read -p "$*"
}

######################################################################################################
# debug_pause() -- Pauses execution if DEBUG > 1 && NO_PAUSE < 1  debug_pause "${FUNCNAME}: ${LINENO}"
######################################################################################################
debug_pause(){
	[ $DEBUG -gt 0 ] && echo "Debug check at line ${1}:  " 1>&2;
	[ $DEBUG -gt 1 ] && [ $NO_PAUSE -lt 1 ] && pause 'Press Enter to continue, or ctrl-c to abort..'
}

######################################################################################################
# debug_cat() -- cats a file to stderr 
######################################################################################################
debug_cat(){
	[ $DEBUG -lt 1 ] && return
	local LFILE="$1"
	if [ -f "$LFILE" ]; then
		error_echo ' '
		error_echo '================================================================================='
		error_echo "${LFILE} contents:"
		error_echo '================================================================================='
		cat "$LFILE" 1>&2;
		error_echo '================================================================================='
		error_echo ' '
	fi
}

########################################################################
# disp_help() -- display the getopts allowable args
########################################################################
disp_help(){
	local LSCRIPTNAME="$(basename "$0")"
	local LDESCRIPTION="$1"
	local LEXTRA_ARGS="${@:2}"
	error_echo  -e "\n${LSCRIPTNAME}: ${LDESCRIPTION}\n"
	error_echo -e "Syntax: ${LSCRIPTNAME} ${LEXTRA_ARGS}\n"
	error_echo "            Optional parameters:"
	# See: https://gist.github.com/sv99/6852cc2e2a09bd3a68ed for explaination of the sed newling replacement
	cat "$(readlink -f "$0")" | grep -E '^\s+-' | grep -v -- '--)' | sed -e 's/)//' -e 's/#/\n\t\t\t\t#/' | fmt -t -s | sed ':a;N;$!ba;s/\n\s\+\(#\)/\t\1/g' 1>&2
	error_echo ' '
}

######################################################################################################
# service_inst_prep() -- Set most of the INST_ variables based on $INST_NAME
######################################################################################################
service_inst_prep(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	if [ -z "$INST_NAME" ]; then
		error_exit "INST_NAME undefined."
	fi

	[ -z "$INST_PROD" ] && INST_PROD=$(echo "$INST_NAME" | tr [a-z] [A-Z])
	[ -z "$INST_DESC" ] && INST_DESC="${INST_PROD} service daemon"
	if [ -z "$INST_BIN" ]; then
		# Try tacking on a 'd'
		INST_BIN=$(which "${INST_NAME}d")
		if [ ! -x "$INST_BIN" ]; then
			# Try just the name..
			INST_BIN=$(which "${INST_NAME}")
			if [ ! -x "$INST_BIN" ]; then
				# Try removing the 'd'
				INST_BIN=$(which "${INST_NAME%d}")
				if [ ! -x "$INST_BIN" ]; then
					# Punt!
					INST_BIN="/usr/local/bin/${INST_NAME}"
				fi
			fi
		fi
	fi
	[ -z "$INST_PIDDIR" ] && INST_PIDDIR="/var/run/${INST_NAME}"
	[ -z "$INST_PID" ] && INST_PID="${INST_PIDDIR}/${INST_NAME}.pid"
	[ -z "$INST_CONF" ] && INST_CONF="/etc/${INST_NAME}/${INST_NAME}.conf"
	[ -z "$INST_USER" ] && inst_user_create
	# [ -z "$INST_GROUP" ] &&
	if [ -z "$INST_ENVFILE" ]; then
		if [ $IS_DEBIAN -gt 0 ]; then
			INST_ENVFILE="/etc/default/${INST_NAME}"
		else
			INST_ENVFILE="/etc/sysconfig/${INST_NAME}"
		fi
	fi
	[ -z "$INST_DATADIR" ] && INST_DATADIR="/var/lib/${INST_NAME}"
	[ -z "$INST_LOGDIR" ] && INST_LOGDIR="/var/lib/${INST_NAME}"
	[ -z "$INST_LOGFILE" ] && INST_LOGFILE="${INST_LOGDIR}/${INST_NAME}.log"

}

############################################################################
# sudo_user_get() -- Returns the name of the user calling sudo or sudo su
############################################################################
sudo_user_get(){
	who am i | sed -n -e 's/^\([[:alnum:]]*\)\s*.*$/\1/p'
}

######################################################################################################
# is_user() -- Check to see if a username exists..
######################################################################################################
is_user(){
	id -u "$1" >/dev/null 2>&1
	return $?
}

######################################################################################################
# inst_user_create() Find or create the user account the service will run under.
######################################################################################################
inst_user_create(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LINST_USER="${1:-${INST_USER}}"
	local LINST_GROUP="$INST_GROUP"


	# If we don't need a user, our user will be root..
	if [ $NEEDSUSER -lt 1 ]; then
		if [ -z "$INST_USER" ]; then
			INST_USER='root'
		    INST_GROUP="$(id -ng "$INST_USER")"
		fi
		return 0
	fi


	# If not specific username, then name after the service..
    if [ -z "$LINST_USER" ]; then
		LINST_USER="$INST_NAME"
	fi

    # If still no INST_USER, get the underlying user account..
    if [ -z "$LINST_USER" ]; then

        LINST_USER=$(who am i | sed -n -e 's/^\([[:alnum:]]*\)\s*.*$/\1/p')
        if [ "$LINST_USER" = 'root' ]; then
            #get the 1st user name with a bash shell who is not root..
            LINST_USER=$(awk -F':' '{ if($7 ~ /\/bin\/bash/ && $1 !~ /root/) {print $1; exit} };0' /etc/passwd)
        fi
        # punt!
        if [ -z "$LINST_USER" ]; then
            LINST_USER=$(whoami)
        fi
    fi

	# Check the id of the INST_USER..
	# If no such user, create the user as a system user..
	
	id -u "$LINST_USER" >/dev/null 2>&1
	
	if [[ ! $? -eq 0 ]]; then
	
		if [ $IS_DEBIAN -gt 0 ]; then
		
			if [ ! -z "$LINST_GROUP" ]; then
				# If the group exists..
				if [ $(grep -c "$INST_GROUP" /etc/group) -lt 1 ]; then
					if [ "$LINST_GROUP" = "$LINST_USER" ]; then
						adduser --system --no-create-home  --group --gecos "${INST_PROD} user account" "$LINST_USER"
					else
						addgroup --system "$LINST_GROUP"
						adduser --system --no-create-home  --ingroup "$LINST_GROUP" --gecos "${INST_PROD} user account" "$LINST_USER"
					fi
				else
					adduser --system --no-create-home  --ingroup "$LINST_GROUP" --gecos "${INST_PROD} user account" "$LINST_USER"
				fi
			else
				adduser --system --no-create-home --gecos "${INST_PROD} user account" "$LINST_USER"
			fi
		else
			useradd --user-group --no-create-home --system --shell /sbin/nologin  "$LINST_USER"
		fi
	fi

	INST_USER="$LINST_USER"
    INST_GROUP=$(id -ng $LINST_USER)

    echo "${INST_NAME} service account set to ${LINST_USER}:${LINST_GROUP}"
}

######################################################################################################
# inst_user_remove() Delete the user account..
######################################################################################################
inst_user_remove(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LINST_USER="${1:-${INST_USER}}"
	local LINST_GROUP="$INST_GROUP"

	# Don't delete root
	debug_echo "inst_user_remove: LINST_USER == ${LINST_USER}"
	if [[ -z "$LINST_USER" ]] || [[ "$LINST_USER" = 'root' ]]; then
		return 1
	fi

	# Don't delete a user with a real login account
	if [ $(cat /etc/passwd | grep -E "^${LINST_USER}:.*$" | grep -c -E '/nologin|/false'	) -lt 1 ]; then
		return 1
	fi

	# Remove the user account if it exists..
	id "$LINST_USER" >/dev/null 2>&1
	if [ $? -eq 0 ]; then

		error_echo "Removing ${LINST_USER} user account.."
		LINST_GROUP="$(id -ng "$LINST_USER")"

		if [ $IS_DEBIAN -gt 0  ]; then
			userdel -r $LINST_USER >/dev/null 2>&1
		else
		  /usr/sbin/userdel -r -f "$LINST_USER" >/dev/null 2>&1
		  /usr/sbin/groupdel "$LINST_GROUP" >/dev/null 2>&1
		fi
	fi

}

######################################################################################################
# home_dir_create( dir ) Create the service home dir (usually parent of data_dir
######################################################################################################
home_dir_create(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LINST_HOMEDIR="${1:-/var/lib/${INST_NAME}}"

    if [ $NEEDSHOME -lt 0 ]; then
		return 1
	fi

	if [ -z "$INST_USER" ]; then
		inst_user_create
	fi

	if [ ! -d "$LINST_HOMEDIR" ];then
		error_echo "Creating ${LINST_HOMEDIR}.."
		mkdir -p "$LINST_HOMEDIR"
	fi

	chown -R "${INST_USER}:${INST_GROUP}" "$LINST_HOMEDIR"
	chmod 1754 "$LINST_HOMEDIR"

	if [ ! -d "$LINST_HOMEDIR" ]; then
		error_echo "Error: could not create ${LINST_HOMEDIR} home directory.."
		return 1
	fi

}

home_dir_update(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LINST_HOMEDIR="${1:-/var/lib/${INST_NAME}}"
	home_dir_create "$LINST_HOMEDIR"
}

######################################################################################################
# home_dir_remove( dir ) Removes the service home dir (usually parent of data_dir
######################################################################################################
home_dir_remove(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LINST_HOMEDIR="${1:-/var/lib/${INST_NAME}}"

    if [ $NEEDSHOME -lt 0 ]; then
		return 1
	fi

	if [ -d "$LINST_HOMEDIR" ];then
		error_echo "Removing ${LINST_HOMEDIR}.."
		rm -Rf "$LINST_HOMEDIR"
	fi

	if [ -d "$LINST_HOMEDIR" ]; then
		error_echo "Error: could not remove ${LINST_HOMEDIR} home directory.."
		return 1
	fi

}



######################################################################################################
# create_data_dir( dir, file ) Create the service data dir..
######################################################################################################
data_dir_create(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LINST_DATADIR="${1:-/var/lib/${INST_NAME}}"
	local LINST_DATAFILE="$2"

    if [ $NEEDSDATA -lt 0 ]; then
		return 1
	fi

	if [ -z "$INST_USER" ]; then
		inst_user_create
	fi

	#~ # Create the service data directory..
	#~ [ -z "$INST_DATADIR" ] && INST_DATADIR="/var/lib/${INST_NAME}"

	if [ ! -d "$LINST_DATADIR" ];then
		error_echo "Creating ${LINST_DATADIR}.."
		mkdir -p "$LINST_DATADIR"
	fi

	if [ ! -z "$LINST_DATAFILE" ]; then
		#~ echo "# ${INST_NAME} data file -- $(date)" > "$INST_DATAFILE"
		touch "$LINST_DATAFILE"
	fi

	chown -R "${INST_USER}:${INST_GROUP}" "$LINST_DATADIR"
	chmod 1754 "$LINST_DATADIR"

	if [ ! -d "$LINST_DATADIR" ]; then
		error_echo "Error: could not update ${LINST_DATADIR} data directory.."
		return 1
	fi

}

######################################################################################################
# data_dir_remove() Remove the service data dir..
######################################################################################################
data_dir_remove(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LINST_DATADIR="${1:-/var/lib/${INST_NAME}}"

    if [ $NEEDSDATA -lt 0 ]; then
		return 1
	fi

	#~ [ -z "$LINST_DATADIR" ] && INST_DATADIR="/var/lib/${INST_NAME}"

	if [ -d "$LINST_DATADIR" ]; then
		error_echo "Removing ${LINST_DATADIR} data directory.."
		rm -Rf "LINST_DATADIR"
	fi

}

######################################################################################################
# data_dir_update() Update the service data dir..
######################################################################################################
data_dir_update(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LINST_DATADIR="${1:-/var/lib/${INST_NAME}}"

	data_dir_create "$LINST_DATADIR"

}

######################################################################################################
# create_log_dir() Create the service log dir..
######################################################################################################
log_dir_create(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LINST_LOGDIR="${1:-/var/log/${INST_NAME}}"
	local LINST_LOGFILE="${2:-${LINST_LOGDIR}/${INST_NAME}.log}"

	if [ $NEEDSLOG -lt 1 ]; then
		return 1
	fi

	if [ -z "$INST_USER" ]; then
		inst_user_create
	fi

	# Create the service log dir & file..

	#~ [ -z "$INST_LOGDIR" ] && INST_LOGDIR="/var/log/${INST_NAME}"

	if [ ! -d "$LINST_LOGDIR" ];then
		error_echo "Creating ${LINST_LOGDIR}.."
		mkdir -p "$LINST_LOGDIR"
	fi

	chown "${INST_USER}:${INST_GROUP}" "$LINST_LOGDIR"
	chmod 1754 "$LINST_LOGDIR"

	#~ [ -z "$INST_LOGFILE" ] && INST_LOGFILE="${INST_LOGDIR}/${INST_NAME}.log"
	echo "Creating ${LINST_LOGFILE}.."

	date > "$LINST_LOGFILE"

	chown "${INST_USER}:${INST_GROUP}" "$LINST_LOGFILE"
	chmod 644 "$LINST_LOGFILE"

    return 0
}

######################################################################################################
# log_dir_update() Update the service log dir..
######################################################################################################
log_dir_update(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LINST_LOGDIR="${1:-/var/log/${INST_NAME}}"
	local LINST_LOGFILE="${2:-${LINST_LOGDIR}/${INST_NAME}.log}"
	log_dir_create "$LINST_LOGDIR" "$LINST_LOGFILE"
}

######################################################################################################
# log_dir_remove() Update the service log dir..
######################################################################################################
log_dir_remove(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LINST_LOGDIR="${1:-/var/log/${INST_NAME}}"

	#~ [ -z "$INST_LOGDIR" ] && INST_LOGDIR="/var/log/${INST_NAME}"

	if [ -d "$LINST_LOGDIR" ]; then
		error_echo "Removing ${LINST_LOGDIR} log directory.."
		rm -Rf "$LINST_LOGDIR"
	fi

}

######################################################################################################
# log_rotate_script_create() Create the log rotate script..
# LOG_DIR="/var/log/${INST_NAME}"
# LOG_FILE="${LOG_DIR}/${INST_NAME}.log"
# log_rotate_script_create "$LOG_FILE"
######################################################################################################
log_rotate_script_create(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"

	local LLOG_FILE="${1:-/var/log/${INST_NAME}/${INST_NAME}.log}"
	local LLOG_FILE_WILD="$(dirname "$LLOG_FILE")/*.log"
	local LESC_LOG_FILE=
	local LLOG_ROTATE_COUNT="$2"
	local LBASENAME="$(basename "$LLOG_FILE")"
	
	# Escape slashes & wildcards..
	LESC_LOG_FILE="${LLOG_FILE////\\/}"
	LESC_LOG_FILE="${LESC_LOG_FILE//./\\.}"
	LESC_LOG_FILE="${LESC_LOG_FILE//\*/\\*}"

	# Wildcards in the logfile spec?
	if [ $(echo "$LLOG_FILE" | grep -c '*') -gt 0 ]; then
		LBASENAME="$(basename "$(dirname "$LLOG_FILE")")"
	else
		LBASENAME="$(basename "$LLOG_FILE")"
	fi

	if [ -z "$LLOG_FILE" ]; then
		LLOG_FILE="/var/log/${INST_NAME}/${INST_NAME}.log"
	fi

	if [ -z "$LLOG_ROTATE_COUNT" ]; then
		LLOG_ROTATE_COUNT='5'
	fi

	INSTPATH="/etc/logrotate.d"

	if [ ! -d "$INSTPATH" ]; then
		mkdir -p "$INSTPATH"
	fi

	LBASENAME="${LBASENAME%%.*}"

	LOG_ROTATE_SCRIPT="${INSTPATH}/${LBASENAME}"


	#~ /var/log/squeezelite/squeezelite.log {
		#~ missingok
		#~ weekly
		#~ notifempty
		#~ compress
		#~ rotate 5
		#~ size 20k
	#~ }

	if [ -f "$LOG_ROTATE_SCRIPT" ]; then
		error_echo "Updating log rotate script ${LOG_ROTATE_SCRIPT}."
		# Delete any existing entry for this log
		sed -i "/${LESC_LOG_FILE}/,/}/d" "$LOG_ROTATE_SCRIPT"
	
		# Don't add log entries to rotate scripts that already contain wildcards, e.g.:
		# /var/log/lighttpd/*.log {

		if [ $(grep --fixed-strings -c "$LLOG_FILE_WILD" "$LOG_ROTATE_SCRIPT") -gt 0 ]; then
			error_echo "${LOG_ROTATE_SCRIPT} already contains wildcards.  Not adding to the script."
			return 0
		fi
	else
		error_echo "Creating log rotate script ${LOG_ROTATE_SCRIPT}."
	fi

	cat >>"$LOG_ROTATE_SCRIPT" <<LOGROTATESCR;
${LLOG_FILE} {
    missingok
    weekly
    notifempty
    compress
    rotate ${LLOG_ROTATE_COUNT}
    size 20k
}

LOGROTATESCR

}

######################################################################################################
# log_rotate_script_remove() Remove the log rotate script..
######################################################################################################
log_rotate_script_remove(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LLOG_FILE="$1"

	if [ -z "$LLOG_FILE" ]; then
		LLOG_FILE="/var/log/${INST_NAME}/${INST_NAME}.log"
	fi

	local LBASENAME="$(basename "$LLOG_FILE")"
	LBASENAME="${LBASENAME%%.*}"

	INSTPATH="/etc/logrotate.d"

	LOG_ROTATE_SCRIPT="${INSTPATH}/${LBASENAME}"

	if [ -f "$LOG_ROTATE_SCRIPT" ]; then
		error_echo "Removing ${LOG_ROTATE_SCRIPT} log rotate script.."
		rm -f "$LOG_ROTATE_SCRIPT"
	else
		error_echo "${LOG_ROTATE_SCRIPT} log rotate script not found."
	fi

}

######################################################################################################
# pid_dir_create() Create a location for the process ID PID file..
######################################################################################################
pid_dir_create(){

	if [ $USE_SYSTEMD -gt 0 ]; then
		if [ $# -gt 1 ]; then
			systemd_tmpfilesd_conf_create $@
		else
			systemd_tmpfilesd_conf_create 'd' "$INST_NAME" '0750' "$INST_USER" "$INST_GROUP" '10d'
		fi

	else
		[ -z "$INST_PIDDIR" ] && INST_PIDDIR="/var/run/${INST_NAME}"
		[ -z "$INST_PID" ] && INST_PID="${INST_PIDDIR}/${INST_NAME}.pid"

		if [ ! -d "$INST_PIDDIR" ]; then
			error_echo "Creating ${INST_PIDDIR}.."
			mkdir -p "$INST_PIDDIR"
			touch "$INST_PID"
		fi

		chown -R "${INST_USER}:${INST_GROUP}" "$INST_PIDDIR"
	fi

}

######################################################################################################
# pid_dir_remove() Remove a location for the process ID PID file..
######################################################################################################
pid_dir_remove(){

	if [ $USE_SYSTEMD -gt 0 ]; then
		systemd_tmpfilesd_conf_remove
	else

		if [ ! -z "$INST_PID" ]; then
			INST_PIDDIR=$(readlink -f $(dirname "$INST_PID"))
		else
			INST_PIDDIR="/var/run/${INST_NAME}"
			INST_PID="${INST_PIDDIR}/${INST_NAME}.pid"
		fi

		if [ -d "$INST_PIDDIR" ]; then
			error_echo "Removing ${INST_PIDDIR} pid directory.."
			rm -Rf "$INST_PIDDIR"
		fi
	fi
}


var_escape(){
	local LVAR="$1"

	[ $DEBUG -gt 0 ] && error_echo "Escaping string '${LVAR}'"

	# escape the escapes..
	LVAR="$(echo "$LVAR" | sed -e 's/\\/\\\\/g')"
	# escape the $s
	LVAR="$(echo "$LVAR" | sed -e 's/\$/\\\$/g')"
	# escape the `s
	LVAR="$(echo "$LVAR" | sed -e 's/`/\\`/g')"

	echo "$LVAR"

}

######################################################################################################
# env_file_create() Create the service config file.  Pass the names of the VARS to be written to the env file..
######################################################################################################
env_file_create(){
	#~ debug_echo "${FUNCNAME}( $@ )"
	local LINST_ENVFILE="$1"
	local LARGS=
	local LARG=
	
	# Note the $$ -- Indirection: Is variable 1 a variable NAME??  If yes, then variable 1 IS NOT our env filename..
	if [[ -v $$LINST_ENVFILE ]]; then
		debug_echo "${FUNCNAME}: 1st arg is a VAR name. LINST_ENVFILE == ${LINST_ENVFILE}"
		LINST_ENVFILE="$INST_NAME"
		LARGS="$@"
	else
		debug_echo "${FUNCNAME}: 1st arg is a FILE name. LINST_ENVFILE == ${LINST_ENVFILE}"
		LARGS="${@:2}"
	fi
	
	# Is the name not a fully qualified path?
	if [ $(echo "$LINST_ENVFILE" | grep -c '/') -lt 1 ]; then

		if [ $IS_DEBIAN -gt 0 ]; then
			LINST_ENVFILE="/etc/default/${LINST_ENVFILE}"
		else
			LINST_ENVFILE="/etc/sysconfig/${LINST_ENVFILE}"
		fi
	fi
	
	# Check to see if the file has the lock flag set..
    if [ -f "$LINST_ENVFILE" ]; then

		if [ $(grep -c 'ENVFILE_LOCK=1' "$LINST_ENVFILE") -gt 0 ]; then
			[ $QUIET -lt 1 ] && error_echo "${FUNCNAME}() error: File ${LINST_ENVFILE} is locked. ENVFILE_LOCK > 0"
			return 1
		fi

        [ ! -f "${LINST_ENVFILE}.org" ] && cp -p "$LINST_ENVFILE" "${LINST_ENVFILE}.org"
        mv -f "$LINST_ENVFILE" "${LINST_ENVFILE}.bak"

	fi

    [ $QUIET -lt 1 ] && error_echo "Creating env file ${LINST_ENVFILE}.."

    # Put in a commented Header..
    echo "# ${LINST_ENVFILE} -- $(timestamp_get_iso8601)" >"$LINST_ENVFILE"
	# In super-test mode, make the env file a bash script so we see color context in an editor
    [ $TEST -gt 2 ] && sed -i '1s|^|#!/bin/bash\n|' "$LINST_ENVFILE"

    
	for LARG in $LARGS
	#~ for ARG in $@
	do
		debug_echo "${LARG}=\"${!LARG}\""
		echo "${LARG}=\"${!LARG}\"" >>"$LINST_ENVFILE"
	done

	debug_echo "${FUNCNAME}() done."
}


######################################################################################################
# env_file_update() Update the service config file with new values, only changing vars that have values..
######################################################################################################
env_file_update(){
	debug_echo "${FUNCNAME}( $@ )"
	local LINST_ENVFILE="$1"
	local LARGS=
	local LARG=
	local LARG_VAL=
	
	# Note the $$ -- Indirection: Is variable 1 a variable NAME??  If yes, then variable 1 IS NOT our env filename..
	if [[ -v $$LINST_ENVFILE ]]; then
		debug_echo "${FUNCNAME}: 1st arg is a VAR name. LINST_ENVFILE == ${LINST_ENVFILE}"
		LINST_ENVFILE="$INST_NAME"
		LARGS="$@"
	else
		debug_echo "${FUNCNAME}: 1st arg is a FILE name. LINST_ENVFILE == ${LINST_ENVFILE}"
		LARGS="${@:2}"
	fi
	
	# Is the name not a fully qualified path?
	if [ $(echo "$LINST_ENVFILE" | grep -c '/') -lt 1 ]; then
		if [ $IS_DEBIAN -gt 0 ]; then
			LINST_ENVFILE="/etc/default/${LINST_ENVFILE}"
		else
			LINST_ENVFILE="/etc/sysconfig/${LINST_ENVFILE}"
		fi
	fi
	
	if [ ! -f "$LINST_ENVFILE" ]; then
		error_exit "Could not find config file ${LINST_ENVFILE}.."
	fi

	for LARG in $LARGS
	do
		# If our (indirect reference) variable isn't empty..
		if [ ! -z "${!LARG}" ]; then
			# escape the value
			LARG_VAL=$(echo "${!LARG}" | sed -e 's/#/\\#/g')

			LARG_VAL="$(var_escape "$LARG_VAL")"

			eval $LARG=\$LARG_VAL

			if [ $INST_ENVFILE_LOCK -lt 1 ]; then

				error_echo "Updating ${LINST_ENVFILE} with value ${LARG}=\"${!LARG}\""

				# Update the default file..
				sed -i -e "s#^${LARG}=.*#${LARG}=\"${!LARG}\"#" "$LINST_ENVFILE"

				if [ $(grep -c -E "${LARG}=\"${!LARG}\"" $LINST_ENVFILE) -lt 1 ]; then
					error_echo "Could not write value  ${LARG}=\"${!LARG}\" to ${LINST_ENVFILE}"
					grep -E "${LARG}=" $LINST_ENVFILE
					error_echo sed -i -e "s#^${LARG}=.*#${LARG}=\"${!LARG}\"#" "$LINST_ENVFILE"
					exit 1
				fi
			else
				error_echo "Env file ${LINST_ENVFILE} is locked. Cannot update with value ${LARG}=\"${!LARG}\""
			fi

		fi
	done
}

######################################################################################################
# env_file_read() Load the var values in the env file..
######################################################################################################
env_file_read(){
	local LINST_ENVFILE="${1:-${INST_NAME}}"

	# if LINST_ENVFILE is NOT a fully qualified pathname..
	if [ $(echo "$LINST_ENVFILE" | grep -c '/') -lt 1 ]; then
		if [ $IS_DEBIAN -gt 0 ]; then
			LINST_ENVFILE="/etc/default/${LINST_ENVFILE}"
		else
			LINST_ENVFILE="/etc/sysconfig/${LINST_ENVFILE}"
		fi
	fi

	if [ -f "$LINST_ENVFILE" ]; then
		. "$LINST_ENVFILE"
	else
		error_echo "Error: could not find ${LINST_ENVFILE}."
		return 1
	fi
}

######################################################################################################
# env_file_show() Show the var values in the env file..
######################################################################################################
env_file_show(){
	local LINST_ENVFILE=
	local LVAR=

	if [ $IS_DEBIAN -gt 0 ]; then
		LINST_ENVFILE="/etc/default/${INST_NAME}"
	else
		LINST_ENVFILE="/etc/sysconfig/${INST_NAME}"
	fi

	. "$LINST_ENVFILE"

	for LVAR in $(cat "$LINST_ENVFILE" | grep -E '^[^# ].*=.*$' | sed -n -e 's/^\([^=]*\).*$/\1/p' | xargs)
	do
		echo "${LVAR}=\"${!LVAR}\""
	done
}

######################################################################################################
# env_file_remove() Delete the default env file..
######################################################################################################
env_file_remove(){
	debug_echo "${FUNCNAME}( $@ )"
	local LINST_ENVFILE="$1"

	if [ -z "$LINST_ENVFILE" ]; then
		if [ $IS_DEBIAN -gt 0 ]; then
			LINST_ENVFILE="/etc/default/${INST_NAME}"
		else
			LINST_ENVFILE="/etc/sysconfig/${INST_NAME}"
		fi
	fi

	if [ -f "$LINST_ENVFILE" ]; then
		error_echo "Removing env file ${LINST_ENVFILE}.."
		rm -f "$LINST_ENVFILE"
	else
		error_echo "${LINST_ENVFILE} env not found."
	fi

}

######################################################################################################
# service_is_installed() Check to see that the service is installed.
#   Returns 0 if installed (i.e. opposite of is_service()
######################################################################################################
service_is_installed(){
	local LSERVICE="$1"
	local LINST_ENVFILE=
	local LINIT_SCRIPT=

	[ -z "$LSERVICE" ] && LSERVICE="$INST_NAME"
	
	if [ $USE_SYSTEMD -gt 0 ]; then
		if [ $(systemctl --no-pager cat "$LSERVICE" 2>/dev/null | wc -l) -gt 0 ]; then
			LINIT_SCRIPT="$(find /lib/ -type f -name "${LSERVICE}.service")"
			echo "${LSERVICE}: ${LINIT_SCRIPT}"
			return 0
		else
			return 1
		fi
	fi
	

	if [ $IS_DEBIAN -gt 0 ]; then
		LINST_ENVFILE="/etc/default/${LSERVICE}"
	else
		LINST_ENVFILE="/etc/sysconfig/${LSERVICE}"
	fi

	if [ $USE_UPSTART -gt 0 ]; then
		LINIT_SCRIPT="/etc/init/${LSERVICE}.conf"
	elif [ $USE_SYSTEMD -gt 0 ]; then
		echo "$LSERVICE"
		[ $(systemctl cat "$LSERVICE" 2>/dev/null | wc -l) -gt 0 ] && return 0 || return 1
		
		LINIT_SCRIPT="/lib/systemd/system/${LSERVICE}.service"
	else
		if [ $IS_DEBIAN -gt 0 ]; then
			LINIT_SCRIPT="/etc/init.d/${LSERVICE}"
		else
			LINIT_SCRIPT="/etc/rc.d/init.d/${LSERVICE}"
		fi
	fi

	if [ ! -f "$LINST_ENVFILE" ]; then
		return 1
	fi

	if [ ! -f "$LINIT_SCRIPT" ]; then
		return 1
	fi

	return 0
}


######################################################################################################
# service_is_enabled() Check to see that the service is installed and enabled.
#   Returns 0 if enabled, 1 if not
######################################################################################################
service_is_enabled(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LSERVICE="$1"

	if [ $USE_SYSTEMD -lt 1 ]; then
		service_is_installed "$LSERVICE"
		return $?
	fi

	( systemctl is-enabled --quiet "$LSERVICE" 2>/dev/null ) && return 0 || return 1

}

######################################################################################################
# service_is_running() Check to see that the service is running.
#   Returns 0 if running, 1 if not
######################################################################################################
service_is_running(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LSERVICE="$1"

	if [ $USE_SYSTEMD -lt 1 ]; then
		service_is_enabled "$LSERVICE"
		return $?
	fi

	( systemctl is-active --quiet "$LSERVICE" 2>/dev/null ) && return 0 || return 1

}


######################################################################################################
# ifaces_get( bIncludeVirtuals ) return a space-delimited list of network interface devices..
######################################################################################################
ifaces_get(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local bINCLUDE_VIRTUAL="${1:-0}"
	local LIFACES=
	local LIFACE=

	for LIFACE in $(ls -1 /sys/class/net/ | grep -v -E '^lo$' )
	do
		# Skip any virtual interfaces..
		if [ $bINCLUDE_VIRTUAL -lt 1 ] && [ $(ls -l /sys/class/net/ | grep "${LIFACE} ->" | grep -c '/virtual/') -gt 0 ]; then
			[[ "$LIFACE" != "ppp"* ]] && continue
		fi
		LIFACES="${LIFACES} ${LIFACE}"
	done

	if [ ! -z "$LIFACES" ]; then
		[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ ) -- Interfaces: ${LIFACES}"
		echo "$LIFACES"
		return 0
	fi

	[ $VERBOSE -gt 0 ] && error_echo "Error: no network interfaces are linked."
	return 1
}


######################################################################################################
# ifacess_get_links() returns a space-delimited list of LINKED network interface devices..
######################################################################################################
ifaces_get_links(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local bINCLUDE_VIRTUAL="${1:-0}"
	local LIFACE=
	local LIFACES=
	local LIS_WIRELESS=


	# Don't match the loopback interface
	for LIFACE in $(ls -1 '/sys/class/net' | grep -v -E '^lo$' | sort | xargs)
	do

		# Skip virtual interfaces..
		if [ $bINCLUDE_VIRTUAL -lt 1 ] && [ $(ls -l /sys/class/net/ | grep "${LIFACE} ->" | grep -c '/virtual/') -gt 0 ]; then
			[[ "$LIFACE" != "ppp"* ]] && continue
		fi

		# Check to see if the nic is wireless..
		iface_is_wireless "$LIFACE"
		LIS_WIRELESS=$?

		if [ $LIS_WIRELESS -eq 0 ]; then
			# wlx2824ff1a1c0d  IEEE 802.11  ESSID:"soledad"
 			#~ if [ $(iwconfig "$LIFACE" 2>&1 | grep -c -E 'ESSID:".+"') -gt 0 ]; then
			# wlp2s0    IEEE 802.11  ESSID:off/any
			if [ $(iwconfig "$LIFACE" 2>&1 | grep -c -E 'ESSID:[^off]') -gt 0 ]; then
				LIFACES="${LIFACES} ${LIFACE}"
			fi
		else
			if [ $(ethtool "$LIFACE" 2>&1 | grep -c 'Link detected: yes') -gt 0 ]; then
				LIFACES="${LIFACES} ${LIFACE}"
			fi
		fi
	done

	if [ ! -z "$LIFACES" ]; then
		# Put the intface with the gateway first..
		for LIFACE in $LIFACES
		do
			# If the interface has a gateway..
			if [ $(networkctl status "$LIFACE" 2>/dev/null | grep -c 'Gateway: ') -gt 0 ]; then
				LIFACES=$(echo $LIFACES | sed -n -e "s/ *${LIFACE} *//p")
				LIFACES="${LIFACE} ${LIFACES}"
				break
			fi
		done

		[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ ) -- Linked Interfaces: ${LIFACES}"
		echo "$LIFACES"
		return 0
	fi

	[ $VERBOSE -gt 0 ] && error_echo "Error: no network interfaces are linked."

	return 1
}

########################################################################################
# iface_is_valid( $NETDEV) Validates an interface name. returns 0 == valid; 1 == invalid
########################################################################################
iface_is_valid(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIFACE="$1"

	[ -z "$LIFACE" ] && return 1

	#~ if [ $(ls -1 '/sys/class/net' | grep -c -E "^${LIFACE}\$") -gt 0 ]; then
	[ -e "/sys/class/net/${LIFACE}" ] && return 0

	[ $VERBOSE -gt 0 ] && error_echo "Error: ${LIFACE} is not a valid network interface."
	return 1
}

########################################################################################
# iface_is_dhcp( $NETDEV) returns 0 == dhcp assigned address; 1 == static address
########################################################################################
iface_is_dhcp(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIFACE="$1"

	[ $(ip -4 addr show "${LIFACE}" | grep -c 'dynamic') -lt 1 ] && return 1 || return 0

}

########################################################################################
# iface_is_static( $NETDEV) returns 0 == static address; 1 == dhcp assigned address
########################################################################################
iface_is_static(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIFACE="$1"

	[ $(ip -4 addr show "${LIFACE}" | grep -c 'dynamic') -lt 1 ] && return 0 || return 1

}

echo_return(){
	$@
	RET=$?
	[ $RET ] && echo 0 || echo 1
	return $RET
}

########################################################################################
# iface_is_wireless( $NETDEV) Validates an interface as wireless. returns 0 == valid; 1 == invalid
########################################################################################
iface_is_wireless(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIFACE="$1"
	if [ -z "$LIFACE" ]; then
		return 1
	fi
	if [ -e "/sys/class/net/${LIFACE}/wireless" ]; then
		[ $DEBUG -gt 0 ] && error_echo "Error: ${LIFACE} is a wireless network interface."
		return 0
	fi
	[ $DEBUG -gt 0 ] && error_echo "Error: ${LIFACE} is not a wireless network interface."
	return 1
}

########################################################################################
# iface_is_wired( $NETDEV) Validates an interface as not wireless. returns 0 == valid; 1 == invalid
########################################################################################
iface_is_wired(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIFACE="$1"
	if [ -z "$LIFACE" ]; then
		return 1
	fi

	if [ -e "/sys/class/net/${LIFACE}" ]; then
		if [ ! -e "/sys/class/net/${LIFACE}/wireless" ]; then
			return 0
		fi
	fi
	[ $DEBUG -gt 0 ] && error_echo "Error: ${LIFACE} is not a wired network interface."
	return 1
}

########################################################################################
# iface_has_link( $NETDEV) Tests to see if an interface is linked. returns 0 == linked; 1 == no link;
########################################################################################
iface_has_link(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIFACE="$1"
	local LIS_WIRELESS=

	if [ -z "$LIFACE" ]; then
		return 1
	fi

	# Check to see if the nic is wireless..
	iface_is_wireless "$LIFACE"
	LIS_WIRELESS=$?

	if [ $LIS_WIRELESS -eq 0 ]; then
		if [ $(iwconfig "$LIFACE" 2>&1 | grep -c 'ESSID:') -gt 0 ]; then
			return 0
		fi
	else
		#~ if [ $(networkctl status "$LIFACE" 2>&1 | grep -c 'State: routable') -gt 0 ]; then
		if [ $(ethtool "$LIFACE" 2>&1 | grep -c 'Link detected: yes') -gt 0 ]; then
			return 0
		fi
	fi

	[ $VERBOSE -gt 0 ] && error_echo "Error: ${LIFACE} has no link."
	return 1

}

########################################################################################
#
# Get the primary nic
#
# Return the 1st nic that has a link status..
#
########################################################################################

iface_primary_geta() {
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	#~ echo "$(ls -1 '/sys/class/net' | grep -v -E '^lo$' | sort | head -n1)"
	local LIFACE="$(ls -1 '/sys/class/net' | sort | grep -m1 -v -E '^lo$')"

	if [ ! -z "$LIFACE" ]; then
		if [ $(ethtool "$LIFACE" | egrep -c 'Link detected: yes') -lt 1 ]; then
			[ $VERBOSE -gt 0 ] && error_echo "Warning: no link detected on primary interface ${LIFACE}.."
		fi
	else
		[ $VERBOSE -gt 0 ] && error_echo "Warning: no primary interface detected.."
		return 1
	fi
	echo "$LIFACE"
	return 0
}

########################################################################################
# iface_primary_getb( ) Get the 1st linked nic with a gateway or 1st physical nic
########################################################################################
iface_primary_getb() {
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local bINCLUDE_VIRTUAL="${1:-0}"
	local bLINKED_ONLY="${2:-0}"

	local LIFACE=
	local LIFACES=

	LIFACES=$(ifaces_get_links $bINCLUDE_VIRTUAL)
	if [ ! -z "$LIFACES" ]; then
		for LIFACE in $LIFACES
		do
			if [ $(networkctl status "$LIFACE" 2>/dev/null | grep -c " Gateway: ") -gt 0 ]; then
				echo "$LIFACE"
				return 0
			fi
		done
	fi

	if [ $bLINKED_ONLY -lt 1 ]; then
		LIFACE=$(ifaces_get $bINCLUDE_VIRTUAL | awk '{ print $1 }' )
		if [ ! -z "$LIFACE" ]; then
			echo "$LIFACE"
			return 0
		fi
	fi

	error_echo "Error: no primary network interface found.."
	return 1

}


iface_primary_get() {
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local PREFER_WIRELESS=${1:-0}
	local HASLINK=0
	local IFACE=''
	local IFACES=''
	local bRet=0

	if [ $PREFER_WIRELESS -gt 0 ]; then
		IFACES=$(iwconfig 2>&1 | grep 'ESSID' | awk '{print $1}')
		# Fallback if there are no wireless devices..
		if [ -z "$IFACES" ]; then
			IFACES=$(ls -1 /sys/class/net | sort | grep -v 'lo')
		fi
	else
		IFACES=$(ls -1 /sys/class/net | sort | grep -v 'lo')
	fi

	if [ -z "$IFACES" ]; then
		error_echo "Error: no network interfaces found.."
		exit 1
	fi

	# Find the 1st (sorted alpha) networking interface with a good link status..
	for IFACE in $IFACES
	do
		#Check the link status..
		if [ $(ethtool "$IFACE" | grep -c 'Link detected: yes') -gt 0 ]; then
			HASLINK=1
			break
		fi
	done

	if [ $HASLINK -gt 0 ]; then
		[ $VERBOSE -gt 0 ] && error_echo "Link detected on ${IFACE}.."
		INST_IFACE="$IFACE"
		echo "$IFACE"
		return 0
	fi

	# No link...try to wait a bit for the network to be established..
	[ $VERBOSE -gt 0 ] && error_echo "No link detected on any network interface...waiting 10 seconds to try again.."
	sleep 10

	# 2nd try..
	for IFACE in $IFACES
	do
		#Check the link status..
		if [ $(ethtool "$IFACE" | grep -c 'Link detected: yes') -gt 0 ]; then
			HASLINK=1
			break
		fi
	done

	if [ $HASLINK -gt 0 ]; then
		[ $VERBOSE -gt 0 ] && error_echo "Link detected on ${IFACE}.."
	else
		# Still no good -- our fallback: return the 1st nic..
		#IFACE="$(ls -1 /sys/class/net | sort | grep -m1 -v 'lo')"
		IFACE=${IFACES[0]}
		error_echo "No link found on any network device.  Defaulting to ${IFACE}.."
		bRet=1
	fi

	INST_IFACE="$IFACE"
	echo "$IFACE"

	[ $DEBUG -gt 0 ] && error_echo "Primary INST_IFACE == ${INST_IFACE}"

	return $bRet
}

iface_secondary_get() {
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	local LSKIPDEV="$1"
	local LHASLINK=0
	[ ! -z "$LSKIPDEV" ] && LSKIPDEV="|${LSKIPDEV}"

	# Get the 2nd entry..
	local LIFACE=$(ls -1 /sys/class/net | sort | egrep -v "lo${LSKIPDEV}" | sed -n 2p)

	if [ ! -z "$LIFACE" ]; then
		if [ $(ethtool "$LIFACE" | egrep -c 'Link detected: yes') -lt 1 ]; then
			[ $VERBOSE -gt 0 ] && error_echo "Warning: no link detected on secondary interface ${LIFACE}.."
		fi
	else
		[ $VERBOSE -gt 0 ] && error_echo "Warning: no secondary interface detected.."
		return 1
	fi
	echo "$LIFACE"
	return 0
}

########################################################################################
# iface_secondary_getb( ) Get the linked 1st nic without a gateway or 2nd physical nic
########################################################################################
iface_secondary_getb() {
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local bINCLUDE_VIRTUAL="${1:-0}"
	local LIFACE=
	local LIFACES=

	LIFACES=$(ifaces_get_links $bINCLUDE_VIRTUAL)
	if [ ! -z "$LIFACES" ]; then
		for LIFACE in $LIFACES
		do
			# If we con't have a gateway && we're != to the primary..
			if [ $(networkctl status "$LIFACE" 2>/dev/null | grep -c " Gateway: ") -lt 1 ] && [ "$LIFACE" != "$(iface_primary_getb)" ]; then
				echo "$LIFACE"
				return 0
			fi
		done
	fi

	# Else, just get the 2nd physical adaptor..
	LIFACE=$(ifaces_get $bINCLUDE_VIRTUAL | awk '{ print $2 }' )
	if [ ! -z "$LIFACE" ]; then
		echo "$LIFACE"
		return 0
	fi

	error_echo "Error: no primary network interface found.."
	return 1

}



########################################################################################
#
# iface_wireless_get()  Get the first wireless interface device name..
#
########################################################################################
iface_wireless_get() {
	iw dev | grep -m1 'Interface' | awk '{ print $2 }'
}

########################################################################################
#
# default_octet_get()  Get the default static IP for this subnet based on hostname..
#
########################################################################################
default_octet_get() {
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"

	case "$(hostname)" in
		scserver)
			echo '198'
			;;
		squeezenas)
			echo '222'
			;;
		squeezenas-mini)
			echo '111'
			;;
		alunas)
			echo '5'
			;;
		medianas)
			echo '10'
			;;
		backupnas)
			echo '15'
			;;
		mountaintop-nas)
			echo '222'
			;;
		unifi-box)
			echo '234'
			;;
		*)
			# bash regular expression matching: don't quote the pattern to match!
			# If the hostname *contains* speedbox, this is a mini-server
			# running lcwa-speedtest..

			# set nocasematch option
			shopt -s nocasematch

			if [[ "$(hostname)" =~ SPEEDBOX ]]; then
				echo '234'
			else
				# Default static IP for unknown hostname..
				echo '123'
			fi

			# unset nocasematch option
			shopt -u nocasematch
			;;
	esac
}

########################################################################################
#
# Validate an IPv4 address..returns 0 == valid; 1 == invalid
#
########################################################################################

ipaddress_validate_old(){
    local  LIP=$1
    local  LVALID_IP=1

	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"

	if [ -z "$LIP" ]; then
		return 1
	fi

	# Can't use sipcalc as it will validate a interface name too
	#~ if [ ! -z "$(which sipcalc)" ]; then
		#~ LVALID_IP=$(sipcalc -c "$LIP" | egrep -c 'ERR')
	#~ else
		if [[ $LIP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
			OIFS=$IFS
			IFS='.'
			LIP=($LIP)
			IFS=$OIFS
			[[ ${LIP[0]} -le 255 && ${LIP[1]} -le 255 \
				&& ${LIP[2]} -le 255 && ${LIP[3]} -le 255 ]]
			LVALID_IP=$?
		fi
	#~ fi
	if [ $LVALID_IP -gt 0 ]; then
		error_echo "Error: ${LIP} is not a valid ip address."
	fi
    return $LVALID_IP
}

########################################################################################
# ipaddress_validate( IPADDR ) See if the arg is a valid ipv4 address..
########################################################################################

ipaddress_validate(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	local LIP=$1
	local LVALID_IP=1

	if [ -z "$LIP" ]; then
		[ $VERBOSE -gt 0 ] && error_echo "${FUNCNAME} error: null address"
		return 1
	fi

	if [ "$LIP" == 'dhcp' ]; then
		return 0
	fi

	if [[ $LIP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
		local OIFS=$IFS
		local IFS='.'
		LIP=($LIP)
		IFS=$OIFS
		[[ ${LIP[0]} -le 255 && ${LIP[1]} -le 255 \
			&& ${LIP[2]} -le 255 && ${LIP[3]} -le 255 ]]
		LVALID_IP=$?
		IFS=$OIFS
	fi
	if [ $LVALID_IP -gt 0 ]; then
		[ $VERBOSE -gt 0 ] && error_echo "Error: ${LIP} is not a valid ip address."
	fi
	return $LVALID_IP
}



########################################################################################
#
# ipaddress_get( [$IFACE] ) Get the ipaddress of the [optional $IFACE]
#
########################################################################################

ipaddress_get(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	local LNETDEV="$1"
	local LIPADDR=

	if [ -z "$LNETDEV" ]; then
		#~ LIPADDR=$(ip -4 addr | grep -v -E 'inet .* lo' | grep -m1 -E 'inet ' | sed -n -e 's/^.*inet \([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\)\/.*/\1/p')
		LIPADDR="$(networkctl status 2>/dev/null | sed -n -e 's/^\s\+Address: \([0-9\.]\+\).*$/\1/p')"
	else
		#~ LIPADDR=$(ip -4 addr list $LNETDEV | grep -m1 -E 'inet ' | sed -n -e 's/^.*inet \([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\)\/.*/\1/p')
		LIPADDR="$(networkctl status "$LNETDEV" 2>/dev/null | sed -n -e 's/^\s\+Address: \([0-9\.]\+\).*$/\1/p')"
	fi

	[ $DEBUG -gt 0 ] && error_echo "IP address for ${LNETDEV} is ${LIPADDR}"

	echo "$LIPADDR"

}

ipaddr_is_valid(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}($@)"
	# Set up local variables
	local ip="$1"
	[ -z "$ip" ] && return 1
	local IFS=.; local -a a=($ip)
	# Start with a regex format test
	[[ $ip =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
	# Test values of quads
	local quad
	for quad in {0..3}; do
		[[ "${a[$quad]}" -gt 255 ]] && return 1
	done
	return 0
}

ipaddr_get(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	# FLAW: ip cmd only returns an ipv4 addr if there is a link..
	#~ local LIPADDR=$(ip -4 addr | grep -v -E 'inet .* lo' | grep -m1 -E 'inet ' | sed -n -e 's/^.*inet \([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\)\/.*/\1/p')
	local LIPADDR="$(networkctl status 2>/dev/null | sed -n -e 's/^\s\+Address: \([0-9\.]\+\).*$/\1/p')"

	[ $DEBUG -gt 0 ] && error_echo "Primary IP address == ${LIPADDR}"

	echo "$LIPADDR"
}

ipaddr_primary_get(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	# FLAW: ip cmd only returns an ipv4 addr if there is a link..
	#~ local LIPADDR=$(ip -4 addr | grep -v -E 'inet .* lo' | grep -m1 -E 'inet ' | sed -n -e 's/^.*inet \([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\)\/.*/\1/p')
	local LIPADDR="$(networkctl status 2>/dev/null | sed -n -e 's/^\s\+Address: \([0-9\.]\+\).*$/\1/p')"

	# Alternative: Get the IP of the 1st linked network device..
	#~ local LDEV=$(iface_primary_get)
	#~ local LIPADDR=$(iface_ipaddress_get "$LDEV")

	[ $DEBUG -gt 0 ] && error_echo "Primary IP address == ${LIPADDR}"

	echo "$LIPADDR"
}

ipaddr_secondary_get(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	# FLAW: ip cmd only returns an ipv4 addr if there is a link..
	#~ local LIPADDR=$(ip -4 addr | sort | grep -v -E 'inet .* lo' | grep -m1 -E 'inet ' | sed -n -e 's/^.*inet \([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\)\/.*/\1/p')
	local LIPADDR=$(ip -4 addr | sort | grep -v -E 'inet .* lo' | grep -E 'inet ' | sed -n -e 's/^.*inet \([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\)\/.*/\1/p' | sed -n 2p)

	# Alternative: Get the IP of the 2nd linked network device..
	#~ local LDEV=$(iface_secondary_get)
	#~ local LIPADDR=$(iface_ipaddress_get "$LDEV")


	[ $DEBUG -gt 0 ] && error_echo "Secondary IP address == ${LIPADDR}"

	echo "$LIPADDR"
}




ipaddrs_get(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	local LIPADDRS=$(ip -br a | grep -v -E '^lo.*' | awk '{ print $3 }' | sed -n -e 's#^\(.*\)/.*$#\1#p')

	[ $DEBUG -gt 0 ] && error_echo "IP addresses == ${LIPADDRS}"

	echo "$LIPADDRS"
}

subnet_get(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LSUBNET=

	if [ -z "$INST_IFACE" ]; then
		iface_primary_get
	fi

	LSUBNET=$(iface_ipaddress_get "$INST_IFACE")

	LSUBNET=$(echo $LSUBNET | sed -n 's/\(.\{1,3\}\)\.\(.\{1,3\}\)\.\(.\{1,3\}\)\..*/\1\.\2\.\3\.0\/24/p')

	INST_SUBNET="$LSUBNET"

	[ $DEBUG -gt 0 ] && error_echo "INST_SUBNET of ${INST_IFACE} == ${INST_SUBNET}"

}


########################################################################################
#
# iface_subnet_get( $NETDEV ) Get the subnet ipaddress of the $NETDEV interface
#
########################################################################################

iface_subnet_get(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIFACE="$1"
	local LSUBNET=$(ip -br a | grep "$LIFACE" | awk '{ print $3 }' | sed -n 's#\([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.\)[0-9]\{1,3\}/\([0-9]\{1,2\}\).*$#\10/\2#p')

	[ $DEBUG -gt 0 ] && error_echo "INST_SUBNET of ${LIFACE} == ${LSUBNET}"
	echo "$LSUBNET"
}

iface_gateway_get(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIFACE="$1"
	#~ local LGATEWAY="$(route -n | grep -E -o "^.*([0-9]{1,3}[\.]){3}[0-9]{1,3}.*UG.*${LIFACE}" | awk '{ print $2 }')"
	local LGATEWAY="$(networkctl status "$LIFACE" 2>/dev/null | grep 'Gateway' | awk '{ print $2 }')"

	if [ ! -z "$LGATEWAY" ]; then
		echo "$LGATEWAY"
		return 0
	fi

	[ $QUIET -lt 1 ] && error_echo "Error: Could not get gateway address for ${LIFACE}."
	return 1
}


########################################################################################
#
# ipaddress_subnet_get( $IPADDR ) Get the subnet ipaddress of the $IPADDR
#
########################################################################################

ipaddress_subnet_get(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local IPADDR="$1"
	local LSUBNET=

	if [ -z "$IPADDR" ]; then
		IPADDR="$(ipaddress_get)"
	fi

	LSUBNET=$(echo "$IPADDR" | sed -n 's/\(.\{1,3\}\)\.\(.\{1,3\}\)\.\(.\{1,3\}\)\..*/\1\.\2\.\3\.0\/24/p')
	echo "$LSUBNET"

	INST_SUBNET="$LSUBNET"

	[ $DEBUG -gt 0 ] && error_echo "INST_SUBNET of ${INST_IFACE} == ${INST_SUBNET}"

	if [ -z "$LSUBNET" ]; then
		return 1
	fi
	return 0
}

########################################################################################
#
# ipaddr_subnet_get( $IPADDR ) Get the subnet ipaddress of the $IPADDR
#
########################################################################################

ipaddr_subnet_get(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIPADDR="$1"
	local LSUBNET=

	if [ -z "$LIPADDR" ]; then
		LIPADDR="$(ipaddress_get)"
	fi

	LSUBNET=$(ip -br a | grep "$LIPADDR" | awk '{ print $3 }' | sed -n 's#\([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.\)[0-9]\{1,3\}/\([0-9]\{1,2\}\).*$#\10/\2#p')

	# Punt!
	[ -z "$LSUBNET" ] && LSUBNET=$(echo "$LIPADDR" | sed -n 's/\(.\{1,3\}\)\.\(.\{1,3\}\)\.\(.\{1,3\}\)\..*/\1\.\2\.\3\.0\/24/p')

	[ $DEBUG -gt 0 ] && error_echo "Subnet of ${LIPADDR} == ${LSUBNET}"

	echo "$LSUBNET"

	if [ -z "$LSUBNET" ]; then
		return 1
	fi
	return 0
}


########################################################################################
#
# iface_ipaddress_get( $IFACE ) Get the ipaddress of the $IFACE
#
########################################################################################

iface_ipaddress_get(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIFACE="$1"
	local LIPADDR=

	# avoid parsing ifconfig
	# use ip
	# or ifdata
	# or hostname --all-ip-addresses
	# or networkctl

	if [ -z "$LIFACE" ]; then
		#~ LIPADDR=$(hostname --all-ip-addresses | sed -n -e 's/^\([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\).*$/\1/p')
		#~ LIPADDR=$(ip -br a | sort | grep -m1 -E -v '^lo.*' | awk '{ print $3 }' | sed -n -e 's#\(.*\)/\+.*$#\1#p')
		LIPADDR="$(networkctl status 2>/dev/null | sed -n -e 's/^\s\+Address: \([0-9\.]\+\).*$/\1/p')"
	else
		#~ if [ ! -z "$(which ifdata)" ]; then
			#~ LIPADDR=$(ifdata -pa "$LIFACE")
		#~ else
			#~ LIPADDR=$(ip -4 addr list $LIFACE | grep -m1 -E 'inet ' | sed -n -e 's/^.*inet \([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\)\/.*/\1/p')
		#~ fi
		LIPADDR="$(networkctl status "$LIFACE" 2>/dev/null | sed -n -e 's/^\s\+Address: \([0-9\.]\+\).*$/\1/p')"
	fi

	[ $DEBUG -gt 0 ] && error_echo "IP address for ${LIFACE} is ${LIPADDR}"

	echo "$LIPADDR"
}


iface_hwaddress_get(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	local LIFACE="$1"

	if [ -z "$LIFACE" ]; then
		return 1
	fi

	#~ local LHWADDR="$(ifconfig "$LIFACE" | grep -o -E '([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}')"
	#~ local LHWADDR="$(networkctl status "$LIFACE" 2>/dev/null | grep 'HW Address:' | awk '{ print $3 }')"
	#~ local LHWADDR="$(networkctl status "$LIFACE" 2>/dev/null | sed -n -e 's/^.*HW Address: \([^\s]\+\)\s*.*$/\1/p')"

	local LHWADDR="$(cat "/sys/class/net/${LIFACE}/address")"

	if [ ! -z "$LHWADDR" ]; then
		echo "$LHWADDR"
		return 0
	fi

	[ $VERBOSE -gt 0 ] && error_echo "Error: Could not get hardware mac address for ${LIFACE}."
	return 1
}


########################################################################################
#
# ipaddress_iface_get( $IPADDR ) Get the interface device configured with $IPADDR
#
########################################################################################
ipaddress_iface_get(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIPADDR="$1"
	local LIFACE=
	ipaddress_validate "$LIPADDR"

	if [ $? -gt 0 ]; then
		error_echo "${LIPADDR} is not a valid IP address.."
		return 1
	fi

	#~ LIFACE=$(netstat -ie | grep -B1 "$LIPADDR" | sed -n -e 's/^\([^ ]\+\)\s.*$/\1/p')
	#~ # Strip any trailing :
	#~ LIFACE=$(echo $local | sed -e 's/^\(.*\):/\1/')

	LIFACE=$(ip -br a | grep "$LIPADDR" | awk '{ print $1 }')


	[ $DEBUG -gt 0 ] && error_echo "Interface for IP address ${LIPADDR} is ${local}"

	echo "$local"
}



######################################################################################################
# Firewall related functions...
######################################################################################################

######################################################################################################
# firewall_service_exists ( service_name ) Checks for existance of a named port definition in
#   /etc/services.  returns 0 == service exists || 1 == service does not exist.
######################################################################################################
firewall_service_exists() {
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LSERVICE="$1"
	local LCONF_FILE='/etc/services'
	[ -z "$LSERVICE" ] && return 1
	#~ grep -E "^${LSERVICE}\s+[[:digit:]]+\/[tcudp]+.*" "$LCONF_FILE"
	[ $(grep -c -E "^${LSERVICE}\s+[[:digit:]]+\/[[:alpha:]]+.*" "$LCONF_FILE") -gt 0 ] && return 0 || return 1
}

######################################################################################################
# firewall_service_comment ( service_name ) Checks for existance of a named port definition in
#   /etc/services and comments it out.  returns 0 == service commented || 1 == service still uncommented.
######################################################################################################
firewall_service_comment() {
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LSERVICE="$1"
	local LCONF_FILE='/etc/services'
	[ -z "$LSERVICE" ] && return 1
	
	# Local services
	#x10cmdr		3003/tcp			# x10 Commander Socket Service

	sed -i -e "s/^\(${LSERVICE}\s\+\)/#\1/" "$LCONF_FILE"
	[ $(grep -c -E "^#${LSERVICE}\s+[[:digit:]]+\/[[:alpha:]]+.*" "$LCONF_FILE") -gt 0 ] && return 0
	[ $(grep -c -E "^${LSERVICE}\s+[[:digit:]]+\/[[:alpha:]]+.*" "$LCONF_FILE") -gt 0 ] && return 1
}

######################################################################################################
# firewall_service_uncomment ( service_name ) Checks for existance of a named port definition in
#   /etc/services and comments it out.  returns 0 == service commented || 1 == service still uncommented.
######################################################################################################
firewall_service_uncomment() {
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LSERVICE="$1"
	local LCONF_FILE='/etc/services'
	[ -z "$LSERVICE" ] && return 1
	
	# Local services
	#x10cmdr		3003/tcp			# x10 Commander Socket Service

	sed -i -e "s/^#\(${LSERVICE}\s\+\)/\1/" "$LCONF_FILE"
	[ $(grep -c -E "^${LSERVICE}\s+[[:digit:]]+\/[[:alpha:]]+.*" "$LCONF_FILE") -gt 0 ] && return 0
	[ $(grep -c -E "^#${LSERVICE}\s+[[:digit:]]+\/[[:alpha:]]+.*" "$LCONF_FILE") -gt 0 ] && return 1
}



######################################################################################################
# firewall_service_open ( service_name, iface|ipaddr|null_for_public )
#		 -- opens a /etc/services defined /etc/services service.
######################################################################################################
firewall_service_open() {
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LSERVICE="$1"
	local LPARAMS="$2"
	local LPARAM=

	# Check to see if the service is in /etc/services
	if ( ! firewall_service_exists "$LSERVICE" ); then
		error_echo "Error: service ${LSERVICE} is undefined."
		return 1
	fi

	if [ -z "$LPARAMS" ]; then
		# Open publically..
		if [ $USE_FIREWALLD -gt 0 ]; then
			LFWZONE='public'
			firewall-cmd --permanent --zone=${LFWZONE} --add-service=${LSERVICE} >/dev/null && error_echo "Opening ${LFWZONE} for service ${LSERVICE}"
			firewall-cmd --reload
		else
			ufw allow "$LSERVICE" >/dev/null && error_echo "Opening Anywhere for service ${LSERVICE}"
		fi
		return $?
	else
		# LPARAMS can be an array of ip addresses or interface devices..
		for LPARAM in $LPARAMS
		do
			if ( ipaddr_is_valid "$LPARAM" ); then
				[ $USE_FIREWALLD -gt 0 ] && LFWZONE="$(ipaddr_firewall_zone_get "$LPARAM")" || LSUBNET="$(ipaddr_subnet_get "$LPARAM")"
			elif (iface_is_valid "$LPARAM" ); then
				[ $USE_FIREWALLD -gt 0 ] && LFWZONE="$(iface_firewall_zone_get "$LPARAM")" || LSUBNET="$(iface_subnet_get "$LPARAM")"
			else
				error_echo "Error: ${LPARAM} is neither an ipaddr or iface."
				continue
			fi

			if [ $USE_FIREWALLD -gt 0 ]; then
				[ ! -z "$LFWZONE" ] && firewall-cmd "--permanent" "--zone=${LFWZONE}" "--add-service=${LSERVICE}" >/dev/null && [ $VERBOSE -gt 0 ] && error_echo "Opening ${LFWZONE} for service ${LSERVICE}.."
			else
				[ ! -z "$LSUBNET" ] && ufw allow from "$LSUBNET" to any port "$LSERVICE" >/dev/null && [ $VERBOSE -gt 0 ] && error_echo "Opening ${LSUBNET} for service ${LSERVICE}.."
			fi
		done
	fi

	return 0
}

firewall_service_close() {
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LSERVICE="$1"
	local LPARAMS="$2"
	local LPARAM=

	# Check to see if the service is in /etc/services
	if ( ! firewall_service_exists "$LSERVICE" ); then
		error_echo "Error: service ${LSERVICE} is undefined."
		return 1
	fi

	if [ -z "$LPARAMS" ]; then
		# Open publically..
		if [ $USE_FIREWALLD -gt 0 ]; then
			LFWZONE='public'
			firewall-cmd --permanent --zone=${LFWZONE} --remove-service=${LSERVICE} >/dev/null && error_echo "Closing ${LFWZONE} for service ${LSERVICE}"
			firewall-cmd --reload
		else
			ufw delete allow "$LSERVICE" >/dev/null && error_echo "Closing Anywhere for service ${LSERVICE}"
		fi
		return $?
	else
		# LPARAMS can be an array of ip addresses or interface devices..
		for LPARAM in $LPARAMS
		do
			if ( ipaddr_is_valid "$LPARAM" ); then
				[ $USE_FIREWALLD -gt 0 ] && LFWZONE="$(ipaddr_firewall_zone_get "$LPARAM")" || LSUBNET="$(ipaddr_subnet_get "$LPARAM")"
			elif (iface_is_valid "$LPARAM" ); then
				[ $USE_FIREWALLD -gt 0 ] && LFWZONE="$(iface_firewall_zone_get "$LPARAM")" || LSUBNET="$(iface_subnet_get "$LPARAM")"
			else
				error_echo "Error: ${LPARAM} is neither an ipaddr or iface."
				continue
			fi

			if [ $USE_FIREWALLD -gt 0 ]; then
				[ ! -z "$LFWZONE" ] && firewall-cmd "--permanent" "--zone=${LFWZONE}" "--remove-service=${LSERVICE}" >/dev/null && [ $VERBOSE -gt 0 ] && error_echo "Closing ${LFWZONE} for service ${LSERVICE}.."
			else
				[ ! -z "$LSUBNET" ] && ufw delete allow from "$LSUBNET" to any port "$LSERVICE" >/dev/null && [ $VERBOSE -gt 0 ] && error_echo "Closing ${LSUBNET} for service ${LSERVICE}.."
			fi
		done
	fi

	return 0
}

######################################################################################################
# firewall_app_exists ( app_name ) Returns 0 if a defined app exists..
######################################################################################################
firewall_app_exists(){
	local LAPP_NAME="$1"
	if [ $USE_FIREWALLD -gt 0 ]; then
		[ $(firewall-cmd --get-services | xargs -n 1 | grep -c -E "^${LAPP_NAME}\$") -gt 0 ] && return 0 || return 1
	else
		[ $(ufw app list | grep -E '^\s+' | xargs | xargs -n 1 | grep -c -E "^${LAPP_NAME}\$") -gt 0 ] && return 0 || return 1
	fi
}


######################################################################################################
# firewall_create_app ( app_name "appfile_contents") Creates and registers the application / service
#	file for ufw or firewalld.
######################################################################################################
firewall_app_create(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LAPP_NAME="$1"
	local LAPP="$2"
	local LPUBLIC=${3:-0}
	local LCONF_DIR=
	local LCONF_FILE=

	# Check to see if the APP is already open


	if [ -z "$LAPP" ]; then
		error_echo "Error: no app file passed."
	fi

	if [ $USE_FIREWALLD -gt 0 ]; then
		LCONF_DIR='/etc/firewalld/services'
		if [ ! -d "$LCONF_DIR" ]; then
			error_echo "Error: ${LCONF_DIR} not found."
			return 1
		fi
		LCONF_FILE="${LCONF_DIR}/${LAPP_NAME}.xml"

		# Only backup service.xml files..
		if [ -f "$LCONF_FILE" ]; then
			if [ ! -f "${LCONF_FILE}.org" ]; then
				cp -p "$LCONF_FILE" "${LCONF_FILE}.org"
			fi
			cp -p "$LCONF_FILE" "${LCONF_FILE}.bak"
		fi

	else

		LCONF_DIR='/etc/ufw/applications.d'
		if [ ! -d "$LCONF_DIR" ]; then
			error_echo "Error: ${LCONF_DIR} not found."
			return 1
		fi

		# Check for $LAPP_NAME in /etc/services. Rename our app to avoid collision..
		#~ if [ $(grep -c -E "^${LAPP_NAME}\s+" /etc/services) -gt 0 ]; then
			#~ LAPP_NAME="my-${LAPP_NAME}"
		#~ fi

		if ( firewall_service_exists "$LAPP_NAME" ); then
			firewall_service_comment "$LAPP_NAME"
		fi
		
		if ( firewall_service_exists "$LAPP_NAME" ); then
			firewall_service_comment "$LAPP_NAME"
			LAPP_NAME="my-${LAPP_NAME}"
		fi
	

		LCONF_FILE="${LCONF_DIR}/${LAPP_NAME}"

	fi

	##############################################################################################
	##############################################################################################
	##############################################################################################
	##############################################################################################
	# For UFW, check for existence of ^${LAPP_NAME}\s+ in /etc/services
	#   If there is one, rename our LAPP_NAME to "my-${LAPP_NAME}" and fixup the [${LAPP_NAME}]
	#   in the file.
	##############################################################################################
	##############################################################################################
	##############################################################################################

	error_echo "Creating firewall application file ${LCONF_FILE}.."

	echo "$LAPP" >"$LCONF_FILE"
	chown root:root "$LCONF_FILE"
	chmod 0644 "$LCONF_FILE"

	if [ $USE_UFW -gt 0 ]; then
		# Fix up entries in the app file if we've prefixed 'my-' to avoid
		# collisions with an entry in /etc/services..
		if [ $(echo $LAPP_NAME | grep -c -E '^my-.*$') -gt 0 ]; then
			if [ $(grep -c -E "^\[${LAPP_NAME#my-}\]" "$LCONF_FILE") -gt 0 ]; then

				sed -i -e "s#^\[${LAPP_NAME#my-}\]#\[${LAPP_NAME}\]#" "$LCONF_FILE"

				sed -i -e "s#^title=${LAPP_NAME#my-}#title=${LAPP_NAME}#" "$LCONF_FILE"
			fi
		fi
	fi


	if [ $DEBUG -gt 0 ]; then
		error_echo "#########################################################################"
		cat "$LCONF_FILE"
		error_echo "#########################################################################"
	fi

	if [ $USE_FIREWALLD -gt 0 ]; then
		firewall-cmd --reload

		if [ $(firewall-cmd --get-services | xargs -n 1 | grep -c -E "^${LAPP_NAME}\$") -lt 1 ]; then
			error_echo "Error: ${LAPP_NAME} was not registered as a service."
			return 1
		fi
	else
		ufw app update "$LAPP_NAME"
		ufw app info "$LAPP_NAME"

		if [ $(ufw app list | grep -c -E "^\s+${LAPP_NAME}$") -lt 1 ]; then
			error_echo "Error: ${LAPP_NAME} was not registered as a service."
			return 1
		fi

	fi
}

######################################################################################################
# firewall_app_file_check ( app_name ) Checks for existance of app-service port definition file.
#	returns 0 == file exists || 1 == file does not exist.
######################################################################################################
firewall_app_file_check(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LAPP_NAME="$1"
	local LCONF_FILE=
	if [ $USE_FIREWALLD -gt 0 ]; then
		LCONF_FILE="/lib/firewalld/services/${LAPP_NAME}.xml"
	else
		LCONF_FILE="/etc/ufw/applications.d/${LAPP_NAME}"
	fi

	# App file not installed, so by definition, the app's port(s) has/have not been opened.
	[ -f "$LCONF_FILE" ] && return 0 || return 1

}

########################################################################################
# firewall_app_open( app_name, ifaces || ipaddrs || null_for_public)
#		Opens a defined ufw app profile or firewalld service.xml
########################################################################################
firewall_app_open(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LAPP_NAME="$1"
	local LPARAMS="$2"
	local LPARAM=
	local LFWZONE=

	# Avoid collision with pre-defined services in /etc/services if using ufw..
	if [ $USE_UFW -gt 0 ]; then
		if ( firewall_service_exists "$LAPP_NAME" ); then
			LAPP_NAME="my-${LAPP_NAME}"
		fi
	fi

	# ufw app update emits no error even if the app isn't defined or exists..
	[ $USE_UFW -gt 0 ] && ufw app update "$LAPP_NAME" || firewall-cmd --reload

	# Check to see if the app defined & registered..
	if ( ! firewall_app_exists "$LAPP_NAME" ); then
		error_echo "Error: application ${LAPP_NAME} is undefined."
		return 1
	fi

	if [ -z "$LPARAMS" ]; then
		# Open publically..
		if [ $USE_FIREWALLD -gt 0 ]; then
			LFWZONE='public'
			firewall-cmd --permanent --zone=${LFWZONE} --add-service=${LAPP_NAME} >/dev/null && echo "Opening ${LFWZONE} for application ${LAPP_NAME}"
			firewall-cmd --reload
		else
			ufw allow "$LAPP_NAME"  >/dev/null && echo "Opening Anywhere for application ${LAPP_NAME}"
		fi
		return $?
	else
		# LPARAMS can be an array of ip addresses or interface devices..
		for LPARAM in $LPARAMS
		do
			if ( ipaddr_is_valid "$LPARAM" ); then
				[ $USE_FIREWALLD -gt 0 ] && LFWZONE="$(ipaddr_firewall_zone_get "$LPARAM")" || LSUBNET="$(ipaddr_subnet_get "$LPARAM")"
			elif (iface_is_valid "$LPARAM" ); then
				[ $USE_FIREWALLD -gt 0 ] && LFWZONE="$(iface_firewall_zone_get "$LPARAM")" || LSUBNET="$(iface_subnet_get "$LPARAM")"
			else
				error_echo "Error: ${LPARAM} is neither an ipaddr or iface."
				continue
			fi

			if [ $USE_FIREWALLD -gt 0 ]; then
				[ ! -z "$LFWZONE" ] && firewall-cmd "--permanent" "--zone=${LFWZONE}" "--add-service=${LAPP_NAME}" && [ $VERBOSE -gt 0 ] && error_echo "Opening ${LFWZONE} for application ${LAPP_NAME}.."
				firewall-cmd --reload
			else
				[ ! -z "$LSUBNET" ] && ufw allow from "$LSUBNET" to any app "$LAPP_NAME" >/dev/null && [ $VERBOSE -gt 0 ] && error_echo "Opening ${LSUBNET} for application ${LAPP_NAME}.."
			fi
		done
	fi

	return 0

}

########################################################################################
# firewall_app_close( app_name, ifaces || ipaddrs || null_for_public)
#		Opens a defined ufw app profile or firewalld service.xml
########################################################################################
firewall_app_close(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LAPP_NAME="$1"
	local LPARAMS="$2"
	local LPARAM=
	local LFWZONE=

	# Avoid collision with pre-defined services in /etc/services if using ufw..
	if [ $USE_UFW -gt 0 ]; then
		if ( firewall_service_exists "$LAPP_NAME" ); then
			LAPP_NAME="my-${LAPP_NAME}"
		fi
	fi

	# ufw app update emits no error even if the app isn't defined or exists..
	[ $USE_UFW -gt 0 ] && ufw app update "$LAPP_NAME" || firewall-cmd --reload

	# Check to see if the app defined & registered..
	if ( ! firewall_app_exists "$LAPP_NAME" ); then
		error_echo "Error: application ${LAPP_NAME} is undefined."
		return 1
	fi

	if [ -z "$LPARAMS" ]; then
		# Open publically..
		if [ $USE_FIREWALLD -gt 0 ]; then
			LFWZONE='public'
			firewall-cmd --permanent --zone=${LFWZONE} --remove-service=${LAPP_NAME} >/dev/null && error_echo "Closing ${LFWZONE} for application ${LAPP_NAME}"
			firewall-cmd --reload
		else
			ufw delete allow "$LAPP_NAME" >/dev/null && error_echo "Closing Anywhere for application ${LAPP_NAME}"
		fi
		return $?
	else
		# LPARAMS can be an array of ip addresses or interface devices..
		for LPARAM in $LPARAMS
		do
			if ( ipaddr_is_valid "$LPARAM" ); then
				[ $USE_FIREWALLD -gt 0 ] && LFWZONE="$(ipaddr_firewall_zone_get "$LPARAM")" || LSUBNET="$(ipaddr_subnet_get "$LPARAM")"
			elif (iface_is_valid "$LPARAM" ); then
				[ $USE_FIREWALLD -gt 0 ] && LFWZONE="$(iface_firewall_zone_get "$LPARAM")" || LSUBNET="$(iface_subnet_get "$LPARAM")"
			else
				error_echo "Error: ${LPARAM} is neither an ipaddr or iface."
				continue
			fi

			if [ $USE_FIREWALLD -gt 0 ]; then
				[ ! -z "$LFWZONE" ] && firewall-cmd "--permanent" "--zone=${LFWZONE}" "--remove-service=${LAPP_NAME}" >/dev/null && [ $VERBOSE -gt 0 ] && error_echo "Closing ${LFWZONE} for application ${LAPP_NAME}.."
				firewall-cmd --reload
			else
				[ ! -z "$LSUBNET" ] && ufw delete allow from "$LSUBNET" to any app "$LAPP_NAME" >/dev/null && [ $VERBOSE -gt 0 ] && error_echo "Closing ${LSUBNET} for application ${LAPP_NAME}.."
			fi
		done
	fi

	return 0

}

########################################################################################
# firewall_app_close( app_name, ifaces || ipaddrs || null_for_public)
#		Opens a defined ufw app profile or firewalld service.xml
########################################################################################
firewall_app_close_all(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LAPP_NAME="$1"
	local LRULE=
	local LFWZONE=
	local LSUBNET=

	[ -z "$LAPP_NAME" ] && return 1

	# Avoid collision with pre-defined services in /etc/services if using ufw..
	if [ $USE_UFW -gt 0 ]; then
		if ( firewall_service_exists "$LAPP_NAME" ); then
			LAPP_NAME="my-${LAPP_NAME}"
		fi
	fi

	# UFW firewall rule can still exist after the app file has been removed..
	#~ if ( ! firewall_app_exists "$LAPP_NAME" ); then
		#~ error_echo "Error: application ${LAPP_NAME} is undefined."
		#~ return 1
	#~ fi

	if [ $USE_FIREWALLD -gt 0 ]; then
		for LFWZONE in $(firewall-cmd --get-zones | xargs -n 1 | sort)
		do
			if [ $(firewall-cmd --zone=${LFWZONE} --list-services | xargs -n 1 | grep -c -E "^${LAPP_NAME}$") -gt 0 ]; then
				firewall-cmd --permanent --zone=${LFWZONE} --remove-service=${LAPP_NAME}>/dev/null && [ $VERBOSE -gt 0 ] && error_echo "Closing zone ${LFWZONE} for application ${LAPP_NAME}.."
			fi
		done
		firewall-cmd --reload

	elif [ $USE_UFW -gt 0 ]; then
		LRULE="$(ufw status | grep -E "^${LAPP_NAME}\s+ALLOW.*$")"
		if [ $(echo "$LRULE" | grep -c 'Anywhere') -gt 0 ]; then
			ufw delete allow "$LAPP_NAME" >/dev/null && error_echo "Closing Anywhere for application ${LAPP_NAME}.."
		else
			LSUBNET="$(echo "$LRULE" | xargs | sed -n -e 's/^.*ALLOW\s\+\(.*\)$/\1/p')"
			[ ! -z "$LSUBNET" ] && ufw delete allow from "$LSUBNET" to any app "$LAPP_NAME" >/dev/null && [ $VERBOSE -gt 0 ] && error_echo "Closing ${LSUBNET} for application ${LAPP_NAME}.."
		fi
	fi

	return 0

}



########################################################################################
# firewall_app_close( app_name, iface || ipaddr )
########################################################################################
firewall_app_closex(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LAPP_NAME="$1"
	local LPARAM="$2"
	local LFWZONE=
	local LRULE_NUM=
	if [ $USE_FIREWALLD -gt 0 ]; then
		#~ for LFWZONE in $(firewall-cmd --get-default-zone) 'public'
		for LFWZONE in $(firewall-cmd --list-all-zones | grep -v -E '^\s+.*' | xargs)
		do
			if [ $(firewall-cmd --zone=${LFWZONE} --list-all | grep 'services:' | \
					xargs -n 1 | grep -c -E "^${LAPP_NAME}\$") -gt 0 ]; then
				firewall-cmd --permanent --zone=${LFWZONE} --remove-service=${LAPP_NAME}
			fi
		done
		firewall-cmd --reload
	else
		#~ [ $DEBUG -gt 0 ] && ufw status numbered | grep -E "^\[ *[[:digit:]]+\]\s+${LAPP_NAME}\s+ALLOW.*\$"
		for LRULE_NUM in  $(ufw status numbered | grep -E "^\[\s*[[:digit:]]+\]\s+${LAPP_NAME}\s+ALLOW.*\$" | sed -n -e 's/^\[\s*\([[:digit:]]\+\)\].*$/\1/p')
		do
			#~ [ $DEBUG -gt 0 ] && ufw status numbered | grep -E "^\[ *[[:digit:]]+\]\s+${LAPP_NAME}\s+ALLOW.*\$"
			[ $DEBUG -gt 0 ] && error_echo "ufw delete ${LRULE_NUM}"
			[ ! -z "$LRULE_NUM" ] && echo 'Y' | ufw delete "$LRULE_NUM"
		done
	fi

	# If the firewall is still closed for the app..
	if ( ! firewall_app_check "$LAPP_NAME" ); then
		[ $QUIET -lt 1 ] && error_echo "Error: unable to close ${LIPADDR} - ${LFWZONE} for ${LAPP_NAME}"
		return 1
	fi

	return 0
}


########################################################################################
# iface_firewall_app_check( iface, appname )-- checks the firewall to see if a app/service
#		file is installed and activated by the firewall. If the iface is null, then checks
#		to see if the firewall is open to all subnets / public zone for the app.
#		Returns 0 if the firewall is not open for the app, 1 if opened for the app.
########################################################################################
iface_firewall_app_check(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIFACE="$1"
	local LAPP_NAME="$2"
	local LFWZONE=
	local LSUBNET=

	# If the App file is not installed, by definition, the app's port(s) has/have not been opened.
	! firewall_app_file_check "$LAPP_NAME" && return 0

	if [ $USE_FIREWALLD -gt 0 ]; then
		if [ -z "$LIFACE" ]; then
			LFWZONE='public'
		else
			LFWZONE="$(iface_firewall_zone_get "$LIFACE")"
		fi

		[ $(firewall-cmd --zone=${LFWZONE} --list-all | grep 'services:' | \
			xargs -n 1 | grep -c -E "^${LAPP_NAME}\$") -gt 0 ] && return 1 || return 0

	else
		# UFW
		#~ LSECTIONS="$(cat $LCONF_FILE | sed -n -e 's/^\[\(.*\)\].*$/\1/p' | xargs)"
		#~ for LSECTION in $LSECTIONS
		#~ do
			#~ ufw status | grep -c -E "^${LSECTION}\s+ALLOW"
		#~ done
		if [ -z "$LIFACE" ]; then
			[ $(ufw status | grep -c -E "^${LAPP_NAME}\s+ALLOW\s+Anywhere.*$") -gt 0 ] && return 1 || return 0
		else
			LSUBNET="$(iface_subnet_get "$LIFACE")"
			[ $(ufw status | grep -c -E "^${LAPP_NAME}\s+ALLOW\s+${LGATEWAY}.*$") -gt 0 ] && return 1 || return 0
		fi
	fi
}

########################################################################################
# ipaddr_firewall_app_check( ipaddr, appname )-- checks the firewall to see if a app/service
#		file is installed and activated by the firewall. If the ipaddr is null, then checks
#		to see if the firewall is open to all subnets / public zone for the app.
#		Returns 0 if the firewall is not open for the app, 1 if opened for the app.
########################################################################################
ipaddr_firewall_app_check(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIPADDR="$1"
	local LAPP_NAME="$2"
	local LFWZONE=
	local LSUBNET=

	# If the App file is not installed, by definition, the app's port(s) has/have not been opened.
	! firewall_app_file_check "$LAPP_NAME" && return 0

	if [ $USE_FIREWALLD -gt 0 ]; then
		if [ -z "$LIPADDR" ]; then
			LFWZONE='public'
		else
			LFWZONE="$(ipaddr_firewall_zone_get "$LIPADDR")"
		fi

		[ $(firewall-cmd --zone=${LFWZONE} --list-all | grep 'services:' | \
			xargs -n 1 | grep -c -E "^${LAPP_NAME}\$") -gt 0 ] && return 1 || return 0

	else
		if [ -z "$LIPADDR" ]; then
			[ $(ufw status | grep -c -E "^${LAPP_NAME}\s+ALLOW\s+Anywhere.*$") -gt 0 ] && return 1 || return 0
		else
			LSUBNET="$(ipaddr_subnet_get "$LIPADDR")"
			[ $(ufw status | grep -c -E "^${LAPP_NAME}\s+ALLOW\s+${LGATEWAY}.*$") -gt 0 ] && return 1 || return 0
		fi
	fi
}

########################################################################################
# iface_firewall_app_open( iface, app_name ) -- opens the firewall for the subnet
#	of the iface for the app.  If the iface is null, then opens the firewall for the app from
#	all subnets, i.e. public.
########################################################################################
iface_firewall_app_open(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIFACE="$1"
	local LAPP_NAME="$2"
	local LFWZONE=
	local LSUBNET=

	if [ $USE_FIREWALLD -gt 0 ]; then
		if [ -z "$LIFACE" ]; then
			LFWZONE='public'
		else
			LFWZONE="$(iface_firewall_zone_get "$LIFACE")"
		fi

		firewall-cmd --permanent --zone=${LFWZONE} --add-service=${LAPP_NAME}
		firewall-cmd --reload

	else
		if [ -z "$LIFACE" ]; then
			ufw allow "$LAPP_NAME"
		else
			LSUBNET="$(iface_subnet_get "$LIFACE")"
		#~  ufw allow from 192.168.0.0/16 to any app <name>
			ufw allow from "$LSUBNET" to any app "$LAPP_NAME"
		fi
	fi

	# If the firewall is still closed for the app..
	if ( iface_firewall_app_check "$LIFACE" "$LAPP_NAME" ); then
		[ $QUIET -lt 1 ] && error_echo "Error: unable to open ${LIFACE} - ${LFWZONE} for ${LAPP_NAME}"
		return 1
	fi

	return 0
}

########################################################################################
# iface_firewall_service_open( iface, app_name ) -- opens the firewall for the subnet
#	of the iface for the service.  If the iface is null, then opens the firewall for
#   the service from all subnets, i.e. public.
########################################################################################
iface_firewall_service_open(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIFACE="$1"
	local LSERVICE="$2"
	local LFWZONE=
	local LSUBNET=

	if [ $USE_FIREWALLD -gt 0 ]; then
		if [ -z "$LIFACE" ]; then
			LFWZONE='public'
		else
			LFWZONE="$(iface_firewall_zone_get "$LIFACE")"
		fi

		firewall-cmd --permanent --zone=${LFWZONE} --add-service=${LSERVICE}
		firewall-cmd --reload

	else
		if [ -z "$LIFACE" ]; then
			ufw allow "$LSERVICE"
		else
			LSUBNET="$(iface_subnet_get "$LIFACE")"
			ufw allow from "$LSUBNET" to any port "$LSERVICE"
		fi
	fi

	# If the firewall is still closed for the app..
	if ( iface_firewall_app_check "$LIFACE" "$LAPP_NAME" ); then
		[ $QUIET -lt 1 ] && error_echo "Error: unable to open ${LIFACE} - ${LFWZONE} for ${LAPP_NAME}"
		return 1
	fi

	return 0
}

########################################################################################
# iface_firewall_app_close( app_name ) -- closes the firewall for the subnet
#	of the iface for the app.  If the iface is null, then closes the firewall
#	for the app from all subnets, i.e. public.
########################################################################################
iface_firewall_app_close(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIFACE="$1"
	local LAPP_NAME="$2"
	local LFWZONE=
	local LSUBNET=
	local LRULE_NUM=

	if [ $USE_FIREWALLD -gt 0 ]; then
		if [ -z "$LIFACE" ]; then
			LFWZONE='public'
		else
			LFWZONE="$(iface_firewall_zone_get "$LIFACE")"
		fi

		firewall-cmd --permanent --zone=${LFWZONE} --remove-service=${LAPP_NAME}
		firewall-cmd --reload
	else
		if [ -z "$LIFACE" ]; then
			#~ find & delete a app rule number:
			LRULE_NUM="$(ufw status numbered | grep -E "^\[[[:digit:]]+\]\s+${LAPP_NAME}\s+ALLOW.*Anywhere.*" | sed -n -e 's/^\[\([[:digit:]]\+\)\].*$/\1/p')"
		else
			LSUBNET="$(iface_subnet_get "$LIFACE")"
			LRULE_NUM="$(ufw status numbered | grep -E "^\[[[:digit:]]+\]\s+${LAPP_NAME}\s+ALLOW.*${LSUBNET}.*" | sed -n -e 's/^\[\([[:digit:]]\+\)\].*$/\1/p')"
		fi
		[ ! -z "$LRULE_NUM" ] && echo 'Y' | ufw delete "$LRULE_NUM"
	fi

	# If the firewall is still closed for the app..
	if ( ! iface_firewall_app_check "$LIFACE" "$LAPP_NAME" ); then
		[ $QUIET -lt 1 ] && error_echo "Error: unable to close ${LIFACE} - ${LFWZONE} for ${LAPP_NAME}"
		return 1
	fi

	return 0
}

########################################################################################
# ipaddr_firewall_app_open( ipaddr, app_name ) -- opens the firewall for the subnet
#	of ipaddr for the app.  If ipaddr is null, then opens the firewall for the app from
#	all subnets, i.e. public.
########################################################################################
ipaddr_firewall_app_open(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIPADDR="$1"
	local LAPP_NAME="$2"
	local LFWZONE=
	local LSUBNET=

	if [ $USE_FIREWALLD -gt 0 ]; then
		if [ -z "$LIPADDR" ]; then
			LFWZONE='public'
		else
			LFWZONE="$(ipaddr_firewall_zone_get "$LIPADDR")"
		fi

		firewall-cmd --permanent --zone=${LFWZONE} --add-service=${LAPP_NAME}
		firewall-cmd --reload

	else
		if [ -z "$LIPADDR" ]; then
			ufw allow "$LAPP_NAME"
		else
			LSUBNET="$(ipaddr_subnet_get "$LIPADDR")"
			ufw allow from "$LSUBNET" to any app "$LAPP"
		fi

	fi

	# If the firewall is still closed for the app..
	if ( ipaddr_firewall_app_check "$LIPADDR" "$LAPP_NAME" ); then
		[ $QUIET -lt 1 ] && error_echo "Error: unable to open ${LIPADDR} - ${LFWZONE} for ${LAPP_NAME}"
		return 1
	fi

	return 0

}

########################################################################################
# ipaddr_firewall_app_close( app_name ) -- closes the firewall for the subnet
#	of the ipaddr for the app.  If the ipaddr is null, then closes the firewall
#	for the app from all subnets, i.e. public.
########################################################################################
ipaddr_firewall_app_close(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIPADDR="$1"
	local LAPP_NAME="$2"
	local LFWZONE=
	local LSUBNET=
	local LRULE_NUM=

	if [ $USE_FIREWALLD -gt 0 ]; then
		if [ -z "$LIPADDR" ]; then
			LFWZONE='public'
		else
			LFWZONE="$(ipaddr_firewall_zone_get "$LIPADDR")"
		fi

		firewall-cmd --permanent --zone=${LFWZONE} --remove-service=${LAPP_NAME}
		firewall-cmd --reload
	else
		if [ -z "$LIPADDR" ]; then
			#~ find & delete a app rule number:
			LRULE_NUM="$(ufw status numbered | grep -E "^\[[[:digit:]]+\]\s+${LAPP_NAME}\s+ALLOW.*Anywhere.*" | sed -n -e 's/^\[\([[:digit:]]\+\)\].*$/\1/p')"
		else
			LSUBNET="$(ipaddr_subnet_get "$LIPADDR")"
			LRULE_NUM="$(ufw status numbered | grep -E "^\[[[:digit:]]+\]\s+${LAPP_NAME}\s+ALLOW.*${LSUBNET}.*" | sed -n -e 's/^\[\([[:digit:]]\+\)\].*$/\1/p')"
		fi
		[ ! -z "$LRULE_NUM" ] && echo 'Y' | ufw delete "$LRULE_NUM"
	fi

	# If the firewall is still closed for the app..
	if ( ! ipaddr_firewall_app_check "$LIPADDR" "$LAPP_NAME" ); then
		[ $QUIET -lt 1 ] && error_echo "Error: unable to close ${LIPADDR} - ${LFWZONE} for ${LAPP_NAME}"
		return 1
	fi

	return 0
}



# echos port/protocol from a named service in /etc/services; returns 0: service exists; 1: service does not exist
firewall_service_portprot_get(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LAPP_NAME="$1"
	local LSERVICES='/etc/services'
	local LPORTSPROTS=

	# Is the app / service present in /etc/services?
	( ! firewall_service_exists $LAPP_NAME ) && return 1

	LPORTSPROTS=$(cat "$LSERVICES" | grep -E "^${LAPP_NAME}\s+" | sed -n -e 's/^[^[:digit:]]\+\([[:digit:]]\+\/[tcudp]\+\).*$/\1/p' | xargs)
	[ ! -z "$LPORTSPROTS" ] && echo $LPORTSPROTS || return 1

	return 0
}


firewall_apps_list(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LOPEN_ONLY=${$:-0}
	if [ $USE_FIREWALLD -gt 0 ]; then
		if [ $LOPEN_ONLY -gt 0 ]; then
			firewall-cmd --list-all-zones | grep 'services:' | sed -n -e 's/\s*services: \(.*\)/\1/p' | xargs -n 1 | sort --unique
		else
			firewall-cmd --get-services | xargs -n 1 | sort --unique
		fi
	elif [ $USE_UFW -gt 0 ]; then
		if [ $LOPEN_ONLY -gt 0 ]; then
			ufw status verbose | grep -v -E 'Logging|Default' | sed -n -e 's/.*(\(.\+\)).*$/\1/p' | sort --unique
		else
			ufw app list | grep -E '^\s+' | xargs -n 1 | sort --unique
		fi
	fi
}


# Returns 0 == service/app not open; 1 == app/service open on firewall..
firewall_app_check(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LAPP_NAME="$1"
	local LPUBLIC=${2:-0}
	local LFWZONE=
	local LSUBNET=
	local LPORTS=
	local LPORT=
	local LRULE_NUM=


	if [ $USE_FIREWALLD -gt 0 ]; then
		if [ $LPUBLIC -gt 0 ]; then
			LFWZONE='public'
		else
			LSWZONE="$(firewall-cmd --get-default-zone)"
		fi

		if [ $(firewall-cmd "--zone=${LFWZONE}" --list-all | grep 'services:' | \
				xargs -n 1 | sort | grep -c -E "^${LAPP_NAME}\$") -gt 0 ]; then
			return 1
		else
			return 0
		fi
	else


		if [ $(ufw status | grep -c -E "^${LAPP_NAME}\s+ALLOW.*\$") -gt 0 ]; then
			return 1

		# See if the app exists in /etc/services
		#~ elif ( firewall_service_exists $LAPP_NAME ); then
			#~ for LPORT in $(firewall_service_portprot_get "$LAPP_NAME")
			#~ do

			#~ done
		#~ else
			#~ return 0
		fi
	fi

}

firewall_app_info(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LAPP_NAME="$1"
	if [ $USE_FIREWALLD -gt 0 ]; then
		firewall-cmd "--info-service=${LAPP_NAME}"
	elif [ $USE_UFW -gt 0 ]; then
		ufw app info "$LAPP_NAME"
	fi
	return $?
}

firewall_app_remove(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LAPP_NAME="$1"
	local LCONF_DIR=
	local LCONF_FILE=
	if [ $USE_FIREWALLD -gt 0 ]; then
		LCONF_DIR='/lib/firewalld/services'
		if [ ! -d "$LCONF_DIR" ]; then
			error_echo "Error: ${LCONF_DIR} not found."
			return 1
		fi
		LCONF_FILE="${LCONF_DIR}/${LAPP_NAME}.xml"
	else
		LCONF_DIR='/etc/ufw/applications.d'
		if [ ! -d "$LCONF_DIR" ]; then
			error_echo "Error: ${LCONF_DIR} not found."
			return 1
		fi
		LCONF_FILE="${LCONF_DIR}/${LAPP_NAME}"
	fi
	if [ -f "$LCONF_FILE" ]; then
		error_echo "Removing firewall application file ${LCONF_FILE}.."
		rm -f "$LCONF_FILE"
		[ $USE_UFW -gt 0 ] && ufw app update all

	else
		error_echo "Error: Firewall application file ${LCONF_FILE} not found.."
	fi

	return 0
}

firewall_port_open(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LPROTOCOL="$1"
	local LPORT="$2"
	local LPARAMS="$3"
	local LPARAM=
	local LFWZONE=
	local LSUBNET=

	[ $USE_FIREWALLD -gt 0 ] && LPORT="${LPORT//:/-}" || LPORT="${LPORT//-/:}"

	if [ -z "$LPARAMS" ]; then
		# Open publically..
		if [ $USE_FIREWALLD -gt 0 ]; then
			LFWZONE='public'
			firewall-cmd "--permanent" "--zone=${LFWZONE}" "--add-port=${LPORT}/${LPROTOCOL}" >/dev/null && echo "Opening ${LFWZONE} for ${LPROTOCOL} port ${LPORT}"
		else
			ufw allow proto "${LPROTOCOL}" to any port "${LPORT}" >/dev/null && echo "Opening Anywhere for ${LPROTOCOL} port ${LPORT}"
		fi
		return $?
	else
		# LPARAMS can be an array of ip addresses or interface devices..
		for LPARAM in $LPARAMS
		do
			if ( ipaddr_is_valid "$LPARAM" ); then
				[ $USE_FIREWALLD -gt 0 ] && LFWZONE="$(ipaddr_firewall_zone_get "$LPARAM")" || LSUBNET="$(ipaddr_subnet_get "$LPARAM")"
			elif (iface_is_valid "$LPARAM" ); then
				[ $USE_FIREWALLD -gt 0 ] && LFWZONE="$(iface_firewall_zone_get "$LPARAM")" || LSUBNET="$(iface_subnet_get "$LPARAM")"
			else
				error_echo "Error: ${LPARAM} is neither an ipaddr or iface."
				continue
			fi

			if [ $USE_FIREWALLD -gt 0 ]; then
				[ ! -z "$LFWZONE" ] && firewall-cmd "--permanent" "--zone=${LFWZONE}" "--add-port=${LPORT}/${LPROTOCOL}" >/dev/null && [ $VERBOSE -gt 0 ] && error_echo "Opening ${LFWZONE} for ${LPROTOCOL} port ${LPORT}"
			else
				[ ! -z "$LSUBNET" ] && ufw allow proto "${LPROTOCOL}" to any port "${LPORT}" from "$LSUBNET" >/dev/null && [ $VERBOSE -gt 0 ] && error_echo "Opening ${LSUBNET} for ${LPROTOCOL} port ${LPORT}"
			fi
		done
	fi
}

firewall_port_close(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LPROTOCOL="$1"
	local LPORT="$2"
	local LPARAMS="$3"
	local LPARAM=
	local LFWZONE=
	local LSUBNET=

	[ $USE_FIREWALLD -gt 0 ] && LPORT="${LPORT//:/-}" || LPORT="${LPORT//-/:}"

	if [ -z "$LPARAMS" ]; then
		# Open publically..
		if [ $USE_FIREWALLD -gt 0 ]; then
			LFWZONE='public'
			firewall-cmd "--permanent" "--zone=${LFWZONE}" "--remove-port=${LPORT}/${LPROTOCOL}" >/dev/null && echo "Closing ${LFWZONE} for ${LPROTOCOL} port ${LPORT}"
		else
			ufw delete allow proto "${LPROTOCOL}" to any port "${LPORT}" >/dev/null && "Closing Anywhere for ${LPROTOCOL} port ${LPORT}"
		fi
		return $?
	else
		# LPARAMS can be an array of ip addresses or interface devices..
		for LPARAM in $LPARAMS
		do
			if ( ipaddr_is_valid "$LPARAM" ); then
				[ $USE_FIREWALLD -gt 0 ] && LFWZONE="$(ipaddr_firewall_zone_get "$LPARAM")" || LSUBNET="$(ipaddr_subnet_get "$LPARAM")"
			elif (iface_is_valid "$LPARAM" ); then
				[ $USE_FIREWALLD -gt 0 ] && LFWZONE="$(iface_firewall_zone_get "$LPARAM")" || LSUBNET="$(iface_subnet_get "$LPARAM")"
			else
				error_echo "Error: ${LPARAM} is neither an ipaddr or iface."
				continue
			fi

			if [ $USE_FIREWALLD -gt 0 ]; then
				[ ! -z "$LFWZONE" ] && firewall-cmd "--permanent" "--zone=${LFWZONE}" "--remove-port=${LPORT}/${LPROTOCOL}" >/dev/null && [ $VERBOSE -gt 0 ] && error_echo "Closing ${LFWZONE} for ${LPROTOCOL} port ${LPORT}"
			else
				[ ! -z "$LSUBNET" ] && ufw delete allow proto "${LPROTOCOL}" to any port "${LPORT}" from "$LSUBNET" >/dev/null && [ $VERBOSE -gt 0 ] && error_echo "Closing ${LSUBNET} for ${LPROTOCOL} port ${LPORT}"
			fi
		done
	fi
}


iface_firewall_zone_get(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIFACE="$1"
	local LFWZONE=

	if [ -z "$LIFACE" ]; then
		LIFACE="$(iface_primary_get)"
	fi

	if [ $USE_FIREWALLD -gt 0 ]; then
		LFWZONE="$(firewall-cmd "--get-zone-of-interface=${LIFACE}" 2>/dev/null)"
		# As of Fedora 33, interfaces & ipaddrs don't seem to have assigned zones
		[ -z "$LFWZONE" ] && LFWZONE="$(firewall-cmd --get-default-zone)"
	fi

	[ $DEBUG -gt 0 ] && error_echo "Firewall zone of ${LIFACE} == ${LFWZONE}"
	echo "$LFWZONE"

}

ipaddr_firewall_zone_get(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIPADDR="$1"
	local LFWZONE=

	if [ -z "$LIPADDR" ]; then
		LIPADDR="$(ipaddress_get)"
	fi

	if [ $USE_FIREWALLD -gt 0 ]; then
		LFWZONE="$(firewall-cmd "--get-zone-of-source=${LIPADDR}" 2>/dev/null)"
		# As of Fedora 33, interfaces & ipaddrs don't seem to have assigned zones
		[ -z "$LFWZONE" ] && LFWZONE="$(firewall-cmd --get-default-zone)"
	fi

	[ $DEBUG -gt 0 ] && error_echo "Firewall zone of ${LIPADDR} == ${LFWZONE}"
	echo "$LFWZONE"

}

########################################################################################
# ifaces_detect()  Re-detect network devices using udev..DEPRECATED??
#########################################################################################
ifaces_detect(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local DEV
	local NETDEVS
	local NETRULES

	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"

	# Only do this on Ubuntu systems..
	if [ $ISFEDORA -gt 0 ]; then
		return 0
	fi

	###################################################################################################
	# Re-detect the nic(s).  If we've cloned this system, make sure the mac address really comes from
	# this system's nic by forcing udev to regenerate the 70-persistent-net.rules file.

	# As of ubuntu 18.04, this rules file is no longer present
	NETRULES='/etc/udev/rules.d/70-persistent-net.rules'
	if [ ! -f "$NETRULES" ]; then
		[ $VERBOSE -gt 0 ] && error_echo "Cannot find network rules file: ${NETRULES}.."
		return 1
	fi

	mv -f "$NETRULES" "${NETRULES}.not"

	if [ $ALL_NICS -gt 0 ]; then
		NETDEVS=$(ls -1 /sys/class/net | sort | egrep -v '^lo$' )
	else
		NETDEVS=$(ls -1 /sys/class/net | sort | egrep -v -m1 '^lo$' )
	fi

	echo -e 'Detecting network devices..'
	for DEV in $NETDEVS
	do
		echo -e "${DEV}.."
		echo add > "/sys/class/net/${DEV}/uevent"
		sleep 1
	done
        sleep 5
	echo ' '

	if [ ! -f "$NETRULES" ]; then
	  [ $VERBOSE -gt 0 ] && error_echo "Warning: udev did not regenerate ${NETRULES} file."
	  [ $VERBOSE -gt 0 ] && error_echo "This file will probably be regenerated upon next boot."
	else
	  [ $VERBOSE -gt 0 ] && echo "New ${NETRULES} file successfully generated.."
	fi

}


########################################################################################
# iface_firewall_port_check [netdev] [udp|tcp] [portno] -- checks the firewall to see if a port is already open
#								   Returns 0 if the port is closed, 1 if open
########################################################################################

iface_firewall_port_check(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIFACE="$1"
	local LPROTOCOL=$2
	local LPORT=$3
	local LFWZONE=
	local LSUBNET=

	if [ ! -z "$LIFACE" ]; then
		iface_is_valid "$LIFACE" || return 1
	fi

	if [ $USE_FIREWALLD -gt 0 ]; then
		# translate colons into hyphens for firewalld port ranges..
		LPORT="${LPORT//:/-}"
		[ ! -z "$LIFACE" ] && LFWZONE="$(iface_firewall_zone_get "$LIFACE")"  || LFWZONE='public'

		[ "$(firewall-cmd "--permanent" "--zone=${LFWZONE}" "--query-port=${LPORT}/${LPROTOCOL}" 2>&1)" = 'yes' ] && return 1 || return 0
	else
		# translate hyphens into colons for ufw port ranges..
		LPORT="${LPORT//-/:}"

		if [ -z "$LIFACE" ]; then
			[ $(ufw status | grep -c -E "^${LPORT}/${LPROTOCOL}\s+ALLOW\s+Anywhere") -gt 0 ] && return 1 || return 0
		else
			LSUBNET="$(iface_subnet_get "$LIFACE")"
			[ $(ufw status | grep -c -E "^${LPORT}/${LPROTOCOL}\s+ALLOW\s+${LSUBNET}") -gt 0 ] && return 1 || return 0
		fi
	fi
}

iface_firewall_port_open(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIFACE="$1"
	local LPROTOCOL=$2
	local LPORT=$3
	local LIPADDR=$4
	local LNETMASK=$5
	local LFWZONE=
	local LSUBNET=


	if ( ! iface_firewall_port_check "$LIFACE" "$LPROTOCOL" "$LPORT" ); then
		error_echo "Error: ${LPORT}/${LPROTOCOL} is already open for ${LIFACE}"
		return 1
	fi

	# Fixup range delimiter
	[ $USE_FIREWALLD -gt 0 ] && LPORT="${LPORT//:/-}" || LPORT="${LPORT//-/:}"

	# Open publically..
	if [ -z "$LIFACE" ]; then
		if [ $USE_FIREWALLD -gt 0 ]; then
			LFWZONE='public'
			[ $QUIET -lt 1 ] && error_echo "Opening ${LFWZONE} for ${LPROTOCOL} port ${LPORT}"
			firewall-cmd "--permanent" "--zone=${LFWZONE}" "--add-port=${LPORT}/${LPROTOCOL}"
		else
			[ $QUIET -lt 1 ] && error_echo "Opening ${LPROTOCOL}:${LPORT} publicly"
			ufw allow proto "${LPROTOCOL}" to any port "${LPORT}" >/dev/null
		fi
		return $?
	fi

	iface_is_valid "$LIFACE" || return 1

	LSUBNET="$(iface_subnet_get "$LIFACE")"

	if [ $USE_FIREWALLD -gt 0 ]; then
		LFWZONE="$(iface_firewall_zone_get "$LIFACE")"
		[ $QUIET -lt 1 ] && error_echo "Opening ${LIFACE} ${LFWZONE} for ${LPROTOCOL} port ${LPORT}"
		firewall-cmd "--permanent" "--zone=${LFWZONE}" "--add-port=${LPORT}/${LPROTOCOL}"
	else
		[ $QUIET -lt 1 ] && error_echo "Opening ${LIFACE} ${LSUBNET} for ${LPROTOCOL} port ${LPORT}"
		[ ! -z "$LSUBNET" ] && ufw allow proto "${LPROTOCOL}" to any port "${LPORT}" from "$LSUBNET" >/dev/null
	fi

}

iface_firewall_port_close(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIFACE="$1"
	local LPROTOCOL=$2
	local LPORT=$3
	local LFWZONE=
	local LSUBNET=

	if [ -z "$LIFACE" ]; then
		LIFACE="$(iface_primary_get)"
	else
		iface_is_valid "$LIFACE"
		# Bad interface name??
		if [ $? -gt 0 ]; then
			exit 1
		fi
	fi

	iface_firewall_port_check "$LIFACE" "$LPROTOCOL" "$LPORT"

	if [ $? -lt 1 ]; then
		LSUBNET="$(iface_subnet_get "$LIFACE")"
		error_echo "${LPROTOCOL} port ${LPORT} not open for ${LIFACE} ${LSUBNET}"
		return 1
	fi

	if [ $USE_FIREWALLD -gt 0 ]; then
		LPORT="${LPORT//:/-}"
		LFWZONE="$(iface_firewall_zone_get "$LIFACE")"
		echo "Closing ${LIFACE} ${LFWZONE} for ${LPROTOCOL} port ${LPORT}"
		firewall-cmd "--permanent" "--zone=${LFWZONE}" "--remove-port=${LPORT}/${LPROTOCOL}"
	else
		LPORT="${LPORT//-/:}"
		LSUBNET="$(iface_subnet_get "$LIFACE")"
		echo "Closing ${LIFACE} ${LSUBNET} for ${LPROTOCOL} port ${LPORT}"
		[ ! -z "$LSUBNET" ] && ufw delete allow proto "${LPROTOCOL}" to any port "${LPORT}" from "$LSUBNET"
	fi

}

########################################################################################
########################################################################################
########################################################################################
########################################################################################
########################################################################################
########################################################################################
########################################################################################

########################################################################################
# ipaddr_firewall_port_check [netdev] [udp|tcp] [portno] -- checks the firewall to see if a port is already open
#								   Returns 0 if the port is closed, 1 if open
########################################################################################

ipaddr_firewall_port_check(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIPADDR="$1"
	local LPROTOCOL=$2
	local LPORT=$3
	local LFWZONE=
	local LSUBNET=


	if [ $USE_FIREWALLD -gt 0 ]; then
		LPORT="${LPORT//:/-}"
		LFWZONE="$(ipaddr_firewall_zone_get "$LIPADDR")"

		if [ "$(firewall-cmd "--permanent" "--zone=${LFWZONE}" "--query-port=${LPORT}/${LPROTOCOL}" 2>&1)" = 'yes' ]; then
			return 1
		else
			return 0
		fi

	else
		# Translate hyphens into colons for ufw port ranges..
		LPORT="${LPORT//-/:}"
		LSUBNET="$(ipaddr_subnet_get "$LIPADDR")"

		#~ echo "^${LPORT}/${LPROTOCOL}\s+ALLOW\s+${LSUBNET}"
		#~ ufw status | grep -E "^${LPORT}/${LPROTOCOL}\s+ALLOW\s+${LSUBNET}"

		if [ $(ufw status | grep -c -E "^${LPORT}/${LPROTOCOL}\s+ALLOW\s+${LSUBNET}") -gt 0 ]; then
			return 1
		else
			return 0
		fi
	fi
}

# A NULL ipaddr will not result in a public open, unlike iface_firewall_port_open()
ipaddr_firewall_port_open(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIPADDR="$1"
	local LPROTOCOL=$2
	local LPORT=$3
	local LFWZONE=
	local LSUBNET=

	if ( ! ipaddr_firewall_port_check "$LIPADDR" "$LPROTOCOL" "$LPORT" ); then
		error_echo "Error: ${LPORT}/${LPROTOCOL} is already open for ${LIPADDR}"
		return 1
	fi

	ipaddr_is_valid "$LIPADDR" || return 1

	LSUBNET="$(ipaddr_subnet_get "$LIPADDR")"

	ipaddr_firewall_port_check "$LIPADDR" "$LPROTOCOL" "$LPORT"

	if [ $? -gt 0 ]; then
		error_echo "${LPROTOCOL} port ${LPORT} already open for ${LSUBNET}"
		return 1
	fi

	if [ $USE_FIREWALLD -gt 0 ]; then
		# translate colons into hyphens for port ranges
		LPORT="${LPORT//:/-}"
		LFWZONE="$(ipaddr_firewall_zone_get "$LIPADDR")"
		[ $QUIET -lt 1 ] && error_echo "Opening ${LSUBNET} ${LFWZONE} for ${LPROTOCOL} port ${LPORT}"
		# firewall-cmd uses hyphens to specify port ranges
		firewall-cmd "--permanent" "--zone=${LFWZONE}" "--add-port=${LPORT}/${LPROTOCOL}"
	else
		# translate hyphens into colons for port ranges
		# for castbridge.., i.e. 49152-49183
		# ufw allow 49152:49183/tcp
		# ufw allow proto tcp to any port 49152:49183 from 192.168.1.0/24
		LPORT="${LPORT//-/:}"
		[ $QUIET -lt 1 ] && error_echo "Opening ${LSUBNET} for ${LPROTOCOL} port ${LPORT}"
		ufw allow proto "${LPROTOCOL}" to any port "${LPORT}" from "$LSUBNET" >/dev/null
	fi

}

ipaddr_firewall_port_close(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LIPADDR="$1"
	local LPROTOCOL="$2"
	local LPORT="$3"
	local LFWZONE=
	local LSUBNET=

	ipaddr_firewall_port_check "$LIPADDR" "$LPROTOCOL" "$LPORT"

	LSUBNET="$(ipaddr_subnet_get "$LIPADDR")"

	if [ $? -lt 1 ]; then
		error_echo "${LPROTOCOL} port ${LPORT} not open for ${LSUBNET}"
		return 1
	fi

	if [ $USE_FIREWALLD -gt 0 ]; then
		LPORT="${LPORT//:/-}"
		LFWZONE="$(ipaddr_firewall_zone_get "$LIPADDR")"
		echo "Closing ${LSUBNET} ${LFWZONE} for ${LPROTOCOL} port ${LPORT}"
		firewall-cmd "--permanent" "--zone=${LFWZONE}" "--remove-port=${LPORT}/${LPROTOCOL}"
	else
		LPORT="${LPORT//-/:}"
		echo "Closing ${LIFACE} ${LSUBNET} for ${LPROTOCOL} port ${LPORT}"
		ufw delete allow proto "${LPROTOCOL}" to any port "${LPORT}" from "$LSUBNET"
	fi

}

######################################################################################################
# conf_dir_create() Creates the service config dir..
######################################################################################################
conf_dir_create(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	local LINST_CONFDIR="${1:-/etc/${INST_NAME}}"

	if [ $NEEDSCONF -lt 1 ]; then
		return 1
	fi

	if [ ! -d "$LINST_CONFDIR" ]; then
		error_echo "Creating config dir ${LINST_CONFDIR}.."
		mkdir -p "$LINST_CONFDIR"
	fi

}

######################################################################################################
# conf_file_remove() Remove the service config dir..
######################################################################################################
conf_dir_remove(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	local LINST_CONFDIR="${1:-/etc/${INST_NAME}}"

	if [ -d "$LINST_CONFDIR" ]; then
		echo "Removing config directory ${LINST_CONFDIR}.."
		rm -Rf "$LINST_CONFDIR"
	fi
}



######################################################################################################
# conf_file_create() Create the service config file..
######################################################################################################
conf_file_create(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	
	local LINST_CONF="$1"
	local LINST_CONFDIR=

	if [ $NEEDSCONF -lt 1 ]; then
		return 1
	fi

	[ -z "$LINST_CONF" ] && LINST_CONF="/etc/${INST_NAME}/${INST_NAME}.conf"

	LINST_CONFDIR="$(dirname "$LINST_CONF")"

	if [ ! -d "$LINST_CONFDIR" ]; then
		mkdir -p "$LINST_CONFDIR"
	fi

	# Make a backup of any pre-existing config file..
	if [ -f "$LINST_CONF" ]; then
		if [ ! -f "${LINST_CONF}.org" ]; then
			cp "$LINST_CONF" "${LINST_CONF}.org"
		fi
		cp "$LINST_CONF" "${LINST_CONF}.bak"
	fi

    echo "Creating config file ${LINST_CONF}.."
    echo "# ${LINST_CONF} -- $(date)" >"$LINST_CONF"

    # The calling script must write the body of the file..

}

######################################################################################################
# conf_file_remove() Remove the service config file..
######################################################################################################
conf_file_remove(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"

	if [ $NEEDSCONF -lt 1 ]; then
		return 1
	fi

	[ -z "$INST_CONF" ] && INST_CONF="/etc/${INST_NAME}/${INST_NAME}.conf"
	CONFIG_FILE_DIR="$(dirname "$INST_CONF")"

	if [ -f "$INST_CONF" ]; then
		echo "Removing config file ${INST_CONF}.."
		rm "$INST_CONF"
	fi

	if [ -d "$CONFIG_FILE_DIR" ]; then
		echo "Removing config directory ${CONFIG_FILE_DIR}.."
		rm -Rf "$CONFIG_FILE_DIR"
	fi
}

######################################################################################################
# service_priority_set() Sets values to run the daemon at a higher/normal priority
######################################################################################################
service_priority_set(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	if [ $NEEDSPRIORITY -gt 0 ]; then
		if [ $USE_UPSTART -gt 0 ]; then
			INST_NICE=-19
			INST_RTPRIO=45
			INST_MEMLOCK='unlimited'
		elif [ $USE_SYSTEMD -gt 0 ]; then
			INST_NICE=-19
			INST_RTPRIO='infinity'
			INST_MEMLOCK='infinity'
		else
			INST_NICE=-19
			INST_RTPRIO=45
			INST_MEMLOCK=
		fi
	else
		INST_NICE=
		INST_RTPRIO=
		INST_MEMLOCK=
	fi

}


######################################################################################################
# is_service( service_name ) -- returns 0 if the service init script exists
######################################################################################################
is_service(){
	local LSERVICE_NAME="$1"
	local LSERVICE_FILE=
	local LUNIT_DIR=

	[ -z "$LSERVICE_NAME" ] && LSERVICE_NAME="$INST_NAME"

	if [ $USE_SYSTEMD -gt 0 ]; then
		# Likely places to find unit files..
		for LUNIT_DIR in '/lib/systemd/system' '/etc/systemd/system'
		do
			LSERVICE_FILE="${LUNIT_DIR}/${LSERVICE_NAME}.service"
			if [ -f "$LSERVICE_FILE" ]; then
				systemctl is-active --quiet "$LSERVICE_FILE" && return 0 || return 1
			fi
		done
		return 1
	elif [ $USE_UPSTART -gt 0 ]; then
		LSERVICE_FILE="/etc/init/${LSERVICE_NAME}.conf"
	else
		if [ $IS_DEBIAN -gt 0 ]; then
			LSERVICE_FILE="/etc/init.d/${LSERVICE_NAME}"
		else
			LSERVICE_FILE="/etc/rc.d/init.d/${LSERVICE_NAME}"
		fi
	fi

	[ -f "${LSERVICE_FILE}" ] && return 0 || return 1

}

######################################################################################################
# service_create() Create the service init file..
######################################################################################################
service_create(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"

	if [ $USE_SYSV -eq 0 ]; then
		error_echo "${FUNCNAME}( $@ ) sysv_init_file_create is deprecated.  Use systemd"
	fi

	if [ $USE_UPSTART -gt 0 ]; then
		error_echo "${FUNCNAME}( $@ ) upstart_conf_file_create is deprecated.  Use systemd"
	elif [ $USE_SYSTEMD -gt 0 ]; then
		systemd_unit_file_create $@
	else
		error_echo "${FUNCNAME}( $@ ) Use of sysv is depricated. User systemd."
	fi

	service_debug_create $@

}

######################################################################################################
# service_tmpfiles_create() Create the run-time directories / tmp files
######################################################################################################
service_tmpfiles_create(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"

	if [ $USE_UPSTART -gt 0 ]; then
		error_echo "${FUNCNAME}( $@ ) upstart_tmpfiles_create not implimented."
	elif [ $USE_SYSTEMD -gt 0 ]; then
		systemd_tmpfilesd_conf_create $@
	else
		error_echo "${FUNCNAME}( $@ ) sysv_tmpfiles_create not implimented."
	fi

}

######################################################################################################
# service_tmpfiles_create() Create the run-time directories / tmp files
######################################################################################################
service_tmpfiles_remove(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"

	if [ $USE_UPSTART -gt 0 ]; then
		error_echo "${FUNCNAME}( $@ ) upstart_tmpfiles_create not implimented."
	elif [ $USE_SYSTEMD -gt 0 ]; then
		systemd_tmpfilesd_conf_remove
	else
		error_echo "${FUNCNAME}( $@ ) sysv_tmpfiles_create not implimented."
	fi

}


######################################################################################################
# service_prestart_set() Update service init file with prestart args..
######################################################################################################
service_prestart_set(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"

	if [ $USE_UPSTART -gt 0 ]; then
		error_echo "${FUNCNAME}( $@ ) upstart_conf_file_prestart_set $@ not implimented."
	elif [ $USE_SYSTEMD -gt 0 ]; then
		systemd_unit_file_prestart_set $@
	else
		error_echo "${FUNCNAME}( $@ ) sysv_init_file_create $@ not implimented."
	fi

}

######################################################################################################
# service_fork_set() Update service init file with forking type..
######################################################################################################
service_fork_set(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"

	if [ $USE_UPSTART -gt 0 ]; then
		upstart_conf_file_fork_set $@
	elif [ $USE_SYSTEMD -gt 0 ]; then
		systemd_unit_file_fork_set
	else
		sysv_init_file_create $@
	fi

}


######################################################################################################
# service_start_after_set() Set the service to start after another service..
######################################################################################################
service_start_after_set(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	if [ $USE_UPSTART -gt 0 ]; then
		upstart_conf_file_start_after_set $@
	elif [ $USE_SYSTEMD -gt 0 ]; then
		systemd_unit_file_start_after_set $@
	else
		sysv_init_file_start_after_set $@
	fi
}

######################################################################################################
# service_debug_create() Create a bash script for debugging the service
######################################################################################################
service_debug_create(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	EXEC_ARGS="$@"
	DEBUG_SCRIPT="${INST_BIN}_debug.sh"

	if [ $IS_DEBIAN -gt 0 ]; then
		INST_ENVFILE="/etc/default/${INST_NAME}"
	else
		INST_ENVFILE="/etc/sysconfig/${INST_NAME}"
	fi

	echo "Creating ${DEBUG_SCRIPT}"

cat >"$DEBUG_SCRIPT" <<DEBUG_SCR1;
#!/bin/bash

. ${INST_ENVFILE}

PID_DIR="\$(dirname "$INST_PID")"
if [ ! -d "\$PID_DIR" ]; then
	mkdir -p "\$PID_DIR"
fi
chown -R "${INST_USER}:${INST_GROUP}" "\$PID_DIR"

LOG_DIR="\$(dirname "$INST_LOGFILE")"
if [ ! -d "\$LOG_DIR" ]; then
	mkdir -p "\$LOG_DIR"
fi

DEBUG_LOG="${LOG_DIR}/${INST_NAME}_debug.log"

date >"\$DEBUG_LOG"

chown -R "${INST_USER}:${INST_GROUP}" "\$LOG_DIR"

echo "Starting ${INST_DESC} and writing output to \${DEBUG_LOG}"

sudo -u "$INST_USER" ${INST_BIN} ${EXEC_ARGS} >"\$DEBUG_LOG" 2>&1 &
tail -f "\$DEBUG_LOG"

DEBUG_SCR1
chmod 755 "$DEBUG_SCRIPT"
}

######################################################################################################
# service_debug_remove() Remove the bash debugging script
######################################################################################################
service_debug_remove(){
	DEBUG_SCRIPT="${INST_BIN}_debug.sh"
	if [ -f "$DEBUG_SCRIPT" ]; then
		echo "Removing ${DEBUG_SCRIPT}"
		rm "${DEBUG_SCRIPT}"
	fi
}

######################################################################################################
# service_update() Update the service script
######################################################################################################
service_update(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	if [ $USE_UPSTART -gt 0 ]; then
		upstart_conf_file_create $@
	elif [ $USE_SYSTEMD -gt 0 ]; then
		systemd_unit_file_create $@
	else
		sysv_init_file_create $@
	fi

	service_debug_create $@
}

######################################################################################################
# service_enable() Enable the service control links..
######################################################################################################
service_enable(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"

	if [ $USE_UPSTART -gt 0 ]; then
		sysv_init_file_disable $@
		upstart_conf_file_enable $@
	elif [ $USE_SYSTEMD -gt 0 ]; then
		sysv_init_file_disable $@
		systemd_unit_file_enable $@
	else
		sysv_init_file_enable $@
	fi

	return $?

}

######################################################################################################
# service_disable() Disable the service, i.e. prevent it from autostarting..
######################################################################################################
service_disable(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"

	if [ $REMOVEALL -gt 0 ]; then
		upstart_conf_file_disable $@
		systemd_unit_file_disable $@
		sysv_init_file_disable $@
	else
		if [ $USE_UPSTART -gt 0 ]; then
			upstart_conf_file_disable $@
		elif [ $USE_SYSTEMD -gt 0 ]; then
			systemd_unit_file_disable $@
		else
			sysv_init_file_disable $@
		fi
	fi

}

######################################################################################################
# service_remove() Uninstall the service and remove all scripts, config files, etc.
######################################################################################################
service_remove(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"

	service_stop $@
	service_disable $@

	if [ $REMOVEALL -gt 0 ]; then
		upstart_conf_file_remove $@
		systemd_unit_file_remove $@
		sysv_init_file_remove $@
	else
		if [ $USE_UPSTART -gt 0 ]; then
			upstart_conf_file_remove $@
		elif [ $USE_SYSTEMD -gt 0 ]; then
			systemd_unit_file_remove $@
		else
			sysv_init_file_remove $@
		fi
	fi

	service_debug_remove $@

	return $?
}

######################################################################################################
# service_start() Start the service..
######################################################################################################
service_start() {
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	local LSERVICE="$1"

	if [ -z "$LSERVICE" ]; then
		LSERVICE="$INST_NAME"
	fi

	error_echo "Starting ${LSERVICE} service.."

	if [ $USE_UPSTART -gt 0 ]; then
		initctl start "$LSERVICE" >/dev/null 2>&1
	elif [ $USE_SYSTEMD -gt 0 ]; then
		if [ $(echo "$LSERVICE" | grep -c -e '.*\..*') -lt 1 ]; then
			LSERVICE="${LSERVICE}.service"
		fi
		systemctl restart "$LSERVICE" >/dev/null 2>&1
	else
		if [ $IS_DEBIAN -gt 0 ]; then
			service "$LSERVICE" start >/dev/null 2>&1
		else
			"/etc/rc.d/init.d/${LSERVICE}" start >/dev/null 2>&1
		fi
	fi
	return $?
}

######################################################################################################
# service_start_at( startdatetime | numseconds ) Start the service at a set time or number of seconds in the future..
######################################################################################################
service_start_at() {
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LSERVICE="$1"
	local LWAIT="$2"
	local LSTARTTIME=
	local LSTARTDATE=
	
	# Clear out old dead one-off timers..
	systemctl daemon-reload
	
	# Get a random number of seconds between 1 & 10 minutes.
	if [ -z "$LWAIT" ]; then
		LWAIT=$(random_get 1 600)
	fi
	
	# Is this a valid date string?
	systemd-analyze calendar "$LWAIT" >/dev/null 2>&1
	if [ $? -gt 0 ]; then
		# LWAIT is a valid date string
		LSTARTTIME="$LWAIT"
	else
		# LWAIT is a number of seconds
		LSTARTTIME="$(date -d "+${LWAIT} sec" '+%Y-%m-%d %H:%M:%S')"
	fi
	
	LSTARTDATE="$(systemd-analyze calendar "$LWAITSECS" | sed -n -e 's/^\s\+Next elapse: \(.*\)$/\1/p')"

	log_msg "Scheduling ${LSERVICE} to restart at ${LSTARTDATE}.."

	[ $TEST_ONLY -lt 1 ] && systemd-run --on-calendar "$LSTARTTIME" systemctl restart "$LSERVICE"
	
	return $?
}



######################################################################################################
# service_stop() Stop the service..
######################################################################################################
service_stop() {
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	local LSERVICE="$1"

	if [ -z "$LSERVICE" ]; then
		LSERVICE="$INST_NAME"
	fi

	error_echo "Stopping ${LSERVICE} service.."

	if [ $USE_UPSTART -gt 0 ]; then
		initctl stop "$LSERVICE" >/dev/null 2>&1
	elif [ $USE_SYSTEMD -gt 0 ]; then
		if [ $(echo "$LSERVICE" | grep -c -e '.*\..*') -lt 1 ]; then
			LSERVICE="${LSERVICE}.service"
		fi
		systemctl stop "$LSERVICE" >/dev/null 2>&1
	else
		if [ $IS_DEBIAN -gt 0 ]; then
			"/etc/init.d/${LSERVICE}" stop >/dev/null 2>&1
		else
			"/etc/rc.d/init.d/${LSERVICE}" stop >/dev/null 2>&1
		fi
	fi

	return $?
}

######################################################################################################
# service_status() Get the status of the service..
######################################################################################################
service_status() {
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	local LSERVICE="$1"

	if [ -z "$LSERVICE" ]; then
		LSERVICE="$INST_NAME"
	fi

	if [ $USE_UPSTART -gt 0 ]; then
		# returns 0 if running, 1 if unknown job
		initctl status "$LSERVICE"
	elif [ $USE_SYSTEMD -gt 0 ]; then
		if [ $(echo "$LSERVICE" | grep -c -e '.*\..*') -lt 1 ]; then
			LSERVICE="${LSERVICE}.service"
		fi
		# returns 0 if service running; returns 3 if service is stopped, dead or not installed..
		systemctl --no-pager status "$LSERVICE"
	else
		# returns 0 if service is running, returns 1 if unrecognized service
		if [ $IS_DEBIAN -gt 0 ]; then
			service "$LSERVICE" status
		else
			"/etc/rc.d/init.d/${LSERVICE}" status
		fi
	fi
	return $?
}

######################################################################################################
# systemd_tmpfilesd_conf_create() Create the systemd-tmpfiles conf file.  Call with execution args in a string
# systemd_tmpfilesd_conf_create 'd' servicename 0750 username usergroup age
######################################################################################################
systemd_tmpfilesd_conf_create(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local L_TYPE="$1"
	local L_INST_NAME="$2"
	local L_MODE="$3"
	local L_UID="$4"
	local L_GID="$5"
	local L_AGE="$6"

	# Strip any path info from L_INST_NAME
	L_INST_NAME="${L_INST_NAME##*/}"

	local LCONF_FILE="/usr/lib/tmpfiles.d/${INST_NAME}.tmpfile.conf"
	local L_DATA=
    echo "Creating systemd-tempfiles conf file ${LCONF_FILE}.."

	# #Type Path        Mode UID      GID      Age Argument
	# d /var/run/lighttpd 0750 www-data www-data 10d -
	L_DATA="$(printf "%s /var/run/%s %s %s %s %s -" "$L_TYPE" "$L_INST_NAME" "$L_MODE" "$L_UID" "$L_GID" "$L_AGE")"

    if [ $DEBUG -gt 0 ]; then
		echo "      L_TYPE = ${L_TYPE}"
		echo " L_INST_NAME = ${L_INST_NAME}"
		echo "      L_MODE = ${L_MODE}"
		echo "       L_UID = ${L_UID}"
		echo "       L_GID = ${L_GID}"
		echo "       L_AGE = ${L_AGE}"
		echo "$L_DATA"
	fi

	if [ ! -z "$L_DATA" ]; then
		echo '#Type Path        Mode UID      GID      Age Argument' >"$LCONF_FILE"
		echo "$L_DATA" >>"$LCONF_FILE"
	fi
	if [ ! -f "$LCONF_FILE" ]; then
		error_echo "ERROR: Could not create ${LCONF_FILE}"
		return 1
	fi
}

######################################################################################################
# systemd_tmpfilesd_conf_remove() Remove the systemd-tmpfiles conf file.
######################################################################################################
systemd_tmpfilesd_conf_remove(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LSERVICE="$1"

	if [ -z "$LSERVICE" ]; then
		LSERVICE="$INST_NAME"
	fi

	local LCONF_FILE="/usr/lib/tmpfiles.d/${LSERVICE}.tmpfile.conf"
	if [ -f "$LCONF_FILE" ]; then
		echo "Removing systemd-tempfiles conf file ${LCONF_FILE}.."
		rm -f "$LCONF_FILE"
	fi
}

######################################################################################################
# systemd_unit_file_create() Create the systemd unit file.  Call with execution args in a string
######################################################################################################
systemd_unit_file_create(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LUNIT="$1"
	local LEXEC_ARGS="${@:2}"
	local LUNIT_FILE=
	local LSZDATE=
	
	# Is the 1st string in LUNIT an executable? If so, then LUNIT must be inferred..
	#~ if [ ${LUNIT:0:1} = '/' ]
	if [ -x $(echo "$LUNIT" | awk '{ print $1 }') ]; then
		LUNIT="$INST_NAME"
		LEXEC_ARGS="$@"
	fi

	[ $(echo "$LUNIT" | grep -c '.service') -lt 1 ] && LUNIT="${LUNIT}.service"

	if [ $(echo "$INST_NAME" | grep -c -e '.*\..*') -gt 0 ]; then
		LUNIT="$INST_NAME"
	else
		LUNIT="${INST_NAME}.service"
	fi
	
	LUNIT_FILE="/lib/systemd/system/${LUNIT}"
    error_echo "Creating systemd unit file ${LUNIT_FILE}.."

	# Make a backup..
	if [ -f "$LUNIT_FILE" ]; then
		if [ ! -f "${LUNIT_FILE}.org" ]; then
			cp -p "$LUNIT_FILE" "${LUNIT_FILE}.org"
		fi
		cp -p "$LUNIT_FILE" "${LUNIT_FILE}.bak"
	fi


    LSZDATE="$(date)"

	if [ $IS_DEBIAN -gt 0 ]; then
		INST_ENVFILE="/etc/default/${INST_NAME}"
	else
		INST_ENVFILE="/etc/sysconfig/${INST_NAME}"
	fi

cat >"$LUNIT_FILE" <<SYSTEMD_SCR1;
## ${LUNIT_FILE} -- ${LSZDATE}
## systemctl service unit file

[Unit]
Description=$INST_DESC
After=network-online.target

[Service]
#UMask=002
Nice=${INST_NICE}
LimitRTPRIO=${INST_RTPRIO}
LimitMEMLOCK=${INST_MEMLOCK}
EnvironmentFile=${INST_ENVFILE}
RuntimeDirectory=${INST_NAME}
#WorkingDirectory=${INST_NAME}
Type=simple
User=${INST_USER}
Group=${INST_GROUP}
ExecStartPre=${INST_PRE_EXEC_ARGS}
ExecStart=${INST_BIN} ${LEXEC_ARGS}
PIDFile=${INST_PID}
RestartSec=5
Restart=on-failure

[Install]
WantedBy=multi-user.target

SYSTEMD_SCR1

	# If no pid file, remove the reference..
	if [ -z "$INST_PID" ]; then
		sed -i '/PIDFile=/d' "$LUNIT_FILE"
	fi

	# If no prestart args, remove the reference..
	if [ -z "$INST_PRE_EXEC_ARGS" ]; then
		sed -i '/ExecStartPre=/d' "$LUNIT_FILE"
	fi


	systemd_unit_file_startas_set

	systemd_unit_file_priority_set



	return 0
}

######################################################################################################
# systemd_unit_file_pidfile_set() Insert or update the PIDFile path
######################################################################################################
systemd_unit_file_pidfile_set(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LUNIT=
	local LUNIT_FILE=
	local L_INST_NAME=
	local L_PIDFILE=

	if [ $(echo "$INST_NAME" | grep -c -e '.*\..*') -gt 0 ]; then
		LUNIT="$INST_NAME"
	else
		LUNIT="${INST_NAME}.service"
	fi
	LUNIT_FILE="/lib/systemd/system/${LUNIT}"

	L_INST_NAME="$(echo "$INST_NAME" | sed -e 's/^\(.*\)\..*$/\1/')"

	L_PIDFILE="/var/run/${L_INST_NAME}/${L_INST_NAME}.pid"

# [Service]
# RuntimeDirectory=squeezelite
# PIDFile=/var/run/squeezelite/squeezelite.pid

    if [ -f "$LUNIT_FILE" ]; then

		if [ $(grep -c -E 'PIDFile=.*$' "$LUNIT_FILE") -gt 0 ]; then
			echo "Changing ${LUNIT_FILE} PIDFile to ${L_PIDFILE}"
			sed -i "s/^PIDFile=.*\$/PIDFile=${L_PIDFILE}/" "$LUNIT_FILE"
		else
			echo "Inserting \"PIDFile=${L_PIDFILE}\" into ${LUNIT_FILE}.."
			#~ sed -i "0,/^\[Service\].*\$/s//\[Service\]\PIDFile=${L_PIDFILE}/" "$LUNIT_FILE"
			sed -i "0,/^\[Service\].*\$/s##\[Service\]\nPIDFile=${L_PIDFILE}#" "$LUNIT_FILE"
		fi

	fi
}

######################################################################################################
# systemd_unit_file_pidfile_remove() Insert or update the PIDFile path
######################################################################################################
systemd_unit_file_pidfile_remove(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	if [ $(echo "$INST_NAME" | grep -c -e '.*\..*') -gt 0 ]; then
		UNIT="$INST_NAME"
	else
		UNIT="${INST_NAME}.service"
	fi
	UNIT_FILE="/lib/systemd/system/${UNIT}"

    if [ -f "$UNIT_FILE" ]; then
		if [ $(grep -c -E '^PIDFile.*$' "$UNIT_FILE") -gt 0 ]; then
			echo "Deleting ${UNIT_FILE} PIDFile"
			sed -i '/^PIDFile.*$/d' "$UNIT_FILE"
		fi
	fi

}

######################################################################################################
# systemd_unit_file_runtimedir_set() Insert or update the RuntimeDirectory path
######################################################################################################
systemd_unit_file_runtimedir_set(){
	if [ $(echo "$INST_NAME" | grep -c -e '.*\..*') -gt 0 ]; then
		UNIT="$INST_NAME"
	else
		UNIT="${INST_NAME}.service"
	fi
	UNIT_FILE="/lib/systemd/system/${UNIT}"

	local L_INST_NAME="$(echo "$INST_NAME" | sed -e 's/^\(.*\)\..*$/\1/')"

# [Service]
# RuntimeDirectory=squeezelite
# PIDFile=/var/run/squeezelite/squeezelite.pid

    if [ -f "$UNIT_FILE" ]; then

		if [ $(grep -c -E 'RuntimeDirectory=.*$' "$UNIT_FILE") -gt 0 ]; then
			echo "Changing ${UNIT_FILE} RuntimeDirectory to ${L_INST_NAME}"
			sed -i "s/^RuntimeDirectory=.*\$/RuntimeDirectory=${L_INST_NAME}/" "$UNIT_FILE"
		else
			echo "Inserting \"RuntimeDirectory=${L_INST_NAME}\" into ${UNIT_FILE}.."
			sed -i "0,/^\[Service\].*\$/s//\[Service\]\nRuntimeDirectory=${L_INST_NAME}/" "$UNIT_FILE"
		fi
	fi

}

######################################################################################################
# systemd_unit_file_runtimedir_remove() Delete the RuntimeDirectory path
######################################################################################################
systemd_unit_file_runtimedir_remove(){
	if [ $(echo "$INST_NAME" | grep -c -e '.*\..*') -gt 0 ]; then
		UNIT="$INST_NAME"
	else
		UNIT="${INST_NAME}.service"
	fi
	UNIT_FILE="/lib/systemd/system/${UNIT}"

    if [ -f "$UNIT_FILE" ]; then
		# Delete any existing RuntimeDirectory
		if [ $(grep -c -E '^RuntimeDirectory.*$' "$UNIT_FILE") -gt 0 ]; then
			echo "Deleting ${UNIT_FILE} RuntimeDirectory"
			sed -i '/^RuntimeDirectory.*$/d' "$UNIT_FILE"
		fi
	fi

}

######################################################################################################
# systemd_unit_file_workingdir_set() Insert or update the WorkingDirectory path
######################################################################################################
systemd_unit_file_workingdir_set(){
	if [ $(echo "$INST_NAME" | grep -c -e '.*\..*') -gt 0 ]; then
		UNIT="$INST_NAME"
	else
		UNIT="${INST_NAME}.service"
	fi
	UNIT_FILE="/lib/systemd/system/${UNIT}"

	local L_INST_NAME="$(echo "$INST_NAME" | sed -e 's/^\(.*\)\..*$/\1/')"
	local L_WORKINGDIR="/var/run/${L_INST_NAME}"


# [Service]
# WorkingDirectory=/var/run/squeezelite

    if [ -f "$UNIT_FILE" ]; then

		if [ $(grep -c -E 'WorkingDirectory=.*$' "$UNIT_FILE") -gt 0 ]; then
			echo "Changing ${UNIT_FILE} WorkingDirectory to ${L_INST_NAME}"
			sed -i "s/^WorkingDirectory=.*\$/WorkingDirectory=${L_WORKINGDIR}/" "$UNIT_FILE"
		else
			echo "Inserting \"WorkingDirectory=${L_WORKINGDIR}\" into ${UNIT_FILE}.."
			#~ sed -i "0,/^\[Service\].*\$/s//\[Service\]\nRestart=${TYPE_ARGS}/" "$UNIT_FILE"
			#~ sed -i "0,/^\[Service\].*\$/s//\[Service\]\WorkingDirectory=${L_WORKINGDIR}/" "$UNIT_FILE"
			sed -i "0,/^\[Service\].*\$/s##\[Service\]\nWorkingDirectory=${L_WORKINGDIR}#" "$UNIT_FILE"

		fi
	fi

}

######################################################################################################
# systemd_unit_file_runtimedir_remove() Delete the RuntimeDirectory path
######################################################################################################
systemd_unit_file_workingdir_remove(){
	if [ $(echo "$INST_NAME" | grep -c -e '.*\..*') -gt 0 ]; then
		UNIT="$INST_NAME"
	else
		UNIT="${INST_NAME}.service"
	fi
	UNIT_FILE="/lib/systemd/system/${UNIT}"

    if [ -f "$UNIT_FILE" ]; then
		# Delete any existing WorkingDirectory
		if [ $(grep -c -E '^WorkingDirectory.*$' "$UNIT_FILE") -gt 0 ]; then
			echo "Deleting ${UNIT_FILE} WorkingDirectory"
			sed -i '/^WorkingDirectory.*$/d' "$UNIT_FILE"
		fi
	fi
}

######################################################################################################
# systemd_unit_file_prestart_set() Insert or update the pre-start command
######################################################################################################
systemd_unit_file_prestart_set(){
	EXEC_ARGS="$@"

	if [ $(echo "$EXEC_ARGS" | grep -c -E '^[-@:!+]') -lt 1 ]; then
		EXEC_ARG="-${EXEC_ARGS}"
	fi

	if [ $(echo "$INST_NAME" | grep -c -e '.*\..*') -gt 0 ]; then
		UNIT="$INST_NAME"
	else
		UNIT="${INST_NAME}.service"
	fi
	UNIT_FILE="/lib/systemd/system/${UNIT}"

    if [ -f "$UNIT_FILE" ]; then
		# Delete any existing ExecStartPre
		if [ $(grep -c -E '^ExecStartPre.*$' "$UNIT_FILE") -gt 0 ]; then
			echo "Deleting ${UNIT_FILE} ExecStartPre"
			sed -i '/^ExecStartPre.*$/d' "$UNIT_FILE"
		fi

		# Add in the prestart..
		if [ ! -z "$EXEC_ARGS" ]; then
			# Escape the args..
			EXEC_ARGS="$(echo "$EXEC_ARGS" | sed -e 's/[\/&]/\\&/g')"
			echo "Setting ${UNIT_FILE} ExecStartPre=-${EXEC_ARGS}"
			#~ ExecStartPre=-/bin/rm -f /etc/apcupsd/powerfail
			sed -i -e "s/^ExecStart.*\$/ExecStartPre=${EXEC_ARGS}\n&/" "$UNIT_FILE"
		fi

	fi

}

######################################################################################################
# systemd_unit_file_fork_set() Insert or update the fork type command
######################################################################################################
systemd_unit_file_fork_set(){
	TYPE_ARGS="$@"

	if [ -z "$TYPE_ARGS" ]; then
		TYPE_ARGS='Type=forking'
	fi

	if [ $(echo "$INST_NAME" | grep -c -e '.*\..*') -gt 0 ]; then
		UNIT="$INST_NAME"
	else
		UNIT="${INST_NAME}.service"
	fi
	UNIT_FILE="/lib/systemd/system/${UNIT}"

    if [ -f "$UNIT_FILE" ]; then
		if [ $(grep -c -E '^Type=.*$' "$UNIT_FILE") -gt 0 ]; then
			echo "Changing ${UNIT_FILE} type to ${TYPE_ARGS}"
			sed -i "s/^Type=.*\$/${TYPE_ARGS}/" "$UNIT_FILE"
		else
			echo "Inserting \"${TYPE_ARGS}\" into ${UNIT_FILE}.."
			sed -i "0,/^\[Service\].*\$/s//\[Service\]\n${TYPE_ARGS}/" "$UNIT_FILE"
		fi
	fi
}

######################################################################################################
# systemd_unit_file_restart_set() Insert or update the restart type
######################################################################################################
systemd_unit_file_restart_set(){
	RESTART_ARGS="$@"

	if [ -z "$RESTART_ARGS" ]; then
		RESTART_ARGS='on-failure'
	fi

	if [ $(echo "$INST_NAME" | grep -c -e '.*\..*') -gt 0 ]; then
		UNIT="$INST_NAME"
	else
		UNIT="${INST_NAME}.service"
	fi
	UNIT_FILE="/lib/systemd/system/${UNIT}"

	#Restart=on-failure
	#Restart=on-abort

    if [ -f "$UNIT_FILE" ]; then
		if [ $(grep -c -E '^Restart=.*$' "$UNIT_FILE") -gt 0 ]; then
			echo "Changing ${UNIT_FILE} Restart to ${RESTART_ARGS}"
			sed -i "s/^Restart=.*\$/Restart=${RESTART_ARGS}/" "$UNIT_FILE"
		else
			echo "Inserting \"Restart=${RESTART_ARGS}\" into ${UNIT_FILE}.."
			sed -i "0,/^\[Service\].*\$/s//\[Service\]\nRestart=${TYPE_ARGS}/" "$UNIT_FILE"
		fi
	fi
}

######################################################################################################
# systemd_unit_file_restartsecs_set() Change the restart seconds
######################################################################################################
systemd_unit_file_restartsecs_set(){
	RESTART_ARGS="$@"

	if [ -z "$RESTART_ARGS" ]; then
		RESTART_ARGS='5'
	fi

	if [ $(echo "$INST_NAME" | grep -c -e '.*\..*') -gt 0 ]; then
		UNIT="$INST_NAME"
	else
		UNIT="${INST_NAME}.service"
	fi
	UNIT_FILE="/lib/systemd/system/${UNIT}"

	#RestartSec=60

    if [ -f "$UNIT_FILE" ]; then
		if [ $(grep -c -E '^Restart=.*$' "$UNIT_FILE") -gt 0 ]; then
			echo "Changing ${UNIT_FILE} RestartSec to ${RESTART_ARGS}"
			sed -i "s/^RestartSec=.*\$/Restart=${RESTART_ARGS}/" "$UNIT_FILE"
		else
			echo "Inserting \"RestartSec=${RESTART_ARGS}\" into ${UNIT_FILE}.."
			sed -i "0,/^\[Service\].*\$/s//\[Service\]\nRestartSec=${TYPE_ARGS}/" "$UNIT_FILE"
		fi
	fi
}

######################################################################################################
# systemd_unit_file_bindsto_set() Insert or update the bindsto= value
######################################################################################################
systemd_unit_file_bindsto_set(){
	BINDSTO_ARGS="$@"

	if [ -z "$BINDSTO_ARGS" ]; then
		exit 0
	fi

	if [ $(echo "$INST_NAME" | grep -c -e '.*\..*') -gt 0 ]; then
		UNIT="$INST_NAME"
	else
		UNIT="${INST_NAME}.service"
	fi
	UNIT_FILE="/lib/systemd/system/${UNIT}"

	# [Unit]
	# BindsTo=lms.service

    if [ -f "$UNIT_FILE" ]; then
		if [ $(grep -c -E 'BindsTo=.*$' "$UNIT_FILE") -gt 0 ]; then
			echo "Changing ${UNIT_FILE} BindsTo to ${BINDSTO_ARGS}"
			sed -i "s/^BindsTo=.*\$/BindsTo=${BINDSTO_ARGS}/" "$UNIT_FILE"
		else
			echo "Inserting \"BindsTo=${BINDSTO_ARGS}\" into ${UNIT_FILE}.."
			sed -i "0,/^\[Unit\].*\$/s//\[Unit\]\nBindsTo=${BINDSTO_ARGS}/" "$UNIT_FILE"
		fi
	fi
}

######################################################################################################
# systemd_unit_file_wants_set() Insert or update the wants= value
######################################################################################################
systemd_unit_file_wants_set(){
	WANTS_ARGS="$@"

	if [ -z "$WANTS_ARGS" ]; then
		exit 0
	fi

	if [ $(echo "$INST_NAME" | grep -c -e '.*\..*') -gt 0 ]; then
		UNIT="$INST_NAME"
	else
		UNIT="${INST_NAME}.service"
	fi
	UNIT_FILE="/lib/systemd/system/${UNIT}"

	# [Unit]
	# Wants=squeezelite.service

    if [ -f "$UNIT_FILE" ]; then
		if [ $(grep -c -E 'Wants=.*$' "$UNIT_FILE") -gt 0 ]; then
			echo "Changing ${UNIT_FILE} Wants to ${WANTS_ARGS}"
			sed -i "s/^Wants=.*\$/Wants=${WANTS_ARGS}/" "$UNIT_FILE"
		else
			echo "Inserting \"Wants=${WANTS_ARGS}\" into ${UNIT_FILE}.."
			sed -i "0,/^\[Unit\].*\$/s//\[Unit\]\nWants=${WANTS_ARGS}/" "$UNIT_FILE"
		fi
	fi
}


######################################################################################################
# systemd_unit_file_start_before_set() Insert or update the Before= value
######################################################################################################
systemd_unit_file_start_before_set(){
	BEFORE_ARGS="$@"

	if [ -z "$BEFORE_ARGS" ]; then
		exit 0
	fi

	if [ $(echo "$INST_NAME" | grep -c -e '.*\..*') -gt 0 ]; then
		UNIT="$INST_NAME"
	else
		UNIT="${INST_NAME}.service"
	fi
	UNIT_FILE="/lib/systemd/system/${UNIT}"

	# [Unit]
	# Before=squeezelite.service

    if [ -f "$UNIT_FILE" ]; then
		if [ $(grep -c -E 'Before=.*$' "$UNIT_FILE") -gt 0 ]; then
			echo "Changing ${UNIT_FILE} Before to ${BEFORE_ARGS}"
			sed -i "s/^Before=.*\$/Before=${BEFORE_ARGS}/" "$UNIT_FILE"
		else
			echo "Inserting \"Before=${BEFORE_ARGS}\" into ${UNIT_FILE}.."
			sed -i "0,/^\[Unit\].*\$/s//\[Unit\]\nBefore=${BEFORE_ARGS}/" "$UNIT_FILE"
		fi
	fi
}

######################################################################################################
# systemd_unit_file_start_after_set() Set the start after value
######################################################################################################
systemd_unit_file_start_after_set(){
	START_AFTER="$@"

	if [ $(echo "$INST_NAME" | grep -c -e '.*\..*') -gt 0 ]; then
		UNIT="$INST_NAME"
	else
		UNIT="${INST_NAME}.service"
	fi
	UNIT_FILE="/lib/systemd/system/${UNIT}"
    if [ -f "$UNIT_FILE" ]; then
		#After=network.target mnt-Media.mount
		if [ $(grep -E -i -c "^After=.* *${START_AFTER} *$" "$UNIT_FILE") -gt 0 ]; then
			echo "Changing ${UNIT_FILE} After to ${START_AFTER}"
			sed -i "s/^After=.*\$/After=${START_AFTER}/" "$UNIT_FILE"
		else
			echo "Inserting \"After=${START_AFTER}\" in ${UNIT_FILE}.."
			#~ sed -i -e "s/^After=\(.*\)\$/After=\1 ${START_AFTER}/I" "$UNIT_FILE"
			sed -i -e "s/^After=.*\$/After=${START_AFTER}/I" "$UNIT_FILE"
		fi
	fi
}

######################################################################################################
# systemd_unit_file_startas_set() Comment out or update the systemd startas uid & gid
######################################################################################################
systemd_unit_file_startas_set(){
	if [ $(echo "$INST_NAME" | grep -c -e '.*\..*') -gt 0 ]; then
		UNIT="$INST_NAME"
	else
		UNIT="${INST_NAME}.service"
	fi
	UNIT_FILE="/lib/systemd/system/${UNIT}"
    if [ -f "$UNIT_FILE" ]; then
		echo "Setting \"startas\" in ${UNIT_FILE}.."
		#~ User=lms
		#~ Group=lms
		if [[ -z "$INST_USER" ]] || [[ "$INST_USER" = 'root' ]]; then
			sed -i -e 's/^.*\(User=.*\)$/#\1/' "$UNIT_FILE"
			sed -i -e 's/^.*\(Group=.*\)$/#\1/' "$UNIT_FILE"
		else
			sed -i -e "s/^.*User=.*\$/User=${INST_USER}/" "$UNIT_FILE"
			sed -i -e "s/^.*Group=.*\$/Group=${INST_GROUP}/" "$UNIT_FILE"
		fi
	fi
}

######################################################################################################
# systemd_unit_file_priority_set() Comment out or update the systemd scheduling priority
######################################################################################################
systemd_unit_file_priority_set(){
	if [ $(echo "$INST_NAME" | grep -c -e '.*\..*') -gt 0 ]; then
		UNIT="$INST_NAME"
	else
		UNIT="${INST_NAME}.service"
	fi
	UNIT_FILE="/lib/systemd/system/${UNIT}"
    if [ -f "$UNIT_FILE" ]; then

		echo "Setting scheduling priority in ${UNIT_FILE}.."
		#~ Nice=0
		#~ LimitRTPRIO=infinity
		#~ LimitMEMLOCK=infinity

		# If no rtprio setting, comment the limit out
		if [ -z "$INST_RTPRIO" ]; then
			sed -i -e 's/^\(LimitRTPRIO=.*\)$/#\1/' "$UNIT_FILE"
		else
			sed -i -e "s/^.*LimitRTPRIO=.*\$/LimitRTPRIO=${INST_RTPRIO}/" "$UNIT_FILE"
		fi

		if [ -z "$INST_MEMLOCK" ]; then
			sed -i -e 's/^\(LimitMEMLOCK=.*\)$/#\1/' "$UNIT_FILE"
		else
			sed -i -e "s/^.*LimitMEMLOCK=.*\$/LimitMEMLOCK=${INST_MEMLOCK}/" "$UNIT_FILE"

		fi

		# If no nice setting, comment the niceness out
		if [ -z "$INST_NICE" ]; then
			sed -i -e 's/^\(Nice=.*\)$/#\1/' "$UNIT_FILE"
		else
			sed -i -e "s/^.*Nice=.*\$/Nice=${INST_NICE}/" "$UNIT_FILE"
		fi
	fi
}


######################################################################################################
# systemd_unit_file_logto_set() Set the log stdout & stderr to file value.
# Requires systemd version >= 236
######################################################################################################
systemd_unit_file_logto_set(){
	local LSTDLOGFILE="$1"
	local LERRLOGFILE="$2"
	local LLOG_TYPE=
	local SECTION=
	local ENTRY=

	if [ $(systemctl --version | head -n 1 | awk '{print $2}') -ge 240 ]; then
		LLOG_TYPE='append:'
	else
		LLOG_TYPE='file:'
	fi

	[ $(systemd --version | grep 'systemd' | awk '{print $2}') -ge 240 ] && LLOG_TYPE='append:' || LLOG_TYPE='file:'

	if [ -z "$LERRLOGFILE" ]; then
		LERRLOGFILE="$1"
	fi

	if [ $(echo "$INST_NAME" | grep -c -e '.*\..*') -gt 0 ]; then
		UNIT="$INST_NAME"
	else
		UNIT="${INST_NAME}.service"
	fi
	UNIT_FILE="/lib/systemd/system/${UNIT}"
    if [ -f "$UNIT_FILE" ]; then
		#StandardOutput=file:|append:/var/log/logfile
		if [ $(grep -E -i -c "^StandardOutput=.*$" "$UNIT_FILE") -gt 0 ]; then
			echo "Logging ${UNIT_FILE} StandardOutput to ${LLOGFILE}"
			sed -i "s#^StandardOutput=.*\$#StandardOutput=${LLOG_TYPE}${LLOGFILE}#" "$UNIT_FILE"
		else
			echo "Inserting \"StandardOutput=${LLOG_TYPE}${LLOGFILE}\" into ${UNIT_FILE}.."

			SECTION="Service"
			ENTRY="StandardOutput=${LLOG_TYPE}${LSTDLOGFILE}"
			sed -i -e '/\['$SECTION'\]/{:a;n;/^$/!ba;i\'"$ENTRY"'' -e '}' "$UNIT_FILE"

			#~ sed -i "0,#^\[Service\].*\$#s##\[Service\]\nStandardOutput=file:${LLOGFILE}#" "$UNIT_FILE"
			#~ sed '/^anothervalue=.*/a after=me' test.txt
			#~ sed -i "#^\[Service\].*#a StandardOutput=file:${LLOGFILE}" "$UNIT_FILE"
			#~ sed -i "0,/^\[Unit\].*\$/s//\[Unit\]\nWants=${WANTS_ARGS}/" "$UNIT_FILE"

		fi
		#StandardError=file:|append:/var/log/logfile
		if [ $(grep -E -i -c "^StandardError=.*$" "$UNIT_FILE") -gt 0 ]; then
			echo "Logging ${UNIT_FILE} StandardError to ${LLOGFILE}"
			sed -i "s#^StandardError=.*\$#StandardError=${LLOG_TYPE}${LLOGFILE}#" "$UNIT_FILE"
		else
			echo "Inserting \"StandardError=${LLOG_TYPE}${LLOGFILE}\" into ${UNIT_FILE}.."
			SECTION="Service"
			ENTRY="StandardError=${LLOG_TYPE}${LERRLOGFILE}"
			sed -i -e '/\['$SECTION'\]/{:a;n;/^$/!ba;i\'"$ENTRY"'' -e '}' "$UNIT_FILE"
			#~ sed -i "0,#^\[Service\].*\$#s##\[Service\]\nStandardError=file:${LLOGFILE}#" "$UNIT_FILE"
			#~ sed -i "#^\[Service\].*#a StandardError=file:${LLOGFILE}" "$UNIT_FILE"
		fi
	fi

	touch "$LSTDLOGFILE"
	chown "${INST_USER}:${INST_GROUP}" "$LSTDLOGFILE"
	touch "$LERRLOGFILE"
	chown "${INST_USER}:${INST_GROUP}" "$LERRLOGFILE"
}






######################################################################################################
# systemd_unit_file_Update() Update the systemd unit file with new values
######################################################################################################
systemd_unit_file_update(){
    systemd_unit_file_create $@
}

######################################################################################################
# systemd_unit_file_enable() Enable the systemd service unit file
######################################################################################################
systemd_unit_file_enable(){
	systemctl daemon-reload >/dev/null 2>&1

	local LUNIT="$1"
	local LUNIT_FILE=

	if [ -z "$LUNIT" ]; then
		LUNIT="${INST_NAME}.service"
	fi

	if [ $(echo "$LUNIT" | grep -c -e '.*\..*') -lt 1 ]; then
		LUNIT="${LUNIT}.service"
	fi

	LUNIT_FILE="/lib/systemd/system/${LUNIT}"

	if [ -f "$LUNIT_FILE" ]; then
		echo "Enabling ${LUNIT_FILE} systemd unit file.."

		systemctl stop "$LUNIT" >/dev/null 2>&1
		systemctl enable "$LUNIT" >/dev/null 2>&1
	else
		error_echo "Cannot find ${LUNIT_FILE} systemd unit file.."
	fi
}

systemd_unit_file_start() {
	systemctl daemon-reload >/dev/null 2>&1

	local LUNIT="$1"
	local LUNIT_FILE=

	if [ -z "$LUNIT" ]; then
		LUNIT="${INST_NAME}.service"
	fi

	if [ $(echo "$LUNIT" | grep -c -e '.*\..*') -lt 1 ]; then
		LUNIT="${LUNIT}.service"
	fi

	LUNIT_FILE="/lib/systemd/system/${LUNIT}"
	if [ -f "$LUNIT_FILE" ]; then
		echo "Starting ${LUNIT_FILE} systemd unit file.."

		systemctl start "$LUNIT" >/dev/null 2>&1
		systemctl -l --no-pager status "$LUNIT"
	else
		error_echo "Cannot find ${LUNIT_FILE} systemd unit file.."
	fi
}

systemd_unit_file_stop() {
	local LUNIT="$1"
	local LUNIT_FILE=

	if [ -z "$LUNIT" ]; then
		LUNIT="${INST_NAME}.service"
	fi

	if [ $(echo "$LUNIT" | grep -c -e '.*\..*') -lt 1 ]; then
		LUNIT="${LUNIT}.service"
	fi

	LUNIT_FILE="/lib/systemd/system/${LUNIT}"
	if [ -f "$LUNIT_FILE" ]; then
		error_echo "Stopping ${LUNIT_FILE} systemd unit file.."

		systemctl stop "$LUNIT" >/dev/null 2>&1
		systemctl -l --no-pager status "$LUNIT"
	else
		error_echo "Cannot find ${LUNIT_FILE} systemd unit file.."
	fi
}

systemd_unit_file_status() {
	local LUNIT="$1"
	local LUNIT_FILE=

	if [ -z "$LUNIT" ]; then
		LUNIT="${INST_NAME}.service"
	fi

	if [ $(echo "$LUNIT" | grep -c -e '.*\..*') -lt 1 ]; then
		LUNIT="${LUNIT}.service"
	fi

	LUNIT_FILE="/lib/systemd/system/${LUNIT}"
	if [ -f "$LUNIT_FILE" ]; then
		systemctl -l --no-pager status "$LUNIT"
	else
		error_echo "Cannot find ${LUNIT_FILE} systemd unit file.."
	fi
}


######################################################################################################
# systemd_unit_file_disable() Disable the systemd service unit file
######################################################################################################
systemd_unit_file_disable(){
	if [ $(echo "$INST_NAME" | grep -c -e '.*\..*') -gt 0 ]; then
		UNIT="$INST_NAME"
	else
		UNIT="${INST_NAME}.service"
	fi
	UNIT_FILE="/lib/systemd/system/${UNIT}"
	if [ -f "$UNIT_FILE" ]; then
		echo "Disabling ${UNIT_FILE} systemd unit file.."
		systemctl stop "$UNIT" >/dev/null 2>&1
		systemctl disable "$UNIT" >/dev/null 2>&1
	fi
	systemctl daemon-reload >/dev/null 2>&1
}

######################################################################################################
# systemd_unit_file_remove() Remove the systemd service unit file
######################################################################################################
systemd_unit_file_remove(){
	if [ $(echo "$INST_NAME" | grep -c -e '.*\..*') -gt 0 ]; then
		UNIT="$INST_NAME"
	else
		UNIT="${INST_NAME}.service"
	fi
	UNIT_FILE="/lib/systemd/system/${UNIT}"
	DEBUG_FILE="$(echo "$UNIT_FILE" | sed -e 's#^\(.*\)\.\(.*\)$#\1_debug.\2#')"

	for FILE in "$UNIT_FILE" "$DEBUG_FILE"
	do
		if [ -f "$FILE" ]; then
			echo "Removing ${FILE} systemd unit file.."
			rm "$FILE"
		fi
	done
	systemctl daemon-reload >/dev/null 2>&1
}




######################################################################################################
# upstart_conf_file_enable() Enable the upstart conf file (delete the manual override)
######################################################################################################
upstart_conf_file_enable(){
	INIT_SCRIPT="/etc/init/${INST_NAME}.conf"
	if [ -f "$INIT_SCRIPT" ]; then
		echo "Enabling ${INIT_SCRIPT} upstart conf file.."
	fi
	INIT_OVERRIDE="/etc/init/${INST_NAME}.override"
	if [ -f "$INIT_OVERRIDE" ]; then
		rm "$INIT_OVERRIDE"
	fi
	initctl reload-configuration >/dev/null 2>&1
}

######################################################################################################
# upstart_conf_file_disable() Disable the upstart conf file (create a manual override)
######################################################################################################
upstart_conf_file_disable(){
	INIT_SCRIPT="/etc/init/${INST_NAME}.conf"
	if [ -f "$INIT_SCRIPT" ]; then
		echo "Disabling ${INIT_SCRIPT} upstart conf file.."
		INIT_OVERRIDE="/etc/init/${INST_NAME}.override"
		echo 'manual' >"$INIT_OVERRIDE"
	fi
	initctl reload-configuration >/dev/null 2>&1
}

######################################################################################################
# upstart_conf_file_remove() Remove the upstart conf file
######################################################################################################
upstart_conf_file_remove(){
	INIT_SCRIPT="/etc/init/${INST_NAME}.conf"
	INIT_OVERRIDE="/etc/init/${INST_NAME}.override"
	INIT_DEBUG_SCRIPT="/etc/init/${INST_NAME}_debug.conf"
	INIT_DEBUG_OVERRIDE="/etc/init/${INST_NAME}_debug.override"
	for FILE in "$INIT_SCRIPT" "$INIT_OVERRIDE" "$INIT_DEBUG_SCRIPT" "$INIT_DEBUG_OVERRIDE"
	do
		if [ -f "$FILE" ]; then
			echo "Removing ${FILE} upstart conf file.."
			rm "$FILE"
		fi
	done
	initctl reload-configuration >/dev/null 2>&1
}

######################################################################################################
# sysv_init_file_enable() Update sysv service control links
######################################################################################################
sysv_init_file_enable(){
	if [ $IS_DEBIAN -gt 0 ]; then
		INIT_SCRIPT="/etc/init.d/${INST_NAME}"
	else
		INIT_SCRIPT="/etc/rc.d/init.d/${INST_NAME}"
	fi
	if [ -f "$INIT_SCRIPT" ]; then
		echo "Enabling ${INST_NAME} sysv service control links.."
		if [ $IS_DEBIAN -gt 0 ]; then
			update-rc.d -f "$INST_NAME" remove >/dev/null 2>&1
			update-rc.d -f "$INST_NAME" defaults >/dev/null 2>&1
		else
			chkconfig --del "$INST_NAME" >/dev/null 2>&1
			chkconfig --add "$INST_NAME" >/dev/null 2>&1
			chkconfig --level 35 "$INST_NAME" on >/dev/null 2>&1
		fi
	fi
}

######################################################################################################
# sysv_init_file_disable() Update sysv service control links
######################################################################################################
sysv_init_file_disable(){
	if [ $IS_DEBIAN -gt 0 ]; then
		INIT_SCRIPT="/etc/init.d/${INST_NAME}"
	else
		INIT_SCRIPT="/etc/rc.d/init.d/${INST_NAME}"
	fi
	if [ -f "$INIT_SCRIPT" ]; then
		echo "Disabling ${INST_NAME} sysv service control links.."
		if [ $IS_DEBIAN -gt 0 ]; then
			update-rc.d -f "$INST_NAME" remove >/dev/null 2>&1
		else
			chkconfig --del "$INST_NAME" >/dev/null 2>&1
		fi
	fi
}

sysv_init_file_remove(){
	if [ $IS_DEBIAN -gt 0 ]; then
		INIT_SCRIPT="/etc/init.d/${INST_NAME}"
	else
		INIT_SCRIPT="/etc/rc.d/init.d/${INST_NAME}"
	fi
	if [ -f "$INIT_SCRIPT" ]; then
		echo "Removing ${INIT_SCRIPT} sysv init file"
		rm "$INIT_SCRIPT"
	fi

}

main_disable_service(){
	service_disable
}

main_enable_service(){
	service_enable
}

main_update_service(){

	if [ $FORCE -lt 1 ]; then
		service_is_installed
		if [ $? -gt 0 ]; then
			error_exit "${INST_NAME} is not installed.  Cannot update ${INST_NAME}.."
		fi
	fi

	service_stop
	service_disable

	env_file_update
	env_file_read
	log_dir_update
	service_update

	service_enable
	service_start

}

main_remove_service(){

	if [ $FORCE -lt 1 ]; then
		service_is_installed

		if [ $? -lt 1 ]; then
			error_exit "${INST_NAME} is not installed.  Cannot remove ${INST_NAME}.."
		fi
	fi

	env_file_read
	service_stop
	service_disable
	service_remove
	log_dir_remove
	data_dir_remove
	conf_file_remove
	env_file_remove
	inst_user_remove

	echo "${INST_NAME} is uninstalled."

}

main_install_service(){
	# Get our default values
	service_inst_prep

	# Get the service account
	inst_user_create

	# Create a data dir
	data_dir_create

	# Create a log dir
	log_dir_create
	log_rotate_script_create

	# Create the env var file
	env_file_create

	# Create the config file
	conf_file_create

	# Create the service init script
	service_create

	# Create the service control links..
	service_enable

}

pass_get_root(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	echo " YXJnbGViYXJnbGUK " | openssl enc -base64 -d
}

pass_get_daadmin(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	echo " ZnVmZXJhbAo= " | openssl enc -base64 -d
}

####################################################################################
# ping_wait()  See if an IP is reachable via ping. Returns 0 if the host is reachable
####################################################################################
ping_wait(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"

	local LIP_ADDR="$1"
	local LPING_COUNT=$2
	local i=0

	if [ -z "$LIP_ADDR" ]; then
		return 1
	fi


	if [ -z $LPING_COUNT ]; then
		LPING_COUNT=5
	fi


	for (( i=0; i<$LPING_COUNT; i++ ))
	do
		"$PING_BIN" $PING_OPTS "$LIP_ADDR" > /dev/null 2>&1

		if [ $? -gt 0 ]; then
			if [ $VERBOSE -gt 2 ]; then
				error_echo "${LIP_ADDR} is not ready.."
			fi
			sleep 1
		else
			if [ $VERBOSE -gt 2 ]; then
				error_echo "${LIP_ADDR} is ready.."
			fi
			return 0
		fi
	done

	return 1
}

########################################################################
# is_scserver -- echos 1 if scserver is available on the local subnet
########################################################################
is_scserver() {
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"

	# If we are scserver, return 0 to force downloading zips, rather than fetching from ourselves!
	if [ "$(hostname)" = "$SCSERVER" ]; then
		echo '0'
		return 1
	fi

	ping_wait "$SCSERVER_IP"
	if [ $? -eq 0 ]; then
		echo '1'
		return 0
	else
		echo '0'
		return 1
	fi

	return 0
}

########################################################################
# ami_scserver -- returns 1 if hostname == scserver
########################################################################
ami_scserver(){
	if [ $(hostname | grep -c -i -E '^scserver$') -gt 0 ]; then
		return 1
	fi
	return 0
}

########################################################################
# script_dir_fetch( /scriptdirpath -- copies files from scserver to
#     the scriptdirpath via robocopy|rsync|scp
########################################################################
script_dir_fetch(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LSCRIPTDIR="$1"
	local LTARGETDIR=
	local LUSER=
	local LGROUP=
	local LPASS=
	local LIS_ROOT=0
	local LROBOCOPY="$(which robocopy)"
	local LRSYNC="$(which rsync)"
	local LSCP="$(which scp)"
	local LSSHPASS="$(which sshpass)"
	local LCOPYCMD=
	local LTO_NULL='>/dev/null'

	[ $VERBOSE -gt 0 ] && LTO_NULL=

	if [ -z "$LSCRIPTDIR" ]; then
		error_echo "${FUNCNAME}( $@ ) target script directory name required."
		return 1
	fi

	# Get the password for the SCRIPTDIR
	# We need root for anything off /usr or /var, all else should be daadmin
	if [ $(echo "$LSCRIPTDIR" | grep -c -E '^/usr/.*|^/var/.*') -gt 0 ]; then
		LIS_ROOT=1
		LUSER='root'
		LGROUP=$(id -ng $LUSER)
		LPASS="$(pass_get_root)"
	else
		LIS_ROOT=0
		LUSER='daadmin'
		LGROUP=$(id -ng $LUSER)
		LPASS="$(pass_get_daadmin)"
	fi

	# Setup sshpass
	if [ ! -z "$LSSHPASS" ]; then
		LSSHPASS="${LSSHPASS} -p ${LPASS}"
	fi

	error_echo ' '

	# Change to the target dir..we should NOT need to create the dir as all the zipped scripts include relative paths..
	# Cope with 'Aux' script dirs.  Zip files for Aux dirs won't contain full relative paths..
	if [ $(echo "$LSCRIPTDIR" | grep -c 'Aux') -gt 0 ]; then
		LTARGETDIR="$(echo "$LSCRIPTDIR" | sed -e 's#Aux##')"
	else
		LTARGETDIR="$LSCRIPTDIR"
	fi

	# Create the target directory..
	if [ ! -d "$LTARGETDIR" ]; then
		error_echo "Creating directory ${LTARGETDIR}"
		mkdir -p "$LTARGETDIR"
	fi

	# Construct the COPYCMD using our most capable available utility..
	if [ ! -z "$LROBOCOPY" ]; then
		LCOPYCMD="${LROBOCOPY} --quiet --password=${LPASS} -se ${LUSER}@scserver:${LSCRIPTDIR} ${LTARGETDIR} ${LTO_NULL}"
	elif [ ! -z "$LRSYNC" ]; then
		LCOPYCMD="${LSSHPASS} ${LRSYNC} -avzP ${LUSER}@scserver:${LSCRIPTDIR} ${LTARGETDIR} ${LTO_NULL}"
	elif [ ! -z "$LSCP" ]; then
		LCOPYCMD="${LSSHPASS} ${LSCP} -rp ${LUSER}@scserver:${LSCRIPTDIR} ${LTARGETDIR} ${LTO_NULL}"
	fi

	if [ -z "$LCOPYCMD" ]; then
		error_echo "${FUNCNAME}( $@ ) Error: Could not construct a copy command to fetch from ${LSCRIPTDIR}."
		return 1
	fi

	error_echo "Fetching files for ${LTARGETDIR}"

	eval "$LCOPYCMD"

	error_echo "Making scripts executable in ${LTARGETDIR}.."
	[ $VERBOSE -gt 0 ] && find "$LTARGETDIR" -name '*.sh' -print -exec chmod 755 {} \; || find "$LTARGETDIR" -name '*.sh' -exec chmod 755 {} \;

	# Fixup permissions..
	#~ if [ $(echo "$LTARGETDIR" | grep -c 'lms') -gt 0 ]; then
		#~ LUSER='lms'
		#~ LGROUP=$(id -ng $LUSER)
		#~ error_echo "Fixing up ownership in ${LTARGETDIR} for ${LUSER}:${LGROUP}"
		#~ chown -R "${LUSER}:${LGROUP}" "$LTARGETDIR"
	if [ $LIS_ROOT -lt 1 ]; then
		error_echo "Fixing up ownership in ${LTARGETDIR} for ${LUSER}:${LGROUP}"
		chown -R "${LUSER}:${LGROUP}" "$LTARGETDIR"
	fi

	return 0
}

########################################################################
# domain_check( URL ) -- echos 0 if domain is reachable, otherwise 1
########################################################################
domain_check(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LURL="$1"
	local LHOST=$(echo "$LURL" | sed -n -e 's#^.*://\([^/]\+\)/.*$#\1#p')
	local LRET=
	[ $VERBOSE -gt 0 ] && error_echo "Checking URL ${LURL} for host ${LHOST}"
	#~ host -W 3 "$LHOST"  > /dev/null 2>&1

	LRET=$(host -W 3 "$LHOST"  2>&1 | grep -c -i "host ${LHOST} not found")
	echo "$LRET"

	[ $LRET -gt 0 ] && error_echo "${FUNCNAME} Error: ${LHOST} is not a valid domain."

	return $LRET
}


########################################################################
# script_zip_download( /scriptdirpath ) -- downloads zip files from
#     hegardtfoundation.org and unzips them to the scriptdirpath
########################################################################
script_zip_download(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LSCRIPTDIR="$1"
	local LZIPFILE="$(basename "$LSCRIPTDIR").zip"
	local LTARGETDIR="$(dirname "$LSCRIPTDIR")"
	local LZIPURL=
	local LUSER=
	local LGROUP=
	local LPASS=
	local LIS_ROOT=0
	local LTO_NULL='>/dev/null'

	[ $VERBOSE -gt 0 ] && LTO_NULL=

	if [ -z "$LSCRIPTDIR" ]; then
		error_echo "${FUNCNAME}( $@ ) target script directory name required."
		return 1
	fi

	# Get the password for the SCRIPTDIR
	# We need root for anything off /usr or /var, all else should be daadmin
	if [ $(echo "$LSCRIPTDIR" | grep -c -E '^/usr/.*|^/var/.*') -gt 0 ]; then
		LIS_ROOT=1
		LUSER='root'
		LGROUP=$(id -ng $LUSER)
		LPASS="$(pass_get_root)"
	else
		LIS_ROOT=0
		LUSER='daadmin'
		LGROUP=$(id -ng $LUSER)
		LPASS="$(pass_get_daadmin)"
	fi

	# Change to the target dir..we should NOT need to create the dir as all the zipped scripts include relative paths..
	# Cope with 'Aux' or 'binx86_64' script dirs.  Zip files for Aux dirs won't contain full relative paths..
	if [ $(echo "$LSCRIPTDIR" | grep -c 'Aux') -gt 0 ]; then
		# Aux zips should be downloaded & unzipped in the child dir.
		LTARGETDIR="$(echo "$LSCRIPTDIR" | sed -e 's#Aux##')"
		LSCRIPTDIR="$LTARGETDIR"
	elif [ $(echo "$LSCRIPTDIR" | grep -c $(uname -m)) -gt 0 ]; then
		# bin zips should be downloaded & unzipped in the parent dir.
		# e.g. LSCRIPTDIR = /usr/local/bini686 || /usr/local/binx86_64
		LSCRIPTDIR="$(echo "$LSCRIPTDIR" | sed -e "s#$(uname -m)##")"
		LTARGETDIR="$(dirname "$LSCRIPTDIR")"
	fi

	error_echo "Downloading and installing ${LZIPFILE} to ${LSCRIPTDIR}"

	if [ ! -d "$LSCRIPTDIR" ]; then
		[ $VERBOSE -gt 0 ] && error_echo "Creating directory ${LSCRIPTDIR}"
		mkdir -p "$LSCRIPTDIR"
	fi

	cd "$LTARGETDIR"

	if [ "$LTARGETDIR" != "$(pwd)" ]; then
		error_echo "${FUNCNAME} Error: could not change to ${LTARGETDIR}."
		return 1
	fi

	if [ ! -f "$LZIPFILE" ]; then
		USERAGENT='Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/35.0.1916.153 Safari/537.36'
		LZIPURL="http://www.hegardtfoundation.org/slimstuff/${LZIPFILE}"

		[ $VERBOSE -gt 0 ] && error_echo "Downloading ${LZIPURL} to ${LTARGETDIR}"

		if [ $(domain_check "$LZIPURL") -lt 1 ]; then
			[ $VERBOSE -gt 0 ] && wget -v -U "$USERAGENT" "$LZIPURL" || wget --quiet -U "$USERAGENT" "$LZIPURL"
		fi

		if [ -f "$LZIPFILE" ]; then
			[ $VERBOSE -gt 0 ] && error_echo "Unzipping ${LZIPFILE}"
			[ $VERBOSE -gt 0 ] && unzip -o "$LZIPFILE" || unzip -q -o "$LZIPFILE"
			rm "$LZIPFILE"

			[ $VERBOSE -gt 0 ] && error_echo "Making scripts executable in ${LSCRIPTDIR}.."
			[ $VERBOSE -gt 0 ] && find "$LSCRIPTDIR" -name '*.sh' -print -exec chmod 755 {} \; || find "$LSCRIPTDIR" -name '*.sh' -exec chmod 755 {} \;

			if [ $LIS_ROOT -lt 1 ]; then
				[ $VERBOSE -gt 0 ] && error_echo "Fixing up ownership in ${LSCRIPTDIR} for ${LUSER}:${LGROUP}"
				chown -R "${LUSER}:${LGROUP}" "$LSCRIPTDIR"
			fi

		else
			echo "${FUNCNAME} Error: Could not download ${LZIPFILE}"
		fi
	fi

	return 0
}

########################################################################
# args_clean( args ) -- removes line-feeds from an arg list
########################################################################
args_clean() {
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LARGS="$*"
	LARGS="$(echo "$LARGS" | sed ':a;N;$!ba;s/\n/ /g')"
	echo "$LARGS"
}

########################################################################
# scripts_get( scriptdirs ) -- arbitrates between fetching scripts from
#      scserver or downloading zipfiles from hegardtfoundation.org
########################################################################
scripts_get(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LSCRIPTDIRS="$1"

	# Replace any line-feeds with spaces..
	LSCRIPTDIRS="$(echo "$LSCRIPTDIRS" | sed ':a;N;$!ba;s/\n/ /g')"

	local LDIR=

	local LIS_SCSERVER=$(is_scserver)

	for LDIR in $LSCRIPTDIRS
	do
		if [ $LIS_SCSERVER -gt 0 ]; then
			script_dir_fetch "$LDIR"
		else
			script_zip_download "$LDIR"
		fi
	done

}


