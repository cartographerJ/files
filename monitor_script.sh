#!/bin/bash

apt-get update && apt-get upgrade
apt-get install -y curl

CLOUDRUN_URL="https://pushgateway-pndkcp73qq-uc.a.run.app"

CLOUDRUN_TOKEN=$(curl "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=https://pushgateway-pndkcp73qq-uc.a.run.app" \
-H "Metadata-Flavor: Google")

declare -a TEMP=$(mktemp /temp_monitoring.XXXXXXXX)

if [[ -z "${BACKEND}" ]]; then
        backend=""
else
        backend=${BACKEND}
fi

function get_disk_info() {
        # df command and cromwell root field
        if [ "$backend" = "aws" ]; then
                df | grep '/$'
        else
                df | grep cromwell_root
        fi
}

function get_disk_usage() {
        # get disk usage field
        get_disk_info | awk '{ print $5 }'
}

function get_mem_info() {
        # /proc/meminfo
        cat /proc/meminfo
}

function get_mem_available() {
        # mem unused from /proc/meminfo
        get_mem_info | grep MemAvailable | awk 'BEGIN { FS=" " } ; { print $2 }'
}

function get_mem_total() {
        # mem total from /proc/meminfo
        get_mem_info | grep MemTotal | awk 'BEGIN { FS=" " } ; { print $2 }'
}

function get_mem_usage() {
        # memTotal and memAvailable
        local -r mem_total=$(get_mem_total)
        local -r mem_available=$(get_mem_available)

        # usage = 100 * mem_used / mem_total
        local -r mem_used=$(($mem_total - $mem_available))
        echo "$mem_used" "$mem_total" | awk '{ print ($1/$2) }'
}

function get_cpu_info() {
        # cpu info from /proc/stat
        cat /proc/stat | grep "cpu "
}

function get_cpu_total() {
        # get the total cpu usage since a given time (including idle and iowait)
        # user+nice+system+idle+iowait+irq+softirq+steal
        get_cpu_info | awk 'BEGIN { FS=" " } ; { print $2+$3+$4+$5+$6+$7+$8+$9 }'
}

function get_cpu_used() {
        # get the cpu usage since a given time (w/o idle or iowait)
        # user+nice+system+irq+softirq+steal
        get_cpu_info | awk 'BEGIN { FS=" " } ; { print $2+$3+$4+$7+$8+$9 }'
}

function get_cpu_usage() {
        # get the cpu usage since a given time (w/o idle or iowait)
        # user+nice+system+irq+softirq+steal
        local -r cpu_used_cur=$(get_cpu_used)

        # get the total cpu usage since a given time (including idle and iowait)
        # user+nice+system+idle+iowait+irq+softirq+steal
        local -r cpu_total_cur=$(get_cpu_total)

        # read in previous cpu usage values
        read -r -a cpu_prev <${TEMP}
        local -r cpu_used_prev=${cpu_prev[0]}
        local -r cpu_total_prev=${cpu_prev[1]}

        # save current values as prev values for next iteration
        cpu_prev[0]=$cpu_used_cur
        cpu_prev[1]=$cpu_total_cur
        echo "${cpu_prev[@]}" >${TEMP}

        # usage = 100 * (cpu_used_cur - cpu_used_prev) / (cpu_total_cur-cpu_total_prev)
        echo "$cpu_used_cur" "$cpu_used_prev" "$cpu_total_cur" "$cpu_total_prev" | awk 'BEGIN {FS=" "} ; { print (($1-$2)/($3-$4)) }'

}

function print_usage() {
local USAGE
USAGE=$(cat <<EOF | curl -s -H "Authorization: Bearer $CLOUDRUN_TOKEN" --data-binary @- $CLOUDRUN_URL/metrics/job/$2/instance/$1
# HELP cpu_usage is the cpu_usage over time, from a specific sample workflow.
# TYPE cpu_usage gauge
cpu_usage{sample="$1"} $(get_cpu_usage)
# HELP memory_usage is the memory usage over time, from a specific sample workflow.
# TYPE memory_usage gauge
memory_usage{sample="$1"} $(get_mem_usage)
# HELP cpu_cores is the number of the cores attached to this CPU during the workflow.
# TYPE cpu_cores gauge
cpu_cores{sample="$1"} $(nproc)
# HELP memory_total is the total memory attached to this specific sample workflow.
# TYPE memory_total gauge
memory_total{sample="$1"} $(echo $(get_mem_total) 1000000 | awk '{ print $1/$2 }')
EOF
)
echo $USAGE
}
#disk_usage{sample="$1"} $(get_disk_usage)
#disk_total{sample="$1"} $(df -h | grep cromwell_root | awk '{ print $2}')
# $(date -u +%s)

declare -a cpu_prev
cpu_prev[0]=$(get_cpu_used)
cpu_prev[1]=$(get_cpu_total)
echo "${cpu_prev[@]}" >${TEMP}

if [ -z "$MONITOR_SCRIPT_SLEEP" ]; then
        MONITOR_SCRIPT_SLEEP=10
fi

sleep "$MONITOR_SCRIPT_SLEEP"
while true; do
        print_usage $1 $2
        sleep "$MONITOR_SCRIPT_SLEEP"
        CLOUDRUN_TOKEN=$(curl "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=https://pushgateway-pndkcp73qq-uc.a.run.app" \
-H "Metadata-Flavor: Google")
done

