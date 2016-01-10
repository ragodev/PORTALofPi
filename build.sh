#!/bin/bash
#  ___  ___  ___ _____ _   _
# | _ \/ _ \| _ \_   _/_\ | | of ._ o  
# |  _/ (_) |   / | |/ _ \| |__  |_)|  
# |_|  \___/|_|_\ |_/_/ \_\____| |
#
# Licensed GPLv3
#
# (c) 2013 the grugq <the.grugq@gmail.com>

# See the README.md for indepth details.
#
# Based on the RaspberryPi Arch image from here:
#  http://www.raspberrypi.org/downloads
# specifically:
#  http://archlinuxarm.org/os/rpi/archlinux-hf-2013-06-15.img.zip

# PORTAL configuration overview
#  
# ((Internet))---[USB]<[Pi]>[eth0]----((LAN))
#   eth0: 172.16.0.1
#        * anything from here can only reach 9050 (Tor proxy) or,
#        * the transparent Tor proxy 
#    USB: ???.
#        * Internet access. You're on your own
#        * No services exposed here

# STEP 1 !!! 
#   configure Internet access, we'll neet to install some basic tools.

# update pacman
pacman -Syu

# install a comfortable work environment
pacman -S yaourt zsh grml-zsh-config vim htop lsof strace

# install development tools, needed only for Tor (? check this ?)
#pacman -S base-devel

# install dnsmasq for DHCP on eth0
pacman -S dnsmasq

# Install Tor
pacman -S tor

# install an HTTP proxy, optional
pacman -S polipo

# logrunner & tlsdate both need to be  built :(

## Setup the hardware random number generator
echo "bcm2708-rng" > /etc/modules-load.d/bcm2708-rng.conf
pacman -Sy rng-tools
# Tell rngd to seed /dev/random using the hardware rng
echo 'RNGD_OPTS="-o /dev/random -r /dev/hwrng"' > /etc/conf.d/rngd
systemctl enable rngd

# set the time to UTC, because that's how we roll
rm /etc/localtime
ln -s /usr/share/zoneinfo/UTC /etc/localtime

# set hostname to PORTAL \m/
echo "portal" > /etc/hostname

# This is the config for Tor, lets set it up:
cat > /etc/tor/torrc << __TORRC__
## CONFIGURED FOR ARCHLINUX

## Replace this with "SocksPort 0" if you plan to run Tor only as a
## server, and not make any local application connections yourself.
SocksPort 9050 # port to listen on for localhost connections
# SocksPort 127.0.0.1:9050 # functionally the same as the line above 
SocksPort 172.16.0.1:9050 # listen on a chosen IP/port too

## Allow no-name routers (ones that the dirserver operators don't
## know anything about) in only these positions in your circuits.
## Other choices (not advised) are entry,exit,introduction.
AllowUnverifiedNodes middle,rendezvous

Log notice syslog

DataDirectory /var/lib/tor

## The port on which Tor will listen for local connections from Tor controller
## applications, as documented in control-spec.txt.  NB: this feature is
## currently experimental.
#ControlPort 9051

## Map requests for .onion/.exit addresses to virtual addresses so
## applications can resolve and connect to them transparently.
AutomapHostsOnResolve 1 
## Subnet to automap .onion/.exit address to.
VirtualAddrNetworkIPv4 10.192.0.0/10

## Open this port to listen for transparent proxy connections.
TransPort 172.16.0.1:9040
## Open this port to listen for UDP DNS requests, and resolve them anonymously.
DNSPort 172.16.0.1:9053                                                               

__TORRC__

#
# set up the ethernet
cat > /etc/conf.d/network << __ETHCONF__
interface=eth0
address=172.16.0.1
netmask=24
broadcast=172.16.0.255
__ETHCONF__

cat > /etc/systemd/system/network.service << __ETHRC__
[Unit]
Description=WStatic IP Connectivity
Wants=network.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=/etc/conf.d/network
ExecStart=/sbin/ip link set dev \${interface} up
#ExecStart=/usr/sbin/wpa_supplicant -B -i \${interface} -c /etc/wpa_supplicant.conf # Remove this for wired connections
ExecStart=/sbin/ip addr add \${address}/\${netmask} broadcast \${broadcast} dev \${interface}
#ExecStart=/sbin/ip route add default via \${gateway}
 
ExecStop=/sbin/ip addr flush dev \${interface}
ExecStop=/sbin/ip link set dev \${interface} down

[Install]
WantedBy=multi-user.target
__ETHRC__

systemctl enable network.service

# should already be enabled
systemctl enable ntpd.service

# patch ntp-wait: strange unresolved bug
sed -i 's/$leap =~ \/(sync|leap)_alarm/$sync =~ \/sync_unspec/' /usr/bin/ntp-wait
sed -i 's/$leap =~ \/leap_(none|((add|del)_sec))/$sync =~ \/sync_ntp/' /usr/bin/ntp-wait

cat > /usr/lib/systemd/system/ntp-wait.service << __NTPWAIT__
[Unit]
Description=Wait for Network Time Service to synchronize
After=ntpd.service
Requires=ntpd.service

[Service]
Type=oneshot
ExecStart=/usr/bin/ntp-wait -n 5

[Install]
WantedBy=multi-user.target
__NTPWAIT__

systemctl enable ntp-wait.service

# configure dnsmasq
cat > /etc/dnsmasq.conf << __DNSMASQ__
bogus-priv
filterwin2k
interface=eth0
bind-interfaces

dhcp-range=172.16.0.50,172.16.0.150,12h

# For debugging purposes, log each DNS query as it passes through
# dnsmasq.
# XXX this is actually a good idea, particularly if you want to look for indicators of compromise.
#log-queries
__DNSMASQ__

# enable the dnsmasq daemon
systemctl enable dnsmasq.service

# setup the iptables rules
cat > /etc/iptables/iptables.rules << __IPTABLES__
# Generated by iptables-save v1.4.16.3 on Thu Jan  1 01:24:22 1970
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A PREROUTING -i eth0 -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -j REDIRECT --to-ports 9040
-A PREROUTING -i eth0 -p udp -m udp --dport 53 -j REDIRECT --to-ports 9053
COMMIT
# Completed on Thu Jan  1 01:24:22 1970
# Generated by iptables-save v1.4.16.3 on Thu Jan  1 01:24:22 1970
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [64:3712]
-A INPUT -p icmp -j ACCEPT
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -i eth0 -p tcp -m tcp --dport 9050 -j ACCEPT
-A INPUT -i eth0 -p tcp -m tcp --dport 9040 -j ACCEPT
-A INPUT -i eth0 -p udp -m udp --dport 9053 -j ACCEPT
-A INPUT -i eth0 -p udp -m udp --dport 67 -j ACCEPT
-A INPUT -p tcp -j REJECT --reject-with tcp-reset
-A INPUT -p udp -j REJECT --reject-with icmp-port-unreachable
-A INPUT -j REJECT --reject-with icmp-proto-unreachable
COMMIT
# Completed on Thu Jan  1 01:24:22 1970 ## truf!
__IPTABLES__

systemctl enable iptables.service

# patch tor service: wait for ntpd to synchronize
sed -i 's/After=network.target/After= network.target ntp-wait.service/' /usr/lib/systemd/system/tor.service

# turn on tor, and reboot... it should work. 
systemctl enable tor.service
