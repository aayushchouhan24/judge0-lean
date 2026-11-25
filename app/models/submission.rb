require "digest"

# Submissions are stored in Redis with a TTL instead of a database: they only need
# to exist between a client creating them and reading the result.
#
#   judge0:submission:<token>  JSON of all attributes except additional_files
#   judge0:files:<sha256>      additional_files archive, shared by identical submissions
#   judge0:submission_id       counter used for numeric ids (sandbox box ids)
#
# Every save refreshes the TTL, so queued and running submissions do not expire.
class Submission
  include ActiveModel::Model
  include ActiveModel::Attributes
  include ActiveModel::Validations::Callbacks
  include ActiveModel::Serialization

  TTL = (ENV["SUBMISSION_TTL_SECONDS"].presence || 3600).to_i
  KEY_PREFIX = "judge0:submission:"
  FILES_KEY_PREFIX = "judge0:files:"
  ID_SEQUENCE_KEY = "judge0:submission_id"
  MAX_ID = 2147483647

  attribute :id,                                         :integer
  attribute :source_code,                                :string
  attribute :language_id,                                :integer
  attribute :stdin,                                      :string
  attribute :expected_output,                            :string
  attribute :stdout,                                     :string
  attribute :status_id,                                  :integer
  attribute :created_at,                                 :datetime
  attribute :finished_at,                                :datetime
  attribute :time,                                       :decimal
  attribute :memory,                                     :integer
  attribute :stderr,                                     :string
  attribute :token,                                      :string
  attribute :number_of_runs,                             :integer
  attribute :cpu_time_limit,                             :decimal
  attribute :cpu_extra_time,                             :decimal
  attribute :wall_time_limit,                            :decimal
  attribute :memory_limit,                               :integer
  attribute :stack_limit,                                :integer
  attribute :max_processes_and_or_threads,               :integer
  attribute :enable_per_process_and_thread_time_limit,   :boolean
  attribute :enable_per_process_and_thread_memory_limit, :boolean
  attribute :max_file_size,                              :integer
  attribute :compile_output,                             :string
  attribute :exit_code,                                  :integer
  attribute :exit_signal,                                :integer
  attribute :message,                                    :string
  attribute :wall_time,                                  :decimal
  attribute :compiler_options,                           :string
  attribute :command_line_arguments,                     :string
  attribute :redirect_stderr_to_stdout,                  :boolean
  attribute :callback_url,                               :string
  attribute :additional_files,                           :binary
  attribute :enable_network,                             :boolean
  attribute :started_at,                                 :datetime
  attribute :queued_at,                                  :datetime
  attribute :updated_at,                                 :datetime
  attribute :queue_host,                                 :string
  attribute :execution_host,                             :string
  attribute :additional_files_digest,                    :string

  validates :source_code, presence: true, unless: -> { is_project }
  validates :source_code, absence: true, if: -> { is_project }
  validates :additional_files, presence: true, if: -> { is_project }
  validates :language_id, presence: true
  validates :number_of_runs,
            numericality: { greater_than: 0, less_than_or_equal_to: Config::MAX_NUMBER_OF_RUNS }
  validates :cpu_time_limit,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: Config::MAX_CPU_TIME_LIMIT }
  validates :cpu_extra_time,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: Config::MAX_CPU_EXTRA_TIME }
  validates :wall_time_limit,
            numericality: { greater_than_or_equal_to: 1, less_than_or_equal_to: Config::MAX_WALL_TIME_LIMIT }
  validates :memory_limit,
            numericality: { greater_than_or_equal_to: 2048, less_than_or_equal_to: Config::MAX_MEMORY_LIMIT }
  validates :stack_limit,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: Config::MAX_STACK_LIMIT }
  validates :max_processes_and_or_threads,
            numericality: { greater_than: 0, less_than_or_equal_to: Config::MAX_MAX_PROCESSES_AND_OR_THREADS }
  validates :enable_per_process_and_thread_time_limit,
            inclusion: { in: [false], message: "this option cannot be enabled" },
            unless: -> { Config::ALLOW_ENABLE_PER_PROCESS_AND_THREAD_TIME_LIMIT }
  validates :enable_per_process_and_thread_memory_limit,
            inclusion: { in: [false], message: "this option cannot be enabled" },
            unless: -> { Config::ALLOW_ENABLE_PER_PROCESS_AND_THREAD_MEMORY_LIMIT }
  validates :max_file_size,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: Config::MAX_MAX_FILE_SIZE }
  validates :compiler_options, length: { maximum: 512 }
  validates :command_line_arguments, length: { maximum: 512 }
  validate :language_existence, :compiler_options_allowed,
           :command_line_arguments_allowed, :callbacks_allowed,
           :additional_files_allowed, :network_allowed

  before_validation :set_defaults

  def self.per_page
    20
  end

  # Attribute names exposed to clients (the serializer); the files digest is internal.
  def self.column_names
    @column_names ||= attribute_names - ["additional_files_digest"]
  end

  def self.find_by(token:)
    return nil if token.blank?
    from_store(JUDGE0_REDIS.get(KEY_PREFIX + token.to_s))
  end

  def self.find_by!(token:)
    find_by(token: token) || raise(RecordNotFound, "Couldn't find Submission")
  end

  # Returns submissions in the order of tokens, nil for missing or expired ones.
  def self.find_all(tokens)
    return [] if tokens.empty?
    JUDGE0_REDIS.mget(*tokens.collect { |t| KEY_PREFIX + t.to_s }).collect { |json| from_store(json) }
  end

  def self.from_store(json)
    return nil if json.nil?
    submission = new
    JSON.parse(json).each do |name, value|
      submission.send(:write_stored_attribute, name, value) if attribute_names.include?(name)
    end
    submission
  end

  def [](name)
    @attributes.fetch_value(name.to_s)
  end

  def []=(name, value)
    @attributes.write_from_user(name.to_s, value)
  end

  def new_record?
    id.nil?
  end

  def save(validate: true)
    return false if validate && !valid?

    if new_record?
      self.token ||= SecureRandom.uuid
      self.id = (JUDGE0_REDIS.incr(ID_SEQUENCE_KEY) % MAX_ID) + 1
      self.created_at ||= Time.now
    end
    self.updated_at = Time.now

    persist_additional_files
    JUDGE0_REDIS.set(KEY_PREFIX + token, stored_attributes.to_json, ex: TTL)
    true
  end

  # Internal updates (queueing, worker results) are always stored, without re-validation.
  def update(attributes)
    assign_attributes(attributes)
    save(validate: false)
  end

  def delete
    JUDGE0_REDIS.del(KEY_PREFIX + token) if token.present?
    self
  end

  def reload
    fresh = self.class.find_by!(token: token)
    @attributes = fresh.instance_variable_get(:@attributes)
    instance_variables.grep(/\A@decoded_/).each { |ivar| remove_instance_variable(ivar) }
    @language = nil
    @additional_files_loaded = false
    @additional_files_dirty = false
    self
  end


  def source_code
    @decoded_source_code ||= Base64Service.decode(self[:source_code])
  end

  def source_code=(value)
    super(value)
    self[:source_code] = Base64Service.encode(self[:source_code])
  end


  def stdin
    @decoded_stdin ||= Base64Service.decode(self[:stdin])
  end

  def stdin=(value)
    super(value)
    self[:stdin] = Base64Service.encode(self[:stdin])
  end


  def stdout
    @decoded_stdout ||= Base64Service.decode(self[:stdout])
  end

  def stdout=(value)
    super(value)
    self[:stdout] = Base64Service.encode(self[:stdout])
  end


  def expected_output
    @decoded_expected_output ||= Base64Service.decode(self[:expected_output])
  end

  def expected_output=(value)
    super(value)
    self[:expected_output] = Base64Service.encode(self[:expected_output])
  end


  def stderr
    @decoded_stderr ||= Base64Service.decode(self[:stderr])
  end

  def stderr=(value)
    super(value)
    self[:stderr] = Base64Service.encode(self[:stderr])
  end


  def compile_output
    @decoded_compile_output ||= Base64Service.decode(self[:compile_output])
  end

  def compile_output=(value)
    super(value)
    self[:compile_output] = Base64Service.encode(self[:compile_output])
  end


  # Loaded from Redis only when used (workers), never on polls.
  def additional_files
    if !@additional_files_loaded && !@additional_files_dirty && additional_files_digest.present?
      data = JUDGE0_REDIS.get(FILES_KEY_PREFIX + additional_files_digest)
      @attributes.write_from_database("additional_files", data&.b)
      @additional_files_loaded = true
    end
    super
  end

  def additional_files=(value)
    super(value)
    @additional_files_dirty = true
  end

  def additional_files?
    additional_files.present?
  end


  def language
    @language ||= Language.unscoped.find_by(id: language_id)
  end


  def status
    Status.find_by(id: status_id)
  end

  def status=(status)
    self.status_id = status.id
  end


  def is_project
    language.try(:is_project) || false
  end

  private

  def write_stored_attribute(name, value)
    @attributes.write_from_database(name, value)
  end

  def stored_attributes
    (self.class.attribute_names - ["additional_files"]).index_with do |name|
      value = self[name]
      case value
      when BigDecimal then value.to_s("F")
      when Time, DateTime then value.iso8601(6)
      else value
      end
    end
  end

  # Archives are stored once per content hash, so identical test cases share one copy.
  def persist_additional_files
    if @additional_files_dirty
      data = self[:additional_files]
      if data.present?
        digest = Digest::SHA256.hexdigest(data)
        key = FILES_KEY_PREFIX + digest
        JUDGE0_REDIS.expire(key, TTL) unless JUDGE0_REDIS.set(key, data, ex: TTL, nx: true)
        self.additional_files_digest = digest
      else
        self.additional_files_digest = nil
      end
      @additional_files_dirty = false
      @additional_files_loaded = true
    elsif additional_files_digest.present?
      JUDGE0_REDIS.expire(FILES_KEY_PREFIX + additional_files_digest, TTL)
    end
  end

  def language_existence
    if not language
      errors.add(:language_id, "language with id #{language_id} doesn't exist")
    elsif language.is_archived
      errors.add(:language_id, "language with id #{language_id} is archived and cannot be used anymore")
    end
  end

  def compiler_options_allowed
    return if compiler_options.blank?

    unless Config::ENABLE_COMPILER_OPTIONS
      errors.add(:compiler_options, "setting compiler options is not allowed")
      return
    end

    if language && language.compile_cmd.nil?
      errors.add(:compiler_options, "setting compiler options is only allowed for compiled languages")
      return
    end

    @@allowed_languages ||= Config::ALLOWED_LANGUAGES_FOR_COMPILER_OPTIONS.collect{ |s| s + " " }
    if language && @@allowed_languages.present? && !language.name.starts_with?(*@@allowed_languages)
      @@allowed_languages_message ||= @@allowed_languages.size > 1 ? @@allowed_languages[0..-2].collect{ |s| s.strip }.join(", ") + " and " + @@allowed_languages[-1].strip : @@allowed_languages[0].strip
      errors.add(:compiler_options, "setting compiler options is only allowed for #{@@allowed_languages_message}")
    end
  end

  def command_line_arguments_allowed
    return if command_line_arguments.blank?

    unless Config::ENABLE_COMMAND_LINE_ARGUMENTS
      errors.add(:command_line_arguments, "setting command line arguments is not allowed")
    end
  end

  def callbacks_allowed
    return if callback_url.blank?

    unless Config::ENABLE_CALLBACKS
      errors.add(:callback_url, "setting callback is not allowed")
    end
  end

  def additional_files_allowed
    return if additional_files.blank?

    unless Config::ENABLE_ADDITIONAL_FILES
      errors.add(:additional_files, "setting additional files is not allowed")
    end
  end

  def network_allowed
    return if enable_network.blank?

    unless Config::ALLOW_ENABLE_NETWORK
      errors.add(:enable_network, "enabling network is not allowed")
    end
  end

  def set_defaults
    self.status ||= Status.queue
    self.number_of_runs ||= Config::NUMBER_OF_RUNS
    self.cpu_time_limit ||= Config::CPU_TIME_LIMIT
    self.cpu_extra_time ||= Config::CPU_EXTRA_TIME
    self.wall_time_limit ||= Config::WALL_TIME_LIMIT
    self.memory_limit ||= Config::MEMORY_LIMIT
    self.stack_limit ||= Config::STACK_LIMIT
    self.max_processes_and_or_threads ||= Config::MAX_PROCESSES_AND_OR_THREADS
    self.enable_per_process_and_thread_time_limit = NilValue.value_or_default(
      self.enable_per_process_and_thread_time_limit,
      Config::ENABLE_PER_PROCESS_AND_THREAD_TIME_LIMIT
    )
    self.enable_per_process_and_thread_memory_limit = NilValue.value_or_default(
      self.enable_per_process_and_thread_memory_limit,
      Config::ENABLE_PER_PROCESS_AND_THREAD_MEMORY_LIMIT
    )
    self.max_file_size ||= Config::MAX_FILE_SIZE
    self.redirect_stderr_to_stdout = NilValue.value_or_default(
      self.redirect_stderr_to_stdout,
      Config::REDIRECT_STDERR_TO_STDOUT
    )
    self.enable_network = NilValue.value_or_default(
      self.enable_network,
      Config::ENABLE_NETWORK
    )
  end
end
