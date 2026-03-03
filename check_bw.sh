#!/bin/bash

# Формат: "HOST PORT THREADS MODE"
# Всюди встановлено 100 потоків (-P 100)
SERVERS=(
    # Ваші обов'язкові сервери
    "ping.online.net 5200 100 -R"
    "ping.online.net 5201 100 -R"
    "iperf3.moji.fr 5200 100 -R"
    "iperf3.moji.fr 5202 100 -R"
    "iperf-ams-nl.eranium.net 5201 100 -R"
    "lg.gigahost.no 9201 100 -R"           # 100G Norway
    "speedtest.nocix.net 5201 100 -R"      # 200G USA
    "dfw.speedtest.is.cc 5202 100 -R"      # 100G USA
    "speedtest.milkywan.fr 9200 100 -R"
    "iperf-ams.vsys.host 5201 100 -R"
    "iperf.vsys.host 5201 100 -R"
    "iperf-sin1.vsys.host 5201 100 -R"
    "paris.bbr.iperf.bytel.fr 9200 100 -R"

    # Потужні сервери (EUROPE 10-100G)
    "t5.cscs.ch 5201 100 -R"               # 100G Zurich
    "iperf-ams-nl.eranium.net 5201 100 -R" # 100G Amsterdam
    "lg.gigahost.no 9201 100 -R"           # 100G Norway
    "iperf.online.net 5202 100 -R"         # 100G France
    "a110.speedtest.wobcom.de 5201 100 -R" # 25G Germany
    "speed1.fiberby.dk 9201 100 -R"        # 25G Denmark
    "speedtest.wtnet.de 5200 100 -R"       # 40G Germany
    "speedtest.nl1.mirhosting.net 5201 100 -R" # 40G Netherlands
    "speed.cosmonova.net 5201 100 -R"      # 40G Ukraine
    "lg.terrahost.com 9200 100 -R"         # 10G Norway
    "speed2.fiberby.dk 9202 100 -R"        # 25G Denmark
    
    # USA
    "dfw.speedtest.is.cc 5202 100 -R"      # 100G Dallas
    "speedtest.nocix.net 5201 100 -R"      # 200G Kansas
    "ash.speedtest.clouvider.net 5201 100 -R" # 10G Ashburn
    "la.speedtest.clouvider.net 5201 100 -R"  # 10G LA
)

echo "--- Запуск мульти-тесту iperf3 (100 потоків на сервер) ---"
trap 'kill $(jobs -p); exit' SIGINT

for s in "${SERVERS[@]}"; do
    read -r host port parallel mode <<< "$s"

    # Швидка перевірка порту
    if timeout 1 bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null; then
        echo "[ OK ] Запуск: $host:$port ($parallel потоків)"
        iperf3 -c "$host" -p "$port" -P "$parallel" $mode -i 0 > /dev/null &
    else
        echo "[SKIP] Сервер недоступний: $host:$port"
    fi
done

echo "-------------------------------------------------------"
echo "Активні тести працюють. Дивіться навантаження:"
echo "nload bond0"
echo "-------------------------------------------------------"

wait
