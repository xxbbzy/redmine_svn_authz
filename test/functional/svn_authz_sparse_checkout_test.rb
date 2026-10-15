# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# The sparse checkout authz example: parent directories are readable, every
# module is denied by [:glob:/trunk/src/*] / [:glob:/trunk/include/*], and
# each group gets its own modules back.
class SvnAuthzSparseCheckoutTest < Redmine::ControllerTest
  tests RepositoriesController
  include SvnAuthzTestHelper

  fixtures :projects, :users, :email_addresses, :user_preferences, :roles, :members, :member_roles,
           :enabled_modules, :repositories, :changesets, :changes, :trackers, :projects_trackers,
           :issue_statuses, :issues

  TEAM_A = 2 # jsmith
  TEAM_B = 3 # dlopper

  def setup
    User.current = nil
    @repository = create_sparse_repository
  end

  def get_repo(action, user, path: nil, **params)
    @request.session[:user_id] = user
    params = params.merge(:id => 'ecookbook', :repository_id => 'sparse')
    params[:path] = path if path
    get action, :params => params
  end

  def listed(user, path = nil)
    get_repo :show, user, :path => path
    assert_response :success
    css_select('tr.entry td.filename a').map { |a| a.text.strip }.reject(&:empty?).sort
  end

  def test_directory_listings
    assert_equal %w(trunk), listed(TEAM_A)
    assert_equal %w(README include src), listed(TEAM_A, 'trunk')
    assert_equal %w(module_a), listed(TEAM_A, 'trunk/src')
    assert_equal %w(module_a), listed(TEAM_A, 'trunk/include')
    assert_equal %w(module_b module_b_ext), listed(TEAM_B, 'trunk/src')
    assert_equal %w(module_b), listed(TEAM_B, 'trunk/include')
  end

  def test_file_access
    {
      'trunk/README' => [200, 200],
      'trunk/src/Makefile' => [403, 403],
      'trunk/src/module_a/app.c' => [200, 403],
      'trunk/include/module_a/a.h' => [200, 403],
      'trunk/src/module_b/b.c' => [403, 200],
      'trunk/src/module_b_ext/ext.c' => [403, 200],
      'trunk/include/module_b/b.h' => [403, 200],
      'branches/b1/readme' => [403, 403]
    }.each do |path, (team_a, team_b)|
      get_repo :entry, TEAM_A, :path => path
      assert_response team_a, "team_a #{path}"
      get_repo :entry, TEAM_B, :path => path
      assert_response team_b, "team_b #{path}"
    end
  end

  def test_other_modules_cannot_be_browsed
    get_repo :show, TEAM_A, :path => 'trunk/src/module_b'
    assert_response 403
    get_repo :show, TEAM_B, :path => 'trunk/src/module_a'
    assert_response 403
  end

  def test_revisions
    get_repo :revisions, TEAM_A
    assert_equal revision_ids(@repository, 1, 2, 4), @controller.instance_variable_get(:@changesets).map(&:id).sort
    get_repo :revisions, TEAM_B
    assert_equal revision_ids(@repository, 1, 3, 4), @controller.instance_variable_get(:@changesets).map(&:id).sort
    get_repo :revision, TEAM_A, :rev => 3
    assert_response 403
    get_repo :revision, TEAM_A, :rev => 5
    assert_response 403
  end

  def test_mixed_revision_is_filtered
    get_repo :revision, TEAM_A, :rev => 4
    assert_response :success
    assert_includes response.body, 'app.c'
    assert_not_includes response.body, 'b.c'

    get_repo :diff, TEAM_A, :rev => 4, :format => 'diff'
    assert_includes response.body, 'module_a v2'
    assert_not_includes response.body, 'module_b v2'
    get_repo :diff, TEAM_B, :rev => 4, :format => 'diff'
    assert_includes response.body, 'module_b v2'
    assert_not_includes response.body, 'module_a v2'
  end

  def test_visible_changesets_follow_new_commits
    dir = Dir.mktmpdir('svn_authz_sparse_copy')
    url = SvnAuthzTestHelper.copy_sparse_repository(dir)
    repository = create_sparse_repository(:identifier => 'sparse-copy', :url => url)
    jsmith = User.find(TEAM_A)
    visible = -> { Changeset.visible(jsmith).where(:repository_id => repository.id).pluck(:revision).sort }
    assert_equal %w(1 2 4), visible.call
    assert_equal 1, SvnAuthzVisibilitySet.where(:repository_id => repository.id).count

    SvnAuthzTestHelper.commit_files(url, 'dlopper', 'module_b only', 'trunk/src/module_b/b.c' => "module_b v3\n")
    SvnAuthzTestHelper.commit_files(url, 'jsmith', 'module_a only', 'trunk/src/module_a/app.c' => "module_a v3\n")
    repository.fetch_changesets
    assert_equal %w(1 2 4 7), visible.call
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  def test_saving_the_rules_drops_precomputed_visibility
    Changeset.visible(User.find(TEAM_A)).to_a
    assert SvnAuthzVisibilitySet.where(:repository_id => @repository.id).exists?
    @repository.svn_authz_config.update!(:authz_content => SPARSE_AUTHZ + "\n[/branches]\n@team_a = r\n")
    assert_not SvnAuthzVisibilitySet.where(:repository_id => @repository.id).exists?
    assert_includes Changeset.visible(User.find(TEAM_A)).where(:repository_id => @repository.id).
      pluck(:revision), '1'
  end

  def test_activity_and_search
    events = Redmine::Activity::Fetcher.new(User.find(TEAM_B), :project => Project.find(1)).
      events(nil, nil).select { |e| e.is_a?(Changeset) && e.repository_id == @repository.id }
    assert_equal %w(1 3 4), events.map(&:revision).sort
    results = Changeset.search_results(%w(module), User.find(TEAM_A), [Project.find(1)])
    assert_equal %w(2 4), results.select { |c| c.repository_id == @repository.id }.map(&:revision).sort
  end
end
