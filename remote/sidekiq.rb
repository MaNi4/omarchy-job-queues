# Sidekiq, as bin/job-queues sends it after core.rb. It reads and
# changes Redis only; see core.rb for what a backend is.
module JobQ
  module SidekiqBackend
    module_function

    # What things are called here is what Sidekiq's own web interface (and
    # sidekiq-cron's) calls them.
    WORDS = {
      stats: { enqueued: "Enqueued", busy: "Busy", scheduled: "Scheduled", retry: "Retries",
               failed: "Dead", processes: "Processes" },
      queues: "Queues", cron: "Cron", failed: "dead", size: "enqueued", latency: "latency",
      retry: "Retry Now", run: "Add to queue", delete: "Delete", retry_all: "Retry All", delete_all: "Delete All",
      clear: "Delete", pause: "Pause", resume: "Unpause", cron_run: "Enqueue Now", enable: "Enable", disable: "Disable"
    }.freeze

    def present?
      !defined?(Sidekiq).nil?
    end

    def load!
      require "sidekiq/api"
      return if defined?(Sidekiq::Cron::Job)
      %w[sidekiq-cron sidekiq/cron].each do |lib|
        require lib
        break
      rescue LoadError
        next
      end
    end

    def set_for(key)
      case key
      when "retry" then Sidekiq::RetrySet.new
      when "dead" then Sidekiq::DeadSet.new
      when "scheduled" then Sidekiq::ScheduledSet.new
      else raise ArgumentError, "unknown list #{key}"
      end
    end

    # >>> changes: left out of the script unless a change was asked for
    def entry(req)
      id = req["id"].to_s
      score, jid = id.split("|", 2)
      found = set_for(req["list"]).fetch(score.to_f, jid)
      found = found.first if found.is_a?(Array)
      found or raise "The job is no longer there"
    end

    def cron_job(name)
      raise "sidekiq-cron is not loaded" unless defined?(Sidekiq::Cron::Job)
      Sidekiq::Cron::Job.find(name.to_s) or raise "No cron job named #{name}"
    end

    def perform(req)
      case req["op"]
      when "retry"
        e = entry(req)
        req["list"] == "scheduled" ? e.add_to_queue : e.retry
        "Queued #{e.display_class}"
      when "delete"
        e = entry(req)
        e.delete
        "Deleted #{e.display_class}"
      when "retry_all"
        set = set_for(req["list"])
        n = set.size
        if set.respond_to?(:retry_all)
          set.retry_all
        else
          set.each(&:add_to_queue)
        end
        "Queued #{n} jobs"
      when "delete_all"
        set = set_for(req["list"])
        n = set.size
        set.clear
        "Deleted #{n} jobs"
      when "clear_queue"
        q = Sidekiq::Queue.new(req["queue"].to_s)
        n = q.size
        q.clear
        "Deleted #{q.name} with its #{n} jobs"
      when "cron_run"
        job = cron_job(req["name"])
        job.respond_to?(:enqueue!) ? job.enqueue! : job.enque!
        "Enqueued #{job.name}"
      when "cron_toggle"
        job = cron_job(req["name"])
        if job.status == "enabled"
          job.disable!
          "Disabled #{job.name}"
        else
          job.enable!
          "Enabled #{job.name}"
        end
      else
        raise ArgumentError, "unknown operation #{req["op"]}"
      end
    end

    # <<< changes

    def job_row(e)
      error = [e.item["error_class"], e.item["error_message"]].compact.join(": ")
      {
        id: "#{e.score}|#{e.jid}",
        cls: JobQ.clip(e.display_class.to_s, 120),
        args: JobQ.clip(e.display_args, DETAIL),
        error: JobQ.clip(error, DETAIL),
        queue: e.queue.to_s,
        at: JobQ.epoch(e.at),
        tries: e.item["retry_count"]
      }
    end

    def list(key, label, newest_first, actions)
      set = set_for(key)
      rows = []
      if newest_first
        # Sorted sets page from the oldest; the newest failures are the ones
        # worth seeing, so read the tail directly.
        raw = Sidekiq.redis { |c| c.call("ZRANGE", set.name, -LIMIT, -1, "WITHSCORES") }
        raw = raw.each_slice(2).to_a if raw.first.is_a?(String)
        raw.reverse_each { |value, score| rows << job_row(Sidekiq::SortedEntry.new(set, score.to_f, value)) }
      else
        set.each do |e|
          rows << job_row(e)
          break if rows.size >= LIMIT
        end
      end
      { key: key, label: label, total: set.size, items: rows, actions: actions }
    end

    def busy_rows
      rows = []
      Sidekiq::WorkSet.new.each do |_process, _thread, work|
        payload = work.respond_to?(:job) ? work.job : nil
        hash = if payload.respond_to?(:item) then payload.item
               elsif work.respond_to?(:[]) then (JSON.parse(work["payload"]) rescue {})
               else {}
               end
        cls = payload.respond_to?(:display_class) ? payload.display_class : (hash["wrapped"] || hash["class"])
        run_at = work.respond_to?(:run_at) ? work.run_at : Time.at(work["run_at"].to_i)
        queue = work.respond_to?(:queue) ? work.queue : work["queue"]
        rows << { id: hash["jid"].to_s, cls: JobQ.clip(cls.to_s, 120), args: JobQ.clip(hash["args"] || []),
                  error: "", queue: queue.to_s, at: JobQ.epoch(run_at), tries: nil }
        break if rows.size >= LIMIT
      end
      rows
    end

    def cron_rows
      return [] unless defined?(Sidekiq::Cron::Job)
      Sidekiq::Cron::Job.all.map do |j|
        last = j.last_enqueue_time
        last = (Time.parse(last) rescue nil) if last.is_a?(String)
        { name: j.name.to_s, schedule: j.cron.to_s, cls: JobQ.clip(j.klass.to_s, 120),
          enabled: j.status == "enabled", last: JobQ.epoch(last), actions: %w[run toggle] }
      end.sort_by { |j| j[:name] }
    end

    def snapshot
      stats = Sidekiq::Stats.new
      busy = busy_rows
      {
        backend: "sidekiq",
        version: Sidekiq::VERSION,
        stats: {
          enqueued: stats.enqueued, busy: stats.workers_size, scheduled: stats.scheduled_size,
          retry: stats.retry_size, failed: stats.dead_size, processes: stats.processes_size,
          processed: stats.processed, latency: stats.default_queue_latency.round(1)
        },
        queues: Sidekiq::Queue.all.map { |q|
          { name: q.name, size: q.size, latency: q.latency.round(1), paused: false, actions: %w[clear] }
        },
        processes: Sidekiq::ProcessSet.new.map { |p|
          { name: "#{p["hostname"]}:#{p["pid"]}", kind: p["quiet"].to_s == "true" ? "quiet" : "worker",
            busy: p["busy"].to_i, concurrency: p["concurrency"].to_i, queues: Array(p["queues"]).join(", "),
            beat: JobQ.epoch(p["beat"]) }
        },
        lists: [
          { key: "busy", label: "Busy", total: stats.workers_size, items: busy, actions: [] },
          list("retry", "Retries", false, %w[retry delete retry_all delete_all]),
          list("scheduled", "Scheduled", false, %w[retry delete delete_all]),
          list("dead", "Dead", true, %w[retry delete retry_all delete_all])
        ],
        words: WORDS,
        cron: cron_rows
      }
    end
  end

  BACKENDS["sidekiq"] = SidekiqBackend
end
