"""Exercise production search handlers with Qt, offscreen, no desktop clipboard."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


class SearchInput(unittest.TestCase):
    def test_production_handlers_in_native_qt_field(self):
        runner=Path('/usr/lib/qt6/bin/qmltestrunner')
        if not runner.exists():self.skipTest('Qt Quick Test not installed')
        text=(ROOT/'BarWidget.qml').read_text()
        start=text.index('            readOnly: true',text.index('id: searchField'))
        end=text.index('            Layout.fillWidth:',start)
        fragment=text[start:end]
        with tempfile.TemporaryDirectory() as directory:
            file=Path(directory)/'tst_search.qml'
            file.write_text('''import QtQuick 6.11
import QtQuick.Controls
import QtTest
import "'''+(ROOT/'UiSafety.js').as_uri()+'''" as UiSafety
Item { width: 400; height: 100
 QtObject { id: searchPasteProc; property bool running: false }
 TextField { id: field; width: 380; height: 40
'''+fragment+'''
 }
 TestCase { name: "SearchSafety"; when: windowShown
  function init() { field.text = ""; field.forceActiveFocus(); searchPasteProc.running=false }
  function test_typed_selection_and_delete() {
   keyClick(Qt.Key_A); keyClick(Qt.Key_B); keyClick(Qt.Key_C)
   compare(field.text, "abc")
   field.select(1, 3); keyClick(Qt.Key_X); compare(field.text, "ax")
   keyClick(Qt.Key_Backspace); compare(field.text, "a")
   compare(field.readOnly, true)
  }
  function test_paste_is_intercepted() {
   keyClick(Qt.Key_V, Qt.ControlModifier)
   compare(searchPasteProc.running, true); compare(field.text, "")
  }
  function test_insert_cap() { field.insertSafe("x".repeat(10000)); compare(field.text.length,256) }
 }
}
''')
            result=subprocess.run([str(runner),'-input',directory],env=dict(os.environ,QT_QPA_PLATFORM='offscreen'),
                                  capture_output=True,text=True,timeout=8)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('5 passed, 0 failed',result.stdout)


if __name__=='__main__':unittest.main()
