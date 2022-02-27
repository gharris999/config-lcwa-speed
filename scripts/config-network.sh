#!/bin/bash

SCRIPT_VERSION=20210117.145727

# Bash script to configure default NIC to a static IP address..

# Todo: Support creating wifi APs via hostapd
#		https://unix.stackexchange.com/questions/401533/making-hostapd-work-with-systemd-networkd-using-a-bridge
#		https://bbs.archlinux.org/viewtopic.php?id=205334

# 5/12/19 Completely refactored to support networkctl, netplan, etc.

# 7/14/14 Started work to refactor to support wifi networking..

# Refactor to make work for Fedora too..
#	Look at: http://www.server-world.info/en/note?os=Fedora_19&p=initial_conf&f=3
#   Look at: http://danielgibbs.co.uk/2013/01/fedora-18-set-static-ip-address/

#First disable the gnome network manager from starting up
#
#systemctl stop NetworkManager.service
#systemctl disable NetworkManager.service
#
#Check which interface(s) you want to set to static
#
#[root@server ~]# ifconfig
#em1: flags=4163 mtu 1500
#..etc..
#
#Now you will need to edit the config file for that interface
#
#vi /etc/sysconfig/network-scripts/ifcfg-em1
#
#Edit the config to look like so. You will need to change BOOTPROTO from dhcp to static
#and add IPADDR, NETMASK, BROADCAST and NETWORK variables. Also make sure ONBOOT is set to yes.
#
#UUID="e88f1292-1f87-4576-97aa-bb8b2be34bd3"
#NM_CONTROLLED="yes"
#HWADDR="D8:D3:85:AE:DD:4C"
#BOOTPROTO="static"
#DEVICE="em1"
#ONBOOT="yes"
#IPADDR0=192.168.1.2
#NETMASK=255.255.255.0
#BROADCAST=192.168.1.255
#NETWORK=192.168.1.0
#GATEWAY=192.168.1.1
#Now to apply the settings restart the network service
#
#systemctl restart network.service
#


# This include file contains most of the utility functions..
INCLUDE_FILE="$(dirname $(readlink -f $0))/instsrv_functions.sh"
[ ! -f "$INCLUDE_FILE" ] && INCLUDE_FILE='/usr/local/sbin/instsrv_functions.sh'

. "$INCLUDE_FILE"

SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
INST_LOGFILE="/var/log/${SCRIPT}.log"


#~ IS_FEDORA="$(which firewall-cmd 2>/dev/null | wc -l)"
#~ IS_NETPLAN="$(which netplan 2>/dev/null | wc -l)"

TESTPING=0
NETCFG_ONLY=0
DEBUG=0
DEBUG_ARG=
QUIET=0
VERBOSE=0
LOG=0
FAKE=0
NETPLAN_TRY=0
UPDATE_YQ=0
NO_PAUSE=0
CONFIG_NETWORK_OPTS=


# MULTI_NICS=1: Default to detecting primary & secondary NICs
MULTI_NICS=1

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


log_msg(){
	error_echo "$@"
	[ $LOG -gt 0 ] && error_log "$@"
}



########################################################################################
# wpa_supplicant_info_save() Save the ESSID & WPA-PSK to 
#  /etc/wpa_supplicant/wpa_supplacant.conf file.
#  If wpa-psk is blank, will configure for open wifi network.
########################################################################################
wpa_supplicant_info_save(){
	local W_ESSID="$1"
	local W_WPA_PSK="$2"
	local CONF_DIR="$(dirname "$WPA_CONF_FILE")"

	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"

	if [ -z "$W_ESSID" ]; then
		[ $QUIET -lt 1 ] && error_echo "Error: no wireless ESSID specified.."
		return 1
	fi

	[ $VERBOSE -gt 0 ] && error_echo "Saving ssid ${W_ESSID} wpa-psk ${W_WPA_PSK}.."

	if [ $FAKE -gt 0 ]; then
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
cat >>"$WPA_CONF_FILE" <<WNET0;
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
		[ $QUIET -lt 1 ] && error_echo "Error saving wifi configuration.."
		return 1
	fi

	return 0
}


########################################################################################
# ubuntu_iface_cfg_write()  Write the /etc/network/interfaces file..
#							Not used on systems with netplan.
########################################################################################

ubuntu_iface_cfg_write(){	
	local LDEV="$1"
	local LADDRESS="$2"
	local LIS_PRIMARY=$3
	local LCONF_FILE='/etc/network/interfaces'

	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"

	local LGATEWAY=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3.1/g')
	local LNETWORK=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3.0/g')
	local LHOSTSAL=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3./g')
	local LBRDCAST=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3.255/g')
	# Google's dns servers..
	local LNAMESRV="${GATEWAY0} 8.8.8.8 8.8.4.4"
	local LNETMASK='255.255.255.0'

	if [ $QUIET -lt 1 ]; then

		error_echo "Configuring ${LDEV} for:"

		iface_is_wireless "$LDEV"
		if [ $? -lt 1 ]; then
			if [ ! -z "$ESSID" ]; then
				error_echo "     ESSID: ${ESSID}"
			fi

			if [ ! -z "$WPA_PSK" ]; then
				error_echo "  wpa-psk: ${WPA_PSK}"
			fi
		fi
		error_echo "  Address: ${LADDRESS}"
		error_echo "  Netmask: ${LNETMASK}"
		error_echo "Broadcast: ${LBRDCAST}"
		error_echo "  Network: ${LNETWORK}"

		if [ $IS_PRIMARY -eq 1 ]; then
			# Secondary adapters must not have a gateway or dns-nameservers in /etc/network/interfaces or the network hangs at boot time
			error_echo "  Gateway: ${LGATEWAY}"
			error_echo "NameSrvrs: ${LNAMESRV}"
		fi
	fi

	if [ $FAKE -gt 0 ]; then
		return 0
	fi

	# If we're configuring just a single interface, overwrite the interfaces file..
	if [ $MULTI_NICS -lt 1 ]; then

cat >"$LCONF_FILE" <<NET0;

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
	#if [ $(iwconfig "$DEV" 2>&1 | egrep -c 'no wireless') -gt 0 ]; then
	if [ ! -e "/sys/class/net/${LDEV}/wireless" ]; then

		[ $VERBOSE -gt 0 ] && error_echo "${LDEV} is a wired device.."

		# Configuring for DHCP?
		if [ "$LADDRESS" == 'dhcp' ]; then
			echo "auto ${LDEV}" >>"$LCONF_FILE"
			echo "iface ${LDEV} inet dhcp" >>"$LCONF_FILE"

		# Static IP config..
		else

# Wired interface..
cat >>"$LCONF_FILE" <<NET1;
auto ${LDEV}
iface ${LDEV} inet static
address ${LADDRESS}
netmask ${LNETMASK}
broadcast ${LBRDCAST}
network ${LNETWORK}
NET1

			if [ $IS_PRIMARY -gt 0 ]; then
# Secondary adapters must not have a gateway or dns-nameservers in /etc/network/interfaces or the network hangs at boot time
cat >>"$LCONF_FILE" <<NET1A;
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
		[ $VERBOSE -gt 0 ] && error_echo "${LDEV} is a wireless device.."

		if [ -f "$WPA_CONF_FILE" ]; then

			if [ "$LADDRESS" == 'dhcp' ]; then
				echo "auto ${LDEV}" >>"$LCONF_FILE"
				echo "iface ${LDEV} inet dhcp" >>"$LCONF_FILE"
				echo "wpa-conf ${WPA_CONF_FILE}" >>"$LCONF_FILE"

			else

cat >>"$LCONF_FILE" <<WNET1;
auto ${LDEV}
iface ${LDEV} inet static
wpa-conf ${WPA_CONF_FILE}
address ${LADDRESS}
netmask ${LNETMASK}
broadcast ${LBRDCAST}
network ${LNETWORK}
WNET1

				if [ $IS_PRIMARY -gt 0 ]; then
cat >>"$LCONF_FILE" <<WNET1A;
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
cat >>"$LCONF_FILE" <<WNET2;
auto ${LDEV}
iface ${LDEV} inet static
address ${LADDRESS}
netmask ${LNETMASK}
broadcast ${LBRDCAST}
network ${LNETWORK}
WNET2
				if [ $IS_PRIMARY -gt 0 ]; then
cat >>"$LCONF_FILE" <<WNET2A;
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
		error_echo "Interfaces File:"
		cat "$LCONF_FILE"
	fi

	return 0
}


########################################################################################
# ubuntu_iface_failsafe_write()  Write the backup /etc/network/interfaces file..
#								 Not used on systems with netplan.
########################################################################################
ubuntu_iface_failsafe_write(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
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

		error_echo "Configuring ${LDEV} failsafe for:"

		error_echo "  Address: ${LADDRESS}"
		error_echo "  Netmask: ${LNETMASK}"
		error_echo "Broadcast: ${LBRDCAST}"
		error_echo "  Network: ${LNETWORK}"
		error_echo "  Gateway: ${LGATEWAY}"
		error_echo "NameSrvrs: ${LNAMESRV}"
	fi

	if [ $FAKE -gt 0 ]; then
		return 0
	fi


# Wired interface..
cat >>"$LCONF_FILE" <<NET2;
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
		error_echo "${LDEV} failsafe interface file: ${LCONF_FILE}"
		cat "$LCONF_FILE"
	fi

	
	return 0
}


###############################################################################
# yq_install()  Install yq by downloading the latest version from
#               https://github.com/mikefarah/yq/releases/latest/
###############################################################################
yq_install(){


	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"

	#~ if [ "$(uname -m)" = 'x86_64' ]; then
		#~ error_echo "Installing yq from ppa.."
		#~ # snap install yq
		#~ add-apt-repository -y ppa:rmescandon/yq
		#~ apt update
		#~ apt install yq -y
		#~ if [ ! -z "$(which yq)" }; then
			#~ return 0
		#~ fi
	#~ fi

	error_echo "Finding latest version of yq YAML parser.."
	TMPDIR='/tmp'
	cd "$TMPDIR"
	if [ ! "$TMPDIR" = "$(pwd)" ]; then
		echo "Error: cannot cd to ${TMPDIR}."
		exit 1
	fi

	if [ -f "${TMPDIR}/index.html" ]; then
		rm -f "${TMPDIR}/index.html"
	fi

	# Don't know how to use YQ 4.x syntax thus far, so don't use it!!!
	#~ YQ_INDEX='https://github.com/mikefarah/yq/releases/latest/'
	YQ_INDEX='https://github.com/mikefarah/yq/releases/tag/3.4.1/'
	
	wget -q "$YQ_INDEX"
	
	if [ ! -f "${TMPDIR}/index.html" ]; then
		error_echo "Error: cannot get ${YQ_INDEX}."
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
			error_echo "${YQ}, version ${YQ_LOCAL_VER} is up to date with remote version ${YQ_REMOTE_VER}."
			return 1
		fi
	fi
	
	#~ Download https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64..
	

	error_echo "Downloading ${YQ_BIN_URL}.."
	wget -q "$YQ_BIN_URL"
	
	if [ ! -f "$YQ_BIN" ]; then
		error_echo "Error: could not download ${YQ_BIN}"
		exit 1
	fi

	YQ_INST='/usr/local/bin/yq'

	if [ -f "$YQ_INST" ]; then
		cp -f "$YQ_INST" "${YQ_INST}.old"
	fi

	cp "$YQ_BIN" "$YQ_INST"
	chmod 755 "$YQ_INST"

	error_echo "${YQ_BIN} installed successfully to ${YQ_INST}.."

	rm "$YQ_BIN"
	return 0
}

###############################################################################
# yq_check() -- Check to see if yq is installed.  Needed for writing yaml files
###############################################################################
yq_check(){
	# See if yq is installed, exit if not..
	local YQ="$(which yq)"
	
	if [ -z "$YQ" ]; then
		error_echo "yq yaml command line editor is not installed."
		yq_install
	elif [ $UPDATE_YQ -gt 0 ]; then
		error_echo "Checking version of installed yq yaml command line editor."
		yq_install
	fi
}

###############################################################################
# dependency_install() -- Make sure we have the utilites we need:
#                           yq, fping, dhcping
###############################################################################
dependency_install(){
	local LUTIL="$@"
	if [ $IS_FEDORA -gt 0 ]; then
		dnf --assumeyes install $LUTIL
	
	elif [ $IS_DEBIAN -gt 0 ]; then
		apt-install $LUTIL
	else
		error_echo "Error: cannot install ${LUTIL}."
		return 1
	fi
	
}

###############################################################################
# dependencies_check() -- Make sure we have the utilites we need:
#                         yq, fping, dhcping, yamllint
###############################################################################
dependencies_check(){
	
	# Get linked interfaces
	local LNETLINKS="$(ifaces_get_links)"

	# Skip dependency checks and installs if no link on any interface..
	if [ -z "$LNETLINKS" ]; then
		return 1
	fi

	for UTIL in fping dhcping yamllint
	do
		error_echo "Checking for dependency ${UTIL}.."
		[ -z "$(which "$UTIL" 2>/dev/null)" ] && dependency_install "$UTIL" || error_echo "${UTIL} found."
	done
	
	if [ $IS_NETPLAN -gt 0 ]; then
		yq_check
	fi

}

########################################################################################
# ubuntu_netplan_cfg_find()  Find the /etc/netplan/0x-netcfg.yaml file
########################################################################################
ubuntu_netplan_cfg_find(){
	local LEXT="$1"
	local LCFG_DIR="$2"
	local LCONF_FILE=
	local LDEFCONF_FILE='/etc/netplan/01-netcfg.yaml'

	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	
	if [ -z "$LEXT" ]; then
		LEXT='yaml'
	fi
	
	if [ -z "$LCFG_DIR" ]; then
		LCFG_DIR='/etc/netplan'
	fi

	#~ LCONF_FILE=$(find /etc/netplan -maxdepth 3 -type f -name "*.${LEXT}" | sort | grep -m1 '.yaml')
	LCONF_FILE=$(find /etc/netplan -maxdepth 1 -type f -name "*.${LEXT}" | sort | grep -m1 ".${LEXT}")
	
	#~ if [ -z "$LCONF_FILE" ]; then
		#~ error_echo "Cannot find any file *.${LEXT}"
		#~ return 1
	#~ fi
	
	if [ -z "$LCONF_FILE" ]; then
		error_echo "${FUNCNAME}: Could not find a netplan config yaml file."
		LCONF_FILE="$LDEFCONF_FILE"
		error_echo "${FUNCNAME}: Creating default ${LCONF_FILE} netplan config yaml file."
		touch "$LCONF_FILE"
	else
		# Rename the existing yaml file if not matching our default name..
		if [ "$LCONF_FILE" != "$LDEFCONF_FILE" ]; then
			mv -f "$LCONF_FILE" "$LDEFCONF_FILE"
			LCONF_FILE="$LDEFCONF_FILE"
		fi
		
		if [ ! -f "${LCONF_FILE}.org" ]; then
			cp "$LCONF_FILE" "${LCONF_FILE}.org"
		fi

		cp "$LCONF_FILE" "${LCONF_FILE}.bak"

	fi
	
	echo "$LCONF_FILE"
	
	return 0
}


########################################################################################
# ubuntu_netplan_cfg_write()  Write the /etc/netplan/0x-netcfg.yaml file using yq
########################################################################################
ubuntu_netplan_cfg_write(){	
	local LDEV="$1"
	local LADDRESS="$2"
	local LMACADDR=
	local LIS_DHCP=0
	local LIS_PRIMARY=$3
	local LGATEWAY=
	local LNAMESRV0=
	local LNAMESRV1=
	local LCONF_FILE=
	local LDEFCONF_FILE='/etc/netplan/01-netcfg.yaml'
	local bRet=0

	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	
	# See if yq is installed, exit if not..
	yq_check

	local YQ="$(which yq)"
	
	if [ -z "$YQ" ]; then
		error_echo "Error: Could not install yq.  ${SCRIPTNAME} must exit."
		exit 1
	fi
	
	#########################################################################
	#########################################################################
	#########################################################################
	#########################################################################
	# Work out differences between version 3 & version 4!!!
	local YQ_VER=$($YQ -V yq -V | sed -r 's/^([^.]+).*$/\1/; s/^[^0-9]*([0-9]+).*$/\1/')
	#########################################################################
	#########################################################################
	#########################################################################
	#########################################################################
	

	# Search for our network yaml file 1 level deep
	LCONF_FILE="$(ubuntu_netplan_cfg_find)"

	[ $DEBUG -gt 0 ] && error_echo "LCONF_FILE == ${LCONF_FILE}"
	
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

		error_echo "Configuring ${LDEV} in ${LCONF_FILE} for:"
		
		iface_is_wireless "$LDEV"
		if [ $? -lt 1 ]; then
			if [ ! -z "$ESSID" ]; then
				error_echo "    ESSID: ${ESSID}"
			fi
			if [ ! -z "$WPA_PSK" ]; then
				error_echo "  wpa-psk: ${WPA_PSK}"
			fi
		fi
		error_echo "  Address: ${LADDRESS}"
		error_echo "  Gateway: ${LGATEWAY}"
		error_echo "NameSrvrs: ${LNAMESRV0},${LNAMESRV1}"
	fi

	if [ $FAKE -gt 0 ]; then
		return 0
	fi
	
	# Default Ubuntu 20.04 netplan file: 00-installer-config.yaml

	## This is the network config written by 'subiquity'
	#network:
	#  ethernets:
	#    enp4s0:
	#      dhcp4: true
	#  version: 2
	
	# Is this a wired device??
	if [ ! -e "/sys/class/net/${LDEV}/wireless" ]; then

		# Delete any existing wired entry for THIS interface..
		$YQ d -i "$LCONF_FILE" "network.ethernets.${LDEV}"

		if [ $LIS_PRIMARY -lt 1 ]; then
			# Make any 2ndary wired adapter optional so boot doesn't hang if it's not linked..
			$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.optional" 'true'
		fi

		# dhcp
		if [ $LIS_DHCP -gt 0 ]; then
			$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.dhcp4" 'true'
			$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.dhcp6" 'true'
		# static
		else
			$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.dhcp4" 'no'
			$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.dhcp6" 'no'
			$YQ w -i "$LCONF_FILE" "network.ethernets.${LDEV}.addresses[+]" "${LADDRESS}/24"
			if [ $LIS_PRIMARY -gt 0 ]; then
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

		
	else	# Wireless
		# Delete any existing wifi entry for the interface..
		$YQ d -i "$LCONF_FILE" "network.wifis.${LDEV}"

		# Make the wifi interface optional...i.e. don't hang at boot time if not present..
		$YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.optional" 'true'

		if [ "$LADDRESS" == 'dhcp' ]; then
			$YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.dhcp4" 'true'
		else
		
			$YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.dhcp4" 'no'
			$YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.dhcp6" 'no'
			$YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.addresses[+]" "${LADDRESS}/24"

			if [ $LIS_PRIMARY -gt 0 ]; then
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
			error_echo "WPA_PSK == ${WPA_PSK}"
			#~ $YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.access-points.${ESSID}.password" "\"${WPA_PSK}\""
			# This issue is fixed in yq version 3.2.1
			$YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.access-points.${ESSID}.password" "${WPA_PSK}"
			# Fixup yq's mangling of numeric password data..
			#~ sed -i -e "s/password:.*/password: ${WPA_PSK}/" "$LCONF_FILE"
		else
			$YQ w -i "$LCONF_FILE" "network.wifis.${LDEV}.access-points.${ESSID}" '{}'
		fi
	fi

	# Make any required fixes to the yaml file

	if [ $(grep -c "'{}'" "$LCONF_FILE") -gt 0 ]; then
		error_echo "Fixing up ${LCONF_FILE}.."
		sed -i -e 's/\x27{}\x27/{}/g' "$LCONF_FILE"
	fi
	
	# Insert our comment into the yaml file..
	# This is the network config written by 'subiquity'

	local LCOMMENT="# This is the network config written by '${SCRIPT}'"
	
	# Delete any existing config ownership comments..
	sed -i -e '/^# This is the network config written by/d' "$LCONF_FILE"
	
	# Insert our comment at the head of the file..
	sed -i "1 i\\${LCOMMENT}" "$LCONF_FILE"
	
	# This is just a backup file, showing the config we're trying..
	cp "$LCONF_FILE" "${LCONF_FILE}.try"

	# Validate each pass while constructing the yaml
	$YQ read "$LCONF_FILE" >/dev/null 2>&1
	bRet=$?
	
	if [ $bRet -gt 0 ] || [ $VERBOSE -gt 0 ]; then
		error_echo '============================================================='
		error_echo "yq read of ${LCONF_FILE} returned ${bRet}"
		error_echo "Netplan File: ${LCONF_FILE}"
		$YQ read --verbose "$LCONF_FILE"
		error_echo '============================================================='
		yamllint -f parsable "$LCONF_FILE"
	fi

	return $bRet

}

########################################################################################
# ubuntu_netplan_failsafe_write()  Write the /etc/netplan/0x-netcfg.yaml.failsafe file using yq
########################################################################################
ubuntu_netplan_failsafe_write(){	
	local LDEVS=
	local LDEV=
	local LADDRESS=
	local LIS_PRIMARY=0
	local LGATEWAY=
	local LNAMESRV0=
	local LNAMESRV1=
	local LCONF_FILE=

	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	
	# See if yq is installed, exit if not..
	yq_check

	local YQ="$(which yq)"
	
	if [ -z "$YQ" ]; then
		error_echo "Error: Could not install yq.  ${SCRIPTNAME} must exit."
		exit 1
	fi

	#########################################################################
	#########################################################################
	#########################################################################
	#########################################################################
	# Work out differences between version 3 & version 4!!!
	local YQ_VER=$($YQ -V yq -V | sed -r 's/^([^.]+).*$/\1/; s/^[^0-9]*([0-9]+).*$/\1/')
	#########################################################################
	#########################################################################
	#########################################################################
	#########################################################################
	
	# Search for our network yaml file 1 level deep
	LCONF_FILE="$(ubuntu_netplan_cfg_find)"

	#########################################################################
	
	LCONF_FILE="${LCONF_FILE}.failsafe"
	
	[ $DEBUG -gt 0 ] && error_echo "LCONF_FILE == ${LCONF_FILE}"
	
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
		error_echo "Could not find primary wired network interface."
		return 1
	fi
	
	# This will be our predictable subnet & address for failsafe..
	LADDRESS="192.168.0.$(default_octet_get)"
	LGATEWAY=$(echo $LADDRESS | sed -e 's/^\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)\.\([[:digit:]]\{1,3\}\)/\1.\2.\3.1/g')
	# Google's dns servers..
	LNAMESRV0='8.8.8.8'
	LNAMESRV1='8.8.4.4'
	
	if [ $QUIET -lt 1 ]; then

		error_echo "Configuring ${LDEV} failsafe for:"
		error_echo "  Address: ${LADDRESS}"
		error_echo "  Gateway: ${LGATEWAY}"
		error_echo "NameSrvrs: ${LNAMESRV0},${LNAMESRV1}"
	fi

	if [ $FAKE -gt 0 ]; then
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
	
	if [ $VERBOSE -gt 0 ]; then
		error_echo "Netplan Failsafe File: ${LCONF_FILE}"
		cat "$LCONF_FILE"
	fi

	# Validate the yaml
	$YQ read "$LCONF_FILE" >/dev/null 2>&1

	return $?
}

########################################################################################
# ubuntu_netplan_apply()  exec a netplan apply or netplan try
########################################################################################
ubuntu_netplan_apply(){
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
		local LCFG="$(ubuntu_netplan_cfg_find)"
		error_echo "$Contents of {LCFG}:"
		$YQ read --verbose "$LCFG"
		cat "$LCFG"
	fi
	
}

########################################################################################
# acpi_events_failsafe_write()  Write the acpi event file to trigger network failsafe
########################################################################################
acpi_events_failsafe_write(){
	local LCONF_FILE='/etc/acpi/events/net_failsafe'
	
	if [ -f "$LCONF_FILE" ]; then
		rm -f "$LCONF_FILE"
	fi
	
	cat >>"$LCONF_FILE" <<CONF1;
event=jack/linein LINEIN plug
action=/usr/local/sbin/config-failsafe-network.sh "%e"
CONF1

	LCONF_FILE="${LCONF_FILE}_undo"
	cat >>"$LCONF_FILE" <<CONF2;
event=jack/microphone MICROPHONE plug
action=/usr/local/sbin/config-failsafe-network.sh "%e" --undo
CONF2
	
}


fedora_iface_cfg_value_write(){
	local LNET_SCRIPT="$1"
	local LKEY="$2"
	local LVALUE="$3"
	
	# If null value, delete the line with the key
	if [ -z "$LVALUE" ]; then
		#~ sed '{[/]<n>|<string>|<regex>[/]}d' <fileName> 
		sed -i "/^${LKEY}=.*\$/d" "$LNET_SCRIPT"
		return 0
	fi

	if [ $(egrep -c "${LKEY}=" "$LNET_SCRIPT") -gt 0 ]; then
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

	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"

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

	if [ $FAKE -gt 0 ]; then
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
	local LCONF_FILE='/etc/dhcpcd.conf'
	
}


#########################################################################################
# Disable the firewall and disable NetworkManager
#########################################################################################

firewall_stop(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	[ $VERBOSE -gt 0 ] && error_echo "Stopping and disabling the firewall.."
	if [ $FAKE -gt 0 ]; then
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
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	[ $VERBOSE -gt 0 ] && error_echo "Enabling and starting the firewall.."
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
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	[ $VERBOSE -gt 0 ] && error_echo "Stopping the network service.."

	if [ $FAKE -gt 0 ]; then
		return 0
	fi


	if [ $IS_FEDORA -gt 0 ]; then
		systemctl stop network.service
	else
		systemctl stop systemd-networkd.service
	fi
}


resolv_conf_fix(){
	if [ $IS_FEDORA -lt 1 ]; then
		# Fixup the resolv.conf file..  Modifications are only made if resolv.conf is not a symbolic link.
		/usr/local/sbin/config-resolv.sh
	fi
}

#########################################################################################
# network_start()  Start the network..
#########################################################################################
network_start(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	[ $VERBOSE -gt 0 ] && error_echo "Restarting the network service.."

	if [ $FAKE -gt 0 ]; then
		return 0
	fi

	if [ $IS_FEDORA -gt 0 ]; then
		systemctl restart network.service
	else
		# Fixup the resolv.conf file..  Modifications are only made if resolv.conf is not a symbolic link.
		resolv_conf_fix
		# Restart the network..
		systemctl restart systemd-networkd.service
	fi

}


#########################################################################################
# netatalk_fix()  If netatalk is installed AND CONFIGURED, then reconfigure it..
#########################################################################################
netatalk_fix(){
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	local LIPADDR0="$1"
	local LIPADDR1="$2"
	
	local LCONF_FILE='/usr/local/etc/afp.conf'
	local IPADR=''
	local LHOSTSALLOW=''

	if [ ! -f "$CONF_FILE" ]; then
		[ $VERBOSE -gt 0 ] && "${FUNCNAME} ERROR: ${LCONF_FILE} not found.  Is netatalk service configured?"
		return 1
	fi

	[ $QUIET -lt 1 ] && error_echo "Configuring netatalk for ${LIPADDR0} ${LIPADDR1}"

	if [ $FAKE -gt 0 ]; then
		return 0
	fi

	if [ $(egrep -c '^hosts allow =.*$' "$CONF_FILE") -gt 0 ]; then

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

		[ $QUIET -lt 1 ] && error_echo "Updating ${LCONF_FILE} with hosts allow = ${LHOSTSALLOW}"
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
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	local LIPADDR0="$1"
	local LIPADDR1="$2"
	local LCONF_FILE='/etc/samba/smb.conf'
	local LHOSTSALLOW=''

	if [ ! -f "$LCONF_FILE" ]; then
		[ $VERBOSE -gt 0 ] && error_echo "${FUNCNAME} ERROR: ${LCONF_FILE} not found.  Is samba service configured?"
		return 1
	fi

	[ $QUIET -lt 1 ] && error_echo "Configuring samba for ${LIPADDR0} ${LIPADDR1}"
	
	if [ $FAKE -gt 0 ]; then
		return 0
	fi

	if [ $(egrep -c '^.*hosts allow =.*$' "$LCONF_FILE") -lt 1 ]; then
		error_echo "Cannot find hosts allow entry in ${LCONF_FILE}"
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

		[ $QUIET -lt 1 ] && error_echo "Updating ${LCONF_FILE} with hosts allow = 127., ${LHOSTSALLOW}"
		sed -i "s/^.*hosts allow = .*$/\thosts allow = 127., ${LHOSTSALLOW}/" "$LCONF_FILE"

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
	[ $DEBUG -gt 0 ] && error_echo "${FUNCNAME} $@"
	local LDEV0="$1"
	local LDEV1="$2"

	local LCONF_FILE='/etc/minidlna/minidlna.conf'
	local LDEVS_ALLOW=


	if [ ! -f "$LCONF_FILE" ]; then
		[ $VERBOSE -gt 0 ] && error_echo "${FUNCNAME} ERROR: ${LCONF_FILE} not found.  Is minidlna service configured?"
		return 1
	fi

	[ $QUIET -lt 1 ] && error_echo "Configuring minidlna for ${LDEV0} ${LDEV1}"

	if [ $FAKE -gt 0 ]; then
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

	[ $QUIET -lt 1 ] && error_echo "Updating ${LCONF_FILE} with network_interface=${LDEVS_ALLOW}"

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

error_echo '===================================================================='
error_echo "${SCRIPT_DIR}/${SCRIPT} ${@}"
error_echo '===================================================================='

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
logfile:,
no-pause,
min,minimal,
pri-only,
primary-only,
netcfg-only,
testping,
test,
try,
netplan-try,
update-yq,
netplan-no-try,
notest,
fake,
nofake,
all,allnics,all-nics,
wireless,
iface:,nic:,
primary:,iface0:,nic0:,
secondary:,iface1:,nic1:,
dhcp,
address:,addr:,ip:,address0:,addr0:,ip0:,primary-ip:,
address1:,addr1:,ip1:,secondary-ip:,
ssid:,essid:,
psk:,wpa-psk:,
min,minimal,
firewall-iface:"

# Remove line-feeds..
LONGARGS="$(echo "$LONGARGS" | sed ':a;N;$!ba;s/\n//g')"


ARGS=$(getopt -o "$SHORTARGS" -l "$LONGARGS"  -n "$(basename $0)" -- "$@")

eval set -- "$ARGS"

while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help)
			echo "${SCRIPTNAME} [--primary-only] [--netcfg-only] [--iface0=net_device] [--ip0=ip_address|dhcp] [--iface1=net_device] [--ip1=ip_address|dhcp] [--ssid=wifi-ssid] [--wpa-psk=wifi-passkey] [--firewall-iface=devname]"
			exit 0
			;;
		--debug)
			DEBUG=1
			CONFIG_NETWORK_OPTS="${CONFIG_NETWORK_OPTS} --debug"
			;;
		--verbose)
			VERBOSE=1
			CONFIG_NETWORK_OPTS="${CONFIG_NETWORK_OPTS} --verbose"
			;;
		--quiet)
			QUIET=1
			VERBOSE=0
			CONFIG_NETWORK_OPTS="${CONFIG_NETWORK_OPTS} --quiet"
			;;
		--force)
			FORCE=1
			CONFIG_NETWORK_OPTS="${CONFIG_NETWORK_OPTS} --force"
			;;
		-t|--test|--fake)
			VERBOSE=1;
			FAKE=1;
			TEST=1
			CONFIG_NETWORK_OPTS="${CONFIG_NETWORK_OPTS} --test"
			;;
		--notest)
			TEST=0
			;;
		--logfile)
			shift
			INST_LOGFILE="$1"
			LOG=1
			;;
		--testping)
			TESTPING=1
			;;
		--notest|--nofake)
			FAKE=0;
			;;
		--try|netplan-try)
			NETPLAN_TRY=1
			;;
		--no-try|netplan-no-try)
			NETPLAN_TRY=0
			;;
		--update-yq)
			UPDATE_YQ=1
			;;
		-p|--pri-only|--primary-only)
			MULTI_NICS=0
			;;
		--netcfg-only)
			NETCFG_ONLY=1
			;;
		-a|--all|--allnics|--all-nics)
			MULTI_NICS=1
			;;
		-w|--wireless)
			PREFER_WIRELESS=1
			;;
		--iface|--nic|--primary|--iface0|--nic0)
			shift
			NETDEV0="$1"
			;;
		--secondary|--iface1|--nic1)
			shift
			NETDEV1="$1"
			MULTI_NICS=1
			;;
		--dhcp)
			DHCP_ALL=1
			IPADDR0='dhcp'
			IPADDR1='dhcp'
			;;
		--address|--addr|--ip|--address0|--addr0|--ip0|--primary-ip)
			shift
			IPADDR0="$1"
			;;
		--address1|--addr1|--ip1|--secondary-ip)
			shift
			IPADDR1="$1"
			;;
		--ssid|--essid)
			shift
			ESSID="$1"
			;;
		--psk|--wpa-psk)
			shift
			WPA_PSK="$1"
			;;
		--min|--minimal)
			FIREWALL_MINIMAL=1
			;;
		--firewall-iface)
			shift
			FIREWALL_IFACE="$1"
			;;
		--)
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
					error_echo "Error: ${1} is not a valid NIC name or ip address.."
					exit 1
				fi
			fi
			;;
   esac
   shift
done

[ $VERBOSE -gt 0 ] && error_echo "Configuring network..."

# Before we do anything else, install any needed dependencies..
dependencies_check

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
		error_echo "Error: network interface ${NETDEV0} does not exist.."
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
			error_echo "Error: could not get an ip address for ${NETDEV0}.."
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
			error_echo "Error: ${IPADDR0} is not a valid IP address.."
			exit 1
		fi
		;;
esac
error_echo "Setting primary interface ${NETDEV0} to ${IPADDR0}."

# Secondary network interface..
if [ $MULTI_NICS -gt 0 ]; then

	if [ ! -z "$NETDEV1" ]; then
		iface_is_valid "$NETDEV1"
		if [ $? -gt 0 ]; then
			error_echo "Error: network interface ${NETDEV1} does not exist.."
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
				error_echo "Error: ${IPADDR1} is not a valid IP address.."
				exit 1
			fi
			;;
	esac
	error_echo "Setting secondary interface ${NETDEV1} to ${IPADDR1}."

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
network_stop

# Write the primary interface..
if [ $IS_FEDORA -gt 0 ]; then
	fedora_iface_cfg_write "$NETDEV0" "$IPADDR0" 1
else
	if [ $IS_NETPLAN -gt 0 ]; then
		ubuntu_netplan_failsafe_write
		ubuntu_netplan_cfg_write 'CLEAR_ALL'
		ubuntu_netplan_cfg_write "$NETDEV0" "$IPADDR0" 1
		if [ $? -gt 0 ]; then
			error_exit "${SCRIPTNAME} failed to produce valid yaml netplan file. Exiting."
		fi
	else
		ubuntu_iface_failsafe_write
		ubuntu_iface_cfg_write "$NETDEV0" "$IPADDR0" 1
	fi
fi

# Write the secondary interface..
if [ $MULTI_NICS -gt 0 ]; then
	if [ ! -z "$NETDEV1" ]; then
		if [ $IS_FEDORA -gt 0 ]; then
			fedora_iface_cfg_write "$NETDEV1" "$IPADDR1" 0
		else
			if [ $IS_NETPLAN -gt 0 ]; then
				ubuntu_netplan_cfg_write "$NETDEV1" "$IPADDR1" 0
				if [ $? -gt 0 ]; then
					error_exit "${SCRIPTNAME} failed to produce valid yaml netplan file. Exiting."
				fi
			else
				ubuntu_iface_cfg_write "$NETDEV1" "$IPADDR1" 0
			fi
		fi
	fi
fi

if [ $IS_NETPLAN -gt 0 ]; then
	ubuntu_netplan_apply
fi

# Restart the network
network_start
error_echo "Waiting 5 seconds for network to restart.."
sleep 5

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
	[ $VERBOSE -gt 0 ] && error_echo "${SCRIPTNAME}: Attempting to ping ${GATEWAY} from ${IPADDR0}.."
	sleep 3
	ping -c 1 -W 5 $GATEWAY >/dev/null 2>&1
	if [ $? -gt 0 ]; then
		[ $QUIET -lt 1 ] && error_echo "${SCRIPTNAME}: Gateway ${GATEWAY} does not respond to ping. Exiting."
		exit 1
	else
		[ $QUIET -lt 1 ] && error_echo "${SCRIPTNAME}: Gateway ${GATEWAY} responds to ping. Continuing.."
	fi
fi


# Fix-up various services and firewall..
if [ $NETCFG_ONLY -lt 1 ]; then
	[ $QUIET -lt 1 ] && error_echo "${SCRIPTNAME}: Configuring other services for ${NETDEV0}:${IPADDR0}, ${NETDEV1}:${IPADDR1}"
	netatalk_fix "$IPADDR0" "$IPADDR1"
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
	
	if [ ! -z "$FIREWALL_IFACE" ]; then
		[ $QUIET -lt 1 ] && error_echo "Configuring firewall for ${FW_ARGS} ${FIREWALL_IFACE}"
		"${SCRIPT_DIR}/config-firewall.sh" $CONFIG_NETWORK_OPTS $FW_ARGS "$FIREWALL_IFACE"
	else
		[ $QUIET -lt 1 ] && error_echo "Configuring firewall for ${FW_ARGS} ${IPADDR0} ${IPADDR1}"
		"${SCRIPT_DIR}/config-firewall.sh" $CONFIG_NETWORK_OPTS $FW_ARGS "$IPADDR0" "$IPADDR1"
	fi
fi

# Check connectivity..
###################################################################################################
# See if we can ping our gateway...

# Return connection status..

if [ $TESTPING -lt 1 ]; then
	[ $QUIET -lt 1 ] && error_echo "${SCRIPTNAME}: Attempting to ping ${GATEWAY}"
	ping -c 1 -W 5 $GATEWAY >/dev/null 2>&1
	
	if [ $? -gt 0 ]; then
		[ $QUIET -lt 1 ] && error_echo "${SCRIPTNAME}: ${GATEWAY} does not respond to ping. Exiting."
		exit 1
	else
		[ $QUIET -lt 1 ] && error_echo "${SCRIPTNAME}: ${GATEWAY} responds to ping, so network is OK.."
		exit 0
	fi
fi

exit 0
