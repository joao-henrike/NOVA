"""Official AWS pricing integration for NOVA FinOps.

A cautious public-price estimator, NOT an AWS invoice or an account-specific quote.
Never produces a complete total when unit prices or billable dimensions are missing.
"""
import datetime as dt
import json
import os
import re

LOCATION = "US East (N. Virginia)"
REGION = "us-east-1"
MAX_PAGES = 4
MAX_PRODUCTS = 75

def filters(**fields):
    return [{"Type": "TERM_MATCH", "Field": k, "Value": str(v)} for k,v in fields.items()]

def candidates(call, service_code, attributes):
    """Bounded pagination; fail closed on truncated catalogs and parsing errors."""
    token = None
    products = []
    for _ in range(MAX_PAGES):
        args={"service_code":service_code,"filters":filters(**attributes),
              "format_version":"aws_v1","max_results":25}
        if token:
            args["next_token"]=token
        response=call("pricing","get-products",**args)
        for entry in response.get("PriceList",[]):
            products.append(json.loads(entry) if isinstance(entry,str) else entry)
            if len(products)>MAX_PRODUCTS:
                raise RuntimeError("Pricing result limit exceeded; refine filters")
        token=response.get("NextToken")
        if not token:
            return products
    raise RuntimeError("Pricing results truncated; no price inferred")

def dimensions(product):
    for offer in product.get("terms",{}).get("OnDemand",{}).values():
        for dim in offer.get("priceDimensions",{}).values():
            price=dim.get("pricePerUnit",{}).get("USD")
            if price is None: continue
            begin=str(dim.get("beginRange","0"))
            # Tiered charges not modeled; first-tier-only prices must not become a full rate.
            if begin not in ("0","0.0","0.000000"): continue
            yield {"price_usd":float(price),"unit":dim.get("unit",""),
                   "description":dim.get("description",""),
                   "sku":product.get("product",{}).get("sku"),
                   "usage_type":product.get("product",{}).get("attributes",{}).get("usagetype",""),
                   "begin_range":begin,"end_range":str(dim.get("endRange","Inf"))}

def unique_rate(call, service_code, attr, usage_pattern, unit_pattern):
    try:
        matches=[]
        for product in candidates(call,service_code,attr):
            attributes=product.get("product",{}).get("attributes",{})
            if attributes.get("regionCode") not in (None,REGION): continue
            for item in dimensions(product):
                if re.search(usage_pattern,item["usage_type"],re.I) and re.search(unit_pattern,item["unit"],re.I):
                    if item["end_range"].lower() not in ("inf","infinity"):
                        continue
                    matches.append(item)
        # Multiple SKUs or prices means ambiguous / mismatched catalog.
        values={(x["sku"],x["price_usd"],x["unit"]) for x in matches}
        if len(values)!=1:
            return {"status":"unavailable","reason":"no unique exact SKU/rate; matched "+str(len(values))}
        item=matches[0].copy()
        item["status"]="ok"
        return item
    except (RuntimeError,ValueError,TypeError,KeyError) as exc:
        return {"status":"unavailable","reason":str(exc)[:160]}

def rds_instance_rate(call, instance_class, multi_az):
    deployment="Multi-AZ" if multi_az else "Single-AZ"
    return unique_rate(call,"AmazonRDS",
       {"location":LOCATION,"instanceType":instance_class,"databaseEngine":"PostgreSQL",
        "deploymentOption":deployment},
       r"(InstanceUsage|Multi-AZUsage)",r"^(Hrs|Hours|Hour)$")

def get_rates(call, inventory):
    """Only prices with an unambiguous official rate are accepted."""
    rates={}
    # Fargate standard Linux/x86_64: requires actual architecture before pricing.
    for name,values in inventory.get("services",{}).items():
        arch=values.get("cpu_architecture")
        if arch not in ("X86_64","ARM64"):
            rates["ecs."+name]={"status":"unavailable","reason":"CPU architecture not captured"}
            continue
        label="ARM" if arch=="ARM64" else "x86"
        base={"location":LOCATION,"operatingSystem":"Linux"}
        vcpu=unique_rate(call,"AmazonECS",base,r"Fargate.*vCPU.*(Hours|Hrs)",r"^(Hrs|Hours|Hour)$")
        memory=unique_rate(call,"AmazonECS",base,r"Fargate.*(GB|Memory).*(Hours|Hrs)",r"^(Hrs|Hours|Hour)$")
        # Architectural variants must be distinguished by attributes/SKU, not assumed.
        if arch!="X86_64":
            rates["ecs."+name]={"status":"unavailable","reason":"ARM64 needs architecture-specific SKU match"}
        else:
            rates["ecs."+name]={"status":"ok" if vcpu.get("status")=="ok" and memory.get("status")=="ok" else "partial",
                                "arch":label,"vcpu":vcpu,"memory":memory}
    for record in inventory.get("rds",[]):
        rates["rds."+record["name"]]=rds_instance_rate(call,record.get("class"),record.get("multi_az",False))
    # We intentionally do not infer NAT/ALB prices from a generic EC2 SKU.
    rates["nat_hour"]={"status":"unavailable","reason":"NAT SKU/usage-type not uniquely validated"}
    rates["alb_hour"]={"status":"unavailable","reason":"ALB SKU/LCU classification not uniquely validated"}
    return rates

def scenario(rates, inventory, frontend_count=None, backend_count=None, hours=730):
    """Scenario subtotal includes only verified ECS/RDS rates; unknown costs remain missing."""
    items=[]
    missing=[]
    services=inventory.get("services",{})
    for name, spec in services.items():
        count=(frontend_count if name=="frontend" and frontend_count is not None else
               backend_count if name=="backend" and backend_count is not None else
               spec.get("running",0))
        entry=rates.get("ecs."+name,{})
        if entry.get("status")!="ok":
            missing.append("ecs."+name+": "+str(entry.get("reason","incomplete public pricing")))
            continue
        cpu=spec.get("cpu_units_per_task",0)/1024
        mem=spec.get("memory_mb_per_task",0)/1024
        unit=cpu*entry["vcpu"]["price_usd"]+mem*entry["memory"]["price_usd"]
        items.append({"name":"ecs."+name,"count":count,"hourly_usd":round(count*unit,6),
                      "monthly_usd":round(count*unit*hours,4)})
    for obj in inventory.get("rds",[]):
        name="rds."+obj["name"]
        entry=rates.get(name,{})
        if entry.get("status")=="ok" and obj.get("state")=="available":
            unit=entry["price_usd"]
            items.append({"name":name,"count":1,"hourly_usd":round(unit,6),
                          "monthly_usd":round(unit*hours,4)})
        else:missing.append(name+": rate or operating state unavailable")
    missing.extend(["NAT Gateway hourly/data processing","ALB hourly/LCU",
                    "RDS storage/IOPS/backups","data transfer/IPv4","ECR/CloudWatch/S3/other"])
    return {"hours_modeled":hours,"estimated_partial_monthly_usd":round(sum(i["monthly_usd"] for i in items),4),
            "is_complete":False,"items":items,"unpriced_components":missing,
            "note":"Public on-demand prices only; not AWS bill, discounts, credits or full monthly total."}

def calculator_existing(call, identifier):
    """Read existing AWS Pricing Calculator workload estimate; never create or mutate."""
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}",identifier or ""):
        raise ValueError("Calculator estimate ID must be 1..128 safe characters")
    result=call("bcm-pricing-calculator","get-workload-estimate",identifier=identifier)
    return {"id":result.get("id"),"name":result.get("name"),
            "status":result.get("status"),"rate_type":result.get("rateType"),
            "total_cost_usd":result.get("totalCost") if result.get("costCurrency")=="USD" else None,
            "currency":result.get("costCurrency"),"source":"AWS Pricing Calculator API",
            "warning":"Existing workload estimate; confirm its scope matches the NOVA resources before comparison."}

def assemble(call, inventory, calculator_id=None):
    rates=get_rates(call,inventory)
    scenarios={
        "current":scenario(rates,inventory),
        "frontend_4_backend_4":scenario(rates,inventory,4,4),
        "frontend_6_backend_6":scenario(rates,inventory,6,6)
    }
    outcome={"source":"AWS Price List Query API (public on-demand)",
             "pricing_region":REGION,
             "rate_observed_at_utc":dt.datetime.now(dt.timezone.utc).isoformat(),
             "rates":rates,"scenarios":scenarios,
             "calculator":None,"calculator_error":None}
    if calculator_id:
        try:outcome["calculator"]=calculator_existing(call,calculator_id)
        except (RuntimeError,ValueError) as exc:outcome["calculator_error"]=str(exc)
    return outcome
