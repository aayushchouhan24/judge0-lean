# Languages are static data (db/languages/*.rb) kept in memory, not in a database.
class Language
  include ActiveModel::Model
  include ActiveModel::Serialization

  ATTRIBUTES = %i[id name is_archived source_file compile_cmd run_cmd].freeze
  attr_accessor(*ATTRIBUTES)

  # Array with the few query helpers the app uses.
  class Scope < Array
    def find_by(id:)
      detect { |l| l.id == id.to_i } if id.present?
    end

    def find(id)
      find_by(id: id) || raise(RecordNotFound, "Couldn't find Language with 'id'=#{id}")
    end

    def order(name: :asc)
      Scope.new(sort_by(&:name).tap { |s| s.reverse! if name.to_s == "desc" })
    end

    def pluck(*columns)
      collect { |l| columns.size == 1 ? l.public_send(columns.first) : columns.collect { |c| l.public_send(c) } }
    end
  end

  def self.records
    @records ||= begin
      # The data files append to @languages; evaluate them here so it is this class's ivar.
      @languages = nil
      %w[archived active].each do |file|
        path = Rails.root.join("db", "languages", "#{file}.rb").to_s
        instance_eval(File.read(path), path)
      end
      data = @languages
      # ENABLED_LANGUAGE_IDS="71,89" keeps only those languages.
      enabled = ENV["ENABLED_LANGUAGE_IDS"].to_s.split(",").collect(&:strip).reject(&:empty?).collect(&:to_i)
      data = data.select { |l| enabled.include?(l[:id]) } if enabled.any?
      Scope.new(data.collect { |l| new(l.slice(*ATTRIBUTES)) }).freeze
    end
  end

  # Active (non-archived) languages ordered by name, like the old default scope.
  def self.all
    Scope.new(records.reject(&:is_archived)).order(name: :asc)
  end

  # Every language, archived included.
  def self.unscoped
    Scope.new(records)
  end

  def self.find_by(id:)
    all.find_by(id: id)
  end

  def is_archived
    @is_archived == true
  end

  def attributes
    ATTRIBUTES.index_with { |a| public_send(a) }.stringify_keys
  end

  def is_project
    name == "Multi-file program"
  end
end
