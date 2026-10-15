# frozen_string_literal: true

module RedmineSvnAuthz
  module Patches
    module RepositoriesControllerPatch
      CHECKED_ACTIONS = [
        :show, :browse, :changes, :entry, :raw, :annotate, :diff,
        :revision, :add_related_issue, :remove_related_issue, :stats, :graph
      ].freeze

      def self.prepended(base)
        base.before_action :svn_authz_check_access, :only => CHECKED_ACTIONS
        # Included after RepositoriesHelper, so its methods take precedence
        base.helper RepositoriesHelperPatch
        # Diffs are fragment-cached by path/revision only; make sure users with
        # different rules never share a cached (filtered) diff.
        base.fragment_cache_key { svn_authz_resolver&.cache_key || 'svn_authz/unrestricted' }
      end

      def revisions
        resolver = svn_authz_resolver
        return super unless resolver

        scope = @repository.changesets.where(resolver.changeset_condition)
        @changeset_count = scope.count
        @changeset_pages = Redmine::Pagination::Paginator.new @changeset_count, per_page_option, params['page']
        @changesets = scope.
          limit(@changeset_pages.per_page).
          offset(@changeset_pages.offset).
          includes(:user, :repository, :parents).
          to_a

        respond_to do |format|
          format.html { render :layout => false if request.xhr? }
          format.atom { render_feed(@changesets, :title => "#{@project.name}: #{l(:label_revision_plural)}") }
        end
      end

      private

      def svn_authz_resolver
        return nil unless @repository

        RedmineSvnAuthz::AccessResolver.for(@repository)
      end

      def svn_authz_check_access
        resolver = svn_authz_resolver
        return true unless resolver

        allowed =
          case action_name
          when 'stats', 'graph'
            # Statistics cover the whole repository
            false
          when 'entry', 'raw', 'annotate'
            resolver.readable?(@path)
          when 'revision', 'add_related_issue', 'remove_related_issue'
            resolver.changeset_visible?(@changeset)
          else
            # Directories that are only traversable can be browsed; diff
            # content is filtered per file by the repository patch.
            resolver.traversable?(@path)
          end
        deny_access unless allowed
      end
    end
  end
end
