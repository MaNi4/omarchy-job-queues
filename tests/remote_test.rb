# What is sent to the servers, as far as it can be tried without one: the
# shared part and the fence around Solid Queue's changes. Needs nothing but
# Ruby:  ruby tests/remote_test.rb
require "minitest/autorun"
require "stringio"

REMOTE = File.expand_path("../remote", __dir__)
load File.join(REMOTE, "core.rb")
REAL_BACKENDS = %w[sidekiq solid_queue].freeze
REAL_BACKENDS.each { |name| load File.join(REMOTE, "#{name}.rb") }

# A backend that only remembers what was done with it.
class FakeBackend
  attr_reader :log

  def initialize(present: true, database: false, perform: true)
    @present = present
    @database = database
    @log = []
    define_singleton_method(:perform) { |req| @log << [:perform, req["op"], FakeRecord.shut]; "Did #{req["op"]}" } if perform
  end

  def present? = @present
  def load! = @log << [:load]

  def writes_database?
    @database
  end

  def snapshot
    @log << [:snapshot, FakeRecord.shut]
    { backend: "fake" }
  end
end

# Stands in for ActiveRecord::Base: knows whether writes are being refused.
module FakeRecord
  class << self
    attr_accessor :shut

    def while_preventing_writes(_enabled = true)
      was = @shut
      @shut = true
      yield
    ensure
      @shut = was
    end
  end
  self.shut = false
end

class CoreTest < Minitest::Test
  def setup
    @kept = JobQ::BACKENDS.dup
    JobQ::BACKENDS.clear
    Object.const_set(:ActiveRecord, Module.new) unless defined?(ActiveRecord)
    ActiveRecord.const_set(:Base, FakeRecord) unless defined?(ActiveRecord::Base)
    FakeRecord.shut = false
  end

  def teardown
    JobQ::BACKENDS.replace(@kept)
    Object.send(:remove_const, :JOBQ_REQUEST) if defined?(JOBQ_REQUEST)
  end

  def answer_to(request)
    Object.const_set(:JOBQ_REQUEST, Base64.strict_encode64(JSON.generate(request)))
    out = StringIO.new
    $stdout = out
    JobQ.answer
    out.string
  ensure
    $stdout = STDOUT
  end

  def test_the_real_backends_put_themselves_on_the_list
    assert_equal REAL_BACKENDS, @kept.keys
    @kept.each_value do |backend|
      %i[present? load! snapshot perform].each { |m| assert_respond_to backend, m }
    end
  end

  def test_only_solid_queue_writes_to_the_database
    assert_equal({ "sidekiq" => false, "solid_queue" => true },
                 @kept.transform_values { |b| b.respond_to?(:writes_database?) && b.writes_database? })
  end

  def test_the_backend_asked_for_is_the_one_used
    a, b = FakeBackend.new, FakeBackend.new
    JobQ::BACKENDS.merge!("a" => a, "b" => b)
    assert_same b, JobQ.backend("b")
  end

  def test_asked_for_none_the_only_one_loaded_is_used
    a, b = FakeBackend.new(present: false), FakeBackend.new
    JobQ::BACKENDS.merge!("a" => a, "b" => b)
    assert_same b, JobQ.backend("auto")
  end

  def test_asked_for_none_with_nothing_to_tell_them_apart_the_first_is_used
    a, b = FakeBackend.new, FakeBackend.new
    JobQ::BACKENDS.merge!("a" => a, "b" => b)
    assert_same a, JobQ.backend("auto")
  end

  def test_looking_is_done_with_the_database_shut
    fake = FakeBackend.new
    JobQ::BACKENDS["fake"] = fake
    out = JobQ.run("backend" => "fake")
    assert_equal [[:load], [:snapshot, true]], fake.log
    assert_equal true, out[:ok]
    assert_equal "", out[:message]
    assert_equal false, FakeRecord.shut
  end

  def test_a_change_that_is_not_the_databases_business_is_made_with_it_shut
    fake = FakeBackend.new
    JobQ::BACKENDS["fake"] = fake
    out = JobQ.run("backend" => "fake", "op" => "retry_all")
    assert_equal [[:load], [:perform, "retry_all", true], [:snapshot, true]], fake.log
    assert_equal "Did retry_all", out[:message]
  end

  def test_a_backend_that_keeps_its_jobs_in_the_database_may_write_there
    fake = FakeBackend.new(database: true)
    JobQ::BACKENDS["fake"] = fake
    JobQ.run("backend" => "fake", "op" => "retry_all")
    assert_equal [[:load], [:perform, "retry_all", false], [:snapshot, true]], fake.log
  end

  def test_a_script_sent_to_look_refuses_to_change
    fake = FakeBackend.new(perform: false)
    JobQ::BACKENDS["fake"] = fake
    error = assert_raises(RuntimeError) { JobQ.run("backend" => "fake", "op" => "delete_all") }
    assert_match(/sent to look/, error.message)
    assert_equal [[:load]], fake.log
  end

  def test_the_answer_is_one_marked_line_of_json
    JobQ::BACKENDS["fake"] = FakeBackend.new
    line = answer_to("backend" => "fake")
    assert_match(/\A@@JOBQ@@\{.*\}\n\z/, line)
    assert_equal({ "backend" => "fake", "ok" => true, "message" => "" }, JSON.parse(line.delete_prefix("@@JOBQ@@")).slice("backend", "ok", "message"))
  end

  def test_whatever_goes_wrong_is_answered_too
    failing = FakeBackend.new
    failing.define_singleton_method(:load!) { raise LoadError, "cannot load such file -- sidekiq/api" }
    JobQ::BACKENDS["fake"] = failing
    answer = JSON.parse(answer_to("backend" => "fake").delete_prefix("@@JOBQ@@"))
    assert_equal false, answer["ok"]
    assert_equal "LoadError: cannot load such file -- sidekiq/api", answer["error"]
  end

  def test_no_backend_sent_is_said
    answer = JSON.parse(answer_to("backend" => "sidekiq").delete_prefix("@@JOBQ@@"))
    assert_match(/No backend was sent/, answer["error"])
  end

  def test_a_script_that_takes_too_long_ends_itself_and_says_so
    began = Time.now
    out = IO.popen(["ruby", "-e", "load ARGV[0]; JobQ.watchdog(0.3); sleep 30", File.join(REMOTE, "core.rb")], &:read)
    assert_operator Time.now - began, :<, 10
    assert_equal 1, $?.exitstatus
    assert_match(/No answer within 0.3 seconds/, JSON.parse(out.delete_prefix("@@JOBQ@@"))["error"])
  end

  def test_an_answer_in_time_calls_the_watch_off
    JobQ::BACKENDS["fake"] = FakeBackend.new
    before = Thread.list.size
    answer_to("backend" => "fake")
    sleep 0.05
    assert_equal before, Thread.list.select(&:alive?).size
  end

  def test_long_and_broken_text_is_made_short_and_whole
    assert_equal 240, JobQ.clip("x" * 5000).length
    assert_equal 2000, JobQ.clip("x" * 5000, JobQ::DETAIL).length
    assert_equal "a b c", JobQ.clip("a\n b\t\tc ")
    assert_equal "caf?", JobQ.clip("caf\xE9".dup.force_encoding("UTF-8"))
    assert_equal '{"a":1}', JobQ.clip({ a: 1 })
  end

  def test_times_are_whole_seconds_or_nothing
    assert_equal 1_700_000_000, JobQ.epoch(Time.at(1_700_000_000.4))
    assert_nil JobQ.epoch(nil)
    assert_nil JobQ.epoch(Time.at(0))
  end
end

class ArgumentsTest < Minitest::Test
  def plain(value) = JobQ::SolidQueueBackend.plain(value)

  def test_what_active_job_adds_is_left_out
    assert_equal [1005, { "notify" => true, "locale" => "sk" }],
                 plain([1005, { "notify" => true, "locale" => "sk", "_aj_symbol_keys" => [] }])
    assert_equal [{ "a" => { "b" => 1 } }],
                 plain([{ "a" => { "b" => 1, "_aj_hash_with_indifferent_access" => true }, "_aj_ruby2_keywords" => ["a"] }])
  end

  def test_a_record_reads_as_its_id
    assert_equal ["gid://shop/User/7", [{ "user" => "gid://shop/Order/1" }]],
                 plain([{ "_aj_globalid" => "gid://shop/User/7" }, [{ "user" => { "_aj_globalid" => "gid://shop/Order/1" } }]])
  end

  def test_a_serialized_value_keeps_what_it_holds
    assert_equal [{ "value" => "2026-01-01T00:00:00Z" }],
                 plain([{ "_aj_serialized" => "ActiveJob::Serializers::TimeSerializer", "value" => "2026-01-01T00:00:00Z" }])
  end

  def test_everything_else_is_as_it_was
    assert_equal [1, "two", nil, true, 3.5, { "plain" => [] }], plain([1, "two", nil, true, 3.5, { "plain" => [] }])
  end
end

# The fence stands before every SQL statement while Solid Queue is changed.
class FenceTest < Minitest::Test
  TABLES = %w[solid_queue_jobs solid_queue_failed_executions solid_queue_ready_executions solid_queue_pauses].freeze

  def fence
    @fence ||= JobQ::SolidQueueBackend::Fence.new(TABLES)
  end

  def passes?(sql, name = "SQL")
    fence.start("sql.active_record", "1", sql: sql, name: name)
    true
  rescue RuntimeError => e
    assert_match(/Stopped a statement outside Solid Queue's tables/, e.message)
    false
  end

  def test_reading_anything_is_let_through
    assert passes?("SELECT * FROM users")
    assert passes?('SELECT "solid_queue_jobs".* FROM "solid_queue_jobs" WHERE id = 1')
    assert passes?("  /* app:shop */ SELECT 1")
  end

  def test_transactions_are_let_through
    %w[BEGIN COMMIT ROLLBACK].each { |sql| assert passes?(sql), sql }
    assert passes?("SAVEPOINT active_record_1")
    assert passes?("RELEASE SAVEPOINT active_record_1")
    assert passes?("begin transaction")
  end

  def test_writes_to_solid_queues_tables_are_let_through
    assert passes?('INSERT INTO "solid_queue_ready_executions" ("job_id") VALUES (1)')
    assert passes?("UPDATE `solid_queue_jobs` SET finished_at = NULL WHERE id = 1")
    assert passes?('DELETE FROM "solid_queue_failed_executions" WHERE "id" IN (1, 2)')
    assert passes?('DELETE FROM "public"."solid_queue_failed_executions"')
    assert passes?("insert into solid_queue_pauses (queue_name) values ('default')")
  end

  def test_writes_to_any_other_table_are_stopped
    refute passes?('DELETE FROM "users"')
    refute passes?('UPDATE "orders" SET total = 0')
    refute passes?('INSERT INTO "users" ("email") VALUES (\'x\')')
    refute passes?('DELETE FROM "solid_queue_made_up"'), "a table that is not there is not Solid Queue's"
    refute passes?('DELETE FROM "users_solid_queue_jobs"')
    refute passes?("/* solid_queue_jobs */ DELETE FROM users")
  end

  def test_whatever_is_not_a_plain_read_or_write_is_stopped
    ["DROP TABLE users", "DROP TABLE solid_queue_jobs", "TRUNCATE solid_queue_jobs", "ALTER TABLE users ADD x int",
     "CREATE TABLE x (id int)", "GRANT ALL ON users TO public", "WITH gone AS (DELETE FROM users RETURNING *) SELECT 1",
     "VACUUM", "SET session_replication_role = replica", "COPY users TO '/tmp/x'", "CALL wipe()", ""].each do |sql|
      refute passes?(sql), sql
    end
  end

  def test_looking_at_the_schema_is_let_through_only_as_that
    assert passes?("SHOW search_path", "SCHEMA")
    assert passes?("PRAGMA table_info(solid_queue_jobs)", "SCHEMA")
    refute passes?("PRAGMA writable_schema = 1")
    refute passes?("DROP TABLE users", "SCHEMA")
  end

  def test_the_first_statement_stopped_is_remembered
    assert_nil fence.stopped
    passes?("DROP TABLE users")
    passes?("TRUNCATE orders")
    assert_equal "DROP TABLE users", fence.stopped
  end
end
