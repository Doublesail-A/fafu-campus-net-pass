#!/usr/bin/env python3
"""Aggregate monitor JSONL. No raw device IDs, credentials, or node labels output."""
import argparse,collections,json,math,statistics
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('log',type=Path);p.add_argument('--since',type=int,default=0);p.add_argument('--until',type=int,default=2**63);args=p.parse_args()
groups=collections.defaultdict(list);hosts=[];bad=0;invalid_reference=0
for line in args.log.read_text(encoding='utf8').splitlines():
 try:d=json.loads(line)
 except ValueError:bad+=1;continue
 if not args.since<=d.get('epoch',0)<=args.until:continue
 if d.get('kind')=='http':
  if d.get('path')=='wired' and d.get('probe_revision',1)<2:invalid_reference+=1;continue
  groups[(d['path'],d['target'])].append(d)
 elif d.get('kind')=='host':hosts.append(d)
def q(vals,p):
 vals=sorted(v for v in vals if v is not None)
 return round(vals[max(0,math.ceil(len(vals)*p)-1)],4) if vals else None
result={'invalid_lines':bad,'discarded_reference_v1':invalid_reference,'host_snapshots':len(hosts),'results':[]}
for (path,target),rows in sorted(groups.items()):
 good=[r for r in rows if r.get('exit')==0 and r.get('http_code') in (200,204) and r.get('page_ok',True)]
 result['results'].append({'path':path,'target':target,'samples':len(rows),'success':len(good),'failure':len(rows)-len(good),'success_rate':round(len(good)/len(rows),4),'p50_s':q([r.get('time_total')for r in good],.5),'p95_s':q([r.get('time_total')for r in good],.95),'dns_p95_s':q([r.get('time_namelookup')for r in good],.95),'tls_cumulative_p95_s':q([r.get('time_appconnect')for r in good],.95),'ttfb_p95_s':q([r.get('time_starttransfer')for r in good],.95)})
print(json.dumps(result,ensure_ascii=False,indent=2))
