#!/bin/bash
# socks_transparent_proxy_setup.sh 
# 2017/7/28

# this script implements tansparent proxy "resocks2" as follows
#                  redsocks2
#                      |
#	     _ _ _ _ _ _ _ _ _ _
#	    |socks load balancer|   
#	     - - - - - - - - - -
#	     /       \         \ 
#    _ _ _ _ _ _    _ _ _ _ _ _
#   |socks proxy|  |socks proxy|   ......
#    - - - - - -    - - - - - -    

set -u

workdir=$(cd $(dirname $0) && pwd)
redsocks2_bin=$workdir/redsocks-release-0.66/redsocks2 
prefix_dir=/usr/local/redsocks2
logdir=$prefix_dir/log
logsavedays=300
# should be local private ip
redsocks_server_ip=192.168.1.254
redsocks_tcp_port=10001
redsocks_udp_port=20001
# socks load balance server or socks proxy server
socks_server="101.19.11.60:1080 12.5.11.27:1080"

cd $workdir

# build redsocks2 first
<<'COMPILE'
yum install libevent2-devel openssl-devel -y
wget https://github.com/semigodking/redsocks/archive/release-0.66.zip
unzip release-0.66
cd redsocks-release-0.66
make -j $(grep -c processor /proc/cpuinfo) 
COMPILE

[ ! -f $redsocks2_bin ] && { echo "err: redsocks2 not exist,build redsocks2 first.";exit 1;}
mkdir -p $prefix_dir
\cp $redsocks2_bin $prefix_dir

cd $prefix_dir

# ------------------------------ redsocks.conf -----------------------------
cat > redsocks.conf <<EOF
base {
        log_debug = off;
        log_info = on;
        //log = stderr;
        log = "file:$prefix_dir/err.log";
        daemon = on;
        redirector = iptables;
}
$(
for ip in $socks_server;do
	server=$(echo $ip|awk -F: '{print $1}')
	port=$(echo $ip|awk -F: '{print $2}')
cat <<COM

redsocks {
        //private ip for redsocks2 server; not set 127.0.0.1 if you set this machine as gateway;
        local_ip = $redsocks_server_ip;
        local_port = $redsocks_tcp_port;
        min_accept_backoff = 100;
        max_accept_backoff = 60000;
        //remote socks proxy server
        ip = $server;
        port = $port;
        type = socks5;
        timeout = 10;
}

redudp {
        // private ip for redsocks2 server;
        local_ip = $redsocks_server_ip;
        local_port = $redsocks_udp_port;
        // remote socks proxy server
        ip = $server;
        port = $port;
        type = socks5;
        udp_timeout = 10;
}
COM
	((redsocks_tcp_port++))
	((redsocks_udp_port++))
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

# Create new chain
iptables -t nat -N REDSOCKS2
iptables -t mangle -N REDSOCKS2
iptables -t mangle -N REDSOCKS2_MARK

# Ignore LANs and some other addresses 
iptables -t nat -A REDSOCKS2 -d 0.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS2 -d 10.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS2 -d 127.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS2 -d 169.254.0.0/16 -j RETURN
iptables -t nat -A REDSOCKS2 -d 172.16.0.0/12 -j RETURN
iptables -t nat -A REDSOCKS2 -d 192.168.0.0/16 -j RETURN
iptables -t nat -A REDSOCKS2 -d 224.0.0.0/4 -j RETURN
iptables -t nat -A REDSOCKS2 -d 240.0.0.0/4 -j RETURN

# ignore your remote socks proxy server's addresses 
iptables -t nat -A REDSOCKS2 -d $(echo $socks_server|egrep -o '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'|xargs |sed 's/ /,/') -j RETURN

# for tcp
for ((i=$(echo $socks_server|xargs -n1|wc -l);i>=1;i--)){
	iptables -t nat -A REDSOCKS2 -p tcp ! --dport 22 -m statistic --mode nth --every $i --packet 0 -j REDIRECT --to-ports $redsocks_tcp_port
	((redsocks_tcp_port++))
}
iptables -t nat -A PREROUTING -p tcp -j REDSOCKS2

# for udp
ip route del local default dev lo table 100
ip rule del fwmark 1 lookup 100
ip route add local default dev lo table 100
ip rule add fwmark 1 lookup 100

for ((i=$(echo $socks_server|xargs -n1|wc -l);i>=1;i--)){
	iptables -t mangle -A REDSOCKS2 -p udp -m multiport --dports 1:10000 -m statistic --mode nth --every $i --packet 0 -j TPROXY --on-port $redsocks_udp_port --tproxy-mark 1
	((redsocks_udp_port++))
}
iptables -t mangle -A PREROUTING -p udp -j REDSOCKS2
iptables -t mangle -A REDSOCKS2_MARK -p udp -m multiport --dports 1:10000 -j MARK --set-mark 1
iptables -t mangle -A OUTPUT -p udp -j REDSOCKS2_MARK

# log
iptables -t nat -I PREROUTING -j LOG --log-prefix 'IPTABLES_LOG:' --log-level debug
iptables -t nat -I POSTROUTING -j LOG --log-prefix 'IPTABLES_LOG:' --log-level debug

# iptables-save
iptables-save > /etc/sysconfig/iptables

# set iptables log 
mkdir -p $logdir
grep -q '^kern\.\*' /etc/rsyslog.conf &&
    sed -i "s#^kern\.\*.*#kern.* $logdir/access.log#" /etc/rsyslog.conf ||
        echo "kern.* $logdir/access.log" >>/etc/rsyslog.conf
/etc/init.d/rsyslog restart

cat >$logdir/logrotate.sh<<EOF
#!/bin/bash
# log rotate
/bin/mv $logdir/access.log{,.\$(/bin/date +%Y%m%d)} 
/etc/init.d/rsyslog reload
/bin/find $logdir -type f -mtime $logsavedays -exec rm -f {} \; 
exit 0
EOF

chmod u+x $logdir/logrotate.sh
grep -q "$logdir/logrotate.sh" /var/spool/cron/root || echo "0 0 * * * $logdir/logrotate.sh" >>/var/spool/cron/root


# --------------------------- redsocks.service ------------------
((redsocks_tcp_port--))
((redsocks_udp_port--))

cat > redsocks2.service <<EOF
#!/bin/bash

. /etc/init.d/functions

start(){
    /etc/init.d/iptables start
    ps aux|egrep -v "grep|\$0" |grep -q redsocks2 && { 
        echo -n "redsocks2 already started";failure;echo;} || {
            $prefix_dir/redsocks2 -c $prefix_dir/redsocks.conf && { echo -n "redsocks2 started";success;echo;}
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
    iptables -t nat -nvL|egrep -q "REDIRECT.*$redsocks_tcp_port" && 
        echo "iptables for tcp redirect is ok" || 
            echo "iptables for tcp redirect is err"
    iptables -t mangle -nvL|egrep -q "TPROXY.*$redsocks_udp_port" && 
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


exit 0
