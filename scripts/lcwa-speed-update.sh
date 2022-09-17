#!/bin/bash
# lcwa-speed-update.sh -- script to update lcwa-speed git repo and restart service..
# Version Control for this script

SCRIPT_VERSION=20220904.081140

INST_NAME='lcwa-speed'
SERVICE_NAME=

SCRIPT="$(readlink -f "$0")"
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DESC="Updates repos, dependencies, parameters and restarts the ${INST_NAME} service."
DEBUG=0
QUIET=0
VERBOSE=0
FORCE=0
TEST=0
LOG=0
LOG_CLEAR=0

CLUSTER_UPDATE=0

NO_UPDATES=1
NO_PATCH=1
SERVICES_UPDATE=0
SBIN_UPDATE=0
OS_UPDATE=0
REBOOT=0

USE_UPSTART=0
USE_SYSTEMD=0
USE_SYSV=1

IS_DEBIAN="$(which apt-get 2>/dev/null | wc -l)"
IS_UPSTART=$(initctl version 2>/dev/null | grep -c 'upstart')
IS_SYSTEMD=$(systemctl --version 2>/dev/null | grep -c 'systemd')

####################################################################################
# Requirements: do we have the utilities needed to get the job done?
TIMEOUT_BIN=$(which timeout)

if [ -z "$TIMEOUT_BIN" ]; then
	TIMEOUT_BIN=$(which gtimeout)
fi

PROC_TIMEOUT=60

# Prefer upstart to systemd if both are installed..
if [ $IS_UPSTART -gt 0 ]; then
	USE_SYSTEMD=0
	USE_SYSV=0
	USE_UPSTART=1
elif [ $IS_SYSTEMD -gt 0 ]; then
	USE_SYSTEMD=1
	USE_SYSV=0
	USE_UPSTART=0
fi

psgrep(){
    ps aux | grep -v grep | grep -E $*
}

error_exit(){
    echo "Error: $@" 1>&2;
    exit 1
}

error_echo(){
	echo "$@" 1>&2;
}

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

debug_echo(){
	[ $DEBUG -gt 0 ] && echo "$@" 1>&2;
}


date_msg(){
	DATE=$(date '+%F %H:%M:%S.%N')
	DATE=${DATE#??}
	DATE=${DATE%?????}
	echo "[${DATE}] ${SCRIPT_NAME} ($$)" $@
}

log_msg(){
	error_echo "$@"
	[ $LOG -gt 0 ] && date_msg "$@" >> "$LCWA_VCLOG"
}

log_clear(){
	error_echo "$@"
	[ $LOG -gt 0 ] && date_msg "$@" > "$LCWA_VCLOG"
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

function displaytime {
  local T=$1
  local D=$((T/60/60/24))
  local H=$((T/60/60%24))
  local M=$((T/60%60))
  local S=$((T%60))
  (( $D > 0 )) && printf '%d days ' $D
  (( $H > 0 )) && printf '%d hours ' $H
  (( $M > 0 )) && printf '%d minutes ' $M
  (( $D > 0 || $H > 0 || $M > 0 )) && printf 'and '
  printf '%d seconds\n' $S
}

# Get a random number between FLOOR & CEILING, inclusive
random_get(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local FLOOR="$1"
	local CEILING="$2"
	local RANGE=$(($CEILING-$FLOOR+1));
	local RESULT=$RANDOM;
	let "RESULT %= $RANGE";
	RESULT=$(($RESULT+$FLOOR));
	echo "$RESULT"
}


########################################################################
# disp_help() -- display the getopts allowable args
########################################################################
disp_help(){
	local LSCRIPT_NAME="$(basename "$0")"
	local LDESCRIPTION="$1"
	local LEXTRA_ARGS="${@:2}"
	error_echo  -e "\n${LSCRIPT_NAME}: ${LDESCRIPTION}\n"
	error_echo -e "Syntax: ${LSCRIPT_NAME} ${LEXTRA_ARGS}\n"
	error_echo "            Optional parameters:"
	# See: https://gist.github.com/sv99/6852cc2e2a09bd3a68ed for explaination of the sed newline replacement
	cat "$(readlink -f "$0")" | grep -E '^\s+-' | grep -v -- '--)' | sed -e 's/)//' -e 's/#/\n\t\t\t\t#/' | fmt -t -s | sed ':a;N;$!ba;s/\n\s\+\(#\)/\t\1/g' 1>&2
	error_echo ' '
}

env_file_read(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"

	if [ $IS_DEBIAN -gt 0 ]; then
		INST_ENVFILE="/etc/default/${INST_NAME}"
	else
		INST_ENVFILE="/etc/sysconfig/${INST_NAME}"
	fi

	if [ -f "$INST_ENVFILE" ]; then
		. "$INST_ENVFILE"
	else
		log_msg "Error: Could not read ${INST_ENVFILE}."
		return 128
	fi
	
	# Default this!
	[ -z "$LCWA_NOUPDATE" ] && LCWA_NOUPDATE=0
	
	if [ -z "$LCWA_NOPATCH" ]; then
		LCWA_NOPATCH=0
	elif [ ! -f "${LCWA_REPO_LOCAL}_patches/src/apply.sh" ]; then
		LCWA_NOPATCH=0
	else
		LCWA_PATCHDIR="${LCWA_REPO_LOCAL}_patches/src"
	fi
}

services_zip_update(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	# Get date of ourselves..
	# Get date of file..
	local LURL='http://www.hegardtfoundation.org/slimstuff/Services.zip'
	#~ SCRIPT='/usr/local/sbin/lcwa-speed-update.sh'
	local REMOT_FILEDATE=
	local LOCAL_FILEDATE=
	local REMOT_EPOCH=
	local LOCAL_EPOCH=
	local TEMPFILE=

	log_msg "Checking ${SCRIPT} to see if update of the update is needed.."
	
	# Remote file time here: 5/1/2020 14:01
	REMOT_FILEDATE="$(curl -s -v -I -X HEAD http://www.hegardtfoundation.org/slimstuff/Services.zip 2>&1 | grep -m1 -E "^Last-Modified:")"
	# Sanitize the filedate, removing tabs, CR, LF
	REMOT_FILEDATE="$(echo "${REMOT_FILEDATE//[$'\t\r\n']}")"
	REMOT_FILEDATE="$(echo "$REMOT_FILEDATE" | sed -n -e 's/^Last-Modified: \(.*$\)/\1/p')"
	error_echo "REMOT_FILEDATE: ${REMOT_FILEDATE}"
	REMOT_EPOCH="$(date "-d${REMOT_FILEDATE}" +%s)"
	
	LOCAL_FILEDATE="$(stat -c %y ${SCRIPT})"
	LOCAL_EPOCH="$(date "-d${LOCAL_FILEDATE}" +%s)"
	
	[ $DEBUG -gt 0 ] && log_msg "Comparing dates"
	[ $DEBUG -gt 0 ] && log_msg " Local: [${LOCAL_EPOCH}] $(date_epoch_to_iso8601  ${LOCAL_EPOCH})"
	[ $DEBUG -gt 0 ] && log_msg "Remote: [${REMOT_EPOCH}] $(date_epoch_to_iso8601  ${REMOT_EPOCH})"

	[ $DEBUG -gt 0 ] && [ $LOCAL_EPOCH -lt $REMOT_EPOCH ] && log_msg "Local ${SCRIPT} is older than Remote ${LURL} by $(displaytime $(echo "${REMOT_EPOCH} - ${LOCAL_EPOCH}" | bc))." || log_msg "Local ${SCRIPT} is newer than Remote ${LURL} by $(displaytime $(echo "${LOCAL_EPOCH} - ${REMOT_EPOCH}" | bc))." 

	# Update ourselves if we're older than Services.zip
	if [ $LOCAL_EPOCH -lt $REMOT_EPOCH ]; then
		log_msg "Updating ${SCRIPT} with new verson.."
		TEMPFILE="$(mktemp -u)"
		# Download the Services.zip file, keeping the file modification date & time
		[ $TEST -lt 1 ] && wget --quiet -O "$TEMPFILE" -S "$LURL" >/dev/null 2>&1
		if [ -f "$TEMPFILE" ]; then
			cd /tmp
			unzip -u -o -qq "$TEMPFILE"
			cd Services
			./install.sh
			cd "config-${INST_NAME}"
			"./config-${INST_NAME}.sh" --update
			cd /tmp
			rm -Rf ./Services
			rm "$TEMPFILE"
			REBOOT=1
		fi
	else
		log_msg "${SCRIPT} is up to date."
	fi
		
}

sbin_zip_update(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LURL='http://www.hegardtfoundation.org/slimstuff/sbin.zip'
	local TEMPFILE="$(mktemp)"

	log_msg "Downloading updated utility scripts.."

	# Download the sbin.zip file, keeping the file modification date & time
	[ $TEST -lt 1 ] && wget --quiet -O "$TEMPFILE" -S "$LURL" >/dev/null 2>&1
	
	if [ -f "$TEMPFILE" ]; then
		log_msg "Updating ${SCRIPT} with new verson.."
		cd /tmp
		#~ unzip -u -o -qq "$TEMPFILE" -d /usr/local
		unzip -o "$TEMPFILE" -d /usr/local
		rm "$TEMPFILE"
	fi
	
}


service_name_get(){
	debug_echo "${FUNCNAME}( $@ )"
	local LSEARCH_NAME="$1"
	local LOUR_NAME=
	local LFOUND_NAME=
	
	debug_echo "Searching for ${LSEARCH_NAME} service.."
	
	
	local LOUR_NAME="$(ps -p $$ -o pid=,unit=,cmd= | awk '{ print $2 }')"
	
	# If we're not running as a systemd service..i.e. just running the script..
	[ $( echo "$OUR_NAME" | grep -c '.service') -lt 1 ] && LOUR_NAME="${INST_NAME}-update.service"
	
	[ $DEBUG -gt 1 ] && log_msg "This Update Service: ${LOUR_NAME}.."
	
	
	# See if the service is running..
	
	LFOUND_NAME="$(ps -e -o pid,unit,cmd | grep -v "${LOUR_NAME}\|grep" | grep -m1 "$LSEARCH_NAME" | awk '{ print $2 }')"
	
	[ $( echo "$LFOUND_NAME" | grep -c '.service') -lt 1 ] && LFOUND_NAME=""

	# This finds enabled but stopped services..
	[ -z "$LFOUND_NAME" ] && LFOUND_NAME="$(systemctl list-units --type=service "${LSEARCH_NAME}*" --all --no-legend | grep -v "$LOUR_NAME" | awk '{ print $1 }')"
	
	if [ -z "$LFOUND_NAME" ]; then
		log_msg "${LSEARCH_NAME} service not found."
		echo ""
		return 1
	fi

	debug_echo "Found ${LFOUND_NAME}.."

	echo "$LFOUND_NAME"
}


service_stop() {
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LSERVICE="${1:=${INST_NAME}}"

	log_msg "Stopping ${LSERVICE}.."

	[ $TEST -lt 1 ] && systemctl stop "${LSERVICE}" >/dev/null 2>&1

	sleep 2

	# Failsafe stop
	local LLCWA_PID=$(pgrep -fn "$LCWA_DAEMON")

	if [ ! -z "$LLCWA_PID" ]; then
		log_msg "Stopping ${LSERVICE_NAME} failed.  Killing ${LLCWA_PID} instead.."
		[ $TEST -lt 1 ] && kill -9 "$LLCWA_PID"
	fi

	return $?
}

######################################################################################################
# service_status() Get the status of the service..
######################################################################################################
service_status() {
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LSERVICE="${1:=${INST_NAME}}"
	
	if ( systemctl is-active --quiet "$LSERVICE" 2>/dev/null ); then
		log_msg "${LSERVICE} is running.."
	else
		log_msg "${LSERVICE} is not running.."
	fi 

	[ $DEBUG -gt 1 ] && systemctl --full --no-pager status "$LSERVICE" >&2

	return $?
}

service_start() {
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LSERVICE="${1:=${INST_NAME}}"
	log_msg "Starting ${LSERVICE}.."

	#~ [ $TEST -lt 1 ] && systemctl start "${LSERVICE}" >/dev/null 2>&1
	[ $TEST -lt 1 ] && systemctl restart "${LSERVICE}" >/dev/null 2>&1
	
	service_status "$LSERVICE"

	return $?
}



#---------------------------------------------------------------------------
# Check to see we are where we are supposed to be..
git_in_repo(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LLOCAL_REPO="$1"
	if [ $(pwd) != "$LLOCAL_REPO" ]; then
		log_msg "Error: ${LLOCAL_REPO} not found."
		return 128
	fi
}

#---------------------------------------------------------------------------
# Discard any local changes from the repo..
git_clean(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LLOCAL_REPO="$1"
	cd "$LLOCAL_REPO" && git_in_repo "$LLOCAL_REPO"
	log_msg "Cleaning ${LLOCAL_REPO}"
	if [ -d './.git' ]; then
		[ $TEST -lt 1 ] && git reset --hard
		[ $TEST -lt 1 ] && git clean -fd
	elif [ -d './.svn' ]; then
		[ $TEST -lt 1 ] && svn revert -R .
	fi
}

#---------------------------------------------------------------------------
# Update the repo..
git_update(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LLOCAL_REPO="$1"
	cd "$LLOCAL_REPO" && git_in_repo "$LLOCAL_REPO" 
	log_msg "Updating ${LLOCAL_REPO}"
	if [ -d './.git' ]; then
		[ $TEST -lt 1 ] && git pull | tee -a "$LCWA_VCLOG"
	elif [ -d './.svn' ]; then
		[ $TEST -lt 1 ] && svn up | tee -a "$LCWA_VCLOG"
	fi
	return $?
}

git_update_do() {
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LLOCAL_REPO="$1"
	git_clean "$LLOCAL_REPO" 
	git_update "$LLOCAL_REPO" && status=0 || status=$?
	if [ $status -eq 0 ]; then
		log_msg "${LLOCAL_REPO} has been updated."
	else
		log_msg "Error updating ${LLOCAL_REPO}."
	fi
}

git_check_up_to_date(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LLOCAL_REPO="$1"
	
	cd "$LLOCAL_REPO" && git_in_repo "$LLOCAL_REPO" 
	if [ -d './.git' ]; then
		# http://stackoverflow.com/questions/3258243/git-check-if-pull-needed
		log_msg "Checking ${LLOCAL_REPO} to see if update is needed.."
		if [ $($TIMEOUT_BIN $PROC_TIMEOUT git remote -v update 2>&1 | grep -c "\[up to date\]") -gt 0 ]; then
			log_msg "Local repository ${LLOCAL_REPO} is up to date."
			return 0
		else
			log_msg "Local repository ${LLOCAL_REPO} requires update."
			git_update_do "$LLOCAL_REPO"
			return 1
		fi
	fi
}

######################################################################################################
# utility_scripts_install( SUP_REPO_SCRIPT_DIR ) Installs the utility scripts to /usr/local/sbin
######################################################################################################
utility_scripts_install(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LSCRIPT_DIR="$1"
	local LTARGET_DIR='/usr/local/sbin'
	local LSCRIPT=
	local LSOURCE=
	local LTARGET=
	
	for LSCRIPT in '../instsrv_functions.sh' $(ls -1 "${LSCRIPT_DIR}/" )
	do
		if [ "$LSCRIPT" = 'getscripts.sh' ] || [ "$LSCRIPT" = 'makelinks.sh' ]; then
			continue
		fi
		
		LSOURCE="${LSCRIPT_DIR}/${LSCRIPT}"
		LTARGET="${LTARGET_DIR}/${LSCRIPT}"
		
		if [ -f "$LSOURCE" ]; then
			if [ "$SOURCE" -nt "$TARGET" ]; then
				# Test the script for errors
				bash -n "$LSOURCE"
				if [ $? -gt 0 ]; then
					error_echo '============================================================='
					error_echo "Error: bash says that ${LSOURCE} has errors!!!"
					error_echo '============================================================='
				else
					error_echo "Copying ${LSOURCE} to ${LTARGET}"
					[ $TEST -lt 1 ] && cp -p "$LSOURCE" "$LTARGET"
				fi
			fi
		fi
	
	done
	
}


script_version_get(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LSCRIPT="$1"
	sed -n -e 's/^SCRIPT_VER.*=\(.*\)$/\1/p' "$LSCRIPT"
}


service_update_check(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LLOCAL_REPO="$1"
	local LBEFORE_VER="$2"
	local LINSTALL_XML="${LLOCAL_REPO}/install.xml"
	local LREPO_VER="$(grep -E '<version>[0-9]{8}\.[0-9]{6}</version>' "$LINSTALL_XML" | sed -n -e 's/^.*\([0-9]\{8\}\.[0-9]\{6\}\).*$/\1/p')"
	local LCONFIG_SCRIPT="${LLOCAL_REPO}/config-${INST_NAME}.sh"
	local LAFTER_VER=$(script_version_get "$LCONFIG_SCRIPT")
	
	if [ $DEBUG -gt 0 ]; then
		log_msg "Comparing versions of ${LCONFIG_SCRIPT} to see if service reconfiguration needed.."
		log_msg "  Before pull version: ${LBEFORE_VER}"
		log_msg "   After pull version: ${LAFTER_VER}"
	fi
	
	# If the repo version is greater than our version..
	if [[ "$LAFTER_VER" > "$LBEFORE_VER" ]]; then
		# Update the service
		log_msg "Updating installed ${INST_NAME} service version ${LCWA_VERSION} to new version ${LREPO_VER} from ${LLOCAL_REPO}/config-${INST_NAME}.sh"
		[ $TEST -lt 1 ] && "$LCONFIG_SCRIPT" --update
	else
		log_msg "Service ${INST_NAME}, version ${LCWA_VERSION} is up to date.  ${LAFTER_VER} is not > ${LBEFORE_VER}."
	fi


}


service_update_check_old(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LLOCAL_REPO="$1"
	local LINSTALL_XML="${LLOCAL_REPO}/install.xml"
	local LREPO_VER=
	local LREPO_EPOCH=
	local LLCWA_EPOCH=
	
	if [ ! -f "$LINSTALL_XML" ]; then
		log_msg "Error: ${LINSTALL_XML} file not found."
		return 100
	fi
	
	log_msg "Checking ${LLOCAL_REPO}/install.xml to see if an update of the ${INST_NAME} service is required."
	
	#~ <version>20200511.232252</version>
	LREPO_VER="$(grep -E '<version>[0-9]{8}\.[0-9]{6}</version>' "$LINSTALL_XML" | sed -n -e 's/^.*\([0-9]\{8\}\.[0-9]\{6\}\).*$/\1/p')"

	
	if [ $DEBUG -gt 0 ]; then
		LREPO_EPOCH="$(echo "$LREPO_VER" | sed -e 's/\./ /g' | sed -e 's/\([0-9]\{8\}\) \([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1 \2:\3:\4/')"
		LREPO_EPOCH="$(date "-d${LREPO_EPOCH}" +%s)"
		LLCWA_EPOCH="$(echo "$LCWA_VERSION" | sed -e 's/\./ /g' | sed -e 's/\([0-9]\{8\}\) \([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1 \2:\3:\4/')"
		LLCWA_EPOCH="$(date "-d${LLCWA_EPOCH}" +%s)"
		
		log_msg "Comparing version timestamps:"
		log_msg "Running: [${LLCWA_EPOCH}] $(date_epoch_to_iso8601  ${LLCWA_EPOCH})"
		log_msg "'  Repo: [${LREPO_EPOCH}] $(date_epoch_to_iso8601  ${LREPO_EPOCH})"

		if [ $LLCWA_EPOCH -lt $LREPO_EPOCH ]; then
			log_msg "Running ${SCRIPT} version is older than repo ${LINSTALL_XML} by $(displaytime $(echo "${LREPO_EPOCH} - ${LLCWA_EPOCH}" | bc))."
		else
			log_msg "Running ${SCRIPT} version is newer than repo ${LINSTALL_XML} by $(displaytime $(echo "${LLCWA_EPOCH} - ${LREPO_EPOCH}" | bc))." 
		fi
	fi
	
	# If the repo version is greater than our version..
	if [[ "$LREPO_VER" > "$LCWA_VERSION" ]]; then
		# Install updated utility scripts..
		# Redundant??
		#~ utility_scripts_install "${LLOCAL_REPO}/scripts"
		# Update the service
		log_msg "Updating installed ${INST_NAME} service version ${LCWA_VERSION} to new version ${LREPO_VER} from ${LLOCAL_REPO}/config-${INST_NAME}.sh"
		[ $TEST -lt 1 ] && "${LLOCAL_REPO}/config-${INST_NAME}.sh" --update
	fi
	
}


########################################################################
# json_validate( temp.json, target.json, $(which jq))
#  
########################################################################
json_validate(){
	local LSOURCE="$1"
	local LTARGET="$2"
	local LJQ="$3"
	local LRET=1
	
	[ -z "$LJQ" ] && LJQ="$(which jq)"
	
	if [ -z "$LJQ" ]; then
		log_msg "${FUNCNAME}() Error: jq  command-line JSON processor not found."
		return 1
	fi
	
	# Validate the new json
	cat "$LTEMPFILE" | "$LJQ" > /dev/null 2>&1
	LRET=$?
	
	if [ $LRET -eq 0 ]; then
		log_msg "New configuration passes json validation.  Installing it to ${LTARGET}."
		cp -p "$LTARGET" "${LTARGET}.bak"
		cp -p "$LSOURCE" "$LTARGET"
		chmod 644 "$LTARGET"
	else
		log_msg "Error: New configuration did not pass json validation."
		return 1
	fi
	
	return 0
}

clustercontrol_update(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME}( $@ )"
	local LLCWA_CONFFILE="${1:-${LCWA_CONFFILE}}"
	local LREPO_CONFFILE="${2:-${LCWA_REPO_LOCALCONF}}"
	local LTEMPFILE="$(mktemp)"
	local LJQ="$(which jq)"
	
	if [ -z "$LLCWA_CONFFILE" ] || [ ! -f "$LLCWA_CONFFILE" ]; then
		log_msg "Error: ${LLCWA_CONFFILE} json config file not found."
		return 1
	fi
	
	if [ -z "$LREPO_CONFFILE" ] || [ ! -f "$LREPO_CONFFILE" ]; then
		log_msg "Error: repo ${LLCWA_CONFFILE} json config file not found."
		return 1
	fi
	
	if [ -z "$LJQ" ]; then
		log_msg "${FUNCNAME}() Error: jq  command-line sjon processor not found."
		return 1
	fi
	
	# Strip the current ClusterControl from our json conf file.
	"$LJQ" 'del(.ClusterControl)' "$LLCWA_CONFFILE" >"$LTEMPFILE"

	# Validate the json..
	json_validate "$LTEMPFILE" "$LLCWA_CONFFILE" "$LJQ"
	if [ $? -gt 0 ]; then
		log_msg "Error: Could not validate ClusterControl removal from ${LLCWA_CONFFILE}"
		return 1
	fi
	
	# Merge in Andi's repo's json conf file..
	"$LJQ" -s ".[0] * .[1]" "$LREPO_CONFFILE" "$LLCWA_CONFFILE" >"$LTEMPFILE"
	
	# Validate the merged json data..
	json_validate "$LTEMPFILE" "$LLCWA_CONFFILE" "$LJQ"
	if [ $? -gt 0 ]; then
		log_msg "Error: Could not validate merged json data in ${LLCWA_CONFFILE}."
		return 1
	fi
	
	# Make sure our ClusterControl runmode is set to "Both"
	

	log_msg "ClusterControl update of ${LLCWA_CONFFILE} complete."
	
	debug_pause "${FUNCNAME}: ${LINENO}"
	return 0
	
}

################################################################################
################################################################################
# main()
################################################################################
################################################################################

# Process cmd line args..
SHORTARGS='hdvftlcw'
LONGARGS="help,
debug,
verbose,
force,
test,
log,
log-clear,
clear-log,
no-update,
no-patch,
cluster,
no-cluster,
services-update,
no-servcies-update,
sbin-update,
os-update"

# Remove line-feeds..
LONGARGS="$(echo "$LONGARGS" | sed ':a;N;$!ba;s/\n//g')"

ARGS=$(getopt -o "$SHORTARGS" -l "$LONGARGS"  -n "$(basename $0)" -- $@)

if [ $? -gt 0 ]; then
	disp_help "$SCRIPT_DESC"
	exit 1
fi

eval set -- "$ARGS"

while [ $# -gt 0 ]; do
	case "$1" in
		--)
			;;
		-h|--help)		# Displays this hellp
			disp_help "$SCRIPT_DESC"
			exit 0
			;;
		-d|--debug)		# Shows debugging info.
			((DEBUG+=1))
			;;
		-q|--quiet)		# Supresses message output.
			QUIET=1
			;;
		-v|--verbose)		# Display additional message output.
			((VERBOSE+=1))
			;;
		-f|--force)		# Forces reinstall of jq commandline JSON processor
			FORCE=1
			;;
		-t|--test)		# Test mode -- -tt will create json in ${SCRIPT_DIR}
			((TEST+=1))
			;;
		-l|--log)		# Turns on output logging
			LOG=1
			;;
		-c|--log-clear|--clear-log)	#Clears the output log
			LOG_CLEAR=1
			LOG=1
			;;
		--cluster)	# Updates the config.json ClusterControl block from the repo config.
			CLUSTER_UPDATE=1
			;;
		--no-cluster)
			CLUSTER_UPDATE=0
			;;
		--no-update)
			NO_UPDATES=1
			;;
		--no-patch)
			NO_PATCH=1
			;;
		--services-update)
			SERVICES_UPDATE=1
			;;
		--no-services-update)
			SERVICES_UPDATE=0
			;;
		--sbin-update)	# Updates scripts in /usr/local/sbin from a remote zip archive
			SBIN_UPDATE=1
			;;
		--os-update)	# Performs an apt-get dist-upgrade
			OS_UPDATE=1
			;;
		*)
			log_msg "Error: unrecognized option ${1}."
			disp_help "$SCRIPT_DESC"
			exit 1
			;;
	esac
	shift
done

# Get our environmental variables..
env_file_read

[ $LOG_CLEAR -gt 0 ] && log_clear "# $(date)"

log_msg "#########################################################################"
log_msg "${SCRIPT_NAME} ${ARGS}"

SERVICE_NAME="$(service_name_get "$INST_NAME")"

# Fall back..
if [ -z "$SERVICE_NAME" ]; then
	systemctl is-enabled --quiet "$INST_NAME" 2>/dev/null
	[ $? -eq 0 ] && SERVICE_NAME="$INST_NAME"
fi

if [ -z "$SERVICE_NAME" ]; then
	log_msg "Could not identify an enabled service like ${INST_NAME}*. Exiting."
	exit 1
else
	log_msg "Beginning update check for ${SERVICE_NAME}.."
fi

service_stop "$SERVICE_NAME"

if [ $NO_UPDATES -gt 0 ]; then
	log_msg "Updates for ${SERVICE_NAME} disabled.  Restarting ${SERVICE_NAME} only."
else

	# Selectivly perform updates..

	# Check and update the speedtest python code repo..
	if [ $LCWA_REPO_UPDATE -gt 0 ]; then
		git_check_up_to_date "$LCWA_REPO_LOCAL"
	fi
	
	# Update this update repo..
	if [ $LCWA_SUPREPO_UPDATE -gt 0 ]; then
		# Check & update the suplimental repo (contains this script)
		BEFORE_VER=$(script_version_get "${LCWA_SUPREPO_LOCAL}/config-${INST_NAME}.sh")
		git_check_up_to_date "$LCWA_SUPREPO_LOCAL"

		# Service version is: $LCWA_VERSION
		# See if we need to update the service installation
		service_update_check "$LCWA_SUPREPO_LOCAL" "$BEFORE_VER"
	fi
	
	# See if we need to update this update script..
	if [ $SERVICES_UPDATE -gt 0 ]; then
		services_zip_update
	fi

	if [ $SBIN_UPDATE -gt 0 ]; then
		sbin_zip_update
	fi

	if [ $OS_UPDATE -gt 0 ]; then
		log_msg "Updating operating system.."
		[ $TEST -lt 1 ] && apt-get update
		[ $TEST -lt 1 ] && apt-get -y upgrade
	fi
	
	# Patch the repo with our local patch files..
	if [ $LCWA_REPO_PATCH -gt 1 ] && [ $NO_PATCH-lt 1 ]; then
		PATCHSCRIPT="${LCWA_REPO_LOCAL}_patches/src/apply.sh"
		log_msg "Checking for ${PATCHSCRIPT} patch script."

		if [ -f "$PATCHSCRIPT" ]; then

			log_msg "Applying patches to ${LCWA_REPO_LOCAL} from ${PATCHSCRIPT} patch script."
			
			[ $TEST -lt 1 ] && "$PATCHSCRIPT" | tee -a "$LCWA_VCLOG"
			
		else
			log_msg "${PATCHSCRIPT} patch script does not exist."
		fi
	else
		[ $VERBOSE -gt 0 ] && log_msg "Patch updates for ${LCWA_REPO_LOCAL} are disabled."
	fi

	# Update the ClusterControl block from Andi's repo's json config file..
	if [ $CLUSTER_UPDATE -gt 0 ]; then
		log_msg "Merging ClusterControl data from ${LCWA_REPO_LOCALCONF}."
		clustercontrol_update "$LCWA_CONFFILE"
	fi

fi	


if [ $REBOOT -gt 0 ]; then
	log_msg "${SCRIPT} requries a reboot of this system!"
	[ $TEST -lt 1 ] && shutdown -r 1 "${SCRIPT} requries a reboot of this system!"
else
	service_start "$SERVICE_NAME"
fi

log_msg "Update check for ${INST_NAME} finished."

exit 0


