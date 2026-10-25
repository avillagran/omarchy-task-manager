"""Unit tests for the light engine's pure helpers (mirrors the Rust tests).
Run: python3 -I tests/test_light_engine.py"""
import importlib.util
import os
import unittest
from unittest.mock import patch
from contextlib import ExitStack
import subprocess
import time

_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "task_manager_light.py")
_spec = importlib.util.spec_from_file_location("tm_light", _path)
tm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tm)


class LightEngine(unittest.TestCase):
    def test_watch_recovers_and_can_freeze_same_app_again(self):
        clock, handler, freezes, resumes = [0.0], [], [], []

        class Paused:
            name, mb = "chrome", 200
            def prune(self):
                return True
            def resume(self):
                resumes.append(clock[0])
                return True

        def freeze(skip):
            self.assertNotIn("chrome", skip)
            freezes.append(clock[0])
            return Paused()

        def sleep(seconds):
            clock[0] += seconds
            if clock[0] >= 40:
                handler[0]()

        def mem():
            critical = clock[0] < 6 or 20 <= clock[0] < 28
            return (16000, 500 if critical else 8000, 0, 0, 0, 0)

        with ExitStack() as stack:
            for name, value in {"runtime": unittest.mock.Mock(), "Governor": unittest.mock.Mock(),
                                "crit_avail_pct": lambda: 6.0, "crit_cpu_pct": lambda: 0.0,
                                "mem_info": mem, "freeze_biggest": freeze,
                                "sample_history": unittest.mock.Mock(),
                                "release_everything": unittest.mock.Mock()}.items():
                stack.enter_context(patch.object(tm, name, value))
            stack.enter_context(patch.dict(os.environ, {}, clear=True))
            stack.enter_context(patch.object(tm.signal, "signal", side_effect=lambda _, fn: handler.append(fn)))
            stack.enter_context(patch.object(tm.time, "monotonic", side_effect=lambda: clock[0]))
            stack.enter_context(patch.object(tm.time, "sleep", side_effect=sleep))
            stack.enter_context(patch.object(tm.sys, "stderr", unittest.mock.Mock()))
            tm.cmd_watch(False)
        self.assertEqual(len(freezes), 2)
        self.assertEqual(len(resumes), 2)
        self.assertGreaterEqual(resumes[0], 16)
        self.assertGreaterEqual(resumes[1], 38)
        self.assertLess(resumes[0], freezes[1])

    def test_auto_resume_real_child_and_reject_wrong_starttime(self):
        child = subprocess.Popen(["/usr/bin/sleep", "30"])
        def wait_stopped(wanted):
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                if tm.pid_stopped(child.pid) == wanted:
                    return
                time.sleep(0.005)
            self.fail("child did not reach expected stop state")
        try:
            st = tm.start_time(child.pid)
            self.assertIsNotNone(st)
            self.assertTrue(tm.signal_pid(child.pid, st, tm.signal.SIGSTOP))
            wait_stopped(True)
            with patch.object(tm, "marker_remove"):
                wrong = tm.AutoPause("child", 0, ([], []), ([(child.pid, st + 1)], []))
                self.assertFalse(wrong.resume())
                self.assertTrue(tm.pid_stopped(child.pid))
                correct = tm.AutoPause("child", 0, ([], []), ([(child.pid, st)], []))
                self.assertTrue(correct.resume())
                wait_stopped(False)
                # The same process can be stopped and recovered a second time.
                self.assertTrue(tm.signal_pid(child.pid, st, tm.signal.SIGSTOP))
                wait_stopped(True)
                again = tm.AutoPause("child", 0, ([], []), ([(child.pid, st)], []))
                self.assertTrue(again.resume())
                wait_stopped(False)
        finally:
            child.kill()
            child.wait()

    def test_recovery_waits_restarts_and_spaces_apps(self):
        r = tm.Recovery()
        self.assertFalse(r.ready(0, True))
        self.assertFalse(r.ready(9.5, True))
        self.assertFalse(r.ready(10, False))
        self.assertFalse(r.ready(11, True))
        self.assertFalse(r.ready(20.5, True))
        self.assertTrue(r.ready(21, True))
        self.assertFalse(r.ready(21.5, True))
        self.assertTrue(r.ready(31, True))
        self.assertFalse(r.ready(32, False))

    def test_recovery_requires_memory_psi_and_cpu_headroom(self):
        good = (16000, 30.0, 0.0, 0.0, 50.0, 90.0, 6.0, 12.0)
        self.assertTrue(tm.recovery_healthy(*good))
        for index, value in ((0, 0), (1, 12.0), (2, 10.0), (3, 1.0), (4, 80.0), (6, 21.0)):
            args = list(good)
            args[index] = value
            self.assertFalse(tm.recovery_healthy(*args), args)
        args = list(good)
        args[4:6] = [100.0, 0.0]
        self.assertTrue(tm.recovery_healthy(*args))

    def test_auto_pause_owns_only_new_markers(self):
        before = ([(10, 1)], ["manual"])
        after = ([(10, 1), (20, 2)], ["manual", "auto"])
        p = tm.AutoPause("browser", 100, before, after)
        with patch.object(tm, "cg_write", return_value=True) as cg, \
                patch.object(tm, "signal_pid", return_value=True) as sig, \
                patch.object(tm, "marker_remove") as rm, \
                patch.object(tm, "marker_remove_scope") as rms:
            self.assertTrue(p.resume())
            self.assertEqual(cg.call_args_list, [unittest.mock.call("auto", "memory.high", "max"),
                                               unittest.mock.call("auto", "cgroup.freeze", "0")])
            sig.assert_called_once_with(20, 2, tm.signal.SIGCONT)
            rm.assert_called_once_with(20)
            rms.assert_called_once_with("auto")

    def test_auto_pause_drops_manual_thaw_and_reused_pid(self):
        p = tm.AutoPause("browser", 100, ([], []), ([(20, 2)], ["auto"]))
        with patch.object(tm, "marker_read", return_value=([(20, 2)], [])), \
                patch.object(tm, "start_time", return_value=3), \
                patch.object(tm, "signal_pid") as sig:
            self.assertFalse(p.prune())
            self.assertTrue(p.resume())
            sig.assert_not_called()

    def test_auto_pause_retries_failed_thaw_without_signalling_reuse(self):
        p = tm.AutoPause("browser", 100, ([], []), ([(20, 2)], ["auto"]))
        with patch.object(tm, "cg_write", return_value=False) as cg, \
                patch.object(tm, "signal_pid", return_value=False), \
                patch.object(tm, "marker_remove") as rm:
            self.assertFalse(p.resume())
            cg.assert_called_once_with("auto", "memory.high", "max")
            rm.assert_not_called()
            self.assertEqual(p.pids, [(20, 2)])

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
