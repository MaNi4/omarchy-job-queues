"""The feed itself: what may be changed and when, what the panel is told,
and how a server's answer is read. No server is asked in any of this."""
import json
import threading
import time

from helper import FeedCase, KAMAL

RETRY_ALL = {"backend": "sidekiq", "op": "retry_all", "list": "retry"}


class Unlocking(FeedCase):
    def setUp(self):
        super().setUp()
        self.path = self.project(deploy=KAMAL, deploy_staging="{}\n", deploy_production="{}\n")
        self.feed_ = self.feed({"path": self.path, "development": {"command": "cat"}})

    def writable(self, env):
        return self.feed_.targets["shop/" + env]["writable"]

    def act(self, env, **more):
        self.feed_.action(json.dumps(dict(RETRY_ALL, id="shop/" + env, **more)))
        return self.feed_.started

    def test_everything_but_development_starts_read_only(self):
        self.assertEqual([self.writable(e) for e in ("development", "staging", "production")], [True, False, False])

    def test_a_change_to_a_read_only_environment_goes_nowhere(self):
        self.assertEqual(self.act("production"), [])
        self.assertFalse(self.feed_.message["ok"])
        self.assertIn("read-only", self.feed_.message["text"])

    def test_typing_the_name_unlocks_that_environment_only(self):
        self.feed_.unlock("shop/staging", "staging")
        self.assertTrue(self.writable("staging"))
        self.assertFalse(self.writable("production"))
        self.assertEqual(self.act("staging"), [("shop/staging", {"op": "retry_all", "backend": "sidekiq", "list": "retry"})])
        self.assertEqual(self.act("production"), self.feed_.started[:1])

    def test_any_other_word_unlocks_nothing(self):
        for typed in ("", "Staging", "production", "staging ", "yes"):
            self.feed_.unlock("shop/staging", typed)
            self.assertFalse(self.writable("staging"), repr(typed))
        self.assertFalse(self.feed_.message["ok"])

    def test_it_ends_with_the_time(self):
        self.feed_.unlock("shop/staging", "staging")
        argv, until = self.feed_.unlocked["shop/staging"]
        self.assertAlmostEqual(until, time.time() + 30 * 60, delta=5)
        self.feed_.unlocked["shop/staging"] = (argv, time.time() - 1)
        self.assertEqual(self.act("staging"), [])
        self.assertFalse(self.writable("staging"))

    def test_it_ends_when_asked(self):
        self.feed_.unlock("shop/staging", "staging")
        self.feed_.lock_again("shop/staging")
        self.assertFalse(self.writable("staging"))
        self.assertEqual(self.act("staging"), [])

    def test_it_ends_when_the_environment_is_reached_another_way(self):
        self.feed_.unlock("shop/staging", "staging")
        with open(self.path + "/config/deploy.staging.yml", "w") as f:
            f.write("servers:\n  job:\n    hosts: [198.51.100.9]\n")
        self.feed_.reload()
        self.assertFalse(self.writable("staging"))

    def test_it_is_written_nowhere(self):
        before = self.read_config()
        self.feed_.unlock("shop/staging", "staging")
        self.assertEqual(self.read_config(), before)
        again = self.m.Feed()
        again.quiet = True
        again.reload()
        self.assertFalse(again.targets["shop/staging"]["writable"])

    def test_the_panel_is_told_until_when(self):
        self.feed_.unlock("shop/staging", "staging")
        envs = {e["name"]: e for e in json.loads(self.feed_.line(0))["projects"][0]["envs"]}
        self.assertTrue(envs["staging"]["writable"])
        self.assertGreater(envs["staging"]["until"], time.time())
        self.assertEqual((envs["production"]["writable"], envs["production"]["until"]), (False, 0))

    def test_only_known_changes_with_plain_arguments_are_passed_on(self):
        self.feed_.unlock("shop/staging", "staging")
        for bad in ({"op": "drop_everything"}, {"op": "retry"}, {"list": ""}, {"list": "x" * 201}, {"list": ["retry"]},
                    {"backend": "resque"}):
            self.assertEqual(self.act("staging", **bad), [], bad)
        self.feed_.action("not json")
        self.feed_.action(json.dumps(dict(RETRY_ALL, id="nobody/nowhere")))
        self.assertEqual(self.feed_.started, [])

    def test_what_is_passed_on_has_nothing_but_the_arguments_of_the_change(self):
        self.feed_.unlock("shop/staging", "staging")
        started = self.act("staging", op="delete", job="123|abc", extra="x", queue="default")
        self.assertEqual(started[0][1], {"op": "delete", "backend": "sidekiq", "list": "retry", "id": "123|abc"})


class Asking(FeedCase):
    """run() and ask() against a command on this machine that plays the server."""

    def one(self, command):
        feed = self.feed({"path": self.project(), "development": False,
                          "environments": {"staging": {"command": command}}})
        del feed.start      # the real one is not used either: run is called directly
        return feed

    def test_an_answer_is_found_among_what_the_application_prints(self):
        feed = self.one("cat >/dev/null; echo booting; echo '@@JOBQ@@{\"ok\":true,\"backend\":\"sidekiq\",\"lists\":[]}'; echo bye")
        feed.run("shop/staging")
        state = feed.states["shop/staging"]
        self.assertEqual((state["ok"], state["error"], state["loading"]), (True, "", False))
        self.assertEqual(state["data"]["sidekiq"]["lists"], [])

    def test_the_script_arrives_on_stdin(self):
        got = self.tmp + "/got"
        feed = self.one("cat > %s; echo '@@JOBQ@@{\"ok\":true}'" % got)
        feed.run("shop/staging")
        with open(got) as f:
            script = f.read()
        self.assertTrue(script.startswith('JOBQ_REQUEST = "'))
        self.assertNotIn("def perform", script)

    def test_without_an_answer_the_last_thing_said_is_the_error(self):
        feed = self.one("cat >/dev/null; echo first; echo 'No running job container of shop'; exit 3")
        feed.run("shop/staging")
        self.assertEqual(feed.states["shop/staging"]["error"], "No running job container of shop")

    def test_an_error_from_the_script_is_shown(self):
        feed = self.one("cat >/dev/null; echo '@@JOBQ@@{\"ok\":false,\"error\":\"LoadError: sidekiq\"}'")
        feed.run("shop/staging")
        self.assertEqual((feed.states["shop/staging"]["ok"], feed.states["shop/staging"]["error"]), (False, "LoadError: sidekiq"))

    def test_an_answer_that_never_comes_is_given_up_on(self):
        self.m.TIMEOUT = 1
        feed = self.one("cat >/dev/null; sleep 30")
        began = time.time()
        feed.run("shop/staging")
        self.assertLess(time.time() - began, 10)
        self.assertIn("No answer within", feed.states["shop/staging"]["error"])

    def test_an_endless_answer_is_cut_off(self):
        self.m.MAX_BYTES = 10000
        feed = self.one("cat >/dev/null; yes")
        feed.run("shop/staging")
        self.assertEqual(feed.states["shop/staging"]["error"], "The answer was too long")

    def test_looks_at_one_environment_do_not_pile_up(self):
        calls = []
        go = threading.Event()

        def slow(target, request):
            calls.append(request)
            go.wait(5)
            return {"ok": True, "reached": True, "backend": "sidekiq"}

        feed = self.one("true")
        self.m.ask = slow
        first = threading.Thread(target=feed.run, args=("shop/staging",))
        first.start()
        while not calls:
            time.sleep(0.01)
        for _ in range(8):
            feed.run("shop/staging")        # returns at once: one is on its way
        self.assertEqual(len(calls), 1)
        self.assertTrue(feed.states["shop/staging"]["loading"])
        go.set()
        first.join()
        self.assertFalse(feed.states["shop/staging"]["loading"])
        feed.run("shop/staging")
        self.assertEqual(len(calls), 2)

    def test_a_backend_that_does_not_answer_is_not_asked_twice(self):
        calls = []
        feed = self.one("true")
        feed.targets["shop/staging"]["backends"] = ["sidekiq", "solid_queue"]
        self.m.ask = lambda target, request: calls.append(request) or {"ok": False, "error": "down", "reached": False}
        feed.run("shop/staging")
        self.assertEqual(len(calls), 1)


class Telling(FeedCase):
    def test_a_long_state_is_sent_shorter_rather_than_not_at_all(self):
        rows = [{"id": str(i), "cls": "Job", "args": "a" * 1500, "error": "e" * 1500} for i in range(50)]
        answer = {"ok": True, "stats": {"failed": 50}, "lists": [{"key": "dead", "total": 50, "items": rows}]}
        feed = self.feed({"path": self.project(deploy=KAMAL)})
        feed.states["shop/production"]["data"] = {"sidekiq": answer}
        whole, cut, bare = (feed.line(level) for level in (0, 1, 2))
        self.assertGreater(len(whole), len(cut))
        self.assertGreater(len(cut), len(bare))

        def lists(line):
            return json.loads(line)["projects"][0]["envs"][0]["data"]["sidekiq"]["lists"][0]

        self.assertEqual(len(lists(cut)["items"][0]["error"]), 240)
        self.assertEqual((lists(bare)["items"], lists(bare)["total"]), ([], 50))
        self.assertEqual(len(answer["lists"][0]["items"][0]["error"]), 1500, "what is kept is not cut")

        sent = []
        feed.quiet = False
        self.m.sys.stdout = type("Out", (), {"write": lambda self, s: sent.append(s), "flush": lambda self: None})()
        try:
            for limit, expected in ((len(whole), whole), (len(whole) - 1, cut), (len(cut) - 1, bare)):
                self.m.MAX_LINE = limit
                feed.emit()
                self.assertEqual(sent.pop(), expected + "\n")
        finally:
            self.m.sys.stdout = self.m.sys.__stdout__

    def test_what_a_kamal_config_leaves_out_is_said_once(self):
        path = self.project(deploy=KAMAL.replace("203.0.113.8", "<%= ENV['H'] %>"))
        feed = self.feed({"path": path})
        self.assertEqual(self.notes, [], "nobody is listening yet: --list and --once say nothing")
        feed.serving = True
        feed.seen = None
        feed.reload()
        feed.seen = None
        feed.reload()
        self.assertEqual(len(self.notes), 1)
        self.assertIn("shop production: the server's address could not be read", self.notes[0])


class FillingIn(FeedCase):
    def setUp(self):
        super().setUp()
        self.path = self.project(deploy=KAMAL.replace("203.0.113.8", "<%= ENV['H'] %>"))
        self.feed_ = self.feed({"path": self.path})
        self.values = {"id": "shop/production", "host": "203.0.113.60", "user": "deploy", "port": "22",
                       "service": "shop", "role": "job"}

    def test_only_what_the_project_does_not_say_is_kept(self):
        self.feed_.environment_set(json.dumps(self.values))
        self.assertEqual(self.read_config()["projects"][0]["environments"], {"production": {"host": "203.0.113.60"}})
        target = self.feed_.targets["shop/production"]
        self.assertEqual((target["missing"], target["error"]), ([], ""))
        self.assertEqual(self.feed_.started, [("shop/production", None)], "and it is looked at right away")

    def test_a_value_read_from_the_project_can_be_replaced_and_given_back(self):
        self.feed_.environment_set(json.dumps(dict(self.values, user="ops")))
        self.assertEqual(self.read_config()["projects"][0]["environments"]["production"],
                         {"host": "203.0.113.60", "user": "ops"})
        self.feed_.environment_set(json.dumps(self.values))
        self.assertEqual(self.read_config()["projects"][0]["environments"]["production"], {"host": "203.0.113.60"})

    def test_other_things_said_about_the_environment_are_kept(self):
        self.config({"path": self.path, "environments": {"production": {"runner": "rails"}}})
        self.feed_.seen = None
        self.feed_.reload()
        self.feed_.environment_set(json.dumps(self.values))
        self.assertEqual(self.read_config()["projects"][0]["environments"]["production"],
                         {"runner": "rails", "host": "203.0.113.60"})

    def test_a_jump_host_and_a_key_can_be_said_but_need_not(self):
        self.feed_.environment_set(json.dumps(dict(self.values, proxy="me@bastion.example", key="~/.ssh/shop")))
        self.assertEqual(self.read_config()["projects"][0]["environments"]["production"],
                         {"host": "203.0.113.60", "proxy": "me@bastion.example", "key": "~/.ssh/shop"})
        argv = self.feed_.targets["shop/production"]["argv"]
        self.assertEqual(argv[argv.index("-J") + 1], "me@bastion.example")

    def test_a_key_picked_as_a_file_is_handed_to_the_form(self):
        opened = []
        self.feed_.reopen = lambda: opened.append(1)
        asked = []
        self.m.choose = lambda start, title, directory=True, wait=600: asked.append((title, directory)) or "/srv/keys/shop"
        self.feed_.key_choose("shop/production")
        self.assertEqual(asked, [("Choose the SSH key", False)])
        self.assertEqual(self.feed_.message["picked"], {"id": "shop/production", "key": "/srv/keys/shop"})
        self.assertEqual(self.feed_.message["text"], "")
        self.m.choose = lambda *a, **k: None
        self.feed_.key_choose("shop/production")
        self.assertEqual(self.feed_.message["picked"]["key"], "", "cancelled: the form keeps what it had")
        self.assertEqual(len(opened), 2, "either way the panel comes back")
        self.assertNotIn("environments", self.read_config()["projects"][0], "nothing is saved until the form is")

    def test_what_does_not_look_right_is_not_saved(self):
        before = self.read_config()
        for field, value in (("host", "-oProxyCommand=x"), ("host", ""), ("user", "a b"), ("port", "abc"),
                             ("service", "shop;id"), ("role", "$(id)"), ("proxy", "-J x"), ("key", "-x")):
            self.feed_.environment_set(json.dumps(dict(self.values, **{field: value})))
            self.assertEqual(self.read_config(), before, "%s=%r" % (field, value))
            self.assertFalse(self.feed_.message["ok"])
        self.assertEqual(self.feed_.started, [])

    def test_an_environment_said_whole_in_the_config_is_left_alone(self):
        self.config({"path": self.path, "environments": {"production": {"ssh": "a@b", "command": "true"}}})
        self.feed_.seen = None
        self.feed_.reload()
        before = self.read_config()
        self.feed_.environment_set(json.dumps(self.values))
        self.assertEqual(self.read_config(), before)


class Listing(FeedCase):
    def test_removing_a_project_takes_it_off_the_list_only(self):
        keep, drop = self.project("keep", deploy=KAMAL), self.project("drop", deploy=KAMAL)
        feed = self.feed({"path": keep}, {"path": drop})
        feed.project_remove("drop")
        self.assertEqual(self.read_config(), {"projects": [{"path": keep}]})
        self.assertEqual([p["name"] for p in feed.projects], ["keep"])
        import os
        self.assertTrue(os.path.isdir(drop))

    def test_a_project_changed_on_disk_is_built_again(self):
        path = self.project(deploy=KAMAL)
        feed = self.feed({"path": path})
        self.assertFalse(feed.reload(), "nothing changed")
        with open(path + "/config/deploy.staging.yml", "w") as f:
            f.write("{}\n")
        self.assertTrue(feed.reload())
        self.assertEqual(sorted(feed.targets), ["shop/staging"])


if __name__ == "__main__":
    import unittest
    unittest.main()
