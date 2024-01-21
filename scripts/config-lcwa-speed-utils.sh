#!/bin/bash
######################################################################################################
# Bash script for for installing lcwa-speed helper scripts & utilities to /usr/local/sbin
#
#	Latest mod: Create view.sh & wipe.sh links in the log directory
######################################################################################################
SCRIPT_VERSION=20240121.112958

SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
SCRIPT_NAME="$(basename $0)"
SCRIPT_DESC="Installs basic bash scripts used by lcwa-speed to /usr/local/sbin"

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

LCWA_ENVFILE=
ALIAS_INST_ONLY=0
UNINSTALL=0
KEEP=0

function escape_var(){
	VAR="$1"
	# escape the escapes, escape the $s, escape the `s, escape the [s, escape the ]s, escape the "s
	#~ ESCVAR="$(echo "$VAR" | sed -e 's/\\/\\\\/g;s/\$/\\\$/g;s/`/\\`/g;s/\[/\\\[/g;s/\]/\\\]/g;s/"/\\"/g')"
	ESCVAR="$(echo "$VAR" | sed -e 's/\\/\\\\/g;s/\$/\\\$/g;s/`/\\`/g;s/"/\\"/g')"
	echo $ESCVAR
}

function bash_alias_add(){
	[ $DEBUG -gt 1 ] && error_echo "${FUNCNAME}( $@ )"
	local LALIASES="$1"
	local LALIAS="$2"
	local LCOMMAND="$3"
	local LESCAPE="${4:-1}"
	
	sed -i "/^alias ${LALIAS}=/d" "$LALIASES"
	[ $QUIET -lt 1 ] && error_echo "Adding alias ${LALIAS} to ${LALIASES}"
	# By default, escape the command string..
	[ $LESCAPE -gt 0 ] && LCOMMAND="$(escape_var "$LCOMMAND")"
	[ $TEST -lt 1 ] && echo "alias ${LALIAS}=\"${LCOMMAND}\"" >>"$LALIASES"
	
}

function bash_alias_remove(){
	[ $DEBUG -gt 1 ] && error_echo "${FUNCNAME}( $@ )"
	local LALIASES="$1"
	local LALIAS="$2"
	local LCOMMAND="$3"
	local LESCAPE="${4:-1}"
	[ $QUIET -lt 1 ] && error_echo "Removing alias ${LALIAS} from ${LALIASES}"
	[ $TEST -lt 1 ] && sed -i "/^alias ${LALIAS}=/d" "$LALIASES"
}

######################################################################################################
# config_bash_aliases( 'list of users' ) Create convenience aliases for shell users
######################################################################################################

function config_bash_aliases(){
	debug_echo "${FUNCNAME}( $@ )"

	local LUSERS="$1"
	local LUSER=
	local LGROUP=
	local LALIASES=
	local LFILEHEADER=
	local LCMD=

	if [ $UNINSTALL -gt 0 ]; then
		LCMD='bash_alias_remove'
	else
		LCMD='bash_alias_add'
	fi

	for LUSER in $LUSERS
	do
		if [ $(id "$LUSER" 2>/dev/null | wc -l) -lt 1 ]; then
			error_echo "${FUNCNAME} error: User ${LUSER} does not exist."
			continue
		fi
		
		LGROUP="$(id -ng $LUSER)"
		LALIASES="/${LUSER}/.bash_aliases"
		if [ "$LUSER" != 'root' ]; then
			LALIASES="/home${LALIASES}"
		fi

		LFILEHEADER="#${LALIASES} -- $(date)"

		if [ ! -f "$LALIASES" ]; then
			[ $UNINSTALL -lt 1 ] && [ $TEST -lt 1 ] && touch "$LALIASES"
			[ $UNINSTALL -lt 1 ] && [ $TEST -lt 1 ] && echo "$LFILEHEADER" > "$LALIASES"
		else
			# Delete the header line
			#~ sed -i '/bash_aliases/d' "$LALIASES"
			[ $TEST -lt 1 ] && sed -i -e '1!b' -e '/bash_aliases --/d' "$LALIASES"

			# Insert the header line at the top
			[ $UNINSTALL -lt 1 ] && [ $TEST -lt 1 ] && sed -i "1s@^@${LFILEHEADER}\n@" "$LALIASES"
		fi

		[ $UNINSTALL -lt 1 ] && [ $TEST -lt 1 ] && chmod 755 "$LALIASES"
		[ $UNINSTALL -lt 1 ] && [ $TEST -lt 1 ] && chown "${LUSER}:${LGROUP}" "$LALIASES"

		# Make a backup of the aliases file..
		if [ ! -f "${LALIASES}.org}" ]; then
			[ $TEST -lt 1 ] && cp -p "$LALIASES" "${LALIASES}.org"
		fi
		[ $TEST -lt 1 ] && cp -pf "$LALIASES" "${LALIASES}.bak"
		[ $TEST -lt 1 ] && chown "${LUSER}:${LGROUP}" "${LALIASES}.bak"

		#Add orr remove the aliases..
		[ $UNINSTALL -lt 1 ] && notquiet_error_echo "Configuring ${LALIASES} for user ${LUSER}.." || notquiet_error_echo "Cleaning ${LALIASES} for user ${LUSER}.."
		
		$LCMD "$LALIASES" 'home'				"pushd /home/\$(who am i | cut '-d ' -f1) >/dev/null"
		$LCMD "$LALIASES" 'sbin'				'pushd /usr/local/sbin >/dev/null'
		$LCMD "$LALIASES" 'psgrep'				'ps aux | grep -v grep | grep -E'
		$LCMD "$LALIASES" 'lsservices'			'systemctl --state=active --no-pager | grep "active running" --color=never | sort | sed -e "s/[[:space:]]*$//"'
		$LCMD "$LALIASES" 'lskernels'			'dpkg --list | grep -E "linux-image" | sort -b -k 3,3 --version-sort -r'
		$LCMD "$LALIASES" 'service-reload'		'systemctl daemon-reload && systemctl reset-failed'

		# Useful aliases for speedboxes
		if [ $(hostname | grep -c -E '^LC.*') -gt 0 ]; then
			$LCMD "$LALIASES" 'logs'			"pushd ${LCWA_LOGDIR}"
			$LCMD "$LALIASES" 'data'			"pushd ${LCWA_DATADIR}"
			$LCMD "$LALIASES" 'code'			"pushd ${LCWA_REPO_LOCAL}/src"
			$LCMD "$LALIASES" 'config'			"pushd $LCWA_SUPREPO_LOCAL"
		fi

		if [ "$LUSER" = 'root' ]; then
			$LCMD "$LALIASES" 'mediaprogress' 'watch "lsof -c rsync | grep /mnt/Media"'
			$LCMD "$LALIASES" 'filesprogress' 'watch "lsof -c rsync | grep -E"'
		fi

		if [ "$LUSER" != 'root' ]; then
			[ $TEST -lt 1 ] && chown "${LUSER}:${LUSER}" "$LALIASES"
			[ $TEST -lt 1 ] && chown "${LUSER}:${LUSER}" "${LALIASES}.org"
		fi
		
		if [ $VERBOSE -gt 0 ]; then
			echo "Contents of ${LALIASES}"
			cat "$LALIASES"
		fi

		[ $QUIET -lt 1 ] && error_echo ' '

	done
	debug_echo "${FUNCNAME} done"
}

######################################################################################################
# rclocal_create() Create the /etc/rc.local file to check the subnet
######################################################################################################

rclocal_create(){
	debug_echo "${FUNCNAME}( $@ )"

	local RCLOCAL='/etc/rc.local'

	if [ -f "$RCLOCAL" ]; then
		if [ ! -f "${RCLOCAL}.org" ]; then
			cp -p "$RCLOCAL" "${RCLOCAL}.org"
		fi
	cp -p "$RCLOCAL" "${RCLOCAL}.bak"
	fi

	[ $QUIET -lt 1 ] && error_echo "Creating ${RCLOCAL}.."


	[ $TEST -lt 1 ] && cat >"$RCLOCAL" <<-RCLOCAL1;
	#!/bin/sh -e
	#
	# rc.local
	#
	# This script is executed at the end of each multiuser runlevel.
	# Make sure that the script will "exit 0" on success or any other
	# value on error.
	#
	# In order to enable or disable this script just change the execution
	# bits.
	#
	# By default this script does nothing.

	########################################################################################
	# ALWAYS fix the /tmp directory
	########################################################################################
	chmod 1777 /tmp

	########################################################################################
	#
	# Check the current network connection. If the subnet has changed, reconfigure the
	# firewall.
	#
	########################################################################################

	/usr/local/sbin/lcwa-speed-fwck.sh --verbose --minimal --public

	exit 0
	RCLOCAL1

	[ $TEST -lt 1 ] && chmod 755 "$RCLOCAL"


}


######################################################################################################
# utility_scripts_name( [ script_dir ] ) Lists the scripts we want to install..
######################################################################################################
utility_scripts_name(){
	debug_echo "${FUNCNAME}( $@ )"
	local LSCRIPT_DIR="${1:-${SCRIPT_DIR}}"
	echo	"../../instsrv_functions.sh" \
			"../instsrv_functions.sh" \
			"./instsrv_functions.sh" \
			"../config-lcwa-speed.sh" \
			"./config-ookla-speedtest.sh" \
			$(find "$LSCRIPT_DIR" -maxdepth 1 -name '*lcwa*' -printf '%f\n' | grep -v -E '[\./]+bak' | sort)
}

# Abbrivated list of scripts...used for uninstall
utility_scripts_name_abbr(){
	debug_echo "${FUNCNAME}( $@ )"
	local LSCRIPT_DIR="${1:-${SCRIPT_DIR}}"
	echo	$(find "$LSCRIPT_DIR" -maxdepth 1 -name '*lcwa*' -printf '%f\n' | grep -v -E '[\./]+bak' | sort)
}


######################################################################################################
# utility_scripts_install( SUP_REPO_SCRIPT_DIR ) Installs the utility scripts to /usr/local/sbin
######################################################################################################
utility_scripts_install(){
	debug_echo "${FUNCNAME}( $@ )"
	local LSCRIPT_DIR="${1:-${SCRIPT_DIR}}"
	local LTARGET_DIR="${2:-/usr/local/sbin}"
	local LSCRIPT=
	local LLINK=
	local LSOURCE=
	local LTARGET=

	[ $QUIET -lt 1 ] && error_echo "Updating utility scripts in ${LTARGET_DIR} from ${LSCRIPT_DIR}"

	# Copy just the scripts with 'lcwa' in the name..
	#~ for LSCRIPT in 	"${LSCRIPT_DIR}/../../instsrv_functions.sh" \
					#~ "${LSCRIPT_DIR}/../instsrv_functions.sh" \
					#~ "${LSCRIPT_DIR}/./instsrv_functions.sh" \
					#~ "${LSCRIPT_DIR}/config-ookla-speedtest.sh" \
					#~ $(find "$LSCRIPT_DIR" -maxdepth 1 -name '*lcwa*' -printf '%f\n' | grep -v -E '[\./]+bak' | sort)

	for LSCRIPT in $(utility_scripts_name)
	do
		[ $VERBOSE -gt 1 ] && error_echo "$LSCRIPT"

		LSOURCE="$(readlink -f "${LSCRIPT_DIR}/${LSCRIPT}")"

		if [ -z "$LSOURCE" ] || [ ! -f "$LSOURCE" ]; then
			continue
		fi
		
		[ $VERBOSE -gt 1 ] && error_echo "$LSOURCE"
		
		LTARGET="${LTARGET_DIR}/$(basename "$LSCRIPT")"

		# Skip overwriting newer files..
		if [ -f "$LTARGET" ] && [ ! "$LSOURCE" -ot "$LTARGET" ]; then
			[ $FORCE -lt 1 ] && continue
		fi

		# Only copy shell script files..
		if [ $(file "$LSOURCE" | grep -c 'shell script') -lt 1 ]; then
			[ $VERBOSE -gt 0 ] && error_echo "$(basename "$LSOURCE") is not a shell script.."
			continue
		fi
		
		if [ -f "$LSOURCE" ]; then
			if [ ! -f "$TARGET" ] || [ "$SOURCE" -nt "$TARGET" ] || [ $FORCE -gt 0 ]; then
				# Test the script for errors
				bash -n "$LSOURCE"
				if [ $? -gt 0 ]; then
					error_echo '============================================================='
					error_echo "${SCRIPT_NAME} error: bash says that ${LSOURCE} has errors!!!"
					error_echo '============================================================='
				else
					[ $VERBOSE -gt 0 ] && error_echo "Copying ${LSOURCE} to ${LTARGET}"
					[ $TEST -lt 1 ] && cp -p "$LSOURCE" "$LTARGET"
				fi
			else
				[ $VERBOSE -gt 0 ] && error_echo "Not copying ${LSOURCE} to ${LTARGET}"
			fi
		fi

	done

	# Make some useful links.
	for LSCRIPT in lcwa-speed-logwipe.sh lcwa-speed-logview.sh
	do
		LLINK="${LSCRIPT:14:7}"
		LSOURCE="${LTARGET_DIR}/${LSCRIPT}"
		LTARGET="${LCWA_LOGDIR}/${LLINK}"
		[ -f "$LTARGET" ] && rm "$LTARGET"
		[ $QUIET -lt 1 ] && error_echo "Linking ${LSOURCE} to ${LTARGET}"
		[ $TEST -lt 1 ] && ln -s "$LSOURCE" "$LTARGET"
	done
	
	rclocal_create

}

######################################################################################################
# utility_scripts_remove() Removes the utility scripts from /usr/local/sbin
######################################################################################################
utility_scripts_remove(){
	debug_echo "${FUNCNAME}( $@ )"
	local LSCRIPT_DIR="${1:-${SCRIPT_DIR}}"
	local LTARGET_DIR="${2:-/usr/local/sbin}"
	local LSCRIPT=
	local LSOURCE=
	local LTARGET=

	[ $QUIET -lt 1 ] && error_echo "Removing utility scripts in ${LTARGET_DIR}.."

	#~ for LSCRIPT in $(find "$LSCRIPT_DIR" -maxdepth 1 -name '*lcwa*' -printf '%f\n' | sort)
	for LSCRIPT in $(utility_scripts_name_abbr)
	do
		LTARGET="${LTARGET_DIR}/${LSCRIPT}"
		if [ -f "$LTARGET" ]; then
			[ $VERBOSE -gt 0 ] && error_echo "Removing ${LTARGET}"
			[ $TEST -lt 1 ] && rm -f "$LTARGET"
		fi
	done
	
	LSCRIPT='/etc/rc.local'
	[ -f "$LSCRIPT" ] && [ $TEST -lt 1 ] && rm "$LSCRIPT"

}

##################################################################################
##################################################################################
##################################################################################
# main()
##################################################################################
##################################################################################
##################################################################################

PRE_ARGS="$@"

SHORTARGS='hdqvftakr'

LONGARGS="
help,
debug,
quiet,
verbose,
test,
force,
alias,
keep,
remove,uninstall,
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
			;;
		-q|--quiet)		# Supresses message output.
			QUIET=1
			;;
		-v|--verbose)		# Increase message output.
			((VERBOSE+=1))
			;;
		-f|--force)		# Force overwriting target files.
			((FORCE+=1))
			;;
		-t|--test)		# Tests script logic without performing actions.
			((TEST+=1))
			;;
		-a|--alias)		# Install / update / remove (with --remove) bash aliases only.
			ALIAS_INST_ONLY=1
			;;
		-k|--keep)
			KEEP=1
			;;
		-r|--remove|--uninstall)	# Removes the utility scripts from /usr/local/sbin
			UNINSTALL=1
			;;
		--env-file)		# =NAME -- Read a specific env file to get the locations for the install.
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

# Make sure we're running as root 
is_root

# We need the /etc/default/lcwa-speed envvars only for creating the log wipe & view links..
if [ ! -z "$LCWA_ENVFILE" ]; then
	[ $VERBOSE -gt 0 ] && error_echo "Getting instance information from ${LCWA_ENVFILE}."
	env_file_read "$LCWA_ENVFILE"
	if [ $? -gt 0 ]; then
		error_echo "${SCRIPT_NAME} warning: could not read from ${LCWA_ENVFILE}."
	fi
else
	INCLUDE_FILE="${SCRIPT_DIR}/lcwa-speed-env.sh"
	[ ! -f "$INCLUDE_FILE" ] && INCLUDE_FILE='/usr/local/sbin/lcwa-speed-env.sh'
	[ $VERBOSE -gt 0 ] && error_echo "Including file: ${INCLUDE_FILE}"
	source "$INCLUDE_FILE"
	if [ $? -gt 0 ]; then
		error_echo "${SCRIPT_NAME} warning: could not include file ${INCLUDE_FILE}."
	else
		env_vars_defaults_get
	fi
fi

if [ $ALIAS_INST_ONLY -gt 0 ]; then
	# Get users with login & shell privileges only..
	[ -z "$USERS" ] && USERS=$(cat /etc/passwd | grep -E '^.*/home/.*/bash$|^.*/root.*bash$' | sed -n -e 's/^\([^:]*\):.*$/\1/p' | sort | xargs )
	config_bash_aliases "$USERS"
	exit 0
fi


if [ $KEEP -gt 0 ] && [ $UNINSTALL -gt 0 ]; then
	[ $VERBOSE -gt 0 ] && error_echo "${SCRIPT_NAME}: Keeping install scripts."
	exit 0
fi

if [ $UNINSTALL -gt 0 ]; then
	utility_scripts_remove
else
	utility_scripts_install
fi

####################################################################
# Add some helpful bash aliases
[ -z "$USERS" ] && USERS=$(cat /etc/passwd | grep -E '^.*/home/.*/bash$|^.*/root.*bash$' | sed -n -e 's/^\([^:]*\):.*$/\1/p' | sort | xargs )
config_bash_aliases "$USERS"

