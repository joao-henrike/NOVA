#!/usr/bin/env python3
"""NOVA: diagnose CloudWatch source metrics without changing AWS resources.

Usage: python3 scripts/nova-metrics-diagnostic.py [hours]
Requires AWS CLI credentials with sts:GetCallerIdentity and cloudwatch:GetMetricStatistics.
No secrets are read, printed, or sent to third parties.
"""
from __future__ import annotations

import datetime as dt
import json
import subprocess
import sys

REGION = "us-east-1"
EXPECTED_ACCOUNT = "996560371158"
CLUSTER = "cloudstart-dev-cluster"
BASE = "cloudstart-dev"
METRICS = [
    ("Backend CPU", "AWS/ECS", "CPUUtilization",
     {"ClusterName": CLUSTER, "ServiceName": BASE + "-backend"}, "%"),
    ("Backend memory", "AWS/ECS", "MemoryUtilization",
     {"ClusterName": CLUSTER, "ServiceName": BASE + "-backend"}, "%"),
    ("Frontend CPU", "AWS/ECS", "CPUUtilization",
     {"ClusterName": CLUSTER, "ServiceName": BASE + "-frontend"}, "%"),
    ("Frontend memory", "AWS/ECS", "MemoryUtilization",
     {"ClusterName": CLUSTER, "ServiceName": BASE + "-frontend"}, "%"),
    ("Monitoring CPU", "AWS/ECS", "CPUUtilization",
     {"ClusterName": CLUSTER, "ServiceName": BASE + "-monitoring"}, "%"),
    ("Monitoring memory", "AWS/ECS", "MemoryUtilization",
     {"ClusterName": CLUSTER, "ServiceName": BASE + "-monitoring"}, "%"),
    ("Application DB connections", "AWS/RDS", "DatabaseConnections",
     {"DBInstanceIdentifier": BASE + "-db"}, ""),
    ("Monitoring DB connections", "AWS/RDS", "DatabaseConnections",
     {"DBInstanceIdentifier": BASE + "-monitoring-db"}, ""),
]


def aws(*args: str) -> dict | str:
    result = subprocess.run(
        ["aws", "--region", REGION, "--no-cli-pager", *args, "--output", "json"],
        capture_output=True, text=True, check=True, timeout=35,
    )
    return json.loads(result.stdout)


def utc(value: dt.datetime) -> str:
    return value.isoformat(timespec="seconds").replace("+00:00", "Z")


def main() -> int:
    if len(sys.argv) > 2 or (len(sys.argv) == 2 and sys.argv[1] in ("--help", "-h")):
        print("Uso: python3 scripts/nova-metrics-diagnostic.py [horas; padrao 6]")
        return 0 if len(sys.argv) == 2 and sys.argv[1] in ("--help", "-h") else 2
    try:
        hours = int(sys.argv[1]) if len(sys.argv) == 2 else 6
    except ValueError:
        print("ERRO: numero de horas invalido", file=sys.stderr)
        return 2
    if not 1 <= hours <= 24:
        print("ERRO: use entre 1 e 24 horas", file=sys.stderr)
        return 2
    try:
        identity = aws("sts", "get-caller-identity")
        account = identity.get("Account")
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired,
            ValueError) as exc:
        print(f"ERRO: nao foi possivel verificar a identidade AWS: {type(exc).__name__}", file=sys.stderr)
        return 2
    if account != EXPECTED_ACCOUNT:
        print(f"ERRO: conta incorreta ({account}); esperado {EXPECTED_ACCOUNT}", file=sys.stderr)
        return 2

    now = dt.datetime.now(dt.timezone.utc)
    start = now - dt.timedelta(hours=hours)
    print("NOVA | DADOS REAIS DO CLOUDWATCH (SOMENTE LEITURA)")
    print(f"Conta: {account} | Regiao: {REGION} | Janela: ultimas {hours}h")
    print("Consulta na resolucao de 60 segundos, sem media de 5 minutos do Grafana.")
    print()
    counts = {"VARIANDO": 0, "ESTAVEL": 0, "SEM DADOS": 0, "ERRO": 0}
    for label, namespace, metric, dimensions, unit in METRICS:
        cmd = [
            "cloudwatch", "get-metric-statistics",
            "--namespace", namespace, "--metric-name", metric,
            "--start-time", utc(start), "--end-time", utc(now),
            "--period", "60", "--statistics", "Average",
            "--dimensions",
            *(f"Name={k},Value={v}" for k, v in dimensions.items()),
        ]
        try:
            result = aws(*cmd)
            points = sorted(result.get("Datapoints", []), key=lambda p: p["Timestamp"])
            vals = [float(p["Average"]) for p in points]
            if not vals:
                print(f"[SEM DADOS] {label:27} | CloudWatch nao retornou amostras")
                counts["SEM DADOS"] += 1
                continue
            lo, hi = min(vals), max(vals)
            age = (now - dt.datetime.fromisoformat(
                points[-1]["Timestamp"].replace("Z", "+00:00")
            )).total_seconds() / 60
            delta = hi - lo
            threshold = 0.05 if unit == "%" else 0.05
            status = "ESTAVEL" if delta <= threshold else "VARIANDO"
            counts[status] += 1
            suffix = f"{unit}"
            print(
                f"[{status:8}] {label:27} | {len(vals):3} amostras | "
                f"min={lo:.3f}{suffix} max={hi:.3f}{suffix} "
                f"atual={vals[-1]:.3f}{suffix} | ultima ha {age:.0f}min"
            )
            if age > 20:
                print("             ATENCAO: a ultima amostra tem mais de 20 minutos")
        except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired,
                KeyError, TypeError, ValueError) as exc:
            counts["ERRO"] += 1
            print(f"[ERRO    ] {label:27} | {type(exc).__name__}")

    print()
    print("RESUMO:", " | ".join(f"{k}: {v}" for k, v in counts.items()))
    print("ESTAVEL com pontos significa linha reta real, nao falha no dashboard.")
    print("Se CloudWatch retorna amostras, mas Grafana diz No data, investigue a consulta/data source.")
    print("As duas metricas do Zabbix nao sao consultadas por este script.")
    return 1 if counts["ERRO"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
