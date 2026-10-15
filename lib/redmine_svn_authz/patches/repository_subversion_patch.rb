# frozen_string_literal: true

module RedmineSvnAuthz
  module Patches
    # Filters repository content for the current user. Every method falls back
    # to stock behaviour when AccessResolver.for returns nil (unrestricted).
    module RepositorySubversionPatch
      def entries(path = nil, identifier = nil)
        entries = super
        resolver = svn_authz_resolver
        return entries unless entries && resolver
        return nil unless resolver.traversable?(path.to_s)

        entries.select! { |entry| resolver.traversable?(entry.path) }
        entries.each do |entry|
          next if resolver.readable?(entry.path)

          # Only shown as a way to reach readable content below it: hide the
          # last revision, which may belong to an unreadable sibling.
          entry.lastrev = nil
          entry.changeset = nil
          entry.size = nil
        end
        entries
      end

      def entry(path = nil, identifier = nil)
        resolver = svn_authz_resolver
        return nil if resolver && !resolver.traversable?(path.to_s)

        super
      end

      def cat(path, identifier = nil)
        resolver = svn_authz_resolver
        return nil if resolver && !resolver.readable?(path.to_s)

        super
      end

      def properties(path, identifier = nil)
        resolver = svn_authz_resolver
        return nil if resolver && !resolver.readable?(path.to_s)

        super
      end

      def latest_changesets(path, rev, limit = 10)
        changesets = super
        resolver = svn_authz_resolver
        return changesets unless resolver && changesets.any?

        visible_ids = Changeset.where(:id => changesets.map(&:id)).
          where(resolver.changeset_condition).pluck(:id)
        changesets.select { |c| visible_ids.include?(c.id) }
      end

      def diff(path, rev, rev_to)
        resolver = svn_authz_resolver
        return super unless resolver
        return nil unless resolver.traversable?(path.to_s)

        diff = super
        return diff if diff.nil? || resolver.fully_readable?(path.to_s)

        RedmineSvnAuthz::DiffFilter.filter(diff, path.to_s) { |p| resolver.readable?(p) }
      end

      def svn_authz_resolver
        RedmineSvnAuthz::AccessResolver.for(self)
      end
    end
  end
end
