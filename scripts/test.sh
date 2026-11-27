#!/usr/bin/env bash
# Runs the test suites (plain Ruby + a mock SketchUp API).
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
for t in test_pure test_yard test_corners test_shop test_sequence test_joints test_plan_corners; do
  timeout 120 ruby test/$t.rb > /tmp/$t.log 2>&1 && echo "ok   $t" || { echo "FAIL $t"; fail=1; }
done
for t in smoke test_tool test_install test_install2 test_jobsite test_dtp test_guided test_update test_toolbar test_corners_oc test_corner_preview test_plan_view test_interior test_fixes test_notes2 test_demo; do
  timeout 120 ruby -Itest/stubs test/$t.rb > /tmp/$t.log 2>&1 && tail -1 /tmp/$t.log | grep -q "ALL PASSED" && echo "ok   $t" || { echo "FAIL $t"; fail=1; }
done
exit $fail
