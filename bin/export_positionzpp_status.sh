#!/bin/sh

#set -x

echo "Stopping positionzpp service"
sudo -u positionzpp_server positionzpp stop
echo "*********** Make sure it gets restarted!"

rundate=`date +"%Y-%m-%d"`
pids=`( positionzpp status | grep "^${rundate} .*started" | sed 's/.*PID *//' )`

while : ; do
    running=0
    for p in $pids; do
        if ps -p $p > /dev/null; then
            running=1
            break
        fi
    done
    echo "PIDS: ${pids} running: $running"
    if [ $running = 0 ]; then
        break
    fi
    echo "Waiting for processes to stop ..."
    sleep 10
done

runtime=`date +"%Y%m%d%H%M%S"`
exportfile=positionzpp_status_${runtime}.tgz

tar -Pcvzf $exportfile /var/log/positionpp /var/lib/positionzpp/data /var/lib/positionzpp/archive /var/lib/positionzpp/statistics /var/lib/positionzpp/work

echo "Restarting positionzpp service"
sudo -u positionzpp_server positionzpp start

echo "Positionzpp status exported to $exportfile"
