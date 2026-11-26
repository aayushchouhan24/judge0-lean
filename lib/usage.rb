require "mongo"

# Usage analytics in MongoDB (enabled when MONGODB_URI is set):
#   requests   one document per API request (time, client, endpoint, status, latency, bytes)
#   executions one document per judged batch (language, verdicts, CPU, memory, timings, cost)
# Both expire after USAGE_RETENTION_DAYS via a TTL index, so nothing needs cleaning up.
# Writes are buffered and flushed in the background: MongoDB being slow or down never
# delays or fails a request or a job.
module Usage
  RETENTION_DAYS = (ENV["USAGE_RETENTION_DAYS"].presence || 180).to_i
  # Allocated compute price used for cost estimates (default: c6a.2xlarge spot / 8 vCPU).
  USD_PER_VCPU_HOUR = (ENV["USAGE_USD_PER_VCPU_HOUR"].presence || 0.0153).to_f
  FIXED_MONTHLY_USD = (ENV["USAGE_FIXED_MONTHLY_USD"].presence || 2).to_f
  FLUSH_SECONDS = 2
  MAX_BUFFER = 20_000
  COLLECTIONS = %w[requests executions].freeze

  class << self
    def enabled?
      ENV["MONGODB_URI"].present?
    end

    # One client per process (Puma and Resque fork after boot).
    def db
      return @db if @db && @db_pid == Process.pid
      Mongo::Logger.logger.level = Logger::WARN
      client = Mongo::Client.new(ENV["MONGODB_URI"],
        database: ENV["USAGE_DB"].presence || "judge0_lean", app_name: "judge0-lean",
        server_selection_timeout: 3, connect_timeout: 3, socket_timeout: 10, max_pool_size: 3)
      @db_pid = Process.pid
      @db = client.database
      COLLECTIONS.each do |c|
        @db[c].indexes.create_one({ ts: 1 }, expire_after: RETENTION_DAYS * 86_400, name: "ts_ttl")
      rescue StandardError => e
        warn_once("index #{c}", e)
      end
      @db
    end

    # shortcut: up to FLUSH_SECONDS of events are lost if a process is killed; fine for analytics.
    def push(collection, doc)
      return unless enabled?
      start_flusher
      @mutex.synchronize { @buffer << [collection, doc] if @buffer.size < MAX_BUFFER }
    end

    def flush
      return unless @mutex
      batch = @mutex.synchronize { b = @buffer; @buffer = []; b }
      batch.group_by(&:first).each do |collection, items|
        db[collection].insert_many(items.collect(&:last), ordered: false)
      end
    rescue StandardError => e
      warn_once("flush", e)
    end

    def record_execution(submissions, language: nil, cache_hit: false)
      return if submissions.blank?
      leader = submissions.first
      now = Time.now.utc
      statuses = submissions.collect { |s| s.status.try(:name).to_s }
      run_ms = leader.started_at ? ((now - leader.started_at.to_time) * 1000).round : nil
      queue_ms = leader.started_at && leader.queued_at ? ((leader.started_at.to_time - leader.queued_at.to_time) * 1000).round : nil
      push("executions", {
        ts: now,
        language: language.presence || "unknown",
        tests: submissions.size,
        statuses: statuses.tally,
        verdict: statuses.find { |s| s != "Accepted" } || "Accepted",
        cache_hit: cache_hit,
        cpu_s: submissions.sum { |s| s.time.to_f }.round(4),
        max_memory_kb: submissions.collect { |s| s.memory.to_i }.max,
        queue_ms: queue_ms,
        run_ms: run_ms,
        archive_bytes: leader.additional_files.to_s.bytesize,
        cost_usd: run_ms ? (run_ms / 3_600_000.0 * USD_PER_VCPU_HOUR).round(8) : 0,
        worker: ENV["HOSTNAME"]
      })
    rescue StandardError => e
      warn_once("record_execution", e)
    end

    # Aggregates for the dashboard over the last `hours`.
    def stats(hours)
      since = Time.now.utc - hours * 3600
      unit = hours <= 6 ? "minute" : (hours <= 72 ? "hour" : "day")
      bucket = { "$dateTrunc" => { date: "$ts", unit: unit, binSize: unit == "minute" ? 5 : 1 } }
      pct = ->(field) { { "$percentile" => { input: field, p: [0.5, 0.95], method: "approximate" } } }

      req = db["requests"].aggregate([
        { "$match" => { ts: { "$gte" => since } } },
        { "$facet" => {
          totals: [{ "$group" => { _id: nil, requests: { "$sum" => 1 }, bytes_in: { "$sum" => "$bytes_in" },
                                   bytes_out: { "$sum" => "$bytes_out" }, errors: { "$sum" => { "$cond" => [{ "$gte" => ["$status", 400] }, 1, 0] } },
                                   latency: pct.("$duration_ms"), clients: { "$addToSet" => "$ip" } } },
                   { "$project" => { _id: 0, requests: 1, bytes_in: 1, bytes_out: 1, errors: 1, latency: 1, clients: { "$size" => "$clients" } } }],
          series: [{ "$group" => { _id: bucket, requests: { "$sum" => 1 }, bytes: { "$sum" => { "$add" => ["$bytes_in", "$bytes_out"] } } } }, { "$sort" => { _id: 1 } }],
          endpoints: [{ "$group" => { _id: { method: "$method", endpoint: "$endpoint" }, requests: { "$sum" => 1 },
                                      bytes: { "$sum" => { "$add" => ["$bytes_in", "$bytes_out"] } }, latency: pct.("$duration_ms") } },
                      { "$sort" => { requests: -1 } }, { "$limit" => 15 }],
          statuses: [{ "$group" => { _id: "$status", requests: { "$sum" => 1 } } }, { "$sort" => { requests: -1 } }],
          clients: [{ "$group" => { _id: { ip: "$ip", origin: "$origin", user_agent: "$user_agent" }, requests: { "$sum" => 1 },
                                    bytes: { "$sum" => { "$add" => ["$bytes_in", "$bytes_out"] } }, last_seen: { "$max" => "$ts" } } },
                    { "$sort" => { requests: -1 } }, { "$limit" => 15 }]
        } }
      ]).first

      exe = db["executions"].aggregate([
        { "$match" => { ts: { "$gte" => since } } },
        { "$facet" => {
          totals: [{ "$group" => { _id: nil, batches: { "$sum" => 1 }, tests: { "$sum" => "$tests" }, cpu_s: { "$sum" => "$cpu_s" },
                                   cost_usd: { "$sum" => "$cost_usd" }, cache_hits: { "$sum" => { "$cond" => ["$cache_hit", 1, 0] } },
                                   queue: pct.("$queue_ms"), run: pct.("$run_ms") } }, { "$project" => { _id: 0 } }],
          series: [{ "$group" => { _id: bucket, batches: { "$sum" => 1 }, tests: { "$sum" => "$tests" } } }, { "$sort" => { _id: 1 } }],
          languages: [{ "$group" => { _id: "$language", batches: { "$sum" => 1 }, tests: { "$sum" => "$tests" }, cpu_s: { "$sum" => "$cpu_s" },
                                      accepted: { "$sum" => { "$cond" => [{ "$eq" => ["$verdict", "Accepted"] }, 1, 0] } }, run: pct.("$run_ms") } },
                      { "$sort" => { batches: -1 } }],
          verdicts: [{ "$group" => { _id: "$verdict", batches: { "$sum" => 1 } } }, { "$sort" => { batches: -1 } }]
        } }
      ]).first

      month_factor = 720.0 / hours
      {
        window_hours: hours, bucket: unit, generated_at: Time.now.utc,
        requests: req, executions: exe,
        cost: {
          compute_usd: exe["totals"].first.to_h["cost_usd"].to_f,
          projected_month_compute_usd: (exe["totals"].first.to_h["cost_usd"].to_f * month_factor).round(4),
          fixed_month_usd: FIXED_MONTHLY_USD,
          usd_per_vcpu_hour: USD_PER_VCPU_HOUR
        },
        queue: (Resque.size(ENV["JUDGE0_VERSION"]) rescue nil)
      }
    end

    private

    def start_flusher
      return if @flusher_pid == Process.pid && @flusher && @flusher.alive?
      @flusher_pid = Process.pid
      @mutex = Mutex.new
      @buffer = []
      @flusher = Thread.new { loop { sleep FLUSH_SECONDS; flush } }
      at_exit { flush }
    end

    def warn_once(what, error)
      @warned ||= {}
      return if @warned[what] && Time.now - @warned[what] < 300
      @warned[what] = Time.now
      Rails.logger.warn("[usage] #{what} failed: #{error.class}: #{error.message}")
    end
  end

  # Rack middleware: records one document per request after the response body is sent.
  class RequestTracker
    SKIP = %w[/healthz /favicon.ico].freeze
    TOKEN_PATH = %r{/submissions/[0-9a-f-]{36}}

    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) unless Usage.enabled? && !SKIP.include?(env["PATH_INFO"])
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status, headers, body = @app.call(env)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
      [status, headers, CountingBody.new(body) { |bytes_out| Usage.push("requests", document(env, status, duration_ms, bytes_out)) }]
    end

    private

    def document(env, status, duration_ms, bytes_out)
      req = Rack::Request.new(env)
      params = env["action_dispatch.request.request_parameters"] || {}
      referer = env["HTTP_REFERER"].to_s
      {
        ts: Time.now.utc,
        method: env["REQUEST_METHOD"],
        endpoint: env["PATH_INFO"].to_s.gsub(TOKEN_PATH, "/submissions/:token"),
        status: status.to_i,
        duration_ms: duration_ms,
        bytes_in: env["CONTENT_LENGTH"].to_i,
        bytes_out: bytes_out,
        ip: (env["action_dispatch.remote_ip"] || req.ip).to_s,
        origin: env["HTTP_ORIGIN"],
        referer_host: (URI(referer).host rescue nil if referer.present?),
        user_agent: env["HTTP_USER_AGENT"].to_s[0, 200],
        batch_size: params["submissions"].is_a?(Array) ? params["submissions"].size : nil,
        tokens: req.params["tokens"].to_s.split(",").size.nonzero?,
        base64: req.params["base64_encoded"],
        wait: req.params["wait"],
        fields: req.params["fields"]
      }.compact
    end
  end

  # Counts response bytes as the server writes them, then reports on close.
  class CountingBody
    def initialize(body, &on_close)
      @body = body
      @bytes = 0
      @on_close = on_close
    end

    def each
      @body.each do |chunk|
        @bytes += chunk.bytesize
        yield chunk
      end
    end

    def close
      @body.close if @body.respond_to?(:close)
    ensure
      @on_close.call(@bytes)
    end
  end
end
