require "mongo"

# Usage analytics in MongoDB (enabled when MONGODB_URI is set):
#   requests   one document per API request (time, client, endpoint, status, latency, bytes)
#   executions one document per judged batch (language, verdicts, CPU, memory, timings, cost)
# Both expire after USAGE_RETENTION_DAYS via a TTL index, so nothing needs cleaning up.
# Writes are buffered and flushed in the background: MongoDB being slow or down never
# delays or fails a request or a job.
module Usage
  RETENTION_DAYS = (ENV["USAGE_RETENTION_DAYS"].presence || 180).to_i
  SYSTEM_ERRORS = ["Internal Error", "Exec Format Error"].freeze
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
        worker: ENV["HOSTNAME"],
        # Sandbox failures carry isolate's message; wrong answers and student errors are not system errors.
        error: submissions.find { |s| SYSTEM_ERRORS.include?(s.status.try(:name)) }.try(:message).to_s[0, 300].presence
      }.compact)
    rescue StandardError => e
      warn_once("record_execution", e)
    end

    # Aggregates for the dashboard over the last `hours`.
    def stats(hours, errors_only: false)
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
                                   cache_hits: { "$sum" => { "$cond" => ["$cache_hit", 1, 0] } },
                                   queue: pct.("$queue_ms"), run: pct.("$run_ms") } }, { "$project" => { _id: 0 } }],
          series: [{ "$group" => { _id: bucket, batches: { "$sum" => 1 }, tests: { "$sum" => "$tests" } } }, { "$sort" => { _id: 1 } }],
          languages: [{ "$group" => { _id: "$language", batches: { "$sum" => 1 }, tests: { "$sum" => "$tests" }, cpu_s: { "$sum" => "$cpu_s" },
                                      accepted: { "$sum" => { "$cond" => [{ "$eq" => ["$verdict", "Accepted"] }, 1, 0] } }, run: pct.("$run_ms") } },
                      { "$sort" => { batches: -1 } }],
          verdicts: [{ "$group" => { _id: "$verdict", batches: { "$sum" => 1 } } }, { "$sort" => { batches: -1 } }]
        } }
      ]).first

      {
        window_hours: hours, bucket: unit, generated_at: Time.now.utc,
        requests: req, executions: exe,
        logs: logs(since, errors_only),
        queue: (Resque.size(ENV["JUDGE0_VERSION"]) rescue nil)
      }
    end

    # Most recent events, newest first; errors_only keeps failed requests and sandbox failures.
    def logs(since, errors_only, limit = 100)
      req_filter = { ts: { "$gte" => since } }
      exe_filter = { ts: { "$gte" => since } }
      if errors_only
        req_filter[:status] = { "$gte" => 400 }
        exe_filter[:error] = { "$exists" => true }
      end
      reqs = db["requests"].find(req_filter, projection: { _id: 0, ts: 1, method: 1, endpoint: 1, status: 1, duration_ms: 1, ip: 1, error: 1, batch_size: 1 })
                           .sort(ts: -1).limit(limit).collect { |d| d.to_h.merge("kind" => "request") }
      exes = db["executions"].find(exe_filter, projection: { _id: 0, ts: 1, language: 1, tests: 1, verdict: 1, run_ms: 1, queue_ms: 1, error: 1, cache_hit: 1 })
                             .sort(ts: -1).limit(limit).collect { |d| d.to_h.merge("kind" => "execution") }
      (reqs + exes).sort_by { |d| -d["ts"].to_f }.first(limit)
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
      # Captured first: Rails rewrites PATH_INFO to /404 or /500 when it renders an error page.
      env["usage.path"] = env["PATH_INFO"].to_s
      env["usage.method"] = env["REQUEST_METHOD"]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = -> { ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1) }
      begin
        status, headers, body = @app.call(env)
      rescue Exception => e
        # The app crashed before producing a response: log it as a 500, then let Rails render it.
        Usage.push("requests", document(env, 500, elapsed.call, 0, "#{e.class}: #{e.message}"[0, 300]))
        raise
      end
      duration_ms = elapsed.call
      body = CountingBody.new(body, capture: status.to_i >= 400) do |bytes_out, head|
        Usage.push("requests", document(env, status, duration_ms, bytes_out, error_text(head, status)))
      end
      [status, headers, body]
    end

    private

    # Failed responses keep their error message ({"error": ...} or the start of the body).
    def error_text(head, status)
      return nil if head.nil?
      return Rack::Utils::HTTP_STATUS_CODES[status.to_i] if head.blank?
      parsed = JSON.parse(head) rescue nil
      text = parsed.is_a?(Hash) ? (parsed["error"] || parsed.to_json) : head
      text.to_s[0, 300]
    end

    def document(env, status, duration_ms, bytes_out, error = nil)
      req = Rack::Request.new(env)
      params = env["action_dispatch.request.request_parameters"] || {}
      referer = env["HTTP_REFERER"].to_s
      {
        ts: Time.now.utc,
        method: env["usage.method"] || env["REQUEST_METHOD"],
        endpoint: (env["usage.path"] || env["PATH_INFO"]).to_s.gsub(TOKEN_PATH, "/submissions/:token"),
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
        fields: req.params["fields"],
        error: error
      }.compact
    end
  end

  # Counts response bytes as the server writes them, then reports on close.
  class CountingBody
    CAPTURE_BYTES = 1024

    def initialize(body, capture: false, &on_close)
      @body = body
      @bytes = 0
      @head = capture ? +"" : nil
      @on_close = on_close
    end

    def each
      @body.each do |chunk|
        @bytes += chunk.bytesize
        @head << chunk.byteslice(0, CAPTURE_BYTES - @head.bytesize) if @head && @head.bytesize < CAPTURE_BYTES
        yield chunk
      end
    end

    def close
      @body.close if @body.respond_to?(:close)
    ensure
      @on_close.call(@bytes, @head && @head.force_encoding(Encoding::UTF_8).scrub)
    end
  end
end
