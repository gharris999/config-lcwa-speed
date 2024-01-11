#!/bin/bash

# Script to wipe the stdout & stderr lcwa-speed service logs
SCRIPT="$(readlink -f "$0")"
SCRIPT_NAME="$(basename "$SCRIPT")"
SCRIPT_DISC="Script to wipe (truncate) the lcwa-speed service stdout and stderr logs.  Optionally wipes the current day's CSV file."

disp_help(){
    local LSCRIPTNAME="$(basename "$0")"
    local LDESCRIPTION="$1"
    local LEXTRA_ARGS="${@:2}"
    echo -e "\n${LSCRIPTNAME}: ${LDESCRIPTION}\n"
    echo -e "\nSyntax: ${LSCRIPTNAME} [ options ] ${LEXTRA_ARGS}\n"
    echo -e "    Optional parameters:\n"
    #~ cat "$(readlink -f "$0")" | grep -E '^\s+-' | grep -v -- '--)' | sed 's/)//' 1>&2
    if [ ! -z "$SCRIPT" ] && [ -e "$SCRIPT" ]; then
	cat "$SCRIPT" | grep -E '^\s+-.*)\s+#' | grep -v -- '--)' | grep -vi '# hide' | sed 's/)//' 1>&2
    else
	grep -E '^\s+-.*)\s+#' "$0" | grep -v -- '--)' | grep -vi '# hide' | sed 's/)//' 1>&2
    fi
    echo ' '
}

DEBUG=0
VERBOSE=0
TEST=0

# Default location & name of the envfile
ENV_FILE='/etc/default/lcwa-speed'

# Get the location and names of our log & data files from the environment file..
source "$ENV_FILE"
if [ $? -gt 0 ]; then
    echo "${SCRIPT_NAME} Error: cannot load ${ENV_FILE} environmental vars file. Exiting."
    exit 1
fi

WIPE_CSV=0
NO_ROTATE=0
NO_FIX_OWNER=0

FNAME_DATE="$(date +%F)"

SHORTARGS='hdvtwrn'
LONGARGS="help,debug,verbose,test,wipe-csv,no-rotate,no-fix"

ARGS=$(getopt -o "$SHORTARGS" -l "$LONGARGS" -n "$(basename $0)" -- "$@")

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
	-h|--help)	# Display this help
	    disp_help "$SCRIPT_DESC"
	    exit 0
	    ;;
	-d|--debug)	# Emit debugging info
	    ((DEBUG+=1))
	    ;;
	-t|--test)	# Operate in dry-run mode, i.e. don't actually truncate files.
	    ((TEST+=1))
	    ;;
	-w|--wipe-csv)	# Wipe today's CSV data file too.
	    WIPE_CSV=1
	    ;;
	-r|--no-rotate)	# Don't execute the log rotate script before wiping logs
	    NO_ROTATE=1
	    ;;
	-n|--no-fix)	# Don't attempt to fixup file ownerships. By default, the script fixes ownership of the log & csv file directories.
	    NO_FIX_OWNER=1
	    ;;

    esac
    shift
done

[ $TEST -gt 0 ] && echo 'Operating in test / dry-run mode..'

# Construct the CSV filename:
LCWA_CSVFILE="${LCWA_DATADIR}/$(hostname | cut -c -4)_${FNAME_DATE}speedfile.csv"
CSVFILE_NAME="$(basename "$LCWA_CSVFILE")"


if [ $DEBUG -gt 0 ]; then
    echo ' '
    echo "DEBUG         == ${DEBUG}"
    echo "VERBOSE       == ${VERBOSE}"
    echo "TEST          == ${TEST}"
    echo ' '
    echo "LCWA_LOGDIR	== ${LCWA_LOGDIR}"
    echo "LCWA_LOGFILE	== ${LCWA_LOGFILE}"
    echo "LCWA_ERRFILE	== ${LCWA_ERRFILE}"
    echo ' '
    echo "LCWA_DATADIR	== ${LCWA_DATADIR}"
    echo "LCWA_CSVFILE	== ${LCWA_CSVFILE}"
    echo ' '
    echo "WIPE_CSV      == ${WIPE_CSV}"
    echo "NO_ROTATE     == ${NO_ROTATE}"
    echo "NO_FIX_OWNER  == ${NO_FIX_OWNER}"
    echo ' '
    
    sleep 3
fi

# Rotate the logs before wiping..
if [ $NO_ROTATE -lt 1 ]; then
    ROTATE_CONF_FILE="/etc/logrotate.d/${LCWA_SERVICE}"
    echo "Executing /etc/logrotate.d/${LCWA_SERVICE} log rotate script.."
    [ $TEST -lt 1 ] && logrotate -vf "$ROTATE_CONF_FILE"
fi

for FILE in "$LCWA_LOGFILE" "$LCWA_ERRFILE"
do
    if [ -f "$FILE" ]; then
	echo "Creating backup of ${FILE}.."
	[ $TEST -lt 1 ] && cp -p "$FILE" "${FILE}.bak"
	echo "Truncating file ${FILE}.."
	[ $TEST -lt 1 ] && truncate --size=0 "$FILE"
    else
	"Creating file ${FILE}.."
	[ $TEST -lt 1 ] && touch "$FILE"
    fi
done

# Only truncate the CSV file if we pass --wipe-csv arg
if [ $WIPE_CSV -gt 0 ]; then
    if [ -f "$LCWA_CSVFILE" ]; then
	if [ ! -f "${LCWA_CSVFILE}.bak" ]; then
	    echo "Backing up file ${CSVFILE_NAME}.."
	    [ $TEST -lt 1 ] && cp -p "$LCWA_CSVFILE" "${LCWA_CSVFILE}.bak"
	else
	    # Test to make sure line count of the csv file isn't less than the line count of the backup file..
	    if [ $(wc -l "${LCWA_CSVFILE}.bak") -le $(wc -l "$LCWA_CSVFILE") ]; then
		echo "Backing up file ${CSVFILE_NAME}.."
		[ $TEST -lt 1 ] && cp -p "$LCWA_CSVFILE" "${LCWA_CSVFILE}.bak"
	    else
		echo "Not backing up ${CSVFILE_NAME}. Existing backup is longer."
	    fi
	fi
	    
	# Truncate the CSV file
	echo "Truncating file ${CSVFILE_NAME}.."
	[ $TEST -lt 1 ] && truncate --size=0 "$LCWA_CSVFILE"
    fi
fi

# Create the CSV file if it doesn't exist..
if [ ! -f "$LCWA_CSVFILE" ]; then
    echo "Creating file ${CSVFILE_NAME}.."
    [ $TEST -lt 1 ] && touch "$LCWA_CSVFILE"
fi

# Make sure the current CSV file has a header row!!
echo "Checking for header row in ${CSVFILE_NAME}.."
if [ $(head -n 1 "$LCWA_CSVFILE" | grep -c -E '^day,time,') -lt 1 ]; then
	MY_IP="$(dig +short myip.opendns.com @resolver1.opendns.com)"
	[ -z "$MY_IP" ] && MY_IP='63.233.220.21'
	HEADER_ROW="day,time,server name,server id,latency,jitter,package,download,upload,latency measured,${MY_IP}"

	if [ $(cat "$LCWA_CSVFILE" | wc -l) -gt 0 ]; then
		echo "Inserting header row into ${LCWA_CSVFILE}."
		#~ [ $TEST -lt 1 ] && sed -i "1 i ${HEADER_ROW}" "$LCWA_CSVFILE"
		[ $TEST -lt 1 ] && sed -i "1s/^/${HEADER_ROW}\n/" "$LCWA_CSVFILE"
	else
		echo "Appending header row onto empty ${LCWA_CSVFILE}."
		[ $TEST -lt 1 ] && echo "$HEADER_ROW" >"$LCWA_CSVFILE"
	fi
fi

# Fix file ownership
if [ $NO_FIX_OWNER -lt 1 ]; then
    echo "Fixing file ownership for ${LCWA_USER}:${LCWA_GROUP} in ${LCWA_LOGDIR}.."
    chown -R "${LCWA_USER}:${LCWA_GROUP}" "$LCWA_LOGDIR"

    echo "Fixing file ownership for ${LCWA_USER}:${LCWA_GROUP} in ${LCWA_DATADIR}.."
    chown -R "${LCWA_USER}:${LCWA_GROUP}" "$LCWA_DATADIR"
fi



