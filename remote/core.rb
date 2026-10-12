# The shared part of what bin/omarchy-job-queues sends on stdin to
# `bin/rails runner -` (or `bundle exec ruby -`) on the server. Nothing of
# this lives in the application.
#
# What is sent is one script, put together by the caller:
#
#   JOBQ_REQUEST = "<base64 of a JSON object>"
#   this file
#   the file of each backend that may be the one asked (sidekiq.rb, ...)
#   JobQ.answer
#
# The request has "backend" (auto, or a backend's name) and, to change
# something before the snapshot is taken, "op" and its arguments. The answer
# is one line on stdout, "@@JOBQ@@" followed by JSON, so whatever the
# application prints while it boots can be told apart from it.
#
# A backend is a module in a file of its own that puts itself into BACKENDS
# under its name and answers to:
#
#   present?    whether its library is loaded in this process
#   load!       require what it needs, or raise saying what is missing
#   snapshot    a Hash of what the panel shows; it must not write anything
#   perform(request)   carry out request["op"], return a sentence about it
#
# perform, and everything else in the file that writes, stands between the
# "changes" marks: the caller cuts that out of every script that is only
# meant to look, so such a script cannot change anything. A backend whose
# changes go to the database says so with `writes_database?`; the others
# make theirs with the database shut.
require "json"
require "base64"
require "time"

module JobQ
  LIMIT = 50      # jobs listed per tab
  TEXT = 240      # longest text sent back
  DETAIL = 2000   # longest arguments or error of a job, which the panel unfolds
  BACKENDS = {}   # name => module, in the order their files were sent
  PATIENCE = 110  # seconds this may take; the caller gives up soon after

  module_function

  def clip(value, max = TEXT)
    s = value.is_a?(String) ? value : value.to_json
    s = s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?").gsub(/\s+/, " ").strip
    s.length > max ? s[0, max - 1] + "…" : s
  rescue StandardError
    ""
  end

  def epoch(time)
    seconds = time.respond_to?(:to_f) ? time.to_f.round : 0
    seconds.positive? ? seconds : nil
  end

  # The one asked for; else the application's Active Job adapter, else the
  # only one whose library is loaded, else the first that was sent.
  def backend(wanted)
    return BACKENDS[wanted] if BACKENDS.key?(wanted)
    if defined?(ActiveJob::Base) && ActiveJob::Base.respond_to?(:queue_adapter_name)
      name = ActiveJob::Base.queue_adapter_name.to_s
      return BACKENDS[name] if BACKENDS.key?(name)
    end
    loaded = BACKENDS.values.select(&:present?)
    loaded.size == 1 ? loaded.first : BACKENDS.values.first
  end

  # Looking never writes: with a database behind it, Rails is told to refuse
  # every INSERT, UPDATE and DELETE on every connection meanwhile.
  def looking(&block)
    return yield unless defined?(ActiveRecord::Base) && ActiveRecord::Base.respond_to?(:while_preventing_writes)

    ActiveRecord::Base.while_preventing_writes(true, &block)
  end

  def run(request)
    impl = backend(request["backend"]) or raise "No backend was sent with this script"
    impl.load!
    message = ""
    if request["op"]
      raise "This script was sent to look, not to change anything" unless impl.respond_to?(:perform)
      own = impl.respond_to?(:writes_database?) && impl.writes_database?
      message = own ? impl.perform(request) : looking { impl.perform(request) }
    end
    out = looking { impl.snapshot }
    out[:ok] = true
    out[:message] = message
    out[:env] = defined?(Rails) && Rails.respond_to?(:env) ? Rails.env.to_s : ENV["RAILS_ENV"].to_s
    out
  end

  # Nobody waits for the answer longer than that, and a process the caller
  # walked away from would stay in the container: it ends itself instead.
  def watchdog(seconds = PATIENCE)
    Thread.new do
      sleep seconds
      $stdout.puts "@@JOBQ@@" + JSON.generate(ok: false, error: "No answer within #{seconds} seconds; stopped on the server")
      $stdout.flush
      exit!(1)
    end
  end

  def answer
    guard = watchdog
    found = begin
      run(JSON.parse(Base64.decode64(JOBQ_REQUEST)))
    rescue Exception => e # rubocop:disable Lint/RescueException -- a LoadError must reach the panel too
      { ok: false, error: clip("#{e.class}: #{e.message}", 400) }
    end
    guard.kill
    $stdout.puts "@@JOBQ@@" + JSON.generate(found)
    $stdout.flush
  end
end
