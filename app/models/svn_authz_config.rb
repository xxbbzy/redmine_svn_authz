# frozen_string_literal: true

class SvnAuthzConfig < ActiveRecord::Base
  SOURCES = %w(managed file).freeze
  MAX_REPORTED_ERRORS = 10

  belongs_to :repository

  scope :enabled, -> { where(:enabled => true) }

  validates :repository_id, :presence => true, :uniqueness => true
  validates :source, :inclusion => { :in => SOURCES }
  validates :authz_repo_name, :format => { :with => /\A[^\s:\[\]]*\z/ }
  validates :path_prefix_override, :format => { :with => %r{\A(/[^\[\]]*)?\z} }
  validate :validate_repository_type, :validate_rules, :validate_export_path

  after_save do
    RedmineSvnAuthz::PolicyStore.clear
    SvnAuthzVisibilitySet.purge(repository_id)
  end

  def file_source?
    source == 'file'
  end

  # The authz text currently in effect.
  def authz_text
    file_source? ? File.read(authz_file_path) : authz_content.to_s
  end

  def parsed_policy
    RedmineSvnAuthz::Parser.parse(authz_text)
  rescue SystemCallError
    nil
  end

  # Name used to match [repo:/path] sections.
  def repo_name
    authz_repo_name.presence || default_repo_name
  end

  def default_repo_name
    root = repository.root_url.presence || safe_scm_root_url || repository.url
    File.basename(root.to_s.chomp('/'))
  end

  # Path of the repository URL inside the svn repository, e.g. "/trunk".
  def path_prefix
    path_prefix_override.presence || default_path_prefix
  end

  def default_path_prefix
    root = repository.root_url.presence || safe_scm_root_url
    url = repository.url.to_s
    return '/' if root.blank? || !url.downcase.start_with?(root.downcase)

    RedmineSvnAuthz::Parser.normalize_path(url[root.length..-1])
  end

  # Writes the managed rules to export_path (atomically) for use by the svn
  # server. Returns false and adds an error if the file cannot be written.
  def export!
    return true unless !file_source? && export_path.present?

    tmp = "#{export_path}.#{Process.pid}.tmp"
    File.write(tmp, authz_content.to_s)
    File.rename(tmp, export_path)
    true
  rescue SystemCallError => e
    FileUtils.rm_f(tmp) if tmp
    errors.add(:export_path, e.message)
    false
  end

  private

  def safe_scm_root_url
    repository.scm.root_url
  rescue StandardError
    nil
  end

  def validate_repository_type
    errors.add(:repository, :invalid) unless repository.is_a?(Repository::Subversion)
  end

  def validate_rules
    if file_source?
      unless RedmineSvnAuthz.path_allowed?(authz_file_path)
        errors.add(:authz_file_path, :svn_authz_path_not_allowed)
        return
      end
      unless File.file?(authz_file_path) && File.readable?(authz_file_path)
        errors.add(:authz_file_path, :svn_authz_file_not_readable)
        return
      end
    end
    policy = parsed_policy
    return unless policy

    policy.errors.first(MAX_REPORTED_ERRORS).each do |issue|
      errors.add(:base, "#{self.class.human_attribute_name(:authz_content)}: #{issue}")
    end
  end

  def validate_export_path
    return if export_path.blank? || file_source?

    errors.add(:export_path, :svn_authz_path_not_allowed) unless RedmineSvnAuthz.path_allowed?(export_path)
  end
end
