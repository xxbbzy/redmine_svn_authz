# frozen_string_literal: true

require 'digest'

module RedmineSvnAuthz
  # The authz rules that apply to one user on one repository, arranged as a
  # tree of path segments. Port of the Subversion 1.10+ lookup in
  # libsvn_repos/authz.c:
  #
  # * The path is walked segment by segment, following every rule node that
  #   matches (literal, *, **, prefix*, *suffix and fnmatch patterns).
  # * If any matched node at the current depth carries a rule, the one that
  #   appears latest in the authz file (highest sequence number) decides;
  #   otherwise the rights of the parent path are inherited.
  # * Without any matching rule at "/", access is denied.
  #
  # Paths are absolute and relative to the svn repository root.
  class UserRules
    class Node
      attr_accessor :rights, :repeat
      attr_reader :children, :patterns
      attr_writer :any, :any_var

      def initialize(repeat: false)
        @children = {}
        @patterns = []
        @repeat = repeat
      end

      # Child nodes for "*" and "**"
      def any
        @any
      end

      def any_var
        @any_var
      end

      def descendants
        @children.values + @patterns.map(&:last) + [@any, @any_var].compact
      end

      def read?
        rights && rights[1].include?('r')
      end

      def deny?
        rights && !rights[1].include?('r')
      end

      # Could any path matched in this sub-tree be readable / denied?
      def subtree_read?
        @subtree_read = read? || below_read? if @subtree_read.nil?
        @subtree_read
      end

      def below_read?
        (repeat && read?) || descendants.any?(&:subtree_read?)
      end

      def subtree_deny?
        @subtree_deny = deny? || below_deny? if @subtree_deny.nil?
        @subtree_deny
      end

      def below_deny?
        (repeat && deny?) || descendants.any?(&:subtree_deny?)
      end
    end

    # +acls+: [[section, access]] for the sections that apply to the user
    def initialize(acls)
      @acls = acls.sort_by { |section, _| section.seq }
      @root = Node.new
      @acls.each do |section, access|
        insert(section.segments).rights = [section.seq, access]
      end
      # Implicit default rule at the root: no access, lowest precedence
      @root.rights ||= [0, '']
    end

    def access(path)
      walk(path)[0][1]
    end

    def readable?(path)
      access(path).include?('r')
    end

    # True if +path+ or possibly something below it is readable. Like svn,
    # this does not check which paths exist, so wildcard rules can make it
    # true for directories that contain nothing readable.
    def traversable?(path)
      rights, current = walk(path)
      rights[1].include?('r') || current.any?(&:below_read?)
    end

    # True if +path+ and everything below it is readable.
    def fully_readable?(path)
      rights, current = walk(path)
      rights[1].include?('r') && current.none?(&:below_deny?)
    end

    def nothing_readable?
      !traversable?('/')
    end

    def everything_readable?
      fully_readable?('/')
    end

    # True if no wildcard rule is involved, so readability only depends on
    # the nearest ancestor with a rule (and can be expressed with LIKE).
    def literal?
      @acls.all? { |section, _| section.segments.all? { |s| s.kind == :literal } }
    end

    # For literal rules: { path => readable } at every path with a rule.
    def decision_points
      raise ArgumentError, 'wildcard rules have no decision points' unless literal?

      points = { '/' => @root.read? || false }
      @acls.each do |section, access|
        points["/#{section.segments.map(&:pattern).join('/')}"] = access.include?('r')
      end
      points
    end

    # [[section header, access]] in file order, for display.
    def describe
      @acls.map { |section, access| [section.header, access] }
    end

    # Identifies the effective rules: users with the same digest see exactly
    # the same paths.
    def digest
      @digest ||= Digest::SHA256.hexdigest(
        @acls.map { |section, access| [section.seq, section.key[1], access] }.inspect
      )
    end

    private

    def insert(segments)
      segments.reduce(@root) do |node, segment|
        case segment.kind
        when :literal
          node.children[segment.pattern] ||= Node.new
        when :any
          node.any ||= Node.new
        when :any_recursive
          node.any_var ||= Node.new(:repeat => true)
        else
          entry = node.patterns.find { |kind, pattern, _| kind == segment.kind && pattern == segment.pattern }
          entry ||= (node.patterns << [segment.kind, segment.pattern, Node.new]).last
          entry.last
        end
      end
    end

    # Returns [rights, nodes]: the rights ([seq, access]) at +path+ and the
    # rule nodes matching it, whose sub-trees may still apply below it.
    def walk(path)
      rights = @root.rights
      current = [@root]
      if @root.any_var
        rights = better(rights, @root.any_var.rights)
        current << @root.any_var
      end

      segments = path.to_s.split('/').reject(&:empty?)
      if segments.empty?
        # svn looks up the root as one empty segment, so e.g. [:glob:/*]
        # applies to "/" itself. The whole tree remains relevant below it.
        local, = step(current, '')
        return [local || rights, current]
      end

      segments.each do |segment|
        break if current.empty?

        local, current = step(current, segment)
        rights = local || rights
      end
      [rights, current]
    end

    # Follows +segment+ from the +current+ nodes. Returns the winning rights
    # among the matched nodes (nil if none carries a rule) and the nodes.
    def step(current, segment)
      nodes = []
      local = nil
      add = lambda do |node|
        next unless node

        local = better(local, node.rights)
        nodes << node
        # "**" also matches an empty sequence of segments
        if node.any_var
          local = better(local, node.any_var.rights)
          nodes << node.any_var
        end
      end

      current.each do |node|
        add.call(node.children[segment])
        add.call(node.any)
        add.call(node) if node.repeat
        node.patterns.each do |kind, pattern, child|
          add.call(child) if segment_matches?(kind, pattern, segment)
        end
      end
      [local, nodes.uniq]
    end

    def better(current, candidate)
      return current if candidate.nil?
      return candidate if current.nil?

      candidate[0] > current[0] ? candidate : current
    end

    def segment_matches?(kind, pattern, segment)
      case kind
      when :prefix then segment.start_with?(pattern)
      when :suffix then segment.end_with?(pattern)
      else File.fnmatch?(pattern, segment, File::FNM_DOTMATCH)
      end
    end
  end
end
