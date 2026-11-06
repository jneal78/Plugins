BEGIN { FS = "|" }
function ts(s,  a) { split(s, a, /[- :.]/); return a[4] * 3600 + a[5] * 60 + a[6] + ("0." a[7]) }
$1 == "T0" { t0 = ts($2) }
$1 == "T1" { t1 = ts($2) }
$1 == "IO"  { k = $2 "|" $3; r0[k] = $4; w0[k] = $5; sr0[k] = $6; sw0[k] = $7; br0[k] = $8; bw0[k] = $9 }
$1 == "IO1" { k = $2 "|" $3; g = $2 "|" ($3 == 2 ? "LOG" : "DATA"); R[g] += $4 - r0[k]; W[g] += $5 - w0[k]; SR[g] += $6 - sr0[k]; SW[g] += $7 - sw0[k]; BR[g] += $8 - br0[k]; BW[g] += $9 - bw0[k] }
$1 == "PC"  { p[$2] = $3 }
$1 == "PC1" { q[$2] = $3 - p[$2] }
$1 == "WT"  { w[$2] = $3; wn[$2] = $4 }
$1 == "WT1" { d[$2] = $3 - w[$2]; dn[$2] = $4 - wn[$2] }
END {
  s = t1 - t0
  if (s < 0) s += 86400   # the sample crossed midnight: the timestamps carry the time of day only
  if (t1 == "" || s <= 0) { print "sample length unknown (T0 or T1 missing): rates not computed"; exit 1 }
  printf "sample %.1f s\n\nCOUNTERS\n", s
  for (c in q) printf "%-34s %12.1f /s\n", c, q[c] / s
  print "\nIO by database id (2 = tempdb; busiest first)"
  for (g in R) if (R[g] + W[g] > 50) printf "%-10s reads/s %6.0f writes/s %6.0f readMB/s %6.1f writeMB/s %6.1f read_ms %5.1f write_ms %5.1f\n", g, R[g]/s, W[g]/s, BR[g]/1048576/s, BW[g]/1048576/s, (R[g] ? SR[g]/R[g] : 0), (W[g] ? SW[g]/W[g] : 0)
  print "\nWAITS (seconds of wait per second; benign waits excluded)"
  benign = "SLEEP|BROKER_|XE_|QUEUE|IDLE|DIAGNOSTICS|FILESTREAM|WAITFOR|DIRTY_PAGE|REQUEST_FOR_DEADLOCK|PARALLEL_REDO|HADR_WORK|HADR_TIMER|HADR_NOTIF|HADR_CLUSAPI|SOS_WORK_DISP|PWAIT_EXT|CXCONSUMER|FLUSHFILEBUFFERS|QDS_|REDO_THREAD|CLR_AUTO"
  for (x in d) if (d[x] > 0 && x !~ benign) printf "%.3f|%s|%d\n", d[x] / 1000 / s, x, dn[x] | "sort -t'|' -k1 -gr | head -10"
}
