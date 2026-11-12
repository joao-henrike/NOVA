#!/usr/bin/env python3
"""NOVA FinOps: AWS read-only billing + operational telemetry, SQLite and local dashboard."""
import argparse
import csv
import datetime as dt
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

REGION = "us-east-1"
ACCOUNT = "996560371158"
PREFIX = "cloudstart-dev"
CLUSTER = PREFIX + "-cluster"
SERVICES = ("frontend", "backend", "monitoring")
GROUPS = tuple("/ecs/" + PREFIX + "/" + s for s in SERVICES)
ROOT = Path(__file__).resolve().parent
DB = ROOT.parent / ".deploy" / "finops" / "data.sqlite3"

def now():
    return dt.datetime.now(dt.timezone.utc)

def iso(t):
    return t.isoformat(timespec="seconds").replace("+00:00", "Z")

def aws(svc, op, **kw):
    args = ["aws", svc, op, "--region", REGION, "--output", "json", "--no-cli-pager"]
    for k, v in kw.items():
        if v is None: continue
        args.extend(["--" + k.replace("_","-"), json.dumps(v) if isinstance(v,(dict,list)) else str(v)])
    try:
        p = subprocess.run(args, text=True, capture_output=True, timeout=45,
                           env=dict(os.environ, AWS_PAGER=""))
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError("AWS unavailable for " + svc + "/" + op) from exc
    if p.returncode:
        raise RuntimeError("AWS " + svc + "/" + op + " failed (permissions or resource missing)")
    try: return json.loads(p.stdout)
    except ValueError as exc: raise RuntimeError("Non-JSON AWS response") from exc

def guard():
    account = aws("sts","get-caller-identity").get("Account")
    if account != ACCOUNT: raise RuntimeError("Wrong AWS account: " + str(account))

def storage(path):
    path = Path(path).expanduser()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    if path.is_symlink(): raise RuntimeError("Database path cannot be symlink")
    db = sqlite3.connect(str(path), timeout=15, check_same_thread=False)
    os.chmod(path, 0o600)
    db.execute("PRAGMA journal_mode=WAL")
    db.executescript("""
    CREATE TABLE IF NOT EXISTS cost(day TEXT, scope TEXT, service TEXT, usd REAL, estimated INTEGER,
       PRIMARY KEY(day,scope,service));
    CREATE TABLE IF NOT EXISTS samples(at TEXT PRIMARY KEY, payload TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    """)
    return db

def meta(db,key):
    row=db.execute("SELECT value FROM meta WHERE key=?",(key,)).fetchone()
    return row[0] if row else None

def billing(days):
    end=now().date()+dt.timedelta(days=1)
    start=end-dt.timedelta(days=days)
    scopes={
       "account":None,
       "project_tagged":{"And":[
           {"Tags":{"Key":"Project","Values":["cloudstart"],"MatchOptions":["EQUALS"]}},
           {"Tags":{"Key":"Environment","Values":["dev"],"MatchOptions":["EQUALS"]}}
       ]}
    }
    rows=[]
    for scope,flt in scopes.items():
        token=None
        while True:
            kwargs={"time_period":{"Start":start.isoformat(),"End":end.isoformat()},
                    "granularity":"DAILY","metrics":["UnblendedCost"],
                    "group_by":[{"Type":"DIMENSION","Key":"SERVICE"}]}
            if flt: kwargs["filter"]=flt
            if token: kwargs["next_page_token"]=token
            response=aws("ce","get-cost-and-usage",**kwargs)
            for period in response.get("ResultsByTime",[]):
                for group in period.get("Groups",[]):
                    cost=group["Metrics"]["UnblendedCost"]
                    if cost.get("Unit")!="USD": raise RuntimeError("CE unit differs from USD")
                    rows.append((period["TimePeriod"]["Start"],scope,
                                 group["Keys"][0],float(cost["Amount"]),
                                 int(period.get("Estimated",True))))
            token=response.get("NextPageToken")
            if not token: break
    return rows

def refresh_billing(db,days,force=False):
    previous=meta(db,"billing_at")
    if previous and not force:
        try:
            if (now()-dt.datetime.fromisoformat(previous.replace("Z","+00:00"))).total_seconds()<3600:
                return "cached"
        except ValueError: pass
    rows=billing(days)
    start=(now().date()+dt.timedelta(days=1)-dt.timedelta(days=days)).isoformat()
    with db:
        db.execute("DELETE FROM cost WHERE day>=?",(start,))
        db.executemany("INSERT INTO cost(day,scope,service,usd,estimated) VALUES(?,?,?,?,?)",rows)
        db.execute("INSERT OR REPLACE INTO meta VALUES(?,?)",("billing_at",iso(now())))
    return "refreshed"

def metric(namespace,metric_name,dimensions):
    end=now()
    response=aws("cloudwatch","get-metric-statistics",
       namespace=namespace,metric_name=metric_name,
       dimensions=[{"Name":k,"Value":v} for k,v in dimensions.items()],
       start_time=iso(end-dt.timedelta(hours=1)),end_time=iso(end),
       period=300,statistics=["Average"])
    pts=[float(x["Average"]) for x in response.get("Datapoints",[]) if "Average" in x]
    return round(sum(pts)/len(pts),4) if pts else None

def observed():
    out={"services":{}, "rds":[], "nat":[], "alb":None, "logs":[], "warnings":[]}
    response=aws("ecs","describe-services",cluster=CLUSTER,
                 services=[PREFIX+"-"+s for s in SERVICES])
    for item in response.get("services",[]):
        name=item["serviceName"].removeprefix(PREFIX+"-")
        task=aws("ecs","describe-task-definition",
                 task_definition=item["taskDefinition"])["taskDefinition"]
        running=int(item.get("runningCount",0))
        cpu=int(task.get("cpu",0)); memory=int(task.get("memory",0))
        dim={"ClusterName":CLUSTER,"ServiceName":item["serviceName"]}
        out["services"][name]={
          "running":running,"desired":item.get("desiredCount",0),
          "cpu_units_per_task":cpu,"memory_mb_per_task":memory,
          "provisioned_vcpu":round(running*cpu/1024,3),
          "provisioned_gib":round(running*memory/1024,3),
          "cpu_avg_1h_percent":metric("AWS/ECS","CPUUtilization",dim),
          "memory_avg_1h_percent":metric("AWS/ECS","MemoryUtilization",dim)}
    for suffix in ("-db","-monitoring-db"):
        name=PREFIX+suffix
        item=aws("rds","describe-db-instances",db_instance_identifier=name)["DBInstances"][0]
        out["rds"].append({
          "name":name,"class":item.get("DBInstanceClass"),"state":item.get("DBInstanceStatus"),
          "storage_gib":item.get("AllocatedStorage"),"multi_az":item.get("MultiAZ",False),
          "db_connections_avg_1h":metric("AWS/RDS","DatabaseConnections",
                                       {"DBInstanceIdentifier":name})})
    nats=aws("ec2","describe-nat-gateways",filter=[
        {"Name":"tag:Project","Values":["cloudstart"]},
        {"Name":"tag:Environment","Values":["dev"]}]).get("NatGateways",[])
    out["nat"]=[{"id":n["NatGatewayId"],"state":n["State"]} for n in nats
                if n["State"] not in ("deleted","failed")]
    try:
        lb=aws("elbv2","describe-load-balancers",names=[PREFIX+"-alb"])["LoadBalancers"][0]
        out["alb"]={"state":lb["State"]["Code"],"name":lb["LoadBalancerName"]}
    except RuntimeError: out["warnings"].append("ALB not present or unavailable")
    for name in GROUPS:
        desc=aws("logs","describe-log-groups",log_group_name_prefix=name)
        hits=[x for x in desc.get("logGroups",[]) if x["logGroupName"]==name]
        out["logs"].append({
          "group":name,"stored_bytes_reported":hits[0].get("storedBytes") if hits else None,
          "incoming_bytes_1h_avg":metric("AWS/Logs","IncomingBytes",{"LogGroupName":name})})
    return out

def recent_log_counts():
    # Retains counts only, never log messages. First 100 matches per group.
    start=int((now().timestamp()-900)*1000)
    result={}
    for group in GROUPS:
        try:
            response=aws("logs","filter-log-events",log_group_name=group,
                         start_time=start,filter_pattern='"ERROR"',limit=100)
            result[group]={"at_least":len(response.get("events",[])),
                           "possibly_more":bool(response.get("nextToken"))}
        except RuntimeError:
            result[group]={"unavailable":True}
    return result

def collect(db,days=30,logs=False,force=False):
    guard()
    errors=[]
    try:
        bill=refresh_billing(db,days,force)
    except RuntimeError as exc:
        bill="unavailable"
        errors.append("billing: "+str(exc))
    try: resources=observed()
    except RuntimeError as exc:
        resources={}
        errors.append("telemetry: "+str(exc))
    events=recent_log_counts() if logs else {}
    stamp=iso(now())
    sample={"timestamp_utc":stamp,"billing_status":bill,
            "resources":resources,"recent_log_errors":events,"errors":errors}
    with db:
        db.execute("INSERT INTO samples VALUES(?,?)",(stamp,json.dumps(sample)))
    return sample

def costs(db,days):
    begin=(now().date()+dt.timedelta(days=1)-dt.timedelta(days=days)).isoformat()
    rows=db.execute("SELECT day,scope,service,usd,estimated FROM cost WHERE day>=? ORDER BY day,scope,service",(begin,)).fetchall()
    return [{"day":d,"scope":s,"service":v,"usd":a,"estimated":bool(est)}
            for d,s,v,a,est in rows]

def report(db,days=30):
    rows=costs(db,days)
    latest=db.execute("SELECT payload FROM samples ORDER BY at DESC LIMIT 1").fetchone()
    project=[x for x in rows if x["scope"]=="project_tagged"]
    account=[x for x in rows if x["scope"]=="account"]
    today=now().date()
    perday={}
    for x in project:
        if x["day"]<today.isoformat():
            perday[x["day"]]=perday.get(x["day"],0)+x["usd"]
    avg=sum(perday.values())/len(perday) if perday else None
    next_month=dt.date(today.year+(today.month==12),today.month%12+1,1)
    remaining=max(0,(next_month-today).days-1)
    mtd=sum(x["usd"] for x in project if x["day"].startswith(today.strftime("%Y-%m")))
    forecast=round(mtd+avg*remaining,2) if avg is not None else None
    byservice={}
    for x in project: byservice[x["service"]]=byservice.get(x["service"],0)+x["usd"]
    budget_env=os.environ.get("NOVA_FINOPS_MONTHLY_BUDGET_USD")
    budget=float(budget_env) if budget_env else None
    return {
      "timestamp_utc":iso(now()),"period_days":days,"currency":"USD","billing_metric":"UnblendedCost",
      "billing_refreshed_at":meta(db,"billing_at"),
      "account_billed_usd":round(sum(x["usd"] for x in account),4),
      "project_tagged_billed_usd":round(sum(x["usd"] for x in project),4),
      "completed_day_average_usd":round(avg,4) if avg is not None else None,
      "month_forecast_usd":forecast,
      "forecast_formula":"project-tagged MTD + avg completed day * days remaining; illustrative",
      "budget_usd":budget,"forecast_exceeds_budget":budget is not None and forecast is not None and forecast>budget,
      "by_service_usd":dict(sorted(byservice.items(),key=lambda p:-p[1])),
      "latest_sample":json.loads(latest[0]) if latest else None,
      "disclaimer":[
        "Cost Explorer data has ingestion delay and may be estimated; it is not a realtime invoice.",
        "Project cost allocation requires activated cost allocation tags; untagged charges are not included.",
        "The account total includes unrelated resources; project tags may have gaps.",
        "CloudWatch and ECS telemetry are recent usage observations, not USD costs per second.",
        "Forecast is a naive historical run-rate, not an AWS guarantee; taxes/credits/discounts vary.",
        "Cost Explorer and other AWS API calls may incur fees."
      ]
    }

def history(db,days=90):
    recent=db.execute("SELECT payload FROM samples ORDER BY at DESC LIMIT 300").fetchall()
    return {"daily_costs":costs(db,days),
            "samples":[json.loads(r[0]) for r in reversed(recent)]}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path=urlparse(self.path).path
        if path=="/":
            body=(ROOT/"dashboard.html").read_bytes()
            content_type="text/html; charset=utf-8"
        elif path in ("/api/summary","/api/history","/healthz"):
            data=(report(self.server.db,90) if path=="/api/summary" else
                  history(self.server.db,90) if path=="/api/history" else {"ok":True})
            body=json.dumps(data).encode("utf-8");content_type="application/json"
        else:
            self.send_error(404);return
        self.send_response(200)
        self.send_header("Content-Type",content_type)
        self.send_header("Content-Length",str(len(body)))
        self.send_header("Cache-Control","no-store")
        self.send_header("X-Content-Type-Options","nosniff")
        self.send_header("Content-Security-Policy","default-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self,*args): pass

def main():
    p=argparse.ArgumentParser(description="NOVA FinOps: Cost Explorer + ECS/RDS/CloudWatch, private dashboard")
    p.add_argument("--db",default=str(DB))
    sub=p.add_subparsers(dest="action",required=True)
    c=sub.add_parser("collect");c.add_argument("--days",type=int,default=30);c.add_argument("--logs",action="store_true");c.add_argument("--force-billing",action="store_true")
    w=sub.add_parser("watch");w.add_argument("--interval",type=int,default=300);w.add_argument("--logs",action="store_true");w.add_argument("--days",type=int,default=30)
    s=sub.add_parser("serve");s.add_argument("--port",type=int,default=8766)
    r=sub.add_parser("report");r.add_argument("--days",type=int,default=30)
    e=sub.add_parser("export");e.add_argument("--days",type=int,default=90);e.add_argument("--file",required=True)
    args=p.parse_args()
    if hasattr(args,"days") and not 1<=args.days<=90:p.error("days must be 1..90")
    if args.action=="watch" and args.interval<300:p.error("interval must be >=300s")
    if args.action=="serve" and not 1024<=args.port<=65535:p.error("invalid port")
    try:
        db=storage(args.db)
        if args.action=="collect":
            print(json.dumps(collect(db,args.days,args.logs,args.force_billing),indent=2))
        elif args.action=="report":
            print(json.dumps(report(db,args.days),indent=2))
        elif args.action=="serve":
            server=ThreadingHTTPServer(("127.0.0.1",args.port),Handler)
            server.db=db
            print("Dashboard local: http://127.0.0.1:"+str(args.port),flush=True)
            try:server.serve_forever()
            except KeyboardInterrupt:pass
            finally:server.server_close()
        elif args.action=="watch":
            while True:
                try:
                    sample=collect(db,args.days,args.logs)
                    print(json.dumps({"at":sample["timestamp_utc"],"errors":sample["errors"],"billing":sample["billing_status"]}),flush=True)
                except RuntimeError as exc: print("WARNING:",exc,file=sys.stderr,flush=True)
                time.sleep(args.interval)
        elif args.action=="export":
            out=Path(args.file).expanduser()
            if out.exists():raise RuntimeError("Refusing to overwrite existing export")
            out.parent.mkdir(parents=True,exist_ok=True)
            with out.open("x",newline="") as f:
                writer=csv.DictWriter(f,fieldnames=["day","scope","service","usd","estimated"])
                writer.writeheader();writer.writerows(costs(db,args.days))
            os.chmod(out,0o600)
            print("CSV:",out)
    except (RuntimeError,OSError,sqlite3.Error,ValueError) as exc:
        print("ERROR:",exc,file=sys.stderr);return 1
    return 0

if __name__=="__main__":
    sys.exit(main())
