#!/usr/bin/env python3
"""NOVA monitoring-only ECS hotfix. No database or secret modifications."""
import base64
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

REGION = 'us-east-1'
CLUSTER = 'cloudstart-dev-cluster'
SERVICE = 'cloudstart-dev-monitoring'
FAMILY = SERVICE
REPO = Path.home() / 'NOVA'
os.environ['AWS_PAGER'] = ''
os.environ['AWS_DEFAULT_REGION'] = REGION

# This runs inside the existing ECS task, not over the public HTTP ALB.
PREFLIGHT = r'''import base64, json, os, time, urllib.request, urllib.parse
from urllib.error import HTTPError

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

base = os.environ['GRAFANA_URL'].rstrip('/')
u = urllib.parse.urlsplit(base)
if u.scheme != 'http' or u.hostname not in ('127.0.0.1', 'localhost', '::1') or u.username or u.password:
    raise SystemExit('NOVA preflight: internal Grafana URL required')
auth = 'Basic ' + base64.b64encode(('admin:' + os.environ['GRAFANA_PASSWORD']).encode()).decode()
region = os.environ.get('AWS_REGION', 'us-east-1')
client = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
def api(path, method='GET', body=None):
    req = urllib.request.Request(base + path, method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={'Authorization':auth,'Content-Type':'application/json','Accept':'application/json'})
    with client.open(req, timeout=25) as response:
        return json.load(response)

def configure():
    sources = api('/api/datasources')
    canonical = next((s for s in sources if s.get('uid') == 'nova-cloudwatch'), None)
    if canonical and canonical.get('type') != 'cloudwatch':
        raise RuntimeError('UID nova-cloudwatch belongs to another type')
    # Repair the known legacy datasource, without deleting it or changing its UID.
    def repair(s):
        if s.get('readOnly'):
            if s.get('jsonData',{}).get('defaultRegion') != region or s.get('jsonData',{}).get('authType') != 'default':
                raise RuntimeError('Read-only CloudWatch source needs provisioning repair')
            return
        model = {k:s[k] for k in ('name','type','access','url','basicAuth','basicAuthUser','database','user','withCredentials','isDefault','jsonData') if k in s}
        model['jsonData'] = dict(model.get('jsonData') or {}, authType='default', defaultRegion=region)
        api('/api/datasources/uid/' + urllib.parse.quote(s['uid'], safe=''), 'PUT', model)
    for s in sources:
        if s.get('type') == 'cloudwatch' and (s.get('uid') in ('nova-cloudwatch','bg5e85fhz75s0a') or s.get('name','').lower() in ('cloudwatch','nova cloudwatch','nova-cloudwatch')):
            repair(s)
    if canonical is None:
        if any(s.get('name','').lower() == 'nova cloudwatch' for s in sources):
            raise RuntimeError('NOVA CloudWatch name conflict: existing UID preserved')
        api('/api/datasources','POST',{'name':'NOVA CloudWatch','uid':'nova-cloudwatch','type':'cloudwatch','access':'proxy','isDefault':not any(s.get('isDefault') for s in sources),'jsonData':{'authType':'default','defaultRegion':region}})
    print('NOVA_CLOUDWATCH_CONFIG_PASS', flush=True)
    now = int(time.time()*1000)
    query = {'refId':'A','datasource':{'type':'cloudwatch','uid':'nova-cloudwatch'},'queryMode':'Metrics','metricQueryType':0,'metricEditorMode':0,'id':'m1','namespace':'AWS/ECS','metricName':'CPUUtilization','dimensions':{'ClusterName':os.environ['NOVA_CLUSTER'],'ServiceName':'cloudstart-dev-frontend'},'region':region,'statistic':'Average','period':'300','matchExact':True,'intervalMs':300000,'maxDataPoints':100}
    result = api('/api/ds/query','POST',{'from':str(now-3600000),'to':str(now),'queries':[query]})['results']['A']
    if result.get('error') or result.get('status',200) >= 400:
        raise RuntimeError('CloudWatch returned a query error')
    count = sum(sum(isinstance(v,(int,float)) and not isinstance(v,bool) for v in values) for frame in result.get('frames',[]) for field, values in zip(frame.get('schema',{}).get('fields',[]),frame.get('data',{}).get('values',[])) if field.get('type') == 'number')
    if not count:
        raise RuntimeError('CloudWatch query returned no numeric data points')
    print('NOVA_CLOUDWATCH_QUERY_PASS points=' + str(count), flush=True)

for attempt in range(3):
    try:
        configure()
        break
    except Exception as exc:
        # Do not print response bodies, headers, credentials or request data.
        print('NOVA_CLOUDWATCH_PREFLIGHT_RETRY ' + type(exc).__name__ + ((' HTTP '+str(exc.code)) if isinstance(exc,HTTPError) else ''), flush=True)
        if attempt == 2:
            raise SystemExit('NOVA_CLOUDWATCH_PREFLIGHT_FAIL')
        time.sleep(15)
'''


def aws(*args, json_result=True):
    out = subprocess.check_output(['aws', *args, '--region', REGION, '--output', 'json' if json_result else 'text'], text=True)
    return json.loads(out) if json_result else out.strip()


def env(c, key, value):
    entries = c.setdefault('environment', [])
    for item in entries:
        if item['name'] == key:
            item['value'] = value
            return
    entries.append({'name': key, 'value': value})


def get_env(c, key):
    return next((v['value'] for v in c.get('environment', []) if v['name'] == key), None)


def hash_bytes(b):
    return hashlib.sha256(b).hexdigest()


def service():
    response = aws('ecs', 'describe-services', '--cluster', CLUSTER, '--services', SERVICE)
    if response.get('failures') or len(response['services']) != 1:
        raise RuntimeError('Monitoring service not found')
    return response['services'][0]


def print_events():
    print(json.dumps([e['message'] for e in service().get('events', [])[:6]], ensure_ascii=False, indent=2))


def wait_stable(timeout=900):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        s = service()
        p = next(d for d in s['deployments'] if d['status'] == 'PRIMARY')
        print('ECS:', p.get('rolloutState'), 'running=', s['runningCount'], 'pending=', s['pendingCount'], flush=True)
        if p.get('rolloutState') == 'FAILED':
            print_events()
            raise RuntimeError('ECS rollout failed')
        if len(s['deployments']) == 1 and s['runningCount'] == s['desiredCount'] == 1 and p.get('rolloutState') == 'COMPLETED':
            return s
        time.sleep(20)
    print_events()
    raise RuntimeError('ECS rollout did not stabilize; no further deployment initiated')


def main():
    # Guard the target; do not run against another account or environment.
    identity = aws('sts','get-caller-identity')
    if identity['Account'] != '996560371158':
        raise RuntimeError('AWS account mismatch')
    if not (REPO / 'monitoring/collector.py').is_file():
        raise RuntimeError('Missing ~/NOVA/monitoring/collector.py')
    subprocess.run(['git','-C',str(REPO),'diff','--quiet','HEAD','--','monitoring/collector.py'],check=True)
    local = subprocess.check_output(['git','-C',str(REPO),'show','HEAD:monitoring/collector.py'])
    compile(local, 'monitoring/collector.py', 'exec')
    compile(PREFLIGHT, 'cloudwatch-preflight.py', 'exec')
    s = service()
    if s['status'] != 'ACTIVE' or s['desiredCount'] != 1:
        raise RuntimeError('Unexpected monitoring service state')
    if s['deploymentConfiguration'].get('maximumPercent') != 100 or s['deploymentConfiguration'].get('minimumHealthyPercent') != 0:
        raise RuntimeError('Unexpected deployment configuration; refusing concurrent collectors')
    print('Checking existing deployment before making changes.', flush=True)
    s = wait_stable()
    old = s['taskDefinition']
    if ':task-definition/' + FAMILY + ':' not in old:
        raise RuntimeError('Unexpected task definition')
    response = aws('ecs','describe-task-definition','--task-definition',old,'--include','TAGS')
    td = response['taskDefinition']
    containers = {c['name']:c for c in td['containerDefinitions']}
    expected = {'zabbix-server','zabbix-web','grafana-db-init','grafana','monitoring-bootstrap'}
    if set(containers) != expected:
        raise RuntimeError('Unexpected container set')
    boot = containers['monitoring-bootstrap']
    collector_b64 = get_env(boot,'NOVA_COLLECTOR_SCRIPT_B64')
    if not collector_b64:
        raise RuntimeError('Missing embedded collector')
    raw = base64.b64decode(collector_b64, validate=True)
    compressed = raw.startswith(b'\x1f\x8b')
    live = gzip.decompress(raw) if compressed else raw
    print('collector encoding:', 'gzip+base64' if compressed else 'base64')
    print('collector local:', hash_bytes(local))
    print('collector AWS:  ', hash_bytes(live))
    if live != local:
        encoded = gzip.compress(local, mtime=0) if compressed else local
        env(boot,'NOVA_COLLECTOR_SCRIPT_B64',base64.b64encode(encoded).decode())
        print('Collector will be updated from local committed version.')
    else:
        print('Collector already matches; preserving live value.')
    for name in ('zabbix-server','zabbix-web'):
        env(containers[name], 'PGSSLMODE','require')
    env(containers['zabbix-server'],'ZBX_DBTLSCONNECT','required')
    env(containers['zabbix-web'],'ZBX_DB_ENCRYPTION','true')
    env(containers['grafana-db-init'],'PGSSLMODE','require')
    env(containers['grafana'],'AWS_REGION',REGION)
    env(containers['grafana'],'AWS_DEFAULT_REGION',REGION)
    env(boot,'NOVA_CLOUDWATCH_PREFLIGHT_B64',base64.b64encode(PREFLIGHT.encode()).decode())
    cmd = boot.get('command',[])
    if boot.get('entryPoint') != ['/bin/sh','-ec'] or len(cmd) != 1 or 'MONITOR_BOOTSTRAP_SCRIPT_B64' not in cmd[0]:
        raise RuntimeError('Unexpected bootstrap entrypoint; no changes registered')
    marker = 'NOVA_CLOUDWATCH_PREFLIGHT_B64'
    if marker not in cmd[0]:
        prefix = "printf '%s' \"$NOVA_CLOUDWATCH_PREFLIGHT_B64\" | base64 -d > /tmp/nova-cloudwatch-preflight.py; if ! python -u /tmp/nova-cloudwatch-preflight.py; then echo NOVA_CLOUDWATCH_PREFLIGHT_WARNING; fi; "
        cmd[0] = prefix + cmd[0]
    # Preserve dependency ordering unless retry behavior is verified in live command.
    if 'until python /tmp/bootstrap.py' in cmd[0]:
        boot['dependsOn'] = [d for d in boot.get('dependsOn',[]) if d['containerName'] != 'zabbix-web']
    # Only the task-definition registration fields, not ECS response metadata.
    allowed = ('family','taskRoleArn','executionRoleArn','networkMode','containerDefinitions','volumes','placementConstraints','requiresCompatibilities','cpu','memory','pidMode','ipcMode','proxyConfiguration','inferenceAccelerators','ephemeralStorage','runtimePlatform','enableFaultInjection')
    model = {key:td[key] for key in allowed if key in td and td[key] is not None}
    tags = [tag for tag in response.get('tags',[]) if not tag['key'].startswith('aws:')]
    if tags:
        model['tags'] = tags
    with tempfile.TemporaryDirectory(prefix='nova-mon-recovery-') as work:
        p = Path(work)/'task.json'
        p.write_text(json.dumps(model))
        p.chmod(0o600)
        new = aws('ecs','register-task-definition','--cli-input-json','file://'+str(p))['taskDefinition']['taskDefinitionArn']
    print('Previous definition:',old)
    print('New definition:',new)
    print('Applying only monitoring ECS service.',flush=True)
    # Do not overwrite a deployment started concurrently by another operator.
    current = service()
    if current['taskDefinition'] != old or len(current['deployments']) != 1:
        raise RuntimeError('Service changed during preparation; new revision registered but not deployed')
    aws('ecs','update-service','--cluster',CLUSTER,'--service',SERVICE,'--task-definition',new)
    s = wait_stable()
    if s['taskDefinition'] != new:
        raise RuntimeError('ECS rolled back or switched revision')
    tasks = aws('ecs','list-tasks','--cluster',CLUSTER,'--service-name',SERVICE,'--desired-status','RUNNING')['taskArns']
    if len(tasks) != 1:
        raise RuntimeError('Expected one monitoring task')
    task_arn = tasks[0]
    task_id = task_arn.split('/')[-1]
    boot_log = boot['logConfiguration']['options']
    group = boot_log['awslogs-group']
    stream = boot_log['awslogs-stream-prefix']+'/monitoring-bootstrap/'+task_id
    print('Waiting for CloudWatch query and collector health.',flush=True)
    deadline = time.monotonic()+600
    while time.monotonic() < deadline:
        task = aws('ecs','describe-tasks','--cluster',CLUSTER,'--tasks',task_arn)['tasks'][0]
        states = {c['name']:c for c in task['containers']}
        print('Containers:', ', '.join(f"{k}={v.get('lastStatus')}/{v.get('healthStatus')}" for k,v in states.items()),flush=True)
        if task.get('lastStatus') != 'RUNNING':
            raise RuntimeError('New task is no longer running')
        try:
            logs = aws('logs','get-log-events','--log-group-name',group,'--log-stream-name',stream,'--limit','1000')['events']
        except subprocess.CalledProcessError:
            logs = []
        proof = [e['message'].strip() for e in logs if e['message'].strip().startswith('NOVA_CLOUDWATCH_QUERY_PASS points=')]
        if proof and states['monitoring-bootstrap'].get('healthStatus') == 'HEALTHY' and states['grafana'].get('healthStatus') == 'HEALTHY' and states['zabbix-web'].get('healthStatus') == 'HEALTHY' and states['zabbix-server'].get('lastStatus') == 'RUNNING' and states['grafana-db-init'].get('exitCode') == 0:
            print(proof[-1])
            print('PASS: basic CloudWatch query and collector health validated. Dashboard-wide and Zabbix DB checks still required.')
            return
        time.sleep(20)
    raise RuntimeError('Monitoring deployed, but CloudWatch proof or collector health not verified; inspect the new bootstrap logs before changing credentials or retrying')

if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, ValueError, KeyError, OSError) as exc:
        print('FAIL:',type(exc).__name__, str(exc) if isinstance(exc,RuntimeError) else 'See previous AWS or validation output.',file=sys.stderr)
        sys.exit(1)
