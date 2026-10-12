"""What is sent to a server: put together from the checked files, and never
able to change anything unless a change was asked for."""
import hashlib
import os
import re
import shutil
import subprocess
import unittest

from helper import FeedCase

WRITES = re.compile(r"def perform|def change|\.retry\b|\.delete\b|\.clear\b|\.discard|enqueue!|enque!|\.enqueue\(|\.pause\b|"
                    r"\.resume\b|disable!|enable!|add_to_queue|dispatch_jobs")


class Scripts(FeedCase):
    def script(self, request, changing=False):
        return self.m.compose(request, changing).decode()

    def test_the_pinned_checksums_are_those_of_the_files(self):
        on_disk = sorted(n for n in os.listdir(self.m.REMOTE) if n.endswith(".rb"))
        self.assertEqual(on_disk, sorted(self.m.REMOTE_SHA256), "every script in remote/ is pinned, and nothing else")
        for name in on_disk:
            with open(os.path.join(self.m.REMOTE, name), "rb") as f:
                self.assertEqual(hashlib.sha256(f.read()).hexdigest(), self.m.REMOTE_SHA256[name],
                                 "%s changed: put what --checksum prints into REMOTE_SHA256" % name)

    def test_backends_are_the_pinned_files(self):
        self.assertEqual(self.m.BACKENDS, ("sidekiq", "solid_queue"))

    def test_looking_sends_no_code_that_writes(self):
        for backend in self.m.BACKENDS + ("auto",):
            script = self.script({"backend": backend})
            self.assertIsNone(WRITES.search(script), "%s: %s" % (backend, WRITES.search(script)))
            self.assertNotIn(">>> changes", script)

    def test_a_change_carries_the_code_for_it(self):
        for backend in self.m.BACKENDS:
            self.assertIn("def perform", self.script({"backend": backend, "op": "retry_all", "list": "x"}, True))

    def test_a_change_is_refused_when_nothing_may_be_changed(self):
        with self.assertRaisesRegex(ValueError, "refusing"):
            self.m.compose({"backend": "sidekiq", "op": "delete_all", "list": "dead"}, False)

    def test_only_the_backend_asked_for_is_sent(self):
        self.assertNotIn("SolidQueueBackend", self.script({"backend": "sidekiq"}))
        self.assertNotIn("SidekiqBackend", self.script({"backend": "solid_queue"}))
        both = self.script({"backend": "auto"})
        self.assertIn("SidekiqBackend", both)
        self.assertIn("SolidQueueBackend", both)

    def test_the_script_is_the_request_the_files_and_the_call(self):
        script = self.script({"backend": "sidekiq"})
        self.assertRegex(script.splitlines()[0], r'^JOBQ_REQUEST = "[A-Za-z0-9+/=]+"$')
        self.assertTrue(script.endswith("JobQ.answer\n"))

    def test_the_request_cannot_break_out_of_its_line(self):
        script = self.script({"backend": "sidekiq", "queue": '"\n system("true") #'})
        self.assertRegex(script.splitlines()[0], r'^JOBQ_REQUEST = "[A-Za-z0-9+/=]+"$')
        self.assertNotIn("system(", script)

    def copy_of_remote(self):
        copy = os.path.join(self.tmp, "remote")
        shutil.copytree(self.m.REMOTE, copy)
        self.m.REMOTE = copy
        return copy

    def test_a_changed_script_is_not_sent(self):
        copy = self.copy_of_remote()
        with open(os.path.join(copy, "sidekiq.rb"), "a") as f:
            f.write("# one more line\n")
        with self.assertRaisesRegex(ValueError, "sidekiq.rb has changed"):
            self.m.compose({"backend": "sidekiq"}, False)
        self.m.compose({"backend": "solid_queue"}, False)   # the other is still what it was

    def test_a_changed_core_stops_everything(self):
        copy = self.copy_of_remote()
        with open(os.path.join(copy, "core.rb"), "a") as f:
            f.write("# one more line\n")
        for backend in self.m.BACKENDS:
            with self.assertRaisesRegex(ValueError, "core.rb has changed"):
                self.m.compose({"backend": backend}, False)

    def test_a_script_nobody_pinned_is_not_a_backend(self):
        copy = self.copy_of_remote()
        with open(os.path.join(copy, "good_job.rb"), "w") as f:
            f.write("system('true')\n")
        self.assertNotIn("system(", self.script({"backend": "good_job"}))
        self.assertNotIn("system(", self.script({"backend": "auto"}))

    def test_a_backend_without_its_marks_is_not_sent_to_look(self):
        copy = self.copy_of_remote()
        path = os.path.join(copy, "sidekiq.rb")
        with open(path) as f:
            text = f.read().replace("# >>> changes", "# changes")
        with open(path, "w") as f:
            f.write(text)
        self.m.REMOTE_SHA256 = dict(self.m.REMOTE_SHA256, **{"sidekiq.rb": hashlib.sha256(text.encode()).hexdigest()})
        with self.assertRaisesRegex(ValueError, "refusing"):
            self.m.compose({"backend": "sidekiq"}, False)

    @unittest.skipUnless(shutil.which("ruby"), "needs ruby")
    def test_every_script_that_can_be_sent_is_valid_ruby(self):
        for backend in self.m.BACKENDS + ("auto",):
            for changing in (False, True):
                request = {"backend": backend, "op": "retry_all", "list": "x"} if changing else {"backend": backend}
                done = subprocess.run(["ruby", "-c"], input=self.m.compose(request, changing), capture_output=True)
                self.assertEqual(done.returncode, 0, done.stderr.decode())


if __name__ == "__main__":
    unittest.main()
