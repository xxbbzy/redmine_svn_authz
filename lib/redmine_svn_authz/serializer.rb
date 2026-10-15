# frozen_string_literal: true

module RedmineSvnAuthz
  # Turns a Policy (or the structured form submitted by the rule editor) back
  # into authz text. Comments of the original text are not preserved.
  # Sections keep their order: with wildcard rules, the order decides which
  # rule wins.
  class Serializer
    def self.dump(policy)
      new(policy.groups, policy.aliases, policy.sections).dump
    end

    # +groups+:   { 'name' => ['member', ...] }
    # +aliases+:  { 'name' => 'login' }
    # +sections+: objects responding to #header (section name without
    #             brackets) and #rules (responding to #principal, #access)
    def initialize(groups, aliases, sections)
      @groups = groups
      @aliases = aliases
      @sections = sections
    end

    def dump
      out = []
      unless @aliases.empty?
        out << '[aliases]'
        @aliases.each { |name, value| out << "#{name} = #{value}" }
        out << ''
      end
      unless @groups.empty?
        out << '[groups]'
        @groups.each { |name, members| out << "#{name} = #{members.join(', ')}" }
        out << ''
      end
      merged_sections.each do |header, rules|
        out << "[#{header}]"
        rules.each { |rule| out << "#{rule.principal} = #{rule.access}".rstrip }
        out << ''
      end
      out.join("\n")
    end

    private

    # Rows with the same header are merged, in order of first appearance.
    def merged_sections
      merged = {}
      @sections.each do |section|
        (merged[section.header] ||= []).concat(section.rules.to_a)
      end
      merged
    end
  end
end
