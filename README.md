应用场景
========

把`redsocks2`部署在网关服务器, 让用户无感知使用`socks5`代理上网, 即透明代理.    
网关服务器需要同时有`内网IP`和`外网IP`.

`redsocks2`的作用是将用户的数据包封装上`socks5`头,
然后传递给后端`socks5`代理服务器(也可以是`socks5`代理负载均衡器, 可用`nginx`或`iptables`实现).

`TCP`和`UDP`均可很好的支持.


安装步骤
========

1. 提前编译好`redsocks2`可执行文件
```bash
yum install libevent2-devel openssl-devel -y
wget https://github.com/semigodking/redsocks/archive/release-0.66.zip
unzip release-0.66
cd redsocks-release-0.66
make -j $(grep -c processor /proc/cpuinfo)
```

2. 根据实际情况修改`src/transparent_socks5proxy_redirector_setup.sh`前置的几个变量
```bash
# 安装路径
prefix_dir=/usr/local/redsocks2

# 用户访问日志路径
logdir=$prefix_dir/log

# 日志保留时间
logsavedays=300

# redsocks2安装在的服务器内网IP, 此处一定不能为127.0.0.1, 公网IP不安全也不考虑
redsocks_server_ip=192.168.1.254

# redsocks2用于接收TCP包的监听端口
redsocks_tcp_port=10001

# redsocks2用于接收UDP包的监听端口
redsocks_udp_port=20001

# redsocks2将封装后的数据包转发给后端的socks5代理服务器列表/socks5代理负载均衡器/tcp转发器), 
# 可以是一个, 多个的话使用空格分隔
socks_server="101.19.11.60:1080 12.5.11.27:1080"
```

3. 执行安装脚本
```bash
bash transparent_socks5proxy_redirector_setup.sh
```


使用说明
========

安装后的默认路径为: `/usr/local/redsocks2/`, 目录中相关文件说明如下:

- `redsocks2`    
redsocks2程序

- `redsocks2.service`    
整个服务的启动、关闭、重启、状态查看脚本

- `redsocks.conf`    
`redsocks2`的配置文件

- `log/access.log`    
用户访问的日志

- `log/logrotate.sh`    
用户日志每日轮转脚本

- `err.log`    
`redsocks2`的debug日志


启用服务:  
```bash
./redsocks2.service start
```
