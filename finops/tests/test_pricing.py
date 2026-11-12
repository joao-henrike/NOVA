"""Official pricing unit contracts. No AWS calls."""
import importlib.util
import json
from pathlib import Path
import unittest

MOD=Path(__file__).resolve().parents[1]/"pricing.py"
spec=importlib.util.spec_from_file_location("nova_finops_pricing",MOD)
p=importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)

def sku(rate,usage="USE1-Fargate-vCPU-Hours:perCPU",unit="Hrs",sku_id="sku1"):
    return {"product":{"sku":sku_id,"attributes":{"regionCode":"us-east-1","usagetype":usage}},
            "terms":{"OnDemand":{"term":{"priceDimensions":{"d":{
             "pricePerUnit":{"USD":str(rate)},"unit":unit,"beginRange":"0",
             "endRange":"Inf","description":"On demand"}}}}}}}

class PricingTests(unittest.TestCase):
    def test_exact_rate(self):
        def fake(svc,op,**kwargs):
            self.assertEqual((svc,op),("pricing","get-products"))
            return {"PriceList":[json.dumps(sku("0.05"))]}
        result=p.unique_rate(fake,"AmazonECS",{"location":p.LOCATION},r"Fargate.*vCPU",r"^Hrs$")
        self.assertEqual(result["status"],"ok")
        self.assertAlmostEqual(result["price_usd"],0.05)

    def test_multiple_skus_fail_closed(self):
        def fake(*args,**kwargs):
            return {"PriceList":[json.dumps(sku(".05")),json.dumps(sku(".07",sku_id="sku2"))]}
        value=p.unique_rate(fake,"AmazonECS",{},r"Fargate.*vCPU",r"Hrs")
        self.assertEqual(value["status"],"unavailable")

    def test_tiered_dimension_not_assumed(self):
        obj=sku(".05")
        dim=obj["terms"]["OnDemand"]["term"]["priceDimensions"]["d"]
        dim["endRange"]="100"
        def fake(*args,**kwargs):return {"PriceList":[obj]}
        result=p.unique_rate(fake,"AmazonECS",{},r"Fargate.*vCPU",r"Hrs")
        self.assertEqual(result["status"],"unavailable")

    def test_pagination_capped(self):
        def fake(*args,**kwargs):return {"PriceList":[],"NextToken":"next"}
        with self.assertRaisesRegex(RuntimeError,"truncated"):
            p.candidates(fake,"AmazonECS",{})

    def test_monthly_scenario_partial_not_total(self):
        rates={"ecs.frontend":{"status":"ok","vcpu":{"price_usd":0.05},
                  "memory":{"price_usd":0.006}}}
        inv={"services":{"frontend":{"running":2,"cpu_units_per_task":1024,
                                     "memory_mb_per_task":1024}},"rds":[]}
        result=p.scenario(rates,inv,frontend_count=4,hours=730)
        self.assertFalse(result["is_complete"])
        self.assertEqual(result["items"][0]["count"],4)
        self.assertAlmostEqual(result["estimated_partial_monthly_usd"],4*730*.056)

    def test_calculator_existing_read_only(self):
        operations=[]
        def fake(service,op,**kwargs):
            operations.append((service,op))
            return {"id":"abc","totalCost":42.5,"costCurrency":"USD","status":"VALID"}
        response=p.calculator_existing(fake,"abc")
        self.assertEqual(response["total_cost_usd"],42.5)
        self.assertEqual(operations,[("bcm-pricing-calculator","get-workload-estimate")])
        with self.assertRaises(ValueError):
            p.calculator_existing(fake,"../bad/id")

if __name__=="__main__":
    unittest.main()
