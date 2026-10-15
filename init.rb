# frozen_string_literal: true

# Redmine SVN Authz - directory-level permissions for Subversion repositories
# Copyright (C) 2026 xxbbzy
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation; either version 2 of the License, or (at your option)
# any later version. See the LICENSE file for details.

Redmine::Plugin.register :redmine_svn_authz do
  name 'Redmine SVN Authz'
  author 'xxbbzy'
  description 'Directory-level read permissions for Subversion repositories, using svn authz rules'
  version '0.1.0'
  url 'https://github.com/xxbbzy/redmine_svn_authz'
  author_url 'https://github.com/xxbbzy'
  requires_redmine :version_or_higher => '5.0.0'

  settings :default => { 'allowed_directories' => '' },
           :partial => 'settings/svn_authz_settings'

  project_module :repository do
    permission :manage_svn_authz, { :svn_authz_configs => [:edit, :update, :download, :import] },
               :require => :member
    permission :bypass_svn_authz, {}, :require => :member
  end
end

RedmineSvnAuthz.apply_patches
RedmineSvnAuthz::Hooks # registers the view hooks
