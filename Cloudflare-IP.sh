#!/bin/bash

[[ ! -d "/root/cloudflare" ]] && mkdir -p /root/cloudflare
cd /root/cloudflare

# opkg update
# opkg install jq

# arch=$(uname -m)
# if [[ ${arch} =~ "x86" ]]; then
#       tag="amd"
#       [[ ${arch} =~ "64" ]] && tag="amd64"
# elif [[ ${arch} =~ "aarch" ]]; then
#       tag="arm"
#       [[ ${arch} =~ "64" ]] && tag="arm64"
# else
#       exit 1
# fi

# version=$(curl -s https://api.github.com/repos/XIU2/CloudflareSpeedTest/tags | jq -r .[].name | head -1)

# if [[ ! -f "CloudflareST" ]]; then
#       rm -rf CloudflareST_linux_${tag}.tar.gz
#       wget -N https://mirror.ghproxy.com/https://github.com/XIU2/CloudflareSpeedTest/releases/download/${version}/CloudflareST_linux_${tag}.tar.gz
#       echo "${version}" > CloudflareST_version.txt
#       tar -xvf CloudflareST_linux_${tag}.tar.gz
#       chmod +x CloudflareST
# fi

if [ ! -f /etc/smartdns/conf.d/cloudflare-ipv4.txt ]; then
        wget https://www.cloudflare.com/ips-v4 -O /etc/smartdns/conf.d/cloudflare-ipv4.txt
fi

if [ ! -f /etc/smartdns/conf.d/cloudflare-ipv6.txt ]; then
        wget https://www.cloudflare.com/ips-v6 -O /etc/smartdns/conf.d/cloudflare-ipv6.txt
fi

./CloudflareST -dn 10 -tll 40 -f /etc/smartdns/conf.d/cloudflare-ipv4.txt -o cf_result-ipv4.txt -url https://cdn.cloudflare.steamstatic.com/steam/apps/5952/movie_max.webm
wait
sleep 3
./CloudflareST -dn 10 -tll 40 -f /etc/smartdns/conf.d/cloudflare-ipv6.txt -o cf_result-ipv6.txt -url https://cdn.cloudflare.steamstatic.com/steam/apps/5952/movie_max.webm
wait
sleep 3

if [[ -f "cf_result-ipv4.txt" ]]; then
        first_dig=$(dig cloudflare.182682.xyz A +short @223.5.5.5 | sed -n "2p" | egrep -o "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}")
        second_dig=$(dig cloudflare.182682.xyz A +short @119.29.29.29 | sed -n "3p" | egrep -o "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}")
        first=$(sed -n '2p' cf_result-ipv4.txt | awk -F ',' '{print $1}' | egrep -o "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}") && echo $first >ipv4.txt
        second=$(sed -n '3p' cf_result-ipv4.txt | awk -F ',' '{print $1}' | egrep -o "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}") && echo $second >>ipv4.txt
        third=$(sed -n '4p' cf_result-ipv4.txt | awk -F ',' '{print $1}' | egrep -o "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}") && echo $third >>ipv4.txt
        if [ ! -n ${first} ] || [ ! -n ${second} ] || [ ! -n ${third} ] || [ ! -n ${first_dig} ] || [ ! -n ${second_dig} ]; then
                echo "变量不存在，退出"
                exit 1
        fi
        echo "ip-rules ip-set:cloudflare-ipv4 -ip-alias ${first_dig},${second_dig},${first},${second},${third}" > /etc/smartdns/conf.d/cloudflare-ipv4
fi
if [[ -f "cf_result-ipv6.txt" ]]; then
        first_dig=$(dig cloudflare.182682.xyz AAAA +short @223.5.5.5 | sed -n "2p" | egrep -o "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}")
        second_dig=$(dig cloudflare.182682.xyz AAAA +short @119.29.29.29 | sed -n "3p" | egrep -o "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}")
        first=$(sed -n '2p' cf_result-ipv6.txt | awk -F ',' '{print $1}' | egrep -o "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}") && echo $first >ipv6.txt
        second=$(sed -n '3p' cf_result-ipv6.txt | awk -F ',' '{print $1}' | egrep -o "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}") && echo $second >>ipv6.txt
        third=$(sed -n '4p' cf_result-ipv6.txt | awk -F ',' '{print $1}' | egrep -o "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}") && echo $third >>ipv6.txt
        if [ ! -n ${first} ] || [ ! -n ${second} ] || [ ! -n ${third} ] || [ ! -n ${first_dig} ] || [ ! -n ${second_dig} ]; then
                echo "变量不存在，退出"
                exit 1
        fi
        echo "ip-rules ip-set:cloudflare-ipv6 -ip-alias ${first_dig},${second_dig},${first},${second},${third}" > /etc/smartdns/conf.d/cloudflare-ipv6
fi

/etc/init.d/smartdns restart