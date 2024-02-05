#!/bin/bash

SCRIPT_VERSION=20240205.063206

#
# config-ookla-speedtest.sh  [--help] [-d|--debug] [-t|--test] [-f|--force] [-q|--quiet] [--no-pause] [--update] [--remove] [--install] [--direct] [optional_username]
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
SCRIPT_DESC="Installs the ookla speedtest cli binary and creates the license file."
SCRIPT_EXTRA='[optional_license_username or license_file_path]'
SCRIPT_HELPER='instsrv_functions.sh'

REC_INCSCRIPT_VER=20240204
INCLUDE_FILE="${SCRIPT_DIR}/instsrv_functions.sh"
[ ! -f "$INCLUDE_FILE" ] && INCLUDE_FILE='instsrv_functions.sh'

source "$INCLUDE_FILE"

if [ $? -gt 0 ]; then
	echo echo "Error: ${INCLUDE_FILE} file not found. Exiting."
	exit 1
fi

if [[ -z "$INCSCRIPT_VERSION" ]] || [[ "$INCSCRIPT_VERSION" < "$REC_INCSCRIPT_VER" ]]; then
	echo "Error: ${INCLUDE_FILE} version is ${INCSCRIPT_VERSION}. Version ${REC_INCSCRIPT_VER} or newer is required."
	exit 1
fi


DEBUG=0			# Set to >1 for action pauses and diagnostic output
NO_PAUSE=0		# Set to 1 to inhibit debug pausing
NO_BANNER=1		# Set to 1 to inhibit banner pause
FORCE=0			# Set to 1 to overwrite an existing speedtest installation.
TEST=0			# Set to 1 to test script logic without performing actions.
QUIET=0			# Set to 1 to inhibit messages
OUT=1			# Set to 1 for apt-get output to stdout, 2 for output to stderr
VERBOSE=0

INSTALL=1		# Default action is to install the ookla cli pkg mgr sources and install
REINSTALL=0		# Set to 1 to reinstall after a remove
UPDATE=0		# Set to 1 to update an existing install
DIRECT=1		# Set to 1 to bypass using a package manager and do a direct download & install
LICENSE_ONLY=0  # Set to 1 to skip install and just generate the license file for the user..
REMOVE=0		# Set to 1 to uninstall the speedtest binary, any pkgmgr souce repos for it, and any license files.

INST_DESC='Ookla speedtest install script'

INST_USER=
INST_HOMEDIR=
INST_LICENSE_FILE=
INST_VERSION=20240205.063206
CUR_VERSION=20240205.063206
LCWA_ENVFILE=

# If we're not running in a tty..
[ $IS_TTY -lt 1 ] && NO_PAUSE=1


######################################################################################################
# is_speedtest() -- returns 0 if speedtest is found and executable, otherwise returns 1
######################################################################################################
function is_speedtest(){
	local LSPEEDTEST="$(which speedtest 2>/dev/null)"
	if [ ! -z "$LSPEEDTEST" ] && [ -x "$LSPEEDTEST" ]; then
		return 0
	fi

	return 1
}


######################################################################################################
# apt_update() -- update the apt cache only if it is more than two hours out of date..
#				  If an arg is a package name, update that package too.
######################################################################################################
apt_update(){
	debug_echo "${FUNCNAME}( $@ )"

	local LPKGS="$@"
	
	local MAX_AGE=$((2 * 60 * 60))
	local CACHE_DIR='/var/cache/apt/'
	local CACHE_DATE=$(stat -c %Y "$CACHE_DIR")
	local NOW_DATE=$(date --utc '+%s')
	local CACHE_AGE=$(($NOW_DATE - $CACHE_DATE))
	local SZCACHE_AGE="$(echo "scale=2; (${CACHE_AGE} / 60 / 60)" | bc) hours"
	local LRET=1

	if [ $FORCE -gt 0 ] || [ $CACHE_AGE -gt $CACHE_AGE ]; then
		[ $CACHE_AGE -gt $CACHE_AGE ] && [ $VERBOSE -gt 0 ] && error_echo "Local cache is out of date.  Updating apt-get package cacahe.."
		[ $DEBUG -gt 0 ] && apt-update || apt-get -qq update
	else
		[ $VERBOSE -gt 0 ] && error_echo  "Local apt cache is up to date as of ${SZCACHE_AGE} ago."
	fi

	if [ ! -z "$LPKGS" ]; then
		[ $QUIET -lt 1 ] && error_echo "apt-get updating ${LPKGS}"
		[ $TEST -lt 1 ] && apt-get install --only-upgrade $LPKGS
		LRET=$?
		[ $TEST -gt 0 ] && LRET=0
		[ $LRET -gt 0 ] && error_echo "${FUNCNAME}() error: could not update ${LPKGS}"
	fi
	
	debug_pause "${FUNCNAME}: returning ${LRET}"
	return $LRET
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
	debug_echo "${FUNCNAME}( $@ )"
	local LPKGS="$@"
	[ $QUIET -lt 1 ] && error_echo "dnf updating cache.."
	[ $TEST -lt 1 ] && dnf check-update --refresh >/dev/null 2>&1
	[ $TEST -lt 1 ] && dnf -y upgrade $LPKGS
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
	local LPKGS="$@"
	local LRET=1
	[[ $OSTYPE == 'darwin'* ]] && return 1

	if [ $USE_APT -gt 0 ]; then
		apt_update $LPKGS
		LRET=$?
	elif [ $USE_YUM -gt 0 ]; then
		dnf_update $LPKGS
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

############################################################################
# pkgmgr_uninstall( package ) -- Removes a package previously installed
#                                via the package manager.  Does not
#								 uninstall the pm sources entry.
############################################################################
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
	

ookla_speedtest_version_get(){
	debug_echo "${FUNCNAME}( $@ )"
	local LSPEEDTEST="${1:-$(which speedtest 2>/dev/null)}"

	if [ -z "$LSPEEDTEST" ] || [ ! -f "$LSPEEDTEST" ]; then
		error_echo "Error: could not find ookla speedtest binary ${LSPEEDTEST}"
		echo ""
		return 1
	fi

    debug_echo "${FUNCNAME}() Getting version information from ${LSPEEDTEST}.."

	# Speedtest by Ookla 1.1.1.28 (c732eb82cf) Linux/x86_64-linux-musl 5.4.0-96-generic x86_64
	"$LSPEEDTEST" --version | sed -n -e 's/^Speedtest by Ookla \([^[:space:]]\+\)\s\+.*$/\1/p'
}

ookla_speedtest_pm_sources_has(){
	debug_echo "${FUNCNAME}( $@ )"

	if [ $USE_APT -gt 0 ]; then
		LSOURCEFILE='/etc/apt/sources.list.d/ookla_speedtest-cli.list'
		
	elif [ $USE_YUM -gt 0 ]; then
		LSOURCEFILE='/etc/yum.repos.d/ookla_speedtest-cli.repo'
	fi

	[ -f "$LSOURCEFILE" ] && return 0 || return 1

}

############################################################################
# ookla_speedtest_pm_sources_install() -- Installs the speedtest package
#                                     	  manager source.
############################################################################
ookla_speedtest_pm_sources_install(){
	debug_echo "${FUNCNAME}( $@ )"
	# Download the install script..
	local LSCRIPT='/tmp/speedtest_inst.sh'
	local LURL=
	local LSOURCEFILE=
	local LRET=1
	
	
	if [ $USE_APT -gt 0 ]; then
		LURL='https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh'
		LSOURCEFILE='/etc/apt/sources.list.d/ookla_speedtest-cli.list'
		
	elif [ $USE_YUM -gt 0 ]; then
		LURL='https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh'
		LSOURCEFILE='/etc/yum.repos.d/ookla_speedtest-cli.repo'
	fi

	if [ -f "$LSOURCEFILE" ] && [ $FORCE -lt 1 ]; then
		[ $VERBOSE -gt 0 ] && error_echo "Ookla package source file ${LSOURCEFILE} already configured."
		return 0
	fi

	[ $VERBOSE -gt 0 ] && error_echo "Downloading Ookla speedtest install script ${LURL}.."

	wget --quiet -O "$LSCRIPT" "$LURL"

	# Execute the install script..just adds the appropriate packagecloud repo to apt or rpm sources..
	if [ -f "$LSCRIPT" ]; then
		chmod 755 "$LSCRIPT" 
		[ $VERBOSE -gt 0 ] && error_echo "Running Ookla speedtest install script.."
		# The repository is setup! You can now install packages.
		[ $TEST -lt 1 ] && LIS_REPO=$("$LSCRIPT" 2>&1 | grep -c 'You can now install packages')
		
		if [ $LIS_REPO -lt 1 ]; then
			error_echo "Error: did not successfully install Ookla speedtest repo source."
			LRET=1
		else
			[ $VERBOSE -gt 0 ] && error_echo "Successfully installed ${LSOURCEFILE}."
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
	[ $USE_APT -gt 0 ] && LLIST_DIR='/etc/apt' || LLIST_DIR='/etc/yum.repos.d'
	
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
	local LINST_USER="$1"
	local LURL=
	local LTMPTGZ='/tmp/speedtest.tgz'
	local LSOURCE='/tmp/speedtest'
	local LTARGET="$(which speedtest 2>/dev/null)"
	local LCLI_URL='https://www.speedtest.net/apps/cli'
	local LCUR_VER=
	local LINST_VER=
	local LOK_TO_INSTALL=0
	local LRET=1
	
	[ $FORCE -gt 0 ] && LOK_TO_INSTALL=1
	[ $IS_MAC -lt 1 ] && deps_check
	
	[ $IS_MAC -gt 0 ] && [ -z "$LTARGET" ] && LTARGET='/usr/local/bin/speedtest'
	[ -z "$LTARGET" ] && LTARGET='/usr/bin/speedtest'

	[ $QUIET -lt 1 ] && error_echo "Getting ookla speedtest download URL fromm ${LCLI_URL}"

	# Direct download from ookla depending on machine architecture
	case "$(uname -m)" in
		x86_64)
			if [[ $OSTYPE == 'darwin'* ]]; then
				LURL="$(curl --silent "$LCLI_URL" 2>/dev/null | lynx -stdin -dump -nonumbers | grep -E '^https.*macosx-universal\.tgz')"
			else
				LURL="$(wget --quiet --output-document=- "$LCLI_URL" 2>/dev/null | lynx -stdin -dump -nonumbers | grep -E '^https.*linux-x86_64\.tgz')"
			fi
			;;
		i686|i386)
			LURL="$(wget --quiet --output-document=- "$LCLI_URL" 2>/dev/null | lynx -stdin -dump -nonumbers | grep -E '^https.*linux-i386\.tgz')"
			;;
		armv6l)	#RPi0, RPi1
			LURL="$(wget --quiet --output-document=- "$LCLI_URL" 2>/dev/null | lynx -stdin -dump -nonumbers | grep -E '^https.*linux-armel\.tgz')"
			;;
		armv7l) #RPi2 | #RPi3b | RPi4b
			LURL="$(wget --quiet --output-document=- "$LCLI_URL" 2>/dev/null | lynx -stdin -dump -nonumbers | grep -E '^https.*linux-armhf\.tgz')"
			;;
		aarch64) #RPi4 bookworm
			LURL="$(wget --quiet --output-document=- "$LCLI_URL" 2>/dev/null | lynx -stdin -dump -nonumbers | grep -E '^https.*linux-aarch64\.tgz')"
			;;
		*)
			error_echo "${FUNCNAME}() Error: Machine type $(uname -m) not supported."
			return 1
			;;
	esac

	if [ -z "$LURL" ]; then
		error_echo "${FUNCNAME}() error: Could not get download URL from ${LCLI_URL}."
		return 1
	fi
	
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

	if [ ! -x "$LSOURCE" ]; then
		error_echo "${FUNCNAME}() error: Could not extract ${LSOURCE} from ${LTMPTGZ}."
		return 1
	fi
	
	# If not forcing, do some version testing..
	if [ -x "$LTARGET" ] && [ $FORCE -lt 1 ]; then
		LCUR_VER="$(ookla_speedtest_version_get "$LTARGET")"
		LINST_VER="$(ookla_speedtest_version_get "$LSOURCE")"
		[ -z "$LCUR_VER" ] && LCUR_VER='0'
		# vercmp (ver1, ver2) -- compares two version strings. Returns:
		#   ver1 == ver2: 0
		#   ver1  > ver2: 1
		#   ver1  < ver2: 2
		vercmp "$LCUR_VER" "$LINST_VER" 

		case $? in
			0)	# Current version == install candidate. Update not needed unless forced.
				[ $QUIET -lt 1 ] && error_echo "${LSOURCE} is the same version as ${LTARGET}. Use --force to update."
				LOK_TO_INSTALL=0
				;;
			1)	# Current is newer than install candidate. Update not needed unless forced.
				[ $QUIET -lt 1 ] && error_echo "${LSOURCE} newer than ${LTARGET}. Use --force to overwrite."
				LOK_TO_INSTALL=0
				;;
			2)	# Current is older than install candidate. Update required.
				LOK_TO_INSTALL=1
				;;
		esac
	else
		LOK_TO_INSTALL=1
	fi
	
	# Install to /usr/bin
	[ $QUIET -lt 1 ] && [ $LOK_TO_INSTALL -gt 0 ] && error_echo "Copying ${LSOURCE} to ${LTARGET}.."
	[ $TEST -lt 1 ] && [ $LOK_TO_INSTALL -gt 0 ] && cp -p "$LSOURCE" "$LTARGET"
	

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
	
	if [ $USE_APT -gt 0 ]; then
		wget --quiet -O "$LSCRIPT" https://install.speedtest.net/app/cli/install.deb.sh
	elif [ $USE_YUM -gt 0 ]; then
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
	if [ $USE_APT -gt 0 ]; then
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
	elif [ $USE_YUM -gt 0 ]; then
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
}

ookla_speedtest_remove_pm(){
	debug_echo "${FUNCNAME}( $@ )"

	pkgmgr_uninstall speedtest

	ookla_speedtest_pm_sources_remove
	
	debug_pause "${LINENO} -- ${FUNCNAME}() done."
}

ookla_speedtest_install(){
	debug_echo "${FUNCNAME}( $@ )"
	local LINST_USER="$1"
	local LRET=1
	
	if [ $DIRECT -gt 0 ]; then
		ookla_speedtest_install_direct "$LINST_USER"
		LRET=$?
	else
		ookla_speedtest_pm_sources_install
		LRET=$?
		#~ [ $LRET -eq 0 ] && 	pkgmgr_update && LRET=$? || LRET=$?
		if [ $LRET -eq 0 ]; then
			pkgmgr_update && pkgmgr_install 'speedtest'
			LRET=$?
		else
			# If the package manager install fails (e.g. due to installing to a newer, 
			#   unsuported OS) try a direct install..
			ookla_speedtest_install_direct
			LRET=$?
		fi
	fi

	if [ $LRET -gt 0 ]; then
		error_echo "Error installing speedtest. Installation not complete."
	else
		[ $QUIET -lt 1 ] && error_echo "Ookla speedtest installation complete."
		ookla_license_install "$LINST_USER"
	fi

	debug_pause "${LINENO} -- ${FUNCNAME}: returning ${LRET}"
	
}

ookla_speedtest_update(){
	debug_echo "${FUNCNAME}( $@ )"
	local LINST_USER="$1"

	if [ $DIRECT -gt 0 ]; then
		ookla_speedtest_install_direct
	else
		pkgmgr_update 'speedtest'
	fi

	if ( ! ookla_license_has ); then
		ookla_license_install "$LINST_USER"
	fi
}



############################################################################
# ookla_speedtest_remove() -- uninstalls speedtest & removes the pkg manager
#                             source. Removes the license file too.
############################################################################
ookla_speedtest_remove(){
	debug_echo "${FUNCNAME}( $@ )"
	local LINST_USER="$1"

	local LSPEEDTEST_BIN="$(which speedtest 2>/dev/null)"
	local LRET=1

	if ( ookla_speedtest_pm_sources_has ); then
		# Uninstall the speedtest package and the pm sources
		ookla_speedtest_remove_pm		
	fi

	LSPEEDTEST_BIN="$(which speedtest 2>/dev/null)"
	# If the speedtest binary is located in a PATH directory, but not uninstalled via a package manager..
	[ -f "$LSPEEDTEST_BIN" ] && rm "$LSPEEDTEST_BIN"

	# Verify that speedtest has been removed from the PATH..
	[ $(which speedtest 2>/dev/null | wc -l) -lt 1 ] && LRET=0 || LRET=1

	# Remove the licence files for all users..
	ookla_license_remove "$LINST_USER"

	if [ $LRET -gt 0 ]; then
		error_echo "Error removing speedtest. Uninstallation not complete."
	else
		[ $QUIET -lt 1 ] && error_echo "Ookla speedtest removal complete."
	fi
	

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
		LHOME_DIR="$(user_homedir_get "$LINST_USER")"
	elif ( is_user "$LINST_USER" ); then
		# has a user, may be root..
		LHOME_DIR="$(user_homedir_get "$LINST_USER")"
	elif [ "$(echo "$LINST_USER" | grep -c '/')" -gt 0 ]; then
		# user arg is actually a filename..
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
# ookla_license_install( username ) -- Runs speedtest under root 
#                                      to generate an ookla license file for
#                                      all users.
############################################################################
ookla_license_install(){
	debug_echo "${FUNCNAME}( $@ )"
	local LINST_USER="$1"
	local LHOME_DIR=
	local LHOME_DIRS=
	local LUSER=
	local LGROUP=
	local LLICENSE_DIR=
	local LLICENSE_FILE=
	local LROOT_LICENSE_FILE="${HOME}/.config/ookla/speedtest-cli.json"
	local LOOKLA="$(which speedtest 2>/dev/null)"
	local LINST_METHOD=0
	local LLICENCE_COUNT=0
	local LRET=1
	
	if [ -z "$LOOKLA" ]; then
		error_echo "${FUNCNAME}() Error: ookla speedtest is not installed."
		return 1
	fi

	# Create the licence file for root..

	if [ ! -f "$LROOT_LICENSE_FILE" ]; then
		# Make 3 attempts at installing the licence file..
		[ $QUIET -lt 1 ] && error_echo "Creating root ookla speedtest license file.."
		for n in 1 2 3
		do
			#~ [ $TEST -lt 1 ] &&  yes | "$LOOKLA" --accept-license --progress=no --format=csv
			[ $TEST -lt 1 ] &&  yes | "$LOOKLA" --progress=no --format=csv
			[ -f "$LROOT_LICENSE_FILE" ] && break
		done
	fi

	if [ ! -f "$LROOT_LICENSE_FILE" ]; then
		error_echo "${FUNCNAME}() error: could not create ookla license file for root user."
		return 1
	else
		debug_cat "$LROOT_LICENSE_FILE"
		((LLICENCE_COUNT++))
	fi

	# Copy the license file to the user's home dir
	if [ ! -z "$LINST_USER" ]; then
		if ( is_user "$LINST_USER" ); then
			LHOME_DIR="$(user_homedir_get "$LINST_USER")"
			[ -z "$LHOME_DIR" ] && LHOME_DIR="/var/lib/${LINST_USER}"
		fi
	fi

	if [ ! -z "$LHOME_DIR" ]; then
		LLICENSE_DIR="${LHOME_DIR}/.config/ookla"
		LLICENSE_FILE="${LLICENSE_DIR}/speedtest-cli.json"
		if [ ! -f "$LLICENSE_FILE" ]; then
			[ $QUIET -lt 1 ] && error_echo "Creating directory ${LLICENSE_DIR}"
			[ $TEST -lt 1 ] && mkdir -p "$LLICENSE_DIR"
			[ $QUIET -lt 1 ] && error_echo "Copying ${LROOT_LICENSE_FILE} to ${LLICENSE_DIR}"
			[ $TEST -lt 1 ] && cp -p "$LROOT_LICENSE_FILE" "$LLICENSE_DIR"
			LGROUP="$(user_group_get "$LINST_USER")"
		else
			error_echo "License file ${LLICENSE_FILE} already exists."
		fi
		[ $TEST -lt 1 ] && chown -R "${LINST_USER}:${LGROUP}" "$LLICENSE_DIR"
		if [ -f "$LLICENSE_FILE" ]; then
			((LLICENCE_COUNT++))
		fi
	fi

	# Iterate through the rest of the users in the system
	LHOME_DIRS="$(cat /etc/passwd | awk -F: '{print $6}' | grep -E '^/home' | xargs)"

	for LHOME_DIR in $LHOME_DIRS
	do
		[ ! -d "$LHOME_DIR" ] && continue
		LUSER="$(stat -c '%U' "$LHOME_DIR")"
		LGROUP="$(user_group_get "$LUSER")"
		LLICENSE_DIR="${LHOME_DIR}/.config/ookla"
		LLICENSE_FILE="${LLICENSE_DIR}/speedtest-cli.json"
		if [ ! -f "$LLICENSE_FILE" ]; then
			[ $QUIET -lt 1 ] && error_echo "Creating directory ${LLICENSE_DIR}"
			[ $TEST -lt 1 ] && mkdir -p "$LLICENSE_DIR"
			[ $QUIET -lt 1 ] && error_echo "Copying ${LROOT_LICENSE_FILE} to ${LLICENSE_DIR}"
			[ $TEST -lt 1 ] && cp -p "$LROOT_LICENSE_FILE" "$LLICENSE_DIR"
		else
			error_echo "License file ${LLICENSE_FILE} already exists."
		fi
		[ $TEST -lt 1 ] && chown -R "${LUSER}:${LGROUP}" "$LLICENSE_DIR"
		if [ -f "$LLICENSE_FILE" ]; then
			((LLICENCE_COUNT++))
		fi
	done

	debug_echo "${LLICENCE_COUNT} licenses on this system."

	[ $LLICENCE_COUNT -gt 1 ] && LRET=0 || LRET=1


	debug_pause "${FUNCNAME}: returning ${LRET}"

	return $LRET
}

############################################################################
# ookla_license_remove() -- Removes the ookla license file for
#                           all users
############################################################################
ookla_license_remove(){
	debug_echo "${FUNCNAME}( $@ )"
	local LINST_USER="$1"
	local LLICENSE_FILE=
	local LLICENSE_DIR=
	local LUSER=
	local LHOME_DIRS=
	local LHOME_DIR=

	# Remove the license file from the user's home dir
	if [ ! -z "$LINST_USER" ]; then
		if ( is_user "$LINST_USER" ); then
			LHOME_DIR="$(user_homedir_get "$LINST_USER")"
			[ -z "$LHOME_DIR" ] && LHOME_DIR="/var/lib/${LINST_USER}"
		fi
	fi

	if [ ! -z "$LHOME_DIR" ]; then
		LLICENSE_DIR="${LHOME_DIR}/.config/ookla"
		if [ -d "$LLICENSE_DIR" ] && [ $(echo "$LLICENSE_DIR" | grep -c 'ookla') -gt 0 ]; then
			[ $QUIET -lt 1 ] && error_echo "Removing directory ${LLICENSE_DIR}"
			[ $TEST -lt 1 ] && rm -R "$LLICENSE_DIR"
		fi
	fi

	# Iterate through the rest of the users

	LHOME_DIRS="$(cat /etc/passwd | awk -F: '{print $6}' | grep '/root\|/home' | xargs)"

	for LHOME_DIR in $LHOME_DIRS
	do
		#~ debug_echo "LHOME_DIR == ${LHOME_DIR}"
		[ ! -d "$LHOME_DIR" ] && continue

		LLICENSE_DIR="${LHOME_DIR}/.config/ookla"
		if [ -d "$LLICENSE_DIR" ] && [ $(echo "$LLICENSE_DIR" | grep -c 'ookla') -gt 0 ]; then
			[ $QUIET -lt 1 ] && error_echo "Removing ${LLICENSE_DIR}.."
			[ $TEST -lt 1 ] && rm -R "$LLICENSE_DIR"
		fi
	done

	debug_pause "${LINENO} -- ${FUNCNAME}() done."
	
}

deps_check(){
	local LWGET="$(which wget 2>/dev/null)"
	local LLYNX="$(which lynx 2>/dev/null)"
	[ $IS_MAC -gt 0 ] && return 1
	[ -z "$LWGET" ] && pkgmgr_install 'wget'
	[ -z "$LLYNX" ] && pkgmgr_install 'lynx'
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


SHORTARGS='hdqvtfnruRk'
LONGARGS="
help,
debug,
quiet,
verbose,
test,
force,
no-pause,
direct,
update,
remove,
reinstall,
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
	disp_help "$SCRIPT_DESC" "$SCRIPT_EXTRA"
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
			disp_help "$SCRIPT_DESC" "$SCRIPT_EXTRA"
			exit 0
			;;
		-d|--debug)	# Emit debugging info
			# Increment the debug value
			((DEBUG++))
			;;
		-q|--quiet)	# Supress messages
			QUIET=1
			VERBOSE=0
			;;
		-v|--verbose)	# Emit extra messages
			QUIET=0
			VERBOSE=1
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
		-k|--direct)	# Install from downloaded tar.gz rather than via apt-get.
			DIRECT=1
			;;
		-u|--update)	# Install or update any existing Ookla speedtest install
			INSTALL=0
			REINSTALL=0
			UPDATE=1
			LICENSE_ONLY=0
			REMOVE=0
			;;
		-r|--remove)	# Remove Ookla speedtest install
			INSTALL=0
			REINSTALL=0
			UPDATE=0
			LICENSE_ONLY=0
			REMOVE=1
			;;
		-R|--reinstall)	# Remove any existing Ookla install and then reinstall
			INSTALL=0
			REINSTALL=1
			UPDATE=0
			LICENSE_ONLY=0
			REMOVE=0
			;;
		--license-only)	# Generate a license file for all system users.
			INSTALL=0
			REINSTALL=0
			UPDATE=0
			LICENSE_ONLY=1
			REMOVE=0
			;;
		--env-file)	# =file -- Read a specific env file to get the locations for the install.
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
[ $(uname -m | grep -c 'arm\|aarch64') -gt 0 ] && DIRECT=1
# No package manager install available for macOS
[ $IS_MAC -gt 0 ] && DIRECT=1


# If updating & forcing but speedtest isn't installed..
if [ $UPDATE -gt 0 ]; then
	if (! is_speedtest ); then
		if [ $FORCE -gt 0 ]; then
			UPDATE=0
			INSTALL=1
		fi
	fi
fi


if [ ! -z "$LCWA_ENVFILE" ]; then
	[ $VERBOSE -gt 0 ] && error_echo "Getting service user from ${LCWA_ENVFILE}."
	source "$LCWA_ENVFILE"
	if [ $? -gt 0 ]; then
		error_echo "${SCRIPT_NAME} Warning: could not read from ${LCWA_ENVFILE}. Using default values."
		LCWA_USER="lcwa-speed"
		LCWA_GROUP="nogroup"
		LCWA_HOMEDIR="/var/lib/lcwa-speed"
	fi
	#~ /var/lib/lcwa-speed/.config/ookla/speedtest-cli.json
	INST_USER="$LCWA_USER"
	INST_HOMEDIR="$LCWA_HOMEDIR"
	INST_LICENSE_FILE="${INST_HOMEDIR}/.config/ookla/speedtest-cli.json"
	#~ This looks weird, but it's right.
	#~ INST_USER="$INST_LICENSE_FILE"
fi

# If no user specified, get the user calling via sudo
if [ -z "$INST_USER" ]; then
	INST_USER="$(sudo_user_get)"
	INST_HOMEDIR="$(cat /etc/passwd | grep "$INST_USER" | awk -F: '{ print $6 }')"
	[ ! -d "$INST_HOMEDIR" ] && INST_HOMEDIR="/var/lib/${INST_USER}"
	INST_LICENSE_FILE="${INST_HOMEDIR}/.config/ookla/speedtest-cli.json"
fi

if [ $DEBUG -gt 0 ]; then
	error_echo ' '
	error_echo "DEBUG             == ${DEBUG}"
	error_echo "QUIET             == ${QUIET}"
	error_echo "VERBOSE           == ${VERBOSE}"
	error_echo "TEST              == ${TEST}"
	error_echo "FORCE             == ${FORCE}"
	error_echo ' '
	error_echo "DIRECT            == ${DIRECT}"
	error_echo ' '
	error_echo "INSTALL           == ${INSTALL}"
	error_echo "REINSTALL         == ${REINSTALL}"
	error_echo "UPDATE            == ${UPDATE}"
	error_echo "LICENSE_ONLY      == ${LICENSE_ONLY}"
	error_echo "REMOVE            == ${REMOVE}"
	error_echo ' '
	error_echo "INST_USER         == ${INST_USER}"
	error_echo "INST_HOMEDIR      == ${INST_HOMEDIR}"
	error_echo "INST_LICENSE_FILE == ${INST_LICENSE_FILE}"
	error_echo ' '
fi


if [ $REMOVE -gt 0 ]; then
	ookla_speedtest_remove "$INST_USER"

elif [ $UPDATE -gt 0 ]; then
	ookla_speedtest_update "$INST_USER"

elif [ $INSTALL -gt 0 ]; then
	ookla_speedtest_install "$INST_USER"

elif [ $REINSTALL -gt 0 ]; then
	ookla_speedtest_remove "$INST_USER"
	ookla_speedtest_install "$INST_USER"

elif [ $LICENSE_ONLY -gt 0 ]; then
	ookla_license_install "$INST_USER"

else
	error_echo "${SCRIPT_NAME} error: INSTALL == ${INSTALL}, UPDATE == ${UPDATE}, REMOVE == ${REMOVE}. Script doesn't know what to do!"
fi

[ $QUIET -lt 1 ] && error_echo ' '
[ $QUIET -lt 1 ] && error_echo "${SCRIPT_NAME} ${PREARGS} finished."
