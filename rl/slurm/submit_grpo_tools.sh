#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
submit_script="$SCRIPT_DIR/submit_slurm_job.sh"
model_id="Qwen/Qwen3-0.6B"
gpu_profile="l40s"
exports=()
sbatch_args=()
submit_args=()

usage() {
  cat <<'USAGE'
Usage: submit_grpo_tools.sh [options] [-- sbatch-options]

Options:
  --model ID              Model ID. Default: Qwen/Qwen3-0.6B.
  --gpu-profile NAME      a100, l40s, or b200. Default: l40s.
  --max-steps N           Override optimizer steps (-1 uses 16 epochs).
  --epochs N              Training epochs. Default: 16.
  --output-root DIR       Remote output root.
  --wandb-run-name NAME   W&B run name.
  --no-wandb              Disable W&B.
  --smoke-test            Run 2 steps and 2 generations.
  --monitor               Monitor after submission.
  --dry-run               Show upload/submission without executing it.
USAGE
}

add_export() {
  exports+=("$1=$2")
}

while (($#)); do
  case "$1" in
    --model) model_id="$2"; shift 2 ;;
    --gpu-profile)
      case "$2" in
        a100|l40s|b200) gpu_profile="$2" ;;
        *) echo "error: --gpu-profile must be a100, l40s, or b200" >&2; exit 2 ;;
      esac
      shift 2
      ;;
    --max-steps) add_export MAX_STEPS "$2"; shift 2 ;;
    --epochs) add_export NUM_EPOCHS "$2"; shift 2 ;;
    --output-root) add_export OUTPUT_ROOT "$2"; shift 2 ;;
    --wandb-run-name) add_export WANDB_RUN_NAME "$2"; shift 2 ;;
    --no-wandb) add_export DISABLE_WANDB 1; shift ;;
    --smoke-test)
      add_export MAX_STEPS 2
      add_export NUM_GENERATIONS 2
      sbatch_args+=("--time=00:45:00")
      shift
      ;;
    --monitor) submit_script="$SCRIPT_DIR/submit_and_monitor.sh"; shift ;;
    --dry-run) submit_args+=("--dry-run"); shift ;;
    --remote-dir|--host|--identity)
      submit_args+=("$1" "$2")
      shift 2
      ;;
    --)
      shift
      sbatch_args+=("$@")
      break
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

exports=("MODEL_ID=$model_id" "GPU_PROFILE=$gpu_profile" "${exports[@]}")
sbatch_args=("--constraint=$gpu_profile" "${sbatch_args[@]}")
export_arg="ALL"
for item in "${exports[@]}"; do
  export_arg+=",$item"
done
sbatch_args=("--export=$export_arg" "${sbatch_args[@]}")

exec "$submit_script" \
  --source-dir "$SOURCE_ROOT" \
  "${submit_args[@]}" \
  rl/slurm/grpo_tools.sbatch \
  -- "${sbatch_args[@]}"
