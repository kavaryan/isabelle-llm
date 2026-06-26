cd /home/me/wr/ai4math/copilots-isabelle/isabelle-llm/sft/distillation/distillation-data

ps -p "$(cat full_pipeline.pid)" -o pid,ppid,etime,stat,cmd

for f in 01_multiline_distillation.jsonl 02_oneshot_rollouts.jsonl 03_oneshot_checked.jsonl 04_mini_ir_repair_rollouts.jsonl 05_mini_ir_checked.jsonl; do
  [ -e "$f" ] && wc -l "$f" || echo "0 $f"
done

tail -f full_pipeline.log