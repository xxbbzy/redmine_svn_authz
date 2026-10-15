# frozen_string_literal: true

# Demo data: bin/rails runner plugins/redmine_svn_authz/docker/seed_demo.rb
# Creates /var/svn/demo with /trunk/dirA and /trunk/dirB, users alice and bob
# (password: password123) and a "demo" project whose repository uses authz
# rules giving alice /trunk/dirA and bob /trunk/dirB.
require 'open3'

def sh(*cmd)
  out, status = Open3.capture2e(*cmd)
  raise "#{cmd.join(' ')}: #{out}" unless status.success?
end

repo_dir = '/var/svn/demo'
unless File.directory?(repo_dir)
  wc = '/tmp/demo-wc'
  sh('svnadmin', 'create', repo_dir)
  sh('svn', 'checkout', '-q', "file://#{repo_dir}", wc)
  { 'dirA' => 'alice', 'dirB' => 'bob' }.each do |dir, user|
    FileUtils.mkdir_p("#{wc}/trunk/#{dir}")
    File.write("#{wc}/trunk/#{dir}/README.md", "# #{dir}\n\nOnly #{user} can read this.\n")
    sh('svn', 'add', '-q', '--parents', "#{wc}/trunk/#{dir}")
    sh('svn', 'commit', '-q', '-m', "Add #{dir}", '--username', user, wc)
  end
  FileUtils.rm_rf(wc)
end

Redmine::DefaultData::Loader.load('en') if Role.givable.empty?
role = Role.find_by(:name => 'Developer') || Role.givable.first
role.add_permission!(:browse_repository, :view_changesets)

project = Project.find_by(:identifier => 'demo') ||
          Project.create!(:name => 'Demo', :identifier => 'demo', :enabled_module_names => %w(repository))
%w(alice bob).each do |login|
  user = User.find_by(:login => login) || User.new(:firstname => login.capitalize, :lastname => 'Demo',
                                                     :mail => "#{login}@example.net")
  user.login = login
  user.password = user.password_confirmation = 'password123'
  user.must_change_passwd = false
  user.save!
  Member.create!(:project => project, :principal => user, :roles => [role]) unless user.member_of?(project)
end

repository = project.repository || Repository::Subversion.create!(:project => project, :identifier => 'demo',
                                                                  :url => "file://#{repo_dir}/trunk",
                                                                  :is_default => true)
repository.fetch_changesets
config = repository.svn_authz_config || repository.build_svn_authz_config
config.update!(:enabled => true, :source => 'managed', :authz_content => <<~AUTHZ)
  [groups]
  team-a = alice

  [/trunk/dirA]
  @team-a = rw

  [/trunk/dirB]
  bob = rw
AUTHZ
# Second repository: the sparse checkout layout, alice in @team_a, bob in @team_b
sparse_dir = '/var/svn/sparse'
unless File.directory?(sparse_dir)
  wc = '/tmp/sparse-wc'
  sh('svnadmin', 'create', sparse_dir)
  sh('svn', 'checkout', '-q', "file://#{sparse_dir}", wc)
  {
    'admin' => %w(trunk/README trunk/src/Makefile trunk/include/README),
    'alice' => %w(trunk/src/module_a/app.c trunk/include/module_a/a.h),
    'bob' => %w(trunk/src/module_b/b.c trunk/src/module_b_ext/ext.c trunk/include/module_b/b.h)
  }.each do |user, files|
    files.each do |f|
      FileUtils.mkdir_p(File.dirname("#{wc}/#{f}"))
      File.write("#{wc}/#{f}", "#{f} by #{user}\n")
    end
    sh('svn', 'add', '-q', '--force', wc)
    sh('svn', 'commit', '-q', '-m', "Add files of #{user}", '--username', user, wc)
  end
  FileUtils.rm_rf(wc)
end
sparse = project.repositories.find_by(:identifier => 'sparse') ||
         Repository::Subversion.create!(:project => project, :identifier => 'sparse', :url => "file://#{sparse_dir}")
sparse.fetch_changesets
config = sparse.svn_authz_config || sparse.build_svn_authz_config
config.update!(:enabled => true, :source => 'managed', :authz_content => <<~AUTHZ)
  [groups]
  team_a = alice
  team_b = bob

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

  [/trunk/src/module_a]
  @team_a = rw
  [/trunk/include/module_a]
  @team_a = rw

  [/trunk/src/module_b]
  @team_b = rw
  [/trunk/src/module_b_ext]
  @team_b = rw
  [/trunk/include/module_b]
  @team_b = rw
  [/trunk/include/module_b_ext]
  @team_b = rw
AUTHZ

puts "Demo ready: project 'demo' (repositories demo and sparse), users alice / bob (password123)"
