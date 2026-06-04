#!/bin/bash -l
#SBATCH --job-name=cpu_test
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=1G
#SBATCH --time=00:05:00
#SBATCH --output=/scratch/users/%u/%x-%j.out
#SBATCH --error=/scratch/users/%u/%x-%j.err

set -euo pipefail

echo "Job ID: ${SLURM_JOB_ID:-unknown}"
echo "Job name: ${SLURM_JOB_NAME:-unknown}"
echo "Partition: ${SLURM_JOB_PARTITION:-unknown}"
echo "Node: ${SLURMD_NODENAME:-$(hostname)}"
echo "Submit directory: ${SLURM_SUBMIT_DIR:-$(pwd)}"
echo "CPUs requested: ${SLURM_CPUS_PER_TASK:-1}"
echo

echo "CPU summary:"
lscpu | sed -n '1,15p'
echo

echo "Python smoke test:"
python3 - <<'PY'
import math

total = sum(math.sqrt(i) for i in range(1, 100_001))
print(f"sum_sqrt_1_to_100000={total:.6f}")
PY

echo
echo "CPU test completed at $(date -Is)"
