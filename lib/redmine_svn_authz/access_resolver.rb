# frozen_string_literal: true

module RedmineSvnAuthz
  # Read-access decisions of one Redmine user on one Subversion repository.
  #
  # AccessResolver.for returns nil when the user is not restricted (plugin not
  # enabled for the repository, administrator, or :bypass_svn_authz), so
  # callers can simply fall back to stock Redmine behaviour.
  #
  # "Browse paths" are relative to the repository URL, as used by
  # RepositoriesController and Repository#entries. "Repository paths" are
  # absolute from the svn repository root, as stored in changes.path and used
  # in authz sections.
  class AccessResolver
    CHANGE_ALIAS = 'svn_authz_changes'

    def self.for(repository, user = User.current)
      return nil unless repository.is_a?(Repository::Subversion)

      config = repository.svn_authz_config
      return nil unless config&.enabled?
      return nil if user.admin? || user.allowed_to?(:bypass_svn_authz, repository.project)

      cache = (repository.instance_variable_get(:@svn_authz_resolvers) ||
               repository.instance_variable_set(:@svn_authz_resolvers, {}))
      policy = PolicyStore.policy_for(config)
      key = [user.id, policy.object_id]
      cache[key] ||= new(config, policy, user)
    end

    attr_reader :config, :user, :rules

    # A nil +policy+ (rules missing or invalid) denies everything.
    def initialize(config, policy, user)
      @config = config
      @user = user
      @prefix = Parser.normalize_path(config.path_prefix)
      login = user.anonymous? ? nil : user.login
      @rules = policy ? policy.user_rules(login, :repo => config.repo_name) : UserRules.new([])
    end

    def to_repository_path(browse_path)
      Parser.normalize_path("#{@prefix}/#{browse_path}")
    end

    def readable?(browse_path)
      @rules.readable?(to_repository_path(browse_path))
    end

    def traversable?(browse_path)
      @rules.traversable?(to_repository_path(browse_path))
    end

    def fully_readable?(browse_path)
      @rules.fully_readable?(to_repository_path(browse_path))
    end

    def readable_repository_path?(path)
      @rules.readable?(path)
    end

    # SQL condition true for changesets that touch at least one readable path.
    def changeset_condition(changeset_table = Changeset.table_name)
      return '1=1' if @rules.everything_readable?
      return '1=0' if @rules.nothing_readable?

      if @rules.literal?
        # Readability only depends on path prefixes: check them directly
        matcher = PathMatcher.new(@rules.decision_points)
        condition = matcher.sql_condition("#{CHANGE_ALIAS}.path", ActiveRecord::Base.connection.method(:quote))
        "EXISTS (SELECT 1 FROM #{Change.table_name} #{CHANGE_ALIAS}" \
          " WHERE #{CHANGE_ALIAS}.changeset_id = #{changeset_table}.id AND #{condition})"
      else
        # Wildcard rules cannot be expressed portably in SQL: use the
        # precomputed list of visible changesets for these rules.
        @visibility_set ||= SvnAuthzVisibilitySet.synced(@config.repository, @rules)
        "EXISTS (SELECT 1 FROM #{SvnAuthzVisibleChangeset.table_name} svn_authz_visible" \
          " WHERE svn_authz_visible.visibility_set_id = #{@visibility_set.id.to_i}" \
          " AND svn_authz_visible.changeset_id = #{changeset_table}.id)"
      end
    end

    def changeset_visible?(changeset)
      changeset.filechanges.pluck(:path).any? { |path| @rules.readable?(path) }
    end

    # Ids of the changeset's changes to readable paths.
    def readable_change_ids(changeset)
      changeset.filechanges.pluck(:id, :path).select { |_, path| @rules.readable?(path) }.map(&:first)
    end

    # Identifies the user's effective rules; used to scope cached fragments.
    def cache_key
      "svn_authz/#{@config.repository_id}/#{@rules.digest[0, 16]}"
    end
  end
end
