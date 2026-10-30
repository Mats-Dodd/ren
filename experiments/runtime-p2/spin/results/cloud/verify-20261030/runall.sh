#!/usr/bin/env bash
cd "$(dirname "$0")"
set -x
GATE=util,waste,cpu_ns_per_hop RESULTS=res/H1 ./measure-cloud.sh --filter 'budget-ns [0-9inf]+ --service-ns 1000 --gap-ns 100000 --workers 4$'
WINDOW_MS=2000 RESULTS=res/H2 ./measure-cloud.sh --filter '(fixed --budget-ns inf|go --budget-ns 20000|pred --budget-ns 20000|ema --budget-ns 20000) --service-ns 1000 --gap-ns 0 --workers 4$'
WINDOW_MS=2000 RESULTS=res/H3 ./measure-cloud.sh --filter 'fixed --budget-ns 20000 --service-ns 1000 --gap-ns 100000 --workers 4$'
WINDOW_MS=2000 RESULTS=res/H4a ./measure-cloud.sh --filter 'go --budget-ns 20000 --service-ns 1000 --gap-ns 0 --workers 4$'
GATE=util,waste,cpu_ns_per_hop RESULTS=res/H4b ./measure-cloud.sh --filter 'go --budget-ns 20000 --service-ns 1000 --gap-ns 100000 --workers 4$'
RESULTS=res/H5 FILTER='budget-ns (inf|5000) .*--workers (4|5|6) ' ./oversub-cloud.sh verify
echo ALLDONE
