import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "demo_bot", Path(__file__).resolve().parents[1] / "demo_bot/bot.py")
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


def message(user_id, text, username="someone", chat_type="private"):
    return {"from": {"id": user_id, "username": username},
            "chat": {"id": user_id, "type": chat_type}, "text": text}


class DemoTests(unittest.TestCase):
    def setUp(self):
        self.store = module.Store(":memory:")
        self.bot = module.Bot(self.store, 100)

    def tearDown(self):
        self.store.db.close()

    def test_username_cannot_impersonate_admin(self):
        reply = self.bot.reply(message(200, "/grant 200 ton infinite", "b4hra1n"))
        self.assertIn("Нужны права", reply)
        self.assertEqual(self.store.user(200)[2], "0")

    def test_admin_has_infinite_demo_funds(self):
        self.assertEqual(self.store.user(100)[1:], ("infinite", "infinite"))
        self.assertIn("DEMO", self.bot.reply(message(100, "/balance")))

    def test_admin_can_assign_custom_number_and_balance(self):
        reply = self.bot.reply(message(100, "/setnumber 200 +79990000000"))
        self.assertIn("DEMO:+79990000000", reply)
        self.bot.reply(message(100, "/grant 200 ton 12.5"))
        self.assertEqual(self.store.user(200)[2], "12.5")
        self.assertIn("DEMO:", self.bot.reply(message(200, "/number")))
        self.assertEqual(self.store.user(200)[0], "DEMO:+79990000000")

    def test_invalid_amounts_preserve_balance(self):
        for value in ("NaN", "Infinity", "-1", "1e100", "0e999999999", "0.00000000001"):
            with self.assertRaises(ValueError):
                self.store.grant(200, "ton", value)
        self.assertEqual(self.store.user(200)[2], "0")
        with self.assertRaises(ValueError):
            self.store.grant(200, "stars", "1.5")

    def test_number_stable_and_all_replies_marked(self):
        first = self.store.number(200)
        self.assertEqual(first, self.store.number(200))
        for command in ("/start", "/balance", "/number", "/id", "/unknown", "/admin"):
            self.assertIn(module.DISCLAIMER, self.bot.reply(message(200, command)))

    def test_groups_cannot_run_admin_actions(self):
        self.bot.reply(message(100, "/grant 200 ton infinite", chat_type="group"))
        self.assertEqual(self.store.user(200)[2], "0")

    def test_persistence_and_offset(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "demo.sqlite3"
            store = module.Store(path)
            store.number(200, "custom")
            store.grant(200, "stars", "infinite")
            store.offset(1234)
            store.db.close()
            restored = module.Store(path)
            self.assertEqual(restored.user(200), ("DEMO:custom", "infinite", "0"))
            self.assertEqual(restored.offset(), 1234)
            restored.db.close()

    def test_all_numeric_prefix_labels(self):
        for code in range(1, 1000):
            prefix = f"+{code}"
            result = self.store.generate_number(prefix)
            self.assertTrue(result.startswith(prefix))
            self.assertTrue(result[1:].isascii() and result[1:].isdigit())
            self.assertLessEqual(len(result) - 1, 15)
        for prefix in ("7", "+", "+0", "+012", "+1234", "+abc", "+７"):
            with self.assertRaises(ValueError):
                self.store.generate_number(prefix)

    def test_number_command_changes_prefix_and_remains_demo(self):
        reply = self.bot.reply(message(200, "/number +888"))
        self.assertIn("DEMO:+888", reply)
        self.assertIn(module.DISCLAIMER, reply)
        self.assertEqual(self.store.number(200), self.store.user(200)[0])
        reply = self.bot.reply(message(200, "/number +7"))
        self.assertIn("DEMO:+7", reply)


if __name__ == "__main__":
    unittest.main()
