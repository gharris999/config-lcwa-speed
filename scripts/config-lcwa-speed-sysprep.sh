#!/bin/bash
######################################################################################################
# Bash script for preparing a system for the lcwa-speed service.  Modifies hostname, system timezone,
# and for Raspberry Pi systems, modifies locale, keyboard and wifi country settings.
#
# Latest mod: Checks to make sure systemd-timesyncd.service and are enabled and started.  This ensures
#   that the system will have a time-sync.target that the speedtest service waits for before starting.
######################################################################################################
SCRIPT_VERSION=20240207.214316

SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
SCRIPT_NAME="$(basename $0)"
SCRIPT_DESC="Initial system prep: hostname checking, locale settings, TZ setting, user creation, etc."


######################################################################################################
# Include the generic service install functions
######################################################################################################

REC_INCSCRIPT_VER=20240206
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

NO_CHANGE_HOSTNAME=0
NO_CONFIG_KERNELPANIC=0
NEW_HOSTNAME=
UNINSTALL=0
USERS=

KPANIC_OPTS=""

INST_NAME='lcwa-speed'
INST_PROD="LCWA Python3 PPPoE Speedtest Logger"
INST_DESC='LCWA PPPoE Speedtest Logger system prep script'

apt_update(){
	debug_echo "${FUNCNAME}( $@ )"
	
	local MAX_AGE=$((2 * 60 * 60))
	local CACHE_DIR='/var/cache/apt/'
	local CACHE_DATE=$(stat -c %Y "$CACHE_DIR")
	local NOW_DATE=$(date --utc '+%s')
	local CACHE_AGE=$(($NOW_DATE - $CACHE_DATE))
	local SZCACHE_AGE="$(echo "scale=2; (${CACHE_AGE} / 60 / 60)" | bc) hours"
	local LFIX_MISSING=

	if [ $FORCE -gt 0 ] || [ $CACHE_AGE -gt $MAX_AGE ]; then
		[ $CACHE_AGE -gt $MAX_AGE ] && [ $VERBOSE -gt 0 ] && error_echo "Local cache is out of date.  Updating apt-get package cacahe.."
		[ $FORCE -gt 1 ] && LFIX_MISSING='--fix-missing'
		[ $DEBUG -gt 0 ] && apt-get update "$LFIX_MISSING" || apt-get -qq update "$LFIX_MISSING"
	else
		[ $VERBOSE -gt 0 ] && error_echo  "Local apt cache is up to date as of ${SZCACHE_AGE} ago."
	fi
}

############################################################################
# apt_install() -- Installs packages via apt-get without prompting.
############################################################################
apt_install(){
	debug_echo "${FUNCNAME}( $@ )"
	local LPKG_LIST="$@"
	local LPKG=
	local LRET=1
	
	export DEBIAN_FRONTEND=noninteractive
	
	for LPKG in $LPKG_LIST
	do
	
		if [ $(dpkg -s "$LPKG" 2>&1 | grep -c 'Status: install ok installed') -gt 0 ] && [ $FORCE -lt 1 ]; then
			[ $VERBOSE -gt 0 ] && error_echo "Package ${LPKG} already installed.."
			continue
		fi
	
		# Make 3 attempts to install packages.  RPi's package repositories have a tendency to time-out..
		[ $QUIET -lt 1 ] && error_echo "Installing package ${LPKG}.."
		for n in 1 2 3 4 5
		do
			apt-get -y -qq -o Dpkg::Options::="--force-confold" install "$LPKG" >/dev/null 2>&1
			
			LRET=$?
			
			if [ $LRET -gt 0 ]; then
				error_echo "Error installing package ${LPKG}...waiting 10 seconds to try again.."
				debug_pause "${LINENO} -- ${FUNCNAME}() error."
				sleep 10
			else
				break
			fi
		done
	done
	
	debug_pause "${LINENO} -- ${FUNCNAME}() done."
	return $LRET
}

dnf_update(){
	debug_echo "${FUNCNAME}( $@ )"
	[ $QUIET -lt 1 ] && error_echo "Updating dnf package cacahe.."
	[ $TEST -lt 1 ] && dnf -y update
}

dnf_install(){
	debug_echo "${FUNCNAME}( $@ )"
	local LPKG_LIST="$1"
	local LPKG=
	local LRET=1
	
	for LPKG in $LPKG_LIST
	do
		if [ $(dnf --installed list "$LPKG" | grep -v 'Installed' | grep -c "^${LPKG}\..*\$") -gt 0 ]; then
			[ $VERBOSE -gt 0 ] && error_echo "${LPKG} already installed."
			continue
		fi
	
		[ $QUIET -lt 1 ] && error_echo "Installing package ${LPKG}.."
		dnf install -y --allowerasing "$LPKG"
		LRET=$?
	
		if [ $LRET -gt 0 ]; then
			error_echo "${FUNCNAME}() error installing package ${LPKG}."
		fi
	done
	
	debug_echo "${LINENO} -- ${FUNCNAME}() done."
	return $LRET
}

dnf_uninstall(){
	debug_echo "${FUNCNAME}( $@ )"
}


############################################################################
# basic_utils_install() Installs a basic set of utils that may
#  not be included by default in the distro.
############################################################################
basic_utils_install(){
	debug_echo "${FUNCNAME}( $@ )"
	local LRET=1
	local LPKG=
	local LPKG_LIST=				
	#~ LPKG_LIST="$(echo "$LPKG_LIST" | xargs)"
	
	if [ $USE_APT -gt 0 ]; then
		LPKG_LIST=" \
				bc \
				curl \
				dhcping \
				file \
				fping \
				git \
				git-extras \
				gzip \
				jq \
				lynx \
				multitail \
				ntpdate \
				sshpass \
				ufw \
				unzip \
				wget \
				yamllint \
				zip"

				
		is_raspberry_pi && LPKG_LIST="${LPKG_LIST} libatlas-base-dev"
		
		LPKG_LIST="$(echo $LPKG_LIST | xargs)"				
		[ $TEST -lt 1 ] && apt_update
		[ $TEST -lt 1 ] && apt_install $LPKG_LIST
		LRET=$?
	else
		LPKG_LIST=" \
				bc \
				curl \
				dhcping\
				file \
				fping\
				git \
				git-extras \
				gzip \
				jq \
				lynx \
				multitail \
				ntpdate \
				sshpass \
				unzip \
				wget \
				yamllint \
				zip"
				
		LPKG_LIST="$(echo $LPKG_LIST | xargs)"				
		[ $TEST -lt 1 ] && dnf_update
		[ $TEST -lt 1 ] && dnf_install "$LPKG_LIST"
		LRET=$?
	fi
	
	debug_echo " ${FUNCNAME}(): done, returning ${LRET}"
	
	return $LRET
}



# Fixup hostname, /etc/hostname & /etc/hosts with new hostname
hostname_change(){
	debug_echo "${FUNCNAME}( $@ )"

	local LOLDHOSTNAME="$1"
	local LNEWHOSTNAME="$2"

	local LCONFFILE='/etc/hostname'
	local LHOSTSFILE='/etc/hosts'
	local LRET=1

	if [ ! -z "$(which hostnamectl 2>/dev/null)" ]; then
		[ $QUIET -lt 1 ] && error_echo "Changing hostname from ${LOLDHOSTNAME} to ${LNEWHOSTNAME}.."
		hostnamectl set-hostname "$LNEWHOSTNAME"
	fi

	if [ -f "$LCONFFILE" ]; then
		[ $QUIET -lt 1 ] && error_echo "Fixing up ${LCONFFILE} with changed hostname ${LNEWHOSTNAME}.."
		[ ! -f "${LCONFFILE}.org" ] && cp "$LCONFFILE" "${LCONFFILE}.org"
		cp "$LCONFFILE" "${LCONFFILE}.bak"
		sed -i "s/$LOLDHOSTNAME/$LNEWHOSTNAME/g" "$LCONFFILE"
		grep -i "$LNEWHOSTNAME" "$LCONFFILE"
	fi

	if [ -f "$LHOSTSFILE" ]; then
		[ $QUIET -lt 1 ] && error_echo "Fixing up ${LHOSTSFILE} with changed hostname ${LNEWHOSTNAME}.."
		[ ! -f "${LHOSTSFILE}.org" ] && cp "$LHOSTSFILE" "${LHOSTSFILE}.org"
		cp "$LHOSTSFILE" "${LHOSTSFILE}.bak"
		sed -i "s/$LOLDHOSTNAME/$LNEWHOSTNAME/g" "$LHOSTSFILE"
		grep -i "$LNEWHOSTNAME" "$LHOSTSFILE"
	fi
	
	#~ if [ "$(hostnamectl status | sed -n -e 's/^.*hostname: \([[:alpha:]]*\)$/\1/p')" != "$LNEWHOSTNAME" ]; then
	if [ "$(hostname)" != "$LNEWHOSTNAME" ]; then
		error_echo "${FUNCNAME} error: Could not change hostname to ${LNEWHOSTNAME}."
		LRET=1
	else
		LRET=0
	fi

	debug_echo " ${FUNCNAME}(): done, returning ${LRET}"
	
	return $LRET
}


# Check the hostname, prompt for a new name if not LCxx-----
hostname_check(){
	debug_echo "${FUNCNAME}( $@ )"

	local LNEWNAME="$1"
	local LOLDNAME="$(hostname)"
	local LRET=1

	if [ ! -z "$LNEWNAME" ]; then
		[ $QUIET -lt 1 ] && error_echo "Checking ${LNEWNAME} for hostname compatibility.."

		if [ "$(echo "$LNEWNAME" | grep -c -E '^lc[0-9]{2}.*$')" -gt 0 ]; then
			LNEWNAME="$(echo "$LNEWNAME" | sed -e 's/^lc/LC/')"
		fi
		
		if [ "$(echo "$LNEWNAME" | grep -c -E '^LC[0-9]{2}.*$')" -gt 0 ]; then
			[ $QUIET -lt 1 ] && error_echo "Changing hostname from ${LOLDNAME} to ${LNEWNAME}.."
			hostname_change "$LOLDNAME" "$LNEWNAME"
			return $?
		fi
	fi

	# Is our hostname OK??
	[ $VERBOSE -gt 0 ] && error_echo "Checking ${LOLDNAME} for hostname compatibility.."
	
	if [ "$(hostname | grep -c -E '^LC[0-9]{2}.*$')" -gt 0 ]; then
		return 0
	fi

	# If hostname begins with 'lcnn', make LCnn
	if [ "$(hostname | grep -c -E '^lc[0-9]{2}.*$')" -gt 0 ]; then
		LNEWNAME="$(hostname | sed -e 's/^lc/LC/')"
		hostname_change "$LOLDNAME" "$LNEWNAME"
		return 0
	else
		# Default to LC99Speedbox
		hostname_change "$LOLDNAME" 'LC99Speedbox'
	fi

	if [ "$(hostname | grep -c -E '^LC[0-9]{2}.*$')" -lt 1 ]; then
		error_echo "WARNING: The hostname of this system needs to be changed using hostnamectl set-hostname."
		LRET=1
	else
		LRET=0
	fi

	debug_echo " ${FUNCNAME}(): done, returning ${LRET}"
	
	return $LRET
}



systemd_set_tz_to_local(){
	debug_echo "${FUNCNAME}( $@ )"
	local LTIMESYNC_CONF='/etc/systemd/timesyncd.conf'
	local LNTP_SERVERS='NTP=0.north-america.pool.ntp.org 1.north-america.pool.ntp.org 2.north-america.pool.ntp.org 3.north-america.pool.ntp.org'
	local LTIMESYNCD='systemd-timesyncd.service'
	local LTIMESYNC_WAIT='systemd-time-wait-sync.service'


	# Check the timezone we're set to..
	local LTIMEDATECTL="$(which timedatectl 2>/dev/null)"

	if [ ! -z "$LTIMEDATECTL" ]; then
		# Change the timezone to local..
		local LSYS_TZ="$("$LTIMEDATECTL" status | grep 'zone:' | sed -n -e 's/^.*: \(.*\) (.*$/\1/p')"
		local LMY_TZ="$(timezone_get)"
		if [ "$LMY_TZ" != "$LSYS_TZ" ]; then
			[ $QUIET -lt 1 ] && error_echo "Resetting local time zone from ${LSYS_TZ} to ${LMY_TZ}.."
			[ $TEST -lt 1 ] && "$LTIMEDATECTL" set-timezone "$LMY_TZ"
		else
			[ $VERBOSE -gt 0 ] && error_echo "Confirmied local timezone ${LMY_TZ} matches system timezone ${LSYS_TZ}."
		fi

		# Configure our prefered NTP servers..
		if [ -f "$LTIMESYNC_CONF" ]; then
			[ $TEST -lt 1 ] && sed -i -e "s/^#*NTP=.*/${LNTP_SERVERS}/" "$LTIMESYNC_CONF"
			[ $TEST -lt 1 ] && sed -i -e 's/^#*FallbackNTP=/FallbackNTP=/' "$LTIMESYNC_CONF"
		fi
		# Increase the time between systemd-timesyncd sync & sets to up to 2 hours
		sed -i -e 's/^#*PollIntervalMaxSec=*/PollIntervalMaxSec=7200/' "$LTIMESYNC_CONF"
		
		# Make sure systemd-timesyncd.service is running
		[ $TEST -lt 1 ] && "$LTIMEDATECTL" set-ntp True

		if [ $("$LTIMEDATECTL" status | grep -c -E '^\s+NTP service: active') -lt 1 ]; then
			[ $TEST -lt 1 ] && systemctl enable "$LTIMESYNCD"
			[ $TEST -lt 1 ] && systemctl restart "$LTIMESYNCD"
		fi
		
		[ $VERBOSE -gt 0 ] && "$LTIMEDATECTL" status
		[ $VERBOSE -gt 0 ] && systemctl -l --no-pager status systemd-timesyncd.service

		# Enable the time-sync.target so that our service only starts AFTER the system time has been synchronized.
		#    -- This depends on our service unit file containing After=time-sync.target and Wants=time-sync.target
		if ( ! systemd_unit_file_is_enabled "$LTIMESYNC_WAIT" ); then
			[ $TEST -lt 1 ] && systemctl enable "$LTIMESYNC_WAIT"
		fi
		[ $TEST -lt 1 ] && systemctl restart "$LTIMESYNC_WAIT"
		[ $VERBOSE -gt 0 ] && systemctl -l --no-pager status "$LTIMESYNCD"
	fi
	
	debug_echo " ${FUNCNAME}(): done"
}

###################################################
# user_daadmin_add() -- adds a daadmin user with its
#   default password as a member of the sudo group
###################################################
user_daadmin_add(){
	debug_echo "${FUNCNAME}( $@ )"
	
	local LUSER='daadmin'
	local LGROUP="$LUSER"
	local LRET=1
	
	# Return if the user already exists..
	is_user "$LUSER" && return 0

	[ $QUIET -lt 1 ] && error_echo "Adding user account for ${LUSER}.."
	
	if [ $IS_DEBIAN -gt 0 ]; then
	
		[ $TEST -lt 1 ] && adduser --disabled-password --gecos "" "$LUSER"
	
		is_user "$LUSER"
		LRET=$?

		if [ $LRET -lt 1 ]; then
			# Add user to sudoers..
			[ $TEST -lt 1 ] && usermod -aG sudo "$LUSER"
		fi
	else
		[ $TEST -lt 1 ] && useradd --user-group --groups wheel --create-home "$LUSER"
	fi

	# Add password
	# LPASS=$(echo 'password' | mkpasswd --method=SHA-256 --stdin)
	local LPASS='$5$IlVIhMrKc$uegnePcFvUjFC52mTZMkt85prUxYnIjNJV2T9zD49k4'
	
	[ $TEST -lt 1 ] && echo "${LUSER}:${LPASS}" | chpasswd --encrypted

	is_user "$LUSER"
	LRET=$?
	
	[ $LRET -gt 0 ] && error_echo "${SCRIPT_NAME} Error: could not create user ${LUSER}."

	debug_echo " ${FUNCNAME}(): done, returning ${LRET}"
	
	return $LRET
	
}

###################################################
# user_admin_add() -- adds a daadmin user with its
#   default password as a member of the sudo group
###################################################
user_admin_add(){
	debug_echo "${FUNCNAME}( $@ )"
	
	local LUSER='admin'
	local LGROUP="$LUSER"
	local LRET=1
	# Return if the user already exists..
	is_user "$LUSER" && return 0

	[ $QUIET -lt 1 ] && error_echo "Adding user account for ${LUSER}.."
	
	if [ $IS_DEBIAN -gt 0 ]; then
	
		[ $TEST -lt 1 ] && adduser --disabled-password --gecos "" "$LUSER"
	
		is_user "$LUSER"
		LRET=$?

		if [ $LRET -lt 1 ]; then
			# Add user to sudoers..
			[ $TEST -lt 1 ] && usermod -aG sudo "$LUSER"
		fi

		# Add password
		# LPASS=$(echo 'pasword' | mkpasswd --method=SHA-256 --stdin)
		local LPASS='$5$3wWL9xQyPhs/texN$ICM2faVB/Dks4lUbk48a7orGdthC10unzH.pUvh3lVD'
		[ $TEST -lt 1 ] && echo "${LUSER}:${LPASS}" | chpasswd --encrypted
	else
		[ $TEST -lt 1 ] && useradd --user-group --groups wheel --create-home "$LUSER"
		[ $TEST -lt 1 ] && echo '!EwA!' | passwd "$LUSER" --stdin
	fi

	is_user "$LUSER"
	LRET=$?
	
	[ $LRET -gt 0 ] && error_echo "${SCRIPT_NAME} Error: could not create user ${LUSER}."

	debug_echo " ${FUNCNAME}(): done, returning ${LRET}"

	return $LRET
	
}

user_admin_remove(){
	debug_echo "${FUNCNAME}( $@ )"
	
	local LUSER='admin'
	local LGROUP="$LUSER"
	local LRET=1

	# Return if the user doesn't exist..
	is_user "$LUSER" || return 0
	
	[ $QUIET -lt 1 ] && error_echo "Removing ${LUSER} user account.."
	LINST_GROUP="$(id -ng "$LUSER")"

	if [ $IS_DEBIAN -gt 0  ]; then
		userdel -r "$LUSER" >/dev/null 2>&1
	else
	  /usr/sbin/userdel -r -f "$LUSER" >/dev/null 2>&1
	  /usr/sbin/groupdel "$LINST_GROUP" >/dev/null 2>&1
	fi
	
}

config_sshd_oldhostkeys(){
	debug_echo "${FUNCNAME}( $@ )"
	local SSHD_CONF='/etc/ssh/sshd_config'
	local SSH_CONF='/etc/ssh/ssh_config'
	local NSSWITCH_CONF='/etc/nsswitch.conf'
	local PAMD_SSHD='/etc/pam.d/sshd'
	
	# /etc/ssh/sshd_config
	if [ $(grep -c -E '^\s*HostKeyAlgorithms' "$SSHD_CONF") -lt 1 ]; then
		[ $QUIET -lt 1 ] && error_echo "Adding 'HostKeyAlgorithms +ssh-rsa' to ${SSHD_CONF}.."
		[ $TEST -lt 1 ] && echo ' ' >>"$SSHD_CONF"
		[ $TEST -lt 1 ] && echo 'HostKeyAlgorithms +ssh-rsa' >>"$SSHD_CONF"
	elif [ $(grep -c -E '^\s*HostKeyAlgorithms \+ssh-rsa' "$SSHD_CONF") -gt 0 ]; then
		[ $VERBOSE -gt 0 ] && error_echo "${SSHD_CONF} already configured for HostKeyAlgorithms +ssh-rsa"
	else
		[ $QUIET -lt 1 ] && error_echo "Modifying ${SSHD_CONF} to add ssh-rsa to HostKeyAlgorithms.."
		#~ [ $TEST -lt 1 ] && sed -i -e 's/^\(HostKeyAlgorithms .*\)$/\1,ssh-rsa/' "$SSHD_CONF"
		[ $TEST -lt 1 ] && sed -i -e 's/^\s*\(HostKeyAlgorithms .*\)$/\1,ssh-rsa/' "$SSHD_CONF"
	fi

	if [ $(grep -c -E '^PubkeyAcceptedAlgorithms' "$SSHD_CONF") -lt 1 ]; then
		[ $QUIET -lt 1 ] && error_echo "Adding 'PubkeyAcceptedAlgorithms +ssh-rsa' to ${SSHD_CONF}.."
		[ $TEST -lt 1 ] && echo 'PubkeyAcceptedAlgorithms +ssh-rsa' >>"$SSHD_CONF"
	elif [ $(grep -c -E '^PubkeyAcceptedAlgorithms \+ssh-rsa' "$SSHD_CONF") -gt 0 ]; then
		[ $VERBOSE -gt 0 ] && error_echo "${SSHD_CONF} already configured for PubkeyAcceptedAlgorithms +ssh-rsa"
	else
		[ $QUIET -lt 1 ] && error_echo "Modifying ${SSHD_CONF} to add ssh-rsa to PubkeyAcceptedAlgorithms.."
		[ $TEST -lt 1 ] && sed -i -e 's/^\(PubkeyAcceptedAlgorithms .*\)$/\1,ssh-rsa/' "$SSHD_CONF"
	fi

	# Modify /etc/ssh/ssh_config so we can ssh into, e.g., ubiquiti airmax & airfiber devices
	if [ $(grep -c -E '^\s*HostKeyAlgorithms' "$SSH_CONF") -lt 1 ]; then
		[ $QUIET -lt 1 ] && error_echo "Adding 'HostKeyAlgorithms +ssh-rsa,ssh-dss' to ${SSH_CONF}.."
		[ $TEST -lt 1 ] && echo ' ' >>"$SSH_CONF"
		[ $TEST -lt 1 ] && echo 'HostKeyAlgorithms +ssh-rsa,ssh-dss' >>"$SSH_CONF"
	elif [ $(grep -c -E '^\s*HostKeyAlgorithms \+ssh-rsa,ssh-dss' "$SSH_CONF") -gt 0 ]; then
		[ $VERBOSE -gt 0 ] && error_echo "${SSH_CONF} already configured for HostKeyAlgorithms +ssh-rsa,ssh-dss"
	else
		[ $QUIET -lt 1 ] && error_echo "Modifying ${SSH_CONF} to add +ssh-rsa,ssh-dss to HostKeyAlgorithms.."
		#~ [ $TEST -lt 1 ] && sed -i -e 's/^\(HostKeyAlgorithms .*\)$/\1,ssh-rsa/' "$SSH_CONF"
		[ $TEST -lt 1 ] && sed -i -e 's/^\s*\(HostKeyAlgorithms .*\)$/\1,+ssh-rsa,ssh-dss/' "$SSH_CONF"
	fi

}

######################################################################################################
# RPi specific functions
######################################################################################################

###################################################
# is_raspberry_pi() returns 0 if system can be
#	identified as a raspberry pi.
###################################################
is_raspberry_pi(){
	debug_echo "${FUNCNAME}( $@ )"
	
	[ $FORCE -gt 0 ] && return 0
	
	local LIS_RPI=0

	if [ -z "$(which lsb_release 2>/dev/null)" ]; then
		[ $QUIET -lt 1 ] && error_echo "${SCRIPT_NAME} error: no lsb_release found."
		[ $QUIET -lt 1 ] && error_echo "This system is probably not a Raspberry Pi."
		return 1
	fi

	# Raspbian GNU/Linux 10 (buster) & Raspbian GNU/Linux 11 (bullseye) & Raspbian GNU/Linux 12 (bookworm)
	LIS_RPI=$(lsb_release -sd | grep -c 'Raspbian')

	if [ $LIS_RPI -lt 1 ]; then
		[ $VERBOSE -gt 0 ] && error_echo "${SCRIPT_NAME}: lsb_release reports $(lsb_release -sd)."
		[ $VERBOSE -gt 0 ] && error_echo "This system is probably not a Raspberry Pi."
		return 1
	fi
	
	# Can we find the config utility?
	local LRASPI_CONFIG="$(which raspi-config)"
	if [ -z "$LRASPI_CONFIG" ]; then
		error_echo "${SCRIPT_NAME} error: connot fine raspi-config utility."
		error_echo "This system is probably not a Raspberry Pi."
		return 1
	fi

}


###################################################
# rpi_def_user_chpasswd() -- changes the default pi
#   user's password to Andi Klein's preferred pw
###################################################
rpi_def_user_chpasswd(){
	debug_echo "${FUNCNAME}( $@ )"

	local LUSER='pi'

	# LPASS=$(echo 'password' | mkpasswd --method=SHA-256 --stdin)
	local LPASS='$5$rGd8cYfswkEV$1nWCsvXeJELc0jku641BBmCQOKwZ8U0v59PIC1oEAE2'

	is_user "$LUSER"

	# If pi user exists..
	if [ $? -lt 1 ]; then
		[ $QUIET -lt 1 ] && error_echo "Setting new password for default user pi.."
		[ $TEST -lt 1 ] && echo "${LUSER}:${LPASS}" | chpasswd --encrypted
	fi

	debug_echo " ${FUNCNAME}(): done"

}

###################################################
# rpi_def_user_lock() Locks the default pi user
#   so can't be logged in via ssh
###################################################
rpi_def_user_lock(){
	debug_echo "${FUNCNAME}( $@ )"

	local LUSER='pi'
	
	[ $QUIET -lt 1 ] && error_echo "Locking account for default user pi.."
	[ $TEST -lt 1 ] && passwd --lock "$LUSER"
}


###################################################
# rpi_locale_set() Sets the system locale to
#    en_US.UTF-8.  Note: calling do_change_locale
#    in raspi-config noint does not seem to work.
###################################################
rpi_locale_set(){
	debug_echo "${FUNCNAME}( $@ )"
	local LNEW_LOCALE="${1:-en_US.UTF-8}"
	local LDEF_LOCALE='en_GB.UTF-8'
	local LSUP_FILE='/usr/share/i18n/SUPPORTED'
	local LGEN_FILE='/etc/locale.gen'
	local LNEW_LOCALE_LINE=
	local LNEW_LANG=
	local LRET=1

	[ $TEST -gt 0 ] && return 0

	[ $QUIET -lt 1 ] && error_echo "Setting system locale to ${LNEW_LOCALE}.."

	LNEW_LOCALE_LINE="$(grep -E "^${LNEW_LOCALE}( |$)" "$LSUP_FILE")"

	if [ -z "$LNEW_LOCALE_LINE" ]; then
		error_echo "${FUNCNAME}(${LNEW_LOCALE}): error ${LNEW_LOCALE} is not a supported local."
		LRET=1
	else
		LNEW_LANG="$(echo $LNEW_LOCALE_LINE | cut -f1 -d " ")"
		export LC_ALL=C
		export LANG=C
		#~ export "LANG=${LNEW_LANG}"
		
		if [ -L "$LGEN_FILE" ] && [ "$(readlink $LGEN_FILE)" = "$LSUP_FILE" ]; then
			[ $QUIET -lt 1 ] && error_echo "Deleting ${LGEN_FILE} link to $(readlink -f "$LGEN_FILE")"
			rm -f "$LGEN_FILE"
		fi

		[ $QUIET -lt 1 ] && error_echo "Adding ${LLOCALE_LINE} to ${LGEN_FILE}"
		echo "$LLOCALE_LINE" > "$LGEN_FILE"
		
		update-locale --no-checks LANG
		update-locale --no-checks "LANG=${LNEW_LANG}"
		dpkg-reconfigure -f noninteractive locales
		
		echo "LANG=${LNEW_LANG}" >/tmp/locale.sh
		
		#~ sed -i -e "s/^#*.*${LNEW_LOCALE}/${LNEW_LOCALE}/" "$LGEN_FILE"
		#~ sed -i -e "s/^#*.*${LDEF_LOCALE}/# ${LDEF_LOCALE}/" "$LGEN_FILE"
		
		#~ locale-gen "$LNEW_LOCALE"
		#~ update-locale "$LNEW_LOCALE"
		
		LRET=$?
	fi

	debug_pause "${FUNCNAME}( $@ ) returned ${LRET}"
	
	return $LRET
}

###################################################
# rpi_setting_change() -- makes calls to 
#	/usr/bin/raspi-config noint functions to 
# 	make settings changes non-interactivly.
###################################################
rpi_setting_change(){
	debug_echo "${FUNCNAME}( $@ )"
	local LRASPI_CONFIG="$(which raspi-config)"
	local LRET=1

	# Can we find the config utility?
	if [ -z "$LRASPI_CONFIG" ]; then
		return 1
	fi
	
	[ $QUIET -lt 1 ] && error_echo "Executing ${LRASPI_CONFIG} nonint $@"
	
	[ $TEST -lt 1 ] && "$LRASPI_CONFIG" nonint $@
	LRET=$?

	debug_pause "${LRASPI_CONFIG} nonint $@ returned ${LRET}"

	return $LRET
}

###################################################
# Fixups for Raspberry Pi, versions:
#	Raspbian GNU/Linux 10 (buster)
#	Raspbian GNU/Linux 11 (bullseye)
###################################################
rpi_fixups(){
	debug_echo "${FUNCNAME}( $@ )"
	
	# This system is a Raspberry Pi running Raspbian.  Fix some things..
	[ $QUIET -lt 1 ] && error_echo "========================================================================================="
	[ $QUIET -lt 1 ] && error_echo "Making Raspberry Pi-specific system settings.."


	####################################################################
	# Install missing basic utilities
	basic_utils_install

	####################################################################
	# Set the locale
	local LMY_LOCALE='en_US.UTF-8'

	if [ $DEBUG -gt 1 ]; then
		error_echo ' '
		error_echo "System locale before:"
		locale
		error_echo ' '
	fi

    # Only change locale if not already correctly set
	if [ $(grep -c "^${LMY_LOCALE} .*\$" /etc/locale.gen) -lt 1 ]; then
		[ $QUIET -lt 1 ] && error_echo "Changing system locale to ${LMY_LOCALE}.."
		update-locale --no-checks LANG
		update-locale --no-checks "LANG=${LMY_LOCALE}"
		dpkg-reconfigure -f noninteractive locales
	fi

	if [ $DEBUG -gt 1 ]; then
		error_echo ' '
		error_echo "System locale after:"
		locale
		error_echo ' '
	fi
	
	####################################################################
	# Configure the keyboard
	#~ rpi_setting_change do_configure_keyboard "pc101" "us"
	local LMY_KBD='us'

	if [ $(grep -c -E "^XKBLAYOUT=\"${LMY_KBD}\"" /etc/default/keyboard) -lt 1 ]; then
		[ $QUIET -lt 1 ] && error_echo "Changing keyboard layout to ${LMY_KBD}.."
		rpi_setting_change do_configure_keyboard "$LMY_KBD"
	fi

	####################################################################
	# Set the wifi interface country code
	local LMY_WIFICO='US'

	if [ $(iw reg get | grep -c "country ${LMY_WIFICO}:") -lt 1 ]; then
		[ $QUIET -lt 1 ] && error_echo "Changing wifi country code to ${LMY_WIFICO}.."
		rpi_setting_change do_wifi_country "$LMY_WIFICO"
	fi

	####################################################################
	# Reset the system timezone from GMT to local
	local LMY_TZ="$(timezone_get)"
	if [ ! -z "$LMY_TZ" ]; then
		# Check to see if TZ is already correct
		if [ $(timedatectl status | grep -c -E "Time zone: ${LMY_TZ} (.*)\$") -lt 1 ]; then
			[ $QUIET -lt 1 ] && error_echo "Changing timezone to ${LMY_TZ}.."
			rpi_setting_change do_change_timezone "$LMY_TZ"
		fi
	fi
	
	####################################################################
	# Change the default pi user password
	[ $QUIET -lt 1 ] && error_echo "Changing default user pi's password.."
	rpi_def_user_chpasswd
	
	####################################################################
	# Make sure the cron daemon is enabled
	[ $QUIET -lt 1 ] && error_echo "Enabling cron daemon.."
	systemctl enable cron

	####################################################################
	# Make sure the ssh daemon is enabled and started..
	[ $QUIET -lt 1 ] && error_echo "Enabling ssh daemon.."
	systemctl enable ssh
	systemctl restart ssh

	debug_echo " ${FUNCNAME}(): done"
}

##################################################################################
##################################################################################
##################################################################################
# main()
##################################################################################
##################################################################################
##################################################################################

PRE_ARGS="$@"

SHORTARGS='hdqvftar'

LONGARGS="
help,
debug,
quiet,
verbose,
test,
force,
alias,
uninstall,remove,
no-hostname,
hostname:,
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
		-h|--help)		# Displays this help
			disp_help "$SCRIPT_DESC"
			exit 0
			;;
		-d|--debug)		# Shows debugging info.
			((DEBUG+=1))
			KPANIC_OPTS="${KPANIC_OPTS} ${1}"
			;;
		-q|--quiet)		# Supresses message output.
			QUIET=1
			KPANIC_OPTS="${KPANIC_OPTS} ${1}"
			;;
		-v|--verbose)		# Increas message output.
			((VERBOSE+=1))
			KPANIC_OPTS="${KPANIC_OPTS} ${1}"
			;;
		-f|--force)		# Inhibit rpi checks
			((FORCE+=1))
			KPANIC_OPTS="${KPANIC_OPTS} ${1}"
			;;
		-t|--test)		# Tests script logic without performing actions.
			((TEST+=1))
			KPANIC_OPTS="${KPANIC_OPTS} ${1}"
			;;
		-a|--alias)		# Install / update / remove (with --remove) bash aliases only.
			ALIAS_INST_ONLY=1
			;;
		--no-hostname)		# Skips LCxx hostname checking
			NO_CHANGE_HOSTNAME=1
			;;
		--no-kernel-panic)	# Skips configuring sysctl values for auto reboots on kernel panics
			NO_CONFIG_KERNELPANIC=1
			;;
		--hostname)		#=NEWHOSTNAME -- change system hostname
			shift
			NEW_HOSTNAME="$1"
			;;
		-r|--uninstall|--remove)	# Removes the 'admin' account. Doesn't uninstall basic utilities.
			UNINSTALL=1
			;;
		*)
			# Do nothing with unneeded args..
			;;
	esac
	shift
done

[ $VERBOSE -gt 0 ] && error_echo "${SCRIPTNAME} ${PRE_ARGS}"

# Make sure we're running as root 
is_root

if [ $UNINSTALL -gt 0 ]; then
	user_admin_remove
	exit 0
fi

####################################################################
# Perform basic rpi config..

is_raspberry_pi
[ $? -lt 1 ] && rpi_fixups

####################################################################
# Change system tz from UTC to local and enable
# systemd-timesyncd.service and systemd-time-wait-sync.service
systemd_set_tz_to_local

####################################################################
# Check our hostname, change to LC99Speedbox by default
[ $NO_CHANGE_HOSTNAME -lt 1 ] && hostname_check "$NEW_HOSTNAME"

####################################################################
# Install missing basic utilities
basic_utils_install

####################################################################
# Add daadmin & admin users, set password, add to sudo group
user_daadmin_add
user_admin_add
	
####################################################################
# Allow ssh logins from older ssh clients, e.g. airCube dropbear
config_sshd_oldhostkeys

####################################################################
# Configure sysctl values to enable auto reboots after kernel panics
"${SCRIPT_DIR}/config-lcwa-speed-kpanic.sh" $KPANIC_OPTS
