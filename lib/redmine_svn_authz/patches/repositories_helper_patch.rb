# frozen_string_literal: true

module RedmineSvnAuthz
  module Patches
    module RepositoriesHelperPatch
      # Wraps @changeset so that the file tree on the revision page only lists
      # changes to readable paths.
      class FilteredChangeset < SimpleDelegator
        def initialize(changeset, resolver)
          super(changeset)
          @resolver = resolver
        end

        def filechanges
          __getobj__.filechanges.where(:id => @resolver.readable_change_ids(__getobj__))
        end
      end

      def render_changeset_changes
        resolver = @changeset && RedmineSvnAuthz::AccessResolver.for(@changeset.repository)
        return super unless resolver

        original = @changeset
        begin
          @changeset = FilteredChangeset.new(original, resolver)
          super
        ensure
          @changeset = original
        end
      end
    end
  end
end
