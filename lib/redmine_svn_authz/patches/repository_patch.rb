# frozen_string_literal: true

module RedmineSvnAuthz
  module Patches
    module RepositoryPatch
      def self.prepended(base)
        base.has_one :svn_authz_config, :dependent => :delete
        base.before_destroy { SvnAuthzVisibilitySet.purge(id) }
      end
    end
  end
end
