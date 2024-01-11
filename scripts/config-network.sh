#!/bin/bash

# Bash script to configure default NIC to a static IP address..

SCRIPT_VERSION=20231026.075039

# Todo: Support creating wifi APs via hostapd
#		https://unix.stackexchange.com/questions/401533/making-hostapd-work-with-systemd-networkd-using-a-bridge
#		https://bbs.archlinux.org/viewtopic.php?id=205334

# 5/12/19 Completely refactored to support networkctl, netplan, etc.

# 7/14/14 Started work to refactor to support wifi networking..

# Refactor to make work for Fedora too..
#	Look at: http://www.server-world.info/en/note?os=Fedora_19&p=initial_conf&f=3
#   Look at: http://danielgibbs.co.uk/2013/01/fedora-18-set-static-ip-address/


SCRIPT="$(realpath -s "$0")"
SCRIPT_NAME="$(basename "$SCRIPT")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
SCRIPT_DESC="Script to automate configuration of network interfaces for dhcp or static IPs."
SCRIPT_EXTRA='[ iface | ipaddr ]'
SCRIPT_LOG="/var/log/config/${SCRIPT_NAME%%.*}.log"

######################################################################################################
# Include the generic service install functions
######################################################################################################

SCRIPT_FUNC='instsrv_functions.sh'
RQD_SCRIPT_FUNC_VER=20201220

# Load the helper functions..
source "${SCRIPT_DIR}/${SCRIPT_FUNC}" >/dev/null 2>&1
if [ $? -gt 0 ]; then
	source "$SCRIPT_FUNC" >/dev/null 2>&1
	if [ $? -gt 0 ]; then
		echo "${SCRIPT_NAME} error: Cannot load script helper functions in ${SCRIPT_FUNC}. Exiting."
		exit 1
	fi
fi

if [[ -z "$INCSCRIPT_VERSION" ]] || [[ "$INCSCRIPT_VERSION" < "$RQD_SCRIPT_FUNC_VER" ]]; then
	# Don't error_exit -- at least try to continue with the utility functions as installed..
	echo "Error: ${INCLUDE_FILE} version is ${INCSCRIPT_VERSION}. Version ${RQD_SCRIPT_FUNC_VER} or newer is required."
fi


DEBUG=0
VERBOSE=0
QUIET=0
FORCE=0
TEST=0
LOG=0

INST_LOGFILE="$SCRIPT_LOG"

# Fix for systemd bug Bug #2036358 systemd wait-online now times out after jammy and lunar upgrade
# See: https://bugs.launchpad.net/ubuntu/+source/systemd/+bug/2036358
SYSTEMD_VER="$(systemd --version | grep 'systemd' | awk '{print $2}')"
if [ $IS_UBUNTU -gt 0 ] && [ $SYSTEMD_VER -eq 249 ]; then
	NETWORKD_TIMEOUT_FIX=1
else
	NETWORKD_TIMEOUT_FIX=0
fi


TESTPING=0
NETCFG_ONLY=0
NETPLAN_TRY=0
UPDATE_YQ=0
CONFIG_NETWORK_OPTS=

# MULTI_NICS=1: Default to detecting primary & secondary NICs
MULTI_NICS=1

NUM_DEVICE=0
ALL_NICS=0
IS_PRIMARY=0
NETDEV0=''
NETDEV1=''
DHCP_ALL=0
IPADDR0=''
IPADDR1=''
PREFER_WIRELESS=1
ESSID=''
WPA_PSK=''
WPA_CONF_FILE='/etc/wpa_supplicant/wpa_supplicant.conf'

FIREWALL_IFACE=
FIREWALL_MINIMAL=0
FIREWALL_PUBLIC=0
# Default to setting up the firewall using the config-firewall-prep-apps.sh script.
FIREWALL_USE_APPS=1
NO_FIREWALL=0
FIX_NETATALK=0
INST_NETWORKMNGR=0

#~ log_msg(){
	#~ error_echo "$@"
	#~ [ $LOG -gt 0 ] && error_log "$@"
#~ }

########################################################################################
# wpa_supplicant_info_save() Save the ESSID & WPA-PSK to
#  /etc/wpa_supplicant/wpa_supplacant.conf file.
#  If wpa-psk is blank, will configure for open wifi network.
########################################################################################
wpa_supplicant_info_save(){
	debug_echo "${FUNCNAME}( $@ )"
	local W_ESSID="$1"
	local W_WPA_PSK="$2"
	local CONF_DIR="$(dirname "$WPA_CONF_FILE")"

	if [ -z "$W_ESSID" ]; then
		log_msg "Error: no wireless ESSID specified.."
		return 1
	fi

	[ $QUIET -lt 1 ] && log_msg "Saving ssid ${W_ESSID} wpa-psk ${W_WPA_PSK}.."

	if [ $TEST -gt 0 ]; then
		return 0
	fi

	if [ ! -d "$CONF_DIR" ]; then
		mkdir -p "$CONF_DIR"
	fi

	# backup the conf file
	if [ -f "$WPA_CONF_FILE" ]; then
		if [ ! -f "${WPA_CONF_FILE}.org" ]; then
			cp -f "$WPA_CONF_FILE" "${WPA_CONF_FILE}.org"
		fi
		cp -f "$WPA_CONF_FILE" "${WPA_CONF_FILE}.bak"
	fi

	# Connecting to an open wifi network??
	if [ -z "$W_WPA_PSK" ]; then
		cat >>"$WPA_CONF_FILE" <<-WNET0;
		network={
			scan_ssid=1
			ssid="$W_ESSID"
			key_mgmt=NONE
			priority=1
		}
		WNET0
	else
		# Create the wpa-psk config file using wpa_passphrase for a psk protected network..
		wpa_passphrase "$W_ESSID" "$W_WPA_PSK" >"$WPA_CONF_FILE"
	fi

	if [ ! -f "$WPA_CONF_FILE" ]; then
		log_msg "Error saving wifi configuration.."
		return 1
	fi

	return 0
}


########################################################################################
# ubuntu_iface_cfg_write()  Write the /etc/network/interfaces file..
#							Not used on systems with netplan.
########################################################################################

ubuntu_iface_cfg_write(){
	debug_echo "${FUNCNAME}( $@ )"
	local LDEV="$1"
	local LADDRESS="$2"
	local LIS_PRIMARY=$3
	local LCONF_FILE='/etc/network/interfaces'

	local LGATEWAY=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3.1/g')
	local LNETWORK=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3.0/g')
	local LHOSTSAL=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3./g')
	local LBRDCAST=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3.255/g')
	# Google's dns servers..
	local LNAMESRV="${GATEWAY0} 8.8.8.8 8.8.4.4"
	local LNETMASK='255.255.255.0'

	if [ $QUIET -lt 1 ]; then

		log_msg "Configuring ${LDEV} for:"

		iface_is_wireless "$LDEV"
		if [ $? -lt 1 ]; then
			if [ ! -z "$ESSID" ]; then
				log_msg "     ESSID: ${ESSID}"
			fi

			if [ ! -z "$WPA_PSK" ]; then
				log_msg "  wpa-psk: ${WPA_PSK}"
			fi
		fi
		log_msg "  Address: ${LADDRESS}"
		log_msg "  Netmask: ${LNETMASK}"
		log_msg "Broadcast: ${LBRDCAST}"
		log_msg "  Network: ${LNETWORK}"

		if [ $IS_PRIMARY -eq 1 ]; then
			# Secondary adapters must not have a gateway or dns-nameservers in /etc/network/interfaces or the network hangs at boot time
			log_msg "  Gateway: ${LGATEWAY}"
			log_msg "NameSrvrs: ${LNAMESRV}"
		fi
	fi

	if [ $TEST -gt 0 ]; then
		return 0
	fi

	# If we're configuring just a single interface, overwrite the interfaces file..
	if [ $MULTI_NICS -lt 1 ]; then

	cat >"$LCONF_FILE" <<-NET0;

	# This file describes the network interfaces available on your system
	# and how to activate them. For more information, see interfaces(5).

	# The loopback network interface
	auto lo
	iface lo inet loopback

	# The primary network interface
	NET0

	else
		# Delete any existing entry for the interface..
		sed -i "/^auto ${LDEV}\$/,/^\$/{/^.*\$/d}" "$LCONF_FILE"
	fi

###################################################################################################
# Add to the interfaces file..

	# Is this a wired device??
	#if [ $(iwconfig "$DEV" 2>&1 | grep -c 'no wireless') -gt 0 ]; then
	if [ ! -e "/sys/class/net/${LDEV}/wireless" ]; then

		[ $VERBOSE -gt 0 ] && log_msg "${LDEV} is a wired device.."

		# Configuring for DHCP?
		if [ "$LADDRESS" == 'dhcp' ]; then
			echo "auto ${LDEV}" >>"$LCONF_FILE"
			echo "iface ${LDEV} inet dhcp" >>"$LCONF_FILE"

		# Static IP config..
		else

			# Wired interface..
			cat >>"$LCONF_FILE" <<-NET1;
			auto ${LDEV}
			iface ${LDEV} inet static
			address ${LADDRESS}
			netmask ${LNETMASK}
			broadcast ${LBRDCAST}
			network ${LNETWORK}
			NET1

			if [ $IS_PRIMARY -gt 0 ]; then
				# Secondary adapters must not have a gateway or dns-nameservers in /etc/network/interfaces or the network hangs at boot time
				cat >>"$LCONF_FILE" <<-NET1A;
				gateway ${LGATEWAY}
				dns-nameservers ${LNAMESRV}
				#dns-search localdomain

				NET1A
			else
				echo '' >>"$LCONF_FILE"
			fi
		fi
	else
		# This is a wireless device..
		[ $VERBOSE -gt 0 ] && log_msg "${LDEV} is a wireless device.."

		if [ -f "$WPA_CONF_FILE" ]; then

			if [ "$LADDRESS" == 'dhcp' ]; then
				echo "auto ${LDEV}" >>"$LCONF_FILE"
				echo "iface ${LDEV} inet dhcp" >>"$LCONF_FILE"
				echo "wpa-conf ${WPA_CONF_FILE}" >>"$LCONF_FILE"

			else

				cat >>"$LCONF_FILE" <<-WNET1;
				auto ${LDEV}
				iface ${LDEV} inet static
				wpa-conf ${WPA_CONF_FILE}
				address ${LADDRESS}
				netmask ${LNETMASK}
				broadcast ${LBRDCAST}
				network ${LNETWORK}
				WNET1

				if [ $IS_PRIMARY -gt 0 ]; then
					cat >>"$LCONF_FILE" <<-WNET1A;
					gateway ${LGATEWAY}
					dns-nameservers ${LNAMESRV}
					#dns-search localdomain

					WNET1A
				else
					echo '' >>"$LCONF_FILE"
				fi
			fi
		else
		# No wpa_supplicant.conf..
			if [ "$ADDRESS" == 'dhcp' ]; then
				echo "auto ${LDEV}" >>"$LCONF_FILE"
				echo "iface ${LDEV} inet dhcp" >>"$LCONF_FILE"
			else
				cat >>"$LCONF_FILE" <<-WNET2;
				auto ${LDEV}
				iface ${LDEV} inet static
				address ${LADDRESS}
				netmask ${LNETMASK}
				broadcast ${LBRDCAST}
				network ${LNETWORK}
				WNET2
				if [ $IS_PRIMARY -gt 0 ]; then
					cat >>"$LCONF_FILE" <<-WNET2A;
					gateway ${LGATEWAY}
					dns-nameservers ${LNAMESRV}
					#dns-search localdomain
					WNET2A
				else
					echo '' >>"$LCONF_FILE"
				fi
			fi
		fi
	fi

	if [ $VERBOSE -gt 0 ]; then
		log_msg "Interfaces File:"
		log_cat "$LCONF_FILE"
	fi

	return 0
}


########################################################################################
# ubuntu_iface_failsafe_write()  Write the backup /etc/network/interfaces file..
#								 Not used on systems with netplan.
########################################################################################
ubuntu_iface_failsafe_write(){
	debug_echo "${FUNCNAME}( $@ )"
	local LDEV=
	local LDEVS=
	local LIS_PRIMARY=
	local LADDRESS=
	local LGATEWAY=
	local LNETWORK=
	local LHOSTSAL=
	local LBRDCAST=
	local LNAMESRV=
	local LNETMASK=
	local LCONF_FILE='/etc/network/interfaces.failsafe'

	LDEV="$(iface_primary_getb)"

	iface_is_wired "$LDEV"
	if [ $? -eq 0 ]; then
		LIS_PRIMARY=1
	else
		LDEVS="$(ifaces_get)"
		for LDEV in $LDEVS
		do
			iface_is_wired "$LDEV"
			if [ $? -eq 0 ]; then
				LIS_PRIMARY=1
				break
			fi
		done
	fi

	# This will be our predictable subnet & address for failsafe..
	LADDRESS="192.168.0.$(default_octet_get)"
	LGATEWAY=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3.1/g')
	LNETWORK=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3.0/g')
	LHOSTSAL=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3./g')
	LBRDCAST=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3.255/g')
	# Google's dns servers..
	LNAMESRV="${LGATEWAY} 8.8.8.8 8.8.4.4"
	LNETMASK='255.255.255.0'

	if [ $QUIET -lt 1 ]; then

		log_msg "Configuring ${LDEV} failsafe for:"

		log_msg "  Address: ${LADDRESS}"
		log_msg "  Netmask: ${LNETMASK}"
		log_msg "Broadcast: ${LBRDCAST}"
		log_msg "  Network: ${LNETWORK}"
		log_msg "  Gateway: ${LGATEWAY}"
		log_msg "NameSrvrs: ${LNAMESRV}"
	fi

	if [ $TEST -gt 0 ]; then
		return 0
	fi


	# Wired interface..
	cat >>"$LCONF_FILE" <<-NET2;
	auto ${LDEV}
	iface ${LDEV} inet static
	address ${LADDRESS}
	netmask ${LNETMASK}
	broadcast ${LBRDCAST}
	network ${LNETWORK}
	gateway ${LGATEWAY}
	dns-nameservers ${LNAMESRV}
	#dns-search localdomain

	NET2

	if [ $VERBOSE -gt 0 ]; then
		log_msg "${LDEV} failsafe interface file: ${LCONF_FILE}"
		log_cat "$LCONF_FILE"
	fi


	return 0
}


###############################################################################
# yq_install()  Install yq by downloading the latest version from
#               https://github.com/mikefarah/yq/releases/latest/
###############################################################################
yq_install(){
	debug_echo "${FUNCNAME}( $@ )"

	#~ if [ "$(uname -m)" = 'x86_64' ]; then
		#~ log_msg "Installing yq from ppa.."
		#~ # snap install yq
		#~ add-apt-repository -y ppa:rmescandon/yq
		#~ apt update
		#~ apt install yq -y
		#~ if [ ! -z "$(which yq)" }; then
			#~ return 0
		#~ fi
	#~ fi

	[ $QUIET -lt 1 ] && log_msg "Finding latest version of yq YAML parser.."
	TMPDIR='/tmp'
	cd "$TMPDIR"
	if [ ! "$TMPDIR" = "$(pwd)" ]; then
		log_msg "Error: cannot cd to ${TMPDIR}."
		exit 1
	fi

	if [ -f "${TMPDIR}/index.html" ]; then
		rm -f "${TMPDIR}/index.html"
	fi

	# YQ 4.x too broken to use thus far!!!
	#~ YQ_INDEX='https://github.com/mikefarah/yq/releases/latest/'
	YQ_INDEX='https://github.com/mikefarah/yq/releases/tag/3.4.1/'

	wget -q "$YQ_INDEX"

	if [ ! -f "${TMPDIR}/index.html" ]; then
		log_msg "Error: cannot get ${YQ_INDEX}."
		exit 1
	fi


	#yq_linux_386
	#yq_linux_amd64

	if [ "$(uname -m)" = 'i686' ]; then
		YQ_BIN='yq_linux_386'
	else
		YQ_BIN='yq_linux_amd64'
	fi

	YQ_BIN_URL="$(cat index.html | grep -e "href=.*${YQ_BIN}" | sed -n -e 's#.*href="\(/.*\)" rel.*$#\1#p')"

	# 2nd try..
	if [ -z "$YQ_BIN_URL" ]; then
		#~ src="https://github.com/mikefarah/yq/releases/expanded_assets/3.4.1"
		YQ_INDEX="$(grep -E 'https://.*assets/3\.4\.1' index.html | sed -n -e 's#^.*src="\(https.*assets/3\.4\.1\).*#\1#p')"
		wget -q  --output-document="${TMPDIR}/index.html" "$YQ_INDEX"
	fi
	
	YQ_BIN_URL="$(cat index.html | grep -e "href=.*${YQ_BIN}" | sed -n -e 's#.*href="\(/.*\)" rel.*$#\1#p')"

	if [ -z "$YQ_BIN_URL" ]; then
		error_echo "Could not form yq download URL.."
		exit 1
	fi
	
	YQ_BIN_URL="https://github.com${YQ_BIN_URL}"

	YQ="$(which yq)"

	if [ ! -z "$YQ" ]; then
		YQ_REMOTE_VER="$(echo $YQ_BIN_URL | sed -n -e 's#^.*/\([0123456789\.]\+\)/.*$#\1#p')"
		YQ_LOCAL_VER="$("$YQ" -V | sed -n -e 's/^.*version \(.*\)$/\1/p')"

		if [[ ! "$YQ_REMOTE_VER" < "$YQ_LOCAL_VER" ]]; then
			$ $QUIET -lt 1 ] && log_msg "${YQ}, version ${YQ_LOCAL_VER} is up to date with remote version ${YQ_REMOTE_VER}."
			return 1
		fi
	fi

	# Download https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64..

	[ $QUIET -lt 1 ] && log_msg "Downloading ${YQ_BIN_URL}.."
	wget -q "$YQ_BIN_URL"

	if [ ! -f "$YQ_BIN" ]; then
		log_msg "Error: could not download ${YQ_BIN}"
		exit 1
	fi

	YQ_INST='/usr/local/bin/yq'

	if [ -f "$YQ_INST" ]; then
		cp -f "$YQ_INST" "${YQ_INST}.old"
	fi

	cp "$YQ_BIN" "$YQ_INST"
	chmod 755 "$YQ_INST"

	[ $QUIET -lt 1 ] && log_msg "${YQ_BIN} installed successfully to ${YQ_INST}.."

	rm "$YQ_BIN"
	return 0
}

#~ function stacktrace {
   #~ local i=0 line file func
    #~ while read line func file; do
        #~ echo -n "[$i] $file:$line $func(): "
        #~ test -f "$file" && sed -n ${line}p "$file" || echo "<unknown>"
        #~ ((i++))
    #~ done < <(while caller $i; do ((i++)); done)
#~ }

###############################################################################
# yq_check() -- Check to see if yq is installed.  Needed for writing yaml files
###############################################################################
yq_check(){
	debug_echo "${FUNCNAME}( $@ )"
	debug_stacktrace
	# See if yq is installed, exit if not..
	local LYQ="$(which yq)"

	if [ -z "$LYQ" ]; then
		log_msg "yq yaml command line editor is not installed."
		yq_install
	elif [ $UPDATE_YQ -gt 0 ]; then
		[ $QUIET -lt 1 ] && log_msg "Checking version of installed yq yaml command line editor."
		yq_install
	fi
}

###############################################################################
# dependency_install() -- Make sure we have the utilites we need:
#                           yq, fping, dhcping
###############################################################################
dependency_install(){
	debug_echo "${FUNCNAME}( $@ )"
	local LUTIL="$@"
	if [ $IS_FEDORA -gt 0 ]; then
		dnf --assumeyes install $LUTIL

	elif [ $IS_DEBIAN -gt 0 ]; then
		apt-install $LUTIL -y
	else
		log_msg "Error: cannot install ${LUTIL}."
		return 1
	fi

}

###############################################################################
# dependencies_check() -- Make sure we have the utilites we need:
#                         yq, fping, dhcping, yamllint
###############################################################################
dependencies_check(){
	debug_echo "${FUNCNAME}( $@ )"
	local LDEPS=
	local LPKG=

	# Get linked interfaces
	local LNETLINKS="$(ifaces_get_links)"

	# Skip dependency checks and installs if no link on any interface..
	if [ -z "$LNETLINKS" ]; then
		return 1
	fi
	
	# If we're installing NetworkManager..
	[ $INST_NETWORKMNGR -gt 0 ] && LDEPS='network-manager '
	[ $INST_NETWORKMNGR -gt 0 ] && [ $IS_GUI -gt 0 ] && LDEPS="${LDEPS}network-manager-gnome "
	
	LDEPS="${LDEPS}fping dhcping yamllint"
	
	for LPKG in $LDEPS
	do
		[ $QUIET -lt 1 ] && log_msg "Checking for dependency ${LPKG}.."
		
		if [ $(dpkg -s "$LPKG" 2>&1 | grep -c 'Status: install ok installed') -gt 0 ] && [ $FORCE -lt 1 ]; then
			[ $VERBOSE -gt 0 ] && log_msg "Package ${LPKG} already installed.."
			continue
		fi
		
		dependency_install "$LPKG" || log_msg "${LPKG} could not be installed."
	done

	if [ $IS_NETPLAN -gt 0 ]; then
		yq_check
	fi

}


# Fix for systemd bug Bug #2036358 systemd wait-online now times out after jammy and lunar upgrade
# See: https://bugs.launchpad.net/ubuntu/+source/systemd/+bug/2036358
networkd_wait_online_fix(){
	debug_echo "${FUNCNAME}( $@ )"
	local LUNIT="${1:-'/lib/systemd/system/systemd-networkd-wait-online.service'}"
	local LUNIT_NAME="$(basename "$LUNIT")"
	local LBIN='/lib/systemd/systemd-networkd-wait-online'
	local LRET=1
	local LNETPLAN_CONF="$(netplan_cfg_find)"
	local LOPTIONAL="$(grep -c 'optional: true' "$LNETPLAN_CONF")"

	if [ $LOPTIONAL -lt 1 ] && [ $FORCE -lt 1 ]; then
		log_msg "${FUNCNAME} error: No interfaces marked as optional in ${LNETPLAN_CONF}. Use --force to override."
		return 1
	fi

	[ $QUIET -lt 1 ] && log_msg "Modifying ${LUNIT_NAME} for shorter timeout. (Fix for systemd Bug #2036358.)"

	if [ ! -f "$LUNIT" ]; then
		log_msg "${FUNCNAME} error: ${LUNIT} not found."
		return 1
	fi

	if [ ! -f "$LBIN" ]; then
		log_msg "${FUNCNAME} error: ${LBIN} not found."
		return 1
	fi

	[ ! -f "${LUNIT}.org" ] && cp -p "$LUNIT" "${LUNIT}.org"

	# ExecStart=/lib/systemd/systemd-networkd-wait-online
	# ExecStart=/lib/systemd/systemd-networkd-wait-online --ignore=lo --timeout=10
	
	[ $TEST -lt 1 ] && sed -i 's#^ExecStart.*$#ExecStart=/lib/systemd/systemd-networkd-wait-online --ignore=lo --timeout=10#' "$LUNIT" || true
	LRET=$?

	if [ $LRET -gt 0 ]; then
		log_msg "${FUNCNAME} error: could not update ${LUNIT}."
	else
		log_msg "${LUNIT_NAME} updated.."
		[ $TEST -lt 1 ] && systemctl daemon-reload && systemctl reset-failed
		if [ $VERBOSE -gt 0 ] || [ $DEBUG -gt 0 ]; then
			cat "$LUNIT"  1>&2
		fi
		[ $LOG -gt 0 ] && cat "$LUNIT" >> "$SCRIPT_LOG"
	fi

	return $LRET

}

networkmanager_enable(){
	debug_echo "${FUNCNAME}( $@ )"

	if [ $IS_NETWORKMNGR -gt 0 ] && [ $FORCE -lt 1 ]; then
		[ $QUIET -lt 1 ] && log_msg "This system is already running NetworkManager."
		[ $QUIET -lt 1 ] && log_msg "Not disabling systemd-networkd.."
	else
		log_msg "Disabling systemd-networkd and enabling NetworkManager.."
		[ $TEST -lt 1 ] && systemctl stop systemd-networkd
		[ $TEST -lt 1 ] && systemctl stop systemd-resolved
		[ $TEST -lt 1 ] && systemctl disable systemd-networkd
		[ $TEST -lt 1 ] && systemctl disable systemd-resolved

		[ $TEST -lt 1 ] && systemctl enable NetworkManager
		[ $TEST -lt 1 ] && systemctl start NetworkManager

		if [ $IS_NETPLAN -gt 0 ]; then
			netplan_cfg_nm_write
			netplan_apply
		fi
	fi

	IS_NETWORKD=$(( systemctl is-enabled --quiet 'systemd-networkd' 2>/dev/null ) && echo 1 || echo 0)
	IS_NETWORKMNGR=$(( systemctl is-enabled --quiet 'NetworkManager' 2>/dev/null ) && echo 1 || echo 0)
}

networkd_enable(){
	debug_echo "${FUNCNAME}( $@ )"

	if [ $IS_NETWORKD -gt 0 ] && [ $FORCE -lt 1 ]; then
		[ $QUIET -lt 1 ] && log_msg "This system is already running systemd-networkd."
		[ $QUIET -lt 1 ] && log_msg "Not disabling NetworkManager.."
	else
		[ $QUIET -lt 1 ] && log_msg "Disabling NetworkManager and enabling systemd-networkd.."
		[ $TEST -lt 1 ] && systemctl stop NetworkManager
		[ $TEST -lt 1 ] && systemctl disable NetworkManager
		
		[ $TEST -lt 1 ] && systemctl enable systemd-networkd
		[ $TEST -lt 1 ] && systemctl enable systemd-resolved

		[ $TEST -lt 1 ] && systemctl start systemd-networkd
		[ $TEST -lt 1 ] && systemctl start systemd-resolved
	fi
	
	IS_NETWORKD=$(( systemctl is-enabled --quiet 'systemd-networkd' 2>/dev/null ) && echo 1 || echo 0)
	IS_NETWORKMNGR=$(( systemctl is-enabled --quiet 'NetworkManager' 2>/dev/null ) && echo 1 || echo 0)
	
}

###############################################################################
# networkmanager_connection_get( [ iface ] ) -- Get the NetworkManager
#  connection name for the interface, or primary interface if iface == null
###############################################################################
networkmanager_connection_get(){
	debug_echo "${FUNCNAME}( $@ )"
	local LIFACE="$1"
	local LIS_WIFI=0
	local LCONNECTION=
	local LRET=1

	if [ -z "$LIFACE" ]; then
		LIFACE="$(iface_primary_getb)"
	else
		# Validate the interface name
		if ! iface_is_valid "$LIFACE"; then
			log_msg "${FUNCNAME}() error: ${LIFACE} is not a valid network interface."
			return 1
		fi
	fi
	
	iface_is_wireless "$LIFACE" && LIS_WIFI=1
	
	[ $DEBUG -gt 0 ] && log_msg "Searching for NetworkManager Connection name for interface ${LIFACE}"

	LCONNECTION="$(nmcli --get-values=DEVICE,NAME connection | grep -m1 -E "^${LIFACE}:" | sed -n -e 's/^.*:\(.*\)$/\1/p')"

	if [ ! -z "$LCONNECTION" ]; then
		LRET=0
		[ $DEBUG -gt 0 ] && log_msg "Found NetworkManager Connection ${LCONNECTION} for interface ${LIFACE}"
		echo "$LCONNECTION"
	else
		LRET=1
		[ $DEBUG -gt 0 ] && log_msg "${FUNCNAME}() error: cound not find NetworkManager Connection for interface ${LIFACE}"
	fi

	return $LRET
}

###############################################################################
# networkmanager_connection_get_next( [ iface ] ) -- constructs a new network
#  connection name
###############################################################################
networkmanager_connection_get_next(){
	debug_echo "${FUNCNAME}( $@ )"
	local LIFACE="$1"
	local LIS_WIFI=0
	local LCONNECTION=
	local LNUM=0
	local LRET=1
	[ -z "$LIFACE" ] && LIFACE="$(iface_primary_getb)"

	# Validate the interface name
	if ! iface_is_valid "$LIFACE"; then
		log_msg "${FUNCNAME}() error: ${LIFACE} is not a valid network interface."
		return 1
	fi
	
	iface_is_wireless "$LIFACE" && LIS_WIFI=1

	LNUM="$(nmcli --get-values=NAME,DEVICE,UUID connection | grep ":${LIFACE}:" | wc -l)"

	while true; do
		((LNUM++))
		
		if [ $LIS_WIFI -gt 0 ]; then
			LCONNECTION="Auto wifi ${LNUM}"
		else
			LCONNECTION="Wired connection ${LNUM}"
		fi
		
		networkmanager_connection_exists "$LCONNECTION" || break
		
		[ $LNUM -gt 9 ] && break
		
	done

	if [ -z "$LCONNECTION" ]; then
		LRET=1
		log_msg "${FUNCNAME}() error: could not construct new connection name for interface ${LIFACE}"
	else
		LRET=0
		[ $DEBUG -gt 0 ] && log_msg "New generated connection name for interface ${LIFACE}: ${LCONNECTION}"
		echo "$LCONNECTION"
	fi

	return $LRET
}

###############################################################################
# networkmanager_connection_exists( 'connection_name' ) -- returns 0 if the
#   connection_name exists.
###############################################################################
networkmanager_connection_exists(){
	debug_echo "${FUNCNAME}( $@ )"
	local LCONNECTION="$1"
	if [ $(nmcli --get-values=DEVICE,NAME,UUID connection show | grep -c ":${LCONNECTION}:") -gt 0 ]; then
		debug_echo "${FUNCNAME}( $@ ); connection ${LCONNECTION} exists."
		return 0
	else
		debug_echo "${FUNCNAME}( $@ ); connection ${LCONNECTION} does NOT exist."
		return 1
	fi
}

###############################################################################
# networkmanager_connection_is_active( 'connection_name' ) -- returns 0 if the
#   connection_name is active, i.e. linked.
###############################################################################
networkmanager_connection_is_active(){
	debug_echo "${FUNCNAME}( $@ )"
	local LCONNECTION="$1"
	
	#~ eno1:Wired connection 1:e8e61688-0439-33b9-afd7-30feebffcc6b
	#~ wlp0s20f3:Auto rockhouse:c9ce3a69-982d-4d6a-8b5b-cb91c08b697b	
	
	if [ $(nmcli --get-values=DEVICE,NAME,UUID connection show --active | grep -c ":${LCONNECTION}:") -gt 0 ]; then
		debug_echo "${FUNCNAME}( $@ ); connection ${LCONNECTION} is active."
		return 0
	else
		debug_echo "${FUNCNAME}( $@ ); connection ${LCONNECTION} is NOT active."
		return 1
	fi
}

###############################################################################
# networkmanager_connection_add( 'connection_name', 'iface', 'ipaddr' )
#   Creates a new connection and brings it up.  Returns 0 if successfull, 1 if not.
###############################################################################
networkmanager_connection_add(){
	debug_echo "${FUNCNAME}( $@ )"
	local LCONNECTION="$1"
	local LIFACE="$2"
	local LIPADDR="${3:-dhcp}"
	local LSSID="$4"
	local LPSK="$5"
	local LTYPE=
	local LGATEWAY=
	local LDNS=
	local LIS_WIFI=
	local LIS_ETHERNET=
	local LIS_DHCP=
	local LRET=1
	local LLOGFILE=
	
	[ $LOG -gt 0 ] && LLOGFILE="$SCRIPT_LOG" || LLOGFILE='/dev/null'

	# Validate the interface name
	if ! iface_is_valid "$LIFACE"; then
		log_msg "${FUNCNAME}() error: ${LIFACE} is not a valid network interface."
		return 1
	fi
	
	if iface_is_wireless "$LIFACE"; then
		LIS_WIFI=1
		LIS_ETHERNET=0
		LTYPE='wifi'
	else
		LIS_WIFI=0
		LIS_ETHERNET=1
		LTYPE='ethernet'
	fi
	
	debug_echo ' '
	debug_echo "${FUNCNAME}( $@ ) here at ${LINENO}"
	debug_echo "      LIFACE == ${LIFACE}"
	debug_echo "     LIPADDR == ${LIPADDR}"
	#~ debug_echo "             == dhcp"

	if [ "$LIPADDR" = "dhcp" ]; then
		LIS_DHCP=1
	else
		LIS_DHCP=0
		LGATEWAY=$(echo "$LIPADDR" | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3.1/g')
		LDNS="$LGATEWAY"
	fi
	
	debug_echo ' '
	debug_echo "${FUNCNAME}( $@ ) here at ${LINENO}"
	debug_echo "    LIS_WIFI == ${LIS_WIFI}"
	if [ $LIS_WIFI -gt 0 ]; then
		debug_echo "       LSSID == ${LSSID}"
		debug_echo "        LPSK == ${LPSK}"
	fi
	debug_echo "LIS_ETHERNET == ${LIS_ETHERNET}"
	debug_echo "    LIS_DHCP == ${LIS_DHCP}"
	debug_echo ' '
	
	if [ $LIS_WIFI -gt 0 ]; then
		if [ -z "$LSSID" ]; then
			log_msg "${FUNCNAME}() error: attempting add a wifi connection but SSID not specified."
			return 1
		fi
		
		[ $QUIET -lt 1 ] && log_msg "Creating ${LTYPE} connection ${LCONNECTION} for ${LIFACE}, ${LIPADDR} ${LSSID} ${LPSK}"
		if iface_is_linked "$LIFACE"; then
			[ $QUIET -lt 1 ] && log_msg "Bringing ${LIFACE} link down.."
			[ $TEST -lt 1 ] && ip link set dev "$LIFACE" down
		fi
	
		if [ $LIS_DHCP -gt 0 ]; then
			[ $TEST -lt 1 ] && nmcli connection add con-name "$LCONNECTION" \
				type "$LTYPE" \
				ifname "$LIFACE" \
				autoconnect yes \
				save yes \
				ssid "$LSSID" \
				wifi-sec.key-mgmt wpa-psk \
				wifi-sec.psk "$LPSK" \
				ipv4.method auto 2>&1 | tee -a "$LLOGFILE"
		else
			[ $TEST -lt 1 ] && nmcli connection add con-name "$LCONNECTION" \
				type "$LTYPE" \
				ifname "$LIFACE" \
				autoconnect yes \
				save yes \
				ssid "$LSSID" \
				wifi-sec.key-mgmt wpa-psk \
				wifi-sec.psk "$LPSK" \
				ipv4.method manual \
				ipv4.address "${LIPADDR}/24" \
				ipv4.dns "$LDNS" \
				ipv4.gateway "$LGATEWAY" 2>&1 | tee -a "$LLOGFILE"
		fi
		
	elif [ $LIS_ETHERNET -gt 0 ]; then

		[ $QUIET -lt 1 ] && log_msg "Creating ${LTYPE} connection ${LCONNECTION} for ${LIFACE}, ${LIPADDR}"
		if iface_is_linked "$LIFACE"; then
			[ $QUIET -lt 1 ] && log_msg "Bringing ${LIFACE} link down.."
			[ $TEST -lt 1 ] && ip link set dev "$LIFACE" down
		fi

		if [ $LIS_DHCP -gt 0 ]; then
			[ $TEST -lt 1 ] && nmcli connection add con-name "$LCONNECTION" \
				type "$LTYPE" \
				ifname "$LIFACE" \
				autoconnect yes \
				save yes \
				ipv4.method auto 2>&1 | tee -a "$LLOGFILE"
		else
			[ $TEST -lt 1 ] && nmcli connection add con-name "$LCONNECTION" \
				type "$LTYPE" \
				ifname "$LIFACE" \
				autoconnect yes \
				save yes \
				ipv4.method manual \
				ipv4.address "${LIPADDR}/24" \
				ipv4.dns "$LDNS" \
				ipv4.gateway "$LGATEWAY" 2>&1 | tee -a "$LLOGFILE"
		fi
		
	fi
	
	nmcli connection up "$LCONNECTION"  2>&1 | tee -a "$LLOGFILE"
	LRET=$?
	
	if [ $LRET -gt 0 ]; then
		log_msg "${FUNCNAME}() error: Could not add ${LTYPE} connection ${LCONNECTION} on ${LIFACE}."
	else
		[ $QUIET -lt 1 ] && log_msg "Connection ${LCONNECTION}, type ${LTYPE} created successsfully."
		if [ $DEBUG -gt 0 ]; then
			nmcli -o -s connection show "$LCONNECTION"
			error_echo ' '
		fi
	fi

	return $LRET
}

networkmanager_connection_modify(){
	debug_echo "${FUNCNAME}( $@ )"
	local LCONNECTION="$1"
	local LIFACE="$2"
	local LIPADDR="${3:-dhcp}"
	local LTYPE=
	local LSSID="$4"
	local LPSK="$5"
	local LGATEWAY=
	local LDNS=
	local LIS_WIFI=
	local LIS_ETHERNET=
	local LIS_DHCP=
	local LRET=1
	local LLOGFILE=
	
	[ $LOG -gt 0 ] && LLOGFILE="$SCRIPT_LOG" || LLOGFILE='/dev/null'

	# Verify that the connection exists
	if ! networkmanager_connection_exists "$LCONNECTION"; then
		log_msg "${FUNCNAME}() error: connection ${LCONNECTION} does not exist."
		return 1
	fi

	# Validate the interface name
	if ! iface_is_valid "$LIFACE"; then
		log_msg "${FUNCNAME}() error: ${LIFACE} is not a valid network interface."
		return 1
	fi
	
	if iface_is_wireless "$LIFACE"; then
		LIS_WIFI=1
		LIS_ETHERNET=0
		LTYPE='wifi'
	else
		LIS_WIFI=0
		LIS_ETHERNET=1
		LTYPE='ethernet'
	fi
	
	if [ "$LIPADDR" = "dhcp" ]; then
		LIS_DHCP=1
	else
		LIS_DHCP=0
		LGATEWAY=$(echo "$LIPADDR" | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3.1/g')
		LDNS="$LGATEWAY"
	fi
	
	debug_echo ' '
	debug_echo "${FUNCNAME}( $@ ) here at ${LINENO}"
	debug_echo "    LIS_WIFI == ${LIS_WIFI}"
	debug_echo "LIS_ETHERNET == ${LIS_ETHERNET}"
	debug_echo "    LIS_DHCP == ${LIS_DHCP}"
	debug_echo ' '
	
	if networkmanager_connection_is_active "$LCONNECTION"; then
		[ $QUIET -lt 1 ] && log_msg "Bringing down connection ${LCONNECTION}.."
		[ $TEST -lt 1 ] && nmcli connection down "$LCONNECTION"  2>&1 | tee -a "$LLOGFILE"
	fi
	
	# If new ipaddr is dhcp, remove any old static ip addresses..
	if [ $LIS_DHCP -gt 0 ]; then
		[ $TEST -lt 1 ] && nmcli connection modify "$LCONNECTION" remove ipv4 2>&1 | tee -a "$LLOGFILE"
		[ $TEST -lt 1 ] && nmcli connection modify "$LCONNECTION" remove ipv6 2>&1 | tee -a "$LLOGFILE"
	fi

	if [ $LIS_WIFI -gt 0 ]; then

		if [ -z "$LSSID" ]; then
			log_msg "${FUNCNAME}() error: attempting add a wifi connection but SSID not specified."
			return 1
		fi
		
		[ $QUIET -lt 1 ] && log_msg "Modifying ${LTYPE} connection ${LCONNECTION} for ${LIFACE}, ${LIPADDR} ${LSSID} ${LPSK}"

		if iface_is_linked "$LIFACE"; then
			[ $QUIET -lt 1 ] && log_msg "Bringing ${LIFACE} link down.."
			[ $TEST -lt 1 ] && ip link set dev "$LIFACE" down
		fi
	
	
		if [ $LIS_DHCP -gt 0 ]; then
			[ $TEST -lt 1 ] && nmcli connection modify "$LCONNECTION" \
				ifname "$LIFACE" \
				autoconnect yes \
				ssid "$LSSID" \
				wifi-sec.key-mgmt wpa-psk \
				wifi-sec.psk "$LPSK" \
				ipv4.method auto 2>&1 | tee -a "$LLOGFILE"
		else
			[ $TEST -lt 1 ] && nmcli connection modify "$LCONNECTION" \
				ifname "$LIFACE" \
				autoconnect yes \
				ssid "$LSSID" \
				wifi-sec.key-mgmt wpa-psk \
				wifi-sec.psk "$LPSK" \
				ipv4.method manual \
				ipv4.address "${LIPADDR}/24" \
				ipv4.dns "$LDNS" \
				ipv4.gateway "$LGATEWAY" 2>&1 | tee -a "$LLOGFILE"
		fi
		
	elif [ $LIS_ETHERNET -gt 0 ]; then
	
		[ $QUIET -lt 1 ] && log_msg "Modifying ${LTYPE} connection ${LCONNECTION} for ${LIFACE}, ${LIPADDR}"

		if iface_is_linked "$LIFACE"; then
			[ $QUIET -lt 1 ] && log_msg "Bringing ${LIFACE} link down.."
			[ $TEST -lt 1 ] && ip link set dev "$LIFACE" down
		fi
	
		debug_echo "${FUNCNAME}() here at ${LINENO}"

		if [ $LIS_DHCP -gt 0 ]; then
			[ $TEST -lt 1 ] && nmcli connection modify "$LCONNECTION" \
				ifname "$LIFACE" \
				autoconnect yes \
				ipv4.method auto 2>&1 | tee -a "$LLOGFILE"
		else
			[ $TEST -lt 1 ] && nmcli connection modify "$LCONNECTION" \
				ifname "$LIFACE" \
				autoconnect yes \
				ipv4.method manual \
				ipv4.address "${LIPADDR}/24" \
				ipv4.dns "$LDNS" \
				ipv4.gateway "$LGATEWAY" 2>&1 | tee -a "$LLOGFILE"
		fi
		
		debug_echo "${FUNCNAME}() here at ${LINENO}"
 
	fi
	
	nmcli connection up "$LCONNECTION" >/dev/null
	LRET=$?
	
	if [ $LRET -gt 0 ]; then
		log_msg "${FUNCNAME}() error: Could not modify ${LTYPE} connection ${LCONNECTION}."
	else
		if [ $DEBUG -gt 0 ]; then
			nmcli -o -s connection show "$LCONNECTION"
			error_echo ' '
		fi
		[ $QUIET -lt 1 ] && log_msg "Connection ${LCONNECTION}, type ${LTYPE} modified successsfully."
	fi

	return $LRET
}

###############################################################################
# networkmanager_connection_remove( 'connection_name|iface_name')
#   Deletes an existing connection and brings it up.  Returns 0 if successfull, 1 if not.
###############################################################################
networkmanager_connection_remove(){
	debug_echo "${FUNCNAME}( $@ )"
	local LCONNECTION="$1"
	local LIFACE=
	local LRET=1
	
	if ! networkmanager_connection_exists "$LCONNECTION"; then
		LIFACE="$LCONNECTION"
		if iface_is_valid "$LIFACE"; then
			LCONNECTION="$(networkmanager_connection_get "$LIFACE")"
			LRET=$?
		fi
		
		if [ $LRET -gt 0 ]; then
			log_msg "Cannot remove non-existant connection ${LCONNECTION}.."
			return 1
		fi
	fi
	
	[ $QUIET -lt 1 ] && log_msg "Removing connection ${LCONNECTION}.."
	nmcli connection delete "$LCONNECTION"
	LRET=$?
	
	if [ $LRET -gt 0 ]; then
		log_msg "Could not remove connection ${LCONNECTION}.."
		return 1
	fi
}

###############################################################################################
# networkmanager_iface_set( 'iface', 'ipaddr|dhcp', [ 'ssid' ], [ 'wpa-psk' ])
#   Creates or modifies a ethernet or wifi connection on the network interface.
###############################################################################################
networkmanager_iface_set(){
	debug_echo "${FUNCNAME}( $@ )"
	local LIFACE="$1"
	local LIPADDR="${2:-dhcp}"
	local LSSID="$3"
	local LPSK="$4"
	local LIS_WIFI=0
	local LCONNECTION="$(networkmanager_connection_get "$LIFACE")"
	local LRET=1
	
	# Validate the interface name
	if ! iface_is_valid "$LIFACE"; then
		log_msg "${FUNCNAME}() error: ${LIFACE} is not a valid network interface."
		return 1
	fi
	
	iface_is_wireless "$LIFACE" && LIS_WIFI=1
	
	# No existing connection, add one
	if [ -z "$LCONNECTION" ]; then
		[ $QUIET -lt 1 ] && log_msg "Constructing new NetworkManager connection for ${LIFACE}.."
		LCONNECTION="$(networkmanager_connection_get_next "$LIFACE")"
		LRET=$?
		[ $LIS_WIFI ] && [ ! -z "$LSSID" ] && LCONNECTION="$(echo "$LCONNECTION" | sed -e "s/wifi/${LSSID}/")"
		if [ $LRET -lt 1 ]; then
			networkmanager_connection_add "$LCONNECTION" "$LIFACE" "$LIPADDR" "$LSSID" "$LPSK"
			LRET=$?
		fi
	else
		# Modify an existing connection
		[ $QUIET -lt 1 ] && log_msg "Modifying NetworkManager connection ${LCONNECTION} for ${LIFACE}.."
		networkmanager_connection_modify "$LCONNECTION" "$LIFACE" "$LIPADDR" "$LSSID" "$LPSK"
		LRET=$?
	fi
	
	if [ $LRET -lt 1 ]; then
		[ $QUIET -lt 1 ] && log_msg "Connection ${LCONNECTION} established on interface ${LIFACE}."
	else
		log_msg "${FUNCNAME}() error: Connection ${LCONNECTION} could not established on interface ${LIFACE}."
	fi
	
	return $LRET
}

########################################################################################
# netplan_cfg_find()  Find the /etc/netplan/0x-netcfg.yaml file
########################################################################################
netplan_cfg_find(){
	debug_echo "${FUNCNAME} $@"
	local LEXT="$1"
	local LCFG_DIR="$2"
	local LCONF_FILE=
	local LDEFCONF_FILE='/etc/netplan/01-netcfg.yaml'

	if [ -z "$LEXT" ]; then
		LEXT='yaml'
	fi

	if [ -z "$LCFG_DIR" ]; then
		LCFG_DIR='/etc/netplan'
	fi

	#~ LCONF_FILE=$(find /etc/netplan -maxdepth 3 -type f -name "*.${LEXT}" | sort | grep -m1 '.yaml')
	LCONF_FILE=$(find /etc/netplan -maxdepth 1 -type f -name "*.${LEXT}" | sort | grep -m1 ".${LEXT}")

	#~ if [ -z "$LCONF_FILE" ]; then
		#~ log_msg "Cannot find any file *.${LEXT}"
		#~ return 1
	#~ fi

	if [ -z "$LCONF_FILE" ]; then
		[ $QUIET -lt 1 ] && log_msg "${FUNCNAME}: Could not find a netplan config yaml file."
		LCONF_FILE="$LDEFCONF_FILE"
		[ $QUIET -lt 1 ] && log_msg "${FUNCNAME}: Creating default ${LCONF_FILE} netplan config yaml file."
		touch "$LCONF_FILE"
	else
		# Rename the existing yaml file if not matching our default name..
		if [ "$LCONF_FILE" != "$LDEFCONF_FILE" ]; then
			mv -f "$LCONF_FILE" "$LDEFCONF_FILE"
			LCONF_FILE="$LDEFCONF_FILE"
		fi

		if [ ! -f "${LCONF_FILE}.org" ]; then
			cp -p "$LCONF_FILE" "${LCONF_FILE}.org"
		fi

		cp -p "$LCONF_FILE" "${LCONF_FILE}.bak"

	fi

	echo "$LCONF_FILE"

	return 0
}

######################################################################################################
# netplan_nm_yaml_write() -- writes a default NetworkManager netplan config yaml file
######################################################################################################

netplan_cfg_nm_write(){
	local LNETPLAN_CONF="$(netplan_cfg_find)"
	local LHEADER=
	
	# See if yq is installed, exit if not..
	yq_check

	local YQ="$(which yq)"
	
	[ $QUIET -lt 1 ] && log_msg "Writing NetworkManager netplan config yaml file ${LNETPLAN_CONF}"
	
	if [ -f "$LNETPLAN_CONF" ]; then
		[ ! -f "${LNETPLAN_CONF}.org" ] cp -p "$LNETPLAN_CONF" "${LNETPLAN_CONF}.org"
		cp -p "$LNETPLAN_CONF" "${LNETPLAN_CONF}.bak"
	fi
	
	$YQ n 'network.version' '2' >"$LNETPLAN_CONF"
	$YQ w -i "$LNETPLAN_CONF" 'network.renderer' 'NetworkManager'

	LHEADER="--- # $(date) -- This is the netplan config written by ${SCRIPT_NAME}"
	sed -i "1s/^/${LHEADER}\n/" "$LNETPLAN_CONF"
	
	if [ -f "$LNETPLAN_CONF" ]; then
		[ ! -f "${LNETPLAN_CONF}.org" ] cp -p "$LNETPLAN_CONF" "${LNETPLAN_CONF}.org"
		cp -p "$LNETPLAN_CONF" "${LNETPLAN_CONF}.bak"
	fi
	
	[ $TEST -lt 1 ] && cat >"$LNETPLAN_CONF" <<-EOF_NETPLANCFG0;
	# $(date) -- This is the netplan config written by ${SCRIPT_DIR}/${SCRIPT_NAME}
	network:
	  version: 2
	  renderer: NetworkManager
	EOF_NETPLANCFG0
	
	
}



########################################################################################
# netplan_cfg_write()  Write the /etc/netplan/0x-netcfg.yaml file using yq
########################################################################################
netplan_cfg_write(){
	debug_echo "${FUNCNAME} $@"
	local LDEV="$1"
	local LADDRESS="$2"
	local LMACADDR=
	local LIS_DHCP=0
	local LIS_PRIMARY=$3
	local LROUTE=
	local LGATEWAY=
	local LNAMESRV0=
	local LNAMESRV1=
	local LCONF_FILE=
	#~ local LDEFCONF_FILE='/etc/netplan/01-netcfg.yaml'
	local bRet=0
	local LNETPLAN_USE_ROUTES="$(netplan info | grep -c default-routes)"

	# See if yq is installed, exit if not..
	yq_check

	local YQ="$(which yq)"

	if [ -z "$YQ" ]; then
		log_msg "Error: Could not install yq.  ${SCRIPT_NAME} must exit."
		exit 1
	fi

	#########################################################################
	#########################################################################
	#########################################################################
	#########################################################################
	# Work out differences between version 3 & version 4!!!
	local YQ_VER=$($YQ -V | sed -r 's/^([^.]+).*$/\1/; s/^[^0-9]*([0-9]+).*$/\1/')
	#########################################################################
	#########################################################################
	#########################################################################
	#########################################################################


	# Search for our network yaml file 1 level deep
	LCONF_FILE="$(netplan_cfg_find)"

	debug_echo "LCONF_FILE == ${LCONF_FILE}"

	# use yq to modify the yaml file. See: http://mikefarah.github.io/yq/create/  & https://github.com/mikefarah/yq/releases/latest
	#   Documentation: http://mikefarah.github.io/yq/read/

	# Create the yaml file if it doesn't exist..i.e. don't trash the file if this is our 2nd pass!!
	if [ "$LDEV" == 'CLEAR_ALL' ]; then
		$YQ n 'network.version' '2' >"$LCONF_FILE"
		return 0
	elif [ ! -f "$LCONF_FILE" ]; then
		$YQ n 'network.version' '2' >"$LCONF_FILE"
	else
		$YQ w -i "$LCONF_FILE" 'network.version' '2'
	fi

	# networkd is the default, so doesn't need to be explicitly involked.  Really??
	$YQ w -i "$LCONF_FILE" 'network.renderer' 'networkd'

	[ "$LADDRESS" == 'dhcp' ] && LIS_DHCP=1

	if [ $LIS_DHCP -lt 1 ]; then
		LGATEWAY=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3.1/g')
		# Google's dns servers..
		LNAMESRV0='8.8.8.8'
		LNAMESRV1='8.8.4.4'
	fi

	# Display the details of the interface we're configuring..
	if [ $QUIET -lt 1 ]; then

		log_msg "Configuring ${LDEV} in ${LCONF_FILE} for:"

		iface_is_wireless "$LDEV"
		if [ $? -lt 1 ]; then
			if [ ! -z "$ESSID" ]; then
				log_msg "    ESSID: ${ESSID}"
				log_msg "  wpa-psk: ${WPA_PSK}"
			fi
		fi
		log_msg "  Address: ${LADDRESS}"
		log_msg "  Gateway: ${LGATEWAY}"
		log_msg "NameSrvrs: ${LNAMESRV0},${LNAMESRV1}"
	fi

	if [ $TEST -gt 0 ]; then
		return 0
	fi

	# Default Ubuntu 20.04 netplan file: 00-installer-config.yaml

	## This is the network config written by 'subiquity'
	#network:
	#  ethernets:
	#    enp4s0:
	#      dhcp4: true
	#  version: 2
	
	if [ $LNETPLAN_USE_ROUTES -gt 0 ]; then
		if [ $NUM_DEVICE -gt 0 ]; then
			LROUTE="$(echo "$LADDRESS" | sed -n 's/\(.\{1,3\}\)\.\(.\{1,3\}\)\.\(.\{1,3\}\)\..*/\1\.\2\.\3\.0\/24/p')"
		else
			LROUTE='default'
		fi
	fi
	

	# Is this a wired device??
	if [ ! -e "/sys/class/net/${LDEV}/wireless" ]; then

		# Delete any existing wired entry for THIS interface..
		$YQ d -i "$LCONF_FILE" "network.ethernets.${LDEV}"

		#~ if [ $LIS_PRIMARY -lt 1 ]; then
			# Make any 2ndary wired adapter optional so boot doesn't hang if it's not linked..
			$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.optional" 'true'
		#~ fi

		# dhcp
		if [ $LIS_DHCP -gt 0 ]; then
			$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.dhcp4" 'true'
			$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.dhcp6" 'true'
		# static
		else
			$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.dhcp4" 'no'
			$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.dhcp6" 'no'
			$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.addresses[+]" "${LADDRESS}/24"
			if [ $LNETPLAN_USE_ROUTES -gt 0 ]; then
				$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.routes[+].to." "$LROUTE"
				$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.routes[0].via" "$LGATEWAY"
				$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.nameservers.addresses[+]" "$LNAMESRV0"
				$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.nameservers.addresses[+]" "$LNAMESRV1"
			elif [ $LIS_PRIMARY -gt 0 ]; then
				# Secondary adapters must not have a gateway or dns-nameservers or the network won't resolve internet addresses..
				$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.gateway4" "$LGATEWAY"
				$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.nameservers.addresses[+]" "$LNAMESRV0"
				$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.nameservers.addresses[+]" "$LNAMESRV1"
			fi
		fi

		# Enable wake-on-lan for this interface
		LMACADDR="$(iface_hwaddress_get "$LDEV")"
		if [ ! -z "$LMACADDR" ]; then
			$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.match.macaddress" "${LMACADDR}"
			$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.wakeonlan" 'true'
		fi

	else	# Wireless !!
		# Delete any existing wifi entry for the interface..
		$YQ d -i "$LCONF_FILE" "network.wifis.${LDEV}"
		
		# Give up if there's no SSID..
		if [ ! -z "$ESSID" ] || [ $FORCE -gt 0 ]; then

			# Make the wifi interface optional...i.e. don't hang at boot time if not present..
			$YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.optional" 'true'

			if [ "$LADDRESS" == 'dhcp' ]; then
				$YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.dhcp4" 'true'
			else

				$YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.dhcp4" 'no'
				$YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.dhcp6" 'no'
				$YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.addresses[+]" "${LADDRESS}/24"

				if [ $LNETPLAN_USE_ROUTES -gt 0 ]; then
					$YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.routes[+].to." "$LROUTE"
					$YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.routes[0].via" "$LGATEWAY"
					$YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.nameservers.addresses[+]" "$LNAMESRV0"
					$YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.nameservers.addresses[+]" "$LNAMESRV1"
				elif [ $LIS_PRIMARY -gt 0 ]; then
					# Secondary adapters must not have a gateway or dns-nameservers or the network won't resolve internet addresses..
					$YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.gateway4" "$LGATEWAY"
					$YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.nameservers.addresses[+]" "$LNAMESRV0"
					$YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.nameservers.addresses[+]" "$LNAMESRV1"
				fi
			fi

			if [ -z "$ESSID" ]; then
				# Generate a fake random SSID
				ESSID="$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)"
				#~ ESSID='SOMESSID'
			fi

			if [ ! -z "$WPA_PSK" ]; then
				log_msg "WPA_PSK == ${WPA_PSK}"
				#~ $YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.access-points.${ESSID}.password" "\"${WPA_PSK}\""
				# This issue is fixed in yq version 3.2.1
				$YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.access-points.${ESSID}.password" "${WPA_PSK}"
				# Fixup yq's mangling of numeric password data..
				#~ sed -i -e "s/password:.*/password: ${WPA_PSK}/" "$LCONF_FILE"
			else
				$YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.access-points.${ESSID}" '{}'
			fi
		else
			[ $QUIET -lt 1 ] && log_msg "Skipping creating a netplan wifi definition for ${LDEV} since no SSID is specified."
		fi
	fi

	# Make any required fixes to the yaml file

	if [ $(grep -c "'{}'" "$LCONF_FILE") -gt 0 ]; then
		log_msg "Fixing up ${LCONF_FILE}.."
		sed -i -e 's/\x27{}\x27/{}/g' "$LCONF_FILE"
	fi

	# Insert our comment into the yaml file..
	# This is the network config written by 'subiquity'

	local LCOMMENT="# $(date): This is the network config written by '${SCRIPT_NAME}'"

	# Delete any existing config ownership comments..
	sed -i -e '/^# This is the network config written by/d' "$LCONF_FILE"

	# Insert our comment at the head of the file..
	sed -i "1 i\\${LCOMMENT}" "$LCONF_FILE"

	# This is just a backup file, showing the config we're trying..
	cp -p "$LCONF_FILE" "${LCONF_FILE}.try"

	# Validate each pass while constructing the yaml
	$YQ read "$LCONF_FILE" >/dev/null 2>&1
	bRet=$?

	if [ $bRet -gt 0 ] || [ $VERBOSE -gt 0 ]; then
		log_msg '============================================================='
		log_msg "yq read of ${LCONF_FILE} returned ${bRet}"
		log_msg "Netplan File: ${LCONF_FILE}"
		$YQ read --verbose "$LCONF_FILE"
		log_msg '============================================================='
		yamllint -f parsable "$LCONF_FILE"
	fi

	chmod 600 "$LCONF_FILE"
	
	((NUM_DEVICE++))

	return $bRet

}

########################################################################################
# netplan_failsafe_write()  Write the /etc/netplan/0x-netcfg.yaml.failsafe file using yq
########################################################################################
netplan_failsafe_write(){
	debug_echo "${FUNCNAME}( $@ )"
	local LDEVS=
	local LDEV=
	local LADDRESS=
	local LIS_PRIMARY=0
	local LGATEWAY=
	local LNAMESRV0=
	local LNAMESRV1=
	local LCONF_FILE=

	# See if yq is installed, exit if not..
	yq_check

	local YQ="$(which yq)"

	if [ -z "$YQ" ]; then
		log_msg "Error: Could not install yq.  ${SCRIPT_NAME} must exit."
		exit 1
	fi

	#########################################################################
	#########################################################################
	#########################################################################
	#########################################################################
	# Work out differences between version 3 & version 4!!!
	local YQ_VER=$($YQ -V | sed -r 's/^([^.]+).*$/\1/; s/^[^0-9]*([0-9]+).*$/\1/')
	#########################################################################
	#########################################################################
	#########################################################################
	#########################################################################

	# Search for our network yaml file 1 level deep
	LCONF_FILE="$(netplan_cfg_find)"

	#########################################################################

	LCONF_FILE="${LCONF_FILE}.failsafe"

	debug_log "LCONF_FILE == ${LCONF_FILE}"

	LDEV="$(iface_primary_getb)"

	iface_is_wired "$LDEV"
	if [ $? -eq 0 ]; then
		LIS_PRIMARY=1
	else
		LDEVS="$(ifaces_get)"
		for LDEV in $LDEVS
		do
			iface_is_wired "$LDEV"
			if [ $? -eq 0 ]; then
				LIS_PRIMARY=1
				break
			fi
		done
	fi


	if [ $LIS_PRIMARY -lt 1 ]; then
		log_msg "Could not find primary wired network interface."
		return 1
	fi

	# This will be our predictable subnet & address for failsafe..
	LADDRESS="192.168.0.$(default_octet_get)"
	LGATEWAY=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3.1/g')
	# Google's dns servers..
	LNAMESRV0='8.8.8.8'
	LNAMESRV1='8.8.4.4'

	if [ $QUIET -lt 1 ]; then
		log_msg "Configuring ${LDEV} in ${LCONF_FILE} for:"
		log_msg "  Address: ${LADDRESS}"
		log_msg "  Gateway: ${LGATEWAY}"
		log_msg "NameSrvrs: ${LNAMESRV0},${LNAMESRV1}"
	fi

	if [ $TEST -gt 0 ]; then
		return 0
	fi

	# Create or overwrite the yaml file..
	$YQ n 'network.version' '2' >"$LCONF_FILE"
	# networkd is the default, so doesn't need to be explicitly involked.
	$YQ w -i "$LCONF_FILE" 'network.renderer' 'networkd'

	# Delete any existing wired entry for the interface..
	#~ $YQ d -i "$LCONF_FILE" "network.ethernets.${LDEV}"

	$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.dhcp4" 'no'
	$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.dhcp6" 'no'
	$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.addresses[+]" "${LADDRESS}/24"

	$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.gateway4" "$LGATEWAY"
	$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.nameservers.addresses[+]" "$LNAMESRV0"
	$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.nameservers.addresses[+]" "$LNAMESRV1"

	chmod 600 "$LCONF_FILE"

	if [ $VERBOSE -gt 0 ]; then
		log_msg "Netplan Failsafe File: ${LCONF_FILE}"
		log_cat "$LCONF_FILE"
	fi

	# Validate the yaml
	$YQ read "$LCONF_FILE" >/dev/null 2>&1

	return $?
}

########################################################################################
# netplan_apply()  exec a netplan apply or netplan try
########################################################################################
netplan_apply(){
	# This step should result in netplan creating a file in:
	#	/run/systemd/network
	# ..with the name ${NUM}-netplan-${DEVNAME}.network
	# .. to be used by systemd-networkd
	netplan --debug generate
	systemctl daemon-reload

	if [ $NETPLAN_TRY -gt 0 ]; then
		netplan try
	else
		netplan apply
	fi

	if [ $DEBUG -gt 0 ]; then
		local YQ="$(which yq)"
		local LCFG="$(netplan_cfg_find)"
		log_msg "$Contents of {LCFG}:"
		$YQ read --verbose "$LCFG"
		debug_cat "$LCFG"
	fi

}

########################################################################################
# acpi_events_failsafe_write()  Write the acpi event file to trigger network failsafe
########################################################################################
acpi_events_failsafe_write(){
	debug_echo "${FUNCNAME}( $@ )"
	local LCONF_FILE='/etc/acpi/events/net_failsafe'

	if [ -f "$LCONF_FILE" ]; then
		rm -f "$LCONF_FILE"
	fi

	cat >>"$LCONF_FILE" <<-CONF1;
	event=jack/linein LINEIN plug
	action=/usr/local/sbin/config-failsafe-network.sh "%e"
	CONF1

	LCONF_FILE="${LCONF_FILE}_undo"
	cat >>"$LCONF_FILE" <<-CONF2;
	event=jack/microphone MICROPHONE plug
	action=/usr/local/sbin/config-failsafe-network.sh "%e" --undo
	CONF2

}


fedora_iface_cfg_value_write(){
	debug_echo "${FUNCNAME}( $@ )"
	local LNET_SCRIPT="$1"
	local LKEY="$2"
	local LVALUE="$3"

	# If null value, delete the line with the key
	if [ -z "$LVALUE" ]; then
		#~ sed '{[/]<n>|<string>|<regex>[/]}d' <fileName>
		sed -i "/^${LKEY}=.*\$/d" "$LNET_SCRIPT"
		return 0
	fi

	if [ $(grep -c "${LKEY}=" "$LNET_SCRIPT") -gt 0 ]; then
		sed -i "s/^${LKEY}=.*\$/${LKEY}=${LVALUE}/" "$LNET_SCRIPT"
	else
		echo "${LKEY}=${LVALUE}" >>"$LNET_SCRIPT"
	fi

}

########################################################################################
#
# FIX THIS!!!!!!!!!!!!!!!!!Write the /etc/sysconfig/network-scripts/ifcfg-xxx file..
#
# http://danielgibbs.co.uk/2014/01/fedora-20-set-static-ip-address/
#
# http://onemoretech.wordpress.com/2014/01/09/manual-wireless-config-for-fedora-19/
#
########################################################################################

fedora_iface_cfg_write(){
	debug_echo "${FUNCNAME}( $@ )"
	local LDEV="$1"
	local LADDRESS="$2"
	local LNET_SCRIPT=
	local LKEY=
	local LVALUE=
	local LGATEWAY=
	local LNETWORK=
	local LHOSTSAL=
	local LBRDCAST=
	local LDNS1=
	local LDNS2=
	local LDNS3=
	local LNETMASK=

	#Skip devices beginning with "w" as they're wireless..
	if [[ "$LDEV" == w* ]]; then
		echo "Not configuring wireless device ${LDEV} for static IP ${LADDRESS}.."
		return 1
	fi

	LNET_SCRIPT="/etc/sysconfig/network-scripts/ifcfg-${LDEV}"

	# Backup the script..
	if [ ! -f "${LNET_SCRIPT}.org" ]; then
		cp -p "$LNET_SCRIPT" "${LNET_SCRIPT}.org"
	fi
	cp -pf "$LNET_SCRIPT" "${LNET_SCRIPT}.bak"


	LGATEWAY=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3.1/g')
	LNETWORK=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3.0/g')
	LHOSTSAL=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3./g')
	LBRDCAST=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3.255/g')
	# Google's dns servers..
	LDNS1="${GATEWAY0}"
	LDNS2='8.8.8.8'
	LDNS3='8.8.4.4'
	LNETMASK='255.255.255.0'

	echo "Configuring ${LDEV} for:"
	echo "  Address: ${LADDRESS}"
	echo "  Gateway: ${LGATEWAY}"
	echo "  Netmask: ${LNETMASK}"
	echo "  Network: ${LNETWORK}"
	echo "Broadcast: ${LBRDCAST}"
	echo "NameSrvrs: ${LNAMESRV}"

	if [ $TEST -gt 0 ]; then
		return 0
	fi

	#~ TYPE=Ethernet
	#~ PROXY_METHOD=none
	#~ BROWSER_ONLY=no
	#~ BOOTPROTO=dhcp
	#~ DEFROUTE=yes
	#~ IPV4_FAILURE_FATAL=no
	#~ IPV6INIT=yes
	#~ IPV6_AUTOCONF=yes
	#~ IPV6_DEFROUTE=yes
	#~ IPV6_FAILURE_FATAL=no
	#~ IPV6_ADDR_GEN_MODE=stable-privacy
	#~ NAME=enp0s31f6
	#~ UUID=e2b35cbc-795a-3d14-be2c-36b5573cdbed
	#~ ONBOOT=yes
	#~ AUTOCONNECT_PRIORITY=-999
	#~ DEVICE=enp0s31f6

	#~ IPADDR=1.2.3.4
	#~ NETMASK=255.255.255.0
	#~ GATEWAY=4.3.2.1
	#~ DNS1=114.114.114.114

	# Associative array of iface keys and values
	declare -A ACFG

	ACFG['TYPE']='Ethernet'
	ACFG['NM_CONTROLLED']='no'
	ACFG['PROXY_METHOD']='none'
	ACFG['BROWSER_ONLY']='no'
	ACFG['BOOTPROTO']='static'
	ACFG['IPADDR']="$LADDRESS"
	ACFG['NETMASK']="$LNETMASK"
	ACFG['BROADCAST']="$LBRDCAST"
	ACFG['NETWORK']="$LNETWORK"
	ACFG['GATEWAY']="$LGATEWAY"
	ACFG['DNS1']="$LDNS1"
	ACFG['DNS2']="$LDNS2"
	ACFG['DNS3']="$LDNS3"
	ACFG['DEFROUTE']='yes'
	ACFG['IPV4_FAILURE_FATAL']='no'
	ACFG['IPV6INIT']='yes'
	ACFG['IPV6_AUTOCONF']='yes'
	ACFG['IPV6_DEFROUTE']='yes'
	ACFG['IPV6_FAILURE_FATAL']='no'
	ACFG['IPV6_ADDR_GEN_MODE']='stable-privacy'
	ACFG['NAME']="$LDEV"
	#~ ACFG['UUID']=''
	ACFG['ONBOOT']='yes'
	ACFG['AUTOCONNECT_PRIORITY']='-999'
	ACFG['DEVICE']="$LDEV"

	for LKEY in "${!ACFG[@]}"
	do
		LVALUE="${ACFG[$LKEY]}"
		echo "key  : ${LKEY}"
		echo "value: ${LVALUE}"
		echo fedora_iface_cfg_value_write "$LNET_SCRIPT" "$LKEY" "$LVALUE"
	done

	return 0
}

fedora_iface_failsafe_write(){
	debug_echo "${FUNCNAME}( $@ )"
	local LDEV="$1"
	local LADDRESS=
	local LNET_SCRIPT=
	local LFAILSAFE_SCRIPT=
	local LKEY=
	local LVALUE=
	local LGATEWAY=
	local LNETWORK=
	local LHOSTSAL=
	local LBRDCAST=

	LNET_SCRIPT="/etc/sysconfig/network-scripts/ifcfg-${LDEV}"
	LFAILSAFE_SCRIPT="${LNET_SCRIPT}.failsafe"

	cp -p "$LNET_SCRIPT" "$LFAILSAFE_SCRIPT"

	LADDRESS="192.168.0.$(default_octet_get)"
	LGATEWAY=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3.1/g')
	LNETWORK=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3.0/g')
	LHOSTSAL=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3./g')
	LBRDCAST=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3.255/g')

	# Associative array of iface keys and values
	declare -A ACFG

	ACFG['IPADDR']="$LADDRESS"
	ACFG['GATEWAY']="$LGATEWAY"
	ACFG['NETWORK']="$LNETWORK"
	ACFG['BROADCAST']="$LBRDCAST"

	for LKEY in "${!ACFG[@]}"
	do
		LVALUE="${ACFG[$LKEY]}"
		echo "key  : ${LKEY}"
		echo "value: ${LVALUE}"
		echo fedora_iface_cfg_value_write "$LFAILSAFE_SCRIPT" "$LKEY" "$LVALUE"
	done

	return 0
}

# Support for dhcpcd configured systems
# See: https://roy.marples.name/projects/dhcpcd/
# See: http://manpages.ubuntu.com/manpages/trusty/man8/dhcpcd5.8.html
# See also https://www.raspberrypi.org/forums/viewtopic.php?t=199860
#  In particular flush the IFACE to get rid of old IP addresses
dhcpcd_cfg_write(){
	debug_echo "${FUNCNAME}( $@ )"
	local LCONF_FILE='/etc/dhcpcd.conf'

}


#########################################################################################
# Disable the firewall and disable NetworkManager
#########################################################################################

firewall_stop(){
	debug_echo "${FUNCNAME}( $@ )"
	[ $VERBOSE -gt 0 ] && log_msg "Stopping and disabling the firewall.."
	if [ $TEST -gt 0 ]; then
		return 0
	fi

	if [ $IS_FEDORA -gt 0 ]; then
		systemctl stop firewalld.service

		# Disable network manager..
		systemctl stop NetworkManager.service
		systemctl disable NetworkManager.service

		# Enable basic networking for static IP..
		systemctl enable network.service
		systemctl restart network.service

	else
		# Disable Network manager
		if [ ! -z "$(which network-manager)" ]; then
			stop network-manager
			#upstart override for network-manager
			echo "manual" >/etc/init/network-manager.override
			update-rc.d -f networking remove >/dev/null 2>&1
			update-rc.d -f networking defaults 2>&1
		fi
		# Disable ubuntu's firewall..
		ufw disable
	fi

}

#########################################################################################
# firewall_start() Enable and restart the firewall
#########################################################################################
firewall_start(){
	debug_echo "${FUNCNAME}( $@ )"
	[ $VERBOSE -gt 0 ] && log_msg "Enabling and starting the firewall.."
	if [ $IS_FEDORA -gt 0 ]; then
		systemctl start firewalld.service
	else
		ufw enable
	fi
}


#########################################################################################
# network_stop()  Stop the network..
#########################################################################################
network_stop(){
	debug_echo "${FUNCNAME}( $@ )"
	[ $QUIET -lt 1 ] && log_msg "Stopping the network service.."

	if [ $TEST -gt 0 ]; then
		return 0
	fi

	if [ $IS_NETWORKD -gt 0 ]; then
		if [ $IS_FEDORA -gt 0 ]; then
			systemctl stop network.service
		else
			systemctl stop systemd-networkd.socket
			systemctl stop systemd-networkd.service
		fi
	elif [ $IS_NETWORKMNGR -gt 0 ]; then
		nmcli networking off
	elif [ $IS_NETINTERFACES -gt 0 ]; then
		/etc/init.d/networking stop
	fi
}


resolv_conf_fix(){
	debug_echo "${FUNCNAME}( $@ )"
	if [ $IS_FEDORA -lt 1 ]; then
		# Fixup the resolv.conf file..  Modifications are only made if resolv.conf is not a symbolic link.
		/usr/local/sbin/config-resolv.sh
	fi
}

#########################################################################################
# network_start()  Start the network..
#########################################################################################
network_start(){
	debug_echo "${FUNCNAME}( $@ )"
	[ $QUIET -lt 1 ] && log_msg "Starting the network service.."

	if [ $TEST -gt 0 ]; then
		return 0
	fi
	
	systemctl daemon-reload

	if [ $IS_NETWORKD -gt 0 ]; then
		if [ $IS_FEDORA -gt 0 ]; then
			systemctl restart network.service
		else
			# Fixup the resolv.conf file..  Modifications are only made if resolv.conf is not a symbolic link.
			resolv_conf_fix
			# Restart the network..
			systemctl restart systemd-networkd.service
			#~ systemctl restart systemd-networkd.socket
		fi
	elif [ $IS_NETWORKMNGR -gt 0 ]; then
		nmcli networking on
	elif [ $IS_NETINTERFACES -gt 0 ]; then
		/etc/init.d/networking restart
	fi

}

#########################################################################################
# network_restart()  Stop then restart the network..
#########################################################################################
network_restart(){
	debug_echo "${FUNCNAME}( $@ )"

	[ $QUIET -lt 1 ] && log_msg "Restarting the network service.."

	if [ $TEST -gt 0 ]; then
		return 0
	fi
	
	if [ $IS_NETWORKD -gt 0 ]; then
		if [ $IS_FEDORA -gt 0 ]; then
			systemctl stop network.service
		else
			systemctl stop systemd-networkd.socket
			systemctl stop systemd-networkd.service
		fi
	elif [ $IS_NETWORKMNGR -gt 0 ]; then
		nmcli networking off
	elif [ $IS_NETINTERFACES -gt 0 ]; then
		/etc/init.d/networking stop
	fi
	
	[ $QUIET -lt 1 ] && log_msg "Waiting 5 seconds to restart the network.."
	sleep 5

	systemctl daemon-reload

	if [ $IS_NETWORKD -gt 0 ]; then
		if [ $IS_FEDORA -gt 0 ]; then
			systemctl restart network.service
		else
			# Fixup the resolv.conf file..  Modifications are only made if resolv.conf is not a symbolic link.
			resolv_conf_fix
			# Restart the network..
			systemctl restart systemd-networkd.service
			#~ systemctl restart systemd-networkd.socket
		fi
	elif [ $IS_NETWORKMNGR -gt 0 ]; then
		nmcli networking on
	elif [ $IS_NETINTERFACES -gt 0 ]; then
		/etc/init.d/networking restart
	fi

}


#########################################################################################
# netatalk_fix()  If netatalk is installed AND CONFIGURED, then reconfigure it..
#########################################################################################
netatalk_fix(){
	debug_echo "${FUNCNAME}( $@ )"
	local LIPADDR0="$1"
	local LIPADDR1="$2"

	local LCONF_FILE='/usr/local/etc/afp.conf'
	local IPADR=''
	local LHOSTSALLOW=''

	if [ ! -f "$CONF_FILE" ]; then
		[ $VERBOSE -gt 0 ] && "${FUNCNAME} ERROR: ${LCONF_FILE} not found.  Is netatalk service configured?"
		return 1
	fi

	[ $QUIET -lt 1 ] && log_msg "Configuring netatalk for ${LIPADDR0} ${LIPADDR1}"

	if [ $TEST -gt 0 ]; then
		return 0
	fi

	if [ $(grep -c -E '^hosts allow =.*$' "$CONF_FILE") -gt 0 ]; then

		if [-z "$LIPADDR0" ]; then
			LIPADDR0=$(ipaddr_primary_get)
		fi
		#192.168.0
		LHOSTSALLOW="${LIPADDR0%.*}.0\/24"

		if [-z "$LIPADDR1" ]; then
			[ $MULTI_NICS -gt 0 ] && LIPADDR1=$(ipaddr_secondary_getb)
		fi
		if [ ! -z "$LIPADDR1" ]; then
			LHOSTSALLOW="${LHOSTSALLOW}, ${LIPADDR1%.*}.0\/24"
		fi

		if [ $(pgrep afpd) ]; then
			systemctl stop netatalk
		fi

		[ $QUIET -lt 1 ] && log_msg "Updating ${LCONF_FILE} with hosts allow = ${LHOSTSALLOW}"
		#hosts allow = 192.168.0.0/16
		sed -i "s/^hosts allow = .*$/hosts allow = ${LHOSTSALLOW}/" "$LCONF_FILE"

		sleep 5
		systemctl start netatalk
		sleep 3
		[ $VERBOSE -gt 0 ] && systemctl -l --no-pager status netatalk

	fi


}

#########################################################################################
# samba_fix()  If samba is installed, then update the hosts allow = with our subnets
#########################################################################################
samba_fix(){
	debug_echo "${FUNCNAME} $@"
	local LIPADDR0="$1"
	local LIPADDR1="$2"
	local LCONF_FILE='/etc/samba/smb.conf'
	local LHOSTSALLOW=''

	if [ ! -f "$LCONF_FILE" ]; then
		[ $VERBOSE -gt 0 ] && log_msg "${FUNCNAME} ERROR: ${LCONF_FILE} not found.  Is samba service configured?"
		return 1
	fi

	[ $QUIET -lt 1 ] && log_msg "Configuring samba for ${LIPADDR0} ${LIPADDR1}"

	if [ $TEST -gt 0 ]; then
		return 0
	fi

	if [ $(grep -c -E '^.*hosts allow =.*$' "$LCONF_FILE") -lt 1 ]; then
		log_msg "Cannot find hosts allow entry in ${LCONF_FILE}"
		return 1
	else
		if [ -z "$LIPADDR0" ]; then
			LIPADDR0=$(ipaddr_primary_get)
		fi
		#192.168.0
		LHOSTSALLOW="${LIPADDR0%.*}."

		if [ -z "$LIPADDR1" ]; then
			[ $MULTI_NICS -gt 0 ] && LIPADDR1=$(ipaddr_secondary_getb)
		fi

		if [ ! -z "$LIPADDR1" ]; then
			LHOSTSALLOW="${LHOSTSALLOW}, ${LIPADDR1%.*}."
		fi


		if [ ! -z "$(pgrep smbd)" ]; then
			systemctl stop smbd
		fi

		[ $QUIET -lt 1 ] && log_msg "Updating ${LCONF_FILE} with hosts allow = 127., ${LHOSTSALLOW}"
		sed -i "s/^.*hosts allow = .*$/\thosts allow = 127., ${LHOSTSALLOW}/" "$LCONF_FILE"
		
		# Comment out the hosts allow line.  This allows access from any subnet..
		[ $FIREWALL_PUBLIC -gt 0 ] && sed -i -e 's/^\s\+hosts allow = /;    hosts allow = /' "$$LCONF_FILE"

		sleep 5

		systemctl start smbd

		sleep 2

		[ $VERBOSE -gt 0 ] && systemctl -l --no-pager status smbd

	fi
	return 0
}

#########################################################################################
# minidlna_fix()  If minidlna is installed, then update the network_interface= with our nics
#########################################################################################
minidlna_fix(){
	debug_echo "${FUNCNAME}( $@ )"
	local LDEV0="$1"
	local LDEV1="$2"

	local LCONF_FILE='/etc/minidlna/minidlna.conf'
	local LDEVS_ALLOW=


	if [ ! -f "$LCONF_FILE" ]; then
		[ $VERBOSE -gt 0 ] && log_msg "${FUNCNAME} error: ${LCONF_FILE} not found.  Is minidlna service configured?"
		return 1
	fi

	[ $QUIET -lt 1 ] && log_msg "Configuring minidlna for ${LDEV0} ${LDEV1}"

	if [ $TEST -gt 0 ]; then
		return 0
	fi

	if [ -z "$LDEV0" ]; then
		LDEVS_ALLOW="$(ifaces_get)"
		LDEVS_ALLOW="$(echo "$LDEVS_ALLOW" | sed -e 's/ /, /g')"
	else
		LDEVS_ALLOW="$LDEV0"
		if [ ! -z "$LDEV1" ]; then
			LDEVS_ALLOW="${LDEVS_ALLOW}, ${LDEV1}"
		fi
	fi

	if [ $(pgrep minidlnad) ]; then
		systemctl stop minidlna
	fi

	[ $QUIET -lt 1 ] && log_msg "Updating ${LCONF_FILE} with network_interface=${LDEVS_ALLOW}"

	#network_interface=eth0
	sed -i "s/^.*network_interface=.*$/network_interface=${LDEVS_ALLOW}/" "$LCONF_FILE"

	systemctl restart minidlna
	sleep 3
	[ $VERBOSE -gt 0 ] && systemctl -l --no-pager status minidlna


}

########################################################################################
########################################################################################
########################################################################################
#
# main()
#
# Any args are IP addresses to assign to net devs.  If no args, assign net devs IPs on
# incremented subnets.
#
########################################################################################
########################################################################################
########################################################################################

DISP_ARGS="${SCRIPT_NAME} ${@}"

# cmd line args...
# --iface
# --ip
# --ssid
# --wpa-psk
#

# Process cmd line args..
SHORTARGS='h,d,q,v,p,t,a,w'
LONGARGS="help,
debug,
quiet,
verbose,
test,
force,
log,
logfile:,
min,minimal,
fix-timeout,
netcfg-only,
testping,
primary-only,
primary:,iface0:,
secondary:,iface1:,
dhcp,
primary-ip:,addr0:,
secondary-ip:,addr1:,
wireless,
ssid:,
psk:,wpa-psk:,
update-yq,
netplan-try,
no-firewall,
firewall-iface:,
apps,fwapps,no-apps,no-fwapps,
public,
netatalk,
NetworkManager"

# Remove line-feeds..
LONGARGS="$(echo "$LONGARGS" | sed ':a;N;$!ba;s/\n//g')"


ARGS=$(getopt -o "$SHORTARGS" -l "$LONGARGS"  -n "$(basename $0)" -- "$@")

if [ $? -gt 0 ]; then
	disp_help "$SCRIPT_DESC" "$SCRIPT_EXTRA"
	exit 1
fi

eval set -- "$ARGS"

while [ $# -gt 0 ]; do
	case "$1" in
		--)
		   ;;
		-h|--help)		# Display this help
			disp_help "$SCRIPT_DESC" "$SCRIPT_EXTRA"
			exit 0
			;;
		-d|--debug)		# Emits debugging info
			((DEBUG++))
			CONFIG_NETWORK_OPTS="${CONFIG_NETWORK_OPTS} --debug"
			;;
		-q|--quiet)		# Suspresses output
			QUIET=1
			VERBOSE=0
			CONFIG_NETWORK_OPTS="${CONFIG_NETWORK_OPTS} --quiet"
			;;
		-v|--verbose)		# Emits extra info
			((VERBOSE++))
			CONFIG_NETWORK_OPTS="${CONFIG_NETWORK_OPTS} --verbose"
			;;
		-f|--force)		# Force install of dependencies, wifi config with no SSID, etc.
			FORCE=1
			CONFIG_NETWORK_OPTS="${CONFIG_NETWORK_OPTS} --force"
			;;
		-t|--test)		# Test script logic without performing actions
			VERBOSE=1;
			TEST=1
			CONFIG_NETWORK_OPTS="${CONFIG_NETWORK_OPTS} --test"
			;;
		-l|--log)		# Log script output
			LOG=1
			log_msg_dir_create "$SCRIPT_LOG"
			;;
		-L|--logfile)		# Specify log file
			LOG=1
			shift
			SCRIPT_LOG="$1"
			log_msg_dir_create "$SCRIPT_LOG"
			;;
		--fix-timeout)		# Fix for systemd-networkd-wait-online timeout bug
			NETWORKD_TIMEOUT_FIX=1
			;;
		--testping)		# Exit script early if ping to gateway failes
			TESTPING=1
			;;
		--netplan-try)		# Execute netplan with try option
			NETPLAN_TRY=1
			;;
		--update-yq)		# Force update of yq YAML parser
			UPDATE_YQ=1
			;;
		-p|--primary-only)	# Configure primary nic only
			MULTI_NICS=0
			;;
		--netcfg-only)		# Configure nics only. Do not configure firewall or fixup services.
			NETCFG_ONLY=1
			;;
		-w|--wireless)		# Use wireless nic as primary adapter
			PREFER_WIRELESS=1
			;;
		--primary|--iface0)	# Primary nic device name
			shift
			NETDEV0="$1"
			;;
		--secondary|--iface1)	# Secondary nic device name
			shift
			NETDEV1="$1"
			MULTI_NICS=1
			;;
		--dhcp)			# Configure all nics to use dhcp
			DHCP_ALL=1
			IPADDR0='dhcp'
			IPADDR1='dhcp'
			;;
		--primary-ip|--addr0)	# IP address for the primary nic
			shift
			IPADDR0="$1"
			;;
		--secondary-ip|--addr1)	# IP address for the secondary nic
			shift
			IPADDR1="$1"
			;;
		--ssid|--essid)		# ESSID for the wireless network to connect with
			shift
			ESSID="$1"
			;;
		--psk|--wpa-psk)		# WPA-PSK passkey for the wireless network
			shift
			WPA_PSK="$1"
			;;
		--NetworkManager)	# Install NetworkManager and disable systemd-networkd
			INST_NETWORKMNGR=1
			;;
#		--netatalk)
#			FIX_NETATALK=1
#			;;
		--no-firewall)		# Don't configure the firewall
			NO_FIREWALL=1
			;;
		--min|--minimal)		# Configure a minimal firewall (bootpc, ssh)
			FIREWALL_MINIMAL=1
			;;
		--public)		# Configure firewall rule for all subnets
			FIREWALL_PUBLIC=1
			;;
		--apps|--fwapps)		# Use service application profiles for the firewall config
			FIREWALL_USE_APPS=1
			;;
		--no-apps|--no-fwapps)	# Don't use firewall service application profiles
			FIREWALL_USE_APPS=0
			;;
		--firewall-iface)	# Configure the firewall for a specific nic only
			shift
			FIREWALL_IFACE="$1"
			;;
		*)
			# is this a valid interface name?
			#~ is_iface "$1"
			iface_is_valid "$1"
			if [ $? -lt 1 ]; then
				if [ -z "$NETDEV0" ]; then
					NETDEV0="$1"
				else
					NETDEV1="$1"
					MULTI_NICS=1
				fi
			else
				# OK, then see if this is a valid IP address..
				#~ valid_ip "$1"
				ipaddr_is_valid "$1"
				if [ $? -lt 1 ]; then
					if [ -z "$IPADDR0" ]; then
						IPADDR0="$1"
					else
						IPADDR1="$1"
					fi
				else
					log_msg "Error: ${1} is not a valid NIC name or ip address.."
					exit 1
				fi
			fi
			;;
   esac
   shift
done

log_msg '===================================================================='
log_msg "${DISP_ARGS}"
log_msg '===================================================================='


[ $VERBOSE -gt 0 ] && log_msg "Configuring network..."

# Before we do anything else, install any needed dependencies..
dependencies_check

#~ # If we're switching to NetworkManager from systemd-networkd
#~ if [ $INST_NETWORKMNGR -gt 0 ]; then

#~ fi

# If we're configuring more than one interface...
#   Get the count of interfaces..
if [ ! $MULTI_NICS -eq 0 ]; then
	#~ if [ $(ls -1 '/sys/class/net' | grep -v -E '^lo$' | wc -l) -lt 2 ]; then
	if [ $(ifaces_get | wc -w) -lt 2 ]; then
		MULTI_NICS=0
	fi
fi


#ARGNUMBER=$#

# If a ESSID has been specified, save the ssid & wpa-psk (if wpa-psk is blank, will configure for open wifi network)
if [ ! -z "$ESSID" ]; then
	wpa_supplicant_info_save "$ESSID" "$WPA_PSK"
fi

# Primary network interface...check or fetch device names
if [ ! -z "$NETDEV0" ]; then
	iface_is_valid "$NETDEV0"
	if [ $? -gt 0 ]; then
		log_msg "Error: network interface ${NETDEV0} does not exist.."
		exit 1
	fi
else
	NETDEV0=$(iface_primary_getb)
fi

# Check or fetch the primary ip address
case "$IPADDR0" in
	"")
		# Maybe we have an ip via DHCP...so stay on that subnet..
		IPADDR0=$(iface_ipaddress_get "$NETDEV0")

		if [ -z "$IPADDR0" ]; then
			log_msg "Error: could not get an ip address for ${NETDEV0}.."
			exit 1
		fi

		SUBNET=${IPADDR0%.*}
		OCTET=$(default_octet_get)
		IPADDR0="${SUBNET}.${OCTET}"
			;;
	dhcp)
		;;
	*)
		ipaddress_validate "$IPADDR0"
		if [ $? -gt 0 ]; then
			log_msg "Error: ${IPADDR0} is not a valid IP address.."
			exit 1
		fi
		;;
esac
[ $QUIET -lt 1 ] && log_msg "Setting primary interface ${NETDEV0} to ${IPADDR0}."

# Secondary network interface..
if [ $MULTI_NICS -gt 0 ]; then

	if [ ! -z "$NETDEV1" ]; then
		iface_is_valid "$NETDEV1"
		if [ $? -gt 0 ]; then
			log_msg "Error: network interface ${NETDEV1} does not exist.."
			# Ignore the error and continue so the primary iface is configured..
			NETDEV1=''
			MULTI_NICS=0
		fi
	else
		NETDEV1=$(iface_secondary_getb)
	fi

	case "$IPADDR1" in
		"")
			SUBNET=${IPADDR0%.*}
			# Increment the subnet
			SUBNET_OCTET=${SUBNET##*\.}
			let SUBNET_OCTET++
			SUBNET="${SUBNET%.*}.${SUBNET_OCTET}"
			OCTET=$(default_octet_get)
			IPADDR1="${SUBNET}.${OCTET}"
			;;
		dhcp)
			;;
		*)
			ipaddress_validate "$IPADDR1"
			if [ $? -gt 0 ]; then
				log_msg "Error: ${IPADDR1} is not a valid IP address.."
				exit 1
			fi
			;;
	esac
	[ $QUIET -lt 1 ] && log_msg "Setting secondary interface ${NETDEV1} to ${IPADDR1}."

fi

#~ if [ $DEBUG -gt 0 ]; then
	error_echo '======================================'
	error_echo "MULTI_NICS == ${MULTI_NICS}"
	error_echo "   NETDEV0 == ${NETDEV0}"
	error_echo "   IPADDR0 == ${IPADDR0}"
	error_echo "   NETDEV1 == ${NETDEV1}"
	error_echo "   IPADDR1 == ${IPADDR1}"
	error_echo "     ESSID == ${ESSID}"
	error_echo "   WPA_PSK == ${WPA_PSK}"
	error_echo '======================================'
#~ fi

# Disable the firewall
firewall_stop

# Stop the network??
#[ $IS_FEDORA -gt 0 ] || [ $IS_NETPLAN -lt 1 ] && network_stop

network_stop

#################################################################################################################################
# Write the primary interface..
#################################################################################################################################
if [ $IS_DHCPCD -gt 0 ]; then
	log_msg "Error: Network configuration for dhcpcd.service is not currently supported.  Exiting."
	exit 1

elif [ $IS_NETWORKMNGR -gt 0 ]; then
	networkmanager_iface_set "$NETDEV0" "$IPADDR0" "$ESSID" "$WPA_PSK"

elif [ $IS_NETINTERFACES -gt 0 ]; then

	if [ $IS_FEDORA -gt 0 ]; then
		fedora_iface_cfg_write "$NETDEV0" "$IPADDR0" 1
	else
		ubuntu_iface_failsafe_write
		ubuntu_iface_cfg_write "$NETDEV0" "$IPADDR0" 1
	fi

elif [ $IS_NETWORKD -gt 0 ]; then

	if [ $IS_FEDORA -gt 0 ]; then
		log_msg "Error: Network configuration for systemd-networkd on Fedora is not currently supported.  Exiting."
		# for possible implimentations, see:
		# https://fedoraproject.org/wiki/Cloud/Network-Requirements
		# https://www.xmodulo.com/switch-from-networkmanager-to-systemd-networkd.html
		exit 1
	elif [ $IS_NETPLAN -gt 0 ]; then
		netplan_failsafe_write
		netplan_cfg_write 'CLEAR_ALL'
		netplan_cfg_write "$NETDEV0" "$IPADDR0" 1
		if [ $? -gt 0 ]; then
			log_msg "${SCRIPT_NAME} failed to produce valid yaml netplan file. Exiting."
			exit 1
		fi
	else
		log_msg "Error: Network configuration for ubuntu & systemd-networkd without netplan is not currently supported.  Exiting."
		exit 1
	fi
fi

#################################################################################################################################
# Write the secondary interface..
#################################################################################################################################
if [ $MULTI_NICS -gt 0 ] && [ ! -z "$NETDEV1" ] && [ $IS_DHCPCD -gt 0 ]; then
	log_msg "Error: Network configuration for dhcpcd.service is not currently supported.  Exiting."
	exit 1

elif [ $MULTI_NICS -gt 0 ] && [ ! -z "$NETDEV1" ] && [ $IS_NETWORKMNGR -gt 0 ]; then
	networkmanager_iface_set "$NETDEV1" "$IPADDR1" "$ESSID" "$WPA_PSK"

elif [ $MULTI_NICS -gt 0 ] && [ ! -z "$NETDEV1" ] && [ $IS_NETINTERFACES -gt 0 ]; then
	if [ $IS_FEDORA -gt 0 ]; then
		fedora_iface_cfg_write "$NETDEV1" "$IPADDR1" 0
	else
		ubuntu_iface_cfg_write "$NETDEV1" "$IPADDR1" 0
	fi

elif [ $MULTI_NICS -gt 0 ] && [ ! -z "$NETDEV1" ] && [ $IS_NETWORKD -gt 0 ]; then
	if [ $IS_NETPLAN -gt 0 ]; then
		netplan_cfg_write "$NETDEV1" "$IPADDR1" 0
		if [ $? -gt 0 ]; then
			log_msg "${SCRIPT_NAME} failed to produce valid yaml netplan file. Exiting."
			exit 1
		fi
	else
		log_msg "Error: Network configuration for systemd-networkd without netplan is not currently supported.  Exiting."
		exit 1
	fi

fi

if [ $IS_NETPLAN -gt 0 ]; then
	netplan_apply
fi

# Restart the network
#~ log_msg "Waiting 5 seconds for network to restart.."
#~ sleep 5
#~ [ $IS_FEDORA -gt 0 ] || [ $IS_NETPLAN -lt 1 ] && network_start
network_restart


# Get the IP addresses if we're configured for dhcp..
if [ $DHCP_ALL -gt 0 ] || [ $IPADDR0 = 'dhcp' ] || [ -z "$NETDEV0" ]; then

	IPADDR0=$(ipaddr_primary_get)

	if [ -z "$NETDEV0" ]; then
		NETDEV0=$(iface_primary_getb)
	fi

	if [ $MULTI_NICS -gt 0 ]; then
		IPADDR1=$(ipaddr_secondary_get)
		if [ -z "$NETDEV1" ]; then
			NETDEV1=$(iface_secondary_getb)
		fi
	else
		IPADDR1=
		NETDEV1=
	fi

fi


#~ GATEWAY=$(echo $IPADDR0 | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3.1/g')
GATEWAY="$(iface_gateway_get "$NETDEV0")"

if [ -z "$GATEWAY" ]; then
	GATEWAY="$(ipaddress_subnet_get "$IPADDR0")"
fi

# If ping fails then exit early, skipping modifying the firewall & sharing services..
if [ $TESTPING -gt 0 ]; then
	[ $VERBOSE -gt 0 ] && log_msg "${SCRIPT_NAME}: Attempting to ping ${GATEWAY} from ${IPADDR0}.."
	sleep 3
	ping -c 1 -W 5 $GATEWAY >/dev/null 2>&1
	if [ $? -gt 0 ]; then
		[ $QUIET -lt 1 ] && log_msg "${SCRIPT_NAME}: Gateway ${GATEWAY} does not respond to ping. Exiting."
		exit 1
	else
		[ $QUIET -lt 1 ] && log_msg "${SCRIPT_NAME}: Gateway ${GATEWAY} responds to ping. Continuing.."
	fi
fi

# Fix for systemd bug Bug #2036358 systemd wait-online now times out after jammy and lunar upgrade
# See: https://bugs.launchpad.net/ubuntu/+source/systemd/+bug/2036358
if [ $NETWORKD_TIMEOUT_FIX -gt 0 ]; then
	networkd_wait_online_fix
fi

# Fix-up various services and firewall..
if [ $NETCFG_ONLY -lt 1 ]; then
	[ $QUIET -lt 1 ] && log_msg "${SCRIPT_NAME}: Configuring other services for ${NETDEV0}:${IPADDR0}, ${NETDEV1}:${IPADDR1}"
	[ $FIX_NETATALK -gt 0 ] && netatalk_fix "$IPADDR0" "$IPADDR1"
	samba_fix "$IPADDR0" "$IPADDR1"
	minidlna_fix "$NETDEV0" "$NETDEV1"
	FW_ARGS=''
	if [ $DEBUG -gt 0 ]; then
		FW_ARGS='--debug'
	fi
	if [ $QUIET -gt 0 ]; then
		FW_ARGS="${FW_ARGS} --quiet"
	fi
	if [ $VERBOSE -gt 0 ]; then
		FW_ARGS="${FW_ARGS} --verbose"
	fi
	if [ $FIREWALL_MINIMAL -gt 0 ]; then
		FW_ARGS="${FW_ARGS} --minimal"
	fi
	if [ $FIREWALL_PUBLIC -gt 0 ]; then
		FW_ARGS="${FW_ARGS} --public"
	fi

	if [ $NO_FIREWALL -lt 1 ]; then
		if [ $FIREWALL_USE_APPS -gt 0 ]; then
			[ $QUIET -lt 1 ] && log_msg "Configuring firewall using application definitions for installed services.."
			"${SCRIPT_DIR}/config-firewall-prep-apps.sh" $FW_ARGS
		else
			if [ ! -z "$FIREWALL_IFACE" ]; then
				[ $QUIET -lt 1 ] && log_msg "Configuring firewall for ${FW_ARGS} ${FIREWALL_IFACE}"
				"${SCRIPT_DIR}/config-firewall.sh" $CONFIG_NETWORK_OPTS $FW_ARGS "$FIREWALL_IFACE"
			else
				[ $QUIET -lt 1 ] && log_msg "Configuring firewall for ${FW_ARGS} ${IPADDR0} ${IPADDR1}"
				"${SCRIPT_DIR}/config-firewall.sh" $CONFIG_NETWORK_OPTS $FW_ARGS "$IPADDR0" "$IPADDR1"
			fi
		fi
	fi

fi

# Check connectivity..
###################################################################################################
# See if we can ping our gateway...

# Return connection status..

if [ $TESTPING -lt 1 ]; then
	[ $QUIET -lt 1 ] && log_msg "${SCRIPT_NAME}: Attempting to ping ${GATEWAY}"

	ping -c 1 -W 5 $GATEWAY >/dev/null 2>&1

	if [ $? -gt 0 ]; then
		[ $QUIET -lt 1 ] && log_msg "${SCRIPT_NAME}: ${GATEWAY} does not respond to ping. Exiting."
		exit 1
	else
		[ $QUIET -lt 1 ] && log_msg "${SCRIPT_NAME}: ${GATEWAY} responds to ping, so network is OK.."
		exit 0
	fi
fi

exit 0
