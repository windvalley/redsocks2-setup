#!/bin/bash
# transparent_socks5proxy_redirector_setup.sh
# 2017/7/28

# this script implements a {tansparent redirector} as follow architecture,
# that encapsulate TCP/UDP packets with socks5 header and then redirect them to socks5 proxy servers.
#
#         {transparent redirector}
#                     |
#        _ _ _ _ _ _ _ _ _
#       |tcp load balancer|
#        - - - - - - - - -
#       /       \         \
#    _ _ _ _ _ _   _ _ _ _ _ _
#   |socks5proxy| |socks5proxy|  ......
#    - - - - - -   - - - - - -

set -u


WORKDIR=$(cd $(dirname $0) && pwd)
REDSOCKS2_BIN=$WORKDIR/redsocks-release-0.66/redsocks2
PREFIX_DIR=/usr/local/redsocks2
LOGDIR=$PREFIX_DIR/log
LOG_SAVE_DAYS=300

# should be local private ip
REDSOCKS_SERVER_IP=192.168.1.254
REDSOCKS_TCP_PORT=10001
REDSOCKS_UDP_PORT=20001
# socks load balance server or socks proxy server
SOCKS_SERVER="101.19.11.60:1080 12.5.11.27:1080"


cd $WORKDIR


# build redsocks2 first
<<'COMPILE'
yum install libevent2-devel openssl-devel -y
wget https://github.com/semigodking/redsocks/archive/release-0.66.zip
unzip release-0.66
cd redsocks-release-0.66
make -j $(grep -c processor /proc/cpuinfo)
COMPILE


[[ ! -f $REDSOCKS2_BIN ]] && {
    echo "err: redsocks2 not exist,build redsocks2 first."
    exit 1
}

mkdir -p $PREFIX_DIR
\cp $REDSOCKS2_BIN $PREFIX_DIR

cd $PREFIX_DIR

# ------------------------------ redsocks.conf -----------------------------
cat > redsocks.conf <<EOF
base {
        log_debug = off;
        log_info = on;
        //log = stderr;
        log = "file:$PREFIX_DIR/err.log";
        daemon = on;
        redirector = iptables;
}

$(
    for server in $SOCKS_SERVER;do
        ip=$(echo $server|awk -F: '{print $1}')
        port=$(echo $server|awk -F: '{print $2}')
        cat <<COM
redsocks {
        //private ip for redsocks2 server; not set 127.0.0.1 if you set this machine as gateway;
        local_ip = $REDSOCKS_SERVER_IP;
        local_port = $REDSOCKS_TCP_PORT;
        min_accept_backoff = 100;
        max_accept_backoff = 60000;
        //remote socks proxy server
        ip = $ip;
        port = $port;
        type = socks5;
        timeout = 10;
}

redudp {
        // private ip for redsocks2 server;
        local_ip = $REDSOCKS_SERVER_IP;
        local_port = $REDSOCKS_UDP_PORT;
        // remote socks proxy server
        ip = $ip;
        port = $port;
        type = socks5;
        udp_timeout = 10;
}
COM
        ((REDSOCKS_TCP_PORT++))
        ((REDSOCKS_UDP_PORT++))
    done
)

EOF

# ----------------------- iptables --------------------------

# clean iptables
iptables -F
iptables -Z
iptables -X
iptables -t nat -F
iptables -t nat -Z
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -Z
iptables -t mangle -X

# create new chain
iptables -t nat -N REDSOCKS2
iptables -t mangle -N REDSOCKS2
iptables -t mangle -N REDSOCKS2_MARK

# ignore LANs and some other addresses
iptables -t nat -A REDSOCKS2 -d 0.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS2 -d 10.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS2 -d 127.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS2 -d 169.254.0.0/16 -j RETURN
iptables -t nat -A REDSOCKS2 -d 172.16.0.0/12 -j RETURN
iptables -t nat -A REDSOCKS2 -d 192.168.0.0/16 -j RETURN
iptables -t nat -A REDSOCKS2 -d 224.0.0.0/4 -j RETURN
iptables -t nat -A REDSOCKS2 -d 240.0.0.0/4 -j RETURN

# ignore local addresses
iptables -t nat -A REDSOCKS2 -d $(ifconfig |awk '/inet addr/{print $2}'|
    awk -F: '{print $2}'|xargs  |sed 's/ /,/g') -j RETURN

# ignore your remote socks proxy server's addresses
iptables -t nat -A REDSOCKS2 -d $(echo $SOCKS_SERVER|
    egrep -o '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'|xargs |sed 's/ /,/') -j RETURN

# for tcp
for ((i=$(echo $SOCKS_SERVER|xargs -n1|wc -l);i>=1;i--)){
	iptables -t nat -A REDSOCKS2 -p tcp -m statistic --mode nth --every $i \
        --packet 0 -j REDIRECT --to-ports $REDSOCKS_TCP_PORT
	((REDSOCKS_TCP_PORT++))
}

iptables -t nat -A PREROUTING -p tcp -j REDSOCKS2

# for udp
ip route del local default dev lo table 100
ip rule del fwmark 1 lookup 100
ip route add local default dev lo table 100
ip rule add fwmark 1 lookup 100

for ((i=$(echo $SOCKS_SERVER|xargs -n1|wc -l);i>=1;i--)){
	iptables -t mangle -A REDSOCKS2 -p udp -m multiport --dports 1:10000 \
        -m statistic --mode nth --every $i --packet 0 \
        -j TPROXY --on-port $REDSOCKS_UDP_PORT --tproxy-mark 1
	((REDSOCKS_UDP_PORT++))
}
iptables -t mangle -A PREROUTING -p udp -j REDSOCKS2
iptables -t mangle -A REDSOCKS2_MARK -p udp -m multiport --dports 1:10000 \
    -j MARK --set-mark 1
iptables -t mangle -A OUTPUT -p udp -j REDSOCKS2_MARK

# log
iptables -t nat -I PREROUTING -j LOG --log-prefix 'IPTABLES_LOG:' --log-level debug
iptables -t nat -I POSTROUTING -j LOG --log-prefix 'IPTABLES_LOG:' --log-level debug

# iptables-save
iptables-save > /etc/sysconfig/iptables

# set iptables log
mkdir -p $LOGDIR
grep -q '^kern\.\*' /etc/rsyslog.conf &&
    sed -i "s#^kern\.\*.*#kern.* $LOGDIR/access.log#" /etc/rsyslog.conf ||
        echo "kern.* $LOGDIR/access.log" >>/etc/rsyslog.conf
/etc/init.d/rsyslog restart

cat >$LOGDIR/logrotate.sh<<EOF
#!/bin/bash
# log rotate
/bin/mv $LOGDIR/access.log{,.\$(/bin/date +%Y%m%d)}
/etc/init.d/rsyslog reload
/bin/find $LOGDIR -type f -mtime $LOG_SAVE_DAYS -exec rm -f {} \;
exit 0
EOF

chmod u+x $LOGDIR/logrotate.sh
grep -q "$LOGDIR/logrotate.sh" /var/spool/cron/root ||
    echo "0 0 * * * $LOGDIR/logrotate.sh" >>/var/spool/cron/root


# --------------------------- redsocks.service ------------------
((REDSOCKS_TCP_PORT--))
((REDSOCKS_UDP_PORT--))

cat > redsocks2.service <<EOF
#!/bin/bash

. /etc/init.d/functions

start(){
    /etc/init.d/iptables start
    ps aux|egrep -v "grep|\$0" |grep -q redsocks2 && {
        echo -n "redsocks2 already started";failure;echo;} || {
            $PREFIX_DIR/redsocks2 -c $PREFIX_DIR/redsocks.conf && { echo -n "redsocks2 started";success;echo;}
        }
}

stop(){
    /etc/init.d/iptables stop
    killall redsocks2 2>/dev/null && { echo -n "redsocks2 stopped.";success;echo;} || {
        echo -n "redsocks2 already stopped.";failure;echo;}
}

status(){
    ps axu|egrep -v "grep|\$0" |grep -q redsocks2 &&
        echo "redsocks2 is running..."||
            echo "redsocks2 has stopped."
    iptables -t nat -nvL|egrep -q "REDIRECT.*$REDSOCKS_TCP_PORT" &&
        echo "iptables for tcp redirect is ok" ||
            echo "iptables for tcp redirect is err"
    iptables -t mangle -nvL|egrep -q "TPROXY.*$REDSOCKS_UDP_PORT" &&
        echo "iptables for udp redirect is ok" ||
            echo "iptables for udp redirect is err"
}

case \$1 in
    start) start
        ;;
    stop) stop
        ;;
    restart) stop;start
        ;;
    status) status
        ;;
    *) echo "Usage:\$0 <start|stop|restart|status>"
        ;;
esac

exit 0
EOF

chmod u+x redsocks2.service

echo "SETUP SUCCESS!
Use $PREFIX_DIR/redsocks2.service to manage the server:
$PREFIX_DIR/redsocks2.service <start|stop|restart|status>
"

exit 0
