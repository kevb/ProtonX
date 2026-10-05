#!/usr/bin/env bash
set -euo pipefail
# No secrets or process arguments are read. Report all matching processes, not just a parent PID.
ps -axo pid=,rss=,%cpu=,comm= | awk '
{
  path=substr($0,index($0,$4)); name=path; sub(/^.*\//,"",name)
  if (name == "ProtonX" || name == "protonx-pass" || name == "proton-bridge" || name == "Proton Mail" || name == "Proton Pass" || name ~ /^Proton (Mail|Pass) Helper( \(.*\))?$/) {
    printf "PID %s  RSS %.1f MiB  CPU %s%%  %s\n", $1, $2/1024, $3, path; total += $2
  }
}
END { printf "Combined matching-process RSS: %.1f MiB\n", total/1024 }'
