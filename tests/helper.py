"""What the tests of bin/job-queues share.

Every test gets the feed loaded afresh with its config in a directory of its
own, so nothing here reads or writes the real ~/.config/omarchy, and nothing
connects anywhere: `ask`, the notifications and the threads are replaced.
"""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import tempfile
import unittest

PLUGIN = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FEED = os.path.join(PLUGIN, "bin", "job-queues")

KAMAL = """\
service: shop
servers:
  web:
    - 203.0.113.7
  job:
    hosts:
      - 203.0.113.8
    cmd: bundle exec sidekiq
ssh:
  user: deploy
"""


def load_feed(config_home):
    """The feed as a module, with its config under `config_home`."""
    before = os.environ.get("XDG_CONFIG_HOME")
    os.environ["XDG_CONFIG_HOME"] = config_home
    try:
        loader = importlib.machinery.SourceFileLoader("jobq_feed", FEED)
        module = importlib.util.module_from_spec(importlib.util.spec_from_loader("jobq_feed", loader))
        loader.exec_module(module)
    finally:
        if before is None:
            del os.environ["XDG_CONFIG_HOME"]
        else:
            os.environ["XDG_CONFIG_HOME"] = before
    return module


class FeedCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="jobq-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.m = load_feed(os.path.join(self.tmp, "config"))
        self.notes = []
        self.m.notify = lambda body, clicked=None: self.notes.append(body)

    def project(self, name="shop", lock="sidekiq (7.3.9)", **files):
        """A made-up project directory; `files` are config/<name with _ for .> contents."""
        path = os.path.join(self.tmp, "projects", name)
        os.makedirs(os.path.join(path, "config"), exist_ok=True)
        with open(os.path.join(path, "Gemfile.lock"), "w") as f:
            f.write("GEM\n  specs:\n    %s\n" % lock)
        for key, text in files.items():
            with open(os.path.join(path, "config", key.replace("_", ".") + ".yml"), "w") as f:
                f.write(text)
        return path

    def config(self, *entries):
        os.makedirs(os.path.dirname(self.m.CONFIG), exist_ok=True)
        with open(self.m.CONFIG, "w") as f:
            json.dump({"projects": list(entries)}, f)

    def read_config(self):
        with open(self.m.CONFIG) as f:
            return json.load(f)

    def feed(self, *entries):
        """A Feed over these config entries that asks no server and starts no thread."""
        self.config(*entries)
        feed = self.m.Feed()
        feed.quiet = True       # nothing printed; what was said is in feed.message
        feed.started = []
        feed.start = lambda key, request=None: feed.started.append((key, request))
        feed.reload()
        return feed
