"""Names from the XLSX remain separated by resource/parameter ID namespace."""
from pathlib import Path
import unittest
from lupa.luajit21 import LuaRuntime

ROOT=Path(__file__).resolve().parents[1]


class HashReferenceTests(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime()
        self.lua.execute('package.path=.....";"..package.path',(ROOT/'offline/?.lua').as_posix())
        self.ref=self.lua.eval("require('zh_reference')")

    def test_unsigned_attachment_ids_keep_all_32_bits(self):
        self.assertEqual(self.ref.parameter_name('attachment',3885038159),'反射式瞄具 Mk2')
        self.assertEqual(self.ref.parameter_name('attachment',1485903299),'机械瞄具')
        self.assertIsNone(self.ref.parameter_name('attachment',-409929137))

    def test_equal_ids_in_different_tables_do_not_share_names(self):
        self.assertEqual(self.ref.parameter_name('beam',1),'LAS-98 激光大炮')
        self.assertEqual(self.ref.parameter_name('arc',1),'光能者猎杀器')
        self.assertIsNone(self.ref.parameter_name('unconfirmed_mount_node',1))
        self.assertIsNone(self.ref.resource_name('0000000000000001'))

    def test_existing_entity_lookup_and_new_alias_both_work(self):
        self.assertIn('AR-23',self.ref.resource_name('968211C0033DCE64'))
        self.assertEqual(self.ref.translate('CQC-20 Breaching Hammer (Hellpod)'),'CQC-20 破门锤（支架）')
        self.assertIsNone(self.ref.translate('unverified entity'))


if __name__=='__main__':unittest.main()
