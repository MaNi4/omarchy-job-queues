"""What is read from a project's own files, and what is made of it."""
import os
import shutil
import stat
import subprocess
import time
import unittest

from helper import FeedCase, KAMAL


def fields(**known):
    """What a Kamal config says, with nothing said about the rest."""
    return dict({"host": "", "user": "root", "port": "22", "service": "", "role": "", "proxy": "", "key": ""}, **known)


SHOP = fields(host="203.0.113.8", user="deploy", service="shop", role="job")


class Kamal(FeedCase):
    def environments(self, role="", **files):
        return self.m.kamal_environments(self.project(**files), role)

    def test_one_deploy_file_is_production(self):
        envs = self.environments(deploy=KAMAL)
        self.assertEqual(list(envs), ["production"])
        self.assertEqual(envs["production"]["destination"], "")
        self.assertEqual(envs["production"]["fields"], SHOP)

    def test_a_file_per_destination_is_merged_over_the_base(self):
        envs = self.environments(deploy=KAMAL, deploy_staging="servers:\n  job:\n    hosts: [203.0.113.50]\n",
                                 deploy_production="ssh:\n  port: 2222\n")
        self.assertEqual(sorted(envs), ["production", "staging"])
        self.assertEqual(envs["staging"]["fields"]["host"], "203.0.113.50")
        self.assertEqual(envs["staging"]["fields"]["user"], "deploy")
        self.assertEqual(envs["staging"]["destination"], "staging")
        self.assertEqual(envs["production"]["fields"]["host"], "203.0.113.8")
        self.assertEqual(envs["production"]["fields"]["port"], "2222")

    def test_examples_are_not_destinations(self):
        envs = self.environments(deploy=KAMAL, deploy_example=KAMAL, deploy_staging="{}\n")
        self.assertEqual(list(envs), ["staging"])

    def test_no_kamal_config_no_environments(self):
        self.assertEqual(self.environments(), {})

    def test_the_role_that_runs_the_jobs_is_found(self):
        by_cmd = "service: s\nservers:\n  web: [h1]\n  background:\n    hosts: [h2]\n    cmd: bin/jobs\n"
        self.assertEqual(self.environments(deploy=by_cmd)["production"]["fields"]["role"], "background")
        by_name = "service: s\nservers:\n  web: [h1]\n  workers: [h2]\n"
        self.assertEqual(self.environments(deploy=by_name)["production"]["fields"]["host"], "h2")
        only_web = "service: s\nservers:\n  - h1\n"
        self.assertEqual(self.environments(deploy=only_web)["production"]["fields"]["role"], "web")

    def test_a_role_asked_for_is_the_one_taken(self):
        fields = self.environments(role="web", deploy=KAMAL)["production"]["fields"]
        self.assertEqual((fields["role"], fields["host"]), ("web", "203.0.113.7"))

    def test_a_jump_host_and_keys_are_read(self):
        ssh = "ssh:\n  user: deploy\n  proxy: bastion.example\n  keys: [config/deploy_key, ~/.ssh/other]\n  keys_only: true\n"
        spec = self.environments(deploy=KAMAL.replace("ssh:\n  user: deploy\n", ssh))["production"]
        self.assertEqual(spec["fields"], dict(SHOP, proxy="root@bastion.example", key="config/deploy_key"))
        self.assertEqual((spec["more_keys"], spec["keys_only"], spec["coded"]), (["~/.ssh/other"], True, []))

    def test_a_jump_host_keeps_the_user_it_names(self):
        spec = self.environments(deploy=KAMAL + "  proxy: jump@bastion.example:2222\n")["production"]
        self.assertEqual(spec["fields"]["proxy"], "jump@bastion.example:2222")

    def test_the_user_is_root_unless_said(self):
        fields = self.environments(deploy="service: s\nservers:\n  - h1\n")["production"]["fields"]
        self.assertEqual((fields["user"], fields["port"]), ("root", "22"))

    def test_hosts_with_tags_are_read(self):
        fields = self.environments(deploy="service: s\nservers:\n  job:\n    hosts:\n      - h9: [tag]\n")["production"]["fields"]
        self.assertEqual(fields["host"], "h9")


class Code(FeedCase):
    """ERB in a Kamal config is stepped over: never run, never guessed."""

    def fields(self, text):
        return self.m.kamal_environments(self.project(deploy=text), "")["production"]["fields"]

    def test_what_code_decides_is_not_known(self):
        found = self.fields(KAMAL.replace("203.0.113.8", '<%= ENV["HOST"] %>')
                             .replace("user: deploy", "user: <%= ENV.fetch('U', 'deploy') %>")
                             .replace("service: shop", "service: <%= app %>"))
        self.assertEqual(found, fields(user="", role="job"))

    def test_code_elsewhere_changes_nothing(self):
        found = self.fields(KAMAL.replace("- 203.0.113.7", "- <%= ENV['WEB'] %>")
                             + "<% if ENV['CI'] %>\nimage: ci/shop\n<% end %>\nenv:\n  secret:\n    - <%= 'KEY' %>\n")
        self.assertEqual(found, SHOP)

    def test_code_is_not_run(self):
        marker = os.path.join(self.tmp, "ran")
        self.fields(KAMAL + "x: <%= File.write('" + marker + "', '1') %>\n<% `touch " + marker + "` %>\n")
        self.assertFalse(os.path.exists(marker))

    def test_servers_made_by_code_lack_the_host_and_the_role(self):
        found = self.fields("service: <%= name %>\nservers: <%= hosts %>\n")
        self.assertEqual(found, fields())

    def test_a_file_that_is_no_yaml_even_then_says_so(self):
        found = self.m.kamal_environments(self.project(deploy="<%= render 'everything' %>\nservers: [h]\n"), "")
        self.assertIsInstance(found["production"], self.m.ConfigError)
        self.assertIn("config/deploy.yml", str(found["production"]))


class Projects(FeedCase):
    def build(self, entry=None, name="shop", **files):
        path = self.project(name, **files)
        return self.m.build_project(dict(entry or {}, path=path), path)

    def env(self, project, name):
        return next(t for t in project["envs"] if t["name"] == name)

    def test_the_backend_is_the_gem_in_the_lockfile(self):
        self.assertEqual(self.m.backends_of(self.project("a", lock="sidekiq (7.3.9)")), ["sidekiq"])
        self.assertEqual(self.m.backends_of(self.project("b", lock="solid_queue (1.1.0)")), ["solid_queue"])
        self.assertEqual(self.m.backends_of(self.project("c", lock="sidekiq-cron (2.0)")), [])
        self.assertEqual(self.m.backends_of(os.path.join(self.tmp, "nowhere")), [])

    def test_a_kamal_deployment_is_entered_over_ssh_into_its_container(self):
        target = self.env(self.build(deploy=KAMAL), "production")
        self.assertEqual(target["error"], "")
        argv = target["argv"]
        self.assertEqual(argv[0], self.m.SSH)
        self.assertEqual(argv[-3:-1], ["--", "deploy@203.0.113.8"])
        self.assertIn("BatchMode=yes", argv)
        self.assertIn("label=service=shop", argv[-1])
        self.assertIn("label=role=job", argv[-1])
        self.assertTrue(argv[-1].endswith("bin/rails runner -"))
        self.assertTrue(target["fast"][-1].endswith("bundle exec ruby -"), "Sidekiq is tried without the application first")

    def test_solid_queue_always_gets_the_application(self):
        path = self.project(lock="solid_queue (1.1.0)", deploy=KAMAL)
        target = self.env(self.m.build_project({"path": path}, path), "production")
        self.assertIsNone(target["fast"])

    def test_only_development_may_be_changed_from_the_start(self):
        project = self.build({"development": {"command": "cat", "cwd": "/"}}, deploy=KAMAL, deploy_staging="{}\n")
        self.assertEqual({t["name"]: t["writable"] for t in project["envs"]}, {"development": True, "staging": False})
        self.assertTrue(all(not t["production"] for t in project["envs"]))
        self.assertTrue(self.env(self.build(name="other", deploy=KAMAL), "production")["production"])

    def test_writable_in_the_config_unlocks_nothing(self):
        project = self.build({"writable": True, "environments": {"production": {"writable": True}}}, deploy=KAMAL)
        self.assertFalse(self.env(project, "production")["writable"])

    def test_what_code_decides_is_asked_for(self):
        target = self.env(self.build(deploy=KAMAL.replace("203.0.113.8", "<%= ENV['H'] %>")), "production")
        self.assertEqual(target["missing"], ["host"])
        self.assertIsNone(target["argv"])
        self.assertIn("does not say the server's address", target["error"])

    def test_what_was_filled_in_completes_it(self):
        entry = {"environments": {"production": {"host": "203.0.113.60"}}}
        target = self.env(self.build(entry, deploy=KAMAL.replace("203.0.113.8", "<%= ENV['H'] %>")), "production")
        self.assertEqual((target["missing"], target["error"]), ([], ""))
        self.assertIn("deploy@203.0.113.60", target["argv"])
        self.assertEqual(target["found"]["host"], "", "what the project itself says stays known")

    def test_what_was_filled_in_replaces_what_was_read(self):
        entry = {"environments": {"production": {"user": "ops", "port": "2200"}}}
        argv = self.env(self.build(entry, deploy=KAMAL), "production")["argv"]
        self.assertIn("ops@203.0.113.8", argv)
        self.assertEqual(argv[argv.index("-p") + 1], "2200")

    def test_an_environment_said_whole_stands_for_itself(self):
        entry = {"environments": {"production": {"ssh": "me@198.51.100.1", "path": "/srv/shop"},
                                  "legacy": {"command": "bin/rails runner -"}}}
        project = self.build(entry, deploy=KAMAL)
        production = self.env(project, "production")
        self.assertIn("me@198.51.100.1", production["argv"])
        self.assertIn("cd -- /srv/shop", production["argv"][-1])
        self.assertEqual(production["fields"], {}, "there is nothing to fill in")
        self.assertEqual(self.env(project, "legacy")["argv"], ["/bin/sh", "-c", "bin/rails runner -"])

    def test_it_is_reached_the_way_kamal_reaches_it(self):
        ssh = "ssh:\n  user: deploy\n  proxy: bastion.example\n  keys: [config/deploy_key, ~/.ssh/other]\n  keys_only: true\n"
        path = self.project(deploy=KAMAL.replace("ssh:\n  user: deploy\n", ssh))
        argv = self.env(self.m.build_project({"path": path}, path), "production")["argv"]
        self.assertEqual(argv[argv.index("-J") + 1], "root@bastion.example")
        keys = [argv[i + 1] for i, a in enumerate(argv) if a == "-i"]
        self.assertEqual(keys, [os.path.join(path, "config/deploy_key"), os.path.expanduser("~/.ssh/other")])
        self.assertIn("IdentitiesOnly=yes", argv)
        self.assertLess(argv.index("-J"), argv.index("--"), "options stand before the host")

    def test_without_them_ssh_is_left_to_its_own_config(self):
        argv = self.env(self.build(deploy=KAMAL), "production")["argv"]
        self.assertFalse({"-J", "-i", "IdentitiesOnly=yes"} & set(argv))

    def test_a_jump_host_or_key_left_to_code_is_asked_for(self):
        target = self.env(self.build(deploy=KAMAL + "  proxy: <%= ENV['JUMP'] %>\n  keys:\n    - <%= ENV['KEY'] %>\n"),
                          "production")
        self.assertEqual(target["missing"], ["proxy", "key"])
        self.assertIn("the jump host and the SSH key", target["error"])
        entry = {"environments": {"production": {"proxy": "me@bastion.example", "key": "~/.ssh/shop"}}}
        argv = self.env(self.build(entry, deploy=KAMAL + "  proxy: <%= ENV['JUMP'] %>\n"), "production")["argv"]
        self.assertEqual(argv[argv.index("-J") + 1], "me@bastion.example")
        self.assertEqual(argv[argv.index("-i") + 1], os.path.expanduser("~/.ssh/shop"))

    def test_what_runs_on_the_server_is_given_a_limit(self):
        command = self.env(self.build(deploy=KAMAL), "production")["argv"][-1]
        self.assertIn('exec timeout -k 5 110 "$@"; exec "$@"\' sh bin/rails runner -', command)

    @unittest.skipUnless(shutil.which("timeout"), "needs timeout")
    def test_the_limit_ends_what_takes_too_long_and_passes_the_rest_through(self):
        self.m.PATIENCE = 1
        began = time.time()
        done = subprocess.run(["/bin/sh", "-c", self.m.guarded("sleep 30")])
        self.assertLess(time.time() - began, 10)
        self.assertEqual(done.returncode, 124)
        done = subprocess.run(["/bin/sh", "-c", self.m.guarded("cat")], input=b"as it came\n", capture_output=True)
        self.assertEqual((done.returncode, done.stdout), (0, b"as it came\n"))

    def test_without_a_timeout_that_works_it_is_run_as_it_is(self):
        empty = os.path.join(self.tmp, "bin")
        os.makedirs(empty)
        for tool in ("sh", "cat"):
            os.symlink(shutil.which(tool), os.path.join(empty, tool))
        done = subprocess.run(["/bin/sh", "-c", self.m.guarded("cat")], input=b"as it came\n", capture_output=True,
                              env={"PATH": empty})
        self.assertEqual((done.returncode, done.stdout), (0, b"as it came\n"))

    def test_values_that_could_be_options_or_shell_are_refused(self):
        for field, value in (("host", "-oProxyCommand=x"), ("host", "h;id"), ("user", "a b"), ("service", "s$(id)"),
                             ("role", "job'"), ("port", "0"), ("port", "22;id"), ("proxy", "-oProxyCommand=x"), ("proxy", "a@b c"),
                             ("key", "-oProxyCommand=x"), ("key", "a\nb")):
            entry = {"environments": {"production": {field: value}}}
            target = self.env(self.build(entry, deploy=KAMAL), "production")
            self.assertIsNone(target["argv"], "%s=%s" % (field, value))
            self.assertIn("does not look right", target["error"])

    def test_bad_names_never_reach_a_command(self):
        with self.assertRaises(self.m.ConfigError):
            self.m.kamal_command("shop; id", "job", "", "bin/rails runner -")
        with self.assertRaises(self.m.ConfigError):
            self.m.target_for({"ssh": "-oProxyCommand=x", "command": "true"}, "production")
        with self.assertRaises(self.m.ConfigError):
            self.m.target_for({"ssh": "a@b", "port": 70000, "command": "true"}, "production")

    def test_a_project_without_anything_to_look_at_says_so(self):
        project = self.build()
        self.assertEqual(project["envs"], [])
        self.assertIn("Nothing to look at", project["note"])


class Config(FeedCase):
    def test_only_listed_projects_count(self):
        listed = self.project("listed", deploy=KAMAL)
        self.project("beside", deploy=KAMAL)
        os.makedirs(os.path.dirname(self.m.CONFIG))
        with open(self.m.CONFIG, "w") as f:
            f.write('{"roots": ["%s"], "projects": [{"path": "%s"}]}' % (os.path.dirname(listed), listed))
        self.assertEqual([p["name"] for p in self.m.load_config()[1]], ["listed"])

    def test_the_config_is_kept_private(self):
        self.m.write_raw({"projects": []})
        self.assertEqual(stat.S_IMODE(os.stat(self.m.CONFIG).st_mode), 0o600)
        os.chmod(self.m.CONFIG, 0o644)
        self.m.read_config()
        self.assertEqual(stat.S_IMODE(os.stat(self.m.CONFIG).st_mode), 0o600)

    def test_writing_does_not_follow_a_link_left_in_its_way(self):
        os.makedirs(os.path.dirname(self.m.CONFIG))
        victim = os.path.join(self.tmp, "victim")
        with open(victim, "w") as f:
            f.write("untouched")
        os.symlink(victim, "%s.%d.tmp" % (self.m.CONFIG, os.getpid()))
        self.m.write_raw({"projects": []})
        with open(victim) as f:
            self.assertEqual(f.read(), "untouched")

    def test_the_interval_is_off_unless_asked_for_and_never_short(self):
        os.makedirs(os.path.dirname(self.m.CONFIG))
        for written, read in ((None, 0), (5, 60), (900, 900), ("x", 0), (-3, 0)):
            with open(self.m.CONFIG, "w") as f:
                f.write('{"projects": []%s}' % ("" if written is None else ', "interval": %r' % written).replace("'", '"'))
            self.assertEqual(self.m.load_config()[0], read, written)

    def test_a_change_in_a_projects_files_is_noticed(self):
        path = self.project(deploy=KAMAL)
        self.config({"path": path})
        before = self.m.signature()
        deploy = os.path.join(path, "config", "deploy.yml")
        os.utime(deploy, (1, 1))
        self.assertNotEqual(self.m.signature(), before)


if __name__ == "__main__":
    unittest.main()
