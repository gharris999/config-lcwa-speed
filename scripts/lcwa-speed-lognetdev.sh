#!/bin/bash

[ "$1" = '--force' ] && FORCE=1 || FORCE=0

# See if there's a ppp interface
IFACE="$(grep ":" /proc/net/dev | awk -F: '{print $1}' | sed s@\ @@g | grep 'ppp')"

# If no ppp interface, then select the 1st listed network interface..
if [ -z "$IFACE" ]; then
	IFACE="$(grep -m1 ":" /proc/net/dev | awk -F: '{print $1}' | sed s@\ @@g)"
fi

LOGFILE='/var/log/lcwa-speed/lcwa-netstats.log'
LOGDIR="$(dirname "$LOGFILE")"

# Create the logdir if necessary..
if [ ! -d "$LOGDIR" ]; then
	mkdir -p "$LOGDIR"
fi

# Create or truncate the logfile and print our column headers..
if [ ! -f "$LOGFILE" ] || [ $FORCE -gt 0 ]; then
	printf "\"date_time\",\"rx_bytes\",\"rx_packets\",\"rx_errs\",\"rx_drop\",\"rx_fifo\",\"rx_frame\",\"rx_compressed\",\"multicast\",\"tx_bytes\",\"tx_packets\",\"tx_errs\",\"tx_drop\",\"tx_fifo\",\"tx_colls\",\"tx_carrier\",\"tx_compressed\"\n" >"$LOGFILE"
fi

# Check to see if our network interface exists..
if [ $(grep \: /proc/net/dev | awk -F: '{print $1}' | grep -c -E "^\s*${IFACE}\$") -lt 1 ]; then
	echo "Error: Device ${IFACE} not found. Should be one of these:" | tee -a "$LOGFILE"
	grep ":" /proc/net/dev | awk -F: '{print $1}' | sed s@\ @@g  | tee -a "$LOGFILE"
	exit 1
fi

DATESTAMP="$(date +"%m-%d-%Y %H:%M:%S")"
NETSTATS=$(grep "${IFACE}:" /proc/net/dev | sed s/.*://);

# Record the netstats in CSV format to the logfile..
printf "\"%s\",\"%u\",\"%u\",\"%u\",\"%u\",\"%u\",\"%u\",\"%u\",\"%u\",\"%u\",\"%u\",\"%u\",\"%u\",\"%u\",\"%u\",\"%u\",\"%u\"\n" "$DATESTAMP" $(echo $NETSTATS | xargs) | tee -a "$LOGFILE"



