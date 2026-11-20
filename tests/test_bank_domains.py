import sys
import unittest
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"scripts"))
from bank_domains import choose


class BankDomains(unittest.TestCase):
    def test_preserves_other_processes_and_replays(self):
        other={"name":"other","version":"5","state":"production","ref":"unchanged","extra":42}
        old={"name":"daily-position","version":"1.0.0","state":"production","ref":"old"}
        document={"domain":"treasury","definitions":[other,old],"metadata":{"custom":True}}
        selected={"daily-position":{"digest":"sha256:"+"1"*64}}
        after=choose(document,"treasury",selected)
        self.assertEqual(after["definitions"][0],other)
        self.assertEqual(after["metadata"],document["metadata"])
        self.assertEqual(after["definitions"][1]["state"],"replaced")
        self.assertEqual(choose(after,"treasury",selected),after)
        self.assertEqual(old["state"],"production")
    def test_ambiguous_versions_rejected(self):
        row={"name":"daily-position","version":"2.0.0","state":"production","ref":"old"}
        with self.assertRaises(RuntimeError):
            choose({"domain":"treasury","definitions":[row,row]},"treasury",{})
