#!/bin/bash
######################################################################################################
# Bash script for viewing the stdout & stderr lcwa-speed service logs and the CSV data file.
#   Requires the multitail package
#
# Latest mod: 
######################################################################################################
SCRIPT_VERSION=20240121.094408

# Script to view the stdout & stderr lcwa-speed service logs and the CSV data file.
SCRIPT="$(realpath -s "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
SCRIPT_NAME="$(basename "$SCRIPT")"
SCRIPT_DESC="Script to view the lcwa-speed service stdout and stderr logs plus the current day's CSV file."

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

pause(){
    read -p "$*"
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

NO_FIX=0

FNAME_DATE="$(date +%F)"

########################################################################

SHORTARGS='hdvtnD:'
LONGARGS="help,debug,verbose,test,no-fix,date:"

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
	-d|--debug)	# View debug logs
	    ((DEBUG+=1))
	    ;;
	-v|--verbose)	# Emit extra Info
	    ((VERBOSE+=1))
	    QUIET=0
	    ;;
	-t|--test)	# Operate in dry-run mode, i.e. don't change any files or directories.
	    ((TEST+=1))
	    ;;
	-n|--no-fix)	# Don't attempt to fixup file ownerships or the csv file header line.
	    NO_FIX=1
	    ;;
	-D|--date)	#=date_str; Shows the CSV file for a different date. E.g. 'yesterday' or '2 days ago'
	    shift
	    FNAME_DATE="$(date -d "$1" +%F)"
	    if [ $? -gt 0 ]; then
		echo "Error: ${1} is not a valid date. Exiting."
		exit 1
	    fi
	    ;;
    esac
    shift
done

[ $TEST -gt 0 ] && echo 'Operating in test / dry-run mode..'

if [ $DEBUG -gt 0 ]; then
    LCWA_LOGFILE="${LCWA_LOGDIR}/${LCWA_SERVICE}-debug.log"
    LCWA_ERRFILE="${LCWA_LOGDIR}/${LCWA_SERVICE}-debug-error.log"
fi

# Construct the CSV filename:
LCWA_CSVFILE="${LCWA_DATADIR}/$(hostname | cut -c -4)_${FNAME_DATE}speedfile.csv"
CSVFILE_NAME="$(basename "$LCWA_CSVFILE")"

if [ $DEBUG -gt 1 ]; then
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
    echo "NO_FIX        == ${NO_FIX}"
    echo ' '
    sleep 3
fi

# Create files that don't exist..
for MYFILE in "$LCWA_LOGFILE" "$LCWA_ERRFILE" "$LCWA_CSVFILE"
do
    if [ ! -f "$MYFILE" ]; then
	[ $VERBOSE -gt 0 ] && echo "Creating ${MYFILE}.."
	[ $TEST -lt 1 ] && touch "$MYFILE"
    fi
done

# Make sure the current CSV file has a header row!!
if [ $NO_FIX -lt 1 ]; then
    [ $VERBOSE -gt 0 ] && echo "Checking for header row in ${CSVFILE_NAME}.."
    if [ $(head -n 1 "$LCWA_CSVFILE" | grep -c -E '^day,time,') -lt 1 ]; then
	MY_IP="$(dig +short myip.opendns.com @resolver1.opendns.com)"
	[ -z "$MY_IP" ] && MY_IP='63.233.220.21'
	HEADER_ROW="day,time,server name,server id,latency,jitter,package,download,upload,latency measured,${MY_IP}"

	if [ $(cat "$LCWA_CSVFILE" | wc -l) -gt 0 ]; then
	    [ $VERBOSE -gt 0 ] && echo "Inserting header row into ${CSVFILE_NAME}."
	    #~ sed -i "1 i ${HEADER_ROW}" "$LCWA_CSVFILE"
	    [ $TEST -lt 1 ] && sed -i "1s/^/${HEADER_ROW}\n/" "$LCWA_CSVFILE"
	else
	    [ $VERBOSE -gt 0 ] && echo "Appending header row onto empty ${CSVFILE_NAME}."
	    [ $TEST -lt 1 ] && echo "$HEADER_ROW" >"$LCWA_CSVFILE"
	fi
    fi

    [ $VERBOSE -gt 0 ] && echo "Fixing file ownership for ${LCWA_USER}:${LCWA_GROUP} in ${LCWA_LOGDIR}.."
    [ $TEST -lt 1 ] && chown -R "${LCWA_USER}:${LCWA_GROUP}" "$LCWA_LOGDIR"

    [ $VERBOSE -gt 0 ] && echo "Fixing file ownership for ${LCWA_USER}:${LCWA_GROUP} in ${LCWA_DATADIR}.."
    [ $TEST -lt 1 ] && chown -R "${LCWA_USER}:${LCWA_GROUP}" "$LCWA_DATADIR"
fi

if [ $VERBOSE -gt 0 ]; then
    echo "Ready to view logfiles.."
    echo ' '
    pause "Hit any key to continue, or Ctrl-C to quit."
fi

multitail -i "$LCWA_LOGFILE" -i "$LCWA_ERRFILE" -i "$LCWA_CSVFILE"
