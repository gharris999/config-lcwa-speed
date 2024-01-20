#!/bin/bash

######################################################################################################
# Bash script for configuring sysctl parameters to enable automatic system reboots on various types
# of kernel panics.
#
# Latest mod: code cleanup.
######################################################################################################
SCRIPT_VERSION=20240120.094107


SCRIPT="$(realpath -s "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
SCRIPT_NAME="$(basename $0)"
SCRIPT_DESC="Script to enable automatic reboots on kernel panics.."
SCRIPT_EXTRA="[ new_kernel.panic_key=0|1 ]"
SCRIPT_FUNC='instsrv_functions.sh'

# Load the helper functions..
source "${SCRIPT_DIR}/${SCRIPT_FUNC}" >/dev/null 2>&1
if [ $? -gt 0 ]; then
    source "$SCRIPT_FUNC" >/dev/null 2>&1
    if [ $? -gt 0 ]; then
	echo "${SCRIPT_NAME} error: Cannot load script helper functions in ${SCRIPT_FUNC}. Exiting."
	exit 1
    fi
fi

DEBUG=0
QUIET=0
VERBOSE=0
FORCE=0
TEST=0
LOGGING=0
LOG=0

LIST_ONLY=0
DEFAULTS=0
DISABLE=0
DELETE=0
TEST_PANIC=0
SYSCLT_PANIC_NEWVALS=


sysctl_panic_enable(){
    debug_echo "${FUNCNAME}($@)"
    local LCONF_FILE="$1"
    local LRET=1
    error_echo "Enabling sysctl values in file ${LCONF_FILE}.."
    
    [ $TEST -lt 1 ] && sysctl -p "$LCONF_FILE" | sort
}

sysctl_panic_conf_delete(){
    debug_echo "${FUNCNAME}($@)"
    local LCONF_FILE="$1"
    [ $QUIET -lt 1 ] && error_echo "Removing file ${LCONF_FILE}.."
    [ $TEST -lt 1 ] && rm "$LCONF_FILE"
}

sysctl_panic_conf_write(){
    debug_echo "${FUNCNAME}($@)"
    local LCONF_FILE="$1"
    local LRET=1
    [ $QUIET -lt 1 ] && error_echo "Writing panic coping values to file ${LCONF_FILE}.."

[ $TEST -lt 1 ] && cat >"$LCONF_FILE" <<-CONF1;
# $(date) -- ${LCONF_FILE} created by ${SCRIPT_NAME}

# Reboot this many seconds after panic and print the panic
kernel.panic = 20
kernel.panic_print = 1

# Panic if the kernel detects an I/O channel
# check (IOCHK). 0=no | 1=yes
kernel.panic_on_io_nmi = 1

# Panic if a hung task was found. 0=no, 1=yes
kernel.hung_task_panic = 1

# Setup timeout for hung task,
# in seconds (suggested 300, i.e. 5 minutes)
kernel.hung_task_timeout_secs = 660

# Panic on out of memory.
# 0=no | 1=usually | 2=always
vm.panic_on_oom=2

# Panic when the kernel detects an NMI
# that usually indicates an uncorrectable
# parity or ECC memory error. 0=no | 1=yes
kernel.panic_on_unrecovered_nmi=1

# Panic if the kernel detects a hard or soft-lockup
# error (1). Otherwise it lets the watchdog
# process skip it's update (0)
kernel.hardlockup_panic = 1
kernel.softlockup_panic = 1

# Panic on oops too. Use with caution.
# kernel.panic_on_oops=30

# Panic on unknown non-maskable interrupt panic.
kernel.unknown_nmi_panic = 1

CONF1

    LRET=$?
    [ $LRET -lt 1 ] && error_echo "${LCONF_FILE} writen." || error_echo "Error writing to ${LCONF_FILE}."

    return $LRET
 
}

sysctl_panic_list(){
    debug_echo "${FUNCNAME}($@)"
    sysctl --all --pattern '.*panic.*' | sort | sed -e 's/ = /=/' 1>&2
    error_echo ' '
}

sysctl_panic_setting_write(){
    debug_echo "${FUNCNAME}($@)"
    local LCONF_FILE="$1"
    local LSETTING="$2"
    local LSETTING_KEY=
    local LSETTING_VALUE=

    if [ ! -f "$LCONF_FILE" ]; then
	error_exit "Error: file ${LCONF_FILE} does not exist. Exiting."
	exit 1
    fi

    if [ -z "$LSETTING" ]; then
	error_echo "Argument error. Setting key=value cannot be null."
	return 1
    fi

    LSETTING_KEY="$(echo "$LSETTING" | sed -n -e 's/^\(.*\)=.*$/\1/p')"
    LSETTING_VALUE="$(echo "$LSETTING" | sed -n -e 's/^.*=\(.*\)$/\1/p')"

    debug_echo "LSETTING_KEY == '${LSETTING_KEY}'"
    debug_echo "LSETTING_VALUE == '${LSETTING_VALUE}'"
    
    if [ $(grep -c -E "^${LSETTING_KEY} *=.*\$" "$LCONF_FILE") -gt 0 ]; then
	[ $QUIET -lt 1 ] && error_echo "Setting ${LSETTING_KEY} = ${LSETTING_VALUE} in ${LCONF_FILE}"
	[ $TEST -lt 1 ] && sed -i "s/^${LSETTING_KEY} *=.*\$/${LSETTING}/" "$LCONF_FILE"
    else
	if [ $FORCE -gt 0 ]; then
	    [ $QUIET -lt 1 ] && error_echo "Appending ${LSETTING_KEY} = ${LSETTING_VALUE} to ${LCONF_FILE}"
	    [ $TEST -lt 1 ] && echo "$LSETTING" >>"$LCONF_FILE"
	else
	    error_echo "${LSETTING_KEY} not found in ${LCONF_FILE}. Use --force to append the setting."
	fi
    fi
    
}

sysctl_panic_settings_write(){
    debug_echo "${FUNCNAME}($@)"
    local LCONF_FILE="$1"
    local LSETTINGS="$2"
    local LSETTING=
    local LSETTING_KEY=
    local LSETTING_VALUE=

    for LSETTING in $LSETTINGS
    do
	sysctl_panic_setting_write "$LCONF_FILE" "$LSETTING"
    done
}

sysctl_panic_defaults_write(){
    debug_echo "${FUNCNAME}($@)"
    local LCONF_FILE="$1"
    local LRET=1
    error_echo "Writing default sysctl values to file ${LCONF_FILE}.."

    # List the 
    # sysctl --all --pattern '.*panic.*'

    [ $QUIET -lt 1 ] && error_echo "Writing kernel panic defaults to ${LCONF_FILE}"

    if [ $TEST -lt 1 ]; then
	sysctl_panic_setting_write "$LCONF_FILE" "kernel.hardlockup_panic = 0"
	sysctl_panic_setting_write "$LCONF_FILE" "kernel.hung_task_panic = 0"
	sysctl_panic_setting_write "$LCONF_FILE" "kernel.kexec_load_limit_panic = -1"
	sysctl_panic_setting_write "$LCONF_FILE" "kernel.max_rcu_stall_to_panic = 0"
	sysctl_panic_setting_write "$LCONF_FILE" "kernel.panic = 0"
	sysctl_panic_setting_write "$LCONF_FILE" "kernel.panic_print = 0"
	sysctl_panic_setting_write "$LCONF_FILE" "kernel.panic_on_io_nmi = 0"
	sysctl_panic_setting_write "$LCONF_FILE" "kernel.panic_on_oops = 0"
	sysctl_panic_setting_write "$LCONF_FILE" "kernel.panic_on_rcu_stall = 0"
	sysctl_panic_setting_write "$LCONF_FILE" "kernel.panic_on_unrecovered_nmi = 0"
	sysctl_panic_setting_write "$LCONF_FILE" "kernel.panic_on_warn = 0"
	sysctl_panic_setting_write "$LCONF_FILE" "kernel.panic_print = 0"
	sysctl_panic_setting_write "$LCONF_FILE" "kernel.softlockup_panic = 0"
	sysctl_panic_setting_write "$LCONF_FILE" "kernel.unknown_nmi_panic = 0"

kernel.panic_on_unrecovered_nmi=1

	
    fi
    
}

sysctl_panic_disable(){
    debug_echo "${FUNCNAME}($@)"
    [ $QUIET -lt 1 ] && error_echo "Disabling kernel panic sysctl settings.."
    local LCONF_FILE="$(mktemp)"

    #~ [ $TEST -lt 1 ] &&
cat > "$LCONF_FILE" <<-SPD1
kernel.hardlockup_panic=0
kernel.hung_task_panic=0
# kernel.kexec_load_limit_panic=-1
# kernel.max_rcu_stall_to_panic=0
kernel.panic=0
kernel.panic_on_io_nmi=0
kernel.panic_on_oops=0
kernel.panic_on_rcu_stall=0
kernel.panic_on_unrecovered_nmi=0
kernel.panic_on_warn=0
kernel.panic_print=0
kernel.softlockup_panic=0
kernel.unknown_nmi_panic=0
vm.panic_on_oom=0
SPD1

    sysctl_panic_enable "$LCONF_FILE"
    rm "$LCONF_FILE"

}

kernel_panic_test(){
    debug_echo "${FUNCNAME}($@)"
    local LWILL_PANIC="$(sysctl --all --pattern 'kernel\.panic' | grep -c -E '^kernel.panic = [^0]')"
    local LWILL_REBOOT_SECS=
    local LHAS_KDUMP=
    local LWALL="$(which wall)"

    if [ $LWILL_PANIC -gt 0 ]; then
	LWILL_REBOOT_SECS="$(sysctl --all --pattern 'kernel\.panic' | grep -E '^kernel.panic = [[:digit:]]+' | awk '{print $3}')"
	#~ set -x
	$LWALL -n >/dev/null 2>&1 <<-EOWALL1;

	Testing simulated kernel panic.

	WARNING: This system WILL panic in 10 seconds
	         and then WILL reboot after another ${LWILL_REBOOT_SECS} seconds.

	EOWALL1

	error_echo -e "Hit Ctrl-C to abort..\n"

	# Display countdown timer..
	for i in {10..01}
	do
	    echo -ne "\rPanicking in ${i} seconds..   "
	    sleep 1
	done
	echo -e "\n\nPanicking NOW!\n" | $LWALL -n >/dev/null 2>&1
	sleep 1
	# Will perform a system crash by a NULL pointer dereference. A crashdump will be taken if configured.
	# See: https://www.kernel.org/doc/html/v6.6/admin-guide/sysrq.html
	#~ [ $TEST -lt 1 ] && echo 1 >/proc/sys/kernel/sysrq
	[ $TEST -lt 1 ] && echo c > /proc/sysrq-trigger
    else
	error_echo -e "\nCannot simulate kernel panic.  This system is not configured to reboot after a kernel panic. See:\n\n"
	sysctl_panic_list
	exit 1
    fi
    
}


########################################################################
########################################################################
########################################################################
# main()
########################################################################
########################################################################
########################################################################

SHORTOPTS='hdqvft'
LONGOPTS="
help,
debug,
quiet,
verbose,
force,
test,
list,
disable,
default,
delete,
test-panic"

# Remove line-feeds..
LONGOPTS="$(echo "$LONGOPTS" | sed ':a;N;$!ba;s/\n//g')"

ARGS=$(getopt -o "$SHORTOPTS" -l "$LONGOPTS"  -n "$(basename $0)" -- "$@")

if [ $? -gt 0 ]; then
    disp_help "$SCRIPT_DESC" "$SCRIPT_EXTRA"
    exit 1
fi

eval set -- "$ARGS"

while [ $# -gt 0 ]; do
    case "$1" in
	--)
	    ;;
	-h|--help)	# Display this help
	    disp_help "$SCRIPT_DESC" "$SCRIPT_EXTRA"
	    exit 0
	    ;;
	-d|--debug)	# Emit debugging info
	    ((DEBUG++))
	    ;;
	-q|--quiet)	# Supress msg output
	    QUIET=1
	    VERBOSE=0
	    ;;
	-v|--verbose)	# Emit extra output
	    QUIET=0
	    ((VERBOSE++))
	    ;;
	-f|--force)	# Append sysctl panic settings to conf file if not present.
	    FORCE=1
	    ;;
	-t|--test)	# Operate in test mode. I.e. test script logic but perform no actions.
	    ((TEST++))
	    ;;
	--list)		# List the current sysctl kernel panic settings
	    LIST_ONLY=1
	    ;;
	--disable)	# Restore (until next reboot) defalt kernel panic sysctl settings.
	    DISABLE=1
	    ;;
	--default)	# Restore (permanently) default kernel panic sysctl settings.
	    DEFAULTS=1
	    ;;
	--delete)	# Deletes the /etc/sysctl.d/10-kernel-panic.conf file and restores defaults.
	    DELETE=1
	    ;;
	--test-panic)	# Tests kernel panic handling by causing an actual panic. Must be used with --force.
	    TEST_PANIC=1
	    ;;
	*)
	    SYSCLT_PANIC_NEWVALS="${SYSCLT_PANIC_NEWVALS} ${1}"
	    ;;
    esac
    shift
done

if [ $LIST_ONLY -gt 0 ]; then
    error_echo ' '
    error_echo "Sysctl panic values:"
    error_echo ' '
    sysctl_panic_list
    exit
fi

# Require root credentials for any other actions..
is_root

if [ $TEST_PANIC -gt 0 ]; then
    if [ $FORCE -gt 0 ]; then
	kernel_panic_test
	exit 0
    else
	error_exit "--test-panic must be used with --force."
    fi
fi

SYSCTL_CONF_DIR='/etc/sysctl.d'
SYSCTL_PANIC_CONF="${SYSCTL_CONF_DIR}/10-kernel-panic.conf"

if [ ! -d "$SYSCTL_CONF_DIR" ]; then
    SYSCTL_PANIC_CONF='/etc/sysctl.conf'
fi

if [ $TEST -lt 1 ]; then
    # Make backups if the conf file exists..
    if [ -f "$SYSCTL_PANIC_CONF" ]; then
	[ ! -f "${SYSCTL_PANIC_CONF}.org" ] && cp -p "$SYSCTL_PANIC_CONF" "${SYSCTL_PANIC_CONF}.org"
	cp -p "$SYSCTL_PANIC_CONF" "${SYSCTL_PANIC_CONF}.bak"
    fi

fi

if [ $VERBOSE -gt 0 ] || [ $DEBUG -gt 0 ]; then
    error_echo ' '
    error_echo "Sysctl panic values BEFORE:"
    error_echo ' '
    sysctl_panic_list
fi

if [ $DEFAULTS -gt 0 ]; then
    sysctl_panic_defaults_write "$SYSCTL_PANIC_CONF"
    sysctl_panic_enable "$SYSCTL_PANIC_CONF"
elif [ $DISABLE -gt 0 ]; then
    sysctl_panic_disable
elif [ $DELETE -gt 0 ]; then
    [ -d "$SYSCTL_CONF_DIR" ] && sysctl_panic_conf_delete "$SYSCTL_PANIC_CONF"
    sysctl_panic_disable
else
    # If we're writing values from the command line..
    if [ ! -z "$SYSCLT_PANIC_NEWVALS" ]; then
    	sysctl_panic_settings_write "$SYSCTL_PANIC_CONF" "$SYSCLT_PANIC_NEWVALS"
	sysctl_panic_enable "$SYSCTL_PANIC_CONF"
    else
	# Create or truncate the conf file except if the conf file is /etc/sysctl.conf
	[ -d "$SYSCTL_CONF_DIR" ] && truncate -s 0 "$SYSCTL_PANIC_CONF"
	sysctl_panic_conf_write "$SYSCTL_PANIC_CONF"
	sysctl_panic_enable "$SYSCTL_PANIC_CONF"
    fi
fi

if [ $VERBOSE -gt 0 ] || [ $DEBUG -gt 0 ]; then
    error_echo ' '
    error_echo "Sysctl panic values AFTER:"
    error_echo ' '
    sysctl_panic_list
fi

