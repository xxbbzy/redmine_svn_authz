# frozen_string_literal: true

require 'set'

module RedmineSvnAuthz
  # Parsed authz rules. Evaluation for a given user happens in UserRules,
  # which ports the Subversion 1.10+ lookup algorithm (libsvn_repos/authz.c).
  #
  # Users are identified by login; nil means anonymous.
  class Policy
    attr_reader :groups, :aliases, :sections, :errors, :warnings

    def initialize(groups: {}, aliases: {}, sections: [], errors: [], warnings: [])
      @groups = groups
      @aliases = aliases
      @sections = sections
      @errors = errors
      @warnings = warnings
      @membership_cache = {}
      @user_rules_cache = {}
    end

    def valid?
      errors.empty?
    end

    # Reports references to undefined groups/aliases and group cycles.
    def validate!
      @groups.each_key { |name| detect_cycle(name, []) }
      @groups.each do |name, members|
        members.each { |m| check_reference(m, "group '@#{name}'", nil) }
      end
      @sections.each do |section|
        section.rules.each { |rule| check_reference(rule.principal.delete_prefix('~'), nil, rule.line) }
      end
      self
    end

    # The rules of +login+ on +repo+, ready for path lookups.
    def user_rules(login, repo: nil)
      @user_rules_cache[[login, repo]] ||= UserRules.new(effective_acls(login, repo))
    end

    # Returns the access string ('', 'r' or 'rw') of +login+ on +path+
    # (an absolute path relative to the svn repository root).
    def access_for(login, path, repo: nil)
      user_rules(login, repo: repo).access(path)
    end

    def readable?(login, path, repo: nil)
      access_for(login, path, repo: repo).include?('r')
    end

    def member_of_group?(login, group)
      return false if login.nil?

      group_members(group).include?(login)
    end

    # Port of svn_authz__get_acl_access(): [applies, access] of +section+ for
    # +login+. A section applies to a user if at least one entry matches.
    # Anonymous users only match '*', '$anonymous' and '~$authenticated'.
    def acl_access(section, login)
      # The global [/] section replaces svn's built-in default rule and
      # therefore applies to everybody.
      applies = section.root? && section.repo.nil?
      read = write = false
      section.rules.each do |rule|
        next unless entry_matches?(rule.principal, login)

        applies = true
        read ||= rule.access.include?('r')
        write ||= rule.access.include?('w')
      end
      [applies, (read ? 'r' : '') + (write ? 'w' : '')]
    end

    private

    # Sections that apply to +login+ on +repo+, with the user's access.
    # For the same rule, a [repo:...] section takes precedence over the
    # global one if it applies to the user or the global one does not.
    def effective_acls(login, repo)
      candidates = @sections.select { |s| s.repo.nil? || s.repo == repo }
      chosen = candidates.group_by { |s| s.key[1] }.values.map do |variants|
        global = variants.find { |s| s.repo.nil? }
        specific = variants.find(&:repo)
        if specific && (global.nil? || acl_access(specific, login)[0] || !acl_access(global, login)[0])
          specific
        else
          global
        end
      end
      chosen.map do |section|
        applies, access = acl_access(section, login)
        [section, access] if applies
      end.compact
    end

    def entry_matches?(principal, login)
      inverted = principal.start_with?('~')
      name = inverted ? principal[1..-1] : principal
      if login.nil?
        return true if name == '*'
        return !inverted if name == '$anonymous'
        return inverted if name == '$authenticated'

        return false
      end

      match =
        case name
        when '*', '$authenticated' then true
        when '$anonymous' then false
        when /\A@(.+)\z/ then member_of_group?(login, Regexp.last_match(1))
        when /\A&(.+)\z/ then @aliases[Regexp.last_match(1)] == login
        else name == login
        end
      # '~$anonymous' matches every authenticated user; '*' cannot be inverted
      name == '$anonymous' ? inverted : match != inverted
    end

    def group_members(group, seen = Set.new)
      return @membership_cache[group] if @membership_cache.key?(group)
      return Set.new if seen.include?(group)

      seen << group
      members = Set.new
      (@groups[group] || []).each do |m|
        case m
        when /\A@(.+)\z/ then members.merge(group_members(Regexp.last_match(1), seen))
        when /\A&(.+)\z/ then members << @aliases[Regexp.last_match(1)] if @aliases[Regexp.last_match(1)]
        else members << m
        end
      end
      @membership_cache[group] = members
    end

    def detect_cycle(group, stack)
      if stack.include?(group)
        msg = "recursive definition of group '@#{group}'"
        @errors << Parser::Issue.new(nil, msg) unless @errors.any? { |e| e.message == msg }
        return
      end
      (@groups[group] || []).each do |m|
        detect_cycle(m[1..-1], stack + [group]) if m.start_with?('@') && stack.size < 64
      end
    end

    def check_reference(principal, context, line)
      where = context ? " in #{context}" : ''
      if principal.start_with?('@') && !@groups.key?(principal[1..-1])
        @errors << Parser::Issue.new(line, "undefined group '#{principal}'#{where}")
      elsif principal.start_with?('&') && !@aliases.key?(principal[1..-1])
        @errors << Parser::Issue.new(line, "undefined alias '#{principal}'#{where}")
      end
    end
  end
end
