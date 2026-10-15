# frozen_string_literal: true

module RedmineSvnAuthz
  class << self
    def apply_patches
      patch(::RepositoriesController, Patches::RepositoriesControllerPatch)
      patch(::Repository, Patches::RepositoryPatch)
      patch(::Repository::Subversion, Patches::RepositorySubversionPatch)
      patch(::Changeset, Patches::ChangesetPatch)
      patch(::Changeset.singleton_class, Patches::ChangesetPatch::ClassMethods)
    end

    # SQL condition restricting a Changeset scope to what +user+ may see across
    # all repositories, or nil if no repository has authz enabled.
    def changeset_visibility_condition(user)
      configs = SvnAuthzConfig.enabled.preload(:repository => :project).to_a
      configs.select! { |c| c.repository.is_a?(Repository::Subversion) }
      return nil if configs.empty?

      table = Changeset.table_name
      clauses = ["#{table}.repository_id NOT IN (#{configs.map(&:repository_id).join(',')})"]
      configs.each do |config|
        resolver = AccessResolver.for(config.repository, user)
        condition = resolver ? " AND #{resolver.changeset_condition(table)}" : ''
        clauses << "(#{table}.repository_id = #{config.repository_id.to_i}#{condition})"
      end
      "(#{clauses.join(' OR ')})"
    end

    # Directories the authz file may be read from / exported to.
    def allowed_directories
      Setting.plugin_redmine_svn_authz['allowed_directories'].to_s.split(/[\r\n]+/).map(&:strip).reject(&:empty?)
    end

    def path_allowed?(path)
      return false if path.blank? || !path.start_with?('/')

      real = resolve_path(path)
      return false unless real

      allowed_directories.any? do |dir|
        base = resolve_path(dir) or next false
        real.start_with?(base.end_with?('/') ? base : "#{base}/")
      end
    end

    private

    # Absolute path with symlinks resolved; the file itself may not exist yet
    # (export target), but its directory must.
    def resolve_path(path)
      File.realpath(path)
    rescue SystemCallError
      begin
        File.join(File.realpath(File.dirname(path)), File.basename(path))
      rescue SystemCallError
        nil
      end
    end

    def patch(target, mod)
      target.prepend(mod) unless target.ancestors.include?(mod)
    end
  end
end
