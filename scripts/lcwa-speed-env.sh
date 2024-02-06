#!/bin/bash

SCRIPT_VERSION=20240206.131624


env_vars_zero(){
	local LARG
	for LARG in $@
	do
		# Don't zero out HOME..
		[ "$LARG" = 'HOME' ] && continue
		export "$LARG"
		eval "${LARG}="
		debug_echo "${LARG} == ${!LARG}"
	done

}

env_vars_show(){
	for VAR in $@
	do
		echo "${VAR}=\"${!VAR}\""
	done
}

env_file_exists(){
	debug_echo "${FUNCNAME}( $@ )"
	local LSERVICE_NAME="$1"
	local LBECHO="$2"
	local LINST_ENVFILE=
	
	[ -z "$LSERVICE_NAME" ] && return 1
	
	if [ "${LSERVICE_NAME:0:1}" != '/' ]; then
	
		if [ $IS_DEBIAN -gt 0 ]; then
			LINST_ENVFILE="/etc/default/${LSERVICE_NAME}"
		else
			LINST_ENVFILE="/etc/sysconfig/${LSERVICE_NAME}"
		fi
	else
		LINST_ENVFILE="$LSERVICE_NAME"
	fi
	
	[ ! -f "$LINST_ENVFILE" ] && return 1
	
	[ ! -z "$LBECHO" ] && echo "$LINST_ENVFILE"
	
	return 0
}

######################################################################################################
# Service-specific Vars
######################################################################################################

# Identifiers
#~ LCWA_ENV_VERSION=20240206.131624
#~ LCWA_INSTANCE="$INST_NAME"												# Top-level identifier, defaults to lcwa-speed
#~ LCWA_SERVICE="$INST_NAME"											# Potentially a sub-identifier of LCWA_INSTANCE, e.g. lcwa-speed-beta or lcwa-speed-test
#~ LCWA_PRODUCT="$INST_PROD"
#~ LCWA_DESC="$INST_DESC"
#~ LCWA_PRODUCTID="f1a4af09-977c-458a-b3f7-f530fb9029c1"				# Random GUID..
#~ LCWA_VERSION=20240206.131624

# User account and group under which the service will run..
#~ LCWA_USER="$INST_USER"
#~ LCWA_GROUP="nogroup"

# Principal file locations
#~ LCWA_INSTDIR="/usr/local/share/${LCWA_INSTANCE}"
#~ LCWA_HOMEDIR="/var/lib/${LCWA_INSTANCE}"
#~ LCWA_DATADIR="/var/lib/${LCWA_INSTANCE}/speedfiles"					# Local storage dir for our CSV data

# Remote & local repos
#~ LCWA_REPO='https://github.com/gharris999/LCWA.git'
#~ LCWA_REPO_BRANCH='origin/wgh_mods03'
#~ LCWA_REPO_LOCAL="${LCWA_INSTDIR}/speedtest"
#~ LCWA_REPO_LOCAL_CONF="${LCWA_REPO_LOCAL}/config/test_speed_cfg.json"
#~ LCWA_REPO_LOCAL_PATCHDIR="${LCWA_REPO_LOCAL}_patches/src"
#~ LCWA_REPO_UPDATE=1
#~ LCWA_REPO_PATCH=0

#~ LCWA_SUPREPO='https://github.com/gharris999/config-lcwa-speed.git'
#~ LCWA_SUPREPO_BRANCH='origin/master'
#~ LCWA_SUPREPO_LOCAL="/usr/local/share/config-${LCWA_SERVICE}"
#~ LCWA_SUPREPO_UPDATE=1

# Conf, data & log files
#~ LCWA_ENVFILE="/etc/default/${LCWA_SERVICE}"							# Env vars file read by the systemd service unit file
#~ LCWA_CONFDIR="/etc/${LCWA_SERVICE}"
#~ LCWA_CONFFILE="${LCWA_CONFDIR}/${LCWA_SERVICE}.json"
#~ LCWA_DB_KEYFILE="${LCWA_CONFDIR}/LCWA_d.txt"							# Key file for shared dropbox folder for posting results
#~ LCWA_LOGDIR="/var/log/${LCWA_INSTANCE}"
#~ LCWA_LOGFILE="${LCWA_LOGDIR}/${LCWA_SERVICE}.log"
#~ LCWA_ERRFILE="${LCWA_LOGDIR}/${LCWA_SERVICE}-error.log"
#~ LCWA_VCLOG="${LCWA_LOGDIR}/${LCWA_SERVICE}-update.log"

# Command to be launched by the service
#~ LCWA_DAEMON="${LCWA_INSTDIR}/bin/python3 -u ${LCWA_REPO_LOCAL}/src/test_speed1_3.py"

# Command-line arguments for the daemon
#~ LCWA_OPTIONS="--conf ${LCWA_CONFFILE}"
#~ LCWA_DEBUG_OPTIONS="--conf ${LCWA_CONFFILE} --time 1 --nowait --testdb --verbosity 2"

# Command-ine arguments for the update daemon
#~ LCWA_UPDATE_OPTIONS="--clean"
#~ LCWA_UPDATE_DEBUG_OPTIONS="--debug --clean"

#~ LCWA_EXEC_ARGS="\$LCWA_OPTIONS"
#~ LCWA_EXEC_ARGS_DEBUG="--adebug \$LCWA_OPTIONS"

# Service control variables: pid, priority, memory, etc..
#~ LCWA_PIDFILE="/var/run/${LCWA_INSTANCE}/${LCWA_SERVICE}.pid"
#~ LCWA_NICE=-19
#~ LCWA_RTPRIO=45
#~ LCWA_MEMLOCK=infinity
#~ LCWA_CLEARLOG=1
#~ LCWA_NOUPDATES="1"													# Prevents nightly updates from the remote repos. Can be overridden with config-lcwa-speed-update.sh --force

# Utility Scripts
#~ LCWA_DEBUG_SCRIPT="${LCWA_SUPREPO_LOCAL}/scripts/${INST_NAME}-debug.sh"
#~ LCWA_UPDATE_SCRIPT="${LCWA_SUPREPO_LOCAL}/scripts/${INST_NAME}-update.sh"

# Other control variables for the update script
#~ LCWA_PRESERVE_ENV=													# Prevents the nightly update service from overwriting the env file
#~ LCWA_CLEARLOG=
#~ LCWA_NOUPDATES=

# Other essential environmental variables
#~ PYTHONPATH="${LCWA_INSTDIR}/lib/$(basename $(readlink -f $(which python3)))/site-packages"
#~ HOME="/var/lib/${LCWA_SERVICE}"


function env_vars_name(){
	echo "LCWA_ENV_VERSION" \
"LCWA_INSTANCE" \
"LCWA_SERVICE" \
"LCWA_PRODUCT" \
"LCWA_DESC" \
"LCWA_PRODUCTID" \
"LCWA_VERSION" \
"LCWA_USER" \
"LCWA_GROUP" \
"LCWA_INSTDIR" \
"LCWA_HOMEDIR" \
"LCWA_DATADIR" \
"LCWA_REPO" \
"LCWA_REPO_BRANCH" \
"LCWA_REPO_LOCAL" \
"LCWA_REPO_LOCAL_CONF" \
"LCWA_REPO_LOCAL_PATCHDIR" \
"LCWA_REPO_UPDATE" \
"LCWA_REPO_PATCH" \
"LCWA_SUPREPO" \
"LCWA_SUPREPO_BRANCH" \
"LCWA_SUPREPO_LOCAL" \
"LCWA_SUPREPO_UPDATE" \
"LCWA_ENVFILE" \
"LCWA_CONFDIR" \
"LCWA_CONFFILE" \
"LCWA_DB_KEYFILE" \
"LCWA_LOGDIR" \
"LCWA_LOGFILE" \
"LCWA_ERRFILE" \
"LCWA_VCLOG" \
"LCWA_DAEMON" \
"LCWA_OPTIONS" \
"LCWA_DEBUG_OPTIONS" \
"LCWA_UPDATE_OPTIONS" \
"LCWA_UPDATE_DEBUG_OPTIONS" \
"LCWA_EXEC_ARGS" \
"LCWA_EXEC_ARGS_DEBUG" \
"LCWA_DEBUG_SCRIPT" \
"LCWA_UPDATE_SCRIPT" \
"LCWA_UPDATE_UNIT" \
"LCWA_UPDATE_TIMER" \
"LCWA_PPPOE_INSTALL" \
"LCWA_PPPOE_PROVIDER" \
"LCWA_PPPOE_PASSWORD" \
"LCWA_PPPOE_OPTS" \
"LCWA_PRESERVE_ENV" \
"LCWA_CLEARLOG" \
"LCWA_NOUPDATES" \
"LCWA_UNIT" \
"LCWA_PIDFILE" \
"LCWA_NICE" \
"LCWA_RTPRIO" \
"LCWA_MEMLOCK" \
"PYTHONPATH" \
"HOME"
}


######################################################################################################
# defaults_get() Generate default values for the /etc/sysconfig|default/config file
######################################################################################################
function env_vars_defaults_get(){
	debug_echo "${FUNCNAME}( $@ )"

    [ $VERBOSE -gt 0 ] && error_echo "Getting Defaults.."

# Identifiers
[ -z "$LCWA_ENV_VERSION" ] 			&&  LCWA_ENV_VERSION=20240206.131624
[ -z "$LCWA_INSTANCE" ] 			&&  LCWA_INSTANCE="$INST_NAME"
[ -z "$LCWA_SERVICE" ] 				&&  LCWA_SERVICE="$INST_NAME"
[ -z "$LCWA_PRODUCT" ] 				&&  LCWA_PRODUCT="$INST_PROD"
[ -z "$LCWA_DESC" ] 				&&  LCWA_DESC="$INST_DESC"
[ -z "$LCWA_PRODUCTID" ] 			&&  LCWA_PRODUCTID="f1a4af09-977c-458a-b3f7-f530fb9029c1"				
[ -z "$LCWA_VERSION" ] 				&&  LCWA_VERSION=20240206.131624
                                                            
# User account and group under which the service will run.. 
[ -z "$LCWA_USER" ] 				&&  LCWA_USER="$LCWA_INSTANCE"
[ -z "$LCWA_GROUP" ] 				&&  LCWA_GROUP="nogroup"
                                                            
# Principal file locations                                  
[ -z "$LCWA_INSTDIR" ] 				&&  LCWA_INSTDIR="/usr/local/share/${LCWA_INSTANCE}"
[ -z "$LCWA_HOMEDIR" ] 				&&  LCWA_HOMEDIR="/var/lib/${LCWA_INSTANCE}"
[ -z "$LCWA_DATADIR" ] 				&&  LCWA_DATADIR="/var/lib/${LCWA_INSTANCE}/speedfiles"					
                                                            
# Remote & local repos                                      
[ -z "$LCWA_REPO" ] 				&&  LCWA_REPO='https://github.com/gharris999/LCWA.git'
[ -z "$LCWA_REPO_BRANCH" ] 			&&  LCWA_REPO_BRANCH='origin/wgh_mods03'
[ -z "$LCWA_REPO_LOCAL" ] 			&&  LCWA_REPO_LOCAL="${LCWA_INSTDIR}/speedtest"
[ -z "$LCWA_REPO_LOCAL_CONF" ] 		&&  LCWA_REPO_LOCAL_CONF="${LCWA_REPO_LOCAL}/config/test_speed_cfg.json"
[ -z "$LCWA_REPO_LOCAL_PATCHDIR" ] 	&&  LCWA_REPO_LOCAL_PATCHDIR="${LCWA_REPO_LOCAL}_patches/src"
[ -z "$LCWA_REPO_UPDATE" ] 			&&  LCWA_REPO_UPDATE=1
[ -z "$LCWA_REPO_PATCH" ] 			&&  LCWA_REPO_PATCH=0
                                                            
[ -z "$LCWA_SUPREPO" ] 				&&  LCWA_SUPREPO='https://github.com/gharris999/config-lcwa-speed.git'
[ -z "$LCWA_SUPREPO_BRANCH" ] 		&&  LCWA_SUPREPO_BRANCH='origin/master'
[ -z "$LCWA_SUPREPO_LOCAL" ] 		&&  LCWA_SUPREPO_LOCAL="${LCWA_INSTDIR}/speedtest-config"
[ -z "$LCWA_SUPREPO_UPDATE" ] 		&&  LCWA_SUPREPO_UPDATE=1
                                                            
# Conf, data & log files
[ -z "$LCWA_ENVFILE" ] 				&&  [ $IS_DEBIAN -gt 0 ] && LCWA_ENVFILE="/etc/default/${LCWA_SERVICE}" || LCWA_ENVFILE="/etc/sysconfig/${LCWA_SERVICE}"
[ -z "$LCWA_CONFDIR" ] 				&&  LCWA_CONFDIR="/etc/${LCWA_INSTANCE}"
[ -z "$LCWA_CONFFILE" ] 			&&  LCWA_CONFFILE="${LCWA_CONFDIR}/${LCWA_SERVICE}.json"
[ -z "$LCWA_DB_KEYFILE" ] 			&&  LCWA_DB_KEYFILE="${LCWA_CONFDIR}/LCWA_a.txt"							
[ -z "$LCWA_LOGDIR" ] 				&&  LCWA_LOGDIR="/var/log/${LCWA_INSTANCE}"
[ -z "$LCWA_LOGFILE" ] 				&&  LCWA_LOGFILE="${LCWA_LOGDIR}/${LCWA_SERVICE}.log"
[ -z "$LCWA_ERRFILE" ] 				&&  LCWA_ERRFILE="${LCWA_LOGDIR}/${LCWA_SERVICE}-error.log"
[ -z "$LCWA_VCLOG" ] 				&&  LCWA_VCLOG="${LCWA_LOGDIR}/${LCWA_SERVICE}-update.log"
                                                            
# Command to be launched by the service                     
[ -z "$LCWA_DAEMON" ] 				&&  LCWA_DAEMON="${LCWA_INSTDIR}/bin/python3 -u ${LCWA_REPO_LOCAL}/src/test_speed1_3.py"
                                                            
# Command-line arguments for the daemon                     
[ -z "$LCWA_OPTIONS" ] 				&&  LCWA_OPTIONS="--conf ${LCWA_CONFFILE}"
[ -z "$LCWA_DEBUG_OPTIONS" ]		&&  LCWA_DEBUG_OPTIONS="--conf ${LCWA_CONFFILE} --time 1 --nowait --testdb --verbosity 2"

# Command-line arguments for the update daemon
[ -z "$LCWA_UPDATE_OPTIONS" ] 		&&  LCWA_UPDATE_OPTIONS="--clean"
[ -z "$LCWA_UPDATE_DEBUG_OPTIONS" ]	&&  LCWA_UPDATE_DEBUG_OPTIONS="--debug --clean"

[ -z "$LCWA_EXEC_ARGS" ] 			&&  LCWA_EXEC_ARGS="$LCWA_OPTIONS"
[ -z "$LCWA_EXEC_ARGS_DEBUG" ] 		&&  LCWA_EXEC_ARGS_DEBUG="--adebug \$LCWA_OPTIONS"
                                                            
# Utility Scripts                                           
[ -z "$LCWA_DEBUG_SCRIPT" ] 		&&  LCWA_DEBUG_SCRIPT="${LCWA_SUPREPO_LOCAL}/scripts/${INST_NAME}-debug.sh"
[ -z "$LCWA_UPDATE_SCRIPT" ] 		&&  LCWA_UPDATE_SCRIPT="${LCWA_SUPREPO_LOCAL}/scripts/${INST_NAME}-update.sh"
[ -z "$LCWA_UPDATE_UNIT" ] 			&&  LCWA_UPDATE_UNIT="/lib/systemd/system/${INST_NAME}-update.service"
[ -z "$LCWA_UPDATE_TIMER" ] 		&&  LCWA_UPDATE_TIMER="/lib/systemd/system/${INST_NAME}-update.timer"
[ -z "$LCWA_PPPOE_INSTALL" ] 		&&  LCWA_PPPOE_INSTALL=0
[ -z "$LCWA_PPPOE_PROVIDER" ] 		&&  LCWA_PPPOE_PROVIDER="provider"
[ -z "$LCWA_PPPOE_PASSWORD" ] 		&&  LCWA_PPPOE_PASSWORD="password"

                                                            
# Other control variables for the update script
[ -z "$LCWA_PRESERVE_ENV" ]			&&	LCWA_PRESERVE_ENV=0       
[ -z "$LCWA_CLEARLOG" ] 			&&  LCWA_CLEARLOG=1
[ -z "$LCWA_NOUPDATES" ] 			&&  LCWA_NOUPDATES=1
                                                            
# Service unit file, control variables: pid, priority, memory, etc..
[ -z "$LCWA_UNIT" ] 				&&  LCWA_UNIT="/lib/systemd/system/${LCWA_SERVICE}.service"
[ -z "$LCWA_PIDFILE" ] 				&&  LCWA_PIDFILE="/var/run/${LCWA_INSTANCE}/${LCWA_SERVICE}.pid"
[ -z "$LCWA_NICE" ] 				&&  LCWA_NICE=-19
[ -z "$LCWA_RTPRIO" ] 				&&  LCWA_RTPRIO=45
[ -z "$LCWA_MEMLOCK" ] 				&&  LCWA_MEMLOCK=infinity
                                                            
# Other essential environmental variables                   
[ -z "$PYTHONPATH" ] 				&&  PYTHONPATH="${LCWA_INSTDIR}/lib/$(basename $(readlink -f $(which python3)))/site-packages"
HOME="$LCWA_HOMEDIR"

[ $DEBUG -gt 1 ] && env_vars_show $(env_vars_name)
debug_pause "${LINENO} ${FUNCNAME}: done"

}

