"""FinOps offline contracts, without any AWS access."""
import datetime as dt
import importlib.util
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

FILE=Path(__file__).resolve().parents[1]/"finops.py"
spec=importlib.util.spec_from_file_location("nova_finops",FILE)
f=importlib.util.module_from_spec(spec)
spec.loader.exec_module(f)

class FinopsTests(unittest.TestCase):
    def test_account_guard(self):
        with patch.object(f,"aws",return_value={"Account":"000000000000"}):
            with self.assertRaisesRegex(RuntimeError,"Wrong AWS account"): f.guard()
        with patch.object(f,"aws",return_value={"Account":f.ACCOUNT}):
            f.guard()

    def test_billing_both_scopes_and_next_page_token(self):
        calls=[]
        def fake(service,op,**kw):
            self.assertEqual((service,op),("ce","get-cost-and-usage"))
            calls.append(kw)
            record={"TimePeriod":{"Start":"2026-11-10"},"Estimated":True,
              "Groups":[{"Keys":["Amazon RDS"],"Metrics":{"UnblendedCost":{"Amount":"1.25","Unit":"USD"}}}]}
            if len(calls)==1:return {"ResultsByTime":[record],"NextPageToken":"next"}
            if len(calls)==2:return {"ResultsByTime":[]}
            return {"ResultsByTime":[record]}
        with patch.object(f,"aws",side_effect=fake):
            rows=f.billing(2)
        self.assertEqual({r[1] for r in rows},{"account","project_tagged"})
        self.assertEqual(len(rows),2)
        self.assertEqual(calls[1]["next_page_token"],"next")
        self.assertIn("And",calls[2]["filter"])

    def test_cost_report_and_sqlite(self):
        with tempfile.TemporaryDirectory() as temp:
            db=f.storage(Path(temp)/"history.sqlite3")
            day=f.now().date().isoformat()
            with db:
                db.execute("INSERT INTO cost VALUES (?,?,?,?,?)",(day,"account","AWS ECS",12.5,1))
                db.execute("INSERT INTO cost VALUES (?,?,?,?,?)",(day,"project_tagged","AWS ECS",3.4,1))
            summary=f.report(db)
            self.assertEqual(summary["account_billed_usd"],12.5)
            self.assertEqual(summary["project_tagged_billed_usd"],3.4)
            self.assertIsNone(summary["month_forecast_usd"])
            self.assertEqual(len(f.history(db)["daily_costs"]),2)
            db.close()

    def test_hourly_billing_cache(self):
        with tempfile.TemporaryDirectory() as temp:
            db=f.storage(Path(temp)/"history.sqlite3")
            with db: db.execute("INSERT INTO meta VALUES (?,?)",("billing_at",f.iso(f.now())))
            with patch.object(f,"billing") as query:
                self.assertEqual(f.refresh_billing(db,30),"cached")
                query.assert_not_called()

    def test_no_metric_points_not_zero(self):
        with patch.object(f,"aws",return_value={"Datapoints":[]}):
            self.assertIsNone(f.metric("AWS/ECS","CPUUtilization",{}))

if __name__=="__main__": unittest.main()
