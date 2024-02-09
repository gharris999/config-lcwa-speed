#!/bin/bash

######################################################################################################
# Bash script for installing local clones of repositories required for Andi Klein's Python 
#   LCWA PPPoE Speedtest Logger
#   By default, repos will be installed to /usr/local/share/lcwa-speed/speedtest &&
#   									   /usr/local/share/lcwa-speed/speedtest-config
#
# Latest mod: added git_repo_make_safe function to allow updating with dubious ownership..
######################################################################################################
SCRIPT_VERSION=20240208.120022

SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
SCRIPT_NAME="$(basename $0)"
SCRIPT_DESC="Installs local repo clones for the lcwa-speed service."


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
#~ FORCE=0
TEST=0
NO_CLEAN=1
UNINSTALL=0
UPDATE=0
ALLREVS=1

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


#------------------------------------------------------------------------------
# git_in_repo() -- Check to see we are where we are supposed to be..
#------------------------------------------------------------------------------
git_in_repo(){
	debug_echo "${FUNCNAME}( $@ )"

	local LLOCAL_REPO="$1"

	if [ $(pwd) != "$LLOCAL_REPO" ]; then
		error_echo "${SCRIPT_NAME} error: Could not find ${LLOCAL_REPO}"
		error_echo "${SCRIPT_NAME} must exit.."
		exit 1
	fi
}

#------------------------------------------------------------------------------
# git_repo_check() -- Check the repo for a .git dir & the fetch url
#                     return values:
#                     10: repo does not exist -- create it
#                      5: wrong repo -- error, quit
#                      0: repo exists -- update it
#------------------------------------------------------------------------------
git_repo_check(){
	debug_echo "${FUNCNAME}( $@ )"

	local LREMOTE_REPO="$1"
	local LLOCAL_REPO="$2"
	local LTHIS_REPO=
	
	# Mark the local repo as "safe" so as to suspress warnings..
	git config --global --add safe.directory "$LLOCAL_REPO"

	if [ ! -d "${LLOCAL_REPO}/.git" ]; then
		[ $VERBOSE -gt 0 ] && error_echo "${LLOCAL_REPO} does not exist or is not a git repository."
		# local repo does not exist..set return value to create it
		return 10
	fi

	cd "$LLOCAL_REPO" && git_in_repo "$LLOCAL_REPO"
	# Get the URL of the fetch origin of the clone..
	LTHIS_REPO=$(git remote -v show | grep 'fetch' | sed -n -e 's/^origin *\([^ ]*\).*$/\1/p')
	LTHIS_REPO=$(echo "$LTHIS_REPO" | sed -e 's/^[[:space:]]*//')
	LTHIS_REPO=$(echo "$LTHIS_REPO" | sed -e 's/[[:space:]]*$//')

	# We don't care if the source is http:// or git://
	if [ "${LTHIS_REPO##*//}" != "${LREMOTE_REPO##*//}" ]; then
		error_echo "${SCRIPT_NAME} error: ${LLOCAL_REPO} is not a git repository for ${LREMOTE_REPO}."
		error_echo "  git reports ${LTHIS_REPO} as the source."
		return 5
	fi

	# Local repo exists & has the right url -- update it..
	return 0
}

#------------------------------------------------------------------------------
# git_repo_show() -- show the status of the local repo
#------------------------------------------------------------------------------
git_repo_show() {
	debug_echo "${FUNCNAME}( $@ )"
	local LLOCAL_REPO="$1"
	local LRET=1

	if [ -d "$LLOCAL_REPO" ]; then
		[ $QUIET -lt 1 ] && error_echo "Getting ${LLOCAL_REPO} status.."
		cd "$LLOCAL_REPO" && git_in_repo "$LLOCAL_REPO"
		git remote show origin >&2
		[ $QUIET -lt 1 ] && error_echo "Available branches in ${LLOCAL_REPO}:"
		git branch -r >&2
		[ $QUIET -lt 1 ] && error_echo "Status of ${LLOCAL_REPO}:"
		git status >&2
		LRET=$?
	else
		error_echo "${FUNCNAME}() error: Local repo ${LLOCAL_REPO} does not exist."
		LRET=1
	fi
	return $LRET
}


#------------------------------------------------------------------------------
# git_repo_clone() -- Clone the remote repo locally..
#------------------------------------------------------------------------------
git_repo_clone(){
	debug_echo "${FUNCNAME}( $@ )"

	local LREMOTE_REPO="$1"
	local LLOCAL_REPO="$2"
	
	# Cloning to --depth 1 (i.e. only most recent revs) results in a dirsize of
	if [ $ALLREVS -gt 0 ]; then
		[ $QUIET -lt 1 ] && error_echo "Cloning ${LREMOTE_REPO} (all revs) to ${LLOCAL_REPO}.."
		[ $TEST -lt 1 ] && git clone "$LREMOTE_REPO" "$LLOCAL_REPO" >/dev/null 2>&1
	else
		[ $QUIET -lt 1 ] && error_echo "Cloning ${LREMOTE_REPO} to ${LLOCAL_REPO}.."
		[ $TEST -lt 1 ] && git clone --depth 1 "$LREMOTE_REPO" "$LLOCAL_REPO" >/dev/null 2>&1
	fi
	
	
	if [ $TEST -lt 1 ]; then
		git_repo_check "$LREMOTE_REPO" "$LLOCAL_REPO"
	else
		true
	fi
	
	if [ $? -eq 10 ]; then
		error_echo "${SCRIPT_NAME} error: Cannot clone ${LREMOTE_REPO}...script must halt."
		exit 1
	fi

	[ $VERBOSE -gt 0 ] && git_repo_show "$LLOCAL_REPO" >&2
}

#------------------------------------------------------------------------------
# git_repo_checkout() -- Check out the desired branch..
#------------------------------------------------------------------------------
git_repo_checkout(){
	debug_echo "${FUNCNAME}( $@ )"

	local LBRANCH="$1"
	local LLOCAL_REPO="$2"
	local LLOCAL_BRANCH="$(basename "$LBRANCH")"
	
	# Check and install or update the main repo..
	git_repo_check "$LREMOTE_REPO" "$LLOCAL_REPO"

	if [ $? -eq 0 ]; then
		cd "$LLOCAL_REPO" && git_in_repo "$LLOCAL_REPO"
		[ $QUIET -lt 1 ] && error_echo "Checking out branch ${LBRANCH} to local branch ${LLOCAL_BRANCH} in ${LLOCAL_REPO}.."
		#check out the new branch..
		[ $TEST -lt 1 ] && git checkout "$LLOCAL_BRANCH" >/dev/null 2>&1
		if [ $? -gt 0 ]; then
			error_echo "${SCRIPT_NAME} error: Cannot check out branch ${LBRANCH}."
			git_repo_show "$LLOCAL_REPO"
			return 1
		fi
	fi
}

#------------------------------------------------------------------------------
# git_repo_clean() -- Discard any local changes from the repo..
#------------------------------------------------------------------------------
git_repo_clean(){
	debug_echo "${FUNCNAME}( $@ )"

	local LREMOTE_REPO="$1"
	local LLOCAL_REPO="$2"

	# Check and install or update the main repo..
	git_repo_check "$LREMOTE_REPO" "$LLOCAL_REPO"

	if [ $? -eq 0 ]; then
		cd "$LLOCAL_REPO" && git_in_repo "$LLOCAL_REPO"
		[ $QUIET -lt 1 ] && error_echo "Cleaning ${LLOCAL_REPO}.."
		[ $TEST -lt 1 ] && git reset --hard >&2
		[ $TEST -lt 1 ] && git clean -fd >&2
	else
		error_echo "${SCRIPT_NAME} error: Cannot clean ${LLOCAL_REPO}...script must halt."
		exit 1
	fi
}

#------------------------------------------------------------------------------
# git_repo_update() -- update the local git repo
#------------------------------------------------------------------------------
git_repo_update(){
	debug_echo "${FUNCNAME}( $@ )"

	local LREMOTE_REPO="$1"
	local LLOCAL_REPO="$2"
	# Check and install or update the main repo..
	git_repo_check "$LREMOTE_REPO" "$LLOCAL_REPO"

	if [ $? -eq 0 ]; then
		cd "$LLOCAL_REPO" && git_in_repo "$LLOCAL_REPO"
		[ $QUIET -lt 1 ] && error_echo "Updating ${LLOCAL_REPO}.."
		[ $TEST -lt 1 ] && git pull >&2
	else
		error_echo "Error updating ${LLOCAL_REPO}...script must halt."
		exit 1
	fi
}

git_repo_make_safe(){
	debug_echo "${FUNCNAME}( $@ )"
	local LLOCAL_REPO="$1"
	git config --global --add safe.directory "$LLOCAL_REPO"
}

#------------------------------------------------------------------------------
# git_repo_create() -- Check and Update or Clone the repo locally and check out a branch
#------------------------------------------------------------------------------
git_repo_create(){
	debug_echo "${FUNCNAME}( $@ )"

	local LREMOTE_REPO="$1"
	local LREMOTE_BRANCH="$2"
	local LLOCAL_REPO="$3"
	local LREPOSTAT=

	# Check and install or update the main repo..
	git_repo_check "$LREMOTE_REPO" "$LLOCAL_REPO"

	LREPOSTAT=$?
	if [ $LREPOSTAT -eq 10 ]; then
		# local repo does not exist...create it..
		git_repo_clone "$LREMOTE_REPO" "$LLOCAL_REPO"
		git_repo_checkout "$LREMOTE_BRANCH" "$LLOCAL_REPO"
		git_repo_make_safe "$LLOCAL_REPO"
		
	elif [ $LREPOSTAT -eq 5 ]; then
		# wrong repo!  Exit!
		git_repo_show "$LREMOTE_REPO" "$LLOCAL_REPO"
		debug_pause "${FUNCNAME}: ${LINENO}"
		exit 1
	else
		# local repo exists...update it..
		git_repo_make_safe "$LLOCAL_REPO"		
		git_repo_clean "$LREMOTE_REPO" "$LLOCAL_REPO"
		git_repo_update "$LREMOTE_REPO" "$LLOCAL_REPO"
	fi
	debug_pause "${LINENO} -- ${FUNCNAME} done."
}

#------------------------------------------------------------------------------
# git_repo_remove() -- delete the local repo
#------------------------------------------------------------------------------
git_repo_remove(){
	debug_echo "${FUNCNAME}( $@ )"

	local LLOCAL_REPO="$1"
	if [ -d "$LLOCAL_REPO" ]; then
		[ $QUIET -lt 1 ] && error_echo "Removing ${LLOCAL_REPO} git local repo.."
		rm -Rf "$LLOCAL_REPO"
	fi
}


patch_dir_apply(){
	debug_echo "${FUNCNAME}( $@ )"
	local LPATCH_SCRIPT="${1:-${LCWA_REPO_LOCAL}_patches/src/apply.sh}"

	if [ -f "$LPATCH_SCRIPT" ]; then
		error_echo "Applying patches to ${INST_SRC} using ${LPATCH_SCRIPT}.."
		[ $TEST -lt 1 ] && "${INST_PATCHDIR}/apply.sh"
	fi

	debug_pause "${FUNCNAME}: ${LINENO}"
	return 0
}

patch_dir_install(){
	debug_echo "${FUNCNAME}( $@ )"
	local LPATCH_DIR="${1:-${LCWA_REPO_LOCAL}_patches/src}"
	local LSOURCE_DIR="${SCRIPT_DIR}/patches"
	
	if [ ! -d "$LSOURCE_DIR" ]; then
		error_echo "${FUNCNAME} error: could not find ${LSOURCE_DIR} patch source directory."
		return 1
	fi
	
	if [ ! -d "$LPATCH_DIR" ]; then
		error_echo "Creating ${LPATCH_DIR} patch directory.."
		[ $TEST -lt 1 ] && mkdir -p "$LPATCH_DIR"
		if [ $? -gt 0 ]; then
			error_echo "${FUNCNAME} error: could not create ${LPATCH_DIR} patch directory."
			return 1
		fi
	fi
	
	error_echo "Copying patch files from ${LPATCH_DIR} to ${LPATCH_DIR}.."
	[ $TEST -lt 1 ] && cp -p "${LSOURCE_DIR}/*" "$LPATCH_DIR"
	if [ $? -gt 0 ]; then
		error_echo "${FUNCNAME} error: could not copy patch files to ${LPATCH_DIR} patch directory."
		debug_pause "${FUNCNAME}: ${LINENO}"
		return 1
	fi
	
	debug_pause "${FUNCNAME}: ${LINENO}"
	
	return 0
}

patch_dir_remove(){
	debug_echo "${FUNCNAME}( $@ )"
	local LPATCH_DIR="${1:-${LCWA_REPO_LOCAL}_patches/src}"
	
	if [ -d "$LPATCH_DIR" ]; then
		error_echo "Removing ${LPATCH_DIR} patch directory.."
		[ $TEST -lt 1 ] && rm -Rf "$LPATCH_DIR"
	fi
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


SHORTARGS='hdqvftkr'

LONGARGS="
help,
debug,
quiet,
verbose,
test,
force,
keep-repos,
clean,
uninstall,remove,
update,
shallow,
branch:,
sup-branch:,
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
			TEST=1
			;;
		-c|--clean)				# Cleans and deletes previous repo installs before reinstalling.
			NO_CLEAN=0
			;;
		-r|--remove|--uninstall) 	# Removes local clones of the repos
			NO_CLEAN=0
			UNINSTALL=1
			;;
		-u|--update)		# Performs a hard reset and update of the repos
			UPDATE=1
			;;
		--shallow)			# Performs a shallow clone of only the latest commit.
			ALLREVS=0
			;;
		--branch)
			shift
			LCWA_REPO_BRANCH="$1"
			;;
		--sup-branch)
			shift
			LCWA_SUPREPO_BRANCH="$1"
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
	#~ echo "IS_DEBIAN == ${IS_DEBIAN}"
	#~ env_vars_defaults_get
	#~ [ $QUIET -lt 1 ] && error_echo "Modifying default dependency install targets from ${LCWA_ENVFILE}."
	#~ env_file_read "$INST_SERVICE_NAME"
else
	env_vars_defaults_get
fi

#~ LCWA_REPO="https://github.com/gharris999/LCWA.git"
#~ LCWA_REPO_BRANCH="origin/master"
#~ LCWA_REPO_LOCAL="/usr/local/share/lcwa-speed/speedtest"

#~ LCWA_SUPREPO="https://github.com/gharris999/config-lcwa-speed.git"
#~ LCWA_SUPREPO_BRANCH="origin/master"
#~ LCWA_SUPREPO_LOCAL="/usr/local/share/lcwa-speed/speedtest-config"

if [ $NO_CLEAN -lt 1 ]; then
	git_repo_remove "$LCWA_REPO_LOCAL"
	git_repo_remove "$LCWA_SUPREPO_LOCAL"
	if [ $UNINSTALL -gt 0 ]; then
		[ $QUIET -lt 1 ] & error_echo "${SCRIPT_NAME} done."
		exit 0
	fi
fi

if [ $UPDATE -gt 0 ]; then
	git_repo_clean "$LCWA_REPO" "$LCWA_REPO_LOCAL"
	git_repo_update "$LCWA_REPO" "$LCWA_REPO_LOCAL"
	git_repo_clean "$LCWA_SUPREPO" "$LCWA_SUPREPO_LOCAL"
	git_repo_update "$LCWA_SUPREPO" "$LCWA_SUPREPO_LOCAL"
else
	git_repo_create "$LCWA_REPO" "$LCWA_REPO_BRANCH" "$LCWA_REPO_LOCAL"
	git_repo_create "$LCWA_SUPREPO" "$LCWA_SUPREPO_BRANCH" "$LCWA_SUPREPO_LOCAL"
fi

[ $QUIET -lt 1 ] & error_echo "${SCRIPT_NAME} done."
