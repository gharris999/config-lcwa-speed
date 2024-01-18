#!/bin/bash

############################################################################################################
# Bash script to check to see if a auto initiated pppoe connection is still up, and if not, re-establish it.
############################################################################################################

SCRIPT_VERSION=20240118.150037

SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
SCRIPT_NAME="$(basename $0)"
SCRIPT_DESC="Check for an active PPPoE connection and reestablishes it if down."

QUIET=0
TEST=0
FORCE=0
WAITSECS=4

IS_FEDORA="$(grep -c -e '^ID.*=.*fedora' /etc/os-release)"

IFACE_FILE='/etc/network/interfaces'
DEF_PROVIDER='provider'
LCWA_SERVICE='lcwa-speed'

# Get our PPPoE account name from /etc/network/interfaces
#~ if [ ! -f "$IFACE_FILE" ]; then
	#~ exit 1
#~ fi

error_echo(){
	echo "$@" 1>&2;
}

####################################################################################
# Stamp a message with the date and the script name (and process id) using
# the same format as found in the squeezeboxserver server.log
#
date_message(){
	DATE=$(date '+%F %H:%M:%S.%N')
	DATE=${DATE#??}
	DATE=${DATE%?????}
	echo "[${DATE}] " $@ 1>&2;
}

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


crontab_entry_set(){
	COMMENT=
	EVENT=
	local PPPOE_ACCOUNT=
	local LINTERFACES='/etc/network/interfaces'
	local ROOTCRONTAB='/var/spool/cron/crontabs/root'

	[ $IS_FEDORA -gt 0 ] && ROOTCRONTAB='/var/spool/cron/root'

	[ ! -f "$ROOTCRONTAB" ] && touch "$ROOTCRONTAB"

	# Add a PPPoE connection check to the crontab if a PPPoE interface is defined..
	if [ -e "$LINTERFACES" ]; then
		PPPOE_ACCOUNT="$(grep -E '^auto.*lcwa.*$|^auto.*provider.*$' "$LINTERFACES" | awk '{ print $2 }')"
		if [ ! -z "$PPPOE_ACCOUNT" ]; then
			COMMENT="#At every 10th minute, check the ${PPPOE_ACCOUNT} PPPoE connecton and reestablish it if down."
			EVENT="*/10 * * * * /usr/local/sbin/lcwa-speed-pppck.sh 2>&1 | /usr/bin/logger -t lcwa-speed-pppck"

			# Remove any old reference to chkppp.sh
			sed -i "/^#.*${PPPOE_ACCOUNT}.*$/d" "$ROOTCRONTAB"
			sed -i "/^.*chkppp\.sh.*$/d" "$ROOTCRONTAB"

			error_echo "Adding ${EVENT} to ${ROOTCRONTAB}"
			echo "$COMMENT" >>"$ROOTCRONTAB"
			echo "$EVENT" >>"$ROOTCRONTAB"

		fi
	fi

	# Make sure the permissions are correct for root crontab! (i.e. must not be 644!)
	chmod 600 "$ROOTCRONTAB"

	# signal crond to reload the file
	sudo touch /var/spool/cron/crontabs

	# Make the entry stick
	error_echo "Restarting root crontab.."
	[ $IS_FEDORA -gt 0 ] && systemctl restart crond || systemctl restart cron


	error_echo 'New crontab:'
	error_echo "========================================================================================="
	crontab -l >&2
	error_echo "========================================================================================="
}

crontab_entry_clear(){
	local ROOTCRONTAB='/var/spool/cron/crontabs/root'

	[ $IS_FEDORA -gt 0 ] && ROOTCRONTAB='/var/spool/cron/root'

	[ $TEST -lt 1 ] && cat >"$ROOTCRONTAB" <<-EOF_ROOTCRONTAB0;
	# $(date) -- ${ROOTCRONTAB}
	# Edit this file to introduce tasks to be run by cron.
	#
	# Each task to run has to be defined through a single line
	# indicating with different fields when the task will be run
	# and what command to run for the task
	#
	# To define the time you can provide concrete values for
	# minute (m), hour (h), day of month (dom), month (mon),
	# and day of week (dow) or use '*' in these fields (for 'any').#
	# Notice that tasks will be started based on the cron's system
	# daemon's notion of time and timezones.
	#
	# Output of the crontab jobs (including errors) is sent through
	# email to the user the crontab file belongs to (unless redirected).
	#
	# For example, you can run a backup of all your user accounts
	# at 5 a.m every week with:
	# 0 5 * * 1 tar -zcf /var/backups/home.tgz /home/
	#
	# For more information see the manual pages of crontab(5) and cron(8)
	#
	# m h  dom mon dow   command
	EOF_ROOTCRONTAB0

	# Make sure the permissions are correct for root crontab! (i.e. must not be 644!)
	chmod 600 "$ROOTCRONTAB"

	# signal crond to reload the file
	sudo touch /var/spool/cron/crontabs

	# Make the entry stick
	error_echo "Restarting root crontab.."
	[ $IS_FEDORA -gt 0 ] && systemctl restart crond || systemctl restart cron


	error_echo 'New crontab:'
	error_echo "========================================================================================="
	crontab -l >&2
	error_echo "========================================================================================="
}

pppoe_provider_get(){
	local LIFACE_FILE='/etc/network/interfaces'
	local LIFACES=
	local LIFACE=
	local LPPPOE_PROVIDER=
	
	if [ ! -f "$IFACE_FILE" ]; then
		if [ $FORCE -gt 0 ]; then
			echo "$DEF_PROVIDER"
		else
			date_message "${SCRIPT_NAME} error -- file not found: ${LIFACE_FILE}"
		fi
		return 1
	fi
	
	LIFACES="$(grep -E '^auto' "$LIFACE_FILE" | awk '{ print $2 }')"

	for LIFACE in $LIFACES
	do
		if [ $(grep -c -E "^iface ${LIFACE} inet ppp" "$LIFACE_FILE") -gt 0 ]; then
			LPPPOE_PROVIDER="$LIFACE"
			break
		fi
	done

	if [ -z "$LPPPOE_PROVIDER" ]; then
		date_message "${SCRIPT_NAME} error: No ppp interface defined in ${LIFACE_FILE}"
		exit 1
	fi
	
	echo "$LPPPOE_PROVIDER"
	return 0
}

ppp_link_is_up(){

	[ $(ip -br a | grep -c -E '^ppp.*peer') -gt 0 ] && return 0 || return 1

}

ppp_link_check(){

	local LPPPOE_PROVIDER="$(pppoe_provider_get)"
	local LRET=1
	
	if ppp_link_is_up; then
		[ $QUIET -lt 1 ] && date_message "PPPoE connection ${LPPPOE_PROVIDER} is UP."
		LRET=0
	else
		[ $QUIET -lt 1 ] && date_message "PPPoE connection ${LPPPOE_PROVIDER} is DOWN."
	
		if [ ! -z "$LPPPOE_PROVIDER" ]; then
			[ $QUIET -lt 1 ] && date_message "Reestablishing ${LPPPOE_PROVIDER} PPPoE connection."
			#~ [ $TEST -lt 1 ] && pppd call "$LPPPOE_PROVIDER"
			[ $TEST -lt 1 ] && pon "$LPPPOE_PROVIDER"
			[ $TEST -lt 1 ] && sleep $WAITSECS
			if ppp_link_is_up; then
				[ $QUIET -lt 1 ] && date_message "PPPoE connection ${LPPPOE_PROVIDER} reestablished and is UP."
			else 
				date_message "${SCRIPT_NAME} error: Could not reestablish PPPoE connection ${LPPPOE_PROVIDER}."
			fi
			LRET=$?
		else
			date_message "Error: could not determine a PPPoE account to reestablish PPPoE connection."
			LRET=1
		fi
	fi
	
	return $LRET
}

####################################################################################################
####################################################################################################
####################################################################################################
####################################################################################################
# main()
####################################################################################################
####################################################################################################
####################################################################################################
####################################################################################################

# Process cmd line args..
SHORTARGS='hqftw:'
LONGARGS='help,quiet,force,test,history,crontab-set,crontab-clear,wait:'
ARGS=$(getopt -o "$SHORTARGS" -l "$LONGARGS"  -n "$(basename $0)" -- $@)

eval set -- "$ARGS"

while [ $# -gt 0 ]; do
	case "$1" in
		--)
			;;
		-h|--help)		# Display this help
			disp_help "$SCRIPT_DESC" "default_provider_name"
			exit 0
			;;
		-q|--quiet)		# Inhibit message output
			QUIET=1
			VERBOSE=0
			;;
		-f|--force)		# Use the DEF_PROVIDER account if no /etc/network/interfaces file
			FORCE=1
			;;
		-t|--test)
			TEST=1
			;;
		--history)		# greps the syslog for crontab lcwa-speed-pppck entries
			cat /var/log/syslog | grep 'lcwa-speed-pppck:'
			exit 0
			;;
		--crontab-set)	# Add a contab entry to run this script every 10 minutes.
			crontab_entry_set
			exit 0
			;;
		--crontab-clear)	# Clear all crontab entries.
			crontab_entry_clear
			exit 0
			;;
		-w|--wait)	# =wait_secs -- Number of seconds to wait to see if connection is back up.  Defaults to 4 seconds.
			shift
			WAITSECS=$1
			;;
		*)
			DEF_PROVIDER="$1"
			;;
	esac
	shift
done

ppp_link_check
exit $?

