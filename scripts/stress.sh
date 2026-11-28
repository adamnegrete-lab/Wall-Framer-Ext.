#!/usr/bin/env bash
# Slow end-to-end runs: a simulated student frames 5 small plans + the Habitat 2-story (H), plus edge cases.
cd "$(dirname "$0")/.."
fail=0
for k in A B C D E H; do
  timeout 300 ruby -Itest/stubs test/stress_plans.rb $k > /tmp/stress_$k.log 2>&1 && tail -1 /tmp/stress_$k.log | grep -q "ALL PASSED" && echo "ok   plan $k" || { echo "FAIL plan $k ($(tail -1 /tmp/stress_$k.log))"; fail=1; }
done
timeout 300 ruby -Itest/stubs test/stress_edges.rb > /tmp/stress_edges.log 2>&1 && tail -1 /tmp/stress_edges.log | grep -q "ALL PASSED" && echo "ok   edges" || { echo "FAIL edges"; fail=1; }
exit $fail
