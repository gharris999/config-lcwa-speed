#!/bin/bash
# Bash script to change server IDs in python speedtest json config file


SERVER_ID_OLD='18002'
SERVER_ID_NEW='10056'

CONF_DIR='/etc/lcwa-speed'
CONF_FILE="${CONF_DIR}/lcwa-speed.json"

cd "$CONF_DIR"

if [ "$(pwd)" != "$CONF_DIR" ]; then
	echo "ERROR: could not change to ${CONF_DIR} directory! Exiting."
	exit 1
fi

if [ ! -f "$CONF_FILE" ]; then
	echo "ERROR: can not find ${CONF_FILE}! Exiting."
	exit 1
fi

echo "Backing up ${CONF_FILE} to ${CONF_FILE}.bak"
cp -p "$CONF_FILE" "${CONF_FILE}.bak"

echo "BEFORE: Testing json validity of ${CONF_FILE}:"
jq  empty "$CONF_FILE"

if [ $? -gt 0 ]; then
	echo "ERROR: ${CONF_FILE} is not valid json! Exiting."
	exit 1
fi

echo "BEFORE: Current speedtest server IDs in ${CONF_FILE}:"
grep '"serverid":' "$CONF_FILE" | sed -e 's/^[[:space:]]*//' | sort | uniq

SERVER_COUNT_OLD="$(grep -c "$SERVER_ID_OLD" "$CONF_FILE")"
echo "BEFORE: Count of ${SERVER_ID_OLD} server IDs in ${CONF_FILE}: ${SERVER_COUNT_OLD}"
SERVER_COUNT_NEW="$(grep -c "$SERVER_ID_NEW" "$CONF_FILE")"
echo "BEFORE: Count of ${SERVER_ID_NEW} server IDs in ${CONF_FILE}: ${SERVER_COUNT_NEW}"

if [ $SERVER_COUNT_OLD -lt 1 ]; then
	echo "No changes to ${CONF_FILE} need to be made! Exiting."
	exit 1
fi

#################################################################################################
echo "Stream editing ${CONF_FILE} to replace ${SERVER_ID_OLD} with ${SERVER_ID_NEW}.."

sed -i -e "s/${SERVER_ID_OLD}/${SERVER_ID_NEW}/g" "$CONF_FILE"
#################################################################################################

echo " AFTER: Current speedtest server IDs in ${CONF_FILE}:"
grep '"serverid":' "$CONF_FILE" | sed -e 's/^[[:space:]]*//' | sort | uniq

SERVER_COUNT_OLD="$(grep -c "$SERVER_ID_OLD" "$CONF_FILE")"
echo " AFTER: Count of ${SERVER_ID_OLD} server IDs in ${CONF_FILE}: ${SERVER_COUNT_OLD}"
SERVER_COUNT_NEW="$(grep -c "$SERVER_ID_NEW" "$CONF_FILE")"
echo " AFTER: Count of ${SERVER_ID_NEW} server IDs in ${CONF_FILE}: ${SERVER_COUNT_NEW}"

echo " AFTER: Testing json validity of ${CONF_FILE}:"
jq  empty "$CONF_FILE"

if [ $? -gt 0 ]; then
	echo "ERROR: ${CONF_FILE} is not valid json! Exiting."
	exit 1
else 
	echo "${CONF_FILE} is valid json."
fi

echo 'Done!' 
