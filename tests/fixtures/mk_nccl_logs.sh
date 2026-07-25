#!/bin/bash
# mk_nccl_logs.sh <llmb_install> <jobid> <peak_busbw> [cols:13|11] [collectives...]
# Fabricates an llmb-run microbenchmark_nccl experiment tree with nccl-tests
# sweep output whose peak busbw is <peak_busbw>.
set -uo pipefail
inst="$1"; jid="$2"; peak="$3"; cols="${4:-13}"; shift 4 || true
colls="${*:-all_reduce all_gather reduce_scatter alltoall sendrecv}"
d="$inst/workloads/microbenchmark_nccl/experiments/nccl_fp8_gpus72_${jid}/LOG_nccl_${jid}_1"
mkdir -p "$d"
for c in $colls; do
  f="$d/nccl_LOG_${c}_72_iter1.txt"
  {
    printf '# nThread 1 nGpus 1 minBytes 8 maxBytes 17179869184 step: 2(factor) warmup iters: 5 iters: 20\n'
    printf '#\n'
    if [[ "$cols" == 13 ]]; then
      printf '#                                                              out-of-place                       in-place\n'
      printf '#       size         count      type   redop    root     time   algbw   busbw #wrong     time   algbw   busbw #wrong\n'
      printf '#        (B)    (elements)                             (us)  (GB/s)  (GB/s)  (rank)     (us)  (GB/s)  (GB/s)  (rank)\n'
      s=8; bw=1.2
      while [[ $s -le 1073741824 ]]; do
        printf '%12d %12d     float     sum      -1  %7.1f %7.2f %7.2f      0  %7.1f %7.2f %7.2f      0\n' \
          "$s" "$((s/4))" 50 "$bw" "$bw" 50 "$bw" "$bw"
        s=$((s*4)); bw=$(awk -v b="$bw" -v p="$peak" 'BEGIN{v=b*3.2; if(v>p) v=p; printf "%.2f", v}')
      done
      printf '%12d %12d     float     sum      -1  %7.1f %7.2f %7.2f      0  %7.1f %7.2f %7.2f      0\n' \
        17179869184 4294967296 999 "$peak" "$peak" 999 "$peak" "$peak"
    else
      printf '#                                                     out-of-place                       in-place\n'
      printf '#       size         count      type     time   algbw   busbw #wrong     time   algbw   busbw #wrong\n'
      printf '%12d %12d     float  %7.1f %7.2f %7.2f      0  %7.1f %7.2f %7.2f      0\n' \
        17179869184 4294967296 999 "$peak" "$peak" 999 "$peak" "$peak"
    fi
    printf '# Out of bounds values : 0 OK\n# Avg bus bandwidth    : %s\n' "$peak"
  } > "$f"
done
printf '%s\n' "$d"
