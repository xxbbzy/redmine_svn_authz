# frozen_string_literal: true

require File.expand_path('../../../test/test_helper', __dir__)
require 'open3'
require 'tmpdir'

module SvnAuthzTestHelper
  REPO_DIR = File.join(Dir.tmpdir, "redmine_svn_authz_test_repo_#{Process.pid}")

  # Layout of the test repository (author in parentheses):
  #   r1 (jsmith)  add /trunk/dirA/a.c
  #   r2 (dlopper) add /trunk/dirB/b.c
  #   r3 (jsmith)  modify /trunk/dirA/a.c and /trunk/dirB/b.c
  #   r4 (admin)   add /trunk/dirA/secret/s.c
  def self.repository_url
    @repository_url ||= begin
      FileUtils.rm_rf(REPO_DIR)
      wc = "#{REPO_DIR}-wc"
      url = "file://#{REPO_DIR}"
      run('svnadmin', 'create', REPO_DIR)
      run('svn', 'checkout', '-q', url, wc)
      commit(wc, 'jsmith', 'add dirA') do
        FileUtils.mkdir_p("#{wc}/trunk/dirA")
        File.write("#{wc}/trunk/dirA/a.c", "alpha\n")
        run('svn', 'add', '-q', "#{wc}/trunk")
      end
      commit(wc, 'dlopper', 'add dirB') do
        FileUtils.mkdir_p("#{wc}/trunk/dirB")
        File.write("#{wc}/trunk/dirB/b.c", "bravo\n")
        run('svn', 'add', '-q', "#{wc}/trunk/dirB")
      end
      commit(wc, 'jsmith', 'touch both') do
        File.write("#{wc}/trunk/dirA/a.c", "alpha changed in r3\n")
        File.write("#{wc}/trunk/dirB/b.c", "bravo changed in r3\n")
      end
      commit(wc, 'admin', 'add secret') do
        FileUtils.mkdir_p("#{wc}/trunk/dirA/secret")
        File.write("#{wc}/trunk/dirA/secret/s.c", "top secret\n")
        run('svn', 'add', '-q', "#{wc}/trunk/dirA/secret")
      end
      FileUtils.rm_rf(wc)
      "#{url}/trunk"
    end
  end

  SPARSE_REPO_DIR = "#{REPO_DIR}_sparse"

  # Sparse checkout layout (URL = repository root):
  #   r1 (admin)   /trunk/README, /trunk/src/Makefile, /trunk/include/README,
  #                /branches/b1/readme
  #   r2 (jsmith)  /trunk/src/module_a/app.c, /trunk/include/module_a/a.h
  #   r3 (dlopper) /trunk/src/module_b/b.c, /trunk/src/module_b_ext/ext.c, /trunk/include/module_b/b.h
  #   r4 (admin)   modify app.c and b.c
  #   r5 (admin)   modify /trunk/src/Makefile
  def self.sparse_repository_url
    @sparse_repository_url ||= begin
      FileUtils.rm_rf(SPARSE_REPO_DIR)
      run('svnadmin', 'create', SPARSE_REPO_DIR)
      url = "file://#{SPARSE_REPO_DIR}"
      with_working_copy(url) do |wc|
        write_and_commit(wc, 'admin', 'layout',
                         'trunk/README' => "readme\n", 'trunk/src/Makefile' => "all:\n",
                         'trunk/include/README' => "headers\n", 'branches/b1/readme' => "branch\n")
        write_and_commit(wc, 'jsmith', 'add module_a',
                         'trunk/src/module_a/app.c' => "module_a v1\n",
                         'trunk/include/module_a/a.h' => "module_a header\n")
        write_and_commit(wc, 'dlopper', 'add module_b',
                         'trunk/src/module_b/b.c' => "module_b v1\n", 'trunk/src/module_b_ext/ext.c' => "gen\n",
                         'trunk/include/module_b/b.h' => "module_b header\n")
        write_and_commit(wc, 'admin', 'touch both modules',
                         'trunk/src/module_a/app.c' => "module_a v2\n", 'trunk/src/module_b/b.c' => "module_b v2\n")
        write_and_commit(wc, 'admin', 'build only', 'trunk/src/Makefile' => "all: app\n")
      end
      url
    end
  end

  # A private copy of the sparse repository, for tests that add commits
  def self.copy_sparse_repository(dir)
    sparse_repository_url
    FileUtils.cp_r("#{SPARSE_REPO_DIR}/.", dir)
    "file://#{dir}"
  end

  def self.commit_files(url, user, message, files)
    with_working_copy(url) { |wc| write_and_commit(wc, user, message, files) }
  end

  def self.with_working_copy(url)
    wc = Dir.mktmpdir('svn_authz_wc')
    run('svn', 'checkout', '-q', url, wc)
    yield wc
  ensure
    FileUtils.rm_rf(wc)
  end

  def self.write_and_commit(wc, user, message, files)
    files.each do |path, content|
      FileUtils.mkdir_p(File.dirname("#{wc}/#{path}"))
      File.write("#{wc}/#{path}", content)
    end
    run('svn', 'add', '-q', '--force', wc)
    run('svn', 'commit', '-q', '-m', message, '--username', user, wc)
  end

  def self.commit(wc, user, message)
    yield
    run('svn', 'commit', '-q', '-m', message, '--username', user, wc)
  end

  def self.run(*cmd)
    out, status = Open3.capture2e(*cmd)
    raise "#{cmd.join(' ')} failed: #{out}" unless status.success?

    out
  end

  AUTHZ = <<~AUTHZ
    [groups]
    team-a = jsmith

    [/trunk/dirA]
    @team-a = r

    [/trunk/dirA/secret]
    @team-a =

    [/trunk/dirB]
    dlopper = rw
  AUTHZ

  # Subversion repository "authz" on project 1 (ecookbook) with rules enabled
  def create_authz_repository(authz = AUTHZ)
    repository = Repository::Subversion.create!(
      :project => Project.find(1), :identifier => 'authz', :url => SvnAuthzTestHelper.repository_url
    )
    repository.fetch_changesets
    SvnAuthzConfig.create!(:repository => repository, :enabled => true, :source => 'managed',
                           :authz_content => authz)
    RedmineSvnAuthz::PolicyStore.clear
    repository.reload
  end

  # The sparse checkout example: jsmith is in @team_a, dlopper in @team_b
  SPARSE_AUTHZ = <<~AUTHZ
    [groups]
    team_a = jsmith
    team_b = dlopper

    # Parents of the modules are readable (sparse checkouts)
    [/trunk]
    @team_a = r
    @team_b = r
    [/trunk/src]
    @team_a = r
    @team_b = r
    [/trunk/include]
    @team_a = r
    @team_b = r

    # No module is readable by default
    [:glob:/trunk/src/*]
    @team_a =
    @team_b =
    [:glob:/trunk/include/*]
    @team_a =
    @team_b =

    # team_a modules
    [/trunk/src/module_a]
    @team_a = rw

    [/trunk/include/module_a]
    @team_a = rw

    # team_b modules
    [/trunk/src/module_b]
    @team_b = rw

    [/trunk/src/module_b_ext]
    @team_b = rw

    [/trunk/include/module_b]
    @team_b = rw

    [/trunk/include/module_b_ext]
    @team_b = rw
  AUTHZ

  def create_sparse_repository(identifier: 'sparse', url: SvnAuthzTestHelper.sparse_repository_url)
    repository = Repository::Subversion.create!(:project => Project.find(1), :identifier => identifier, :url => url)
    repository.fetch_changesets
    SvnAuthzConfig.create!(:repository => repository, :enabled => true, :source => 'managed',
                           :authz_content => SPARSE_AUTHZ)
    RedmineSvnAuthz::PolicyStore.clear
    repository.reload
  end

  def revision_ids(repository, *revisions)
    repository.changesets.where(:revision => revisions.map(&:to_s)).pluck(:id).sort
  end
end

Minitest.after_run do
  FileUtils.rm_rf(SvnAuthzTestHelper::REPO_DIR)
  FileUtils.rm_rf(SvnAuthzTestHelper::SPARSE_REPO_DIR)
end
