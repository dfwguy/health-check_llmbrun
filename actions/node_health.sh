#!/bin/bash
# BCM finalize script: run local health checks, aggregate output into a "reason"
# # string, then drain this node in Slurm with that reason.

## use if categories are used
#[[ "$CMD_CATEGORY" == "spcx-hosts" ]] || exit 0

source /etc/profile.d/modules.sh
module load slurm

state=$(sinfo -N -n "$HOSTNAME" -h -o '%T')
if [[ -z "$state" ]]
then
        exit 0
fi

reason=""


#scontrol update NodeName="${$HOSTNAME}" State=DOWN Reason="test"

## Create valid-config/default by using "ln -s {target} default
valid_health="/opt/llmb-bringup/valid-config/default/"
#valid_health="/cm/shared/apps/bringup/valid-config/air-test/"
node_health="/opt/llmb-bringup/logs/$HOSTNAME/"

## use to gather env data as seen from script
#env > $node_health/script-env


if [[ -d $node_health ]];
then
	if [[ ! -f $node_health/refresh ]];
	then
		exit 0
	else
		rm $node_health/refresh
	fi
fi

mkdir -p $node_health


append_reason() {
  local header="$1"
  local content="$2"

  # Always add the header
  reason+=$'\n'"${header}"

  # Add content or a placeholder if empty
  if [[ -n "$content" ]]; then
    reason+=$'\n'"${content}"
  else
    reason+=$'\n'"(no output)"
  fi
}

#echo -e "\n########INFO: NODE=$(hostname)" > $node_health

echo -e "########INFO: Check BIOS" > $node_health/bios
bios_out=$(
  grep -r . /sys/class/dmi/id/bios_* 2>/dev/null | cut -d'/' -f6- | sort | paste -s -d','
)
echo "${bios_out}" >> $node_health/bios
if ! diff "$node_health/bios" "$valid_health/bios" > /dev/null
then
	append_reason "Check BIOS" " "
fi

echo -e "########INFO: Check OS" > $node_health/os
os_out=$(
  uname -r
  df -Th | grep /cm/node-installer &>/dev/null || echo 'OS is READY'
)
echo "${os_out}" >> $node_health/os
if ! diff "$node_health/os" "$valid_health/os" > /dev/null
then
	append_reason "os" " "
fi
#append_reason "Check OS" "${os_out}"

echo -e "########INFO: Check Kernel Parm" > $node_health/kernel-params
kernel_parm_out=$(
  uname -r
  cat /proc/cmdline | tr ' ' '\n' | grep -v -E 'ip=|BOOT' | sort | paste -s -d' '
)
echo "${kernel_parm_out}" >> $node_health/kernel-params
if ! diff "$node_health/kernel-params" "$valid_health/kernel-params" > /dev/null
then
	append_reason "kernel-params" " "
fi

echo -e "########INFO: Check CPU" > $node_health/cpu-specs
cpu_out=$(
  lscpu | awk '/Architecture:/,/L3 cache:/{print $0}' | grep -E -v 'GHz|MHz|BogoMIPS|Flags:|cache:'
)
echo "${cpu_out}" >> $node_health/cpu-specs
if ! diff "$node_health/cpu-specs" "$valid_health/cpu-specs" > /dev/null
then
	append_reason "cpu-specs" " "
fi

echo -e "########INFO: Check CPU Frequency (Expected: CPUs are in performance mode and frequency all above 1800 MHz)" > $node_health/cpu-freq
cpu_freq_out=$(
  if [ -f /sys/devices/system/cpu/cpufreq/policy0/scaling_governor ]; then
    cat /sys/devices/system/cpu/cpufreq/policy*/scaling_governor | sort | uniq -c
  else
    echo "CPU frequency scaling not supported" 
  fi

  if [ "$(uname -m)" == x86_64 ]; then
    cpupower monitor -m Mperf | awk '/Mperf/,/^$/{print $0}' | grep -v -e Mperf -e Freq \
      | awk -F '|' '{print $1,$NF}' | sort -n \
      | awk '{
          key=$1; val=$2;
          sum[key]+=val; count[key]++
        } END {
          for (k in sum) {
            avg=sum[k]/count[k];
            status=(avg > 1800 ? "PASS" : "FAIL");
            printf "CPU Freq: Socket%s %s\n", k, status
          }
        }' | paste -s -d','
  fi

  if [ "$(uname -m)" == aarch64 ]; then
    m=
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_cur_freq ]; then
      m=cpuinfo_cur_freq
    elif [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
      m=scaling_cur_freq
    fi
    if [ -n "${m}" ]; then
      for i in $(ls -1 /sys/devices/system/node | grep node | sed -e 's:node::g'); do
        cat /sys/devices/system/node/node${i}/cpu*/cpufreq/$m 2>/dev/null \
        | awk -v node=$i 'BEGIN{sum=0}{
            sum+=$1
          } END {
            if (NR>0) {
              ret=int(sum/NR/1000);
              if (ret>1800) {
                printf "%s freq PASS\n", node
              } else {
                printf "%s freq FAILED\n", node
              }
            }
          }'
      done
    else
      echo "CPU frequency info not available"
    fi
  fi
)
echo "${cpu_freq_out}" >> $node_health/cpu-freq
if ! diff "$node_health/cpu-freq" "$valid_health/cpu-freq" > /dev/null
then
	append_reason "cpu-freq" " "
fi

echo -e "########INFO: Check Memory" > $node_health/memory
memory_out=$(
  dmidecode -t memory | grep -P '\tVolatile Size:' | tr -d '\t' | sort | uniq -c
)
echo "${memory_out}" >> $node_health/memory
if ! diff "$node_health/memory" "$valid_health/memory" > /dev/null
then
	append_reason "memory" " "
fi

echo -e "########INFO: Check NUMA_BALANCING and THP (Expected: NUMA_BALANCING=0 and THP=madvise)" > $node_health/numa-settings
numa_thp_out=$(
  sysctl kernel.numa_balancing
  cat /sys/kernel/mm/transparent_hugepage/enabled
)
echo "${numa_thp_out}" >> $node_health/numa-settings
if ! diff "$node_health/numa-settings" "$valid_health/numa-settings" > /dev/null
then
	append_reason "numa-settings" " "
fi

echo -e "########INFO: Check NUMA" > $node_health/numa
numa_out=$(
  numactl -H | grep size: | grep -v ' 0 MB' \
    | awk '{print "N"$2"="int($(NF-1)/1000)"GB"}' | paste -s -d','
)
echo "${numa_out}" >> $node_health/numa
if ! diff "$node_health/numa" "$valid_health/numa" > /dev/null
then
	append_reason "numa" " "
fi

echo -e "########INFO: Check GPU basic" > $node_health/nvidia-smi-ecc
gpu_basic_out=$(
  nvidia-smi --format=csv \
    --query-gpu gpu_bus_id,gpu_name,vbios_version,pstate,enforced.power.limit,\
ecc.errors.uncorrected.aggregate.total,remapped_rows.failure,remapped_rows.uncorrectable,remapped_rows.pending
)
echo "${gpu_basic_out}" >> $node_health/nvidia-smi-ecc
if ! diff "$node_health/nvidia-smi-ecc" "$valid_health/nvidia-smi-ecc" > /dev/null
then
	append_reason "nvidia-smi-ecc" " "
fi

echo -e "#########INFO: Check NVLINK status (Expected: 72 links are up)" > $node_health/nvlinks
nvlink_status_out=$(
  nvidia-smi nvlink -s | grep '5[0-9].* GB/s' | wc -l
  nvidia-smi --format=csv --query-gpu gpu_bus_id,fabric.state,fabric.status
)
echo "${nvlink_status_out}" >> $node_health/nvlinks
if ! diff "$node_health/nvlinks" "$valid_health/nvlinks" > /dev/null
then
	append_reason "nvlinks" " "
fi

echo -e "#########INFO: Check NVLINK BER (Expected: no output)" > $node_health/nvlink-ber
nvlink_ber_out=$(
  nvidia-smi nvlink -e | grep BER | grep -v 15e-255 || true
)
echo "${nvlink_ber_out}" >> $node_health/nvlink-ber
if ! diff "$node_health/nvlink-ber" "$valid_health/nvlink-ber" > /dev/null
then
	append_reason "nvlink-ber" " "
fi

echo -e "#########INFO: Check P2P nvlink capability status (Expected: All GPU are OK on GBXX/BXX/HXX)" > $node_health/nvidia-smi-p2p-nvlink
p2p_nvlink_out=$(
  nvidia-smi topo -p2p n 2>&1 | grep GPU[0-9].*OK || true
)
echo "${p2p_nvlink_out}" >> $node_health/nvidia-smi-p2p-nvlink
if ! diff "$node_health/nvidia-smi-p2p-nvlink" "$valid_health/nvidia-smi-p2p-nvlink" > /dev/null
then
	append_reason "nvidia-smi-p2p-nvlink" " "
fi

echo -e "#########INFO: Check P2P pcie capability status (Expected: All GPU are OK on RTX/L20)" > $node_health/nvidia-smi-p2p-pcie
p2p_pcie_out=$(
  nvidia-smi topo -p2p p 2>&1 | grep GPU[0-9].*OK || true
)
echo "${p2p_pcie_out}" >> $node_health/nvidia-smi-p2p-pcie
if ! diff "$node_health/nvidia-smi-p2p-pcie" "$valid_health/nvidia-smi-p2p-pcie" > /dev/null
then
	append_reason "nvidia-smi-p2p-pcie" " "
fi

echo -e "########INFO: Check CUUID (Expected: For GBXX, all nodes in the same rack have the same CUUID)" > $node_health/nvidia-smi-cuuid
cuuid_out=$(
  nvidia-smi -q | grep -E 'Bus Id|CliqueId|ClusterUUID'
)
echo "${cuuid_out}" >> $node_health/nvidia-smi-cuuid
if ! diff "$node_health/nvidia-smi-cuuid" "$valid_health/nvidia-smi-cuuid" > /dev/null
then
	append_reason "cuuid" " "
fi

echo -e "########INFO: Check IB devices status (Expected: All up and active)" > $node_health/ib-status
ib_status_out=$(
  ibstatus | grep -E 'Infiniband|state:' | paste - - - | sort -t'_' -k2n
)
echo "${ib_status_out}" >> $node_health/ib-status
if ! diff "$node_health/ib-status" "$valid_health/ib-status" > /dev/null
then
	append_reason "ib-status" " "
fi

echo -e "########INFO: Check IB Link Down status (Expected: No issue found)" > $node_health/ib-down
# Bypass those 4 ports IB HCA is connected to nvswitch on B200/B300.
ib_link_down_status_out=$(
  ls -l /sys/class/infiniband \
    | grep -v $((lspci -D | grep -i Infiniband | awk '{print $1}' | cut -d '.' -f 1 \
      | sort | uniq -c | grep -w 4 || echo NONE) | awk '{print $NF}' \
      | xargs -I {} echo "-e {}.") \
    | grep infiniband | awk -F'/' '{print $(NF-2),$NF}' \
    | while read -r bdf dev; do
        ret=$(mlxlink -d "$bdf" 2>&1 | grep Recommendation | cut -f2- -d ':' \
          | grep -v 'No issue was observed' || true)
        if [ "X$ret" != "X" ]; then
          echo "${dev}:${ret}"
        fi
      done | paste -s -d','
)
echo "${ib_link_down_status_out}" >> $node_health/ib-down
if ! diff "$node_health/ib-down" "$valid_health/ib-down" > /dev/null
then
	append_reason "ib-down" " "
fi

echo -e "########INFO: Check IB Link Down counters (Expected: No issue found)" > $node_health/ib-link
# Bypass those 4 ports IB HCA is connected to nvswitch on B200/B300.
ib_link_down_counters_out=$(
  for dev in $(
    ls -l /sys/class/infiniband \
      | grep -v $((lspci -D | grep -i Infiniband | awk '{print $1}' | cut -d '.' -f 1 \
        | sort | uniq -c | grep -w 4 || echo NONE) | awk '{print $NF}' \
        | xargs -I {} echo "-e {}.") \
      | grep infiniband | awk -F'/' '{print $NF}'
  ); do
    link_downed=$(</sys/class/infiniband/${dev}/ports/1/counters/link_downed)
    symbol_error=$(</sys/class/infiniband/${dev}/ports/1/counters/symbol_error)
    if [[ ${link_downed} -ne 0 || ${symbol_error} -ne 0 ]]; then
      echo "${dev}:link_downed=${link_downed},symbol_error=${symbol_error}"
    fi
  done
)
echo "${ib_link_down_counters_out}" >> $node_health/ib-link
if ! diff "$node_health/ib-link" "$valid_health/ib-link" > /dev/null
then
	append_reason "ib-link" " "
fi

echo -e "########INFO: Check IB PKEY (Expected: All nodes have the same PKEY)" > $node_health/ib-pkey
ib_pkey_out=$(
  for i in $(
    ls -l /sys/class/infiniband \
      | grep -v $((lspci -D | grep -i Infiniband | awk '{print $1}' | cut -d '.' -f 1 \
        | sort | uniq -c | grep -w 4 || echo NONE) | awk '{print $NF}' \
        | xargs -I {} echo "-e {}.") \
      | grep infiniband | awk -F'/' '{print $NF}' \
      | grep -v bond_ | sort -t'_' -k2n
  ); do
    ret=$(cat /sys/class/infiniband/${i}/ports/1/pkeys/* \
      | grep -E -v '0x0000' | sort | uniq | paste -s -d',')
    if [ -n "$ret" ]; then
      echo "${i}: ${ret}"
    fi
  done || true
)
echo "${ib_pkey_out}" >> $node_health/ib-pkey
if ! diff "$node_health/ib-pkey" "$valid_health/ib-pkey" > /dev/null
then
	append_reason "ib-pkey" " "
fi

echo -e "########INFO: Check IB FW (Expected: All nodes have the same FW version)" > $node_health/ib-firmware
ib_fw_out=$(
  for i in /sys/class/infiniband/*; do
    printf "%50s%15s\n" "${i}/fw_ver" "$( <"${i}/fw_ver" )"
  done
)
echo "${ib_fw_out}" >> $node_health/ib-firmware
if ! diff "$node_health/ib-firmware" "$valid_health/ib-firmware" > /dev/null
then
	append_reason "ib-firmware" " "
fi

echo -e "########INFO: Check PCIe LnkCap+LnkStat (Expected: No issue found, but on BXX/HXX xx:xx.{0..3} shown is expected)" > $node_health/pcie-lnk-stat
pcie_link_out=$(
  if [ "$(uname -m)" == x86_64 ]; then
    lspci -d 15b3: -nn | awk '{print $1}' \
      | while read -r i; do
          cnt=$(lspci -s "$i" -vvv \
            | grep -e LnkCap: -e LnkSta: \
            | grep -o "Speed.*" \
            | awk -F',' '{print $1, $2}' \
            | tr -s ' ' \
            | sort | uniq -c | wc -l)
          if [ "$cnt" -ne 1 ]; then
            echo "$i"
          fi
        done
  elif [ "$(uname -m)" == aarch64 ]; then
    lspci -d 15b3: -nn | grep controller | awk '{print $1}' \
      | while read -r i; do
          cnt=$(lspci -s "$i" -vvv \
            | grep -e LnkCap: -e LnkSta: \
            | grep -o "Speed.*" \
            | awk -F',' '{print $1, $2}' \
            | tr -s ' ' \
            | sort | uniq -c | wc -l)
          if [ "$cnt" -ne 1 ]; then
            echo "$i"
          fi
        done
  fi
)
echo "${pcie_link_out}" >> $node_health/pcie-lnk-stat
if ! diff "$node_health/pcie-lnk-stat" "$valid_health/pcie-lnk-stat" > /dev/null
then
	append_reason "pcie-lnk-stat" " "
fi

echo -e "########INFO: Check PCIe ACS (Expected: All same brand nodes the same)" > $node_health/pcie-acs
pcie_acs_out=$(
  lspci -vvv | grep 'ACSCtl:.*SrcValid-' | wc -l
)
echo "${pcie_acs_out}" >> $node_health/pcie-acs
if ! diff "$node_health/pcie-acs" "$valid_health/pcie-acs" > /dev/null
then
	append_reason "pcie-acs" " "
fi

echo -e "########INFO: Check PCIe MRRS (Expected: all 4096, but on BXX/HXX some&lt;4&gt; with 512 is expected)" > $node_health/pcie-mrrs
pcie_mrrs_out=$(
  lspci -d 15b3: -nn | awk '{print $1}' \
    | xargs -I {} lspci -s {} -vvv \
    | grep -o "MaxReadReq.*" \
    | awk '{print $(NF-1)}' | sort | uniq -c
)
echo "${pcie_mrrs_out}" >> $node_health/pcie-mrrs
if ! diff "$node_health/pcie-mrrs" "$valid_health/pcie-mrrs" > /dev/null
then
	append_reason "pcie-mrrs" " "
fi

echo -e "########INFO: Check IFace device status (Expected: all nodes use the same interface connect to default gateway)" > $node_health/iface
iface_out=$(
  ip r sh | grep default | grep -o "dev.*" | cut -f2 -d' '
)
echo "${iface_out}" >> $node_health/iface
if ! diff "$node_health/iface" "$valid_health/iface" > /dev/null
then
	append_reason "iface" " "
fi

echo -e "########INFO: Check Bond interfaces (Expected: all nodes the same)" > $node_health/bond
bond_out=$(
  for i in /proc/net/bonding/*; do
    {
      ethtool "${i##*/}" | grep -e Speed -e Link
      echo '==DETAILS=='
      grep -e 'Bonding Mode' -e 'Transmit Hash Policy' "$i"
      for j in $(grep 'Slave Interface' "$i" | awk '{print $NF}' | sort); do
        grep -A5 "$j" "$i" \
          | grep -e 'Slave Interface' -e 'MII Status' -e 'Speed' \
          | paste -s -d' '
      done
    } | xargs -I {} echo "${i}: {}"
  done
)
echo "${bond_out}" >> $node_health/bond
if ! diff "$node_health/bond" "$valid_health/bond" > /dev/null
then
	append_reason "bond" " "
fi

echo -e "########INFO: Check IMEX channel devices (Expected: At least one channel exist on GBXX)" > $node_health/imex-channels
imex_channel_out=$(
  if [ "$(uname -m)" == aarch64 ]; then
    ls -1 /dev/nvidia-caps-imex-channels/ 2>/dev/null || true
  fi
)
echo "${imex_channel_out}" >> $node_health/imex-channels
if ! diff "$node_health/imex-channels" "$valid_health/imex-channels" > /dev/null
then
	append_reason "imex-channels" " "
fi

echo -e "########INFO: Check IMEX profile" > $node_health/imex-profile
imex_profile_out=$(
  if [ "$(uname -m)" == aarch64 ]; then
    grep -E "^(SERVER_PORT|IMEX_CMD_PORT|IMEX_CMD_ENABLED|IMEX_CMD_BIND_INTERFACE_IP)=" \
      /etc/nvidia-imex/config.cfg 2>/dev/null | paste -s -d' ' || true
  fi
)
echo "${imex_profile_out}" >> $node_health/imex-profile
if ! diff "$node_health/imex-profile" "$valid_health/imex-profile" > /dev/null
then
	append_reason "imex-profile" " "
fi

echo -e "########INFO: Check IMEX nodes_config (Expected: file exist on GBXX)" > $node_health/imex-node-config
imex_nodes_cfg_out=$(
  if [ "$(uname -m)" == aarch64 ]; then
    md5sum /etc/nvidia-imex/nodes_config.cfg 2>/dev/null || true
  fi
)
echo "${imex_nodes_cfg_out}" >> $node_health/imex-node-config
if ! diff "$node_health/imex-node-config" "$valid_health/imex-node-config" > /dev/null
then
	append_reason "imex-node-config" " "
fi

echo -e "########INFO: Check IMEX service status (Expected: 2 ports up and service is active on GBXX)" > $node_health/imex-service
imex_service_out=$(
  if [ "$(uname -m)" == aarch64 ]; then
    ss -lntp | grep nvidia-imex | grep -v nv-hostengine | wc -l
    systemctl is-active nvidia-imex.service || true
    ls /cm/local/apps/slurm/var/*/*imex* 2>/dev/null || true
  fi
)
echo "${imex_service_out}" >> $node_health/imex-service
if ! diff "$node_health/imex-service" "$valid_health/imex-service" > /dev/null
then
	append_reason "imex-service" " "
fi

echo -e "#########INFO: Check IMEX readiness (Expected: imex is READY on GBXX)" > $node_health/imex-readiness
imex_ready_out=$(
  if [ "$(uname -m)" == aarch64 ]; then
    nvidia-imex-ctl -q 2>&1 || true
  fi
)
echo "${imex_ready_out}" >> $node_health/imex-readiness
if ! diff "$node_health/imex-readiness" "$valid_health/imex-readiness" > /dev/null
then
	append_reason "imex-readiness" " "
fi

echo -e "########INFO: Check IMEX connection status (Expected: Node be in READY, all nodes connected and Domain UP on GBXX)" > $node_health/imex-status
imex_conn_out=$(
  if [ "$(uname -m)" == aarch64 ]; then
    nvidia-imex-ctl -N 2>&1 \
      | awk '/Nodes:/,/Domain state:/{print $0}' \
      | sed -e 's:\*: :g' -e 's:-::g' | tr -s ' '
  fi
)
echo "${imex_conn_out}" >> $node_health/imex-status
if ! diff "$node_health/imex-status" "$valid_health/imex-status" > /dev/null
then
	append_reason "imex-status" " "
fi

echo -e "########INFO: Check Enroot runtime directory (Expected: ENROOT_RUNTIME_PATH Writable)" > $node_health/enroot
enroot_runtime_out=$(
  a=$(grep ENROOT_RUNTIME_PATH /etc/enroot/enroot.conf 2>/dev/null | grep -o '/.*')
  if [ -n "${a}" ]; then
    mkdir -p "${a}" 2>/dev/null
    if touch "${a}/test" &>/dev/null; then
      echo "${a} is writable"
      rm -f "${a}/test"
    else
      echo "${a} is read-only"
    fi
  else
    echo "ENROOT_RUNTIME_PATH not set"
  fi
)
echo "${enroot_runtime_out}" >> $node_health/enroot
if ! diff "$node_health/enroot" "$valid_health/enroot" > /dev/null
then
	append_reason "enroot missing" " "
fi

echo -e "########INFO: Check dmesg - NV_ERR (Expected: No NV_ERR_*)" > $node_health/dmesg-nv_err
dmesg_nverr_out=$(
  dmesg | grep -o "NV_ERR_[^]]*" | sort | uniq
)
echo "${dmesg_nverr_out}" >> $node_health/dmesg-nv_err
if ! diff "$node_health/dmesg-nv_err" "$valid_health/dmesg-nv_err" > /dev/null
then
	append_reason "dmesg-nv_err" " "
fi

echo -e "########INFO: Check dmesg - Call trace (Expected: No Call trace)" > $node_health/dmesg-trace
dmesg_calltrace_out=$(
  dmesg | grep -i "Call trace" | wc -l
)
echo "${dmesg_calltrace_out}" >> $node_health/dmesg-trace
if ! diff "$node_health/dmesg-trace" "$valid_health/dmesg-trace" > /dev/null
then
	append_reason "dmesg-trace" " "
fi

echo -e "########INFO: Check dmesg - Hardware Error (Expected: No Hardware Error)" > $node_health/dmesg-hw_err
dmesg_hwerr_out=$(
  dmesg | grep "Hardware Error" | wc -l
)
echo "${dmesg_hwerr_out}" >> $node_health/dmesg-hw_err
if ! diff "$node_health/dmesg-hw_err" "$valid_health/dmesg-hw_err" > /dev/null
then
	append_reason "dmesg-hw_err" " "
fi

echo -e "########INFO: Check dmesg - Xid (Expected: No Xid)" > $node_health/dmesg-xid
dmesg_xid_out=$(
  dmesg | grep -E -o 'Xid ([^)].*): [0-9]+,' \
    | tr -d ',' \
    | awk '{print $1":"$NF}' \
    | sort | uniq | paste -s -d','
)
echo "${dmesg_xid_out}" >> $node_health/dmesg-xid
if ! diff "$node_health/dmesg-xid" "$valid_health/dmesg-xid" > /dev/null
then
	append_reason "dmesg-xid " "${dmesg_xid_out}"
fi

echo -e "########INFO: Check dmesg - knvlinkDiscoverPostRxDetLinks (Expected: No knvlinkDiscoverPostRxDetLinks)" > $node_health/dmesg-knvlink
dmesg_knvlink_out=$(
  dmesg | grep "NVRM: knvlinkDiscoverPostRxDetLinks" | wc -l
)
echo "${dmesg_knvlink_out}" >> $node_health/dmesg-knvlink
if ! diff "$node_health/dmesg-knvlink" "$valid_health/dmesg-knvlink" > /dev/null
then
	append_reason "dmesg-knvlink" " "
fi

echo -e "########INFO: Check dmesg - ipmi_ssif (Expected: No ipmi_ssif Not present errors)" > $node_health/dmesg-ipmi_ssif
dmesg_ipmi_out=$(
  if ipmitool mc info &>/dev/null; then
    echo "ipmitool mc info OK"
  else
    dmesg --since "8 hour ago" | grep "ipmi_ssif.*i2c-.*Not present" | wc -l
  fi
)
echo "${dmesg_ipmi_out}" >> $node_health/dmesg-ipmi_ssif
if ! diff "$node_health/dmesg-ipmi_ssif" "$valid_health/dmesg-ipmi_ssif" > /dev/null
then
	append_reason "dmesg-ipmi_ssif" " "
fi

echo -e "########INFO: Check dmesg - mlx5_core.*Health issue observed.*ERROR (Expected: No mlx5_core Health issue observed errors)" > $node_health/dmesg-mlx5_core
dmesg_mlx5_out=$(
  dmesg --since "8 hour ago" | grep "mlx5_core.*Health issue observed.*ERROR" | wc -l
)
echo "${dmesg_mlx5_out}" >> $node_health/dmesg-mlx5_core
if ! diff "$node_health/dmesg-mlx5_core" "$valid_health/dmesg-mlx5_core" > /dev/null
then
	append_reason "dmesg-mlx5_core" " "
fi

#echo >> $node_health
#echo -e "\n########INFO: sysinfo check completed, please review the above information for any potential issue.\n" >> $node_health

# Service user comes from the site config so this works on any cluster.
_svc="${RUN_AS_USER:-$(stat -c %U "$home" 2>/dev/null || id -un)}"
chown -R "$_svc:$_svc" $node_health 2>/dev/null || true
# -----------------------------------------------------------------------------
# Drain this node in Slurm with the aggregated "reason" text
# -----------------------------------------------------------------------------
node_name=${SLURMD_NODENAME:-$(hostname -s)}

if command -v /cm/local/apps/slurm/current/bin/scontrol >/dev/null 2>&1; then
  if [ -z "${reason}" ]; then
    scontrol update NodeName="${node_name}" State=IDLE
  else
    # Flatten newlines to spaces for the Slurm reason field
    scontrol update NodeName="${node_name}" State=DOWN \
      Reason="$(echo "${reason}" | tr $'\n' ' ' | sed 's/  */ /g')"
  fi
else
  echo "########WARN: scontrol not found; unable to update node in Slurm."
fi

