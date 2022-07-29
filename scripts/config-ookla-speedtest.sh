#!/bin/bash

SCRIPT_VERSION=20220130.01

#
# ookla-speedtest-update.sh  [--help] [-d|--debug] [-t|--test] [-f|--force] [-q|--quiet] [--no-pause] [--update] [--remove] [--install] [--direct] [optional_username]
#
# Installs or updates a previous installation of the Ookla speedtest binary.
#   Can optionall remove or remove and reinstall the same.
#
# Optional arguments:
#
# -f or --force		Force a update even if the installed version is newer than the install candidate.
# -n or --no-pause	Unattended operation, disabling the info banner prompt.
# -r or --remove	Uninstall the speedtest binary, any package manager sources and remove the license files.
# -i or --install	Reinstall after a remove, i.e. clean the system and then reinstall.  --install MUST follow --remove on the command line.
# -k or --direct	Install directly from a tar.gz file downloaded from install.speedtest.net, i.e. don't use the apt|dnf package managers.
#
#
# Usage example:
#
# sudo ./ookla-speedtest-update.sh
#
#   This installs the speedtest binary and installs the ookla license file as $HOME/.config/ookla/speedtest-cli.json
#     for the user that called sudo.  So, if that user was 'pi', the license file would be saved as:
#     '/home/pi/.config/ookla/speedtest-cli.json'
#
# Usage example:
#
# To install speedtest so that it's licensed for a system account
#
# sudo adduser --system --no-create-home  --group --gecos "lcwa-speed user account" "lcwa-speed"
# sudo mkdir -p /var/lib/lcwa-speed
# sudo chown -R lcwa-speed:nogroup /var/lib/lcwa-speed
# sudo ./ookla-speedtest-update.sh /var/lib/lcwa-speed/.config/ookla/speedtest-cli.json
#
#   This installs the speedtest binary and installs the ookla license file at the indicated location with permissions
#     for user lcwa-speed.
#
#

SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
SCRIPT_NAME="$(basename "$0")"

DEBUG=0			# Set to >1 for action pauses and diagnostic output
NO_PAUSE=0		# Set to 1 to inhibit debug pausing
NO_BANNER=1		# Set to 1 to inhibit banner pause
FORCE=0			# Set to 1 to overwrite an existing speedtest installation.
TEST=0			# Set to 1 to test script logic without performing actions.
QUIET=0			# Set to 1 to inhibit messages
OUT=1			# Set to 1 for apt-get output to stdout, 2 for output to stderr
VERBOSE=0

REMOVE=0		# Set to 1 to uninstall the speedtest binary and any packagemanager souce repos for it.
INSTALL=0		# Set to 1 to reinstall after a remove
UPDATE=1		# Set to 1 to update an existing install
DIRECT=0		# Set to 1 to bypass using a package manager and do a direct download & install
LICENSE_ONLY=0  # Set to 1 to skip install and just generate the license file for the user..

INST_DESC='Ookla speedtest install script'

INST_USER=
INST_LICENSE_FILE=
INST_VERSION='1.1.1'
CUR_VERSION=
LCWA_ENVFILE=

# Distinguish between debian and redhat systems..
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
	IS_RPM=
	USE_YUM=0
fi

######################################################################################################
# is_root() -- make sure we're running with suficient credentials..
######################################################################################################
function is_root(){
	if [ $(whoami) != 'root' ]; then
		echo '################################################################################'
		echo -e "\nError: ${SCRIPT_NAME} needs to be run with root cridentials, either via:\n\n# sudo ${0}\n\nor under su.\n"
		echo '################################################################################'
		exit 1
	fi
}

######################################################################################################
# is_macos() -- returns 0 if a mac, 1 if not.
######################################################################################################
function is_macos(){
	[[ $OSTYPE == 'darwin'* ]] && return 0 || return 1
}

######################################################################################################
# is_macos_chk() -- Exit if we're running on a mac unless --force
######################################################################################################
is_macos_chk(){
	if ( is_macos ); then
		echo '################################################################################'
		[ $FORCE -lt 1 ] && echo -e "\nError: ${SCRIPT_NAME} is not compatible with macOS yet."
		[ $FORCE -gt 0 ] && echo -e "\nWarning: ${SCRIPT_NAME} is not fully compatible with macOS."
		echo '################################################################################'
		[ $FORCE -lt 1 ] && exit 1
	fi
}

######################################################################################################
# is_speedtest() -- returns 0 if speedtest is found and executable, otherwise returns 1
######################################################################################################
function is_speedtest(){
	which speedtest >/dev/null 2>&1
	return $?
}

######################################################################################################
# is_raspberrypi() -- returns 0 if RPi0, 1, 2, 3 or 4 or a close clone
######################################################################################################
function is_raspberrypi(){
	[ $(grep -c -E "BCM(283(5|6|7)|270(8|9)|2711)" /proc/cpuinfo) -gt 0 ] && return 0 || return 1
}

######################################################################################################
# is_user( username ) -- returns 0 if username is a valid user account, 1 if not
######################################################################################################
function is_user(){
	debug_echo "${FUNCNAME}( $@ )"
	local LINST_USER="$1"
	
	[ -z "$LINST_USER" ] && return 1
	
	id "$LINST_USER" >/dev/null 2>&1
	return $?
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
# pause() -- echo a prompt and then wait for keypress
######################################################################################################
pause(){
	read -p "$*"
}

######################################################################################################
# debug_pause() -- Pauses execution if DEBUG > 1 && NO_PAUSE < 1  debug_pause "${LINENO} -- ${FUNCNAME}() done."
######################################################################################################
debug_pause(){
	debug_echo "Debug check: $@" 1>&2;
	debug_echo " " 1>&2;
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

######################################################################################################
# apt_update() -- update the apt cache only if it is more than two hours out of date..
######################################################################################################
apt_update(){
	debug_echo "${FUNCNAME}( $@ )"
	
	local MAX_AGE=$((2 * 60 * 60))
	local CACHE_DIR='/var/cache/apt/'
	local CACHE_DATE=$(stat -c %Y "$CACHE_DIR")
	local NOW_DATE=$(date --utc '+%s')
	local CACHE_AGE=$(($NOW_DATE - $CACHE_DATE))
	local SZCACHE_AGE="$(echo "scale=2; (${CACHE_AGE} / 60 / 60)" | bc) hours"

	if [ $FORCE -gt 0 ] || [ $CACHE_AGE -gt $CACHE_AGE ]; then
		[ $CACHE_AGE -gt $CACHE_AGE ] && [ $VERBOSE -gt 0 ] && error_echo "Local cache is out of date.  Updating apt-get package cacahe.."
		[ $DEBUG -gt 0 ] && apt-update || apt-get -qq update
	else
		[ $VERBOSE -gt 0 ] && error_echo  "Local apt cache is up to date as of ${SZCACHE_AGE} ago."
	fi
}

############################################################################
# apt_install() -- Installs packages via apt-get without prompting.
############################################################################
apt_install(){
	debug_echo "${FUNCNAME}( $@ )"
	local LRET=1

	[ $QUIET -lt 1 ] && error_echo "apt-get installing $@"
	#~ [ $TEST -lt 1 ] && apt_update
	[ $TEST -lt 1 ] && apt-get -y install "$@"
	LRET=$?

	debug_pause "${FUNCNAME}: returning ${LRET}"
	
	return $LRET
}

############################################################################
# apt_uninstall() -- Removes packages & their config files without prompting.
############################################################################
apt_uninstall(){
	debug_echo "${FUNCNAME}( $@ )"

	[ $QUIET -lt 1 ] && error_echo "apt-get uninstalling $@"
	[ $TEST -lt 1 ] && apt-get purge -y "$@" >/dev/null 2>&1
	#~ [ $TEST -lt 1 ] && apt autoremove -y >/dev/null 2>&1
	LRET=$?

	debug_pause "${FUNCNAME}: returning ${LRET}"
	return $LRET
}


dnf_update(){
	[ $QUIET -lt 1 ] && error_echo "dnf updating cache.."
	[ $TEST -lt 1 ] && dnf check-update --refresh >/dev/null 2>&1
	return 0
}

dnf_install(){
	[ $QUIET -lt 1 ] && error_echo "dnf installing $@"
	[ $TEST -lt 1 ] && dnf -y install "$@"
	return 0
}

dnf_uninstall(){
	local LPKG_NAME="$1"
	[ $QUIET -lt 1 ] && error_echo "dnf uninstalling $@"
	[ $TEST -lt 1 ] && dnf -y remove "$LPKG_NAME"
	return 0
}

pkgmgr_update(){
	debug_echo "${FUNCNAME}( $@ )"
	local LRET=1
	[[ $OSTYPE == 'darwin'* ]] && return 1

	if [ $USE_APT -gt 0 ]; then
		apt_update
		LRET=$?
	elif [ $USE_YUM -gt 0 ]; then
		dnf_update
		LRET=$?
	elif [ $IS_MAC -gt 0 ]; then
		[ $VERBOSE -gt 0 ] && error_echo "${FUNCNAME}() not supported on macOS."
		LRET=1
	fi
	debug_pause "${FUNCNAME}: returning ${LRET}"
	return $LRET
}

pkgmgr_install(){
	debug_echo "${FUNCNAME}( $@ )"
	local LPKG_NAME="$1"
	local LRET=1
	
	[ $QUIET -lt 1 ] && error_echo "Installing ${LPKG_NAME}"
	
	if [ $USE_APT -gt 0 ]; then
		apt_install $LPKG_NAME
		LRET=$?
	elif [ $USE_YUM -gt 0 ]; then
		dnf_install $LPKG_NAME
		LRET=$?
	elif [ $IS_MAC -gt 0 ]; then
		[ $VERBOSE -gt 0 ] && error_echo "${FUNCNAME}() not supported on macOS."
		LRET=1
	fi
	debug_pause "${FUNCNAME}: returning ${LRET}"
	return $LRET
}

pkgmgr_uninstall(){
	debug_echo "${FUNCNAME}( $@ )"
	local LPKG_NAME="$1"
	local LRET=1
	if [ $USE_APT -gt 0 ]; then
		apt_uninstall "$LPKG_NAME"
		LRET=$?
	elif [ $USE_YUM -gt 0 ]; then
		dnf_uninstall "$LPKG_NAME"
		LRET=$?
	elif [ $IS_MAC -gt 0 ]; then
		[ $VERBOSE -gt 0 ] && error_echo "${FUNCNAME}() not supported on macOS."
		LRET=$?
	fi
	debug_pause "${FUNCNAME}: returning ${LRET}"
	return $LRET
}
	


############################################################################
# sudo_user_get() -- Returns the name of the user calling sudo or sudo su
############################################################################
sudo_user_get(){
	who am i | sed -n -e 's/^\([[:alnum:]]*\)\s*.*$/\1/p'
}

############################################################################
# users_list() -- List all users configured on the system
############################################################################
users_list(){
	local LUSER=
	for LUSER in $(cat /etc/passwd | cut -d: -f1 | sort); do  echo ${LUSER}:$(id -ng ${LUSER}); done
}

user_group_get(){
	local LUSER="$1"
	local LGROUP=
	if ( is_user "$LUSER" ); then
		LGROUP="$(id -g -n "$LUSER")"
	else
		return 1
	fi
	echo "$LGROUP"
}

############################################################################
# user_home_get( username ) -- Get the home dir of a user
############################################################################
user_home_get(){
	debug_echo "${FUNCNAME}( $@ )"
	local LINST_USER="${1:-$(who am i | sed -n -e 's/^\([[:alnum:]]*\)\s*.*$/\1/p')}"
	local LHOME_DIR=
	
	# 1st try
	LHOME_DIR="$( eval echo "~${LINST_USER}")"
	
	# 2nd try
	if [ -z "$LHOME_DIR" ] || [ ! -d "$LHOME_DIR" ]; then
		LHOME_DIR="$(cat /etc/passwd | grep "$LINST_USER" | awk -F':' '{ print $6 }')"
	fi
	
	# 3rd try
	if [ -z "$LHOME_DIR" ] || [ ! -d "$LHOME_DIR" ]; then
		LHOME_DIR="/var/lib/${LINST_USER}"
	fi

	
	[ -d "$LHOME_DIR" ] && echo "$LHOME_DIR" || echo ""
}


vercomp () {
    if [[ $1 == $2 ]]
    then
        return 0
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    # fill empty fields in ver1 with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++))
    do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++))
    do
        if [[ -z ${ver2[i]} ]]
        then
            # fill empty fields in ver2 with zeros
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]}))
        then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]}))
        then
            return 2
        fi
    done
    return 0
}

############################################################################
# vercomp2( ver1, ver2 ) -- returns 0 if ver1 == ver2, 1 if ver1 > ver2, 2 if ver2 > ver1
############################################################################
vercomp2(){
	debug_echo "${FUNCNAME}( $@ )"
	local LVER1="$1"
	local LVER2="$2"
	local LHIGHER=
	
	if [ "$1" = "$2" ]; then
		debug_echo "${FUNCNAME}: ${1} == ${2}, returning 0"
		return 0
	fi
	
	LHIGHER="$(echo -e "${1} \n${2}" | sort -r -V | head -n1)"
	
	if [ "$1" = "$LHIGHER" ]; then
		debug_echo "${FUNCNAME}: ${1} > ${2}, returning 1"
		return 1
	else
		debug_echo "${FUNCNAME}: ${1} < ${2}, returning 2"
		return 2
	fi
	
	return 255
}

ookla_speedtest_version_get(){
	debug_echo "${FUNCNAME}( $@ )"
	local LSPEEDTEST="$(which speedtest 2>/dev/null)"
	
	[ -z "$LSPEEDTEST" ] && return 1
	# Speedtest by Ookla 1.1.1.28 (c732eb82cf) Linux/x86_64-linux-musl 5.4.0-96-generic x86_64
	speedtest --version | sed -n -e 's/^Speedtest by Ookla \([^[:space:]]\+\)\s\+.*$/\1/p'
}

############################################################################
# ookla_speedtest_pm_sources_install() -- Installs the speedtest package
#                                     	  manageer source.
############################################################################
ookla_speedtest_pm_sources_install(){
	debug_echo "${FUNCNAME}( $@ )"
	# Download the install script..
	local LSCRIPT='/tmp/speedtest_inst.sh'
	local LURL=
	local LSOURCEFILE=
	local LRET=1
	
	
	[ $IS_DEB -gt 0 ] && LURL='https://install.speedtest.net/app/cli/install.deb.sh' || LURL='https://install.speedtest.net/app/cli/install.rpm.sh'

	[ $QUIET -lt 1 ] && error_echo "Downloading Ookla speedtest install script ${LURL}.."

	wget --quiet -O "$LSCRIPT" "$LURL"
	
	# Execute the install script..just adds the appropriate packagecloud repo to apt or rpm sources..
	if [ -f "$LSCRIPT" ]; then
		chmod 755 "$LSCRIPT" 
		[ $QUIET -lt 1 ] && error_echo "Running Ookla speedtest install script.."
		# The repository is setup! You can now install packages.
		[ $TEST -lt 1 ] && LIS_REPO=$("$LSCRIPT" 2>&1 | grep -c 'You can now install packages')
		
		if [ $LIS_REPO -lt 1 ]; then
			error_echo "Error: did not successfully install Ookla speedtest repo source."
			LRET=1
		else
			[ $QUIET -lt 1 ] && error_echo "Successfully installed ${LSOURCEFILE}."
			LRET=0
		fi
	fi
	
	debug_pause "${FUNCNAME}: returning ${LRET}"

	return $LRET
}

############################################################################
# ookla_speedtest_pm_sources_remove() -- Removes the speedtest package
#                                     	 manageer source.
############################################################################
ookla_speedtest_pm_sources_remove(){
	debug_echo "${FUNCNAME}( $@ )"
	
	# No package manager sources for macOS..
	[ $IS_MAC -gt 0 ] && return 1
	
	# Remove package manager repo source files, if they haven't already been removed..
	[ $IS_DEB -gt 0 ] && LLIST_DIR='/etc/apt' || LLIST_DIR='/etc/yum.repos.d'
	
	# Remove ookla binary repo list by file name:
	for LLIST_FILE in $(find "$LLIST_DIR" -name '*ookla*')
	do
		[ $QUIET -lt 1 ] && error_echo "Removing ${LLIST_FILE}.."
		[ $TEST -lt 1 ] && rm -f "$LLIST_FILE"
	done
	
	# Remove ookla binary repo list by file name:
	for LLIST_FILE in $(find "$LLIST_DIR" -name '*speedtest*')
	do
		[ $QUIET -lt 1 ] && error_echo "Removing ${LLIST_FILE}.."
		[ $TEST -lt 1 ] && rm -f "$LLIST_FILE"
	done
	
	# Remove any reference to the ookla repo in any existing non-ookla repo source files..
	for LLIST_FILE in $(grep -H -rl 'ookla' "$LLIST_DIR" | grep '.list' | grep -v '.bak')
	do
		[ $QUIET -lt 1 ] && error_echo "Removing ookla reference from ${LLIST_FILE}.."
		[ $TEST -lt 1 ] && [ ! -f "${LLIST_FILE}.bak" ] && cp -p "$LLIST_FILE" "${LLIST_FILE}.bak"
		[ $TEST -lt 1 ] && sed -i '/ookla/d' "$LLIST_FILE"
	done

	debug_pause "${FUNCNAME}: done."
	
}



############################################################################
# ookla_speedtest_install_direct() -- Installs the ookla speedtest binary via
#                                     direct download of a tar.gz
############################################################################
ookla_speedtest_install_direct(){
	debug_echo "${FUNCNAME}( $@ )"
	local LURL=
	local LTMPTGZ='/tmp/speedtest.tgz'
	local LSOURCE='/tmp/speedtest'
	local LTARGET="$(which speedtest 2>/dev/null)"
	local LRET=1
	
	[ $IS_MAC -lt 1 ] && wget_check
	
	[ -z "$LTARGET" ] && LTARGET='/usr/bin/speedtest'
	[ $IS_MAC -gt 0 ] && LTARGET='/usr/local/bin/speedtest'

	# Direct download from ookla depending on machine architecture
	case "$(uname -m)" in
		x86_64)
			if [[ $OSTYPE == 'darwin'* ]]; then
				LURL="https://install.speedtest.net/app/cli/ookla-speedtest-1.1.1.84-macosx-x86_64.tgz"
			else
				LURL="https://install.speedtest.net/app/cli/ookla-speedtest-1.1.1-linux-x86_64.tgz"
			fi
			;;
		i686|i386)
			LURL="https://install.speedtest.net/app/cli/ookla-speedtest-1.1.1-linux-i386.tgz"
			;;
		armv6l)	#RPi0, RPi1
			LURL='https://install.speedtest.net/app/cli/ookla-speedtest-1.1.1-linux-armel.tgz'
			;;
		armv7l) #RPi2 | #RPi3b | RPi4b
			LURL='https://install.speedtest.net/app/cli/ookla-speedtest-1.1.1-linux-armhf.tgz'
			;;
		*)
			error_echo "${FUNCNAME}() Error: Machine type $(uname -m) not supported."
			return 1
			;;
	esac
	
	[ $QUIET -lt 1 ] && error_echo "Downloading ${LURL}.."
	if [ $TEST -lt 1 ]; then
		if [ $IS_MAC -gt 0 ]; then
			curl --silent -o "$LTMPTGZ" "$LURL"
		else
			wget --quiet -O "$LTMPTGZ" "$LURL"
		fi
	fi
	
	if [ ! -f "$LTMPTGZ" ]; then
		error_echo "${FUNCNAME}() error: Could not download ${LTMPTGZ} from ${LURL}."
		return 1
	fi
	
	# Extract the tgz
	[ $QUIET -lt 1 ] && error_echo "Extracting ${LTMPTGZ}.."
	[ $TEST -lt 1 ] && tar -xzf "$LTMPTGZ" -C /tmp >/dev/null 2>&1
	
	# Install to /usr/bin
	if [ -x "$LSOURCE" ]; then
		[ $QUIET -lt 1 ] && error_echo "Copying ${LSOURCE} to ${LTARGET}.."
		[ $TEST -lt 1 ] && cp -p "$LSOURCE" "$LTARGET"
	fi
	
	if [ $(which speedtest 2>/dev/null | wc -l) -lt 1 ]; then
		error_echo "${FUNCNAME}() error: Could not install ${LSOURCE} to ${LTARGET}"
		return 1
	else
		LRET=0
	fi

	[ $QUIET -lt 1 ] && error_echo "Ookla speedtest binary successfully installed."
	
	# Clean up
	[ $TEST -lt 1 ] && rm /tmp/speedtest*
	
	debug_pause "${FUNCNAME}: returning ${LRET}"
	
	return $LRET
}

############################################################################
# ookla_speedtest_install_pm() -- Install speedtest via a package manager
#								  Working again as of 20220130
############################################################################
ookla_speedtest_install_pm(){
	debug_echo "${FUNCNAME}( $@ )"
	
	# Download the install script..
	local LSCRIPT='/tmp/speedtest_inst.sh'
	local LIS_REPO=0
	local LRET=1
	
	[ $QUIET -lt 1 ] && error_echo "Downloading Ookla speedtest install script.."
	
	if [ $IS_DEB -gt 0 ]; then
		wget --quiet -O "$LSCRIPT" https://install.speedtest.net/app/cli/install.deb.sh
	elif [ $IS_RPM -gt 0 ]; then
		wget --quiet -O "$LSCRIPT" https://install.speedtest.net/app/cli/install.rpm.sh
	else
		error_echo "Error: Cannot determine which ookla speedtest install script to use."
		exit 1
	fi
	
	# Execute the install script..just adds the appropriate packagecloud repo to apt or rpm sources..
	if [ -f "$LSCRIPT" ]; then
		chmod 755 "$LSCRIPT" 
		[ $QUIET -lt 1 ] && error_echo "Running Ookla speedtest install script.."
		[ $TEST -lt 1 ] && LIS_REPO=$("$LSCRIPT" | grep -c 'You can now install packages')
		if [ $LIS_REPO -lt 1 ]; then
			error_echo "Error: did not successfully install Ookla speedtest repo source."
			return 1
		fi
	fi

	# Now install the binary
	if [ $IS_DEB -gt 0 ]; then
		if [ $TEST -lt 1 ]; then
			# Make 3 attempts to install packages.  RPi's package repositories have a tendency to time-out..
			for n in 1 2 3
			do

				[ $QUIET -lt 1 ] && error_echo "Installing Ookla speedtest deb package.."
				[ $TEST -lt 1 ] && apt_install speedtest
				LRET=$?

				if [ $LRET -eq 0 ]; then
					break
				fi
				# Problem installing the dependencies..
				error_echo "Error installing Ookla speedtest deb package...waiting 10 seconds to try again.."
				sleep 10

			done
		fi
	elif [ $IS_RPM -gt 0 ]; then
		if [ $TEST -lt 1 ]; then
			for n in 1 2 3
			do
				[ $QUIET -lt 1 ] && error_echo "Installing Ookla speedtest rpm package.."
				[ $TEST -lt 1 ] dnf -y --refresh install speedtest
				LRET=$?

				if [ $LRET -eq 0 ]; then
					break
				fi
				# Problem installing the dependencies..
				error_echo "Error installing Ookla speedtest rpm package...waiting 10 seconds to try again.."
				sleep 10

			done
		fi
	fi
	
	debug_pause "${LINENO} -- ${FUNCNAME}() done."
	
	debug_pause "${LINENO} -- ${FUNCNAME}() done."
}

ookla_speedtest_install(){
	debug_echo "${FUNCNAME}( $@ )"
	local LINST_USER="$1"
	local LRET=1
	
	if [ $DIRECT -gt 0 ]; then
		ookla_speedtest_install_direct
		LRET=$?
	else
		ookla_speedtest_pm_sources_install && LRET=$? || LRET=$?
		#~ [ $LRET -eq 0 ] && 	pkgmgr_update && LRET=$? || LRET=$?
		if [ $LRET -eq 0 ]; then
			pkgmgr_install 'speedtest'
			LRET=$?
		else
			# If the package manager install fails (e.g. due to installing to a newer, 
			#   unsuported OS) try a direct install..
			ookla_speedtest_install_direct
			LRET=$?
		fi
		
	fi
	
	[ $QUIET -lt 1 ] && error_echo "Ookla speedtest installation complete."

	debug_pause "${LINENO} -- ${FUNCNAME}: returning ${LRET}"
	
}

############################################################################
# ookla_speedtest_remove() -- uninstalls speedtest & removes the apt source
############################################################################
ookla_speedtest_remove(){
	debug_echo "${FUNCNAME}( $@ )"

	local LSPEEDTEST_BIN="$(which speedtest 2>/dev/null)"
	local LRET=1
	
	# Uninstall the speedtest package
	if [ ! -z "$LSPEEDTEST_BIN" ]; then
		[ $QUIET -lt 1 ] && error_echo "Uninstalling ${LSPEEDTEST_BIN}"
		pkgmgr_uninstall 'speedtest'
	fi

	# If the speedtest binary is located in a PATH directory, but not installed via a package manager..
	[ -f "$LSPEEDTEST_BIN" ] && rm "$LSPEEDTEST_BIN"

	# Verify that speedtest has been removed from the PATH..
	[ $(which speedtest 2>/dev/null | wc -l) -lt 1 ] && LRET=0 || LRET=1

	[ $QUIET -lt 1 ] && error_echo "Ookla speedtest removal complete."

	debug_pause "${FUNCNAME}: returning ${LRET}"
	
	return $LRET
}



############################################################################
# ookla_license_has( username ) -- Checks for the existance of a license
#								   file for the specified user.
############################################################################
ookla_license_has(){
	debug_echo "${FUNCNAME}( $@ )"
	local LINST_USER="$1"
	local LHOME_DIR=
	local LLICENSE_FILE="$2"
	local LRET=1
	
	# Simple minded immediate check for a valid licence file..
	if [ ! -z "$LLICENSE_FILE" ] && [ -f "$LLICENSE_FILE" ] && [ $(grep -c 'LicenseAccepted' "$LLICENSE_FILE") -gt 0 ]; then
		[ $QUIET -lt 1 ] && error_echo "Ookla license file ${LLICENSE_FILE} exists and is VALID"
		LRET=0
	elif [ -z "$LINST_USER" ]; then
		# If no user, get the user who called sudo..
		LINST_USER="$(sudo_user_get)"
		LHOME_DIR="$(user_home_get "$LINST_USER")"
	elif ( is_user "$LINST_USER" ); then
		# has a user, may be root..
		LHOME_DIR="$(user_home_get "$LINST_USER")"
	elif [ "$(echo "$LINST_USER" | grep -c '/')" -gt 0 ]; then
		LLICENSE_FILE="$LINST_USER"
	else
		# punt!
		LINST_USER="$(whoami)"
		LHOME_DIR="$HOME"
	fi
	
	if [ -z "$LLICENSE_FILE" ]; then
		if [ $IS_MAC -gt 0 ]; then
			LLICENSE_FILE="/System/Volumes/Data/Users/${LINST_USER}/Library/Preferences/com.ookla.speedtest-cli/speedtest-cli.json"
		else
			LLICENSE_FILE="${LHOME_DIR}/.config/ookla/speedtest-cli.json"
		fi
	fi
	
	[ -f "$LLICENSE_FILE" ] && LRET=0 || LRET=1

	debug_pause "${FUNCNAME}: returning ${LRET}"

	return $LRET
}


############################################################################
# ookla_license_install( username ) -- Runs speedtest under a specified user
#                                      to generate an ookla license file for
#                                      that user.
############################################################################
ookla_license_install(){
	debug_echo "${FUNCNAME}( $@ )"
	local LINST_USER="$1"
	local LINST_GROUP=
	local LHOME_DIR="$2"
	local LLICENSE_DIR=
	local LLICENSE_FILE=
	local LROOT_LICENSE_FILE="${HOME}/.config/ookla/speedtest-cli.json"
	local LOOKLA="$(which speedtest 2>/dev/null)"
	local LINST_METHOD=0
	local LRET=1
	
	if [ -z "$LOOKLA" ]; then
		error_echo "${FUNCNAME}() Error: ookla speedtest package is not installed."
		exit 1
	fi
	
	# optional parameter 1 can be a user name or a fully qualified pathname for the license file
	
	if [ -z "$LINST_USER" ]; then
		# If no user, get the user who called sudo..
		LINST_USER="$(sudo_user_get)"
		LHOME_DIR="$(user_home_get "$LINST_USER")"
		LINST_METHOD=1
	elif [ ! -z "$LHOME_DIR" ] && [ -d "$LHOME_DIR" ]; then
		LLICENSE_FILE="${LHOME_DIR}/.config/ookla/speedtest-cli.json"
		LLICENSE_DIR="$(dirname "$LLICENSE_FILE")"
		is_user "$LINST_USER" || LINST_USER="$(stat -c '%U' "$LHOME_DIR")"
		LINST_METHOD=2
	elif ( is_user "$LINST_USER" ); then
		# has a user, may be root..
		LHOME_DIR="$(user_home_get "$LINST_USER")"
		LINST_METHOD=3
	elif [ "$(echo "$LINST_USER" | grep -c '/')" -gt 0 ]; then
		# not a user, is a pathname like: /home/pi/.config/ookla/speedtest-cli.json
		# warning: doesn't check for a valad path..
		LLICENSE_FILE="$LINST_USER"
		LINST_USER=
		LLICENSE_DIR="$(dirname "$LLICENSE_FILE")"
		LHOME_DIR="$(echo "$LLICENSE_FILE" | sed -e 's#^\(.*\)/\.config.*$#\1#')"
		echo "$HOME_DIR" | sed -n -e 's#^/home/\(.*\).*$#\1#p'
		LINST_METHOD=4
	else
		# punt!
		LHOME_DIR="$HOME"
		LINST_METHOD=5
	fi
	
	# Get the user if we don't already know it..
	if [ -z "$LINST_USER" ]; then
		# Get the owner of the home dir..
		LINST_USER="$(stat -c '%U' "$LHOME_DIR")"

		# If that didn't work, try to figure out from the path..
		if [ -z "$LINST_USER" ]; then
			LINST_USER="$(echo "$LHOME_DIR" | sed -n -e 's#^/home/\(.*\).*$#\1#p')"
		fi
	
		# Punt!
		if [ -z "$LINST_USER" ]; then
			LINST_USER="$(sudo_user_get)"
		fi
	fi
	
	LINST_GROUP="$(user_group_get "$LINST_USER")"
	
	[ -z "$LLICENSE_DIR" ] && LLICENSE_DIR="${LHOME_DIR}/.config/ookla"
	[ -z "$LLICENSE_FILE" ] && LLICENSE_FILE="${LLICENSE_DIR}/speedtest-cli.json"
	
	if [ $IS_MAC -gt 0 ]; then
		LROOT_LICENSE_FILE='/var/root/Library/Preferences/com.ookla.speedtest-cli/speedtest-cli.json'
		LLICENSE_FILE="/System/Volumes/Data/Users/${LINST_USER}/Library/Preferences/com.ookla.speedtest-cli/speedtest-cli.json"
		LLICENSE_DIR="$(dirname "$LLICENSE_FILE")"
		LHOME_DIR="$(echo "$LLICENSE_FILE" | sed -e 's#^\(.*\)/\.config.*$#\1#')"
		LINST_METHOD=5

	fi
	
	if [ $DEBUG -gt 0 ]; then
		error_echo ' '
		error_echo "             DEBUG == ${DEBUG}"
		error_echo "      LINST_METHOD == ${LINST_METHOD}"
		error_echo "        LINST_USER == ${LINST_USER}"
		error_echo "       LINST_GROUP == ${LINST_GROUP}"
		error_echo "         LHOME_DIR == ${LHOME_DIR}"
		error_echo "      LLICENSE_DIR == ${LLICENSE_DIR}"
		error_echo "     LLICENSE_FILE == ${LLICENSE_FILE}"
		error_echo "LROOT_LICENSE_FILE == ${LROOT_LICENSE_FILE}"
		error_echo ' '
		debug_pause "${LINENO} -- ${FUNCNAME}()"
	fi

	if [[ -f "$LLICENSE_FILE" ]] && [[ $FORCE -lt 1 ]]; then
		error_echo "Ookla speed test licence file ${LLICENSE_FILE} already installed.  Use --force to reinstall."
		return 0
	fi

	# Create the home directory if needed..
	#~ if [ ! -d "$LHOME_DIR" ]; then
		#~ [ $TEST -lt 1 ] && mkdir -p "$LHOME_DIR"
	#~ fi

	# Make sure the user has the appropriate permissions to the  directory
	[ ! -d "$LLICENSE_DIR" ] && mkdir -p "$LLICENSE_DIR"
	[ $QUIET -lt 1 ] && error_echo "Fixing permissions for ${LINST_USER}:${LINST_GROUP} to ${LLICENSE_DIR}.."
	[ $TEST -lt 1 ] && chown -R "${LINST_USER}:${LINST_GROUP}" "${LLICENSE_DIR}"
	
	# Now run the speedtest under the user account setting the home directory
	[ $QUIET -lt 1 ] && error_echo "Running ${LOOKLA} to generate a license file at ${LLICENSE_FILE}"
	
	[ $DEBUG -gt 0 ] && echo sudo HOME="$LHOME_DIR" -u "$LINST_USER" yes \| "$LOOKLA" --progress=no --format=csv --server-id=18002
	debug_pause "${LINENO} -- ${FUNCNAME}()"

	# Make 3 attempts at installing the licence file..
	for n in 1 2 3
	do
		# speedtest doesn't seem to respect the HOME variable..instead 
		[ $TEST -lt 1 ] && sudo HOME="$LHOME_DIR" -u "$LINST_USER" yes | "$LOOKLA" --progress=no --format=csv --server-id=18002
		
		# If the license file got installed to root..
		if [ ! -f "$LLICENSE_FILE" ] && [ -f "$LROOT_LICENSE_FILE" ]; then
			[ $QUIET -lt 1 ] && error_echo "Copying ${LROOT_LICENSE_FILE} to ${LLICENSE_FILE}.."
			[ $TEST -lt 1 ] && cp -p "$LROOT_LICENSE_FILE" "$LLICENSE_FILE"
		fi
		
		if [ ! -f "$LLICENSE_FILE" ]; then
			LRET=1
			error_echo "${FUNCNAME}() Error: Olkla license file ${LLICENSE_FILE} was NOT installed."
		else
			[ $TEST -lt 1 ] && chown -R "${LINST_USER}:${LINST_GROUP}" "$LLICENSE_DIR"
			[ $QUIET -lt 1 ] && error_echo ' '
			[ $QUIET -lt 1 ] && error_echo "Ookla Licence file ${LLICENSE_FILE} successfully generated."
			[ $QUIET -lt 1 ] && error_echo ' '
			LRET=0
		fi
		
		[ $LRET -lt 1 ] && break
	
	done
	
	[ -f "$LLICENSE_FILE" ] && debug_cat "$LLICENSE_FILE"
	debug_pause "${FUNCNAME}: returning ${LRET}"

	return $LRET
}

############################################################################
# ookla_license_remove() -- Removes the ookla license file by looking
#                           in places it might be found..
############################################################################
ookla_license_remove(){
	debug_echo "${FUNCNAME}( $@ )"

	local LLICENSE_FILE="$1"
	local LLICENSE_DIR="/var/lib/${INST_NAME}/.config/ookla"
	local LUSER=
	local LHOME_DIR=
	
	if [ ! -z "$LLICENSE_FILE" ] && [ -f "$LLICENSE_FILE" ]; then
		LUSER="$(stat -c '%U' "$LLICENSE_FILE")"		
		[ $QUIET -lt 1 ] && error_echo "Removing ookla license file ${LLICENSE_FILE} for user ${LUSER}."
		[ $TEST -lt 1 ] && rm "$LLICENSE_FILE"
	fi
	
	for LUSER in 'root' 'pi' 'daadmin' 'lcwa-speed' "$(sudo_user_get)"
	do
		LHOME_DIR="$(user_home_get "$LUSER")"
		if [ -z "$LHOME_DIR" ]; then
			continue
		fi
		if [ $IS_MAC -gt 0 ]; then
			LLICENSE_FILE="/System/Volumes/Data/Users/${LUSER}/Library/Preferences/com.ookla.speedtest-cli/speedtest-cli.json"
		else
			LLICENSE_FILE="${LHOME_DIR}/.config/ookla/speedtest-cli.json"
		fi
		
		if [ $DEBUG -gt 0 ]; then
			error_echo ' '
			error_echo "        DEBUG == ${DEBUG}"
			error_echo "        LUSER == ${LUSER}"
			error_echo "    LHOME_DIR == ${LHOME_DIR}"
			error_echo "LLICENSE_FILE == ${LLICENSE_FILE}"
			error_echo ' '
			debug_pause "${LINENO} -- ${FUNCNAME}() done."
		fi
		
		if [ -f "$LLICENSE_FILE" ]; then
			[ $QUIET -lt 1 ] && error_echo "Removing ookla license file ${LLICENSE_FILE} for user ${LUSER}."
			[ $TEST -lt 1 ] && rm "$LLICENSE_FILE"
		else
			debug_echo "${FUNCNAME}() No ${LLICENSE_FILE} file to remove for user ${LUSER}"
		fi
	done

	debug_pause "${LINENO} -- ${FUNCNAME}() done."
	
}

wget_check(){
	local LWGET="$(which wget)"
	[ $IS_MAC -gt 0 ] && return 1
	[ -z "$LWGET" ] && pkgmgr_install 'wget'
}


banner_pause(){
	local LSPEEDTEST="$(which speedtest 2>/dev/null)"
	
	if [ $QUIET -lt 1 ]; then

		if [ $REMOVE -gt 0 ] && [ $INSTALL -gt 0 ]; then
			[ ! -z "$LSPEEDTEST" ] && error_echo "Removing ${LSPEEDTEST} and installing the latest" || error_echo "Installing Ookla speedtest with the latest"
			error_echo "version from the Ookla website."

		elif [ $UPDATE -gt 0 ] && [ $INSTALL -eq 0 ]; then
			true
			#~ error_echo "Ookla speedtest currently installed version ${CUR_VERSION} is newer or equal to "
			#~ error_echo "candidate version ${INST_VERSION}. Use --force to force a reinstall."
		elif [ $UPDATE -gt 0 ]; then
			error_echo "Updating Ookla speedtest with the latest"
			error_echo "version from the Ookla website."			
		elif [ $REMOVE -gt 0 ]; then
			error_echo "Removing ${LSPEEDTEST} and its package manager source list."
		elif [ $INSTALL -gt 0 ]; then
			[ ! -z "$LSPEEDTEST" ] && error_echo "Replacing ${LSPEEDTEST} with the latest" || error_echo "Installing Ookla speedtest with the latest"
			error_echo "version from the Ookla website."
		fi
	
		debug_echo ' '
		debug_echo "       DEBUG == ${DEBUG}"
		debug_echo "    NO_PAUSE == ${NO_PAUSE}"
		debug_echo "       FORCE == ${FORCE}"
		debug_echo "        TEST == ${TEST}"
		debug_echo "       QUIET == ${QUIET}"
		debug_echo "         OUT == ${OUT}"
		debug_echo "      REMOVE == ${REMOVE}"
		debug_echo "     INSTALL == ${INSTALL}"
		debug_echo "      UPDATE == ${UPDATE}"
		debug_echo "      DIRECT == ${DIRECT}"
		debug_echo "   INST_USER == ${INST_USER}"
		debug_echo "INST_VERSION == ${INST_VERSION}"
		debug_echo " CUR_VERSION == ${CUR_VERSION}"
		debug_echo ' '

		if [ $NO_PAUSE -lt 1 ]; then
			error_echo ' '
			error_echo "Press any key to continue, or"
			pause "Ctrl-C to abort."
		fi
	fi
	
}

########################################################################
# help_disp() -- display the getopt allowable args
########################################################################
help_disp(){
	local LSCRIPT_NAME="$(basename "$0")"
	local LDESCRIPTION="$1"
	local LEXTRA_ARGS="${@:2}"
	if [ $IS_MAC -gt 0 ]; then
		error_echo "Syntax: ${LSCRIPT_NAME} ${LEXTRA_ARGS} $(echo "$SHORTARGS" | sed -e 's/, //g' -e 's/\(.\)/[-\1] /g')"
		return 0
	fi

	error_echo  -e "\n${LSCRIPT_NAME}: ${LDESCRIPTION}"
	error_echo -e "\nSyntax: ${LSCRIPT_NAME} ${LEXTRA_ARGS}\n"
	error_echo "            Optional parameters:"
	cat "$(readlink -f "$0")" | grep -E '^\s+-' | grep -v -- '--)' | sed 's/)//' 1>&2
	error_echo ' '
}

############################################################################
############################################################################
############################################################################
# main()
############################################################################
############################################################################
############################################################################

PRE_ARGS="$@"

# Make sure we're running as root 
is_root


SHORTARGS='hdqvtfnruik'
LONGARGS="
help,
debug,
quiet,
verbose,
test,
force,
no-pause,
update,
remove,
install,
direct,
license-only,
env-file:"

# Remove line-feeds..
LONGARGS="$(echo "$LONGARGS" | sed ':a;N;$!ba;s/\n//g')"

PREARGS="$@"

if [ $IS_MAC -gt 0 ]; then
	ARGS=$(/usr/bin/getopt "$SHORTARGS" -- "$@")
	ERR=$?
else
	ARGS=$(getopt -o "$SHORTARGS" -l "$LONGARGS"  -n "$SCRIPT_NAME" -- $@)
	ERR=$?
fi

if [ $ERR -gt 0 ]; then
	help_disp "$INST_DESC" '[optional_license_username or license_file_path]'
	exit 1
fi

eval set -- "$ARGS"

# get args
while test $# -gt 0
do
	case "$1" in
		--)
			;;
		-h|--help)	# Display this help
			help_disp "$INST_DESC" '[optional_license_username or license_file_path]'
			exit 0
			;;
		-d|--debug)	# Emit debugging info
			# Increment the debug value
			((DEBUG++))
			;;
		-q|--quiet)	# Supress messages
			QUIET=1
			;;
		-t|--test)	# Test logic, but perform no actions.
			TEST=1
			;;
		-f|--force)	# Force reinstall of speedtest
			FORCE=1
			;;
		-n|--no-pause)	# Supress prompt and pause
			NO_PAUSE=1
			;;
		-u|--update)	# Install or update any existing Ookla speedtest install
			REMOVE=0
			INSTALL=0
			UPDATE=1
			;;
		-r|--remove)	# Remove Ookla speedtest install
			REMOVE=1
			INSTALL=0
			UPDATE=0
			;;
		-i|--install)	# Remove any existing Ookla install and then reinstall
			UPDATE=1
			INSTALL=1
			;;
		-k|--direct)	# Install from downloaded tar.gz rather than via apt-get.
			DIRECT=1
			;;
		--license-only)
			LICENSE_ONLY=1
			;;
		--env-file)		# =NAME -- Read a specific env file to get the locations for the install.
			shift
			LCWA_ENVFILE="$1"
			[ -f "$LCWA_ENVFILE" ] && LCWA_ENVFILE="$(readlink -f "$LCWA_ENVFILE")"
			;;
		*)
			INST_USER="$1"
			;;
	esac
	shift
done

[ $VERBOSE -gt 0 ] && error_echo "${SCRIPTNAME} ${PRE_ARGS}"

# Force direct (non-package manager) download & install for rpi systems..
[ $(uname -m | grep -c 'arm') -gt 0 ] && DIRECT=1


if [ ! -z "$LCWA_ENVFILE" ] && [ -f "$LCWA_ENVFILE" ]; then
	[ $QUIET -lt 1 ] && error_echo "Getting service user ${LCWA_ENVFILE}."
	. "$LCWA_ENVFILE"
	if [ $? -gt 0 ]; then
		error_echo "${SCRIPT_NAME} fatal error: could not read from ${LCWA_ENVFILE}. Exiting."
		exit 1
	fi
	#~ /var/lib/lcwa-speed/.config/ookla/speedtest-cli.json
	INST_LICENSE_FILE="${LCWA_HOMEDIR}/.config/ookla/speedtest-cli.json"
	INST_USER="$INST_LICENSE_FILE"
fi

# Parameter checking..
if [ ! -z "$INST_USER" ]; then
	if ( is_user "$INST_USER" ); then
		INST_LICENSE_FILE=""
	elif [ $(echo "$INST_USER" | grep -c '/') -gt 0 ]; then
		INST_LICENSE_FILE="$INST_USER"
	else
		error_echo "${SCRIPT_NAME} error: '${INST_USER}' is neither a valid user name or licence-file path."
		help_disp
		exit 1
	fi
fi

if [ $LICENSE_ONLY -gt 0 ]; then
	ookla_license_install "$INST_USER" "$INST_LICENSE_FILE"
	exit $?
fi

# No package manager install available for macOS
[ $IS_MAC -gt 0 ] && DIRECT=1

# See if we need to update..
if [ $UPDATE -gt 0 ]; then
	CUR_VERSION="$(ookla_speedtest_version_get)"
	INSTALL=0
	REMOVE=0
	if [ -z "$CUR_VERSION" ]; then
		UPDATE=0
		INSTALL=1
	#~ elif [ ! -f "$INST_LICENSE_FILE" ]; then
		#~ INSTALL=1
	else
		vercomp2 "$INST_VERSION" "$CUR_VERSION"
		case $? in
			0)	# Current version == install candidate. Update not needed unless forced.
				[ $FORCE -gt 0 ] && INSTALL=1
				#~ UPDATE=0
				;;
			1)	# Update required
				INSTALL=1
				;;
			2)	# Current newer than install candidate. Update not needed unless forced.
				[ $FORCE -gt 0 ] && INSTALL=1
				#~ INSTALL=0
				;;
		esac
		
	fi
fi

# Display our banner and then pause..
[ $NO_BANNER -lt 1 ] && banner_pause

if [ $REMOVE -gt 0 ]; then
	ookla_speedtest_remove
	ookla_speedtest_pm_sources_remove
	ookla_license_has "$INST_USER" && ookla_license_remove "$INST_USER"
	
elif [ $UPDATE -eq 1 ] && [ $INSTALL -eq 0 ]; then

	if [ $QUIET -lt 1 ]; then
		error_echo "Ookla speedtest currently installed version ${CUR_VERSION} is newer or equal to "
		error_echo "candidate version ${INST_VERSION}. Use --force to force a reinstall."
	fi
	
	# Speedtest may be installed, but we need a licence file too!
	ookla_license_has "$INST_USER" "$INST_LICENSE_FILE" || ookla_license_install "$INST_USER" "$INST_LICENSE_FILE"

	[ $QUIET -lt 1 ] && error_echo ' '
	[ $QUIET -lt 1 ] && error_echo "${SCRIPT_NAME} ${PREARGS} finished."
	exit 0

fi

if [ $INSTALL -gt 0 ]; then

	if [ $UPDATE -gt 0 ]; then
		[ $QUIET -lt 1 ] && error_echo "Updating Current version of Ookla speedtest from ${CUR_VERSION} to ${INST_VERSION}"
	else
		[ $QUIET -lt 1 ] && error_echo "Installing Ookla speedtest ${INST_VERSION}"
	fi
	error_echo ' '
	ookla_speedtest_install "$INST_USER"
	
	ookla_license_install "$INST_USER" "$LCWA_HOMEDIR"

fi

[ $QUIET -lt 1 ] && error_echo ' '
[ $QUIET -lt 1 ] && error_echo "${SCRIPT_NAME} ${PREARGS} finished."
