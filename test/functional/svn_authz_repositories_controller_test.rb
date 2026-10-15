# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class SvnAuthzRepositoriesControllerTest < Redmine::ControllerTest
  tests RepositoriesController
  include SvnAuthzTestHelper

  fixtures :projects, :users, :email_addresses, :user_preferences, :roles, :members, :member_roles,
           :enabled_modules, :repositories, :changesets, :changes, :trackers, :projects_trackers,
           :issue_statuses, :issues

  def setup
    User.current = nil
    @repository = create_authz_repository
  end

  def get_repo(action, path: nil, user: 2, **params)
    @request.session[:user_id] = user
    params = params.merge(:id => 'ecookbook', :repository_id => 'authz')
    params[:path] = path if path
    get action, :params => params
  end

  def assigned(name)
    @controller.instance_variable_get(:"@#{name}")
  end

  def test_root_lists_only_traversable_directories
    get_repo :show
    assert_response :success
    assert_select 'tr.dir a', :text => 'dirA'
    assert_select 'tr.dir a', :text => 'dirB', :count => 0
  end

  def test_denied_subdirectory_is_hidden
    get_repo :show, :path => 'dirA'
    assert_response :success
    assert_select 'tr.file a', :text => 'a.c'
    assert_select 'tr.dir a', :text => 'secret', :count => 0
  end

  def test_other_users_directory_is_forbidden
    get_repo :show, :path => 'dirB'
    assert_response 403
    get_repo :entry, :path => 'dirB/b.c'
    assert_response 403
    get_repo :raw, :path => 'dirB/b.c'
    assert_response 403
    get_repo :annotate, :path => 'dirB/b.c'
    assert_response 403
    get_repo :entry, :path => 'dirA/secret/s.c'
    assert_response 403
  end

  def test_readable_file
    get_repo :entry, :path => 'dirA/a.c'
    assert_response :success
    get_repo :raw, :path => 'dirA/a.c'
    assert_response :success
    assert_equal "alpha changed in r3\n", response.body
  end

  def test_revisions_only_lists_visible_changesets
    get_repo :revisions
    assert_response :success
    assert_equal revision_ids(@repository, 1, 3), assigned(:changesets).map(&:id).sort
    assert_equal 2, assigned(:changeset_count)
  end

  def test_revision_without_readable_changes_is_forbidden
    get_repo :revision, :rev => 2
    assert_response 403
    get_repo :revision, :rev => 4
    assert_response 403
  end

  def test_revision_page_lists_only_readable_changes
    get_repo :revision, :rev => 3
    assert_response :success
    assert_includes response.body, 'a.c'
    assert_not_includes response.body, 'b.c'
  end

  def test_diff_of_mixed_revision_is_filtered
    get_repo :diff, :rev => 3, :format => 'diff'
    assert_response :success
    assert_includes response.body, 'alpha changed in r3'
    assert_not_includes response.body, 'bravo'
  end

  def test_html_diff_is_not_shared_through_the_fragment_cache
    store = RepositoriesController.cache_store
    RepositoriesController.cache_store = ActiveSupport::Cache::MemoryStore.new
    RepositoriesController.perform_caching = true
    get_repo :diff, :rev => 3, :user => 1
    assert_includes response.body, 'bravo'
    get_repo :diff, :rev => 3
    assert_not_includes response.body, 'bravo'
  ensure
    RepositoriesController.perform_caching = false
    RepositoriesController.cache_store = store
  end

  def test_statistics_are_forbidden
    get_repo :stats
    assert_response 403
  end

  def test_other_user_sees_the_other_directory
    get_repo :show, :user => 3
    assert_response :success
    assert_select 'tr.dir a', :text => 'dirB'
    assert_select 'tr.dir a', :text => 'dirA', :count => 0
  end

  def test_admin_is_not_restricted
    get_repo :show, :path => 'dirA', :user => 1
    assert_select 'tr.dir a', :text => 'secret'
    get_repo :revisions, :user => 1
    assert_equal 4, assigned(:changeset_count)
  end

  def test_bypass_permission
    Role.find(1).add_permission! :bypass_svn_authz
    get_repo :show, :path => 'dirB'
    assert_response :success
  end

  def test_disabled_config_restores_stock_behaviour
    @repository.svn_authz_config.update!(:enabled => false)
    get_repo :show, :path => 'dirB'
    assert_response :success
  end

  def test_unreadable_rules_deny_everything
    @repository.svn_authz_config.update_columns(:source => 'file', :authz_file_path => '/nonexistent/authz')
    get_repo :show
    assert_response 403
  end
end
