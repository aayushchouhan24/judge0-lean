require "digest"

module IsolateRunner
  MAX_WAIT_TIME_S = 600

  INITIAL_WAIT_TIME_S = 2
  NEXT_WAIT_TIME_S = 1
  WAIT_TIME_FACTOR_S = 0.5

  WAITING_STATUSES = [Status.queue.id, Status.process.id, nil]

  def self.perform_now(submission)
    IsolateRunner.perform_later(submission)

    token = submission.token

    total_wait_time = 0
    (0..).each do |i|
      break if total_wait_time >= MAX_WAIT_TIME_S

      if i == 0 then
        wait_time = INITIAL_WAIT_TIME_S
      elsif i == 1 then
        wait_time = NEXT_WAIT_TIME_S
      else
        wait_time = WAIT_TIME_FACTOR_S * i
      end

      sleep(wait_time)

      total_wait_time += wait_time

      break if !WAITING_STATUSES.include?(Submission.find_by(token: token)&.status_id)
    end
  end

  def self.perform_later(submission)
    submission.update(status: Status.queue, queued_at: DateTime.now, queue_host: ENV["HOSTNAME"])
    IsolateJob.perform_later(submission.token)
  end

  # Enqueues one job per group of submissions that compile identically, so each
  # group is unzipped and compiled once and then run once per submission.
  def self.perform_later_batch(submissions)
    return submissions.each { |s| perform_later(s) } unless Config::ENABLE_BATCH_COMPILE_ONCE

    submissions.group_by { |s| compile_group_key(s) }.each_value do |group|
      now = DateTime.now
      group.each { |s| s.update(status: Status.queue, queued_at: now, queue_host: ENV["HOSTNAME"]) }
      IsolateJob.perform_later(group.collect(&:token))
    end
  end

  def self.compile_group_key(submission)
    [
      submission.language_id,
      Digest::SHA256.hexdigest(submission[:source_code].to_s),
      submission.additional_files_digest.to_s,
      submission.compiler_options.to_s,
      submission.enable_per_process_and_thread_time_limit,
      submission.enable_per_process_and_thread_memory_limit
    ]
  end
end
