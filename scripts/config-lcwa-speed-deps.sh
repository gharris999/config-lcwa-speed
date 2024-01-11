#!/bin/bash

######################################################################################################
# Bash script for installing dependencies required for Andi Klein's Python LCWA PPPoE Speedtest Logger
#   A python3 venv will be installed to /usr/local/share/lcwa-speed
######################################################################################################
SCRIPT_VERSION=20231227.100815

SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
SCRIPT_NAME="$(basename $0)"
SCRIPT_DESC="Installs system and python library dependencies for the lcwa-speed service."


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
NO_PAUSE=0

# Save our HOME var to be restored later..
CUR_HOME="$HOME"

# Change to 1 to prevent updates to the env file
INST_ENVFILE_LOCK=0

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

NEEDSUSER=1
NEEDSDATA=1
KEEPCACHE=0
NO_CLEAN=1

LIST_PIP_LIBS=0
UPDATE_PIP_LIBS=0

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




#~ LCWA_SERVICE="$INST_NAME"
#~ LCWA_INSTDIR="/usr/local/share/${LCWA_SERVICE}"
#~ LCWA_REPO_LOCAL="${LCWA_INSTDIR}/speedtest"
#~ LCWA_HOMEDIR="/var/lib/${INST_NAME}"
#~ LCWA_DATADIR="${LCWA_HOMEDIR}/speedfiles"


instance_dir_create(){
	debug_echo "${FUNCNAME}( $@ )"
	local LINST_DIR="${1:-${LCWA_INSTDIR}}"
	
	if [ ! -d "$LINST_DIR" ]; then
		error_echo "Creating ${LINST_DIR} home dir for ${INST_USER}.."
		mkdir -p "$LINST_DIR"
	fi

	error_echo "Fixing permissions for ${INST_USER}:${INST_GROUP} on ${LINST_DIR}.."
	chown --silent -R "${INST_USER}:${INST_GROUP}" "$LINST_DIR"

	debug_echo "${LINENO} -- ${FUNCNAME}() done."

	[ -d "$LINST_DIR" ] && return 0 || return 1
}

home_dir_create(){
	debug_echo "${FUNCNAME}( $@ )"
	local LLCWA_HOMEDIR="${1:-${LCWA_HOMEDIR}}"

	if [ ! -d "$LLCWA_HOMEDIR" ]; then
		error_echo "Creating ${LLCWA_HOMEDIR} home dir for ${INST_USER}.."
		mkdir -p "$LLCWA_HOMEDIR"
	fi

	error_echo "Fixing permissions for ${INST_USER}:${INST_GROUP} on ${LLCWA_HOMEDIR}.."
	chown --silent -R "${INST_USER}:${INST_GROUP}" "$LLCWA_HOMEDIR"

	debug_echo "${LINENO} -- ${FUNCNAME}() done."

	[ -d "$LLCWA_HOMEDIR" ] && return 0 || return 1
}

is_raspberry_pi(){
	debug_echo "${FUNCNAME}( $@ )"
	
	[ $FORCE -gt 0 ] && return 0
	
	local LIS_RPI=0

	if [ -z "$(which lsb_release 2>/dev/null)" ]; then
		[ $QUIET -lt 1 ] && error_echo "${SCRIPT_NAME} error: no lsb_release found."
		[ $QUIET -lt 1 ] && error_echo "This system is probably not a Raspberry Pi."
		return 1
	fi

	# Raspbian GNU/Linux 10 (buster) & Raspbian GNU/Linux 11 (bullseye)
	LIS_RPI=$(lsb_release -sd | grep -c 'Raspbian')

	if [ $LIS_RPI -lt 1 ]; then
		error_echo "${SCRIPT_NAME}: lsb_release reports $(lsb_release -sd)."
		error_echo "This system is probably not a Raspberry Pi."
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
		[ $CACHE_AGE -gt $MAX_AGE ] && [ $VERBOSE -gt 0 ] && error_echo "Local cache is out of date. Updating apt-get package cacahe.." || error_echo "Updating apt-get package cacahe.."
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
	
	[ $VERBOSE -gt 0 ] && error_echo "Packages selected for install: ${LPKG_LIST}"
	
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
			[ $TEST -lt 1 ] && apt-get -y -qq -o Dpkg::Options::="--force-confold" install "$LPKG"
			
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
	
	debug_echo "${LINENO} -- ${FUNCNAME}() done."
	return $LRET
}

############################################################################
# apt_uninstall() -- Removes packages & their config files without prompting.
############################################################################
apt_uninstall(){
	debug_echo "${FUNCNAME}( $@ )"

	export DEBIAN_FRONTEND=noninteractive

	apt-get purge -y "$@" >/dev/null 2>&1
	apt autoremove >/dev/null 2>&1
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
		[ $TEST -lt 1 ] && dnf install -y --allowerasing "$LPKG"
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

pip_libs_list(){
	debug_echo "${FUNCNAME}( $@ )"
	local LLCWA_INST_DIR="${1:-${LCWA_INSTDIR}}"
	local LUSER="${2:-${LCWA_USER}}"
	local LLCWA_HOMEDIR="${3:-${LCWA_HOMEDIR}}"
	local LUPDATABLE_ONLY="${4:-0}"

	local LGROUP="$(id -gn "$LUSER")"
	local LINST_PIP3="${LLCWA_INST_DIR}/bin/pip3"
	local LCACHE_DIR="${LLCWA_HOMEDIR}/.cache/pip}"
	local LPIP3_DIR=
	local LCUR_DIR=


	if [ ! -x "$LINST_PIP3" ]; then
		error_echo "Error: venv pip3 ${LINST_PIP3} not found."
		debug_pause "${LINENO} -- ${FUNCNAME}() done."
		return 1
	fi

	if [ ! -d "$LCACHE_DIR" ]; then
		error_echo "Creating pip cache directory ${LCACHE_DIR}.."
		[ $TEST -lt 1 ] && mkdir -p "$LCACHE_DIR"
		[ $TEST -lt 1 ] && chown --silent -R "${LUSER}:${LGROUP}" "$LCACHE_DIR"
	fi

	LPIP3_DIR="$(dirname "${LINST_PIP3}")"
	LCUR_DIR="$(pwd)"

	cd "$LPIP3_DIR"

	error_echo '========================================================'
	error_echo 'Out of date pip3 packages in this venv:'
	error_echo ' '
	sudo -H -u "$LUSER" "$LINST_PIP3" list --local --outdated --default-timeout=60 --cache-dir "$LCACHE_DIR"
	if [ $? -gt 0 ]; then
		error_echo ' '
		error_echo "Pip3 Timeout Error: could not fetch list up updatable pip3 packages."
	fi
	error_echo ' '
	if [ $LUPDATABLE_ONLY -lt 1 ]; then
		error_echo 'Up to date pip3 packages in this venv:'
		error_echo ' '
		sudo -H -u "$LUSER" "$LINST_PIP3" list --local --uptodate --default-timeout=60 --cache-dir "$LCACHE_DIR"
		if [ $? -gt 0 ]; then
			error_echo ' '
			error_echo "Pip3 Timeout Error: could not fetch list up updatable pip3 packages."
		fi
		error_echo ' '
	fi

	cd "$LCUR_DIR"

	[ $TEST -lt 1 ] && debug_echo "${LINENO} -- ${FUNCNAME}() done."
}

############################################################################
# pip_libs_install ( pip3_path, username, cache_dir, library_list) -- Installs or updates
#              python libraries via pip3 for user 'username'.  Works for
#			   venv virtual environment installs.  Requirement:
#              For some libraries, username *must* have a /home/username
#			   directory.  Apparently, pip caches /home/user/.cache/pip/http
#			   data there despite the --cache-dir setting.
############################################################################
pip_libs_install(){
	debug_echo "${FUNCNAME}( $@ )"
	local LPIP3="${1:-$(which pip3)}"
	local LUSER="${2:-${INST_USER}}"
	local LCACHE_DIR="${3:-/home/${LUSER}/.cache/pip}"
	local LLIB_LIST="$4"
	local LGROUP="$(id -gn "$LUSER")"
	local LFAKE_HOME="/home/${INST_USER}"
	local LLIB=
	local LACTION=
	
	if ! ( is_user "$LUSER" ); then
		error_echo "Error: ${LUSER} -- no such user."
		return 1
	fi
	
	# Even with venv, pip seems to require a user have a /home/user directory for ..
	if [ ! -d "$LFAKE_HOME" ]; then
		error_echo "Creating fake home ${LFAKE_HOME} for pip3 libraries install.."
		[ $TEST -lt 1 ] && mkdir -p "$LFAKE_HOME"
		[ $TEST -lt 1 ] && chown --silent -R "${INST_USER}:${INST_GROUP}" "$LFAKE_HOME"
		HOME="$LFAKE_HOME"
	else
		LFAKE_HOME=
	fi

	# Have pip3 install one library at a time.  Much better odds of success this way.
	for LLIB in $LLIB_LIST
	do
	
		# Check to see if the library is already installed
		if "${LCWA_INSTDIR}/bin/python3" -c "import ${LLIB}" >/dev/null 2>&1; then
			if [ $UPDATE_PIP_LIBS -gt 0 ]; then
				LACTION='updating'
			else
				LACTION='installing'
				[ $QUIET -lt 1 ] && error_echo "Library ${LLIB} already installed.."
				[ $FORCE -lt 1 ] && continue
			fi
		fi
	
		for n in 1 2 3 4 5
		do
			# Allow 20 minutes for any download before timing out and retrying.  Useful for
			# large libraries and slow internet connections.
			if [ $UPDATE_PIP_LIBS -gt 0 ]; then
				[ $QUIET -lt 1 ] && error_echo "Checking library ${LLIB}.."
				[ $TEST -lt 1 ] && sudo -H -u "$LUSER" "$LPIP3" install --upgrade --default-timeout=1200 "--cache-dir=${LCACHE_DIR}" "$LLIB"
				LRET=$?
				[ $TEST -gt 0 ] && LRET=0
			else
				[ $QUIET -lt 1 ] && error_echo "Pip ${LACTION} ${LLIB}.."
				[ $TEST -lt 1 ] && sudo -H -u "$LUSER" "$LPIP3" install -qq --default-timeout=1200 "--cache-dir=${LCACHE_DIR}" --force-reinstall "$LLIB"
				LRET=$?
				[ $TEST -gt 0 ] && LRET=0
			fi

			if [ $LRET -gt 0 ]; then
				error_echo "Error ${LACTION} python3 library ${LLIB}...waiting 10 seconds to try again.."
				debug_pause "${LINENO} -- ${FUNCNAME}() Problem with ${LLIB}."
				sleep 10
			else
				# on the the next
				break
			fi

		done
	done
	
	HOME="$CUR_HOME"

	# Remove the fake home directory. The important cache still exists at 
	[ ! -z "$LFAKE_HOME" ] && [ -d "$LFAKE_HOME" ] && [ $KEEPCACHE -lt 1 ] && rm -Rf "$LFAKE_HOME"

	[ $TEST -lt 1 ] && debug_echo "${LINENO} -- ${FUNCNAME}() done."
	return $LRET
}


############################################################################
# jq_install() -- Installs the jq json cmd line processor
############################################################################
jq_install(){
	debug_echo "${FUNCNAME}( $@ )"
	local LRET=1
	
	if [ -z "$(which jq)" ] || [ $FORCE -gt 0 ]; then
	
		error_echo "Installing jq commandline JSON processor.."

		local LURL=
		local LSOURCE=
		local LTARGET=

		# Don't use a package manager so as to get a newer version of jq..
		case "$(uname -m)" in
			x86_64)
				LURL="https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64"
				;;
			i686|i386)
				LURL="https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux32"
				;;
			armv7l|armv6l)
				# RPi4b | RPi0
				apt_install 'jq'
				;;
		esac
		
		if [ ! -z "$LURL" ]; then
			LSOURCE='/tmp/jq'
			LTARGET='/usr/local/bin/jq'
			error_echo "Downloading ${LURL} to ${LSOURCE}.."
			wget -q "$LURL" -O "$LSOURCE"
			if [ $( file "$LSOURCE" | grep -c -E 'executable.*statically' ) -gt 0 ]; then
				chmod 755 "$LSOURCE"
				[ -f "$LTARGET" ] && mv "$LTARGET" "${LTARGET}.bak"
				[ $QUIET -lt 1 ] && error_echo "Copying ${LSOURCE} to ${LTARGET}.."
				[ $TEST -lt 1 ] && cp -p "$LSOURCE" "$LTARGET"
				rm "$LSOURCE"
			fi
		fi
		
	fi
	
	if [ $(which jq | wc -l) -gt 0 ]; then
		LRET=0
		[ $QUIET -lt 1 ] && error_echo "jq successfully installed."
	else
		LRET=1
		error_echo "${FUNCNAME}() error: could not install jq."
	fi
		
	debug_echo "${LINENO} -- ${FUNCNAME}() done."
	return $LRET
}


pkg_check(){
	debug_echo "${FUNCNAME}( $@ )"
	local LPKG_LIST="$1"
	local LPKG=
	local LPKGS=""
	local LPKG_ERRS=""
	local LRET=1
	
	if [ $USE_APT -gt 0 ]; then
		for LPKG in $LPKG_LIST;
		do
			if [ $(apt-cache pkgnames "$LPKG" | wc -l) -lt 1 ]; then
				error_echo "Error: Package ${LPKG} not found."
				LPKG_ERRS="${LPKG_ERRS} ${LPKG}"
			else
				LPKGS="${LPKGS} ${LPKG}"
			fi
		done
	elif [ $USE_YUM -gt 0 ]; then
		LPKGS="$(dnf list $LPKG_LIST | grep -v 'Last metadata' | sed -n -e 's/^\([^\.]\+\)\..*$/\1/p' | xargs)"
		for LPKG in $LPKG_LIST
		do
			if [ $(echo "$LPKG" | grep -c -w "$LPKGS") -lt 1 ]; then
				error_echo "Error: Package ${LPKG} not found."
				LPKG_ERRS="${LPKG_ERRS} ${LPKG}"
			fi
		done

	fi
	
	if [ ! -z "$LPKG_ERRS" ]; then
		LRET=1
		error_echo "Error -- the following packages were not found: ${LPKG_ERRS}"
		DEBUG=3
	else
		LRET=0
	fi
	
	
	debug_echo "${LINENO} -- ${FUNCNAME}() found packages: ${LPKGS}"

	echo "$LPKGS" | xargs
	return $LRET
}

############################################################################
# pkg_deps_install() -- Installs all dependencies available via apt
############################################################################
pkg_deps_install(){
	debug_echo "${FUNCNAME}( $@ )"

	local LRET=1
	local LIBFFI=
	local LPKG_LIST=
	local LPKG=

	[ $QUIET -gt 0 ] && error_echo "Installing system development package dependencies.."

	if [ $TEST -lt 1 ]; then

		if [ $USE_APT -gt 0 ]; then
		
			# Update the apt cache..
			[ $FORCE -gt 1 ] && apt_update
		
			#~ [ $IS_FOCAL -lt 1 ] && LIBFFI='libffi6' || LIBFFI='libffi7'
			LIBFFI="$(apt-cache search 'libffi[0-9]{1,3}' | awk '{ print $1 }')"
			
			LPKG_LIST=" \
				bc \
				jq \
				dnsutils \
				iperf3 \
				wget \
				whois \
				ufw \
				file \
				git \
				git-extras \
				gzip \
				zip \
				unzip \
				sshpass \
				gnupg1 \
				espeak \
				pulseaudio \
				build-essential \
				git \
				git-extras \
				scons \
				swig \
				libffi-dev \
				${LIBFFI} \
				at-spi2-core"
				
			LPKG_LIST="$(echo $LPKG_LIST | xargs)"
			
			[ $QUIET -gt 0 ] && error_echo "Checking package list.."

			LPKG_LIST="$(pkg_check "$LPKG_LIST")"
			
			apt_install $LPKG_LIST
			LRET=$?

		elif [ $USE_YUM -gt 0 ]; then
			#Install dependencies for Fedora 32 and newer..
			#~ dnf groupinstall -y "Development Tools"
			#~ dnf groupinstall -y "C Development Tools and Libraries"
			dnf_update
			dnf groupinstall -y "Development Tools" "Development Libraries"
			LRET=$?

			if [ $LRET -gt 0 ]; then
				error_echo "${FUNCNAME} error installing development tools"
			fi
			
			LPKG_LIST=" \
				bc \
				jq \
				bind-utils \
				iperf3 \
				wget \
				whois \
				gzip \
				zip \
				unzip \
				sshpass \
				gnupg1 \
				espeak \
				sshpass \
				pulseaudio \
				git \
				git-extras \
				python3-scons \
				swig \
				libffi-devel \
				libffi \
				at-spi2-core"
				
			LPKG_LIST="$(echo $LPKG_LIST | xargs)"
			
			LPKG_LIST="$(pkg_check "$LPKG_LIST")"
			
			dnf_install $LPKG_LIST

			dnf install -y $LPKG_LIST
			LRET=$?
		fi
		
		# Fix for missing liblibiperf.a
		# Find libiperf3.a
		LIBIPERF="$(find /usr -name 'libiperf\.a' -print -quit)"

		# See if there is a liblibiperf.a
		LIBLIBIPERF="$(find /usr -name 'liblibiperf\.a')"

		if [ ! -f "$LIBLIBIPERF" ]; then
			if [ -f "$LIBIPERF" ]; then
				LIBLIBIPERF="$(dirname "$LIBIPERF")/liblibiperf.a"
				echo ' '
				echo "Creating link: ln -s ${LIBIPERF} ${LIBLIBIPERF}"
				echo "$DAADMIN_PASS" | sudo -S ln -s "$LIBIPERF" "$LIBLIBIPERF"
			fi
		fi

	fi
	
	# Install a pre-compiled updated version of jq
	#~ [ $TEST -lt 1 ] && jq_install

	debug_pause "${LINENO} -- ${FUNCNAME}() done."
	return $LRET
}


############################################################################
# python_libs_install() -- Installs python library dependencies
############################################################################
python_libs_install(){
	debug_echo "${FUNCNAME}( $@ )"
	
	local LLCWA_INST_DIR="${1:-${LCWA_INSTDIR}}"
	local LLCWA_HOMEDIR="${2:-${LCWA_HOMEDIR}}"
	local LPKG_LIST=
	local LPKG=
	local LFAKE_HOME=
	local LCUR_HOME="$HOME"
	
	local CURCD="$(pwd)"
	cd /tmp

	# Install system python3 development packages..
	
	error_echo "Installing python3 development dackages.."

	if [ $USE_APT -gt 0 ]; then
	
		[ $FORCE -gt 1 ] && apt_update
	
		# Figure out which version of python3-venv to install..
		local LVER="$(python3 --version | sed -n -e 's/^.* \([[:digit:]]\{1\}\.[[:digit:]]\{1\}\).*$/\1/p')"
		local LPYTHON_VENV="$(apt-cache search "python${LVER}.*-venv" | awk '{ print $1 }')"
		
		LPKG_LIST=" \
			python3 \
			python3-dev \
			python3-pip \
			${LPYTHON_VENV} \
			python3-tk \
			python3-gi-cairo \
			libfreetype6-dev \
			libpng-dev \
			pkg-config"
			
		LPKG_LIST="$(echo $LPKG_LIST | xargs)"

		[ $QUIET -gt 0 ] && error_echo "Checking package list.."

		LPKG_LIST="$(pkg_check "$LPKG_LIST")"

		apt_install "$LPKG_LIST"
		LRET=$?
		
	elif [ $USE_YUM -gt 0 ]; then

		LPKG_LIST=" \
			python3 \
			python3-devel \
			python3-pip \
			python3-tkinter\
			python3-gobject \
			gtk3 \
			freetype-devel \
			libpng-devel \
			pkgconf-pkg-config"

		LPKG_LIST="$(echo $LPKG_LIST | xargs)"
		LPKG_LIST="$(pkg_check "$LPKG_LIST")"
		
		dnf_update

		dnf_install $LPKG_LIST
		LRET=$?
	fi
	#~ debug_pause "${LINENO} -- ${FUNCNAME}() python3 development dackages done."

	# Install the python libraries needed for the speedtest code..

	
	# Point HOME towards our data directory for the python installs
	LCUR_HOME="$HOME"
	HOME="$LLCWA_HOMEDIR"

	error_echo "========================================================================================="
	error_echo "Installing venv python virtual environment to ${LLCWA_INST_DIR}, caching to ${LLCWA_HOMEDIR}/.cache/pip"
	error_echo "  HOME is set to ${HOME}"
	[ $TEST -lt 1 ] && sudo -H -u "$INST_USER" python3 -m venv "$LLCWA_INST_DIR"
	
	INST_PYTHON="${LLCWA_INST_DIR}/bin/python3"
	INST_PIP3="${LLCWA_INST_DIR}/bin/pip3"
	
	if [ ! -x "$INST_PYTHON" ]; then
		error_echo "Error: venv python3 ${INST_PYTHON} not found."
		debug_pause "${LINENO} -- ${FUNCNAME}() done."
		HOME="$LCUR_HOME"
		return 1
	fi

	if [ ! -x "$INST_PIP3" ]; then
		error_echo "Error: venv pip3 ${INST_PIP3} not found."
		debug_pause "${LINENO} -- ${FUNCNAME}() done."
		HOME="$LCUR_HOME"
		return 1
	fi
	
	debug_echo "${LINENO} -- ${FUNCNAME}() venv installation done."
	
	# Update pip3
	error_echo "Updating ${INST_PIP3}.."
	[ $TEST -lt 1 ] && sudo -H -u "$INST_USER" "$INST_PIP3" install -qq --default-timeout=1200 --cache-dir "${LLCWA_HOMEDIR}/.cache/pip" --upgrade pip

	debug_echo "${LINENO} -- ${FUNCNAME}() Update pip done."
	
	# Even with venv, pip seems to require a user have a /home/user directory for ..
	LFAKE_HOME="/home/${INST_USER}"
	error_echo "Creating fake home ${LFAKE_HOME} for python libraries install.."
	[ $TEST -lt 1 ] && mkdir -p "$LFAKE_HOME"
	[ $TEST -lt 1 ] && chown --silent -R "${INST_USER}:${INST_GROUP}" "$LFAKE_HOME"
	HOME="$LFAKE_HOME"
	
	error_echo "========================================================================================="
	error_echo "Installing python libraries to virtual environment ${LLCWA_INST_DIR}, caching to ${LLCWA_HOMEDIR}/.cache/pip"
	error_echo "  HOME is set to ${HOME}"
	
	local LPYTHON_LIBS=" \
		testresources \
		backports.functools_lru_cache \
		pydig \
		iperf3 \
		ntplib \
		tcp_latency \
		dropbox \
		cairocffi \
		matplotlib \
		pandas"

	LPYTHON_LIBS="$(echo "$LPYTHON_LIBS" | xargs)"
	
	pip_libs_install "$INST_PIP3" "$INST_USER" "${LLCWA_HOMEDIR}/.cache/pip" "$LPYTHON_LIBS"
	
	# 20210505: Make the /var/lib/lcwa-speed/.config/matplotlib/ directory writeable..
	[ $TEST -lt 1 ] && mkdir -p "${LLCWA_HOMEDIR}/.config/matplotlib"
	[ $TEST -lt 1 ] && chown --silent -R "${INST_USER}:${INST_GROUP}" "$LLCWA_HOMEDIR"
	error_echo "Setting permissions on ${LLCWA_HOMEDIR}/.config/matplotlib/"
	[ $TEST -lt 1 ] && chmod 777 "${LLCWA_HOMEDIR}/.config/matplotlib/"

	cd "$CURCD"
	
	HOME="$CUR_HOME"
	
	# Check fake home to make sure there isn't anything important..
	[ $KEEPCACHE -lt 1 ] && rm -Rf "$LFAKE_HOME"

	debug_pause "${LINENO} -- ${FUNCNAME}() done."
}

############################################################################
# python_libs_update() -- Installs python library dependencies
############################################################################
python_libs_update(){
	debug_echo "${FUNCNAME}( $@ )"
	
	local LLCWA_INST_DIR="${1:-${LCWA_INSTDIR}}"
	local LLCWA_HOMEDIR="${2:-${LCWA_HOMEDIR}}"
	local LPKG_LIST=
	local LPKG=
	local LFAKE_HOME=
	
	local CURCD="$(pwd)"

	INST_PYTHON="${LLCWA_INST_DIR}/bin/python3"
	INST_PIP3="${LLCWA_INST_DIR}/bin/pip3"

	# Point HOME towards our data directory for the python installs
	HOME="$LLCWA_HOMEDIR"

	error_echo "========================================================================================="
	error_echo "Checking venv python virtual environment in ${LLCWA_INST_DIR}"
	
	INST_PYTHON="${LLCWA_INST_DIR}/bin/python3"
	INST_PIP3="${LLCWA_INST_DIR}/bin/pip3"
	
	if [ ! -x "$INST_PYTHON" ]; then
		error_echo "Error: venv python3 ${INST_PYTHON} not found."
		debug_pause "${LINENO} -- ${FUNCNAME}() done."
		return 1
	fi

	if [ ! -x "$INST_PIP3" ]; then
		error_echo "Error: venv pip3 ${INST_PIP3} not found."
		debug_pause "${LINENO} -- ${FUNCNAME}() done."
		return 1
	fi

	debug_echo "${LINENO} -- ${FUNCNAME}() venv check done."

	# Update pip3
	error_echo "Updating ${INST_PIP3}.."
	[ $TEST -lt 1 ] && sudo -H -u "$INST_USER" "$INST_PIP3" install --default-timeout=1200 --cache-dir "${LLCWA_HOMEDIR}/.cache/pip" --upgrade pip
	[ $TEST -lt 1 ] && sudo -H -u "$INST_USER" "$INST_PIP3" install --upgrade --default-timeout=1200 --cache-dir "${LLCWA_HOMEDIR}/.cache/pip" 'setuptools'

	debug_echo "${LINENO} -- ${FUNCNAME}() Update pip done."
	
	# Even with venv, pip seems to require a user have a /home/user directory for ..
	LFAKE_HOME="/home/${INST_USER}"
	error_echo "Creating fake home ${LFAKE_HOME} for python libraries install.."
	[ $TEST -lt 1 ] && mkdir -p "$LFAKE_HOME"
	[ $TEST -lt 1 ] && chown --silent -R "${INST_USER}:${INST_GROUP}" "$LFAKE_HOME"
	HOME="$LFAKE_HOME"
	
	error_echo "========================================================================================="
	error_echo "Updating python libraries in virtual environment ${LLCWA_INST_DIR}, caching to ${LLCWA_HOMEDIR}/.cache/pip"
	error_echo "  HOME is set to ${HOME}"
	
	local LPYTHON_LIBS=" \
		testresources \
		backports.functools_lru_cache \
		pydig \
		iperf3 \
		ntplib \
		tcp_latency \
		dropbox \
		cairocffi \
		matplotlib \
		pandas"

	LPYTHON_LIBS="$(echo "$LPYTHON_LIBS" | xargs)"
	
	pip_libs_install "$INST_PIP3" "$INST_USER" "${LLCWA_HOMEDIR}/.cache/pip" "$LPYTHON_LIBS"
	
	# 20210505: Make the /var/lib/lcwa-speed/.config/matplotlib/ directory writeable..
	[ $TEST -lt 1 ] && mkdir -p "${LLCWA_HOMEDIR}/.config/matplotlib"
	[ $TEST -lt 1 ] && chown --silent -R "${INST_USER}:${INST_GROUP}" "$LLCWA_HOMEDIR"
	error_echo "Setting permissions on ${LLCWA_HOMEDIR}/.config/matplotlib/"
	[ $TEST -lt 1 ] && chmod 777 "${LLCWA_HOMEDIR}/.config/matplotlib/"

}


python_libs_remove(){
	debug_echo "${FUNCNAME}( $@ )"

	[ $TEST -lt 1 ] && pip uninstall backports.functools_lru_cache \
									dropbox \
									cairocffi \
									matplotlib

	[ $TEST -lt 1 ] && pip3 uninstall pydig

}

# Clean up from previous install attempts..
clean_up(){
	
	# Delete any fake homedir -- may have a partial pip cache
	if [ -d "/home/${LCWA_USER}" ]; then
		# Make sure the home directory is really fake!
		# lcwa-speed:x:113:65534: user account,,,:/home/lcwa-speed:/usr/sbin/nologin
		
		if [ $(grep -c -E "${LCWA_USER}:.*/nologin" /etc/passwd) -gt 0 ]; then
			[ $QUIET -lt 1 ] && error_echo "Deleteing /home/${LCWA_USER}"
			rm -Rf "/home/${LCWA_USER}"
		fi
	fi
	
	# Delete the install dir -- this is the venv python environment
	if [ -d "$LCWA_INSTDIR" ]; then
		[ $QUIET -lt 1 ] && error_echo "Deleteing ${LCWA_INSTDIR}"
		rm -Rf "$LCWA_INSTDIR"
	fi
	
	# Don't delete this if we want to keep the pip cache..
	if [ $KEEPCACHE -lt 1 ] && [ -d "$LCWA_HOMEDIR" ]; then
		[ $QUIET -lt 1 ] && error_echo "Deleteing ${LCWA_HOMEDIR}"
		rm -Rf "$LCWA_HOMEDIR"
	fi
	
	debug_echo "${LINENO} -- ${FUNCNAME}() done."
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


SHORTARGS='hdqvftLUk'

LONGARGS="
help,
debug,
quiet,
verbose,
test,
force,
list-pip,
update-pip,
keep-cache,
clean,
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
		-h|--help)	# Displays this help
			disp_help "$SCRIPT_DESC"
			exit 0
			;;
		-d|--debug)	# Shows debugging info.
			((DEBUG+=1))
			;;
		-q|--quiet)	# Supresses message output.
			QUIET=1
			VERBOSE=0
			;;
		-v|--verbose)	# Increase message output.
			QUIET=0
			((VERBOSE+=1))
			;;
		-f|--force)	# Forces reinstall of jq commandline JSON processor
			((FORCE+=1))
			;;
		-t|--test)	# Tests script logic without performing actions.
			TEST=1
			;;
		-c|--clean)	# Cleans and deletes previous install before reinstalling.
			NO_CLEAN=0
			;;
		-L|--list-pip)	# Lists the installed libraries
			LIST_PIP_LIBS=1
			;;
		-U|--update-pip)	# Just updates the currently installed pip libraries
			UPDATE_PIP_LIBS=1
			;;
		-k|--keep-cache)	# Retains local pip3 http cache.
			KEEPCACHE=1
			;;
		--inst-name)	# =NAME -- Instance name that defines the install location: /usr/local/share/NAME and user account name -- defaults to lcwa-speed.
			shift
			INST_INSTANCE_NAME="$1"
			LCWA_INSTANCE="$1"
			INST_NAME="$LCWA_INSTANCE"
			;;
		--service-name)	# =NAME -- Defines the name of the service: /lib/systemd/system/NAME.service -- defaults to lcwa-speed.
			shift
			INST_SERVICE_NAME="$1"
			LCWA_SERVICE="$(basename "$INST_SERVICE_NAME")"
			;;
		--env-file)	# =NAME -- Read a specific env file to get the locations for the install.
			shift
			LCWA_ENVFILE="$1"
			[ -f "$LCWA_ENVFILE" ] && LCWA_ENVFILE="$(readlink -f "$LCWA_ENVFILE")"
			;;
		*)
			;;
	esac
	shift
done

[ $VERBOSE -gt 0 ] && error_echo "${SCRIPTNAME} ${PRE_ARGS}"

# Default overrides:
[ $TEST -gt 1 ] && INST_SERVICE_NAME="./${INST_SERVICE_NAME}"

if [ ! -z "$LCWA_ENVFILE" ]; then
	LCWA_INSTANCE=
	LCWA_SERVICE=
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
fi

INST_NAME="$LCWA_INSTANCE"
INST_INSTANCE_NAME="$LCWA_INSTANCE"
INST_SERVICE_NAME="$LCWA_SERVICE"

if [ $DEBUG -gt 1 ]; then
	env_vars_show $(env_vars_name)
	debug_pause "Press any key to continue.."
fi

if [ $DEBUG -gt 0 ]; then
	error_echo "=========================================="
	error_echo "            DEBUG == ${DEBUG}"
	error_echo "            FORCE == ${FORCE}"
	error_echo "             TEST == ${TEST}"
	error_echo "    LIST_PIP_LIBS == ${LIST_PIP_LIBS}"
	error_echo "  UPDATE_PIP_LIBS == ${UPDATE_PIP_LIBS}"
	error_echo "        KEEPCACHE == ${KEEPCACHE}"
	error_echo "         NO_CLEAN == ${NO_CLEAN}"
	error_echo "=========================================="
	error_echo "        INST_NAME == ${INST_NAME}"
	error_echo "INST_INSTANCE_NAME == ${INST_INSTANCE_NAME}"
	error_echo "INST_SERVICE_NAME == ${INST_SERVICE_NAME}"
	error_echo "=========================================="
	error_echo "     LCWA_ENVFILE == ${LCWA_ENVFILE}"
	error_echo "=========================================="
	error_echo "    INST_INSTANCE_NAME == ${INST_INSTANCE_NAME}"
	error_echo "         LCWA_INSTANCE == ${LCWA_INSTANCE}"
	error_echo "        LCWA_USER == ${LCWA_USER}"
	error_echo "       LCWA_GROUP == ${LCWA_GROUP}"
	error_echo "=========================================="
	error_echo "INST_SERVICE_NAME == ${INST_SERVICE_NAME}"
	error_echo "     LCWA_SERVICE == ${LCWA_SERVICE}"
	error_echo "    LCWA_INSTDIR == ${LCWA_INSTDIR}"
	error_echo "  LCWA_REPO_LOCAL == ${LCWA_REPO_LOCAL}"
	error_echo "     LCWA_HOMEDIR == ${LCWA_HOMEDIR}"
	error_echo "     LCWA_DATADIR == ${LCWA_DATADIR}"
	error_echo "             HOME == ${HOME}"
	error_echo "=========================================="
	
	debug_pause "Press any key to continue.."
	
fi

if [ $LIST_PIP_LIBS -gt 0 ]; then
	pip_libs_list "$LCWA_INSTDIR" "$LCWA_USER" "$LCWA_HOMEDIR" 0
	exit
fi

if [ $UPDATE_PIP_LIBS -gt 0 ]; then
	pip_libs_list "$LCWA_INSTDIR" "$LCWA_USER" "$LCWA_HOMEDIR" 1
	python_libs_update "$LCWA_INSTDIR" "$LCWA_HOMEDIR"
	pip_libs_list "$LCWA_INSTDIR" "$LCWA_USER" "$LCWA_HOMEDIR" 1
	exit
fi

# Start with a fresh slate..
[ $NO_CLEAN -lt 1 ] && clean_up

# Create the service account
inst_user_create "$LCWA_USER"

instance_dir_create "$LCWA_INSTDIR"

home_dir_create "$LCWA_HOMEDIR"

data_dir_create "$LCWA_DATADIR"

pkg_deps_install

python_libs_install "$LCWA_INSTDIR" "$LCWA_HOMEDIR"
	
[ $QUIET -lt 1 ] && error_echo "${SCRIPT_NAME} done."
