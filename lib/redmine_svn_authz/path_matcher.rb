# frozen_string_literal: true

module RedmineSvnAuthz
  # Read-access decisions of one user on one repository, derived from
  # Policy#decision_points. All paths are absolute and relative to the svn
  # repository root. Pure Ruby; the SQL builder only needs a quoting callable.
  class PathMatcher
    def initialize(decision_points)
      @points = decision_points
      @points['/'] = false unless @points.key?('/')
    end

    def readable?(path)
      @points[nearest_point(Parser.normalize_path(path))]
    end

    # True if the user may read +path+ or anything below it. Directories that
    # are only traversable are shown so the user can navigate to their content.
    def traversable?(path)
      path = Parser.normalize_path(path)
      return true if readable?(path)

      @points.any? { |p, allowed| allowed && below?(p, path) }
    end

    # True if +path+ and everything below it is readable.
    def fully_readable?(path)
      path = Parser.normalize_path(path)
      readable?(path) && @points.none? { |p, allowed| !allowed && below?(p, path) }
    end

    def nothing_readable?
      @points.values.none?
    end

    def everything_readable?
      @points.values.all?
    end

    # SQL condition true when +column+ holds a readable path:
    # some allowed point P matches and no denied point below P matches.
    # +quote+ turns a Ruby string into an SQL string literal.
    def sql_condition(column, quote)
      return '1=1' if everything_readable?
      return '1=0' if nothing_readable?

      allowed, denied = @points.keys.partition { |p| @points[p] }
      clauses = allowed.map do |p|
        cond = p == '/' ? nil : match_sql(column, p, quote)
        excluded = denied.select { |d| below?(d, p) }.map { |d| match_sql(column, d, quote) }
        parts = [cond, ("NOT (#{excluded.join(' OR ')})" if excluded.any?)].compact
        "(#{parts.join(' AND ')})"
      end
      "(#{clauses.join(' OR ')})"
    end

    private

    def nearest_point(path)
      loop do
        return path if @points.key?(path)
        return '/' if path == '/'

        idx = path.rindex('/')
        path = idx.zero? ? '/' : path[0...idx]
      end
    end

    # Is +path+ strictly below +ancestor+?
    def below?(path, ancestor)
      return path != '/' if ancestor == '/'

      path.start_with?("#{ancestor}/")
    end

    def match_sql(column, path, quote)
      escaped = path.gsub(/[!%_]/) { |c| "!#{c}" }
      "(#{column} = #{quote.call(path)} OR #{column} LIKE #{quote.call("#{escaped}/%")} ESCAPE '!')"
    end
  end
end
