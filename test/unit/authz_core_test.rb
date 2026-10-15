# frozen_string_literal: true

# Pure Ruby tests for Parser / Policy / PathMatcher / Serializer.
# Also runnable without Redmine: ruby test/unit/authz_core_test.rb
redmine_test_helper = File.expand_path('../../../../test/test_helper.rb', __dir__)
if File.exist?(redmine_test_helper)
  # Inside Redmine the files are autoloaded; requiring them directly would
  # bypass Zeitwerk.
  require redmine_test_helper
else
  require 'minitest/autorun'
  %w(parser policy user_rules path_matcher serializer).each do |f|
    require_relative "../../lib/redmine_svn_authz/#{f}"
  end
end

class AuthzCoreTest < Minitest::Test
  P = RedmineSvnAuthz

  AUTHZ = <<~AUTHZ
    # sample
    [aliases]
    boss = carol

    [groups]
    team-a = alice, dave
    team-b = bob
    devs = @team-a, @team-b
    leads = &boss

    [/]
    @leads = r

    [/dirA]
    @team-a = rw

    [/dirA/secret]
    @team-a =
    alice = r

    [/dirB]
    @team-b = rw
    ~@devs = r

    [myrepo:/dirB]
    bob = r

    [/public]
    * = r

    [/members]
    $authenticated = r
    $anonymous =
  AUTHZ

  def policy
    @policy ||= P::Parser.parse(AUTHZ)
  end

  def test_parses_without_errors
    assert policy.valid?, policy.errors.map(&:to_s).join("\n")
    assert_equal %w[alice dave], policy.groups['team-a']
    assert_equal 'carol', policy.aliases['boss']
  end

  def test_access_table
    cases = [
      # login, path, repo, expected
      ['alice', '/dirA', nil, 'rw'],
      ['alice', '/dirA/sub/file.c', nil, 'rw'],
      ['alice', '/dirA/secret', nil, 'r'],      # union inside section
      ['dave', '/dirA/secret/x', nil, ''],      # nearest matching section wins
      ['alice', '/dirB', nil, ''],              # devs member -> ~@devs no match
      ['bob', '/dirB/f', nil, 'rw'],
      ['bob', '/dirB/f', 'myrepo', 'r'],        # repo section takes precedence
      ['bob', '/dirB/f', 'other', 'rw'],
      ['eve', '/dirB', nil, 'r'],               # ~@devs matches non-members
      ['bob', '/dirA', nil, ''],
      ['bob', '/', nil, ''],
      ['carol', '/', nil, 'r'],                 # group via alias
      ['carol', '/dirA/secret', nil, 'r'],      # inherited from /
      [nil, '/public/readme', nil, 'r'],        # anonymous and '*'
      [nil, '/members', nil, ''],
      ['bob', '/members/x', nil, 'r'],
      ['bob', '/dirAother', nil, '']            # prefix must be a full segment
    ]
    cases.each do |login, path, repo, expected|
      assert_equal expected, policy.access_for(login, path, repo: repo),
                   "access_for(#{login.inspect}, #{path}, repo: #{repo.inspect})"
    end
  end

  def test_errors_are_reported_with_line_numbers
    pol = P::Parser.parse(<<~AUTHZ)
      [groups]
      a = @b
      b = @a
      [/x]
      @nope = r
      alice = rx
      [relative]
      foo
      [:glob:/**/tmp]
      * = r
    AUTHZ
    messages = pol.errors.map(&:to_s)
    assert(messages.any? { |m| m.include?('recursive definition of group') })
    assert_includes messages, "line 5: undefined group '@nope'"
    assert(messages.any? { |m| m.start_with?("line 6: the access mode 'x'") })
    assert(messages.any? { |m| m.start_with?('line 7: section is not valid') })
    assert(messages.any? { |m| m.start_with?('line 8:') })
    assert_empty pol.warnings
  end

  def test_non_canonical_paths_are_rejected
    %w([/a//b] [/a/] [/a/./b] [/a/../b]).each do |header|
      assert_not_valid P::Parser.parse("#{header}\n* = r\n"), header
    end
  end

  def test_continuation_lines
    pol = P::Parser.parse("[groups]\ng = alice,\n  bob\n[/a/b]\n@g = r\n")
    assert pol.valid?, pol.errors.map(&:to_s).join("\n")
    assert_equal %w[alice bob], pol.groups['g']
    assert pol.readable?('bob', '/a/b/c')
  end

  def test_anonymous_only_matches_anonymous_entries
    pol = P::Parser.parse("[/]\n~alice = r\n[/x]\n~$authenticated = r\n")
    assert_equal '', pol.access_for(nil, '/')
    assert_equal 'r', pol.access_for('bob', '/')
    assert_equal 'r', pol.access_for(nil, '/x')
  end

  # Sparse checkout layout: parents readable, every module denied by a
  # wildcard rule, then each module granted to its group.
  SPARSE = <<~AUTHZ
    [groups]
    team_a = user_a
    team_b = user_b

    [/trunk]
    @team_a = r
    @team_b = r
    [/trunk/src]
    @team_a = r
    @team_b = r
    [/trunk/include]
    @team_a = r
    @team_b = r

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

  def test_sparse_checkout_layout
    pol = P::Parser.parse(SPARSE)
    assert pol.valid?, pol.errors.map(&:to_s).join("\n")
    {
      '/' => ['', ''],
      '/trunk' => %w(r r),
      '/trunk/README' => %w(r r),
      '/trunk/src' => %w(r r),
      '/trunk/src/Makefile' => ['', ''],
      '/trunk/src/module_a/app.c' => ['rw', ''],
      '/trunk/src/module_b/x.c' => ['', 'rw'],
      '/trunk/src/module_b_ext/ext.c' => ['', 'rw'],
      '/trunk/src/other' => ['', ''],
      '/trunk/include/module_a/a.h' => ['rw', ''],
      '/trunk/include/module_b/b.h' => ['', 'rw'],
      '/trunk/include/module_b_ext' => ['', 'rw'],
      '/branches' => ['', '']
    }.each do |path, (team_a, team_b)|
      assert_equal team_a, pol.access_for('user_a', path), "user_a #{path}"
      assert_equal team_b, pol.access_for('user_b', path), "user_b #{path}"
      assert_equal '', pol.access_for(nil, path), "anonymous #{path}"
    end

    rules = pol.user_rules('user_a')
    refute rules.literal?
    assert rules.traversable?('/')
    assert rules.traversable?('/trunk/src')
    refute rules.traversable?('/trunk/src/module_b')
    refute rules.fully_readable?('/trunk/src')
    assert rules.fully_readable?('/trunk/src/module_a')
  end

  def test_later_wildcard_section_wins_at_the_same_depth
    pol = P::Parser.parse("[/src/module_a]\n* = r\n[:glob:/src/*]\n* =\n")
    assert_equal '', pol.access_for('user_a', '/src/module_a/a.c')
    pol = P::Parser.parse("[:glob:/src/*]\n* =\n[/src/module_a]\n* = r\n")
    assert_equal 'r', pol.access_for('user_a', '/src/module_a/a.c')
  end

  def test_recursive_wildcards
    pol = P::Parser.parse("[/]\n* = r\n[:glob:/**/secret*]\n* =\n[:glob:/**/*.key]\n* =\n")
    assert_equal 'r', pol.access_for('x', '/a/b/c.txt')
    assert_equal '', pol.access_for('x', '/a/secret')
    assert_equal '', pol.access_for('x', '/a/b/secrets/c.txt')
    assert_equal '', pol.access_for('x', '/id.key')
    assert_equal 'r', pol.access_for('x', '/id.key.txt')
  end

  def assert_not_valid(policy, message = nil)
    refute policy.valid?, message
  end

  def test_path_matcher
    m = P::PathMatcher.new(policy.user_rules('alice').decision_points)
    assert m.readable?('/dirA/x')
    refute m.readable?('/')
    assert m.traversable?('/')
    refute m.traversable?('/dirB')
    assert m.fully_readable?('/dirA/secret')
    m2 = P::PathMatcher.new(policy.user_rules('dave').decision_points)
    refute m2.fully_readable?('/dirA')
    refute m2.readable?('/dirA/secret/y')
  end

  def test_sql_condition_agrees_with_readable
    require 'sqlite3'
    db = SQLite3::Database.new(':memory:')
    db.execute('CREATE TABLE changes (path TEXT)')
    paths = %w[/ /dirA /dirA/a.c /dirA/secret /dirA/secret/k /dirAx /dirB /dirB/y
               /public/p /members/m /dir_A /dir%A /other]
    paths.each { |p| db.execute('INSERT INTO changes VALUES (?)', [p]) }
    quote = ->(s) { "'#{s.gsub("'", "''")}'" }
    [nil, 'alice', 'dave', 'bob', 'carol', 'eve'].each do |login|
      %w[nil myrepo].each do |repo|
        repo = nil if repo == 'nil'
        rules = policy.user_rules(login, repo: repo)
        m = P::PathMatcher.new(rules.decision_points)
        sql = "SELECT path FROM changes WHERE #{m.sql_condition('path', quote)}"
        expected = paths.select { |p| rules.readable?(p) }.sort
        assert_equal expected, db.execute(sql).flatten.sort, "login=#{login.inspect} repo=#{repo.inspect}"
      end
    end
  rescue LoadError
    skip 'sqlite3 gem not available'
  end

  def test_serializer_round_trip
    text = P::Serializer.dump(policy)
    again = P::Parser.parse(text)
    assert again.valid?, again.errors.map(&:to_s).join("\n")
    [nil, 'alice', 'dave', 'bob', 'carol', 'eve'].each do |login|
      %w[/ /dirA /dirA/secret /dirB /public /members].each do |path|
        assert_equal policy.access_for(login, path, repo: 'myrepo'),
                     again.access_for(login, path, repo: 'myrepo')
      end
    end
  end
end
