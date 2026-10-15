# frozen_string_literal: true

# Compares Parser/Policy/UserRules with the real Subversion implementation
# (the `svnauthz` tool) on randomly generated authz files.
#
#   SVN_AUTHZ_FUZZ=500 ruby test/unit/svnauthz_differential_test.rb
#
# Skipped when svnauthz is not installed.
redmine_test_helper = File.expand_path('../../../../test/test_helper.rb', __dir__)
if File.exist?(redmine_test_helper)
  require redmine_test_helper
else
  require 'minitest/autorun'
  %w(parser policy user_rules).each { |f| require_relative "../../lib/redmine_svn_authz/#{f}" }
end
require 'open3'
require 'tempfile'

class SvnauthzDifferentialTest < Minitest::Test
  P = RedmineSvnAuthz

  USERS = [nil, 'alice', 'bob', 'carol', 'dave'].freeze
  REPO = 'repo1'
  LITERALS = %w(trunk src lib app include a.c b.h .hidden x).freeze
  GLOBS = ['*', '**', 'a*', '*.c', 'li?', '[ab]*', '*o*', '.*', 'lib*'].freeze
  PRINCIPALS = ['*', '$anonymous', '$authenticated', '~$anonymous', '~$authenticated',
                'alice', 'bob', '~carol', '@g1', '~@g2', '&a1'].freeze
  ACCESS = ['', 'r', 'rw'].freeze

  def setup
    skip 'svnauthz is not installed' unless system('svnauthz --version > /dev/null 2>&1')
    @rng = Random.new(Integer(ENV.fetch('SVN_AUTHZ_SEED', 20_261_015)))
  end

  def test_access_matches_svnauthz
    iterations = Integer(ENV.fetch('SVN_AUTHZ_FUZZ', 40))
    checked = 0
    iterations.times do
      text = random_authz
      policy = P::Parser.parse(text)
      next unless policy.valid? # validity is compared separately

      with_file(text) do |file|
        20.times do
          user = USERS.sample(random: @rng)
          path = random_path
          expected = svnauthz_access(file, user, path)
          actual = policy.access_for(user, path, repo: REPO)
          actual = 'no' if actual.empty?
          assert_equal expected, actual, "user=#{user.inspect} path=#{path}\n#{text}"
          checked += 1
        end
      end
    end
    assert_operator checked, :>, 0
  end

  def test_validity_matches_svnauthz
    texts = Array.new(Integer(ENV.fetch('SVN_AUTHZ_FUZZ', 40))) { random_authz(invalid: true) }
    texts += [
      "[/a/]\n* = r\n", "[/a//b]\n* = r\n", "[/a/../b]\n* = r\n", "[/a]\n* = w\n",
      "[/a]\n~* = r\n", "[/a]\n~~alice = r\n", "[/a]\n$nobody = r\n", "[/a]\n** = r\n",
      "[/a]\n* = rx\n", "[/a]\n* = r\n[/a]\n* = r\n", "[/a]\n* = r\n[:glob:/a]\n* = r\n",
      "[:glob:/a/**/**]\n* = r\n[:glob:/a/**]\n* = r\n", "[:nope:/a]\n* = r\n", "[foo]\n* = r\n",
      "[groups]\n@g = a\n", "[groups]\ng = @h\n", "[groups]\ng = @h\nh = @g\n[/]\n@g = r\n",
      "[aliases]\n&x = a\n", "[/a]\n@missing = r\n", "[/a]\n&missing = r\n",
      " [/a]\n* = r\n", "[/a]\n  * = r\n", "[/a]\n# c\n * = r\n", "[/a]\n* = r\n  # indented\n",
      "[/a]\n* :r\n", "[/a]\n* = \n  r\n", "* = r\n", "[/a\n* = r\n", "[/a] trailing\n* = r\n",
      "[repo1:/a]\n* = r\n[/a]\n* =\n", "[:repo1:/a]\n* = r\n", "[:glob:repo1:/a/*]\n* = r\n"
    ]
    texts.each do |text|
      with_file(text) do |file|
        _out, status = Open3.capture2e('svnauthz', 'validate', file)
        assert_equal status.success?, P::Parser.parse(text).valid?,
                     "svnauthz validate says #{status.success? ? 'valid' : 'invalid'}:\n#{text}"
      end
    end
  end

  private

  def svnauthz_access(file, user, path)
    args = ['svnauthz', 'accessof', '--path', path, '--repository', REPO]
    args += ['--username', user] if user
    out, status = Open3.capture2e(*args, file)
    raise "svnauthz failed: #{out}" unless status.success?

    out.strip
  end

  def with_file(text)
    file = Tempfile.new('authz')
    file.write(text)
    file.close
    yield file.path
  ensure
    file&.unlink
  end

  def random_authz(invalid: false)
    out = ["[aliases]\na1 = dave\n", "[groups]\ng1 = alice, bob\ng2 = @g1, carol\n"]
    headers = []
    @rng.rand(1..7).times do
      glob = @rng.rand < 0.6
      depth = @rng.rand(0..4)
      segments = Array.new(depth) do
        glob && @rng.rand < 0.5 ? GLOBS.sample(random: @rng) : LITERALS.sample(random: @rng)
      end
      path = "/#{segments.join('/')}"
      repo = @rng.rand < 0.25 ? "#{%w(repo1 repo2).sample(random: @rng)}:" : ''
      header = glob ? ":glob:#{repo}#{path}" : "#{repo}#{path}"
      next if !invalid && headers.include?(header)

      headers << header
      entries = Array.new(@rng.rand(0..3)) do
        "#{PRINCIPALS.sample(random: @rng)} = #{ACCESS.sample(random: @rng)}"
      end
      entries << '* = w' if invalid && @rng.rand < 0.1
      out << "[#{header}]\n#{entries.uniq.join("\n")}\n"
    end
    out.join("\n")
  end

  def random_path
    vocabulary = LITERALS + %w(app2 libx foo.c)
    '/' + Array.new(@rng.rand(0..5)) { vocabulary.sample(random: @rng) }.join('/')
  end
end
