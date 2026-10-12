# Solid Queue, as bin/omarchy-job-queues sends it after core.rb. Its jobs
# are rows in the application's database; see core.rb for what a backend is.
module JobQ
  module SolidQueueBackend
    module_function

    def present?
      !defined?(SolidQueue).nil?
    end

    # Its changes are database writes, fenced in to its own tables below.
    def writes_database?
      true
    end

    def load!
      raise "Solid Queue needs the application: set \"runner\" to \"rails\"" unless defined?(SolidQueue::Job)
    end

    # >>> changes: left out of the script unless a change was asked for
    def job(req)
      SolidQueue::Job.find_by(id: req["id"].to_i) or raise "The job is no longer there"
    end

    def failed_jobs
      SolidQueue::Job.where(id: SolidQueue::FailedExecution.select(:job_id))
    end

    def recurring(key)
      SolidQueue::RecurringTask.find_by(key: key.to_s) or raise "No recurring task named #{key}"
    end

    # Stands before every SQL statement while a change is carried out and
    # stops the ones that are not Solid Queue's own business: a write to any
    # table but its own, and anything that is not a plain read or write at
    # all (DROP, TRUNCATE, ALTER ...). Raising here keeps the statement from
    # being sent.
    class Fence
      READS = /\A(SELECT|BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)\b/i
      SCHEMA = /\A(SELECT|SHOW|PRAGMA)\b/i
      WRITES = /\A(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+(?:["`]?\w+["`]?\.)?["`]?(\w+)/i

      attr_reader :stopped

      def initialize(tables)
        @tables = tables
      end

      def start(_name, _id, payload)
        sql = payload[:sql].to_s.sub(/\A(?:\s|\/\*.*?\*\/)+/m, "")
        return if sql.match?(READS) || (payload[:name] == "SCHEMA" && sql.match?(SCHEMA))
        return if (m = sql.match(WRITES)) && @tables.include?(m[1].downcase)

        @stopped ||= sql[0, 80]
        raise "Stopped a statement outside Solid Queue's tables: #{@stopped}"
      end

      def finish(_name, _id, _payload); end
    end

    def perform(req)
      tables = SolidQueue::Record.connection.tables.map(&:downcase).select { |t| t.start_with?("solid_queue_") }
      fence = Fence.new(tables)
      watch = ActiveSupport::Notifications.subscribe("sql.active_record", fence)
      begin
        change(req)
      rescue Exception # rubocop:disable Lint/RescueException -- whatever wraps the fence's own error
        raise "Stopped a statement outside Solid Queue's tables: #{fence.stopped}" if fence.stopped

        raise
      ensure
        ActiveSupport::Notifications.unsubscribe(watch)
      end
    end

    def change(req)
      case req["op"]
      when "retry"
        j = job(req)
        if req["list"] == "scheduled"
          j.scheduled_execution or raise "The job is no longer scheduled"
          SolidQueue::ScheduledExecution.dispatch_jobs([j.id])
        else
          j.retry
        end
        "Queued #{j.class_name}"
      when "delete"
        j = job(req)
        j.discard
        "Deleted #{j.class_name}"
      when "retry_all"
        raise ArgumentError, "unknown list" unless req["list"] == "failed"
        n = SolidQueue::FailedExecution.count
        SolidQueue::FailedExecution.retry_all(failed_jobs)
        "Queued #{n} jobs"
      when "delete_all"
        scope = case req["list"]
                when "failed" then SolidQueue::FailedExecution
                when "scheduled" then SolidQueue::ScheduledExecution
                else raise ArgumentError, "unknown list"
                end
        n = scope.count
        scope.discard_all_in_batches
        "Deleted #{n} jobs"
      when "clear_queue"
        q = SolidQueue::Queue.find_by_name(req["queue"].to_s)
        n = q.size
        q.clear
        "Removed #{n} jobs from #{q.name}"
      when "pause_queue"
        q = SolidQueue::Queue.find_by_name(req["queue"].to_s)
        if q.paused?
          q.resume
          "Resumed #{q.name}"
        else
          q.pause
          "Paused #{q.name}"
        end
      when "cron_run"
        task = recurring(req["name"])
        task.enqueue(at: Time.current)
        "Queued #{task.key}"
      else
        raise ArgumentError, "unknown operation #{req["op"]}"
      end
    end

    # <<< changes

    # Arguments as they were given, without what Active Job adds to carry
    # them: its "_aj_..." notes are dropped and a record reads as its id.
    def plain(value)
      case value
      when Array then value.map { |v| plain(v) }
      when Hash
        return value["_aj_globalid"] if value.key?("_aj_globalid")
        value.reject { |k, _| k.to_s.start_with?("_aj_") }.transform_values { |v| plain(v) }
      else value
      end
    end

    def job_row(job, at, error = "")
      args = job.arguments
      args = args["arguments"] if args.is_a?(Hash) && args.key?("arguments")
      { id: job.id.to_s, cls: JobQ.clip(job.class_name.to_s, 120), args: JobQ.clip(plain(args), DETAIL),
        error: JobQ.clip(error, DETAIL), queue: job.queue_name.to_s, at: JobQ.epoch(at), tries: nil }
    end

    def executions(scope, order)
      scope.includes(:job).order(order).limit(LIMIT).select(&:job)
    end

    def cron_rows
      return [] unless defined?(SolidQueue::RecurringTask)
      last = if defined?(SolidQueue::RecurringExecution)
        SolidQueue::RecurringExecution.group(:task_key).maximum(:run_at)
      else
        {}
      end
      SolidQueue::RecurringTask.order(:key).map do |t|
        { name: t.key.to_s, schedule: t.schedule.to_s, cls: JobQ.clip((t.class_name || t.command).to_s, 120),
          enabled: true, last: JobQ.epoch(last[t.key]), actions: %w[run] }
      end
    end

    def snapshot
      failed = executions(SolidQueue::FailedExecution, created_at: :desc).map { |e|
        job_row(e.job, e.created_at, [e.exception_class, e.message].compact.join(": "))
      }
      running = executions(SolidQueue::ClaimedExecution, created_at: :asc).map { |e| job_row(e.job, e.created_at) }
      scheduled = executions(SolidQueue::ScheduledExecution, scheduled_at: :asc).map { |e| job_row(e.job, e.scheduled_at) }
      blocked = executions(SolidQueue::BlockedExecution, created_at: :asc).map { |e| job_row(e.job, e.created_at) }
      counts = {
        enqueued: SolidQueue::ReadyExecution.count, busy: SolidQueue::ClaimedExecution.count,
        scheduled: SolidQueue::ScheduledExecution.count, failed: SolidQueue::FailedExecution.count,
        blocked: SolidQueue::BlockedExecution.count
      }
      queues = SolidQueue::Queue.all.map { |q|
        latency = q.respond_to?(:latency) ? q.latency.to_f.round(1) : nil
        { name: q.name, size: q.size, latency: latency, paused: q.paused?, actions: %w[pause clear] }
      }
      {
        backend: "solid_queue",
        version: (SolidQueue::VERSION rescue ""),
        stats: {
          enqueued: counts[:enqueued], busy: counts[:busy], scheduled: counts[:scheduled], retry: nil,
          failed: counts[:failed], processes: SolidQueue::Process.count, processed: nil,
          latency: queues.map { |q| q[:latency].to_f }.max
        },
        queues: queues,
        processes: SolidQueue::Process.order(:kind, :id).map { |p|
          meta = p.metadata.is_a?(Hash) ? p.metadata : {}
          { name: "#{p.hostname}:#{p.pid}", kind: p.kind.to_s.downcase, busy: nil,
            concurrency: meta["thread_pool_size"], queues: meta["queues"].to_s, beat: JobQ.epoch(p.last_heartbeat_at) }
        },
        lists: [
          { key: "busy", label: "Running", total: counts[:busy], items: running, actions: [] },
          { key: "failed", label: "Failed", total: counts[:failed], items: failed,
            actions: %w[retry delete retry_all delete_all] },
          { key: "scheduled", label: "Scheduled", total: counts[:scheduled], items: scheduled,
            actions: %w[retry delete delete_all] },
          { key: "blocked", label: "Blocked", total: counts[:blocked], items: blocked, actions: %w[delete] }
        ],
        cron: cron_rows
      }
    end
  end

  BACKENDS["solid_queue"] = SolidQueueBackend
end
