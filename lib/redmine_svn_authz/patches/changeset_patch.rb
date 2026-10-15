# frozen_string_literal: true

module RedmineSvnAuthz
  module Patches
    # Changeset.visible is what issues ("Associated revisions"), the activity
    # provider and search use, so restricting it covers all of them.
    module ChangesetPatch
      module ClassMethods
        def visible(*args)
          scope = super
          user = args.first.is_a?(User) ? args.first : User.current
          condition = RedmineSvnAuthz.changeset_visibility_condition(user)
          condition ? scope.where(condition) : scope
        end
      end

      def visible?(user = User.current)
        allowed = defined?(super) ? super : user.allowed_to?(:view_changesets, repository&.project)
        return false unless allowed

        resolver = RedmineSvnAuthz::AccessResolver.for(repository, user)
        resolver.nil? || resolver.changeset_visible?(self)
      end
    end
  end
end
