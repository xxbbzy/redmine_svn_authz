# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class SvnAuthzChangesetVisibilityTest < ActiveSupport::TestCase
  include SvnAuthzTestHelper

  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :repositories, :changesets, :changes, :issues, :trackers,
           :projects_trackers, :issue_statuses

  def setup
    User.current = nil
    @repository = create_authz_repository
    @jsmith = User.find(2)
  end

  def test_path_prefix_is_detected_from_the_root_url
    assert_equal '/trunk', @repository.svn_authz_config.path_prefix
  end

  def test_visible_scope
    ids = Changeset.visible(@jsmith).where(:repository_id => @repository.id).pluck(:id).sort
    assert_equal revision_ids(@repository, 1, 3), ids
  end

  def test_other_repositories_are_unaffected
    other = Changeset.where.not(:repository_id => @repository.id)
    assert_equal Changeset.visible(@jsmith).merge(other).count,
                 Changeset.where(:id => other.select(:id)).visible(@jsmith).count
    assert Changeset.visible(@jsmith).where(:repository_id => 10).exists?
  end

  def test_visible_predicate
    assert @repository.changesets.find_by(:revision => '3').visible?(@jsmith)
    assert_not @repository.changesets.find_by(:revision => '2').visible?(@jsmith)
    assert @repository.changesets.find_by(:revision => '2').visible?(User.find(1))
  end

  def test_activity
    events = Redmine::Activity::Fetcher.new(@jsmith, :project => Project.find(1)).
      events(nil, nil).select { |e| e.is_a?(Changeset) && e.repository_id == @repository.id }
    assert_equal revision_ids(@repository, 1, 3), events.map(&:id).sort
  end

  def test_search
    results = Changeset.search_results(%w(dirB), @jsmith, [Project.find(1)])
    assert_empty results.select { |c| c.repository_id == @repository.id }
    results = Changeset.search_results(%w(dirB), User.find(3), [Project.find(1)])
    assert_equal revision_ids(@repository, 2), results.map(&:id)
  end

  def test_issue_associated_revisions
    issue = Issue.find(1)
    issue.changesets << @repository.changesets.find_by(:revision => '2')
    assert_not_includes issue.changesets.visible(@jsmith).map(&:revision), '2'
  end
end
