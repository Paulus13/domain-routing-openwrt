#!/bin/sh

#set -x

check_repo() {
    printf "\033[32;1mChecking OpenWrt repo availability...\033[0m\n"
    opkg update | grep -q "Failed to download" && printf "\033[32;1mopkg failed. Check internet or date. Command for force ntp sync: ntpd -p ptbtime1.ptb.de\033[0m\n" && exit 1
}

check_inet() {
printf "\033[32;1mChecking Internet connection...\033[0m\n"
p_loss=$(ping -qw 3 8.8.8.8 | grep 'packet loss' | cut -d ' ' -f 7 | sed 's/%//')

if [ $p_loss -eq 100 ]; then
	printf "\033[32;1mInternet check failed.\033[0m\n"
	exit 1
fi
}

route_vpn () {
    if [ "$TUNNEL" == wg ]; then
cat << EOF > /etc/hotplug.d/iface/30-vpnroute
#!/bin/sh

ip route add table vpn default dev wg0
EOF
    elif [ "$TUNNEL" == singbox ] || [ "$TUNNEL" == ovpn ] || [ "$TUNNEL" == tun2socks ]; then
cat << EOF > /etc/hotplug.d/iface/30-vpnroute
#!/bin/sh

sleep 5
ip route add table vpn default dev tun0
EOF
    fi
}

add_mark() {
    grep -q "99 vpn" /etc/iproute2/rt_tables || echo '99 vpn' >> /etc/iproute2/rt_tables
    
    if ! uci show network | grep -q mark0x1; then
        printf "\033[32;1mConfigure mark rule\033[0m\n"
        uci add network rule
        uci set network.@rule[-1].name='mark0x1'
        uci set network.@rule[-1].mark='0x1'
        uci set network.@rule[-1].priority='100'
        uci set network.@rule[-1].lookup='vpn'
        uci commit
    fi
}

add_tunnel() {
    echo "We can automatically configure only Wireguard. OpenVPN, Sing-box(Shadowsocks2022, VMess, VLESS, etc) and tun2socks will need to be configured manually"
    echo "Select a tunnel:"
    echo "1) WireGuard"
    echo "2) Existing WireGuard (interface name must be 'wg0', and firewall zone configured)"	
    echo "3) OpenVPN"
    echo "4) Sing-box"
    echo "5) tun2socks"
    echo "6) Skip this step"

    while true; do
    read -r -p '' TUNNEL
        case $TUNNEL in 

        1) 
            TUNNEL=wg
            break
            ;;
			
		2) 
            TUNNEL=wg_ex
            break
            ;;

        3)
            TUNNEL=ovpn
            break
            ;;

        4) 
            TUNNEL=singbox
            break
            ;;

        5) 
            TUNNEL=tun2socks
            break
            ;;

        6)
            echo "Skip"
            TUNNEL=0
            break
            ;;

        *)
            echo "Choose from the following options"
            ;;
        esac
    done

    if [ "$TUNNEL" == 'wg_ex' ]; then
		TUNNEL=wg
		route_vpn
		TUNNEL=0
	fi
	
    if [ "$TUNNEL" == 'wg' ]; then
        printf "\033[32;1mConfigure WireGuard\033[0m\n"
        if opkg list-installed | grep -q wireguard-tools; then
            echo "Wireguard already installed"
        else
            echo "Installed wg..."
            opkg install wireguard-tools
        fi

        route_vpn

        read -r -p "Enter the private key (from [Interface]):"$'\n' WG_PRIVATE_KEY

        while true; do
            read -r -p "Enter internal IP address with subnet, example 192.168.100.5/24 (from [Interface]):"$'\n' WG_IP
            if echo "$WG_IP" | egrep -oq '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$'; then
                break
            else
                echo "This IP is not valid. Please repeat"
            fi
        done

        read -r -p "Enter the public key (from [Peer]):"$'\n' WG_PUBLIC_KEY
        read -r -p "If use PresharedKey, Enter this (from [Peer]). If your don't use leave blank:"$'\n' WG_PRESHARED_KEY
        read -r -p "Enter Endpoint host without port (Domain or IP) (from [Peer]):"$'\n' WG_ENDPOINT

        read -r -p "Enter Endpoint host port (from [Peer]) [51820]:"$'\n' WG_ENDPOINT_PORT
        WG_ENDPOINT_PORT=${WG_ENDPOINT_PORT:-51820}
        if [ "$WG_ENDPOINT_PORT" = '51820' ]; then
            echo $WG_ENDPOINT_PORT
        fi
        
        uci set network.wg0=interface
        uci set network.wg0.proto='wireguard'
        uci set network.wg0.private_key=$WG_PRIVATE_KEY
        uci set network.wg0.listen_port='51820'
        uci set network.wg0.addresses=$WG_IP

        if ! uci show network | grep -q wireguard_wg0; then
            uci add network wireguard_wg0
        fi
        uci set network.@wireguard_wg0[0]=wireguard_wg0
        uci set network.@wireguard_wg0[0].name='wg0_client'
        uci set network.@wireguard_wg0[0].public_key=$WG_PUBLIC_KEY
        uci set network.@wireguard_wg0[0].preshared_key=$WG_PRESHARED_KEY
        uci set network.@wireguard_wg0[0].route_allowed_ips='0'
        uci set network.@wireguard_wg0[0].persistent_keepalive='25'
        uci set network.@wireguard_wg0[0].endpoint_host=$WG_ENDPOINT
        uci set network.@wireguard_wg0[0].allowed_ips='0.0.0.0/0'
        uci set network.@wireguard_wg0[0].endpoint_port=$WG_ENDPOINT_PORT
        uci commit
    fi

    if [ "$TUNNEL" == 'ovpn' ]; then
        if opkg list-installed | grep -q openvpn-openssl; then
            echo "OpenVPN already installed"
        else
            echo "Installed openvpn"
            opkg install openvpn-openssl
        fi
        printf "\033[32;1mConfigure route for OpenVPN\033[0m\n"
        route_vpn
    fi

    if [ "$TUNNEL" == 'singbox' ]; then
        if opkg list-installed | grep -q sing-box; then
            echo "Sing-box already installed"
        else
            AVAILABLE_SPACE=$(df / | awk 'NR>1 { print $4 }')
            if  [[ "$AVAILABLE_SPACE" -gt 2000 ]]; then
                echo "Installed sing-box"
                opkg install sing-box
            else
                printf "\033[31;1mNo free space for a sing-box. Sing-box is not installed.\033[0m\n"
                exit 1
            fi
        fi
        if grep -q "option enabled '0'" /etc/config/sing-box; then
            sed -i "s/	option enabled \'0\'/	option enabled \'1\'/" /etc/config/sing-box
        fi
        if grep -q "option user 'sing-box'" /etc/config/sing-box; then
            sed -i "s/	option user \'sing-box\'/	option user \'root\'/" /etc/config/sing-box
        fi
        if grep -q "tun0" /etc/sing-box/config.json; then
        printf "\033[32;1mConfig /etc/sing-box/config.json already exists\033[0m\n"
        else
cat << 'EOF' > /etc/sing-box/config.json
{
  "log": {
    "level": "debug"
  },
  "inbounds": [
    {
      "type": "tun",
      "interface_name": "tun0",
      "domain_strategy": "ipv4_only",
      "inet4_address": "172.16.250.1/30",
      "auto_route": false,
      "strict_route": false,
      "sniff": true 
   }
  ],
  "outbounds": [
    {
      "type": "$TYPE",
      "server": "$HOST",
      "server_port": $PORT,
      "method": "$METHOD",
      "password": "$PASS"
    }
  ],
  "route": {
    "auto_detect_interface": true
  }
}
EOF
        printf "\033[32;1mCreate template config in /etc/sing-box/config.json. Edit it manually. Official doc: https://sing-box.sagernet.org/configuration/outbound/\033[0m\n"
        printf "\033[32;1mOfficial doc: https://sing-box.sagernet.org/configuration/outbound/\033[0m\n"
        printf "\033[32;1mManual with example SS: https://cli.co/Badmn3K \033[0m\n"

        fi
        printf "\033[32;1mConfigure route for Sing-box\033[0m\n"
        route_vpn
    fi
}

dnsmasqfull() {
    if opkg list-installed | grep -q dnsmasq-full; then
        printf "\033[32;1mdnsmasq-full already installed\033[0m\n"
    else
        printf "\033[32;1mInstalled dnsmasq-full\033[0m\n"
        cd /tmp/ && opkg download dnsmasq-full
        opkg remove dnsmasq && opkg install dnsmasq-full --cache /tmp/

        [ -f /etc/config/dhcp-opkg ] && cp /etc/config/dhcp /etc/config/dhcp-old && mv /etc/config/dhcp-opkg /etc/config/dhcp
fi
}

remove_forwarding() {
    if [ ! -z "$forward_id" ]; then
        while uci -q delete firewall.@forwarding[$forward_id]; do :; done
    fi
}

add_zone() {
    if  [ "$TUNNEL" == 0 ]; then
        printf "\033[32;1mZone setting skipped\033[0m\n"
    elif uci show firewall | grep -q "@zone.*name='$TUNNEL'"; then
        printf "\033[32;1mZone already exist\033[0m\n"
    else
        printf "\033[32;1mCreate zone\033[0m\n"

        # Delete exists zone
        zone_tun_id=$(uci show firewall | grep -E '@zone.*tun0' | awk -F '[][{}]' '{print $2}' | head -n 1)
        if [ "$zone_tun_id" == 0 ] || [ "$zone_tun_id" == 1 ]; then
            printf "\033[32;1mtun0 zone has an identifier of 0 or 1. That's not ok. Fix your firewall. lan and wan zones should have identifiers 0 and 1. \033[0m\n"
            exit 1
        fi
        if [ ! -z "$zone_tun_id" ]; then
            while uci -q delete firewall.@zone[$zone_tun_id]; do :; done
        fi

        zone_wg_id=$(uci show firewall | grep -E '@zone.*wg0' | awk -F '[][{}]' '{print $2}' | head -n 1)
        if [ "$zone_wg_id" == 0 ] || [ "$zone_wg_id" == 1 ]; then
            printf "\033[32;1mwg0 zone has an identifier of 0 or 1. That's not ok. Fix your firewall. lan and wan zones should have identifiers 0 and 1. \033[0m\n"
            exit 1
        fi
        if [ ! -z "$zone_wg_id" ]; then
            while uci -q delete firewall.@zone[$zone_wg_id]; do :; done
        fi

        uci add firewall zone
        uci set firewall.@zone[-1].name="$TUNNEL"
        if [ "$TUNNEL" == wg ]; then
            uci set firewall.@zone[-1].network='wg0'
        elif [ "$TUNNEL" == singbox ] || [ "$TUNNEL" == ovpn ] || [ "$TUNNEL" == tun2socks ]; then
            uci set firewall.@zone[-1].device='tun0'
        fi
        if [ "$TUNNEL" == wg ] || [ "$TUNNEL" == ovpn ] || [ "$TUNNEL" == tun2socks ]; then
            uci set firewall.@zone[-1].forward='REJECT'
            uci set firewall.@zone[-1].output='ACCEPT'
            uci set firewall.@zone[-1].input='REJECT'
        elif [ "$TUNNEL" == singbox ]; then
            uci set firewall.@zone[-1].forward='ACCEPT'
            uci set firewall.@zone[-1].output='ACCEPT'
            uci set firewall.@zone[-1].input='ACCEPT'
        fi
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'
        uci set firewall.@zone[-1].family='ipv4'
        uci commit firewall
    fi
    
    if [ "$TUNNEL" == 0 ]; then
        printf "\033[32;1mForwarding setting skipped\033[0m\n"
    elif uci show firewall | grep -q "@forwarding.*name='$TUNNEL-lan'"; then
        printf "\033[32;1mForwarding already configured\033[0m\n"
    else
        printf "\033[32;1mConfigured forwarding\033[0m\n"
        # Delete exists forwarding
        if [[ $TUNNEL != "wg" ]]; then
            forward_id=$(uci show firewall | grep -E "@forwarding.*dest='wg'" | awk -F '[][{}]' '{print $2}' | head -n 1)
            remove_forwarding
        fi

        if [[ $TUNNEL != "ovpn" ]]; then
            forward_id=$(uci show firewall | grep -E "@forwarding.*dest='ovpn'" | awk -F '[][{}]' '{print $2}' | head -n 1)
            remove_forwarding
        fi

        if [[ $TUNNEL != "singbox" ]]; then
            forward_id=$(uci show firewall | grep -E "@forwarding.*dest='singbox'" | awk -F '[][{}]' '{print $2}' | head -n 1)
            remove_forwarding
        fi

        if [[ $TUNNEL != "tun2socks" ]]; then
            forward_id=$(uci show firewall | grep -E "@forwarding.*dest='tun2socks'" | awk -F '[][{}]' '{print $2}' | head -n 1)
            remove_forwarding
        fi

        uci add firewall forwarding
        uci set firewall.@forwarding[-1]=forwarding
        uci set firewall.@forwarding[-1].name="$TUNNEL-lan"
        uci set firewall.@forwarding[-1].dest="$TUNNEL"
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].family='ipv4'
        uci commit firewall
    fi
}

show_manual() {
    if [ "$TUNNEL" == tun2socks ]; then
        printf "\033[42;1mZone for tun2socks cofigured. But you need to set up the tunnel yourself.\033[0m\n"
        echo "Use this manual: https://cli.co/VNZISEM"
    elif [ "$TUNNEL" == ovpn ]; then
        printf "\033[42;1mZone for OpenVPN cofigured. But you need to set up the tunnel yourself.\033[0m\n"
        echo "Use this manual: https://itdog.info/nastrojka-klienta-openvpn-na-openwrt/"
    fi
}

add_set() {
    if uci show firewall | grep -q "@ipset.*name='vpn_domains'"; then
        printf "\033[32;1mSet already exist\033[0m\n"
    else
        printf "\033[32;1mCreate set\033[0m\n"
        uci add firewall ipset
        uci set firewall.@ipset[-1].name='vpn_domains'
        uci set firewall.@ipset[-1].match='dst_net'
        uci commit
    fi
    if uci show firewall | grep -q "@rule.*name='mark_domains'"; then
        printf "\033[32;1mRule for set already exist\033[0m\n"
    else
        printf "\033[32;1mCreate rule set\033[0m\n"
        uci add firewall rule
        uci set firewall.@rule[-1]=rule
        uci set firewall.@rule[-1].name='mark_domains'
        uci set firewall.@rule[-1].src='lan'
        uci set firewall.@rule[-1].dest='*'
        uci set firewall.@rule[-1].proto='all'
        uci set firewall.@rule[-1].ipset='vpn_domains'
        uci set firewall.@rule[-1].set_mark='0x1'
        uci set firewall.@rule[-1].target='MARK'
        uci set firewall.@rule[-1].family='ipv4'
        uci commit
    fi
}

add_dns_resolver() {
    echo "Configure DNSCrypt2 or Stubby? It does matter if your ISP is spoofing DNS requests"
    DISK=$(df -m / | awk 'NR==2{ print $2 }')
    if [[ "$DISK" -lt 32 ]]; then 
        printf "\033[31;1mYour router a disk have less than 32MB. It is not recommended to install DNSCrypt, it takes 10MB\033[0m\n"
    fi
    echo "Select:"
    echo "1) No [Default]"
    echo "2) DNSCrypt2 (10.7M)"
    echo "3) Stubby (36K)"

    while true; do
    read -r -p '' DNS_RESOLVER
        case $DNS_RESOLVER in 

        1) 
            echo "Skiped"
            break
            ;;

        2)
            DNS_RESOLVER=DNSCRYPT
            break
            ;;

        3) 
            DNS_RESOLVER=STUBBY
            break
            ;;

        *)
            echo "Choose from the following options"
            ;;
        esac
    done

    if [ "$DNS_RESOLVER" == 'DNSCRYPT' ]; then
        if opkg list-installed | grep -q dnscrypt-proxy2; then
            printf "\033[32;1mDNSCrypt2 already installed\033[0m\n"
        else
            printf "\033[32;1mInstalled dnscrypt-proxy2\033[0m\n"
            opkg install dnscrypt-proxy2
            if grep -q "# server_names" /etc/dnscrypt-proxy2/dnscrypt-proxy.toml; then
                sed -i "s/^# server_names =.*/server_names = [\'google\', \'cloudflare\', \'scaleway-fr\', \'yandex\']/g" /etc/dnscrypt-proxy2/dnscrypt-proxy.toml
            fi

            printf "\033[32;1mDNSCrypt restart\033[0m\n"
            service dnscrypt-proxy restart
            printf "\033[32;1mDNSCrypt needs to load the relays list. Please wait\033[0m\n"
            sleep 30

            if [ -f /etc/dnscrypt-proxy2/relays.md ]; then
                uci set dhcp.@dnsmasq[0].noresolv="1"
                uci -q delete dhcp.@dnsmasq[0].server
                uci add_list dhcp.@dnsmasq[0].server="127.0.0.53#53"
                uci add_list dhcp.@dnsmasq[0].server='/use-application-dns.net/'
                uci commit dhcp
                
                printf "\033[32;1mDnsmasq restart\033[0m\n"

                /etc/init.d/dnsmasq restart
            else
                printf "\033[31;1mDNSCrypt not download list on /etc/dnscrypt-proxy2. Repeat install DNSCrypt by script.\033[0m\n"
            fi
    fi

    fi

    if [ "$DNS_RESOLVER" == 'STUBBY' ]; then
        printf "\033[32;1mConfigure Stubby\033[0m\n"

        if opkg list-installed | grep -q stubby; then
            printf "\033[32;1mStubby already installed\033[0m\n"
        else
            printf "\033[32;1mInstalled stubby\033[0m\n"
            opkg install stubby

            printf "\033[32;1mConfigure Dnsmasq for Stubby\033[0m\n"
            uci set dhcp.@dnsmasq[0].noresolv="1"
            uci -q delete dhcp.@dnsmasq[0].server
            uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#5453"
            uci add_list dhcp.@dnsmasq[0].server='/use-application-dns.net/'
            uci commit dhcp

            printf "\033[32;1mDnsmasq restart\033[0m\n"

            /etc/init.d/dnsmasq restart
        fi
    fi
}

add_packages() {
    if opkg list-installed | grep -q "curl -"; then
        printf "\033[32;1mCurl already installed\033[0m\n"
    else
        printf "\033[32;1mInstall curl\033[0m\n"
        opkg install curl
    fi

    # if opkg list-installed | grep -q nano; then
        # printf "\033[32;1mNano already installed\033[0m\n"
    # else
        # printf "\033[32;1mInstall nano\033[0m\n"
        # opkg install nano
    # fi
}

add_getdomains() {
    echo "Choose you country"
    echo "Select:"
    echo "1) Russia inside. You are inside Russia"
    echo "2) Russia outside. You are outside of Russia, but you need access to Russian resources"
    echo "3) Ukraine. uablacklist.net list"
    echo "4) Skip script creation"

    while true; do
    read -r -p '' COUNTRY
        case $COUNTRY in 

        1) 
            COUNTRY=russia_inside
            break
            ;;

        2)
            COUNTRY=russia_outside
            break
            ;;

        3) 
            COUNTRY=ukraine
            break
            ;;

        4) 
            echo "Skiped"
            COUNTRY=0
            break
            ;;

        *)
            echo "Choose from the following options"
            ;;
        esac
    done

    if [ "$COUNTRY" == 'russia_inside' ]; then
        EOF_DOMAINS=DOMAINS=https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst
    elif [ "$COUNTRY" == 'russia_outside' ]; then
        EOF_DOMAINS=DOMAINS=https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/outside-dnsmasq-nfset.lst
    elif [ "$COUNTRY" == 'ukraine' ]; then
        EOF_DOMAINS=DOMAINS=https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Ukraine/inside-dnsmasq-nfset.lst
    fi

    if [ "$COUNTRY" != '0' ]; then
        printf "\033[32;1mCreate script /etc/init.d/getdomains\033[0m\n"

cat << EOF > /etc/init.d/getdomains
#!/bin/sh /etc/rc.common

START=99

start () {
    $EOF_DOMAINS
EOF
cat << 'EOF' >> /etc/init.d/getdomains
    count=0
    while true; do
        if curl -m 3 github.com; then
            curl -f $DOMAINS --output /tmp/dnsmasq.d/domains.lst
            break
        else
            echo "GitHub is not available. Check the internet availability [$count]"
            count=$((count+1))
        fi
    done

    if dnsmasq --conf-file=/tmp/dnsmasq.d/domains.lst --test 2>&1 | grep -q "syntax check OK"; then
        /etc/init.d/dnsmasq restart
    fi
}
EOF

        chmod +x /etc/init.d/getdomains
        /etc/init.d/getdomains enable

        if crontab -l | grep -q /etc/init.d/getdomains; then
            printf "\033[32;1mCrontab already configured\033[0m\n"

        else
            crontab -l | { cat; echo "0 */8 * * * /etc/init.d/getdomains start"; } | crontab -
            printf "\033[32;1mIgnore this error. This is normal for a new installation\033[0m\n"
            /etc/init.d/cron restart
        fi

        printf "\033[32;1mStart script\033[0m\n"

        /etc/init.d/getdomains start
    fi
}

check_sysupgrade() {
if ! cat /etc/sysupgrade.conf | grep -q 30-vpnroute; then
	echo '/etc/hotplug.d/iface/30-vpnroute' >> /etc/sysupgrade.conf
fi

if ! cat /etc/sysupgrade.conf | grep -q getdomains; then
	echo '/etc/init.d/getdomains' >> /etc/sysupgrade.conf
	echo '/etc/rc.d/S99getdomains' >> /etc/sysupgrade.conf
	printf "\033[32;1mSysupgrade file now updated\033[0m\n"
else
	printf "\033[32;1mSysupgrade file already updated\033[0m\n"
fi
}

# System Details
MODEL=$(grep machine /proc/cpuinfo | cut -d ':' -f 2)
RELEASE=$(grep OPENWRT_RELEASE /etc/os-release | awk -F '"' '{print $2}')
printf "\033[34;1mModel:$MODEL\033[0m\n"
printf "\033[34;1mVersion: $RELEASE\033[0m\n"

VERSION_ID=$(grep VERSION_ID /etc/os-release | awk -F '"' '{print $2}' | awk -F. '{print $1}')

if [ "$VERSION_ID" -lt 23 ]; then
    printf "\033[31;1mScript only support OpenWrt 23.05 and 24.10\033[0m\n"
    echo "For OpenWrt 21.02 and 22.03 you can:"
    echo "1) Use ansible https://github.com/itdoginfo/domain-routing-openwrt"
    echo "2) Configure manually. Old manual: https://itdog.info/tochechnaya-marshrutizaciya-na-routere-s-openwrt-wireguard-i-dnscrypt/"
    exit
fi

if [ "$VERSION_ID" -eq 24 ]; then
	if [ ! -d /tmp/dnsmasq.d ]; then
		uci set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'
		uci commit
	fi
fi

printf "\033[31;1mAll actions performed here cannot be rolled back automatically.\033[0m\n"

#check_repo
check_inet

add_packages

add_tunnel

add_mark

add_zone

show_manual

add_set

dnsmasqfull

add_dns_resolver

add_getdomains

check_sysupgrade

printf "\033[32;1mRestart network\033[0m\n"
/etc/init.d/network restart

printf "\033[32;1mDone\033[0m\n"
