require "digest"
require "fileutils"
require "json"

class IsolateJob < ApplicationJob
  # Only triggers when the job starts before its submissions are visible in the database.
  retry_on RuntimeError, wait: 0.25.seconds, attempts: 20

  queue_as ENV["JUDGE0_VERSION"].to_sym

  STDIN_FILE_NAME = "stdin.txt"
  STDOUT_FILE_NAME = "stdout.txt"
  STDERR_FILE_NAME = "stderr.txt"
  METADATA_FILE_NAME = "metadata.txt"
  SNAPSHOT_FILE_NAME = "snapshot.tar"
  ADDITIONAL_FILES_ARCHIVE_FILE_NAME = "additional_files.zip"

  attr_reader :submission, :cgroups,
              :box_id, :workdir, :boxdir, :tmpdir,
              :source_file, :stdin_file, :stdout_file,
              :stderr_file, :metadata_file, :snapshot_file,
              :additional_files_archive_file

  # Accepts a single submission token or an array of tokens. All submissions in an
  # array share language, source code, additional files and compile settings
  # (see IsolateRunner.compile_group_key), so the sandbox is prepared and the
  # program is compiled once, then run once per submission (test case).
  def perform(submission_tokens)
    tokens = Array(submission_tokens)
    found = Submission.find_all(tokens)
    missing = tokens.each_index.reject { |i| found[i] }.collect { |i| tokens[i] }
    raise "Submissions #{missing.join(", ")} not found." if missing.any?

    @submissions = found
    @leader = @submissions.first
    @submission = @leader

    started_at = DateTime.now
    @submissions.each do |s|
      s.update(status: Status.process, started_at: started_at, execution_host: ENV["HOSTNAME"])
    end

    initialize_workdir
    if prepare_box == :failure
      cleanup
      return
    end

    execute_all

    cleanup
  rescue Exception => e
    raise e.message unless @leader
    (@submissions || [@leader]).each do |s|
      next unless [Status.queue.id, Status.process.id].include?(s.status_id)
      s.update(message: e.message, status: Status.boxerr, finished_at: DateTime.now)
    end
    cleanup(raise_exception = false)
  ensure
    (@submissions || []).each { |s| call_callback(s) }
    Usage.record_execution(@submissions, **(@usage || {})) if @submissions
  end

  private

  # Runs the leader in this box and the other submissions in parallel, each in its own
  # box restored from the compiled snapshot, so slow or looping test cases do not
  # wait for each other (stock Judge0 also ran them in parallel, one job each).
  def execute_all
    others = @submissions.drop(1)
    concurrency = [[Config::BATCH_RUN_CONCURRENCY, 1].max - 1, others.size].min

    if concurrency.zero?
      @submissions.each do |s|
        @submission = s
        execute_submission
      end
      return
    end

    pending = Queue.new
    others.each { |s| pending << s }
    drain = -> { while (s = (pending.pop(true) rescue nil)); IsolateJob.new.send(:run_from_snapshot, s, snapshot_file); end }

    threads = Array.new(concurrency) { Thread.new(&drain) }
    begin
      @submission = @leader
      execute_submission
      drain.call
    ensure
      threads.each(&:join) # never clean up the shared snapshot while other boxes still use it
    end
  end

  # Runs one submission in its own box, starting from another box's compiled snapshot.
  # Callbacks are sent by the job that owns the batch.
  def run_from_snapshot(submission, source_snapshot)
    @submissions = [submission]
    @leader = submission
    @submission = submission
    initialize_workdir
    `sudo cp #{source_snapshot} #{snapshot_file}`
    restore_snapshot
    execute_submission
    cleanup
  rescue Exception => e
    if [Status.queue.id, Status.process.id].include?(submission.status_id)
      submission.update(message: e.message, status: Status.boxerr, finished_at: DateTime.now)
    end
    cleanup(raise_exception = false)
  end

  def initialize_workdir
    @box_id = @leader.id%2147483647
    @cgroups = (!@leader.enable_per_process_and_thread_time_limit || !@leader.enable_per_process_and_thread_memory_limit) ? "--cg" : ""
    @workdir = `isolate #{cgroups} -b #{box_id} --init`.chomp
    @boxdir = workdir + "/box"
    @tmpdir = workdir + "/tmp"
    @source_file = boxdir + "/" + @leader.language.source_file.to_s
    @stdin_file = workdir + "/" + STDIN_FILE_NAME
    @stdout_file = workdir + "/" + STDOUT_FILE_NAME
    @stderr_file = workdir + "/" + STDERR_FILE_NAME
    @metadata_file = workdir + "/" + METADATA_FILE_NAME
    @snapshot_file = workdir + "/" + SNAPSHOT_FILE_NAME
    @additional_files_archive_file = boxdir + "/" + ADDITIONAL_FILES_ARCHIVE_FILE_NAME
    @runs_done = 0

    initialize_files(stdin_file, stdout_file, stderr_file, metadata_file)
  end

  def initialize_files(*files)
    paths = files.join(" ")
    `sudo touch #{paths} && sudo chown $(whoami): #{paths}`
  end

  # Writes source and additional files into the box and compiles them, or restores
  # an identical compiled box from the worker-local compile cache.
  def prepare_box
    cache_key = compile_cache_key
    cached = compile_cache_lookup(cache_key)

    @usage = { cache_hit: !!cached }
    if cached && cached[:failed]
      @usage[:language] = cached[:language]
      apply_compilation_error(cached[:compile_output])
      return :failure
    elsif cached
      `sudo cp #{cached[:snapshot]} #{snapshot_file}`
      restore_snapshot
      @usage[:language] = detect_language
      apply_compile_output(cached[:compile_output])
      return :success
    end

    File.open(source_file, "wb") { |f| f.write(@leader.source_code) } unless @leader.is_project
    extract_archive
    @usage[:language] = detect_language

    result, compile_output, timed_out = compile
    if result == :failure
      compile_cache_store(cache_key, compile_output, failed: true) unless timed_out
      apply_compilation_error(compile_output)
      return :failure
    end

    # Compiler warnings are reported on every submission, as when each one compiled itself.
    apply_compile_output(compile_output)

    total_runs = @submissions.sum(&:number_of_runs)
    take_snapshot if total_runs > 1 || (result == :success && cache_key)
    compile_cache_store(cache_key, compile_output, failed: false) if result == :success
    :success
  end

  def apply_compile_output(compile_output)
    @submissions.each { |s| s.compile_output = compile_output }
  end

  def extract_archive
    return unless @leader.additional_files?

    File.open(additional_files_archive_file, "wb") { |f| f.write(@leader.additional_files) }

    command = "isolate #{cgroups} \
    -s \
    -b #{box_id} \
    --stderr-to-stdout \
    -t 2 \
    -x 1 \
    -w 4 \
    -k #{Config::MAX_STACK_LIMIT} \
    -p#{Config::MAX_MAX_PROCESSES_AND_OR_THREADS} \
    #{@leader.enable_per_process_and_thread_time_limit ? (cgroups.present? ? "--no-cg-timing" : "") : "--cg-timing"} \
    #{memory_limit_flag(@leader.enable_per_process_and_thread_memory_limit, Config::MAX_MEMORY_LIMIT)} \
    -f #{Config::MAX_EXTRACT_SIZE} \
    --run \
    -- /usr/bin/unzip -n -qq #{ADDITIONAL_FILES_ARCHIVE_FILE_NAME} \
    "

    log("Extracting archive", command)

    `#{command}`

    File.delete(additional_files_archive_file)
  end

  # Returns [:success | :skipped | :failure, compile_output, timed_out].
  def compile
    unless @leader.is_project
      return [:skipped, nil, false] unless @leader.language.compile_cmd
    end

    compile_script = boxdir + "/" + "compile.sh"

    acceptable_project_compile_scripts = [compile_script, boxdir + "/" + "compile"]
    if @leader.is_project
      compile_file_exists = false
      acceptable_project_compile_scripts.each do |f|
        if File.file?(f)
          compile_script = f
          compile_file_exists = true
          break
        end
      end

      unless compile_file_exists
        return [:skipped, nil, false] # If compile script does not exist then this project does not need to be compiled.
      end
    else
      # gsub can be skipped if compile script is used, but is kept for additional security.
      compiler_options = @leader.compiler_options.to_s.strip.encode("UTF-8", invalid: :replace).gsub(/[$&;<>|`]/, "")
      File.open(compile_script, "w") { |f| f.write("#{@leader.language.compile_cmd % compiler_options}") }
    end

    compile_output_file = workdir + "/" + "compile_output.txt"
    initialize_files(compile_output_file)

    command = "isolate #{cgroups} \
    -s \
    -b #{box_id} \
    -M #{metadata_file} \
    --stderr-to-stdout \
    -i /dev/null \
    -t #{Config::MAX_CPU_TIME_LIMIT} \
    -x 0 \
    -w #{Config::MAX_WALL_TIME_LIMIT} \
    -k #{Config::MAX_STACK_LIMIT} \
    -p#{Config::MAX_MAX_PROCESSES_AND_OR_THREADS} \
    #{@leader.enable_per_process_and_thread_time_limit ? (cgroups.present? ? "--no-cg-timing" : "") : "--cg-timing"} \
    #{memory_limit_flag(@leader.enable_per_process_and_thread_memory_limit, Config::MAX_MEMORY_LIMIT)} \
    -f #{Config::MAX_MAX_FILE_SIZE} \
    -E HOME=/tmp \
    -E PATH=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\" \
    -E LANG -E LANGUAGE -E LC_ALL -E JUDGE0_HOMEPAGE -E JUDGE0_SOURCE_CODE -E JUDGE0_MAINTAINER -E JUDGE0_VERSION \
    -d /etc:noexec \
    --run \
    -- /bin/bash $(basename #{compile_script}) > #{compile_output_file} \
    "

    log("Compiling", command)

    `#{command}`
    process_status = $?

    compile_output = File.read(compile_output_file)
    compile_output = nil if compile_output.empty?

    metadata = get_metadata

    reset_metadata_file

    files_to_remove = [compile_output_file]
    files_to_remove << compile_script unless @leader.is_project
    `sudo rm -rf #{files_to_remove.join(" ")}`

    return [:success, compile_output, false] if process_status.success?

    timed_out = metadata[:status] == "TO"
    compile_output = "Compilation time limit exceeded." if timed_out

    [:failure, compile_output, timed_out]
  end

  def apply_compilation_error(compile_output)
    finished_at = DateTime.now
    @submissions.each do |s|
      s.compile_output = compile_output
      s.finished_at = finished_at
      s.time = nil
      s.wall_time = nil
      s.memory = nil
      s.stdout = nil
      s.stderr = nil
      s.exit_code = nil
      s.exit_signal = nil
      s.message = nil
      s.status = Status.ce
      s.save(validate: false)
    end
  end

  def execute_submission
    File.open(stdin_file, "wb") { |f| f.write(submission.stdin) }

    time = []
    memory = []

    submission.number_of_runs.times do
      restore_snapshot if @runs_done > 0
      run
      verify
      @runs_done += 1

      time << submission.time
      memory << submission.memory

      reset_run_files
      break if submission.status != Status.ac
    end

    submission.time = time.inject(&:+).to_f / time.size
    submission.memory = memory.inject(&:+).to_f / memory.size
    submission.save(validate: false)
  end

  def run
    run_script = boxdir + "/" + "run.sh"

    acceptable_project_run_scripts = [run_script, boxdir + "/" + "run"]
    acceptable_project_run_scripts.each do |f|
      if File.file?(f)
        run_script = f
        break
      end
    end

    unless submission.is_project
      # gsub is mandatory!
      command_line_arguments = submission.command_line_arguments.to_s.strip.encode("UTF-8", invalid: :replace).gsub(/[$&;<>|`]/, "")
      File.open(run_script, "w") { |f| f.write("#{submission.language.run_cmd} #{command_line_arguments}")}
    end

    command = "isolate #{cgroups} \
    -s \
    -b #{box_id} \
    -M #{metadata_file} \
    #{submission.redirect_stderr_to_stdout ? "--stderr-to-stdout" : ""} \
    #{submission.enable_network ? "--share-net" : ""} \
    -t #{submission.cpu_time_limit} \
    -x #{submission.cpu_extra_time} \
    -w #{submission.wall_time_limit} \
    -k #{submission.stack_limit} \
    -p#{submission.max_processes_and_or_threads} \
    #{submission.enable_per_process_and_thread_time_limit ? (cgroups.present? ? "--no-cg-timing" : "") : "--cg-timing"} \
    #{memory_limit_flag(submission.enable_per_process_and_thread_memory_limit, submission.memory_limit)} \
    -f #{submission.max_file_size} \
    -E HOME=/tmp \
    -E PATH=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\" \
    -E LANG -E LANGUAGE -E LC_ALL -E JUDGE0_HOMEPAGE -E JUDGE0_SOURCE_CODE -E JUDGE0_MAINTAINER -E JUDGE0_VERSION \
    -d /etc:noexec \
    --run \
    -- /bin/bash $(basename #{run_script}) \
    < #{stdin_file} > #{stdout_file} 2> #{stderr_file} \
    "

    log("Running", command)

    `#{command}`

    `sudo rm #{run_script}` unless submission.is_project
  end

  def verify
    submission.finished_at = DateTime.now

    metadata = get_metadata

    program_stdout = File.read(stdout_file)
    program_stdout = nil if program_stdout.empty?

    program_stderr = File.read(stderr_file)
    program_stderr = nil if program_stderr.empty?

    submission.time = metadata[:time]
    submission.wall_time = metadata[:"time-wall"]
    submission.memory = (cgroups.present? ? metadata[:"cg-mem"] : metadata[:"max-rss"])
    submission.stdout = program_stdout
    submission.stderr = program_stderr
    submission.exit_code = metadata[:exitcode].try(:to_i) || 0
    submission.exit_signal = metadata[:exitsig].try(:to_i)
    submission.message = metadata[:message]
    submission.status = determine_status(metadata[:status], submission.exit_signal)

    # After adding support for compiler_options and command_line_arguments
    # status "Exec Format Error" will no longer occur because compile and run
    # is done inside a dynamically created bash script, thus isolate doesn't call
    # execve directily on submission.language.compile_cmd or submission.langauge.run_cmd.
    # Consequence of running compile and run through bash script is that when
    # target binary is not found then submission gets status "Runtime Error (NZEC)".
    #
    # I think this is for now O.K. behaviour, but I will leave this if block
    # here until I am 100% sure that "Exec Format Error" can be deprecated.
    if submission.status == Status.boxerr &&
       (
         submission.message.to_s.match(/^execve\(.+\): Exec format error$/) ||
         submission.message.to_s.match(/^execve\(.+\): No such file or directory$/) ||
         submission.message.to_s.match(/^execve\(.+\): Permission denied$/)
       )
       submission.status = Status.exeerr
    end
  end

  # Fresh output files for the next run, without re-creating the sandbox.
  def reset_run_files
    `sudo rm -rf #{stdout_file} #{stderr_file} #{metadata_file}`
    initialize_files(stdout_file, stderr_file, metadata_file)
  end

  # Saves the compiled box (ownership and modes preserved) so every run starts from it.
  def take_snapshot
    `sudo tar -C #{boxdir} -cpf #{snapshot_file} .`
  end

  # Puts the box back exactly as it was right after compilation, so runs
  # cannot leave files behind for the next test case.
  def restore_snapshot
    # tmp only exists after a box's first run, so it may be missing in a fresh box.
    `sudo find #{boxdir} -mindepth 1 -delete; [ -d #{tmpdir} ] && sudo find #{tmpdir} -mindepth 1 -delete`
    `sudo tar -C #{boxdir} -xpf #{snapshot_file} --same-owner`
    raise "Restoring sandbox #{box_id} from snapshot failed." unless $?.success?
  end

  def cleanup(raise_exception = true)
    return if workdir.blank?
    `sudo find #{boxdir} #{tmpdir} -mindepth 1 -delete; sudo rm -rf #{stdin_file} #{stdout_file} #{stderr_file} #{metadata_file} #{snapshot_file}`
    `isolate #{cgroups} -b #{box_id} --cleanup`
    raise "Cleanup of sandbox #{box_id} failed." if raise_exception && Dir.exists?(workdir)
  end

  def reset_metadata_file
    `sudo rm -rf #{metadata_file}`
    initialize_files(metadata_file)
  end

  # Everything that can change what compilation produces. nil when caching is off.
  def compile_cache_key
    return nil unless Config::ENABLE_COMPILE_CACHE

    Digest::SHA256.hexdigest([
      ENV["JUDGE0_VERSION"],
      @leader.language_id,
      @leader[:source_code].to_s,
      Digest::SHA256.hexdigest(@leader.additional_files.to_s),
      @leader.compiler_options.to_s,
      cgroups,
      @leader.enable_per_process_and_thread_time_limit,
      @leader.enable_per_process_and_thread_memory_limit
    ].to_json)
  end

  # Cache entry: <key>.json ({failed, compile_output}) plus <key>.tar (compiled box) on success.
  # Returns { failed:, compile_output:, snapshot: } or nil.
  def compile_cache_lookup(key)
    return nil unless key

    meta_path = cache_path(key, "json")
    return nil unless File.exist?(meta_path)
    return nil if Time.now - File.mtime(meta_path) > Config::COMPILE_CACHE_TTL

    meta = JSON.parse(File.read(meta_path))
    entry = { failed: meta["failed"] == true, compile_output: meta["compile_output"], language: meta["language"] }
    unless entry[:failed]
      entry[:snapshot] = cache_path(key, "tar")
      return nil unless File.exist?(entry[:snapshot])
    end
    entry
  rescue StandardError
    nil
  end

  # The .json is written last, so a reader never sees it without its .tar.
  def compile_cache_store(key, compile_output, failed:)
    return unless key
    return if !failed && !File.exist?(snapshot_file)

    unless failed
      tar = cache_path(key, "tar")
      tmp_tar = "#{tar}.#{Process.pid}.tmp"
      `sudo cp #{snapshot_file} #{tmp_tar} && sudo chmod 644 #{tmp_tar} && mv -f #{tmp_tar} #{tar}`
      return unless $?.success?
    end

    meta = cache_path(key, "json")
    tmp_meta = "#{meta}.#{Process.pid}.tmp"
    File.write(tmp_meta, { failed: failed, compile_output: compile_output, language: (@usage || {})[:language] }.to_json)
    File.rename(tmp_meta, meta)
    prune_compile_cache
  rescue StandardError
  end

  def cache_path(key, ext)
    FileUtils.mkdir_p(Config::COMPILE_CACHE_DIR)
    File.join(Config::COMPILE_CACHE_DIR, "#{key}.#{ext}")
  end

  # shortcut: scans the cache dir on every store, fine for a few thousand entries; use an LRU index if it grows past that.
  def prune_compile_cache
    entries = Dir.glob(File.join(Config::COMPILE_CACHE_DIR, "*")).collect { |p| [p, File.mtime(p), File.size(p)] rescue nil }.compact
    expired, live = entries.partition { |_, mtime, _| Time.now - mtime > Config::COMPILE_CACHE_TTL }
    expired.each { |p, _, _| File.delete(p) rescue nil }

    total = live.sum { |_, _, size| size }
    limit = Config::COMPILE_CACHE_MAX_MB * 1024 * 1024
    live.sort_by { |_, mtime, _| mtime }.each do |p, _, size|
      break if total <= limit
      File.delete(p) rescue nil
      total -= size
    end
  end

  # Best-effort language label for usage analytics, from the project's compile/run scripts
  # (or the Judge0 language for single-file submissions).
  def detect_language
    return @leader.language.try(:name).to_s unless @leader.is_project
    script = %w[compile compile.sh run run.sh].collect { |f| File.read(File.join(boxdir, f)) rescue "" }.join("\n")
    case script
    when /\bjavac\b|\bjava\b/ then "java"
    when /\bg\+\+/ then "cpp"
    when /\bgcc\b/ then "c"
    when /\bnode\b/ then "javascript"
    when /\bpython3?\b/ then "python"
    when /\bgo\s+(build|run)\b/ then "go"
    else script[/\A\s*(\S+)/, 1] || "unknown"
    end
  end

  def call_callback(s)
    return unless s.callback_url.present?

    serialized_submission = ActiveModelSerializers::SerializableResource.new(
      s,
      {
        serializer: SubmissionSerializer,
        base64_encoded: true,
        fields: SubmissionSerializer.default_fields
      }
    ).to_json

    Config::CALLBACKS_MAX_TRIES.times do
      begin
        response = HTTParty.put(
          s.callback_url,
          body: serialized_submission,
          headers: {
            "Content-Type" => "application/json"
          },
          timeout: Config::CALLBACKS_TIMEOUT
        )
        break
      rescue Exception => e
      end
    end
  rescue Exception => e
  end

  # Per-process mode limits address space (-m); cgroup mode limits real memory (--cg-mem).
  # ISOLATE_DISABLE_ADDRESS_SPACE_LIMIT drops -m for local hosts without cgroup v1, where
  # Node and the JVM cannot start under a small address-space limit. Never set it in production.
  def memory_limit_flag(per_process, limit_kb)
    return "--cg-mem=#{limit_kb}" unless per_process
    Config::ISOLATE_DISABLE_ADDRESS_SPACE_LIMIT ? "" : "-m #{limit_kb}"
  end

  def log(action, command)
    Rails.logger.debug { "[#{DateTime.now}] #{action} submission #{submission.token} (#{submission.id}): #{command.gsub(/\s+/, " ")}" }
  end

  def get_metadata
    metadata = File.read(metadata_file).split("\n").collect do |e|
      { e.split(":").first.to_sym => e.split(":")[1..-1].join(":") }
    end.reduce({}, :merge)
    return metadata
  end

  def determine_status(status, exit_signal)
    if status == "TO"
      return Status.tle
    elsif status == "SG"
      return Status.find_runtime_error_by_status_code(exit_signal)
    elsif status == "RE"
      return Status.nzec
    elsif status == "XX"
      return Status.boxerr
    elsif submission.expected_output.nil? || strip(submission.expected_output) == strip(submission.stdout)
      return Status.ac
    else
      return Status.wa
    end
  end

  def strip(text)
    return nil unless text
    text.split("\n").collect(&:rstrip).join("\n").rstrip
  rescue ArgumentError
    return text
  end
end
