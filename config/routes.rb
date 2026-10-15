# frozen_string_literal: true

scope 'repositories/:repository_id/svn_authz', :controller => 'svn_authz_configs' do
  get '', :action => 'edit', :as => 'edit_repository_svn_authz'
  match '', :action => 'update', :via => [:patch, :put], :as => 'repository_svn_authz'
  get 'download', :action => 'download', :as => 'download_repository_svn_authz'
  post 'import', :action => 'import', :as => 'import_repository_svn_authz'
end
