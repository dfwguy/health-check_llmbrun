# Migration: sbatch/Slurm → `llmb-run`

What changed, why, and what to check on the cluster before you deploy.

---

## 1. Command mapping

| Old | New |
|-----|-----|
| `sbatch -w <node> jobs/allreduce.sbatch` (5 runs) | `llmb-run submit -w microbenchmark_nccl -s nccl --dtype fp8 --scale 72 --force --nodelist <rack>` |
| `sbatch -w <node> jobs/alltoall.sbatch` | *(same job — the sweep covers all 5 collectives)* |
| `sbatch -w <node> jobs/dcgm.sbatch` | unchanged (`runner=sbatch scope=node`) |
| `sbatch -N <racknodes> mnubergemm.sbatch` | `nccl_multi` group workload, scale 288 |
| — | `llmb-run submit -w <pretrain workload> --dtype fp8 --scale <rack GPUs> --force …` |
| `benchmarks="dcgm allreduce alltoall"` in `launch_job.sh` | `conf/workloads.conf` table |
| result parsing inside each `.sbatch` | `lib/results.sh` + `lib/llmb.sh` |

Environment carried into every `llmb-run` call: `RUN_CONF_IMAGE` (local NVMe
path), `LLMB_EXTRA_ENV` from `cluster.conf`, plus the workload's own `env=`
(`MAX_STEPS`, `TIME_LIMIT`, `MELLANOX_VISIBLE_DEVICES`).

## 2. Architectural change

Rack-scale submission moved from the per-tray BCM action to a single head-node
orchestrator (`bin/rack-orchestrator.sh`). Per-tray health checking did not
move. See README → "Why rack-scale work moved off the node".

## 3. What is preserved

- `results/<node>/<workload>.txt` with `DONE`/`FAIL` as the **last line**.
  Every existing consumer of that contract still works.
- `node_health.sh` and its 38 checks, byte for byte.
- `sync-check.sh`, `set-valid-default.sh`, `node-health-refresh.sh`,
  `single-node-purge.sh`, `watch-rack.sh` — carried over unchanged.
- Drain-on-failure with a human-readable reason in `sinfo -R`.

---

## Before you fly — five things to verify on the target cluster

All five are automated by `bin/verify-cluster.sh`; they are spelled out here so
you know what it is checking and why each one matters.

**1. Which `llmb-run` release is installed?**

```bash
llmb-run --help | grep -E 'submit|single'
llmb-run jobs --help >/dev/null 2>&1 && echo "jobs: yes" || echo "jobs: no"
```

- `submit` + `jobs` → 26.06-style, everything works.
- `single` only → 25.10-style. It has **no placement flags**, so a rack-scale job
  cannot be pinned. The orchestrator refuses to submit rather than queue a job
  whose result cannot be attributed to a rack (override with
  `AAT_ALLOW_UNPINNED=1` only if you accept unattributable results).
- No `jobs` subcommand → TFLOPS/GPU cannot be read, so `nemo_single` will FAIL
  with `no TFLOPS/GPU reported`. Either upgrade, or set
  `metric=-` on `nemo_single` to score on completion alone.

**2. Is the fabric interface name right?**

`NCCL_SOCKET_IFNAME` must name the interface NCCL bootstraps over. The interview
probes a real node for its highest-speed non-IB link; confirm it:

```bash
srun -w <node> -p <partition> ip -br link
```

A wrong value hangs jobs at initialisation with no useful error.

**3. Does the inventory match Slurm?**

```bash
awk '!/^#/{print $1, NF-2}' conf/inventory/racks.txt | awk '$2!=<nodes_per_rack>'
sinfo -h -N -o '%N' | sort > /tmp/live; # compare against the inventory
```

Site documentation often carries two naming domains for the same hardware (an
OS/provisioning name and a cabling/port-map name). Slurm is authoritative for
`--nodelist`. On a mismatch, regenerate: `docs/gen-inventory-from-slurm.sh`.

**4. Does topology/block placement apply?**

```bash
scontrol show config | grep -i topology
```

If `topology/block` is in use, multi-rack jobs must be pinned with `--exclude`,
not `--nodelist` — `--nodelist` conflicts with block placement and yields
"Requested topology configuration is not available". `SLURM_TOPOLOGY=block` in
`cluster.conf` selects this automatically (single rack → `--nodelist`, multi-rack
→ `--exclude`). If the cluster has **no** topology plugin, set
`SLURM_TOPOLOGY=none` to use `--nodelist` everywhere.

**5. Calibrate the thresholds.**

Let a few racks run `nccl_single`, then:

```bash
bin/rack-status.sh --metrics
grep -h '^m_' state/racks/*/nccl_single.state
```

Set the floors in your `conf/profiles/<platform>.conf` to ~90 % of what healthy
racks actually achieve. Profiles for less-characterised platforms ship with floors
unset on purpose — an unset floor means the workload passes on completion and only
the fleet-relative outlier gate applies, which is the honest default until you
have measured.

---

## Bugs found and fixed during offline validation

Recorded because each would have presented as something confusing on a bring-up
call. `tests/lint.sh` now has a rule for the first three classes.

| Symptom you would have seen | Cause |
|---|---|
| Every workload rejected as `unknown key 'scale'` | the valid-key list spanned two lines, so the `case " $KEYS " in *" $key "*` membership test could not match the key before the newline |
| `llmb-run … --scale 0`, jobs pending forever | group membership was registered into a global map by a function only ever called as `$(group_build …)` — a subshell — so the map was empty by the time the submitter read it |
| `((: 0\n0: syntax error`, no submissions at all | `grep -c` prints `0` *and* exits 1, so `grep -c … \|\| printf 0` emitted two lines into an arithmetic context |
| `pin: unbound variable` under `set -u` | `local a="$1" b="$a"` — bash expands every RHS on a `local` line before making any assignment |
| `--dry-run` printed nothing useful | the dry-run line went to stdout, which the caller was capturing for the job id |

## Known limitations

- **`soak` tray coverage.** The reference implementation ran two windows per
  rack (`--exclude ct[17-18]` then `--exclude ct[01-02]`) so all 18 trays got
  exercised at a power-of-2 scale. This port hands Slurm the full 72-tray pool
  and lets it carve 4×16, so the 2 leftover trays per rack are not guaranteed
  coverage. `soak` ships `enabled=0`; add explicit windows if you need it.
- **Partial groups are dropped.** 3 racks is not a 4-rack test, so a trailing
  chunk smaller than `racks_per_job` is skipped rather than run at lower scale.
- **`runs>1` is implemented for state and result files but untested at rack
  scope.** The sbatch original used `totalRuns=5` on allreduce; the NCCL sweep
  already iterates internally, so rack workloads ship `runs=1`.
- **HPL is not ported.** `jobs/hpl.sbatch` and `jobs/mnubergemm.sbatch` are
  carried over but not in the matrix; `llmb-run` has no equivalent workload. Add
  them as `runner=sbatch` entries if the acceptance plan needs them.
- **No sacct on the head node** degrades job tracking to `squeue` only, which
  loses jobs the moment they finish. The collector will then report
  `unknown to slurm` and retry. Check `sacct -j 1` works. (Present on the
  validated GB300 cluster, so this path stayed theoretical there.)

Live-cluster results, measured bandwidth vs the shipped floors, and the container
environment variables that must not be set are in
[VALIDATION-NscaleTX-2026-07-29.md](VALIDATION-NscaleTX-2026-07-29.md).

## Offline test coverage

`tests/run-tests.sh` — **37 tests, all passing**, no cluster required, mock
`llmb-run` + Slurm:

- hostlist fold/expand/subtract incl. the non-contiguous the target cluster tray numbering
- job-id parsing across all four output shapes seen in the wild
- NCCL busbw parsing for both 13-column and 11-column `nccl-tests` layouts
- elapsed-time parsing (`MM:SS`, `HH:MM:SS`, `D-HH:MM:SS`, `D-HH:MM`, leading-zero
  hours that must not be read as octal)
- workload-table validation (typo'd key, forward gate reference → both fatal)
- inventory loading, duplicate-node rejection
- dry run writes no state and queues nothing
- gating (node → rack → group), idempotency, flock, submit budget, queue depth
- success path opening the next gate; low busbw → FAIL + whole-rack drain
- `COMPLETED` with unparsable results treated as failure, not success
- Slurm `FAILED` terminal vs `NODE_FAIL` retried without draining
- 30 h timeout → `scancel` + FAIL
- one bad tray blocks its whole rack
- multi-rack uses `--exclude`, never `--nodelist`; group blocked until all
  members pass
- old `llmb-run` refuses unpinned submission unless explicitly overridden
- submit failure and unparsable job id both stay retryable
- `status-check` / CSV report shape and width

Plus `tests/lint.sh` (static checks), `tests/preflight.sh` (dry run against the
real 112-rack inventory) and `tests/simulate.sh` (drives the full matrix to
completion, including a deliberately marginal rack).
