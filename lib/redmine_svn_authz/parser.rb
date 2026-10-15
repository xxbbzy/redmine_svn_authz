# frozen_string_literal: true

module RedmineSvnAuthz
  # Parses Subversion authz files (mod_authz_svn / svnserve format), following
  # the Subversion 1.10+ parser (libsvn_subr/config_file.c and
  # libsvn_repos/authz_parse.c), including [:glob:...] wildcard sections.
  #
  # Pure Ruby, no Rails dependency. Returns a Policy; syntax problems are
  # collected in Policy#errors (with line numbers) instead of raising, so the
  # configuration UI can report all of them at once. svn refuses to load a
  # file with any of these errors.
  class Parser
    Rule = Struct.new(:principal, :access, :line)

    # kind: :literal, :prefix, :suffix, :any (*), :any_recursive (**) or
    # :fnmatch. +pattern+ is the literal text, the prefix / suffix, or the
    # fnmatch pattern ('' for * and **).
    Segment = Struct.new(:kind, :pattern)

    # +path+ is the path as written in the header; +segments+ its parsed
    # form ([] for the root). +seq+ is the position among rule sections
    # (1-based): when several rules match a path at the same depth, the one
    # with the highest seq wins.
    Section = Struct.new(:repo, :path, :glob, :segments, :rules, :line, :seq) do
      def header
        name = repo ? "#{repo}:#{path}" : path
        glob ? ":glob:#{name}" : name
      end

      def root?
        segments.empty?
      end

      # Sections with the same key describe the same rule.
      def key
        [repo.to_s, segments.map { |s| [s.kind, s.pattern] }]
      end
    end

    Issue = Struct.new(:line, :message) do
      def to_s
        line ? "line #{line}: #{message}" : message
      end
    end

    RESERVED_NAME_CHARS = '@$&*~'

    def self.parse(text)
      new(text).parse
    end

    # Normalizes a browse/repository path: leading slash, no trailing slash
    # (except for the root), no empty or "." segments.
    def self.normalize_path(path)
      segments = path.to_s.split('/').reject { |s| s.empty? || s == '.' }
      '/' + segments.join('/')
    end

    # Parses a section name (without brackets). Returns [section, error];
    # section is :groups / :aliases for those sections.
    def self.parse_section_name(name)
      glob = false
      rest = name
      if rest.start_with?(':')
        token, sep, after = rest[1..-1].partition(':')
        return [nil, "empty repository name in authz rule [#{name}]"] if sep.empty?
        return [nil, "invalid type token '#{token}' in authz rule [#{name}]"] unless token == 'glob'

        glob = true
        rest = after
      end

      repo = nil
      unless rest.start_with?('/')
        idx = rest.index(':')
        if idx
          return [nil, "empty repository name in authz rule [#{name}]"] if idx.zero?

          repo = rest[0...idx]
          rest = rest[(idx + 1)..-1]
        end
      end

      unless rest.start_with?('/')
        return [:groups, nil] if name == 'groups'
        return [:aliases, nil] if name == 'aliases'

        return [nil, "section is not valid in the authz file: [#{name}]"]
      end

      segments, error = parse_rule_path(rest, glob)
      return [nil, "#{error} in authz rule [#{name}]"] if error

      [Section.new(repo, rest, glob, segments, [], nil, nil), nil]
    end

    # Port of parse_rule_path() in authz_parse.c.
    def self.parse_rule_path(path, glob)
      segments = []
      parts = path[1..-1].split('/', -1)
      parts.each_with_index do |part, i|
        if part.empty?
          return [[], nil] if i.zero?

          return [nil, "non-canonical path '#{path}' (empty segment)"]
        end
        return [nil, "non-canonical path '#{path}' ('#{part}' segment)"] if part == '.' || part == '..'

        unless glob
          segments << Segment.new(:literal, part)
          next
        end
        unless fnmatch_test(part)
          segments << Segment.new(:literal, unescape(part))
          next
        end

        if part == '*'
          if segments.last&.kind == :any_recursive
            # "**/*" is normalized to "*/**"
            segments.last.kind = :any
            segments << Segment.new(:any_recursive, '')
          else
            segments << Segment.new(:any, '')
          end
        elsif part == '**'
          # "**/**" is the same as "**"
          segments << Segment.new(:any_recursive, '') unless segments.last&.kind == :any_recursive
        elsif part.start_with?('*') && !fnmatch_test(part[1..-1])
          segments << Segment.new(:suffix, unescape(part[1..-1]))
        elsif part.end_with?('*') && part[-2] != '\\' && !fnmatch_test(part[0...-1])
          segments << Segment.new(:prefix, unescape(part[0...-1]))
        else
          segments << Segment.new(:fnmatch, part)
        end
      end
      [segments, nil]
    end

    # Port of apr_fnmatch_test(): does the pattern contain wildcards?
    def self.fnmatch_test(pattern)
      nesting = 0
      i = 0
      while i < pattern.length
        case pattern[i]
        when '?', '*' then return true
        when '\\'
          i += 1
          return false if i >= pattern.length
        when '[' then nesting += 1
        when ']' then return true if nesting.positive?
        end
        i += 1
      end
      false
    end

    # Port of unescape_in_place(): drops backslash escapes.
    def self.unescape(text)
      idx = text.index('\\')
      return text unless idx

      out = +text[0...idx]
      escape = true
      text[(idx + 1)..-1].each_char do |c|
        if escape
          out << c
          escape = false
        elsif c == '\\'
          escape = true
        else
          out << c
        end
      end
      out << '\\' if escape
      out
    end

    def initialize(text)
      @text = text.to_s
    end

    def parse
      @groups = {}
      @aliases = {}
      @sections = []
      @errors = []
      @warnings = []
      @seen_headers = {}
      @seen_rules = {}
      current = nil

      logical_lines.each do |lineno, kind, data|
        case kind
        when :error
          @errors << Issue.new(lineno, data)
        when :section
          current = start_section(lineno, data)
        when :option
          name, value = data
          case current
          when nil then @errors << Issue.new(lineno, 'section header expected')
          when :skip then next
          when :groups then add_group(lineno, name, value)
          when :aliases then add_alias(lineno, name, value)
          when Section then add_rule(lineno, current, name, value)
          end
        end
      end

      Policy.new(groups: @groups, aliases: @aliases, sections: @sections,
                 errors: @errors, warnings: @warnings).tap(&:validate!)
    end

    private

    # Port of svn_config__parse_stream(): yields [line, kind, data] where
    # kind is :section (data = name), :option (data = [name, value]) or
    # :error (data = message). '#' starts a comment only in the first column;
    # an indented line right after an option continues its value.
    def logical_lines
      lines = @text.dup.force_encoding(Encoding::UTF_8).delete_prefix("﻿").split("\n", -1)
      result = []
      i = 0
      while i < lines.size
        lineno = i + 1
        line = lines[i]
        stripped = line.lstrip
        indent = line.length - stripped.length
        i += 1
        next if stripped.strip.empty?

        case stripped[0]
        when '['
          if indent.positive?
            result << [lineno, :error, 'section header must start in the first column']
          elsif (close = stripped.index(']'))
            result << [lineno, :section, stripped[1...close]]
          else
            result << [lineno, :error, "section header must end with ']'"]
          end
        when '#'
          result << [lineno, :error, 'comment must start in the first column'] if indent.positive?
        else
          if indent.positive?
            result << [lineno, :error, 'option expected']
            next
          end
          option = split_option(line)
          unless option
            result << [lineno, :error, "option must end with ':' or '='"]
            next
          end
          name, value = option
          # Continuation lines: indented, non-blank lines that follow
          while i < lines.size && lines[i] =~ /\A[ \t\r\f\v]/ && !lines[i].strip.empty?
            value = "#{value} #{lines[i].strip}"
            i += 1
          end
          result << [lineno, :option, [name, value.strip]]
        end
      end
      result
    end

    # The name ends at the first ':' before '=' or at '='.
    def split_option(line)
      equals = line.index('=')
      colon = line.index(':')
      separator = equals && colon && colon < equals ? colon : (equals || colon)
      return nil unless separator

      [line[0...separator].rstrip, line[(separator + 1)..-1].strip]
    end

    def start_section(lineno, name)
      if @seen_headers.key?(name)
        @errors << Issue.new(lineno, "section appears more than once in the authz file: [#{name}]")
        return :skip
      end
      @seen_headers[name] = true

      section, error = self.class.parse_section_name(name)
      if error
        @errors << Issue.new(lineno, error)
        return :skip
      end
      return section if section.is_a?(Symbol)

      if (other = @seen_rules[section.key])
        @errors << Issue.new(lineno, "section [#{name}] describes the same rule as section [#{other}]")
        return :skip
      end
      @seen_rules[section.key] = name
      section.line = lineno
      section.seq = @sections.size + 1
      @sections << section
      section
    end

    def add_group(lineno, name, value)
      if RESERVED_NAME_CHARS.include?(name[0])
        @errors << Issue.new(lineno, "group name '#{name}' may not begin with '#{name[0]}'")
      elsif @groups.key?(name)
        @errors << Issue.new(lineno, "can't override definition of group '@#{name}'")
      else
        @groups[name] = value.split(',').map(&:strip).reject(&:empty?)
      end
    end

    def add_alias(lineno, name, value)
      if RESERVED_NAME_CHARS.include?(name[0])
        @errors << Issue.new(lineno, "alias name '#{name}' may not begin with '#{name[0]}'")
      elsif @aliases.key?(name)
        @errors << Issue.new(lineno, "can't override definition of alias '&#{name}'")
      else
        @aliases[name] = value
      end
    end

    # Port of add_access_entry().
    def add_rule(lineno, section, principal, value)
      name = principal.delete_prefix('~')
      inverted = name.length != principal.length
      error =
        if name.start_with?('~')
          "access entry '#{principal}' has more than one inversion; double negatives are not permitted"
        elsif name.start_with?('*') && name != '*'
          "access entry '#{principal}' is not valid; it must be a single '*'"
        elsif inverted && name == '*'
          "access entry '~*' will never match"
        elsif name.start_with?('$') && !%w($anonymous $authenticated).include?(name)
          "access entry token '#{principal}' is not valid; should be '$anonymous' or '$authenticated'"
        elsif (bad = value.delete(" \t\r\f\v").delete('rw')[0])
          "the access mode '#{bad}' in access entry '#{principal}' of rule [#{section.header}] is not valid"
        elsif value.include?('w') && !value.include?('r')
          "write-only access entry '#{principal}' of rule [#{section.header}] is not valid"
        end
      if error
        @errors << Issue.new(lineno, error)
        return
      end

      # Canonical form: '', 'r' or 'rw'
      access = value.include?('r') ? (value.include?('w') ? 'rw' : 'r') : ''
      section.rules << Rule.new(principal, access, lineno)
    end
  end
end
