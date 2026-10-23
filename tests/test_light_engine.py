"""Unit tests for the light engine's pure helpers (mirrors the Rust tests).
Run: python3 -I tests/test_light_engine.py"""
import importlib.util
import os
import unittest

_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "task_manager_light.py")
_spec = importlib.util.spec_from_file_location("tm_light", _path)
tm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tm)


class LightEngine(unittest.TestCase):
    def test_targets(self):
        self.assertEqual(tm.parse_target("1234"), (1234, None))
        self.assertEqual(tm.parse_target("1234:987654"), (1234, 987654))
        for bad in ("1234:", ":5", "-5", "1", "12x", "99999999999", "12:3:4", "١٢٣"):
            self.assertIsNone(tm.parse_target(bad), bad)

    def test_starttime(self):
        stat = "4242 (Web (Content) x) S 1 4242 4242 0 -1 4194560 100 0 0 0 5 6 0 0 20 0 1 0 778899 1000 50"
        self.assertEqual(tm.parse_starttime(stat), 778899)
        self.assertIsNone(tm.parse_starttime(stat.replace(") S", ") Z")))
        self.assertIsNone(tm.parse_starttime("garbage"))

    def test_prefs(self):
        self.assertIs(tm.pref_value("bool", "1"), True)
        self.assertIsNone(tm.pref_value("bool", "yes"))
        self.assertEqual(tm.pref_value("mode", "graph"), "graph")
        self.assertIsNone(tm.pref_value("mode", "x"))
        self.assertIsNone(tm.pref_value("px", "200"))
        self.assertIsNone(tm.pref_value("ram", "100"))
        self.assertEqual(tm.pref_value("cpu", "0"), 0)
        self.assertEqual(tm.pref_value("engine", "light"), "light")
        self.assertIsNone(tm.pref_value("engine", "rust"))

    def test_freeze_only_at_real_scarcity(self):
        self.assertFalse(tm.freeze_critical(17.0, 6.0, 45.8, 30.0))
        self.assertFalse(tm.freeze_critical(55.8, 6.0, 90.0, 30.0))
        self.assertTrue(tm.freeze_critical(5.0, 6.0, 0.0, 30.0))
        self.assertTrue(tm.freeze_critical(8.0, 6.0, 35.0, 30.0))
        self.assertFalse(tm.freeze_critical(8.0, 6.0, 15.0, 30.0))

    def test_cgroup_paths(self):
        root = tm.user_root()
        self.assertTrue(tm.cg_path_ok(root + "/app.slice/app-x.scope"))
        self.assertFalse(tm.cg_path_ok(root))
        self.assertFalse(tm.cg_path_ok(root + "/../x"))
        self.assertFalse(tm.cg_path_ok("/system.slice/x.service"))
        self.assertFalse(tm.cg_path_ok(None))

    def test_addresses(self):
        self.assertTrue(tm.valid_address("0xaaab0a3c8500"))
        for bad in ("0x", "0xzz", '0x1" }) os.exit() --', None):
            self.assertFalse(tm.valid_address(bad))

    def test_reset_worker_match(self):
        self.assertTrue(tm.is_normal_reset(["/x/bin/task-manager", "shell-reset"]))
        self.assertTrue(tm.is_normal_reset(["/usr/bin/python3", "-I", "-S", "/x/bin/task_manager_light.py", "shell-reset"]))
        self.assertFalse(tm.is_normal_reset(["/x/bin/task-manager", "shell-reset", "force"]))
        self.assertFalse(tm.is_normal_reset(["vim", "shell-reset"]))

    # Governor: mirrors the tests in bin/task-manager-rs/src/governor.rs.
    def test_gov_level_hysteresis(self):
        L = tm.gov_level
        self.assertEqual(L(40.0, 0.0, "calm"), "calm")
        self.assertEqual(L(24.0, 0.0, "calm"), "elevated")
        self.assertEqual(L(30.0, 25.0, "calm"), "elevated")
        self.assertEqual(L(50.0, 80.0, "calm"), "calm")
        self.assertEqual(L(27.0, 0.0, "elevated"), "elevated")
        self.assertEqual(L(31.0, 0.0, "elevated"), "calm")
        self.assertEqual(L(11.0, 0.0, "elevated"), "critical")
        self.assertEqual(L(13.0, 0.0, "critical"), "critical")
        self.assertEqual(L(16.0, 0.0, "critical"), "elevated")

    def test_gov_classification(self):
        C = tm.gov_classify
        ses = "/user.slice/user-1001.slice/user@1001.service/session.slice/wayland-wm@hyprland.desktop.service"
        self.assertEqual(C(ses, [], True, True), "protected")
        self.assertEqual(C("/u/app.slice/hermes-gateway.service", ["hermes"], False, False), "protected")
        chrome = "/u/app.slice/app-com.google.Chrome-1.scope"
        self.assertEqual(C(chrome, [], True, True), "foreground")
        self.assertEqual(C(chrome, [], False, True), "interactive")
        agent = "/u/app.slice/app-t3code.slice/app-t3code-agents.slice/t3code-claude-1.scope"
        self.assertEqual(C(agent, [], False, False), "batch")
        self.assertEqual(C("/u/app.slice/t3code.service", [], False, False), "service")
        self.assertEqual(C("/u/app.slice/omarchy-task-manager.service", [], False, False), "protected")

    def test_gov_squeeze(self):
        N, M, g = tm.gov_next_high, tm.MIB, 1024 * tm.MIB
        a = N(4 * g, None, "elevated", True, 0.0, 0)
        self.assertEqual(a[0], "set")
        self.assertTrue(3 * g < a[1] < 4 * g)
        self.assertLess(N(4 * g, None, "critical", True, 0.0, 0)[1], a[1])
        self.assertEqual(N(300 * M, tm.GOV_FLOOR, "critical", True, 0.0, 0), ("keep",))
        self.assertEqual(N(100 * M, None, "critical", True, 0.0, 0), ("keep",))
        self.assertEqual(N(g // 2, 2 * g, "critical", True, 0.0, 0), ("keep",))
        b = N(2 * g, 2 * g, "elevated", True, 0.0, 0)
        self.assertTrue(b[0] == "set" and g < b[1] < 2 * g)
        self.assertEqual(N(g, g, "critical", True, 0.0, 2 * g), ("keep",))
        self.assertEqual(N(3 * g, None, "critical", True, 0.0, 8 * g), ("keep",))
        self.assertEqual(N(4 * g, 4 * g, "critical", True, 0.0, 8 * g), ("keep",))
        self.assertEqual(N(g, g, "critical", True, 55.0, 0), ("set", g + g // 16))
        self.assertEqual(N(g, None, "critical", True, 55.0, 0), ("keep",))
        self.assertEqual(N(g, g, "calm", False, 0.0, 0), ("set", g + g // 4))
        self.assertEqual(N(g, g + 400 * M, "calm", False, 0.0, 0), ("release",))
        self.assertEqual(N(g, None, "calm", False, 0.0, 0), ("keep",))

    def test_gov_reclaim_chunks(self):
        R, M = tm.gov_reclaim_chunk, tm.MIB
        self.assertEqual(R(100 * M, 0.0, 1024 * M), 0)
        self.assertEqual(R(2048 * M, 0.0, 1024 * M), tm.RECLAIM_CHUNK_MAX)
        self.assertEqual(R(400 * M, 0.0, 1024 * M), 20 * M)
        self.assertEqual(R(2048 * M, 0.0, 10 * M), 10 * M)
        self.assertEqual(R(2048 * M, 30.0, 1024 * M), 0)


if __name__ == "__main__":
    unittest.main()
